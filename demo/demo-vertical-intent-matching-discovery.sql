-- demo/demo-vertical-intent-matching-discovery.sql
--
-- Industry vertical: Intent matching: signal clustering and diverse
-- candidate selection. DOMAIN kit: 24 target entities in four intent
-- clusters (category + stage signal vectors) and a 30-item content library.
-- Scout (`fractal_search_explore`, the diversity-first MMR search) picks
-- six deliberately different entities around a target profile instead of
-- six near-duplicates, and `fractal_agent_recommend_diverse` returns a
-- repulsion-diverse set of content items for the chosen entity: no model
-- needed for either.
--
--   1. fractal_search_explore (Scout): six diverse entities around the
--      ideal profile.
--   2. Coverage check: how many of the four categories the six picks span.
--   3. fractal_agent_recommend_diverse: a diverse content set for the
--      target entity.
--   4. A closing fractal_reason() writes the summary.
--
-- Prerequisites: the fractalsql extension loaded (.load ./fractalsql); the
-- agents ship inside it. The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   sqlite3 -cmd ".load ./fractalsql" :memory: ".read demo/demo-vertical-intent-matching-discovery.sql"
--
-- Safe to re-run: imd_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Entity intent vector = [topic match, engagement depth, profile fit,
--     stage signal].
--   * Scout is an MMR search: lowering mmr_lambda trades relevance for
--     variety.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

.print
.print === 1. 24 target entities in four intent clusters ===
DROP TABLE IF EXISTS imd_entities;
CREATE TABLE imd_entities (
    id INTEGER PRIMARY KEY,
    label TEXT,
    category TEXT,
    c1 REAL,
    c2 REAL,
    c3 REAL,
    c4 REAL,
    vec TEXT NOT NULL CHECK (fractal_vector_dims(vec) = 4)
);
INSERT INTO imd_entities (id, label, category, c1, c2, c3, c4, vec) VALUES
    (1, 'ENT-01', 'cluster-b', 0.2013, 0.8387, 0.3313, 0.3687, '0.2013,0.8387,0.3313,0.3687'),
    (2, 'ENT-02', 'cluster-c', 0.3626, 0.2374, 0.8726, 0.5974, '0.3626,0.2374,0.8726,0.5974'),
    (3, 'ENT-03', 'cluster-d', 0.5739, 0.6361, 0.2639, 0.2261, '0.5739,0.6361,0.2639,0.2261'),
    (4, 'ENT-04', 'cluster-a', 0.9352, 0.1348, 0.2052, 0.8548, '0.9352,0.1348,0.2052,0.8548'),
    (5, 'ENT-05', 'cluster-b', 0.1465, 0.8335, 0.2465, 0.3335, '0.1465,0.8335,0.2465,0.3335'),
    (6, 'ENT-06', 'cluster-c', 0.3078, 0.2322, 0.9378, 0.5622, '0.3078,0.2322,0.9378,0.5622'),
    (7, 'ENT-07', 'cluster-d', 0.6691, 0.6309, 0.1791, 0.1909, '0.6691,0.6309,0.1791,0.1909'),
    (8, 'ENT-08', 'cluster-a', 0.8804, 0.1296, 0.2704, 0.8196, '0.8804,0.1296,0.2704,0.8196'),
    (9, 'ENT-09', 'cluster-b', 0.2417, 0.8283, 0.3117, 0.4483, '0.2417,0.8283,0.3117,0.4483'),
    (10, 'ENT-10', 'cluster-c', 0.253, 0.227, 0.853, 0.527, '0.253,0.227,0.853,0.527'),
    (11, 'ENT-11', 'cluster-d', 0.6143, 0.6257, 0.2443, 0.1557, '0.6143,0.6257,0.2443,0.1557'),
    (12, 'ENT-12', 'cluster-a', 0.9756, 0.1244, 0.1856, 0.7844, '0.9756,0.1244,0.1856,0.7844'),
    (13, 'ENT-13', 'cluster-b', 0.1869, 0.8231, 0.3769, 0.4131, '0.1869,0.8231,0.3769,0.4131'),
    (14, 'ENT-14', 'cluster-c', 0.3482, 0.2218, 0.9182, 0.6418, '0.3482,0.2218,0.9182,0.6418'),
    (15, 'ENT-15', 'cluster-d', 0.5595, 0.6205, 0.1595, 0.1205, '0.5595,0.6205,0.1595,0.1205'),
    (16, 'ENT-16', 'cluster-a', 0.9208, 0.1192, 0.2508, 0.7492, '0.9208,0.1192,0.2508,0.7492'),
    (17, 'ENT-17', 'cluster-b', 0.2821, 0.8179, 0.2921, 0.3779, '0.2821,0.8179,0.2921,0.3779'),
    (18, 'ENT-18', 'cluster-c', 0.2934, 0.2166, 0.9834, 0.6066, '0.2934,0.2166,0.9834,0.6066'),
    (19, 'ENT-19', 'cluster-d', 0.6547, 0.6153, 0.2247, 0.2353, '0.6547,0.6153,0.2247,0.2353'),
    (20, 'ENT-20', 'cluster-a', 0.866, 0.114, 0.166, 0.714, '0.866,0.114,0.166,0.714'),
    (21, 'ENT-21', 'cluster-b', 0.2273, 0.8127, 0.3573, 0.3427, '0.2273,0.8127,0.3573,0.3427'),
    (22, 'ENT-22', 'cluster-c', 0.3886, 0.2114, 0.8986, 0.5714, '0.3886,0.2114,0.8986,0.5714'),
    (23, 'ENT-23', 'cluster-d', 0.5999, 0.6101, 0.2899, 0.2001, '0.5999,0.6101,0.2899,0.2001'),
    (24, 'ENT-24', 'cluster-a', 0.9612, 0.1088, 0.2312, 0.8288, '0.9612,0.1088,0.2312,0.8288');
