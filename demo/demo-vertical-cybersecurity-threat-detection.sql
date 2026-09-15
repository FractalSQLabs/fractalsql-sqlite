-- demo/demo-vertical-cybersecurity-threat-detection.sql
--
-- Industry vertical: Cybersecurity & Threat Detection (network behavior
-- analytics / SOC log analysis).
--
-- A 35-host fleet across three network zones, each with a BASELINE
-- traffic-behavior vector and a CURRENT (recent window) vector. One
-- host goes quiet-then-beacons: a compromise pattern (outbound
-- connection volume, unique destination ports, and DNS query rate all
-- spike; failed-auth rate barely moves -- this isn't a brute-force
-- attempt, it's a stealthier C2 beaconing profile). Diverse
-- traffic-profile clustering for threat hunting, a zone-restricted
-- search, current-vs-baseline drift detection, and connection-rate
-- regime-change detection via DFA.
--
-- Prerequisites: extension loaded (sections 0-4 need nothing else).
-- Section 5's rationale calls need the reasoning plugin -- see
-- ../docs/reasoning-setup.md (per-connection fractalsql_set state, so
-- re-apply your load_fractalsql.sql snippet with -init).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-cybersecurity-threat-detection.sql"
--
-- Notes:
--   * There is no seedable global RNG -- the fixture's noise is plain
--     random() (a signed 64-bit integer here, mapped into [-1,1) with
--     /2^63), so the noise pattern differs run to run; every analysis
--     output stays structurally identical.
--   * Vector columns are CSV TEXT guarded by a
--     CHECK(fractal_vector_dims(...) = 4) constraint: a feature-
--     extraction bug that silently changed the vector's width is
--     still a hard write-time error.
--   * The fractal_agent_* presets are blueprint compositions over the
--     primitives (see demo-agents.sql for the pattern).
--   * doc_id is the row's 0-based position in the search's own scan
--     order, and in SQLite that order IS rowid order (UPDATE keeps a
--     rowid table's physical position on UPDATE);
--     vcy_hosts' rowid aliases its INTEGER PRIMARY KEY id, so doc_id =
--     id - 1 exactly, stable across the section-1 UPDATE.
--
-- Safe to re-run: vcy_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. 35 hosts across 3 zones (dmz, internal, guest), each with a
-- BASELINE behavior vector (normal traffic profile) and a CURRENT
-- vector (this window's telemetry). Fields, in order:
-- [outbound_conn_rate, unique_dest_ports, dns_query_rate,
-- failed_auth_rate], each normalized to roughly [-1, 1]. Host 7 gets
-- a deliberate compromise pattern -- everyone else's current stays
-- close to baseline (ordinary traffic noise).
-- ------------------------------------------------------------------
.print
.print === 1. 35 hosts: baseline vs. current network-behavior vectors ===

DROP TABLE IF EXISTS vcy_hosts;
CREATE TABLE vcy_hosts (
    id        INTEGER PRIMARY KEY,
    hostname  TEXT,
    zone      TEXT,
    baseline  TEXT NOT NULL
              CHECK (fractal_vector_dims(baseline) = 4),
    current   TEXT NOT NULL
              CHECK (fractal_vector_dims(current) = 4)
);

-- Baselines are four random components per host; current is the same
-- shape plus ordinary traffic noise (each random() reference evaluates
-- per row, so the two vectors are independent draws where they should
-- be). Host 7's current is overwritten by the deliberate-compromise
-- UPDATE right below.
INSERT INTO vcy_hosts (hostname, zone, baseline, current)
WITH RECURSIVE gs(g) AS (SELECT 1 UNION ALL SELECT g + 1 FROM gs WHERE g < 35)
SELECT 'HOST-' || g,
       CASE (g - 1) % 3 WHEN 0 THEN 'dmz' WHEN 1 THEN 'internal' ELSE 'guest' END,
       '[' || printf('%.4f,%.4f,%.4f,%.4f', b1, b2, b3, b4) || ']',
       '[' || printf('%.4f,%.4f,%.4f,%.4f',
                     b1 + (random() / 9223372036854775808.0 - 0.5) * 0.06,
                     b2 + (random() / 9223372036854775808.0 - 0.5) * 0.06,
                     b3 + (random() / 9223372036854775808.0 - 0.5) * 0.06,
                     b4 + (random() / 9223372036854775808.0 - 0.5) * 0.06) || ']'
FROM (SELECT g,
             random() / 9223372036854775808.0 AS b1,
             random() / 9223372036854775808.0 AS b2,
             random() / 9223372036854775808.0 AS b3,
             random() / 9223372036854775808.0 AS b4
        FROM gs);

-- Host 7's deliberate compromise: outbound connections, destination
-- ports, and DNS query volume all spike; failed-auth barely moves.
UPDATE vcy_hosts
   SET current = printf('[%.4f,%.4f,%.4f,%.4f]',
                        json_extract(baseline, '$[0]') + 0.8,
                        json_extract(baseline, '$[1]') + 0.7,
                        json_extract(baseline, '$[2]') + 0.6,
                        json_extract(baseline, '$[3]') + 0.05)
 WHERE id = 7;

-- ------------------------------------------------------------------
-- 2. Scout Discovery: diverse traffic-profile clustering across the
-- fleet -- threat hunting ("what KINDS of behavior profiles are
-- actually running right now") instead of cosine top-K, which would
-- just return 6 near-duplicates of whichever profile is most common
-- and miss the one host that looks different.
-- ------------------------------------------------------------------
.print
.print === 2. Diverse traffic-profile clustering (threat hunting) ===
.print --- raw explore form (query-agnostic -- explore samples the space) ---
WITH e AS (SELECT fractal_search_explore(current, '0,0.2,0,0',
                                  '{"population_size": 6, "iterations": 8, "walk": 0}') AS res
             FROM vcy_hosts)
SELECT value AS particle
  FROM e, json_each(e.res, '$.population');

-- Productized preset (the recommend_diverse composition): real host ids +
-- scores (1 - cosine_distance) with session-global repulsion enabled, then
-- we restore the session so section 3 below sees the same diversify-off
-- state as before (the composition leaves diversify on -- the caller owns
-- that policy). The raw explore above is query-agnostic; the telemetry
-- form is query-anchored, so anchor on the first host's own current
-- vector.
.print --- recommend_diverse composition (query-anchored, repulsion on) ---
WITH t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'vcy_hosts', 'current',
                      (SELECT current FROM vcy_hosts ORDER BY id LIMIT 1), 6)))
SELECT m.id                     AS item_id,
       m.hostname               AS hostname,
       1.0 - t.dist             AS score
FROM t
JOIN (SELECT id, hostname, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM vcy_hosts) m USING (doc_id)
ORDER BY t.dist;
SELECT fractal_diversify_disable();

-- ------------------------------------------------------------------
-- 3. Zone-restricted search: "DMZ hosts only" -- a zone filter composes
-- by searching a filtered temp table (the same cohort-then-search shape
-- fractal_hybrid_clinical_search uses internally for its doc_ids
-- allowlist). doc_id is the row's 0-based position in the search's own
-- scan, which for a rowid table is rowid order -- and vcy_dmz_cohort's
-- rowids are vcy_hosts' ids (INTEGER PRIMARY KEY aliases rowid, SELECT *
-- carries the id), so the row_number mapping below resolves doc_id back
-- to hostname without assuming id - 1.
-- ------------------------------------------------------------------
.print
.print === 3. Zone-restricted search: DMZ hosts only ===

