-- GOLD: index admissions with the 30-day readmission outcome (HRRP-style definition).
--   * Index stay  = inpatient discharge alive. is_measure_eligible additionally excludes AMA discharges (as CMS does).
--   * Readmission = next UNPLANNED inpatient admission for the same patient within 30 days of discharge (planned staged procedures excluded).
--   * Outcome is only known when the full 30-day window has elapsed before the extract date (label_window_complete).
USE SCHEMA lakeview_health;

CREATE OR REFRESH MATERIALIZED VIEW gold_index_admissions (
  CONSTRAINT label_present_when_window_complete EXPECT (NOT label_window_complete OR readmitted_30d IS NOT NULL),
  CONSTRAINT patient_found EXPECT (age_at_admit IS NOT NULL)
)
COMMENT 'One row per live inpatient discharge (index stay) with the 30-day unplanned readmission outcome and legacy outreach status. Use is_measure_eligible = true AND label_window_complete = true when computing the readmission rate.'
AS
WITH extract_date AS (
  SELECT max(discharge_ts) AS extract_ts FROM silver_encounters
),
next_unplanned AS (
  SELECT i.encounter_id,
         min_by(r.encounter_id, r.admit_ts) AS readmit_encounter_id,
         min(r.admit_ts)                    AS readmit_ts
  FROM silver_encounters i
  JOIN silver_encounters r
    ON r.patient_id = i.patient_id
   AND r.admit_ts > i.discharge_ts
   AND r.admit_ts <= i.discharge_ts + INTERVAL 30 DAYS
   AND NOT r.is_planned
  GROUP BY i.encounter_id
),
outreach AS (
  SELECT encounter_id, max(outcome = 'Reached') AS reached, min(outreach_ts) AS first_outreach_ts
  FROM silver_care_mgmt_outreach GROUP BY encounter_id
)
SELECT
  e.encounter_id, e.patient_id, e.facility_id, e.admit_ts, e.discharge_ts, e.discharge_date,
  CAST(date_trunc('MONTH', e.discharge_date) AS DATE) AS discharge_month,
  e.primary_condition, e.primary_icd10,
  CASE e.primary_condition
    WHEN 'Heart failure' THEN 'HF' WHEN 'COPD exacerbation' THEN 'COPD' WHEN 'Pneumonia' THEN 'Pneumonia'
    WHEN 'Acute MI' THEN 'AMI' WHEN 'Hip/knee replacement' THEN 'THA/TKA' ELSE 'Non-HRRP' END AS hrrp_condition,
  e.admission_type, e.is_planned, e.discharge_disposition, e.los_days, e.ed_visits_prior_6m,
  CAST(floor(datediff(e.admit_ts, p.dob) / 365.25) AS INT) AS age_at_admit,
  p.sex, p.payer, p.primary_language,
  e.discharge_disposition <> 'Left against medical advice' AS is_measure_eligible,
  x.extract_ts >= e.discharge_ts + INTERVAL 30 DAYS AS label_window_complete,
  CASE WHEN x.extract_ts >= e.discharge_ts + INTERVAL 30 DAYS THEN n.readmit_encounter_id IS NOT NULL END AS readmitted_30d,
  n.readmit_encounter_id,
  datediff(n.readmit_ts, e.discharge_ts) AS days_to_readmit,
  o.encounter_id IS NOT NULL AS legacy_outreach_contacted,
  coalesce(o.reached, false) AS legacy_outreach_reached,
  round((unix_timestamp(o.first_outreach_ts) - unix_timestamp(e.discharge_ts)) / 3600, 1) AS hours_to_first_outreach
FROM silver_encounters e
JOIN silver_patients p ON p.patient_id = e.patient_id
CROSS JOIN extract_date x
LEFT JOIN next_unplanned n ON n.encounter_id = e.encounter_id
LEFT JOIN outreach o ON o.encounter_id = e.encounter_id
WHERE e.discharge_disposition <> 'Expired';
