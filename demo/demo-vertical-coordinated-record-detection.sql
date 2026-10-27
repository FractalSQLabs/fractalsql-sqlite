-- demo/demo-vertical-coordinated-record-detection.sql
--
-- Industry vertical: Coordinated-record detection: ring signatures and
-- severity-trajectory analysis. DOMAIN kit: A review desk screens new
-- submissions against known ring signatures with
-- `fractal_agent_outlier_intercept`, finds the records that moved from the
-- normal severity baseline the way a staged ring does with
-- `fractal_search_trajectory`, and measures the geographic footprint of
-- event locations with `fractal_dimension_boxcount` (organic events scatter
-- across the city; a staged ring repeats along one road).
--
--   1. fractal_agent_outlier_intercept: hold new records that match a known
--      ring signature.
--   2. fractal_search_trajectory: which open records moved the way the
--      ring's records did.
--   3. fractal_dimension_boxcount: the footprint of event locations,
--      organic vs ring.
--   4. A closing fractal_reason() writes the referral line.
--
-- Prerequisites: the fractalsql extension loaded (.load ./fractalsql); the
-- agents ship inside it. The closing fractal_reason() narrative and any
-- shipped-agent rationale columns need the reasoning plugin
-- (docs/reasoning-setup.md); every other step runs with no model.
--
-- Run:
--   sqlite3 -cmd ".load ./fractalsql" :memory: ".read demo/demo-vertical-coordinated-record-detection.sql"
--
-- Safe to re-run: crd_* tables are dropped and recreated each time.
--
-- Notes:
--   * Fully deterministic fixtures (no random()).
--   * Ring signature = [record velocity, shared provider, shared
--     representative, soft-tissue ratio, address clustering].
--   * Severity vector = [severity jump, treatment gap, bill inflation,
--     representative speed]; the three ring records (ids 5, 13, 22) share
--     one vector.
--   * Ends with a HEADLINE line computed from the kit's own results (HEADLINE kit=<name> ok);
--     the build_test kit gate greps for it.

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

.print
.print === 1. Known ring signatures + proposed new records ===
DROP TABLE IF EXISTS crd_known;
CREATE TABLE crd_known (
    id INTEGER PRIMARY KEY,
    label TEXT,
    vec TEXT NOT NULL CHECK (fractal_vector_dims(vec) = 5)
);
INSERT INTO crd_known (id, label, vec) VALUES
    (1, 'staged-event ring: same provider and representative', '0.95,0.9,0.85,0.1,0.2'),
    (2, 'synthetic-severity ring: repeated minor-severity pile-up', '0.9,0.05,0.3,0.95,0.4'),
    (3, 'phantom-participant records, one address cluster', '0.05,0.05,0.1,0.1,0.95'),
    (4, 'provider-collusion ring: repeat billing', '0.1,0.8,0.9,0.85,0.3');
DROP TABLE IF EXISTS crd_proposed;
CREATE TABLE crd_proposed (
    id INTEGER PRIMARY KEY,
    label TEXT,
    vec TEXT NOT NULL CHECK (fractal_vector_dims(vec) = 5)
);
INSERT INTO crd_proposed (id, label, vec) VALUES
    (1, 'P1 staged-pattern record, usual provider and representative', '0.92,0.88,0.8,0.12,0.18'),
    (2, 'P2 isolated single-party record', '0.02,0,0.05,0,0.05'),
    (3, 'P3 new provider, same city', '0,0.02,0.7,0.04,0.05'),
    (4, 'P4 faint minor-severity pattern, far away', '0.4,0.02,0.12,0.42,0.16');

.print
.print === 2. fractal_agent_outlier_intercept (cosine, threshold 0.10) ===
DROP TABLE IF EXISTS crd_screen;
CREATE TABLE crd_screen AS
SELECT id, label, json_extract(v, '$.intercepted') AS intercepted, 'cosine' AS metric
FROM (SELECT id, label, fractal_agent_outlier_intercept(vec, 'crd_known', 'vec', 0.1) AS v
        FROM crd_proposed)
ORDER BY id;

SELECT id, label, intercepted, metric FROM crd_screen ORDER BY id;

