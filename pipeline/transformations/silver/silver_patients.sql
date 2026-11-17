-- SILVER: conformed, typed, de-duplicated patients (latest record per patient wins, so re-extracts are idempotent).
USE SCHEMA lakeview_health;

CREATE OR REFRESH MATERIALIZED VIEW silver_patients (
  CONSTRAINT valid_patient_id EXPECT (patient_id IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT valid_dob        EXPECT (dob IS NOT NULL AND dob BETWEEN DATE'1900-01-01' AND DATE'2026-11-04'),
  CONSTRAINT valid_sex        EXPECT (sex IN ('F', 'M')),
  CONSTRAINT known_facility   EXPECT (home_facility_id IN ('LVH-NORTH', 'LVH-CENTRAL', 'LVH-SOUTH'))
)
COMMENT 'Patient master: one row per patient. PHI columns: mrn, first_name, last_name, dob, zip.'
AS SELECT
  patient_id, mrn, first_name, last_name, CAST(dob AS DATE) AS dob, sex, zip, payer, primary_language, home_facility_id,
  ingested_at
FROM bronze_patients
QUALIFY row_number() OVER (PARTITION BY patient_id ORDER BY ingested_at DESC) = 1;
