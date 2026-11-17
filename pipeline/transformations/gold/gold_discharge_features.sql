-- GOLD: model-ready structured features per index discharge, plus the LACE baseline the customer uses today.
-- Only information available AT DISCHARGE is used (no post-discharge outreach or follow-up attendance -> no label leakage).
USE SCHEMA lakeview_health;

CREATE OR REFRESH MATERIALIZED VIEW gold_discharge_features (
  CONSTRAINT lace_in_range EXPECT (lace_score BETWEEN 0 AND 19)
)
COMMENT 'Structured discharge-time features + LACE score per index admission. Join to lakeview_ml.note_social_risk on encounter_id for GenAI social-risk features.'
AS
WITH dx AS (
  SELECT encounter_id,
         count_if(NOT is_primary)                                    AS comorbidity_count,
         max(icd10_code = 'F03.90')                                  AS has_dementia,
         max(icd10_code IN ('I50.9', 'I50.23'))                      AS has_heart_failure_dx,
         max(icd10_code IN ('N18.3'))                                AS has_ckd,
         max(icd10_code IN ('F32.9'))                                AS has_depression
  FROM silver_diagnoses GROUP BY encounter_id
),
meds AS (
  SELECT encounter_id, count(*) AS num_discharge_meds,
         max(med_name LIKE 'insulin%')                               AS on_insulin,
         max(med_name IN ('warfarin', 'apixaban'))                   AS on_anticoagulant,
         max(med_name IN ('oxycodone'))                              AS on_opioid
  FROM silver_medications GROUP BY encounter_id
),
labs AS (
  SELECT encounter_id,
         max(CASE WHEN lab_name = 'Sodium'     THEN lab_value END) AS sodium,
         max(CASE WHEN lab_name = 'Hemoglobin' THEN lab_value END) AS hemoglobin,
         max(CASE WHEN lab_name = 'Creatinine' THEN lab_value END) AS creatinine,
         max(CASE WHEN lab_name = 'BNP'        THEN lab_value END) AS bnp,
         count_if(is_abnormal)                                       AS abnormal_lab_count
  FROM silver_labs GROUP BY encounter_id
),
fu AS (
  SELECT source_encounter_id AS encounter_id, true AS followup_scheduled_7d, min(provider_type) AS followup_provider_type
  FROM silver_followup_appointments GROUP BY source_encounter_id
),
prior AS (
  SELECT i.encounter_id, count(r.encounter_id) AS prior_admissions_12m
  FROM silver_encounters i
  LEFT JOIN silver_encounters r
    ON r.patient_id = i.patient_id AND r.discharge_ts < i.admit_ts AND r.admit_ts >= i.admit_ts - INTERVAL 365 DAYS
  GROUP BY i.encounter_id
)
SELECT
  a.encounter_id, a.patient_id, a.facility_id, a.discharge_ts, a.discharge_date, a.primary_condition, a.hrrp_condition,
  a.admission_type, a.discharge_disposition, a.age_at_admit, a.sex, a.payer, a.primary_language,
  a.los_days, a.ed_visits_prior_6m, coalesce(p.prior_admissions_12m, 0) AS prior_admissions_12m,
  coalesce(dx.comorbidity_count, 0) AS comorbidity_count, coalesce(dx.has_dementia, false) AS has_dementia,
  coalesce(dx.has_heart_failure_dx, false) AS has_heart_failure_dx, coalesce(dx.has_ckd, false) AS has_ckd,
  coalesce(dx.has_depression, false) AS has_depression,
  coalesce(m.num_discharge_meds, 0) AS num_discharge_meds, coalesce(m.on_insulin, false) AS on_insulin,
  coalesce(m.on_anticoagulant, false) AS on_anticoagulant, coalesce(m.on_opioid, false) AS on_opioid,
  l.sodium, l.hemoglobin, l.creatinine, l.bnp, coalesce(l.abnormal_lab_count, 0) AS abnormal_lab_count,
  coalesce(fu.followup_scheduled_7d, false) AS followup_scheduled_7d, fu.followup_provider_type,
  -- LACE index (van Walraven 2010): L = length of stay, A = acuity, C = comorbidity (Charlson proxy), E = ED visits in 6 months
  (CASE WHEN a.los_days < 1 THEN 0 WHEN a.los_days = 1 THEN 1 WHEN a.los_days = 2 THEN 2 WHEN a.los_days = 3 THEN 3
        WHEN a.los_days <= 6 THEN 4 WHEN a.los_days <= 13 THEN 5 ELSE 7 END)
  + (CASE WHEN a.admission_type IN ('Emergency', 'Urgent') THEN 3 ELSE 0 END)
  + (CASE WHEN coalesce(dx.comorbidity_count, 0) >= 4 THEN 5 ELSE coalesce(dx.comorbidity_count, 0) END)
  + least(a.ed_visits_prior_6m, 4) AS lace_score,
  a.is_measure_eligible, a.label_window_complete, a.readmitted_30d
FROM gold_index_admissions a
LEFT JOIN dx    ON dx.encounter_id = a.encounter_id
LEFT JOIN meds m ON m.encounter_id = a.encounter_id
LEFT JOIN labs l ON l.encounter_id = a.encounter_id
LEFT JOIN fu    ON fu.encounter_id = a.encounter_id
LEFT JOIN prior p ON p.encounter_id = a.encounter_id;
