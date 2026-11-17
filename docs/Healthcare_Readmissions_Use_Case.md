# FE Bar Use Case: Reducing 30-Day Readmissions at a Regional Health System

## 1. Business outcome (lead with this)

**Customer (fictional):** Lakeview Health, a 3-hospital regional health system with about 40,000 inpatient discharges a year, 45% of them Medicare.

**Problem:** Lakeview's 30-day all-cause readmission rate is **16.2%**, above the national benchmark of about 14.5%. That puts it under CMS Hospital Readmissions Reduction Program (HRRP) penalties for heart failure, pneumonia, COPD and AMI. Care coordinators can only call about 20% of discharged patients. Today they choose who to call with a manual LACE score in a spreadsheet, with no visibility into social risk factors that sit in free-text discharge notes.

**Buyers**
* Executive sponsor: **Chief Medical Officer / VP Quality**. KPIs: readmission rate, HRRP penalty dollars, star ratings.
* Domain owner: **Director of Care Management**. KPIs: coordinator productivity, follow-up visits within 7 days, outreach completion rate.
* Technical stakeholder: **Director of Data and Analytics**. Concerns: PHI governance, EHR integration, model trust, cost.

**Solution in one sentence:** A daily risk-ranked transitions-of-care worklist. It combines structured EHR data with GenAI-extracted social risk from discharge notes, so coordinators call the patients most likely to be readmitted. Every action is written back and measured.

**Value hypothesis (estimates; state assumptions in the deck)**

| Lever | Assumption | Annual value |
| --- | --- | --- |
| HRRP penalty reduction | Medicare base DRG payments of about $300M; penalty reduced from 1.2% to 0.4% | about $2.4M |
| Avoided readmissions (value-based and ACO contracts) | Rate drops 16.2% to 14.2% on 40k discharges = 800 avoided; about $15k each; 30% of revenue at risk | about $3.6M |
| Capacity freed | 800 avoided x 5-day stay = 4,000 bed-days reused for elective cases | about $2M contribution margin |
| Coordinator productivity | Building the call list goes from 1.5 hours/day to 10 minutes for 12 coordinators | about 4,500 hours/year |
| **Total** | | **about $8M a year; target payback within 6 months** |

---

## 2. Architecture: one connected data flow

```
Synthetic EHR files (Synthea / generated) in a UC Volume
   -> [Lakeflow SDP] bronze -> silver -> gold (expectations, Auto Loader)
   -> [Unity Catalog] governed catalog: PHI tags, column masks, row filters by facility, lineage
   -> [ML + GenAI] ai_extract social risk from notes -> features -> readmission model (MLflow, UC registry)
         -> daily batch scoring job -> gold.patient_risk_scores
   -> [Lakebase] synced table (worklist) + native table (outreach_actions, written by the app)
   -> [Genie Agent] natural-language questions over gold + scores + outreach results
   -> [Databricks App] Coordinator worklist + Executive view (with Genie embedded)
   -> outreach_actions flow back into UC -> measure intervention impact -> retrain
```

Naming: catalog `lakeview_health`, schemas `raw`, `curated`, `ml`, `serving`. Use the same names everywhere so the evaluator can follow the data from start to finish.

---

## 3. Data (synthetic or public, no real PHI)

**Source options**
* **Synthea** (public synthetic patient generator): CSV export of patients, encounters, conditions, medications, observations and procedures.
* Or generate with Python or `dbldatagen`. A notebook in the repo should generate it so it can be reproduced.
* Optional public benchmark: CMS HRRP hospital-level data, used to compare Lakeview with peers on the executive view.

**Raw entities (landed as files in `/Volumes/lakeview_health/raw/landing/`)**

| Entity | Key fields |
| --- | --- |
| patients | patient_id, mrn, name, dob, sex, zip, payer, primary_language |
| encounters | encounter_id, patient_id, facility_id, admit_ts, discharge_ts, encounter_type, drg, discharge_disposition |
| diagnoses | encounter_id, icd10_code, is_primary |
| medications | encounter_id, rxnorm_code, med_name, start_dt, end_dt |
| labs | encounter_id, loinc_code, value, unit, result_ts |
| discharge_notes | encounter_id, note_text (generated free text containing social signals) |
| followup_appointments | patient_id, appt_ts, provider_type, status |

Tip: in the generated note text, put signals like "lives alone," "no transportation to pharmacy" and "unable to afford insulin" in a share of notes, and link them to a higher chance of readmission. That way the GenAI features measurably improve the model.

---

## 4. Layer by layer

### 4.1 Lakeflow: ingest and transform
* A **Lakeflow Spark Declarative Pipeline** reads files from the volume with **Auto Loader**, which supports incremental arrival of new daily extracts.
* **Bronze:** raw records plus ingest metadata.
* **Silver:** typed, deduplicated and conformed records. Expectations: `patient_id IS NOT NULL`, `discharge_ts >= admit_ts`, valid ICD-10 format (drop or quarantine failures).
* **Gold:**
  * `gold.index_admissions`: eligible inpatient index stays, HRRP-style. Exclude planned readmissions, transfers and deaths.
  * `gold.readmission_labels`: `readmitted_30d` flag, using an unplanned inpatient admission within 30 days of discharge.
  * `gold.discharge_features`: length of stay, acuity, comorbidity count (Charlson), ED visits in the past 6 months, number of medications, abnormal labs, LACE score (baseline), and social risk features (from 4.3).
