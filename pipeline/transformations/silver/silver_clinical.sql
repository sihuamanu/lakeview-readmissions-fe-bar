-- SILVER: clinical detail per encounter (diagnoses, discharge medications, labs with abnormal flags).
USE SCHEMA lakeview_health;

CREATE OR REFRESH MATERIALIZED VIEW silver_diagnoses (
  CONSTRAINT valid_keys         EXPECT (encounter_id IS NOT NULL AND icd10_code IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT valid_icd10_format EXPECT (icd10_code RLIKE '^[A-Z][0-9]{2}[.]?[0-9A-Z]{0,4}$')
)
COMMENT 'ICD-10 diagnoses per encounter; is_primary marks the principal diagnosis, others are comorbidities.'
AS SELECT encounter_id, CAST(seq AS INT) AS seq, icd10_code, description, CAST(is_primary AS BOOLEAN) AS is_primary
FROM bronze_diagnoses
QUALIFY row_number() OVER (PARTITION BY encounter_id, seq ORDER BY ingested_at DESC) = 1;

CREATE OR REFRESH MATERIALIZED VIEW silver_medications (
  CONSTRAINT valid_keys EXPECT (encounter_id IS NOT NULL AND med_name IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Medications prescribed at discharge, one row per encounter and medication.'
AS SELECT DISTINCT encounter_id, lower(trim(med_name)) AS med_name
FROM bronze_medications;

CREATE OR REFRESH MATERIALIZED VIEW silver_labs (
  CONSTRAINT valid_keys     EXPECT (encounter_id IS NOT NULL AND loinc_code IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT physiologic    EXPECT (lab_value > 0 AND lab_value < 100000)
)
COMMENT 'Last lab result before discharge. is_abnormal uses readmission-relevant thresholds: sodium < 133, hemoglobin < 10, creatinine > 1.6, BNP > 800.'
AS SELECT
  encounter_id, loinc_code, lab_name, CAST(value AS DOUBLE) AS lab_value, unit, CAST(result_ts AS TIMESTAMP) AS result_ts,
  CASE lab_name WHEN 'Sodium' THEN value < 133 WHEN 'Hemoglobin' THEN value < 10
                WHEN 'Creatinine' THEN value > 1.6 WHEN 'BNP' THEN value > 800 END AS is_abnormal
FROM bronze_labs
QUALIFY row_number() OVER (PARTITION BY encounter_id, loinc_code ORDER BY result_ts DESC, ingested_at DESC) = 1;
