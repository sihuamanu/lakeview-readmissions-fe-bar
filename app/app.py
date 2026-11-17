"""Lakeview Health - Transitions of Care (FE Bar build, synthetic data).

Coordinator view : risk-ranked worklist from Lakebase (synced from Unity Catalog), facility-scoped by
                   lakeview_ml.facility_access, PHI masked unless can_view_phi; outreach logged to care.outreach_actions.
Executive view   : readmission KPIs from Unity Catalog via SQL warehouse + Genie for natural-language questions.
"""
import os
import pandas as pd
import psycopg
import streamlit as st
from psycopg_pool import ConnectionPool
from databricks.sdk import WorkspaceClient

st.set_page_config(page_title="Lakeview Health - Transitions of Care", page_icon="🏥", layout="wide")

w = WorkspaceClient()
BRANCH = os.getenv("LAKEBASE_BRANCH", "projects/lakeview-health/branches/production")
WAREHOUSE_ID = os.getenv("DATABRICKS_WAREHOUSE_ID")
GENIE_SPACE_ID = os.getenv("GENIE_SPACE_ID")
KPI_TABLE = os.getenv("KPI_TABLE", "simo_show_case_catalog.lakeview_health.gold_readmission_kpis_monthly")
WORKLIST = "lakeview_ml.worklist_app_feed_synced"
ACCESS = "lakeview_ml.facility_access_synced"

st.markdown("""
<style>
.chip {display:inline-block; padding:2px 10px; margin:2px 4px 2px 0; border-radius:12px; background:#e8f1fb; color:#0b4f8a; font-size:0.85rem;}
.tier-High {color:#b42318; font-weight:700;} .tier-Medium {color:#b54708; font-weight:700;} .tier-Low {color:#027a48; font-weight:700;}
.footer {color:#6b7280; font-size:0.8rem; margin-top:2rem;}
</style>""", unsafe_allow_html=True)


# ---------------------------------------------------------------- Lakebase connection (OAuth token per connection)
def _endpoint_name() -> str:
    ep = os.getenv("LAKEBASE_ENDPOINT", "")
    if ep.startswith("projects/") and "/endpoints/" in ep:
        return ep
    return next(iter(w.postgres.list_endpoints(parent=BRANCH))).name


class TokenConnection(psycopg.Connection):
    @classmethod
    def connect(cls, conninfo="", **kwargs):
        kwargs["password"] = w.postgres.generate_database_credential(endpoint=_endpoint_name()).token
        return super().connect(conninfo, **kwargs)


@st.cache_resource
def get_pool() -> ConnectionPool:
    conninfo = (f"host={os.environ['PGHOST']} port={os.environ.get('PGPORT', '5432')} dbname={os.environ.get('PGDATABASE', 'databricks_postgres')} "
                f"user={os.environ['PGUSER']} sslmode=require")
    pool = ConnectionPool(conninfo=conninfo, connection_class=TokenConnection, min_size=1, max_size=5,
                          max_lifetime=2700, kwargs={"autocommit": True}, open=True)
    with pool.connection() as conn:   # app-owned schema for write-back (service principal creates and owns it)
        conn.execute("CREATE SCHEMA IF NOT EXISTS care")
        conn.execute("""CREATE TABLE IF NOT EXISTS care.outreach_actions (
            action_id BIGSERIAL PRIMARY KEY,
            encounter_id TEXT NOT NULL,
            coordinator_email TEXT NOT NULL,
            action_type TEXT NOT NULL,
            outcome TEXT NOT NULL,
            followup_booked BOOLEAN NOT NULL DEFAULT FALSE,
            notes TEXT,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now())""")
        conn.execute("CREATE INDEX IF NOT EXISTS outreach_actions_encounter_idx ON care.outreach_actions (encounter_id)")
    return pool


def pg_df(sql: str, params=None) -> pd.DataFrame:
    with get_pool().connection() as conn, conn.cursor() as cur:
        cur.execute(sql, params)
        cols = [d.name for d in cur.description]
        return pd.DataFrame(cur.fetchall(), columns=cols)