* Narrative point: in production, the same pipeline would take HL7/FHIR feeds from Epic or Cerner, through a partner connector or FHIR bulk export landing in cloud storage.

### 4.2 Unity Catalog: govern PHI
* Governed **tags**: `phi=true` on name, dob, mrn, zip and note_text; `domain=clinical`.
* **Column masks:** analysts see a masked name, dob reduced to birth year, and a hashed MRN. The `care_coordinators` group sees the clear values.
* **Row filter:** coordinators see only their own facility (`facility_id`, mapped to a group).
* Table and column **comments** on every gold table. The Genie Agent uses them.
* Show **lineage** from the raw volume to the app's tables, and mention audit logs (system tables) for HIPAA access review.
* The model is registered in UC (`lakeview_health.ml.readmission_risk`), so it is governed like data.

### 4.3 ML and GenAI: make it intelligent
**GenAI feature extraction (batch, in SQL):**
* Run `ai_extract` on `discharge_notes.note_text` to produce structured social risk fields: `lives_alone`, `transportation_barrier`, `medication_cost_barrier`, `caregiver_available`, `health_literacy_concern` and `substance_use`.
* Write the results to `curated.note_social_risk` and join them into `gold.discharge_features`.

**Predictive model:**
* LightGBM or XGBoost classifier on `discharge_features` that predicts `readmitted_30d`. Tracked in **MLflow**.
* Compare against the **LACE baseline** (typically AUC about 0.68). Target AUC above 0.75. Report the improvement in recall among the top 20% of patients by risk, which matters more than AUC because coordinators can only reach about 20% of patients.
* Show an ablation: the model with and without the GenAI social features. This is the clearest proof that the AI adds value.
* Calculate SHAP values to get the top 3 risk drivers for each patient. These drive explainability in the app.
* Register in UC with a `@champion` alias.

**Scoring:** a Lakeflow Job runs every day after the pipeline. It scores new discharges into `ml.patient_risk_scores` (risk_score, risk_tier, top_drivers). Then `ai_query` generates a short **coordinator brief** for high-risk patients, for example: "72-year-old with HF, 3rd admission in 6 months, lives alone, cost barrier to meds. Prioritize med reconciliation and a 7-day cardiology follow-up."

### 4.4 Lakebase: operational serving
* A **synced table** from `serving.coordinator_worklist` (Delta) to Lakebase Postgres gives the app fast reads per patient and per facility.
* A **native Postgres table** `outreach_actions` (action_id, encounter_id, coordinator_id, action_type, outcome, follow-up booked, timestamp) is written by the app. Its transactional writes are the reason Lakebase is a better fit than a warehouse.
* Register the Lakebase database in UC, so `outreach_actions` can be queried from the lakehouse. Use it for measurement and as a training signal, which closes the loop.

### 4.5 Genie Agent: ask in plain language
* Tables: `gold.index_admissions`, `gold.readmission_labels`, `ml.patient_risk_scores` and the outreach actions.
* Instructions: define the readmission rate the HRRP way (index stays only), with trusted SQL for the rate and for penalty exposure.
* Sample questions:
  * "What was our 30-day readmission rate for heart failure last quarter by facility?"
  * "Of high-risk patients we reached within 48 hours, how many were readmitted, compared with those we didn't reach?"
  * "Which social risk factors are most common among readmitted COPD patients?"
  * "How many high-risk discharges from yesterday still have no outreach?"

### 4.6 Databricks App: show it to the business
* **Coordinator view:** today's worklist sorted by risk and filtered to their facility (row filter). Opening a patient shows the risk score, top drivers, GenAI brief and discharge medications. One click logs the outreach outcome to Lakebase.
* **Executive view:** readmission rate trend against the benchmark, estimated penalty avoided, outreach coverage among high-risk patients, and readmissions for reached versus not-reached patients. Includes an embedded **Genie** chat (Genie Conversation API) or an embedded AI/BI dashboard.
* The app runs with a service principal plus user authorization, so UC masks and filters apply to each user. Mention this in the demo.

---

## 5. Decisions and trade-offs (include in README)

