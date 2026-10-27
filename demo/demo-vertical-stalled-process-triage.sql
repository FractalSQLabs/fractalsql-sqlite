-- demo/demo-vertical-stalled-process-triage.sql
--
-- Industry vertical: Staged pipeline: velocity bottlenecks and stalled-item
-- triage. DOMAIN kit: 36 open items across segments and stages; three
-- tier-1 items in the review stage show the same stall signature
-- (time-in-stage far above the healthy velocity, falling engagement, a
-- silent owner, deepening concessions).
-- `fractal_agent_patient_deterioration_triage` is reused verbatim (cohort
-- search plus baseline-vs-current drift, with item-health columns in place
-- of clinical vitals): an item's stage-entry telemetry plays the patient's
-- admission baseline.
--
--   1. Cohort-restricted search: tier-1 items in the review stage only
--      (plain SQL picks the cohort).
--   2. fractal_search_trajectory: which items moved from the healthy-
--      velocity baseline the way the stalled one did.
--   3. fractal_agent_patient_deterioration_triage: both searches plus a
--      reasoned rationale in one call.
--   4. A closing fractal_reason() writes the recovery-plan recommendation.
--
-- Prerequisites: the fractalsql extension loaded (.load ./fractalsql); the
-- agents ship inside it. The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   sqlite3 -cmd ".load ./fractalsql" :memory: ".read demo/demo-vertical-stalled-process-triage.sql"
--
-- Safe to re-run: spt_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Item-health vector = [days-in-stage drift, engagement drop, owner
--     silence, concession pressure]; healthy items sit near zero.
--   * The three stalled items (ids 7, 15, 31) share one vector, so they tie
--     at the top of the trajectory search.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

.print
.print === 1. 36 items: segment, stage and item-health vector ===
DROP TABLE IF EXISTS spt_items;
CREATE TABLE spt_items (
    id INTEGER PRIMARY KEY,
    label TEXT,
    segment TEXT,
    stage TEXT,
    vec TEXT NOT NULL CHECK (fractal_vector_dims(vec) = 4)
);
INSERT INTO spt_items (id, label, segment, stage, vec) VALUES
    (1, 'ITEM-001', 'tier-2', 'intake', '0.05,-0.06,0.03,-0.04'),
    (2, 'ITEM-002', 'tier-3', 'review', '0.1,-0.02,0.06,0.02'),
    (3, 'ITEM-003', 'tier-1', 'intake', '0.15,0.02,0.09,0.08'),
    (4, 'ITEM-004', 'tier-2', 'review', '0.2,0.06,0,0.14'),
    (5, 'ITEM-005', 'tier-3', 'intake', '0,0.1,0.03,0.2'),
    (6, 'ITEM-006', 'tier-1', 'review', '0.05,0.14,0.06,-0.1'),
    (7, 'ITEM-007', 'tier-1', 'review', '1.4,0.9,1.1,1.2'),
    (8, 'ITEM-008', 'tier-3', 'review', '0.15,-0.06,0,0.02'),
    (9, 'ITEM-009', 'tier-1', 'intake', '0.2,-0.02,0.03,0.08'),
    (10, 'ITEM-010', 'tier-2', 'review', '0,0.02,0.06,0.14'),
    (11, 'ITEM-011', 'tier-3', 'intake', '0.05,0.06,0.09,0.2'),
    (12, 'ITEM-012', 'tier-1', 'review', '0.1,0.1,0,-0.1'),
    (13, 'ITEM-013', 'tier-2', 'intake', '0.15,0.14,0.03,-0.04'),
    (14, 'ITEM-014', 'tier-3', 'review', '0.2,-0.1,0.06,0.02'),
    (15, 'ITEM-015', 'tier-1', 'review', '1.4,0.9,1.1,1.2'),
    (16, 'ITEM-016', 'tier-2', 'review', '0.05,-0.02,0,0.14'),
    (17, 'ITEM-017', 'tier-3', 'intake', '0.1,0.02,0.03,0.2'),
    (18, 'ITEM-018', 'tier-1', 'review', '0.15,0.06,0.06,-0.1'),
    (19, 'ITEM-019', 'tier-2', 'intake', '0.2,0.1,0.09,-0.04'),
    (20, 'ITEM-020', 'tier-3', 'review', '0,0.14,0,0.02'),
    (21, 'ITEM-021', 'tier-1', 'intake', '0.05,-0.1,0.03,0.08'),
    (22, 'ITEM-022', 'tier-2', 'review', '0.1,-0.06,0.06,0.14'),
    (23, 'ITEM-023', 'tier-3', 'intake', '0.15,-0.02,0.09,0.2'),
    (24, 'ITEM-024', 'tier-1', 'review', '0.2,0.02,0,-0.1'),
    (25, 'ITEM-025', 'tier-2', 'intake', '0,0.06,0.03,-0.04'),
    (26, 'ITEM-026', 'tier-3', 'review', '0.05,0.1,0.06,0.02'),
    (27, 'ITEM-027', 'tier-1', 'intake', '0.1,0.14,0.09,0.08'),
    (28, 'ITEM-028', 'tier-2', 'review', '0.15,-0.1,0,0.14'),
    (29, 'ITEM-029', 'tier-3', 'intake', '0.2,-0.06,0.03,0.2'),
    (30, 'ITEM-030', 'tier-1', 'review', '0,-0.02,0.06,-0.1'),
    (31, 'ITEM-031', 'tier-1', 'review', '1.4,0.9,1.1,1.2'),
    (32, 'ITEM-032', 'tier-3', 'review', '0.1,0.06,0,0.02'),
    (33, 'ITEM-033', 'tier-1', 'intake', '0.15,0.1,0.03,0.08'),
    (34, 'ITEM-034', 'tier-2', 'review', '0.2,0.14,0.06,0.14'),
    (35, 'ITEM-035', 'tier-3', 'intake', '0,-0.1,0.09,0.2'),
    (36, 'ITEM-036', 'tier-1', 'review', '0.05,-0.06,0,-0.1');
