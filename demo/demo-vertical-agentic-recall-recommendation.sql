-- demo/demo-vertical-agentic-recall-recommendation.sql
--
-- Industry vertical: Agentic recommendation: recall of similar past
-- sessions and diverse next-best offers. AGENTIC kit: 24 candidate offers
-- in four clusters and 30 abandoned sessions across categories. Scout
-- (`fractal_search_explore`) picks six deliberately different offers around
-- the user's profile so the follow-up tests variety rather than six
-- near-identical offers; `fractal_agent_recall_hybrid` recalls the most
-- similar past sessions inside the user's category (a strict metadata
-- filter); and `fractal_sql_agent` answers a question over the session
-- table in plain English.
--
--   1. fractal_search_explore (Scout): six diverse offers around the user
--      profile.
--   2. fractal_agent_recall_hybrid: similar past sessions in one category,
--      with their follow-up note.
--   3. fractal_sql_agent: a question in plain English, SQL generated and
--      run with retries.
--   4. A closing fractal_reason() writes the follow-up brief.
--
-- Prerequisites: the fractalsql extension loaded (.load ./fractalsql); the
-- agents ship inside it. The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   sqlite3 -cmd ".load ./fractalsql" :memory: ".read demo/demo-vertical-agentic-recall-recommendation.sql"
--
-- Safe to re-run: arr_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Offer vector = [price sensitivity, brand affinity, urgency, bundle
--     appeal]; session vector = [value tier, dwell time, return history,
--     promo response].
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

.print
.print === 1. 24 candidate offers in four clusters ===
DROP TABLE IF EXISTS arr_offers;
CREATE TABLE arr_offers (
    id INTEGER PRIMARY KEY,
    label TEXT,
    kind TEXT,
    c1 REAL,
    c2 REAL,
    c3 REAL,
    c4 REAL,
    vec TEXT NOT NULL CHECK (fractal_vector_dims(vec) = 4)
);
INSERT INTO arr_offers (id, label, kind, c1, c2, c3, c4, vec) VALUES
    (1, 'OFFER-01 offer-priority', 'offer-priority', 0.2013, 0.8387, 0.3313, 0.3687, '0.2013,0.8387,0.3313,0.3687'),
    (2, 'OFFER-02 offer-credit', 'offer-credit', 0.3626, 0.2374, 0.8726, 0.5974, '0.3626,0.2374,0.8726,0.5974'),
    (3, 'OFFER-03 offer-discount', 'offer-discount', 0.5739, 0.6361, 0.2639, 0.2261, '0.5739,0.6361,0.2639,0.2261'),
    (4, 'OFFER-04 offer-bundle', 'offer-bundle', 0.9352, 0.1348, 0.2052, 0.8548, '0.9352,0.1348,0.2052,0.8548'),
    (5, 'OFFER-05 offer-priority', 'offer-priority', 0.1465, 0.8335, 0.2465, 0.3335, '0.1465,0.8335,0.2465,0.3335'),
    (6, 'OFFER-06 offer-credit', 'offer-credit', 0.3078, 0.2322, 0.9378, 0.5622, '0.3078,0.2322,0.9378,0.5622'),
    (7, 'OFFER-07 offer-discount', 'offer-discount', 0.6691, 0.6309, 0.1791, 0.1909, '0.6691,0.6309,0.1791,0.1909'),
    (8, 'OFFER-08 offer-bundle', 'offer-bundle', 0.8804, 0.1296, 0.2704, 0.8196, '0.8804,0.1296,0.2704,0.8196'),
    (9, 'OFFER-09 offer-priority', 'offer-priority', 0.2417, 0.8283, 0.3117, 0.4483, '0.2417,0.8283,0.3117,0.4483'),
    (10, 'OFFER-10 offer-credit', 'offer-credit', 0.253, 0.227, 0.853, 0.527, '0.253,0.227,0.853,0.527'),
    (11, 'OFFER-11 offer-discount', 'offer-discount', 0.6143, 0.6257, 0.2443, 0.1557, '0.6143,0.6257,0.2443,0.1557'),
    (12, 'OFFER-12 offer-bundle', 'offer-bundle', 0.9756, 0.1244, 0.1856, 0.7844, '0.9756,0.1244,0.1856,0.7844'),
    (13, 'OFFER-13 offer-priority', 'offer-priority', 0.1869, 0.8231, 0.3769, 0.4131, '0.1869,0.8231,0.3769,0.4131'),
    (14, 'OFFER-14 offer-credit', 'offer-credit', 0.3482, 0.2218, 0.9182, 0.6418, '0.3482,0.2218,0.9182,0.6418'),
    (15, 'OFFER-15 offer-discount', 'offer-discount', 0.5595, 0.6205, 0.1595, 0.1205, '0.5595,0.6205,0.1595,0.1205'),
    (16, 'OFFER-16 offer-bundle', 'offer-bundle', 0.9208, 0.1192, 0.2508, 0.7492, '0.9208,0.1192,0.2508,0.7492'),
    (17, 'OFFER-17 offer-priority', 'offer-priority', 0.2821, 0.8179, 0.2921, 0.3779, '0.2821,0.8179,0.2921,0.3779'),
    (18, 'OFFER-18 offer-credit', 'offer-credit', 0.2934, 0.2166, 0.9834, 0.6066, '0.2934,0.2166,0.9834,0.6066'),
    (19, 'OFFER-19 offer-discount', 'offer-discount', 0.6547, 0.6153, 0.2247, 0.2353, '0.6547,0.6153,0.2247,0.2353'),
    (20, 'OFFER-20 offer-bundle', 'offer-bundle', 0.866, 0.114, 0.166, 0.714, '0.866,0.114,0.166,0.714'),
    (21, 'OFFER-21 offer-priority', 'offer-priority', 0.2273, 0.8127, 0.3573, 0.3427, '0.2273,0.8127,0.3573,0.3427'),
    (22, 'OFFER-22 offer-credit', 'offer-credit', 0.3886, 0.2114, 0.8986, 0.5714, '0.3886,0.2114,0.8986,0.5714'),
    (23, 'OFFER-23 offer-discount', 'offer-discount', 0.5999, 0.6101, 0.2899, 0.2001, '0.5999,0.6101,0.2899,0.2001'),
    (24, 'OFFER-24 offer-bundle', 'offer-bundle', 0.9612, 0.1088, 0.2312, 0.8288, '0.9612,0.1088,0.2312,0.8288');
