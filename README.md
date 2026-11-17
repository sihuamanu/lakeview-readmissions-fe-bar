# Lakeview Health: Reducing 30-Day Readmissions with a Risk-Ranked Transitions-of-Care Worklist

> FE Bar build | Industry: Healthcare (provider) | Data: 100% synthetic (no real PHI)

**Repo layout:** `notebooks/` (00-05, run in order) | `pipeline/transformations/` (Lakeflow SDP SQL: bronze, silver, gold) | `app/` (Databricks App) | `deck/` (presentation) | `docs/` (use-case design). The key execution results are written out as text in section 3 below. *Notebook cell outputs are not included in this commit yet.*

## 1. Business outcome

**Customer (fictional):** Lakeview Health, a 3-hospital regional system (LVH-NORTH, LVH-CENTRAL, LVH-SOUTH).

**Problem:** The 30-day readmission rate is **15.5%** (measured in this build), above the benchmark, and it drives CMS HRRP penalties. Care coordinators can call only a fraction of discharged patients. Today they build the call list by hand from a LACE spreadsheet, which **cannot see the social risk factors buried in free-text discharge notes**.

**Solution:** Every morning the system produces a ranked worklist of patients still inside their 30-day window. Risk combines structured EHR data with **GenAI-extracted social risk**. Each patient shows their **top 3 risk drivers** and a **GenAI call brief**. Coordinators log outcomes in an app backed by Lakebase, and every call is measured.

**Buyers and KPIs**
* CMO / VP Quality: readmission rate, HRRP penalty exposure
* Director of Care Management: high-risk patients reached, 7-day follow-up rate, coordinator hours
* Director of Data & Analytics: PHI governance, EHR integration, model trust

**Measured results (held-out period May to Oct 2026: 3,093 discharges, 501 readmissions)**

| Approach | AUC | PR-AUC | Readmissions captured in top 20% |
| --- | --- | --- | --- |
| LACE (today) | 0.686 | 0.321 | 40.7% |
| GBT on structured EHR | 0.700 | 0.341 | 40.5% |
| **GBT + GenAI social risk** | **0.732** | **0.370** | **42.7%** |

Most of the lift comes from the GenAI features. Structured data alone does not beat LACE in the top 20%.

**Value hypothesis (scaled to 40,000 discharges/yr; estimates, assumptions below)**

| Lever | Logic | Avoided readmissions/yr |
| --- | --- | --- |
| Better targeting | +2.0 pts of readmissions on the same-size list -> ~124 more at-risk patients listed; 64% reach rate; 24% relative risk reduction when reached | ~19 |
| More patients reached | Worklist + briefs cut call prep, so the reached share of discharges rises from 12% today to 18%; reaching a LACE >= 10 patient lowers readmission 23.2% -> 17.6% (observed in program data) | ~134 |
| **Total** | Readmission rate 15.5% -> ~15.1% | **~150 (~$2.3M at $15k each, ~700 bed-days)** |

Upside: reaching 25% of discharges gives ~300 avoided readmissions (~$4.6M). Coordinator time saved on manual list building is about 3,700 hours/yr (12 coordinators x 1.25 h/day). **Caveat:** the reach effect is observational and comes from synthetic data. The pilot should measure it with a stepped rollout across facilities.

## 2. Architecture: one connected flow

```
Synthetic EHR extract (CSV/JSON)  ->  UC Volume  /Volumes/simo_show_case_catalog/lakeview_raw/landing
  -> [Lakeflow SDP] bronze (Auto Loader) -> silver (typed, de-duplicated, expectations) -> gold (index admissions, features, KPIs)
  -> [GenAI] ai_extract on discharge notes -> lakeview_ml.note_social_risk
  -> [ML] GBT vs LACE (MLflow) -> UC model lakeview_ml.readmission_risk@champion
  -> [Scoring] patient_risk_scores + worklist with top drivers + ai_query briefs
  -> [UC governance] PHI tags, facility row filter, PHI column masks (coordinator_worklist)
  -> [Lakebase] synced worklist + entitlements (Postgres) + care.outreach_actions (app writes)
  -> [Genie Agent] natural-language KPIs over gold + scores + worklist
  -> [Databricks App] coordinator worklist and executive view
```

| Layer | Asset |
| --- | --- |
| Data generation | `00_generate_synthetic_ehr` |
| Lakeflow pipeline | `lakeview_readmissions_pipeline` (SQL: `transformations/bronze, silver, gold`) |
| GenAI features | `01_genai_social_risk_extraction` |
| Model | `02_train_readmission_model`, MLflow experiment `lakeview_readmission_experiment`, UC model `simo_show_case_catalog.lakeview_ml.readmission_risk` v1 `@champion` |
| Scoring and briefs | `03_score_worklist_and_briefs` |
| Governance | `04_unity_catalog_governance` |
| Lakebase | `05_lakebase_serving`, project `lakeview-health` |
| Genie | Genie Agent "Lakeview Health Readmissions" |
| App | `app/` (Databricks App) |