.print
.print === 3. Open-record severity trajectory: who moved like the ring ===
DROP TABLE IF EXISTS crd_records;
CREATE TABLE crd_records (
    id INTEGER PRIMARY KEY,
    label TEXT,
    vec TEXT NOT NULL CHECK (fractal_vector_dims(vec) = 4)
);
INSERT INTO crd_records (id, label, vec) VALUES
    (1, 'REC-001', '0.05,-0.06,0.03,-0.04'),
    (2, 'REC-002', '0.1,-0.02,0.06,0.02'),
    (3, 'REC-003', '0.15,0.02,0.09,0.08'),
    (4, 'REC-004', '0.2,0.06,0,0.14'),
    (5, 'REC-005 (ring)', '1.4,0.9,1.1,1.2'),
    (6, 'REC-006', '0.05,0.14,0.06,-0.1'),
    (7, 'REC-007', '0.1,-0.1,0.09,-0.04'),
    (8, 'REC-008', '0.15,-0.06,0,0.02'),
    (9, 'REC-009', '0.2,-0.02,0.03,0.08'),
    (10, 'REC-010', '0,0.02,0.06,0.14'),
    (11, 'REC-011', '0.05,0.06,0.09,0.2'),
    (12, 'REC-012', '0.1,0.1,0,-0.1'),
    (13, 'REC-013 (ring)', '1.4,0.9,1.1,1.2'),
    (14, 'REC-014', '0.2,-0.1,0.06,0.02'),
    (15, 'REC-015', '0,-0.06,0.09,0.08'),
    (16, 'REC-016', '0.05,-0.02,0,0.14'),
    (17, 'REC-017', '0.1,0.02,0.03,0.2'),
    (18, 'REC-018', '0.15,0.06,0.06,-0.1'),
    (19, 'REC-019', '0.2,0.1,0.09,-0.04'),
    (20, 'REC-020', '0,0.14,0,0.02'),
    (21, 'REC-021', '0.05,-0.1,0.03,0.08'),
    (22, 'REC-022 (ring)', '1.4,0.9,1.1,1.2'),
    (23, 'REC-023', '0.15,-0.02,0.09,0.2'),
    (24, 'REC-024', '0.2,0.02,0,-0.1'),
    (25, 'REC-025', '0,0.06,0.03,-0.04'),
    (26, 'REC-026', '0.05,0.1,0.06,0.02'),
    (27, 'REC-027', '0.1,0.14,0.09,0.08'),
    (28, 'REC-028', '0.15,-0.1,0,0.14'),
    (29, 'REC-029', '0.2,-0.06,0.03,0.2'),
    (30, 'REC-030', '0,-0.02,0.06,-0.1');
DROP TABLE IF EXISTS crd_traj;
CREATE TABLE crd_traj AS
WITH tr AS (SELECT fractal_search_trajectory(
                    'crd_records', 'vec',
                    '0.05,0,0.03,0',    -- baseline
                    '1.4,0.9,1.1,1.2',    -- current
                    5) AS tj)
SELECT row_number() OVER (ORDER BY json_extract(je.value, '$.distance'), w.id) AS rk, w.id, w.label AS label,
       round(json_extract(je.value, '$.distance'), 4) AS distance
FROM tr, json_each(tr.tj) je
JOIN crd_records w ON w.id - 1 = json_extract(je.value, '$.doc_id');

SELECT rk, id, label, distance FROM crd_traj ORDER BY rk;

.print
.print === 4. Event-location topology: organic vs staged ring ===
DROP TABLE IF EXISTS crd_locations;
CREATE TABLE crd_locations (
    ent TEXT,
    pt  INTEGER,
    x   REAL,
    y   REAL
);
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 200),
     s(ent, p1) AS (VALUES
         ('organic-records', 1),
         ('staged-ring', 0))
INSERT INTO crd_locations (ent, pt, x, y)
SELECT ent, g, ((g * 37) % 100) / 100.0, CASE WHEN p1 = 1 THEN ((g * 61) % 100) / 100.0 ELSE ((g * 37) % 100) / 200.0 + 0.002 * (g % 5) END
FROM s, gs;
DROP TABLE IF EXISTS crd_dim;
CREATE TABLE crd_dim AS
SELECT ent, round(fractal_dimension_boxcount(
         (SELECT '[' || group_concat(printf('%.4f,%.4f', x, y), ',') || ']'
            FROM (SELECT x, y FROM crd_locations p2 WHERE p2.ent = e.ent ORDER BY pt)), 2), 3) AS dim
FROM (SELECT DISTINCT ent FROM crd_locations) e
ORDER BY ent;

SELECT ent, dim FROM crd_dim ORDER BY ent;

.print
.print === 5. Reasoning: referral ===
SELECT fractal_reason(
    'one-line referral for the suspected staged-event ring',
    json_object('held_record', (SELECT label FROM crd_screen WHERE id = 1), 'ring_records_found', (SELECT count(*) FROM crd_traj WHERE distance < 0.001), 'ring_dimension', (SELECT dim FROM crd_dim WHERE ent = 'staged-ring'))) AS narrative;

.print
.print === 6. Headline check ===
SELECT 'HEADLINE kit=coordinated-record-detection ' || CASE WHEN (SELECT intercepted FROM crd_screen WHERE id = 1) = 1 AND (SELECT intercepted FROM crd_screen WHERE id = 2) = 0 AND (SELECT intercepted FROM crd_screen WHERE id = 4) = 1 AND (SELECT count(*) FROM crd_traj WHERE distance < 0.001) >= 3 AND (SELECT dim FROM crd_dim WHERE ent = 'staged-ring') + 0.3 < (SELECT dim FROM crd_dim WHERE ent = 'organic-records') THEN 'ok' ELSE 'MISS' END AS headline;

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE crd_known; DROP TABLE crd_proposed; DROP TABLE crd_screen; DROP TABLE crd_records; DROP TABLE crd_traj; DROP TABLE crd_locations; DROP TABLE crd_dim;