SELECT kind, count(*) AS n FROM arr_offers
 GROUP BY kind ORDER BY kind;

.print
.print === 2. Scout (diversity-first): six different offers ===
DROP TABLE IF EXISTS arr_scout;
CREATE TABLE arr_scout AS
SELECT fractal_search_explore(vec, '0.6,0.4,0.6,0.5',
           '{"population_size": 6, "iterations": 8, "mmr_lambda": 0.15}') AS rj
  FROM arr_offers;

DROP TABLE IF EXISTS arr_picks;
CREATE TABLE arr_picks AS
SELECT pt.key + 1 AS ord, s.id, s.label, s.kind
FROM arr_scout t, json_each(json_extract(t.rj, '$.population')) pt
JOIN arr_offers s ON abs(s.c1 - json_extract(pt.value, '$[0]')) < 1e-6 AND abs(s.c2 - json_extract(pt.value, '$[1]')) < 1e-6 AND abs(s.c3 - json_extract(pt.value, '$[2]')) < 1e-6 AND abs(s.c4 - json_extract(pt.value, '$[3]')) < 1e-6
ORDER BY pt.key;

SELECT ord, id, label, kind FROM arr_picks ORDER BY ord;
.print --- coverage: offer kinds represented in the six picks ---
SELECT count(DISTINCT kind) AS kinds_covered_of_4 FROM arr_picks;

