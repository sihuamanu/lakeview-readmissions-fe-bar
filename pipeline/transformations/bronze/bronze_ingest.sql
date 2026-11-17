-- BRONZE: incremental ingestion of the daily EHR extract files with Auto Loader (read_files + STREAM).
-- Raw, append-only, with lineage columns. The rescued-data column captures malformed records instead of failing.
USE SCHEMA lakeview_health;

CREATE OR REFRESH STREAMING TABLE bronze_patients
COMMENT 'Raw patient demographics from the EHR extract (contains PHI). Source: /Volumes/simo_show_case_catalog/lakeview_raw/landing/patients'
AS SELECT *, _metadata.file_path AS source_file, current_timestamp() AS ingested_at
FROM STREAM read_files('/Volumes/simo_show_case_catalog/lakeview_raw/landing/patients/', format => 'csv', header => true,
                       schemaHints => 'mrn STRING, zip STRING, dob STRING');

CREATE OR REFRESH STREAMING TABLE bronze_encounters
COMMENT 'Raw inpatient encounters (admit/discharge) from the EHR extract'
AS SELECT *, _metadata.file_path AS source_file, current_timestamp() AS ingested_at
FROM STREAM read_files('/Volumes/simo_show_case_catalog/lakeview_raw/landing/encounters/', format => 'csv', header => true,
                       schemaHints => 'admit_ts TIMESTAMP, discharge_ts TIMESTAMP, is_planned BOOLEAN, ed_visits_prior_6m INT');

CREATE OR REFRESH STREAMING TABLE bronze_diagnoses
COMMENT 'Raw ICD-10 diagnoses per encounter'
AS SELECT *, _metadata.file_path AS source_file, current_timestamp() AS ingested_at
FROM STREAM read_files('/Volumes/simo_show_case_catalog/lakeview_raw/landing/diagnoses/', format => 'csv', header => true);

CREATE OR REFRESH STREAMING TABLE bronze_medications
COMMENT 'Raw discharge medication list per encounter'
AS SELECT *, _metadata.file_path AS source_file, current_timestamp() AS ingested_at
FROM STREAM read_files('/Volumes/simo_show_case_catalog/lakeview_raw/landing/medications/', format => 'csv', header => true);

CREATE OR REFRESH STREAMING TABLE bronze_labs
COMMENT 'Raw last-before-discharge lab results (LOINC) per encounter'
AS SELECT *, _metadata.file_path AS source_file, current_timestamp() AS ingested_at
FROM STREAM read_files('/Volumes/simo_show_case_catalog/lakeview_raw/landing/labs/', format => 'csv', header => true,
                       schemaHints => 'value DOUBLE, result_ts TIMESTAMP');

CREATE OR REFRESH STREAMING TABLE bronze_followup_appointments
COMMENT 'Raw post-discharge follow-up appointments'
AS SELECT *, _metadata.file_path AS source_file, current_timestamp() AS ingested_at
FROM STREAM read_files('/Volumes/simo_show_case_catalog/lakeview_raw/landing/followup_appointments/', format => 'csv', header => true,
                       schemaHints => 'appt_ts TIMESTAMP');

CREATE OR REFRESH STREAMING TABLE bronze_care_mgmt_outreach
COMMENT 'Raw legacy care-management outreach log (LACE-driven call list)'
AS SELECT *, _metadata.file_path AS source_file, current_timestamp() AS ingested_at
FROM STREAM read_files('/Volumes/simo_show_case_catalog/lakeview_raw/landing/care_mgmt_outreach/', format => 'csv', header => true,
                       schemaHints => 'outreach_ts TIMESTAMP');

CREATE OR REFRESH STREAMING TABLE bronze_coordinators
COMMENT 'Raw care coordinator roster with facility assignment'
AS SELECT *, _metadata.file_path AS source_file, current_timestamp() AS ingested_at
FROM STREAM read_files('/Volumes/simo_show_case_catalog/lakeview_raw/landing/coordinators/', format => 'csv', header => true);

CREATE OR REFRESH STREAMING TABLE bronze_discharge_notes
COMMENT 'Raw free-text discharge summaries (JSON lines, contains PHI)'
AS SELECT *, _metadata.file_path AS source_file, current_timestamp() AS ingested_at
FROM STREAM read_files('/Volumes/simo_show_case_catalog/lakeview_raw/landing/discharge_notes/', format => 'json',
                       schemaHints => 'note_ts TIMESTAMP');