DROP TABLE IF EXISTS vcy_dmz_cohort;
CREATE TEMP TABLE vcy_dmz_cohort AS
SELECT * FROM vcy_hosts WHERE zone = 'dmz';

WITH t AS (SELECT json_extract(value, '$.doc_id')   AS doc_id,
                  json_extract(value, '$.distance') AS dist
             FROM json_each(fractal_search_telemetry(
                      'vcy_dmz_cohort', 'current', '0.3,0.3,0.3,0.0', 5)))
SELECT h.hostname, t.dist AS distance
FROM t
JOIN (SELECT hostname, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM vcy_dmz_cohort) h ON h.doc_id = t.doc_id
ORDER BY t.dist;

-- ------------------------------------------------------------------
-- 4. fractal_search_trajectory: current vs. baseline DELTA for host 7
-- -- "what changed" rather than "what's closest", the direct fit for
-- compromise/beaconing detection. The baseline/current TEXT columns
-- resolve the vector primitives directly.
-- ------------------------------------------------------------------
.print
.print === 4. Host 7 drift vs. the fleet (fractal_search_trajectory) ===

WITH tr AS (SELECT fractal_search_trajectory(
                    'vcy_hosts', 'current',
                    (SELECT baseline FROM vcy_hosts WHERE id = 7),
                    (SELECT current  FROM vcy_hosts WHERE id = 7),
                    5) AS tj)
SELECT h.hostname, h.zone, json_extract(je.value, '$.distance') AS distance
FROM tr, json_each(tr.tj) je
JOIN (SELECT id, hostname, zone, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
        FROM vcy_hosts) h ON h.doc_id = json_extract(je.value, '$.doc_id')
ORDER BY json_extract(je.value, '$.distance');