def pg_exec(sql: str, params=None):
    with get_pool().connection() as conn:
        conn.execute(sql, params)


# ---------------------------------------------------------------- identity and entitlements
def current_user() -> str:
    try:
        email = st.context.headers.get("X-Forwarded-Email")
    except Exception:
        email = None
    return email or os.getenv("DEV_USER_EMAIL", "unknown@local")


def entitlements(email: str):
    df = pg_df(f"SELECT facility_id, can_view_phi FROM {ACCESS} WHERE lower(principal) = lower(%s)", (email,))
    facilities = sorted(df.facility_id.unique().tolist()) if len(df) else []
    if "*" in facilities:
        facilities = ["LVH-CENTRAL", "LVH-NORTH", "LVH-SOUTH"]
    return facilities, bool(df.can_view_phi.any()) if len(df) else False


# ---------------------------------------------------------------- UC / SQL warehouse
@st.cache_data(ttl=600)
def sql_df(statement: str) -> pd.DataFrame:
    r = w.statement_execution.execute_statement(warehouse_id=WAREHOUSE_ID, statement=statement, wait_timeout="50s")
    if r.status and r.status.error:
        raise RuntimeError(r.status.error.message)
    cols = [c.name for c in r.manifest.schema.columns]
    return pd.DataFrame((r.result.data_array or []) if r.result else [], columns=cols)


# ---------------------------------------------------------------- header
user = current_user()
st.title("🏥 Lakeview Health - Transitions of Care")
st.caption("Daily 30-day readmission risk worklist | model: readmission_risk@champion (Unity Catalog) | GenAI social-risk features and call briefs")

try:
    allowed, can_view_phi = entitlements(user)
except Exception as e:
    st.error(f"Could not read from Lakebase. Check that the app service principal can read the synced tables. Details: {e}")
    st.stop()

coord_tab, exec_tab = st.tabs(["📋 Coordinator worklist", "📈 Executive view"])

