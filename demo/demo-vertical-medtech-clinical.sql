-- demo/demo-vertical-medtech-clinical.sql
--
-- Industry vertical: MedTech, Clinical Telemetry & Patient Monitoring.
--
-- Synthetic patient vitals + telemetry (cohort-filtered search, current-
-- vs-baseline drift) plus the four domain-specific geometry functions on
-- small, pre-extracted geometric fixtures (a vessel graph, a triangulated
-- mesh, a nerve fiber skeleton) -- these take PRE-EXTRACTED geometry, not
-- raw imaging data (see fractal_vascular_network/_cortical_folding/
-- _nerve_plexus_metric's own doc comments for that scope boundary).
--
-- Prerequisites: extension loaded (sections 0-6 need nothing else).
-- Section 3's rationale call needs the reasoning plugin -- see
-- ../docs/reasoning-setup.md (per-connection fractalsql_set state, so
-- re-apply your load_fractalsql.sql snippet with -init).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-medtech-clinical.sql"
--
-- Notes:
--   * There is no seedable global RNG -- the fixture's noise is plain
--     random() (a signed 64-bit integer here, mapped into [-1,1) with
--     /2^63), so the noise pattern differs run to run; every analysis
--     output stays structurally identical.
--   * Vitals are CSV TEXT guarded by a
--     CHECK(fractal_vector_dims(...) = 5) constraint:
--     [hr_z, spo2_z, systolic_z, diastolic_z, temp_z] is a fixed,
--     known-width vector where dimension-drift protection actually
--     matters clinically -- a malformed vitals write (wrong field
--     count from an upstream monitor integration) still raises loudly
--     at write time, not silently corrupting a patient record.
--   * The fractal_agent_* preset is a blueprint composition over the
--     primitives (see demo-agents.sql for the pattern).
--   * doc_id is the row's 0-based position in the search's own scan
--     order, and in SQLite that order IS rowid order (UPDATE keeps a
--     rowid table's physical position on UPDATE);
--     vmc_patients' rowid aliases its INTEGER PRIMARY KEY id, so doc_id
--     = id - 1 exactly, stable across the section-1 cohort-force UPDATE.
--
-- Safe to re-run: the vmc_* tables are dropped and recreated each time
-- (the TEMP tables evaporate with the connection).

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 40 synthetic patients with a demographic/condition cohort and a
-- 5-dim current-vitals vector (heart rate, SpO2, systolic, diastolic,
-- temperature, each roughly normalized). One flagged "sepsis-watch"
-- cohort (age > 65 AND condition = 'sepsis') for Sections 2-3.
-- ------------------------------------------------------------------
.print
.print === 1. 40 synthetic patients: demographics + current vitals ===

DROP TABLE IF EXISTS vmc_patients;
CREATE TABLE vmc_patients (
    id        INTEGER PRIMARY KEY,
    age       INTEGER,
    condition TEXT,
    vitals    TEXT NOT NULL
              CHECK (fractal_vector_dims(vitals) = 5)
);

-- Two independent random() draws per row drive the condition mix
-- (0.2/0.4 thresholds); the vitals vector is five more.
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 40)
INSERT INTO vmc_patients (age, condition, vitals)
SELECT
    22 + CAST((random() / 9223372036854775808.0 + 1) / 2 * 68 AS INTEGER),
    CASE WHEN (random() / 9223372036854775808.0 + 1) / 2 < 0.2 THEN 'sepsis'
         WHEN (random() / 9223372036854775808.0 + 1) / 2 < 0.4 THEN 'post-op'
         ELSE 'routine' END,
    printf('%.4f,%.4f,%.4f,%.4f,%.4f',
           random() / 9223372036854775808.0,
           random() / 9223372036854775808.0,
           random() / 9223372036854775808.0,
           random() / 9223372036854775808.0,
           random() / 9223372036854775808.0)
FROM gs;

-- Force at least a few real hits in the cohort filter below, deterministically.
UPDATE vmc_patients SET age = 70, condition = 'sepsis'
 WHERE id IN (3, 11, 27);

-- ------------------------------------------------------------------
-- 2. fractal_hybrid_clinical_search: cohort-restricted search
-- (cohort = age > 65 AND condition = sepsis, computed with ordinary SQL
-- -- never a raw SQL predicate string, see that function's own doc
-- comment). The cohort is the CSV of the matching rows' 0-based scan
-- positions -- id - 1 exactly, since the rowid aliases the INTEGER
-- PRIMARY KEY (a row_number() over the FILTERED set would renumber
-- from 0 and silently widen the cohort -- the classic mistake here).
-- ------------------------------------------------------------------
.print
.print === 2. Cohort-restricted search: the sepsis-watch cohort ===

WITH hs AS (SELECT fractal_hybrid_clinical_search(
                    'vmc_patients', 'vitals', '1,-1,1,1,0.5',
                    (SELECT group_concat(id - 1, ',') FROM vmc_patients
                      WHERE age > 65 AND condition = 'sepsis'), 5) AS rj)
SELECT p.id          AS patient_id,
       p.condition   AS condition,
       json_extract(je.value, '$.distance') AS distance
FROM hs, json_each(hs.rj) je
JOIN vmc_patients p ON p.id - 1 = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- ------------------------------------------------------------------
-- 3. fractal_search_trajectory: one patient's CURRENT vitals vs their
-- own admission BASELINE -- "what changed", the natural query shape
-- for drift/trajectory monitoring (this function's own doc comment
-- uses this exact patient-baseline example). The vectors are plain
-- text here, so the primitives resolve them directly -- no unpack
-- step.
-- ------------------------------------------------------------------
.print
.print === 3. Patient drift from admission baseline (fractal_search_trajectory) ===

WITH tr AS (SELECT fractal_search_trajectory(
                    'vmc_patients', 'vitals',
                    '0.1,0.05,0.0,0.0,0.0',   -- admission baseline
                    '1.4,-1.1,0.9,0.7,1.2',   -- current (deteriorating)
                    5) AS tj)
SELECT p.id, p.condition, json_extract(je.value, '$.distance') AS distance
FROM tr, json_each(tr.tj) je
JOIN vmc_patients p ON p.id - 1 = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- patient_deterioration_triage composition: the cohort-restricted hybrid
-- search (nearest sepsis-watch cohort patient to the query vitals) and
-- the baseline->current drift search, then a reasoning pass
-- (plugin-gated: the clean hint is the expected output without one).
-- nearest_cohort_id/cohort_distance/drift_distance are real; the cohort
-- is caller-built from age>65 AND condition='sepsis' (the two-predicate
-- cohort a single filter pair can't express).
.print --- deterioration_triage composition (hybrid + trajectory + reason) ---
WITH cohort AS (SELECT group_concat(id - 1, ',') AS ids
                  FROM vmc_patients
                 WHERE age > 65 AND condition = 'sepsis'),
     hs AS (SELECT fractal_hybrid_clinical_search(
                    'vmc_patients', 'vitals', '1,-1,1,1,0.5',
                    (SELECT ids FROM cohort), 5) AS rj),
     tr AS (SELECT fractal_search_trajectory(
                    'vmc_patients', 'vitals',
                    '0.1,0.05,0.0,0.0,0.0', '1.4,-1.1,0.9,0.7,1.2', 5) AS tj)
SELECT (SELECT p.id FROM hs, json_each(hs.rj) je
         JOIN vmc_patients p ON p.id - 1 = json_extract(je.value, '$.doc_id')
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS nearest_cohort_id,
       (SELECT json_extract(je.value, '$.distance') FROM hs, json_each(hs.rj) je
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS cohort_distance,
       (SELECT json_extract(je.value, '$.distance') FROM tr, json_each(tr.tj) je
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS drift_distance,
       (SELECT count(*) FROM vmc_patients
         WHERE age > 65 AND condition = 'sepsis') AS cohort_matches;
SELECT fractal_reason('one-line deterioration-triage rationale for this patient cohort scan');

-- ------------------------------------------------------------------
-- 4. fractal_vascular_network: a branching vessel graph -- a 28-node
-- centerline chain plus 2 branch leaves off node 10, node_coords in 3D
-- with real arc lengths from an upstream centerline trace. Needs >= 8
-- nodes AND enough of them for the internal box-counting dimension
-- estimator to find >= 3 valid eps-octaves (its own documented
-- "avg >= 3 points/occupied-cell" validity filter, same one
-- fractalsql-core's own boxcount unit tests calibrate against) -- a
-- too-small skeleton returns rc=-1, not a wrong number. The C side
-- validates the cross-product: arc-length count must equal edge count
-- exactly (29 edges here). (Recursive CTEs build the fixture.)
-- ------------------------------------------------------------------
.print
.print === 4. Vessel tortuosity/branch-density/dimension (fractal_vascular_network) ===

DROP TABLE IF EXISTS vmc_vessel;
CREATE TEMP TABLE vmc_vessel AS
WITH RECURSIVE gs(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM gs WHERE i < 27)
SELECT (SELECT group_concat(printf('%.1f,0,0', i), ',') FROM gs) || ',10,1,0,10,0,1'
           AS nodes,
       (SELECT group_concat(printf('%d,%d', i, i + 1), ',') FROM gs WHERE i < 27)
           || ',10,28,10,29' AS edges,
       (WITH ls(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM ls WHERE i < 28)
          SELECT group_concat('1.02', ',') FROM ls) AS arcs;

SELECT fractal_vascular_network(nodes, edges, arcs) FROM vmc_vessel;

-- ------------------------------------------------------------------
-- 5. fractal_cortical_folding: a unit-cube surface mesh (8 vertices,
-- 12 triangular faces) -- a "smooth" (unfolded) reference case where
-- mesh area should closely match hull area (GI ~1.0), the same known-
-- answer sanity check fractalsql-core's own cortical.c unit tests use.
-- ------------------------------------------------------------------
.print
.print === 5. Gyrification Index on a reference mesh (fractal_cortical_folding) ===

SELECT fractal_cortical_folding(
    '0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1',
    '0,1,2, 0,2,3, 4,5,6, 4,6,7, 0,1,5, 0,5,4,
     3,2,6, 3,6,7, 0,3,7, 0,7,4, 1,2,6, 1,6,5') AS gyrification_index;

-- ------------------------------------------------------------------
-- 6. fractal_nerve_plexus_metric: an 80-fiber zigzag skeleton (corneal
-- confocal microscopy convention -- fiber length density, branch
-- density, box-counting dimension). Same box-counting-scale note as
-- Section 4 above -- 80 points is comfortably past the internal
-- estimator's minimum for a reliable answer.
-- ------------------------------------------------------------------
.print
.print === 6. Corneal nerve fiber plexus (fractal_nerve_plexus_metric) ===

DROP TABLE IF EXISTS vmc_nerve;
CREATE TEMP TABLE vmc_nerve AS
WITH RECURSIVE gs(i) AS (SELECT 0 UNION ALL SELECT i + 1 FROM gs WHERE i < 79)
SELECT (SELECT group_concat(printf('%.2f,%.2f', i, 0.05 * sin(i)), ',')
          FROM gs WHERE i < 80) AS coords,
       (SELECT group_concat(printf('%d,%d', i, i + 1), ',') FROM gs WHERE i < 79)
           AS edges;

SELECT fractal_nerve_plexus_metric(coords, 2, edges) FROM vmc_nerve;

-- ------------------------------------------------------------------
-- 7. Reasoning: the cohort-search + trajectory-drift clinical narrative
-- is carried by the deterioration_triage composition's rationale in
-- Section 3. The vessel/cortical/nerve geometry primitives in Sections
-- 4-6 stay raw (domain geometry with no engine home) -- their own
-- output columns are the showcase.
-- ------------------------------------------------------------------
.print
.print === 7. Reasoning: carried by the deterioration_triage composition rationale ===

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vmc_patients;
.print (the vmc_* TEMP tables evaporate with the connection.)
.print ================================================================