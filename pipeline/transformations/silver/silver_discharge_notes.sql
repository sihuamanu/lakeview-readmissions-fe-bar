-- SILVER: discharge summaries ready for GenAI feature extraction (ai_extract in the ML step).
USE SCHEMA lakeview_health;

CREATE OR REFRESH MATERIALIZED VIEW silver_discharge_notes (
  CONSTRAINT valid_keys     EXPECT (note_id IS NOT NULL AND encounter_id IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT non_empty_note EXPECT (length(note_text) > 50) ON VIOLATION DROP ROW
)
COMMENT 'One discharge summary per encounter (latest version). note_text is PHI free text containing social history.'
AS SELECT note_id, encounter_id, patient_id, note_type, author_role, CAST(note_ts AS TIMESTAMP) AS note_ts, note_text
FROM bronze_discharge_notes
QUALIFY row_number() OVER (PARTITION BY encounter_id ORDER BY note_ts DESC, ingested_at DESC) = 1;