## 3. Execution evidence (from committed notebook outputs)

* **Data:** 8,000 patients, 13,200 encounters, 42,783 diagnoses, 90,222 medications, 52,800 labs, 13,200 notes. Counts were re-read with `read_files` and match the generator.
* **Pipeline:** the dry run and update succeeded. `gold_index_admissions` has 12,989 live discharges; 12,480 are measure-eligible with a complete window. The readmission rate is 15.5%, the same in both `gold_index_admissions` and `gold_readmission_kpis_monthly`. LACE >= 10 patients: 22.4% rate vs 10.2% for LACE < 10.
* **GenAI extraction:** 13,200 notes, 0 errors. Patients who live alone: 25.2% readmission rate vs 13.1%. No transportation: 25.1% vs 14.4%.
* **Model:** see the table above. Passed the isolated serving check (`mlflow.models.predict(..., env_manager="uv")`) and is registered in UC.
* **Worklist:** 254 patients (71 High, 60 Medium, 123 Low), 0 missing briefs. Average LACE by tier is 13.0 / 10.5 / 8.1.
* **Governance test:** a LVH-NORTH user without PHI rights sees 90 rows with `***` names and MRNs and DOB reduced to Jan 1 of the birth year. A care-team lead sees all 254 rows (96 + 90 + 68) in clear.
* **Lakebase:** `worklist_app_feed_synced` has 254 rows in Postgres, equal to the UC source. Per-facility counts match.
* **Genie test:** "reached vs not reached" returned 1,524 + 10,956 = 12,480 stays (equal to the pipeline count), with the HRRP filters applied automatically.

## 4. Decisions and trade-offs

| Decision | Why | Alternative considered |
| --- | --- | --- |
| SQL declarative pipeline, MVs with `QUALIFY` de-duplication in silver | Idempotent re-extracts; expectations give data quality metrics | Streaming silver with Auto CDC: more complex than this daily batch extract needs |
| GenAI **extracts features**; a GBT model **predicts** | Auditable, measurable lift (ablation), explainable drivers | An LLM judging risk directly: not measurable or explainable |
| Prompt iterated against a rule baseline | v1 confused "independent with ADLs" with living alone (988 false positives) and missed opioid use disorder history (260). v2 reaches 99.4% / 99.98% agreement | No validation: silent label noise |
| Temporal split, discharge-time features only | Mirrors production; no leakage from outreach or follow-up attendance | Random split: optimistic |
| Recall in the top 20% as the business metric | Matches coordinator capacity | AUC alone does not reflect how the list is used |
| Class-weighted model -> show **tiers and percentiles**, not probabilities | Probabilities are uncalibrated (Brier 0.21) | Isotonic calibration (next step) |
| Payer and language excluded as inputs, used for the fairness check | Avoid proxy bias. Commercial and Medicaid patients are flagged less often (lower base rates); monitored | Including them as features |
| Occlusion attribution for drivers | Model-agnostic, no extra dependencies, plain-language driver names | SHAP (adds a dependency; similar result) |
| Two worklist tables: governed `coordinator_worklist` + restricted `worklist_app_feed` | UC does not allow row filters or column masks on a synced-table source (error reproduced in notebook 05) | A single table: either no RLS for analysts or no Lakebase sync |
| Lakebase for the app | Many concurrent per-patient reads plus transactional outreach writes | Querying a SQL warehouse directly: higher latency, no OLTP writes |
| Daily batch scoring | Coordinators work from a morning list | Real-time scoring at discharge through Model Serving (roadmap) |

**Known limitations:** `01` currently re-extracts every note (fine for a demo; production should extract only new notes). The reach effect is observational. The data is synthetic, so the absolute AUC is not a clinical claim.

## 5. How AI was used (AI as a teammate)

* Genie Code (Databricks AI assistant) scaffolded the generator, the pipeline SQL, the notebooks and the app. **[Author: before submitting, describe here in your own words which decisions you made, changed or rejected. The FE Bar attestation requires the work, decisions and narrative to be yours.]**
* **AI Functions in the product:** `ai_extract` (social risk, schema v2.1 with typed booleans) and `ai_query` with `databricks-claude-haiku-4-5` (coordinator briefs, constrained to the given facts and 60 words).
* **Evidence-driven prompt iteration:** see the prompt iteration log in notebook 01 (v1 -> v2 with measured agreement).
* Every AI-produced number was cross-checked with a second method (re-reading files, KPI table vs gold, Lakebase vs UC counts, Genie totals vs pipeline counts).

## 6. How to run

1. `00_generate_synthetic_ehr` (lands files)
2. Run the pipeline `lakeview_readmissions_pipeline`
3. `01` -> `02` (train and register; only on retrain) -> `03` (daily scoring)
4. `04` (once: governance) and `05` (once: Lakebase sync; afterwards trigger the sync after `03`)
5. Deploy `app/`
