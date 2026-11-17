# Lakeview Health | Fewer Readmissions, Same Care Team
*Draft deck: 10 slides. Speaker notes are in italics. Export to PDF for submission.*

---

## Slide 1: The problem
**Lakeview discharges about 110 patients a day. 15.5% come back within 30 days.**
* Coordinators can call only a fraction, and they pick by hand from a LACE spreadsheet.
* The strongest warning signs (lives alone, cannot afford meds, no ride to follow-up) are buried in free-text notes that LACE never sees.
* Every avoidable readmission costs about $15k, a bed, and HRRP penalty exposure.

*Notes: open with the coordinator's morning, not with technology.*

---

## Slide 2: What it costs
| | Today |
| --- | --- |
| 30-day readmission rate | 15.5% (HF, COPD and AMI are higher) |
| Readmissions/yr (40k discharges) | ~6,200 |
| High-risk patients actually reached | ~12% of discharges |
| Coordinator time building lists | ~3,700 h/yr |

Social risk in the notes nearly doubles readmission risk: **lives alone 25.2% vs 13.1%; no transportation 25.1% vs 14.4%.**

---

## Slide 3: The solution in one sentence
**A risk-ranked worklist every morning that reads the notes, explains why each patient is at risk, and tells the coordinator what to do on the call.**

A day in the life: open the app -> top patients for my hospital -> the 3 reasons each one is at risk + a 60-word brief -> call -> log the outcome in one click.

---

## Slide 4: Proof the AI adds value (held-out period: 3,093 discharges)
| | AUC | Readmissions in the top 20% |
| --- | --- | --- |
| LACE (today) | 0.686 | 40.7% |
| Structured EHR model | 0.700 | 40.5% |
| **+ GenAI social risk from notes** | **0.732** | **42.7%** |

* Structured data alone does **not** beat LACE. **The GenAI note features create the lift.**
* The extraction was validated: 99.4% to 100% agreement with an independent rule check after one prompt iteration.

*Notes: be candid that the ranking lift is modest. The bigger lever is reaching more of the right patients (next slide).*

---

## Slide 5: Demo
1. Coordinator view: today's ranked worklist for LVH-NORTH, with drivers and the GenAI brief, and logging an outreach
2. Executive view: readmission trend by facility and condition, reached vs not reached
3. Genie: "Of patients reached by care management, how many were readmitted compared with those not reached?"

---

## Slide 6: Value (estimates, assumptions shown)
| Lever | Avoided readmissions/yr |
| --- | --- |
| Better targeting (+2.0 pts of readmissions on the same list) | ~19 |
| Reach more high-risk patients (12% -> 18% of discharges; reached LACE >= 10 patients: 17.6% vs 23.2%) | ~134 |
| **Total** | **~150 -> ~$2.3M/yr, ~700 bed-days, rate 15.5% -> 15.1%** |

Upside at 25% reached: ~300 avoided (~$4.6M). Plus ~3,700 coordinator hours/yr and lower HRRP exposure (not quantified).

*Notes: the reach effect is observational. The pilot will measure it properly.*

---

## Slide 7: Architecture: one governed platform
EHR extract -> **Lakeflow** (bronze/silver/gold, data quality expectations) -> **Unity Catalog** (PHI tags, row filters, masks, lineage) -> **AI Functions** (`ai_extract` social risk, `ai_query` briefs) -> **MLflow + UC model** (`readmission_risk@champion`) -> **Lakebase** (worklist + outreach write-back) -> **Databricks App** and **Genie**

---

## Slide 8: Trust: governance, explainability, fairness
* PHI never leaves the platform: models are hosted on Databricks, and UC enforces masks and row filters by facility (tested: a LVH-NORTH user sees only LVH-NORTH with masked identifiers).
* Every score shows its top 3 drivers in plain language.
* Decision support only: coordinators decide.
* Fairness: payer and language are not model inputs. Lower flag rates for Commercial and Medicaid patients follow their lower base rates; monitored monthly.
* Known gaps: probability calibration and incremental note extraction are on the roadmap.

---

## Slide 9: Path to production
| Phase | Scope |
| --- | --- |
| 0-30 days | Connect Epic/Cerner (FHIR bulk export or partner connector) into the same Lakeflow pipeline |
| 30-90 days | Pilot at LVH-NORTH; stepped rollout to measure the reach effect; calibrate the model |
| 90+ days | All facilities; real-time scoring at discharge (Model Serving); write tasks back to the EHR |

---

## Slide 10: The ask
**A 90-day pilot at one facility.** Success criteria:
* Share of high-risk patients reached in 72 h: 12% -> 18%
* Readmission rate among High-tier patients at the pilot facility drops vs the control facilities
* Coordinator list prep time drops from over 1 h/day to under 10 min

---

### Appendix: likely objections
| From | Objection | Answer |
| --- | --- | --- |
| CMO | "Black box?" | Top 3 drivers for each patient, compared against LACE, decision support only |
| CMO | "Biased?" | Fairness by payer and language is measured and monitored |
| CMO | "Cost / time to value?" | Serverless, pay per use; 90-day pilot at one facility |
| Data lead | "Epic integration?" | FHIR bulk export or a partner connector feeds the same pipeline |
| Data lead | "PHI?" | UC tags, masks, row filters, audit logs; models hosted inside Databricks |
| Data lead | "Why Lakebase?" | OLTP writes from coordinators plus fast reads; synced from the lakehouse with no custom ETL |
