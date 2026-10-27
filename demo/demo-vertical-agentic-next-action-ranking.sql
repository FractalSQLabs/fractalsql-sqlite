-- demo/demo-vertical-agentic-next-action-ranking.sql
--
-- Industry vertical: Agentic ranking: autonomous candidate scoring and
-- dynamic next-action routing. AGENTIC kit: 30 candidates across segments,
-- a 12-item action catalog and a natural-language question over the
-- candidate table. `fractal_agent_recall_hybrid` recalls the most similar
-- past candidates inside one segment (a strict metadata filter),
-- `fractal_agent_recommend_diverse` proposes a diverse set of next actions
-- (not four variations of 'send an email'), and `fractal_sql_agent` answers
-- a status question in plain English by generating and running the SQL.
--
--   1. fractal_agent_recall_hybrid: similar past candidates, restricted to
--      one segment.
--   2. fractal_agent_recommend_diverse: a repulsion-diverse next-action
--      set.
--   3. fractal_sql_agent: a natural-language status question, generated SQL
--      executed with retries.
--   4. A closing fractal_reason() writes the ready-to-act recommendation.
--
-- Prerequisites: the fractalsql extension loaded (.load ./fractalsql); the
-- agents ship inside it. The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   sqlite3 -cmd ".load ./fractalsql" :memory: ".read demo/demo-vertical-agentic-next-action-ranking.sql"
--
-- Safe to re-run: anr_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Candidate vector = [profile fit, intent signal, engagement depth,
--     recency].
--   * The shipped agents need an embedding/reasoning endpoint only for their
--     narrative or SQL generation steps.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

.print
.print === 1. 30 candidates: segment, note and candidate vector ===
DROP TABLE IF EXISTS anr_candidates;
CREATE TABLE anr_candidates (
    id INTEGER PRIMARY KEY,
    label TEXT,
    segment TEXT,
    note TEXT,
    vec TEXT NOT NULL CHECK (fractal_vector_dims(vec) = 4)
);
INSERT INTO anr_candidates (id, label, segment, note, vec) VALUES
    (1, 'CAND-001', 'tier-2', 'attended the briefing', '0.2013,0.8387,0.3313,0.3687'),
    (2, 'CAND-002', 'tier-3', 'viewed the overview twice this week', '0.3626,0.2374,0.8726,0.5974'),
    (3, 'CAND-003', 'tier-1', 'contact changed roles', '0.5739,0.6361,0.2639,0.2261'),
    (4, 'CAND-004', 'tier-1', 'requested a trial', '0.9352,0.1348,0.2052,0.8548'),
    (5, 'CAND-005', 'tier-2', 'renewal discussion opened', '0.1465,0.8335,0.2465,0.3335'),
    (6, 'CAND-006', 'tier-3', 'requested a detailed review', '0.3078,0.2322,0.9378,0.5622'),
    (7, 'CAND-007', 'tier-1', 'attended the briefing', '0.6691,0.6309,0.1791,0.1909'),
    (8, 'CAND-008', 'tier-1', 'viewed the overview twice this week', '0.8804,0.1296,0.2704,0.8196'),
    (9, 'CAND-009', 'tier-2', 'contact changed roles', '0.2417,0.8283,0.3117,0.4483'),
    (10, 'CAND-010', 'tier-3', 'requested a trial', '0.253,0.227,0.853,0.527'),
    (11, 'CAND-011', 'tier-1', 'renewal discussion opened', '0.6143,0.6257,0.2443,0.1557'),
    (12, 'CAND-012', 'tier-1', 'requested a detailed review', '0.9756,0.1244,0.1856,0.7844'),
    (13, 'CAND-013', 'tier-2', 'attended the briefing', '0.1869,0.8231,0.3769,0.4131'),
    (14, 'CAND-014', 'tier-3', 'viewed the overview twice this week', '0.3482,0.2218,0.9182,0.6418'),
    (15, 'CAND-015', 'tier-1', 'contact changed roles', '0.5595,0.6205,0.1595,0.1205'),
    (16, 'CAND-016', 'tier-1', 'requested a trial', '0.9208,0.1192,0.2508,0.7492'),
    (17, 'CAND-017', 'tier-2', 'renewal discussion opened', '0.2821,0.8179,0.2921,0.3779'),
    (18, 'CAND-018', 'tier-3', 'requested a detailed review', '0.2934,0.2166,0.9834,0.6066'),
    (19, 'CAND-019', 'tier-1', 'attended the briefing', '0.6547,0.6153,0.2247,0.2353'),
    (20, 'CAND-020', 'tier-1', 'viewed the overview twice this week', '0.866,0.114,0.166,0.714'),
    (21, 'CAND-021', 'tier-2', 'contact changed roles', '0.2273,0.8127,0.3573,0.3427'),
    (22, 'CAND-022', 'tier-3', 'requested a trial', '0.3886,0.2114,0.8986,0.5714'),
    (23, 'CAND-023', 'tier-1', 'renewal discussion opened', '0.5999,0.6101,0.2899,0.2001'),
    (24, 'CAND-024', 'tier-1', 'requested a detailed review', '0.9612,0.1088,0.2312,0.8288'),
    (25, 'CAND-025', 'tier-2', 'attended the briefing', '0.1725,0.8075,0.2725,0.3075'),
    (26, 'CAND-026', 'tier-3', 'viewed the overview twice this week', '0.3338,0.2062,0.9638,0.5362'),
    (27, 'CAND-027', 'tier-1', 'contact changed roles', '0.6951,0.6049,0.2051,0.1649'),
    (28, 'CAND-028', 'tier-1', 'requested a trial', '0.9064,0.1036,0.2964,0.7936'),
    (29, 'CAND-029', 'tier-2', 'renewal discussion opened', '0.2677,0.8023,0.3377,0.4223'),
    (30, 'CAND-030', 'tier-3', 'requested a detailed review', '0.279,0.201,0.879,0.501');
