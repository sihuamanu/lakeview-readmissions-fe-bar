-- SILVER: care-coordination data (follow-up appointments, legacy outreach log, coordinator roster).
USE SCHEMA lakeview_health;

CREATE OR REFRESH MATERIALIZED VIEW silver_followup_appointments (
  CONSTRAINT valid_keys   EXPECT (appointment_id IS NOT NULL AND source_encounter_id IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT valid_status EXPECT (status IN ('Scheduled', 'Completed', 'No-show'))
)
COMMENT 'Post-discharge follow-up appointments linked to the discharging encounter.'
AS SELECT appointment_id, patient_id, source_encounter_id, CAST(appt_ts AS TIMESTAMP) AS appt_ts, provider_type, status
FROM bronze_followup_appointments
QUALIFY row_number() OVER (PARTITION BY appointment_id ORDER BY ingested_at DESC) = 1;

CREATE OR REFRESH MATERIALIZED VIEW silver_care_mgmt_outreach (
  CONSTRAINT valid_keys EXPECT (outreach_id IS NOT NULL AND encounter_id IS NOT NULL) ON VIOLATION DROP ROW
)
COMMENT 'Legacy (pre-solution) care-management outreach calls. Coordinators chose patients manually using LACE >= 10.'
AS SELECT outreach_id, encounter_id, patient_id, coordinator_id, CAST(outreach_ts AS TIMESTAMP) AS outreach_ts, channel, outcome
FROM bronze_care_mgmt_outreach
QUALIFY row_number() OVER (PARTITION BY outreach_id ORDER BY ingested_at DESC) = 1;

CREATE OR REFRESH MATERIALIZED VIEW silver_coordinators
COMMENT 'Care coordinator roster; facility_id drives facility-level row filtering.'
AS SELECT DISTINCT coordinator_id, facility_id FROM bronze_coordinators;