SELECT segment, stage, count(*) AS n FROM spt_items
 GROUP BY segment, stage ORDER BY segment, stage;

.print
.print === 2. Cohort-restricted search: tier-1 items in review ===
WITH hs AS (SELECT fractal_hybrid_clinical_search(
                    'spt_items', 'vec', '1.4,0.9,1.1,1.2',
                    (SELECT group_concat(id) FROM spt_items WHERE segment = 'tier-1' AND stage = 'review'), 5) AS rj)
SELECT w.id, w.label AS label, round(json_extract(je.value, '$.distance'), 4) AS distance
FROM hs, json_each(hs.rj) je
JOIN spt_items w ON w.rowid = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance'), w.id;

.print
.print === 3. Baseline -> current item-health trajectory ===
DROP TABLE IF EXISTS spt_traj;
CREATE TABLE spt_traj AS
WITH tr AS (SELECT fractal_search_trajectory(
                    'spt_items', 'vec',
                    '0.05,0,0.03,0',    -- baseline
                    '1.4,0.9,1.1,1.2',    -- current
                    5) AS tj)
SELECT row_number() OVER (ORDER BY json_extract(je.value, '$.distance'), w.id) AS rk, w.id, w.label AS label,
       round(json_extract(je.value, '$.distance'), 4) AS distance
FROM tr, json_each(tr.tj) je
JOIN spt_items w ON w.id - 1 = json_extract(je.value, '$.doc_id');

SELECT rk, id, label, distance FROM spt_traj ORDER BY rk;

.print
.print === 4. fractal_agent_patient_deterioration_triage (stalled-item triage) ===
DROP TABLE IF EXISTS spt_triage;
CREATE TABLE spt_triage AS
SELECT CAST(json_extract(j, '$.nearest_cohort_id') AS TEXT) AS nearest_cohort_id,
       json_extract(j, '$.cohort_distance') AS cohort_distance,
       json_extract(j, '$.drift_distance') AS drift_distance,
       json_extract(j, '$.rationale') AS rationale
FROM (SELECT fractal_agent_patient_deterioration_triage(
    'spt_items', 'vec', '1.4,0.9,1.1,1.2',
    '0.05,0,0.03,0', '1.4,0.9,1.1,1.2',
    (SELECT group_concat(id) FROM spt_items WHERE segment = 'tier-1' AND stage = 'review'),
    5) AS j);

SELECT nearest_cohort_id, cohort_distance, drift_distance, rationale FROM spt_triage;

.print
.print === 5. Reasoning: recovery-plan recommendation ===
SELECT fractal_reason(
    'one-line recovery-plan recommendation for these stalled tier-1 items',
    json_object('stalled_items_found', (SELECT count(*) FROM spt_traj WHERE distance < 0.001), 'nearest_cohort_item', (SELECT nearest_cohort_id FROM spt_triage))) AS narrative;

.print
.print === 6. Headline check ===
SELECT 'HEADLINE kit=stalled-process-triage ' || CASE WHEN (SELECT count(*) FROM spt_traj WHERE distance < 0.001) >= 3 AND (SELECT nearest_cohort_id FROM spt_triage) IN ('7', '15', '31') THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE spt_items; DROP TABLE spt_traj; DROP TABLE spt_triage;