.print
.print === 3. Recall: similar abandoned sessions in the same category ===
DROP TABLE IF EXISTS arr_sessions;
CREATE TABLE arr_sessions (
    id INTEGER PRIMARY KEY,
    label TEXT,
    category TEXT,
    note TEXT,
    vec TEXT NOT NULL CHECK (fractal_vector_dims(vec) = 4)
);
INSERT INTO arr_sessions (id, label, category, note, vec) VALUES
    (1, 'SESS-001', 'group-2', 'recovered with a bundle', '0.2013,0.8387,0.3313,0.3687'),
    (2, 'SESS-002', 'group-3', 'ignored two follow-ups', '0.3626,0.2374,0.8726,0.5974'),
    (3, 'SESS-003', 'group-1', 'recovered after a discount', '0.5739,0.6361,0.2639,0.2261'),
    (4, 'SESS-004', 'group-1', 'completed offline', '0.9352,0.1348,0.2052,0.8548'),
    (5, 'SESS-005', 'group-2', 'recovered with a credit', '0.1465,0.8335,0.2465,0.3335'),
    (6, 'SESS-006', 'group-3', 'recovered with priority handling', '0.3078,0.2322,0.9378,0.5622'),
    (7, 'SESS-007', 'group-1', 'recovered with a bundle', '0.6691,0.6309,0.1791,0.1909'),
    (8, 'SESS-008', 'group-1', 'ignored two follow-ups', '0.8804,0.1296,0.2704,0.8196'),
    (9, 'SESS-009', 'group-2', 'recovered after a discount', '0.2417,0.8283,0.3117,0.4483'),
    (10, 'SESS-010', 'group-3', 'completed offline', '0.253,0.227,0.853,0.527'),
    (11, 'SESS-011', 'group-1', 'recovered with a credit', '0.6143,0.6257,0.2443,0.1557'),
    (12, 'SESS-012', 'group-1', 'recovered with priority handling', '0.9756,0.1244,0.1856,0.7844'),
    (13, 'SESS-013', 'group-2', 'recovered with a bundle', '0.1869,0.8231,0.3769,0.4131'),
    (14, 'SESS-014', 'group-3', 'ignored two follow-ups', '0.3482,0.2218,0.9182,0.6418'),
    (15, 'SESS-015', 'group-1', 'recovered after a discount', '0.5595,0.6205,0.1595,0.1205'),
    (16, 'SESS-016', 'group-1', 'completed offline', '0.9208,0.1192,0.2508,0.7492'),
    (17, 'SESS-017', 'group-2', 'recovered with a credit', '0.2821,0.8179,0.2921,0.3779'),
    (18, 'SESS-018', 'group-3', 'recovered with priority handling', '0.2934,0.2166,0.9834,0.6066'),
    (19, 'SESS-019', 'group-1', 'recovered with a bundle', '0.6547,0.6153,0.2247,0.2353'),
    (20, 'SESS-020', 'group-1', 'ignored two follow-ups', '0.866,0.114,0.166,0.714'),
    (21, 'SESS-021', 'group-2', 'recovered after a discount', '0.2273,0.8127,0.3573,0.3427'),
    (22, 'SESS-022', 'group-3', 'completed offline', '0.3886,0.2114,0.8986,0.5714'),
    (23, 'SESS-023', 'group-1', 'recovered with a credit', '0.5999,0.6101,0.2899,0.2001'),
    (24, 'SESS-024', 'group-1', 'recovered with priority handling', '0.9612,0.1088,0.2312,0.8288'),
    (25, 'SESS-025', 'group-2', 'recovered with a bundle', '0.1725,0.8075,0.2725,0.3075'),
    (26, 'SESS-026', 'group-3', 'ignored two follow-ups', '0.3338,0.2062,0.9638,0.5362'),
    (27, 'SESS-027', 'group-1', 'recovered after a discount', '0.6951,0.6049,0.2051,0.1649'),
    (28, 'SESS-028', 'group-1', 'completed offline', '0.9064,0.1036,0.2964,0.7936'),
    (29, 'SESS-029', 'group-2', 'recovered with a credit', '0.2677,0.8023,0.3377,0.4223'),
    (30, 'SESS-030', 'group-3', 'recovered with priority handling', '0.279,0.201,0.879,0.501');
DROP TABLE IF EXISTS arr_recall;
CREATE TABLE arr_recall AS
SELECT je.key + 1 AS rk, CAST(json_extract(je.value, '$.mem_id') AS TEXT) AS mem_id,
       json_extract(je.value, '$.content') AS content
FROM json_each(fractal_agent_recall_hybrid('arr_sessions', 'vec', '0.85,0.25,0.25,0.75',
         'category', 'group-1', 3, 'id', 'note')) je;

SELECT rk, mem_id, content FROM arr_recall ORDER BY rk;

.print
.print === 4. fractal_sql_agent: a question in plain English ===
SELECT fractal_sql_agent('How many abandoned group-1 sessions are there?', '["arr_sessions"]', 3, 1) AS sql_agent_result;

.print
.print === 5. Reasoning: follow-up message brief ===
SELECT fractal_reason(
    'one-line follow-up message brief: which offer to lead with and what worked on similar sessions',
    json_object('offers_tested', (SELECT count(*) FROM arr_picks), 'similar_sessions', (SELECT count(*) FROM arr_recall))) AS narrative;

.print
.print === 6. Headline check ===
SELECT 'HEADLINE kit=agentic-recall-recommendation ' || CASE WHEN (SELECT count(*) FROM arr_picks) = 6 AND (SELECT count(DISTINCT kind) FROM arr_picks) >= 3 AND (SELECT count(*) FROM arr_recall) = 3 AND (SELECT count(*) FROM arr_recall r JOIN arr_sessions c ON c.id = CAST(r.mem_id AS INTEGER) WHERE c.category = 'group-1') = 3 THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE arr_offers; DROP TABLE arr_picks; DROP TABLE arr_scout; DROP TABLE arr_sessions; DROP TABLE arr_recall;