SELECT category, count(*) AS n FROM imd_entities
 GROUP BY category ORDER BY category;

.print
.print === 2. Scout (diversity-first): six different entities ===
DROP TABLE IF EXISTS imd_scout;
CREATE TABLE imd_scout AS
SELECT fractal_search_explore(vec, '0.6,0.3,0.5,0.7',
           '{"population_size": 6, "iterations": 8, "mmr_lambda": 0.15}') AS rj
  FROM imd_entities;

DROP TABLE IF EXISTS imd_picks;
CREATE TABLE imd_picks AS
SELECT pt.key + 1 AS ord, s.id, s.label, s.category
FROM imd_scout t, json_each(json_extract(t.rj, '$.population')) pt
JOIN imd_entities s ON abs(s.c1 - json_extract(pt.value, '$[0]')) < 1e-6 AND abs(s.c2 - json_extract(pt.value, '$[1]')) < 1e-6 AND abs(s.c3 - json_extract(pt.value, '$[2]')) < 1e-6 AND abs(s.c4 - json_extract(pt.value, '$[3]')) < 1e-6
ORDER BY pt.key;

SELECT ord, id, label, category FROM imd_picks ORDER BY ord;
.print --- coverage: categories represented in the six picks ---
SELECT count(DISTINCT category) AS categories_covered_of_4 FROM imd_picks;

.print
.print === 3. Content library + diverse recommendations for the target entity ===
DROP TABLE IF EXISTS imd_content;
CREATE TABLE imd_content (
    id INTEGER PRIMARY KEY,
    label TEXT,
    vec TEXT NOT NULL CHECK (fractal_vector_dims(vec) = 3)
);
INSERT INTO imd_content (id, label, vec) VALUES
    (1, 'calculator #1', '0.1513,0.8487,0.2763'),
    (2, 'technical whitepaper #2', '0.3026,0.1474,0.8776'),
    (3, 'integration playbook #3', '0.5789,0.5461,0.6539'),
    (4, 'case study #4', '0.9302,0.1448,0.1552'),
    (5, 'analyst report #5', '0.1065,0.8435,0.2065'),
    (6, 'overview guide #6', '0.2578,0.1422,0.9328'),
    (7, 'calculator #7', '0.6591,0.5409,0.5841'),
    (8, 'technical whitepaper #8', '0.8854,0.1396,0.2104'),
    (9, 'integration playbook #9', '0.1867,0.8383,0.2617'),
    (10, 'case study #10', '0.213,0.137,0.863'),
    (11, 'analyst report #11', '0.6143,0.5357,0.6393'),
    (12, 'overview guide #12', '0.9656,0.1344,0.1406'),
    (13, 'calculator #13', '0.1419,0.8331,0.3169'),
    (14, 'technical whitepaper #14', '0.2932,0.1318,0.9182'),
    (15, 'integration playbook #15', '0.5695,0.5305,0.5695'),
    (16, 'case study #16', '0.9208,0.1292,0.1958'),
    (17, 'analyst report #17', '0.2221,0.8279,0.2471'),
    (18, 'overview guide #18', '0.2484,0.1266,0.9734'),
    (19, 'calculator #19', '0.6497,0.5253,0.6247'),
    (20, 'technical whitepaper #20', '0.876,0.124,0.126'),
    (21, 'integration playbook #21', '0.1773,0.8227,0.3023'),
    (22, 'case study #22', '0.3286,0.1214,0.9036'),
    (23, 'analyst report #23', '0.6049,0.5201,0.6799'),
    (24, 'overview guide #24', '0.9562,0.1188,0.1812'),
    (25, 'calculator #25', '0.1325,0.8175,0.2325'),
    (26, 'technical whitepaper #26', '0.2838,0.1162,0.9588'),
    (27, 'integration playbook #27', '0.6851,0.5149,0.6101'),
    (28, 'case study #28', '0.9114,0.1136,0.2364'),
    (29, 'analyst report #29', '0.2127,0.8123,0.2877'),
    (30, 'overview guide #30', '0.239,0.111,0.889');
DROP TABLE IF EXISTS imd_rec;
CREATE TABLE imd_rec AS
SELECT row_number() OVER (ORDER BY json_extract(je.value, '$.score') DESC, json_extract(je.value, '$.item_id')) AS rk,
       json_extract(je.value, '$.item_id') AS item_id, c.label AS label,
       round(json_extract(je.value, '$.score'), 4) AS score
FROM json_each(fractal_agent_recommend_diverse('imd_content', 'vec', '0.8,0.3,0.25', 5, 'id')) je
JOIN imd_content c ON c.id = json_extract(je.value, '$.item_id')
ORDER BY 1;

SELECT rk, item_id, label, score FROM imd_rec ORDER BY rk;
SELECT fractal_diversify_disable();

.print
.print === 4. Reasoning: engagement-plan summary ===
SELECT fractal_reason(
    'one-line engagement plan: which entities to prioritize and which content to lead with',
    json_object('entities_picked', (SELECT count(*) FROM imd_picks), 'top_content', (SELECT label FROM imd_rec WHERE rk = 1))) AS narrative;

.print
.print === 5. Headline check ===
SELECT 'HEADLINE kit=intent-matching-discovery ' || CASE WHEN (SELECT count(*) FROM imd_picks) = 6 AND (SELECT count(DISTINCT category) FROM imd_picks) >= 3 AND (SELECT count(*) FROM imd_rec) = 5 THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE imd_entities; DROP TABLE imd_picks; DROP TABLE imd_scout; DROP TABLE imd_content; DROP TABLE imd_rec;