| Decision | Why | Alternative considered |
| --- | --- | --- |
| Batch daily scoring instead of a real-time endpoint | Discharges are processed daily and coordinators work from a morning list, so it's cheaper and simpler | Model Serving endpoint, for scoring at discharge in the future |
| GenAI extraction into structured features, not an LLM making the prediction | Auditable, measurable lift, explainable to clinicians | End-to-end LLM risk judgment: hard to validate or explain |
| Gradient-boosted trees instead of deep learning | Tabular data, explained with SHAP, strong results with limited data | Neural networks or AutoML (mention AutoML for a quick baseline) |
| Lakebase for the worklist and write-back | Low-latency reads and transactional writes from many coordinators | Querying a SQL warehouse directly: higher latency, no OLTP writes |
| Optimize recall in the top 20% instead of AUC alone | Matches coordinator capacity, which is the real constraint | Threshold at 0.5: doesn't match operations |
| LACE as the baseline | It's what the customer uses today, so the comparison is credible | No baseline: no story about improvement |

Risks to acknowledge: label leakage (use only features available at discharge), fairness across payer, race and language groups (show a breakdown by subgroup), and intervention bias in later retraining.

---

## 6. AI-as-teammate log (Build + AI Mindset)
Document the following in the repo:
* Which AI assistants you used and for what (data generator, pipeline scaffolding, test SQL, app UI).
* 3–5 important prompts and what you changed by hand afterward.
* The `ai_extract` schema and the prompt-design choices for extracting social risk.
* The conversation ID, which is optional on the form.

---

## 7. Repo layout (submit with outputs visible)

```
README.md                      # outcome first, then architecture, trade-offs, AI log
deck/Lakeview_Readmissions.pdf
00_generate_synthetic_data.ipynb   (outputs committed)
01_pipeline/                   # SDP source (bronze/silver/gold + expectations)
02_governance.sql              # tags, masks, row filters, comments
03_genai_social_risk.ipynb     # ai_extract + sample outputs
04_train_readmission_model.ipynb   # MLflow run, LACE comparison, ablation, SHAP
05_batch_scoring_job.ipynb     # scoring + ai_query briefs
06_lakebase_setup.ipynb        # synced table + outreach_actions DDL
07_genie_space.md              # instructions, sample Qs, trusted SQL, example answers
app/                           # Databricks App source + app.yaml
evidence/                      # text logs: pipeline event summary, job run output, query results
```

The evaluator reads only text. Commit notebook outputs, pipeline and job run logs, and copied Genie answers as text. Screenshots alone don't count.

---

## 8. Deck outline (8–10 slides)
1. Lakeview's problem: a 16.2% readmission rate, HRRP penalties and coordinators who can't reach everyone.
2. The cost: about $8M a year at stake, broken down by lever.
3. The solution in one sentence, plus a day in the life of a coordinator.
4. Results: the model against LACE, the lift from GenAI features and recall in the top 20%.
5. Demo flow.
6. Value and KPIs: readmission rate, penalty dollars, 7-day follow-up rate, coordinator hours.
7. Architecture: one diagram showing the connected flow.
8. Governance and trust: PHI masks, row filters, lineage, explainability and fairness checks.
9. Path to production: EHR (FHIR) integration, real-time scoring at discharge, a 90-day pilot at one facility.
10. Ask and next steps: a pilot with success criteria.

---

## 9. Roleplay script (tell-show-tell)
* **Set up (1 minute):** "Lakeview discharges 110 patients a day. Your team can call 22. Today it picks them with a spreadsheet. I'll show how you pick the right 22 and prove it worked."
* **Tell:** "You'll see the coordinator's morning, then the CMO's view of impact."
* **Show:** worklist, then a patient's drivers and brief, then logging the outreach, then the executive view, then asking Genie about reached versus not-reached readmissions.
* **Tell:** "Reaching the right patients cuts readmissions by about 2 points, which is about $8M a year. The pilot pays back within 6 months."

**Objection prep**

| From | Likely objection | Answer outline |
| --- | --- | --- |
| CMO | "Can clinicians trust a black box?" | SHAP drivers for each patient, the LACE comparison, clinician review of the brief, decision support only |
| CMO | "What does it cost and when do we see value?" | Serverless pay-per-use, a 90-day pilot at one facility, measured on reached versus not-reached patients |
| CMO | "Is the model biased?" | Subgroup performance breakdown and monitoring on the roadmap |
| Data lead | "How does this connect to Epic?" | FHIR bulk export or partner connector into the same Lakeflow pipeline; worklist write-back through an API later |
| Data lead | "How is PHI protected?" | UC tags, masks, row filters, audit logs, a BAA-eligible platform, no PHI sent outside the workspace (Foundation Models hosted in Databricks) |
| Data lead | "Data quality from source systems?" | Expectations, quarantined records, pipeline event logs |
| Data lead | "Why Lakebase rather than our existing OLTP database?" | One governed platform, synced tables with no custom ETL, write-backs available to the lakehouse right away |

---

## 10. Build plan (about 6–8 hours)

| Step | Time |
| --- | --- |
| Generate synthetic data + land it in a volume | 1 hour |
| SDP pipeline bronze/silver/gold | 1.5 hours |
| UC governance | 0.5 hours |
| ai_extract features + model training + scoring job | 2 hours |
| Lakebase synced table + outreach table | 0.5 hours |
| Genie Agent | 0.5 hours |
| App (2 views) | 1.5 hours |
| README, evidence, deck | 1 hour |
