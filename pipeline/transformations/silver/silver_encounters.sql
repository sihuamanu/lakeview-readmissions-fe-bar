-- SILVER: typed inpatient encounters with data quality rules. Bad timestamps are dropped; unknown facility / malformed ICD-10 are flagged (warn).
USE SCHEMA lakeview_health;

CREATE OR REFRESH MATERIALIZED VIEW silver_encounters (
  CONSTRAINT valid_encounter_id    EXPECT (encounter_id IS NOT NULL AND patient_id IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT discharge_after_admit EXPECT (discharge_ts >= admit_ts) ON VIOLATION DROP ROW,
  CONSTRAINT known_facility        EXPECT (facility_id IN ('LVH-NORTH', 'LVH-CENTRAL', 'LVH-SOUTH')),
  CONSTRAINT valid_icd10_format    EXPECT (primary_icd10 RLIKE '^[A-Z][0-9]{2}[.]?[0-9A-Z]{0,4}$'),
  CONSTRAINT plausible_los         EXPECT (los_days BETWEEN 0 AND 120)
)
COMMENT 'Inpatient encounters, one row per encounter_id. los_days = calendar days between admit and discharge.'
AS SELECT
  encounter_id, patient_id, facility_id, encounter_type, admission_type,
  CAST(is_planned AS BOOLEAN)        AS is_planned,
  CAST(admit_ts AS TIMESTAMP)        AS admit_ts,
  CAST(discharge_ts AS TIMESTAMP)    AS discharge_ts,
  CAST(discharge_ts AS DATE)         AS discharge_date,
  datediff(CAST(discharge_ts AS DATE), CAST(admit_ts AS DATE)) AS los_days,
  primary_condition, primary_icd10, discharge_disposition,
  CAST(ed_visits_prior_6m AS INT)    AS ed_visits_prior_6m,
  ingested_at
FROM bronze_encounters
QUALIFY row_number() OVER (PARTITION BY encounter_id ORDER BY ingested_at DESC) = 1;