# ================================================================ COORDINATOR VIEW
with coord_tab:
    if not allowed:
        st.warning(f"{user} has no facility entitlement in lakeview_ml.facility_access. Ask a care-management admin for access.")
    else:
        st.info(f"Signed in as **{user}** | facilities: **{', '.join(allowed)}** | PHI: **{'visible' if can_view_phi else 'masked'}**")
        f1, f2, f3 = st.columns([2, 2, 2])
        fac = f1.multiselect("Facility", allowed, default=allowed)
        tiers = f2.multiselect("Risk tier", ["High", "Medium", "Low"], default=["High", "Medium"])
        max_days = f3.slider("Days since discharge (max)", 0, 30, 7)

        wl = pg_df(f"""
            SELECT w.encounter_id, w.first_name, w.last_name, w.mrn, w.dob, w.facility_id, w.days_since_discharge,
                   w.primary_condition, w.discharge_disposition, w.age_at_admit, w.sex, w.primary_language, w.lace_score,
                   w.risk_percentile, w.risk_tier, w.top_drivers, w.social_risk_summary, w.coordinator_brief,
                   w.followup_scheduled_7d, w.followup_provider_type,
                   (SELECT max(o.created_at) FROM care.outreach_actions o WHERE o.encounter_id = w.encounter_id) AS last_outreach,
                   (SELECT o.outcome FROM care.outreach_actions o WHERE o.encounter_id = w.encounter_id ORDER BY o.created_at DESC LIMIT 1) AS last_outcome
            FROM {WORKLIST} w
            WHERE w.facility_id = ANY(%s) AND w.risk_tier = ANY(%s) AND w.days_since_discharge <= %s
            ORDER BY w.risk_percentile DESC""", (fac or ["none"], tiers or ["none"], max_days))

        if not can_view_phi and len(wl):
            wl["first_name"], wl["last_name"], wl["mrn"] = "***", "***", "***"
            wl["dob"] = pd.to_datetime(wl["dob"]).dt.year.astype(str) + "-**-**"
        wl["patient"] = wl["last_name"].astype(str) + ", " + wl["first_name"].astype(str)

        m1, m2, m3, m4 = st.columns(4)
        m1.metric("Patients on list", len(wl))
        m2.metric("High risk", int((wl.risk_tier == "High").sum()))
        m3.metric("Not yet contacted", int(wl.last_outreach.isna().sum()))
        m4.metric("No follow-up booked", int((~wl.followup_scheduled_7d.astype(bool)).sum()) if len(wl) else 0)

        view = wl[["patient", "mrn", "facility_id", "days_since_discharge", "primary_condition", "risk_tier", "risk_percentile",
                   "lace_score", "top_drivers", "last_outcome"]].rename(columns={
            "facility_id": "facility", "days_since_discharge": "days out", "primary_condition": "condition", "risk_tier": "tier",
            "risk_percentile": "risk pct", "lace_score": "LACE", "top_drivers": "top drivers", "last_outcome": "last outreach"})
        event = st.dataframe(view, hide_index=True, use_container_width=True, on_select="rerun", selection_mode="single-row",
                             column_config={"risk pct": st.column_config.ProgressColumn("risk pct", min_value=0, max_value=100, format="%.0f")})

        rows = event.selection.rows if event and event.selection else []
        if not len(wl):
            st.write("No patients match the filters.")
        elif not rows:
            st.caption("Select a patient row to see the risk explanation, the GenAI call brief, and to log outreach.")
        else:
            p = wl.iloc[rows[0]]
            st.divider()
            left, right = st.columns([3, 2])
            with left:
                st.subheader(f"{p.patient}  ·  {p.age_at_admit}{p.sex}  ·  {p.primary_condition}")
                st.markdown(f"MRN {p.mrn} · DOB {p.dob} · {p.facility_id} · discharged {p.days_since_discharge} days ago to "
                            f"{str(p.discharge_disposition).lower()} · language: {p.primary_language}")
                st.markdown(f"Risk tier <span class='tier-{p.risk_tier}'>{p.risk_tier}</span> · {p.risk_percentile:.0f}th percentile "
                            f"(LACE {p.lace_score}) <br><span style='color:#6b7280;font-size:0.8rem'>Percentile vs all historical discharges. "
                            f"Decision support only.</span>", unsafe_allow_html=True)
                st.markdown("**Why this patient is at risk**<br>" + "".join(f"<span class='chip'>{d.strip()}</span>" for d in str(p.top_drivers).split("|")),
                            unsafe_allow_html=True)
                st.markdown(f"**Social history (GenAI from discharge note):** {p.social_risk_summary or 'none documented'}")
                st.markdown(f"**Follow-up:** {'scheduled with ' + str(p.followup_provider_type) if p.followup_scheduled_7d else '⚠️ none scheduled'}")
                st.markdown("**GenAI call brief**")
                st.info(p.coordinator_brief)
            with right:
                st.markdown("**Log outreach**")
                with st.form(f"outreach_{p.encounter_id}", clear_on_submit=True):
                    action = st.selectbox("Action", ["Phone call", "Text message", "Pharmacy referral", "Home health referral", "Transportation arranged"])
                    outcome = st.selectbox("Outcome", ["Reached", "No answer", "Left voicemail", "Wrong number"])
                    booked = st.checkbox("Follow-up appointment booked")
                    notes = st.text_area("Notes", max_chars=500)
                    if st.form_submit_button("Save", type="primary"):
                        pg_exec("""INSERT INTO care.outreach_actions (encounter_id, coordinator_email, action_type, outcome, followup_booked, notes)
                                   VALUES (%s, %s, %s, %s, %s, %s)""", (p.encounter_id, user, action, outcome, booked, notes))
                        st.success("Outreach saved to Lakebase.")
                hist = pg_df("""SELECT created_at, coordinator_email, action_type, outcome, followup_booked, notes
                                FROM care.outreach_actions WHERE encounter_id = %s ORDER BY created_at DESC""", (p.encounter_id,))
                st.markdown("**Outreach history**")
                st.dataframe(hist, hide_index=True, use_container_width=True) if len(hist) else st.caption("No outreach logged yet.")

