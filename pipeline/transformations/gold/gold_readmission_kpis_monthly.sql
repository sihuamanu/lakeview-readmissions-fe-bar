-- GOLD: executive KPI table - monthly 30-day readmission rate by facility and HRRP condition.
USE SCHEMA lakeview_health;

CREATE OR REFRESH MATERIALIZED VIEW gold_readmission_kpis_monthly (
  CONSTRAINT rate_in_range EXPECT (readmission_rate BETWEEN 0 AND 1)
)
COMMENT 'Monthly readmission KPIs (measure-eligible index stays with a complete 30-day window). readmission_rate = readmissions / index_stays.'
AS SELECT
  discharge_month, facility_id, hrrp_condition,
  count(*)                                         AS index_stays,
  count_if(readmitted_30d)                         AS readmissions,
  round(count_if(readmitted_30d) / count(*), 4)    AS readmission_rate,
  count_if(legacy_outreach_contacted)              AS outreach_contacted,
  count_if(legacy_outreach_reached)                AS outreach_reached
FROM gold_index_admissions
WHERE is_measure_eligible AND label_window_complete
GROUP BY ALL;