SELECT segment, count(*) AS n FROM anr_candidates
 GROUP BY segment ORDER BY segment;

.print
.print === 2. Recall: similar past tier-1 candidates (fractal_agent_recall_hybrid) ===
DROP TABLE IF EXISTS anr_recall;
CREATE TABLE anr_recall AS
SELECT je.key + 1 AS rk, CAST(json_extract(je.value, '$.mem_id') AS TEXT) AS mem_id,
       json_extract(je.value, '$.content') AS content
FROM json_each(fractal_agent_recall_hybrid('anr_candidates', 'vec', '0.85,0.25,0.25,0.75',
         'segment', 'tier-1', 3, 'id', 'note')) je;

SELECT rk, mem_id, content FROM anr_recall ORDER BY rk;

.print
.print === 3. Next-action catalog + diverse recommendations ===
DROP TABLE IF EXISTS anr_actions;
CREATE TABLE anr_actions (
    id INTEGER PRIMARY KEY,
    label TEXT,
    vec TEXT NOT NULL CHECK (fractal_vector_dims(vec) = 3)
);
INSERT INTO anr_actions (id, label, vec) VALUES
    (1, 'book briefing (1)', '0.1513,0.8487,0.2763'),
    (2, 'offer trial (2)', '0.3026,0.1474,0.8776'),
    (3, 'share summary model (3)', '0.5789,0.5461,0.6539'),
    (4, 'invite to panel (4)', '0.9302,0.1448,0.1552'),
    (5, 'schedule review (5)', '0.1065,0.8435,0.2065'),
    (6, 'send case summary (6)', '0.2578,0.1422,0.9328'),
    (7, 'book briefing (7)', '0.6591,0.5409,0.5841'),
    (8, 'offer trial (8)', '0.8854,0.1396,0.2104'),
    (9, 'share summary model (9)', '0.1867,0.8383,0.2617'),
    (10, 'invite to panel (10)', '0.213,0.137,0.863'),
    (11, 'schedule review (11)', '0.6143,0.5357,0.6393'),
    (12, 'send case summary (12)', '0.9656,0.1344,0.1406');
DROP TABLE IF EXISTS anr_rec;
CREATE TABLE anr_rec AS
SELECT row_number() OVER (ORDER BY json_extract(je.value, '$.score') DESC, json_extract(je.value, '$.item_id')) AS rk,
       json_extract(je.value, '$.item_id') AS item_id, c.label AS label,
       round(json_extract(je.value, '$.score'), 4) AS score
FROM json_each(fractal_agent_recommend_diverse('anr_actions', 'vec', '0.8,0.3,0.25', 4, 'id')) je
JOIN anr_actions c ON c.id = json_extract(je.value, '$.item_id')
ORDER BY 1;

SELECT rk, item_id, label, score FROM anr_rec ORDER BY rk;
SELECT fractal_diversify_disable();

.print
.print === 4. fractal_sql_agent: a status question in plain English ===
SELECT fractal_sql_agent('How many tier-1 candidates are in the list?', '["anr_candidates"]', 3, 1) AS sql_agent_result;

.print
.print === 5. Reasoning: ready-to-act recommendation ===
SELECT fractal_reason(
    'one-line next-action recommendation for this operator, using the similar past candidates and actions',
    json_object('similar_candidates', (SELECT count(*) FROM anr_recall), 'candidate_action', (SELECT label FROM anr_rec WHERE rk = 1))) AS narrative;

.print
.print === 6. Headline check ===
SELECT 'HEADLINE kit=agentic-next-action-ranking ' || CASE WHEN (SELECT count(*) FROM anr_recall) = 3 AND (SELECT count(*) FROM anr_recall r JOIN anr_candidates l ON l.id = CAST(r.mem_id AS INTEGER) WHERE l.segment = 'tier-1') = 3 AND (SELECT count(*) FROM anr_rec) = 4 THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE anr_candidates; DROP TABLE anr_recall; DROP TABLE anr_actions; DROP TABLE anr_rec;