# ================================================================ EXECUTIVE VIEW
with exec_tab:
    try:
        k = sql_df(f"SELECT discharge_month, facility_id, hrrp_condition, index_stays, readmissions, outreach_contacted, outreach_reached FROM {KPI_TABLE}")
        for c in ["index_stays", "readmissions", "outreach_contacted", "outreach_reached"]:
            k[c] = pd.to_numeric(k[c])
        k["discharge_month"] = pd.to_datetime(k["discharge_month"])
        conds = ["All"] + sorted(k.hrrp_condition.unique().tolist())
        cond = st.selectbox("Condition (HRRP)", conds, index=0)
        kk = k if cond == "All" else k[k.hrrp_condition == cond]

        tot = kk[["index_stays", "readmissions", "outreach_contacted", "outreach_reached"]].sum()
        last6 = kk[kk.discharge_month >= kk.discharge_month.max() - pd.DateOffset(months=5)]
        l6 = last6[["index_stays", "readmissions"]].sum()
        e1, e2, e3, e4 = st.columns(4)
        e1.metric("30-day readmission rate (all time)", f"{tot.readmissions / tot.index_stays:.1%}")
        e2.metric("Last 6 months", f"{l6.readmissions / l6.index_stays:.1%}")
        e3.metric("Index stays", f"{int(tot.index_stays):,}")
        e4.metric("Patients reached by care mgmt", f"{tot.outreach_reached / tot.index_stays:.1%}", help="Share of index stays reached by legacy outreach")

        trend = kk.groupby(["discharge_month", "facility_id"])[["index_stays", "readmissions"]].sum().reset_index()
        trend["readmission_rate_pct"] = 100 * trend.readmissions / trend.index_stays
        c1, c2 = st.columns([3, 2])
        with c1:
            st.markdown("**Readmission rate by month and facility (%)**")
            st.line_chart(trend.pivot(index="discharge_month", columns="facility_id", values="readmission_rate_pct"))
        with c2:
            st.markdown("**Outreach coverage by facility**")
            cov = kk.groupby("facility_id")[["index_stays", "outreach_contacted", "outreach_reached"]].sum()
            st.bar_chart(pd.DataFrame({"contacted %": 100 * cov.outreach_contacted / cov.index_stays,
                                       "reached %": 100 * cov.outreach_reached / cov.index_stays}))
        st.caption("Measure-eligible index stays (AMA excluded) with a complete 30-day window. Source: Unity Catalog gold_readmission_kpis_monthly.")
    except Exception as e:
        st.error(f"Could not load KPIs from the SQL warehouse: {e}")

    st.divider()
    st.subheader("💬 Ask Genie")
    q = st.text_input("Ask a question about readmissions", placeholder="Of patients reached by care management, how many were readmitted compared with those not reached?")
    if st.button("Ask", type="primary") and q:
        with st.spinner("Genie is thinking..."):
            try:
                msg = w.genie.start_conversation_and_wait(space_id=GENIE_SPACE_ID, content=q)
                for a in msg.attachments or []:
                    if a.text and a.text.content:
                        st.markdown(a.text.content)
                    if a.query and a.query.query:
                        res = w.genie.get_message_attachment_query_result(space_id=GENIE_SPACE_ID, conversation_id=msg.conversation_id,
                                                                          message_id=msg.id, attachment_id=a.attachment_id)
                        sr = res.statement_response
                        if sr and sr.result and sr.manifest:
                            st.dataframe(pd.DataFrame(sr.result.data_array or [], columns=[c.name for c in sr.manifest.schema.columns]),
                                         hide_index=True, use_container_width=True)
                        with st.expander("SQL generated by Genie"):
                            st.code(a.query.query, language="sql")
            except Exception as e:
                st.error(f"Genie request failed: {e}")

st.markdown("<div class='footer'>All data is synthetic (no real patients). Lakeview Health is fictional. "
            "Built on Databricks: Lakeflow · Unity Catalog · AI Functions · MLflow · Lakebase · Genie · Databricks Apps.</div>",
            unsafe_allow_html=True)