-- ------------------------------------------------------------------
-- 5. fractal_dimension_dfa / fractal_dimension_drift: host 7's
-- connections-per-minute series over the last 300 minutes, with a
-- deliberate regime change at t=220 -- low-amplitude noisy baseline
-- traffic, then a shift to a regular, higher-frequency beaconing
-- interval. DFA's scaling exponent picks up the change in long-range
-- structure; fractal_dimension_drift makes the same point directly by
-- comparing the tail window against everything before it. (A recursive
-- CTE generates the time index.)
-- ------------------------------------------------------------------
.print
.print === 5. Host 7 connection-rate regime change (DFA + drift) ===

DROP TABLE IF EXISTS vcy_conn_series;
CREATE TEMP TABLE vcy_conn_series AS
WITH RECURSIVE gs(t) AS (SELECT 1 UNION ALL SELECT t + 1 FROM gs WHERE t < 300)
SELECT t,
       CASE WHEN t < 220
            THEN 4.0 + 1.5 * sin(t * 0.31) + (random() / 9223372036854775808.0 - 0.5) * 0.8
            ELSE 4.0 + 3.0 * sin(t * 1.4)  + (random() / 9223372036854775808.0 - 0.5) * 0.4
       END AS conn_rate
FROM gs;

-- Blueprint (raw primitives): the connection-rate series' DFA exponent
-- and its drift report -- the same two halves the composition below folds
-- together with a reasoning step.
WITH s AS (SELECT '[' || group_concat(printf('%.4f', conn_rate) ORDER BY t) || ']' AS sj
             FROM vcy_conn_series)
SELECT fractal_dimension_dfa((SELECT sj FROM s)) AS full_series_dfa_exponent;

WITH s AS (SELECT '[' || group_concat(printf('%.4f', conn_rate) ORDER BY t) || ']' AS sj
             FROM vcy_conn_series)
SELECT fractal_dimension_drift((SELECT sj FROM s), 60) AS recent_60min_vs_history;

-- Composition (1): the regime-triage shape -- real DFA exponent, real
-- drift_detected, real alphas, then a real reasoning pass (plugin-gated:
-- the clean hint is the expected output without one).
.print --- regime_triage composition (dfa + drift + reason) ---
WITH s AS (SELECT '[' || group_concat(printf('%.4f', conn_rate) ORDER BY t) || ']' AS sj
             FROM vcy_conn_series),
d AS (SELECT fractal_dimension_dfa((SELECT sj FROM s)) AS dfa,
             fractal_dimension_drift((SELECT sj FROM s), 64) AS dj)
SELECT d.dfa                                        AS dfa_exponent,
       (abs(json_extract(d.dj, '$.drift')) > 0.5)   AS drift_detected,
       json_extract(d.dj, '$.recent_alpha')         AS recent_alpha,
       json_extract(d.dj, '$.baseline_alpha')       AS baseline_alpha
FROM d;
SELECT fractal_reason('one-line regime triage for this host connection-rate series');

-- Composition (2): the track-anomaly shape -- real nearest fleet host
-- (fractal_search_trajectory over host 7's baseline->current, resolved
-- through the rowid mapping), real trajectory_distance, real
-- connection-rate DFA exponent.
.print --- track_anomaly composition (trajectory + heading DFA) ---
WITH tr AS (SELECT fractal_search_trajectory(
                    'vcy_hosts', 'current',
                    (SELECT baseline FROM vcy_hosts WHERE id = 7),
                    (SELECT current  FROM vcy_hosts WHERE id = 7),
                    5) AS tj),
s AS (SELECT '[' || group_concat(printf('%.4f', conn_rate) ORDER BY t) || ']' AS sj
        FROM vcy_conn_series)
SELECT (SELECT h.id FROM tr, json_each(tr.tj) je
         JOIN (SELECT id, (row_number() OVER (ORDER BY rowid) - 1) AS doc_id
                 FROM vcy_hosts) h ON h.doc_id = json_extract(je.value, '$.doc_id')
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS nearest_fleet_id,
       (SELECT json_extract(je.value, '$.distance') FROM tr, json_each(tr.tj) je
        ORDER BY json_extract(je.value, '$.distance') LIMIT 1) AS trajectory_distance,
       fractal_dimension_dfa((SELECT sj FROM s)) AS dfa_exponent;
SELECT fractal_reason('one-line track-anomaly read for this host');

-- ------------------------------------------------------------------
-- 6. Reasoning: the SOC triage narrative for host 7 is carried by the
-- two composition rationales above (track_anomaly's baseline->current
-- drift + connection-rate DFA, and regime_triage's regime change
-- itself).
-- ------------------------------------------------------------------
.print
.print === 6. Reasoning: carried by the two composition rationales above ===

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE vcy_hosts;
.print (the vcy_* TEMP tables evaporate with the connection.)
.print ================================================================