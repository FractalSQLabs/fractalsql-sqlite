-- demo/demo-business-intelligence.sql
--
-- A business-intelligence walkthrough, not just a text-to-sql
-- walkthrough: ask a plain-English business question, generate SQL,
-- EXECUTE it, and feed the real result back into fractal_reason() for
-- a narrative answer -- the loop demo-text-to-sql.sql deliberately
-- stops short of (execution is always a separate, explicit, caller-
-- side step -- see ../docs/text-to-sql-setup.md). Also covers the
-- other half of the product: Sniper Search to define a target
-- customer archetype, and Scout Discovery to find and name real
-- customer segments -- general data reasoning, not single-query
-- translation.
--
-- The synthetic data below has real patterns baked into it on
-- purpose (a revenue dip, five RFM-style customer segments) so the
-- reasoning sections below have something genuine to discover, not
-- just a number to restate -- same trick demo.sql's alert table uses.
--
-- Prerequisites: extension installed, reasoning configured -- see
-- ../docs/reasoning-setup.md and confirm with:
--   SELECT fractal_reason('reply with a short confirmation that this connection works');
-- before running this script.
--
-- API surface notes:
--   * SQLite has no procedural exception-handling construct, so
--     generation results land in a TEMP staging table instead of a
--     safe-wrapper function: on the retry-budget-exhausted path (a
--     real, expected outcome for a weaker model or an ambiguous
--     question -- it raises, aborting that statement), the staging
--     INSERT fails with the clean error and the staging table simply
--     stays empty; every later step reads the staging table and
--     spools empty, i.e. no-ops, instead of cascading into later steps.
--   * The generated SQL is executed with the CLI's .once/.read spool
--     trick (keep .timer OFF around the .once SELECTs). Spool files
--     land in the current directory, overwritten each run.
--   * fractal_search_debug(query, iterations[, population_size,
--     diffusion_factor]) is the tunable abstract-space Sniper form
--     (the two-argument fractal_search(vector, query) is the per-row
--     form over a stored column). The result is one JSON document;
--     the ideal point is its $.best_point.
--   * Scout Discovery is the AGGREGATE fractal_search_explore(col,
--     query, params) over your own column, returning one JSON
--     document whose $.population key holds the particles.
--
-- Safe to re-run: the schema is dropped and recreated at the top.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Schema + seed data. 18 months of orders across 60 customers,
-- with two patterns deliberately built in:
--   - a real revenue dip 4 months back (a supply issue, say) --
--     something for Section 3 to find.
--   - five RFM (recency/frequency/monetary) customer archetypes,
--     spread across SFS's [-1,1] operating box with enough margin
--     that Scout can actually tell them apart -- see benchmark.sql's
--     own comment on why narrow clustering silently understates
--     Scout's real result.
-- ------------------------------------------------------------------
.print
.print === 1. Schema + 18 months of order history, 60 customers ===

DROP TABLE IF EXISTS bi_customer_features;
DROP TABLE IF EXISTS bi_orders;
DROP TABLE IF EXISTS bi_customers;
DROP TABLE IF EXISTS bi_archetypes;

CREATE TABLE bi_customers (
    id       INTEGER PRIMARY KEY,
    name     TEXT NOT NULL,
    segment  TEXT NOT NULL,  -- ground truth, for narrating results below -- not fed to Scout/Sniper
    status   TEXT NOT NULL DEFAULT 'active'
);

CREATE TABLE bi_orders (
    id            INTEGER PRIMARY KEY,
    customer_id   INTEGER NOT NULL REFERENCES bi_customers(id),
    total_cents   INTEGER NOT NULL,
    placed_at     TEXT NOT NULL
);

-- Five RFM archetypes: (recency, frequency, monetary), each roughly
-- in [-0.8, 0.8] -- comfortably inside the [-1,1] box with margin for
-- per-customer noise. -1 recency = very recent/good; +1 frequency/
-- monetary = high/good (recency is inverted: -1 is the "good" end).
CREATE TABLE bi_archetypes (segment TEXT PRIMARY KEY, r REAL, f REAL, m REAL, n_customers INTEGER);
INSERT INTO bi_archetypes (segment, r, f, m, n_customers) VALUES
    ('Champions',        -0.7,  0.7,  0.7, 14),
    ('At-Risk',           0.6,  0.5,  0.6, 10),
    ('New & Exploring',  -0.6, -0.6, -0.5, 12),
    ('Lost',               0.7, -0.7, -0.6, 14),
    ('Loyal & Modest',   -0.3,  0.4, -0.2, 10);

-- Numbered customer names across all five segments (a recursive CTE
-- expands each archetype to its row count, then row_number() seeds
-- unique names):
INSERT INTO bi_customers (name, segment)
WITH RECURSIVE
expand(segment, r, f, m, n_customers, n) AS (
    SELECT segment, r, f, m, n_customers, 1 FROM bi_archetypes
    UNION ALL
    SELECT segment, r, f, m, n_customers, n + 1
      FROM expand WHERE n < n_customers
)
SELECT 'customer_' || row_number() OVER (ORDER BY segment, n), segment
FROM expand;

CREATE TABLE bi_customer_features (customer_id INTEGER PRIMARY KEY REFERENCES bi_customers(id), feature_vec TEXT);

-- Feature vectors as CSV TEXT -- one 3-dim (recency, frequency,
-- monetary) vector per customer, archetype + noise. (random() is a
-- signed 64-bit INTEGER: dividing by 2^63 maps it into [-1,1).)
INSERT INTO bi_customer_features (customer_id, feature_vec)
SELECT c.id,
       (a.r + 0.075 * random() / 9223372036854775808.0) || ',' ||
       (a.f + 0.075 * random() / 9223372036854775808.0) || ',' ||
       (a.m + 0.075 * random() / 9223372036854775808.0)
FROM bi_customers c
JOIN bi_archetypes a ON a.segment = c.segment;

-- Order history: order count/value roughly follows each customer's
-- own frequency/monetary features, so the two tables tell a
-- consistent story. Month 4 (of 18, counting back from today) gets a
-- deliberate ~40% revenue dip across every segment -- 4 months back
-- comfortably inside any "last 6 months" trend question regardless of
-- what today's actual date is when this script runs, unlike a fixed
-- calendar month would be.
WITH RECURSIVE months(month_offset) AS (
    SELECT 1 UNION ALL SELECT month_offset + 1 FROM months WHERE month_offset < 18
)
INSERT INTO bi_orders (customer_id, total_cents, placed_at)
SELECT c.id,
       CAST((3000 + (ABS(random()) % 12000))
              * CASE WHEN mo.month_offset = 4 THEN 0.6 ELSE 1.0 END AS INTEGER),
       datetime('now', '-' || mo.month_offset || ' months',
                        '+' || (ABS(random()) % 25) || ' days')
FROM bi_customers c
JOIN bi_archetypes a ON a.segment = c.segment
CROSS JOIN months mo
-- order count per customer per month scales with their frequency
-- feature (a.f): high-frequency customers order most months,
-- low-frequency customers order occasionally.
WHERE ((random() / 9223372036854775808.0) + 1) / 2
        < (0.15 + 0.5 * ((a.f + 1) / 2));

.print
.print Seed data:
SELECT (SELECT count(*) FROM bi_customers) AS customers,
       (SELECT count(*) FROM bi_orders) AS orders,
       printf('$%,.2f', (SELECT sum(total_cents) / 100.0 FROM bi_orders)) AS total_revenue;

-- ------------------------------------------------------------------
-- 2. Simple fact lookup: generate -> execute -> show the raw result.
-- No reasoning yet -- this section is the loop's first half only, to
-- show what "generate then execute" looks like plainly before adding
-- interpretation on top of it in Section 3.
-- ------------------------------------------------------------------
.print
.print === 2. Simple fact lookup: generate, then execute ===

CREATE TEMP TABLE bi_gen (sql_text TEXT);
DELETE FROM bi_gen;
-- On generation failure this INSERT is the one thing that errors
-- (with the clean reason/limit message) and bi_gen stays empty --
-- every step after reads an empty staging table and spools a no-op.
INSERT INTO bi_gen (sql_text)
SELECT fractal_text_to_sql('how many customers do we have and what is our total revenue?');

.print Generated:
SELECT sql_text AS generated_sql FROM bi_gen;
.print

.timer off
.once bi_generated.sql
SELECT sql_text FROM bi_gen;
.read bi_generated.sql
.timer on

.print
.print Worth noticing: if the customer count above is lower than the 60
.print from the seed summary in Section 1, the model chose an INNER JOIN
.print between customers and orders -- quietly narrowing the question
.print from ALL customers to CUSTOMERS WITH ORDERS. Not wrong, exactly,
.print but a real example of why fractal_text_to_sql() never
.print auto-executes: the SQL is always worth reading, not just
.print trusting the English question implies.

-- ------------------------------------------------------------------
-- 3. The full BI loop: generate -> execute -> reason over the REAL
-- result. This is the part demo-text-to-sql.sql deliberately never
-- does. The question is designed to surface the month-4 dip baked
-- into the data above -- fractal_reason() sees the actual monthly
-- numbers, not a hint that a dip exists. Explicitly excluding the
-- current (in-progress) month, not just "last 6 months" -- otherwise
-- whatever partial month is running when this script executes always
-- looks like a fake dip, which would be a real and common BI
-- reporting mistake to bake into a demo unremarked.
-- ------------------------------------------------------------------
.print
.print === 3. The full loop: generate, execute, then reason over the real result ===

DELETE FROM bi_gen;
INSERT INTO bi_gen (sql_text)
SELECT fractal_text_to_sql('show total revenue for each of the 6 most recent FULLY COMPLETED calendar months, excluding the current in-progress month, oldest first');

.print Generated:
SELECT sql_text AS trend_sql FROM bi_gen;

-- Result materialized by spooling the candidate wrapped in CREATE
-- TEMP TABLE AS (no dynamic SQL in SQLite; empty staging -> empty
-- spool -> no-op .read -> bi_trend_result stays the empty placeholder
-- below, so Section 4 keeps a defined shape):
DROP TABLE IF EXISTS bi_trend_result;
CREATE TEMP TABLE bi_trend_result (month TEXT, total_revenue NUMERIC);

.timer off
.once bi_trend.sql
SELECT 'CREATE TEMP TABLE IF NOT EXISTS bi_trend_result AS ' || sql_text || ';'
  FROM bi_gen;
.read bi_trend.sql
.timer on

.print
.print Executed -- real result:
SELECT * FROM bi_trend_result;

.print
.print Reasoning over the actual result (not the question, the DATA):
SELECT fractal_reason(
    'this is our last 6 months of revenue by month -- what happened, and does it need attention?',
    (SELECT json_group_array(json_object('month', month, 'total_revenue', total_revenue))
       FROM bi_trend_result)
);

-- ------------------------------------------------------------------
-- 4. General data reasoning: synthesize across SEVERAL facts in one
-- call, not translate one question into one query. This is the
-- capability text-to-sql alone can't offer -- a single SQL statement
-- can't hold "here's the trend AND the segment mix AND the churn
-- signal, now tell me what's really going on."
-- ------------------------------------------------------------------
.print
.print === 4. General reasoning: synthesize multiple facts into one narrative ===

SELECT fractal_reason(
    'given revenue trend, customer segment mix, and status breakdown together, what is the state of the business and what would you look into first?',
    json_object(
        'monthly_revenue',  (SELECT json_group_array(json_object('month', month, 'total_revenue', total_revenue))
                               FROM bi_trend_result),
        'segment_mix',      (SELECT json_group_array(json_object('segment', segment, 'customers', customers))
                               FROM (SELECT segment, count(*) AS customers FROM bi_customers GROUP BY segment ORDER BY segment)),
        'status_breakdown', (SELECT json_group_array(json_object('status', status, 'customers', customers))
                               FROM (SELECT status, count(*) AS customers FROM bi_customers GROUP BY status))
    )
);

-- ------------------------------------------------------------------
-- 5. Sniper Search: converge toward a TARGET customer archetype.
-- Not a lookup against real customers -- SFS refines toward the
-- mathematically ideal point matching the query direction, useful for
-- "what would our best-possible customer profile look like" before
-- you go find (or build toward) one.
-- ------------------------------------------------------------------
.print
.print === 5. Sniper Search: converge toward an ideal-customer profile ===
.print Query: recent + frequent + high-value (a Champions-shaped target)
.print (fractal_search_debug(query, iterations) is the abstract-space
.print Sniper form; the ideal point is its $.best_point key.)
SELECT json_extract(
           fractal_search_debug('-0.7,0.7,0.7', 50),
           '$.best_point') AS ideal_profile;

.print
.print Notice the ratio between components matches the query direction,
.print but the exact magnitude varies run to run (sometimes near the
.print [-1,1] box edges, sometimes a scaled-down interior point) -- cosine
.print similarity (what Sniper optimizes for) is scale-invariant, so
.print every point along the same ray as the query scores identically.
.print SFS has no pressure to pick one particular point on that ray over
.print another, only to find the right ray. Read this as a DIRECTION to
.print aim for, not a literal target coordinate.

-- ------------------------------------------------------------------
-- 6. Scout Discovery: find real, DIVERSE customer segments from the
-- actual stored feature vectors -- then have fractal_reason() name
-- them in business language. This is the same anti-mode-collapse
-- property benchmark.sql measures numerically, applied to an actual
-- business question: "what kinds of customers do we actually have?"
-- ------------------------------------------------------------------
.print
.print === 6. Scout Discovery: find and name real customer segments ===

DROP TABLE IF EXISTS bi_scout_result;
CREATE TEMP TABLE bi_scout_result (particle_id INTEGER, feature_vec TEXT);
-- (The explore query is a small nonzero point, NOT the origin -- cosine
-- is undefined for a zero vector, the same adversarial case
-- benchmark.sql's comment documents.)
INSERT INTO bi_scout_result (particle_id, feature_vec)
SELECT row_number() OVER (), je.value
  FROM (SELECT fractal_search_explore(feature_vec, '0.2,0.2,0.2',
                               '{"population_size": 8, "iterations": 10, "walk": 0}') AS res
          FROM bi_customer_features) s,
       json_each(s.res, '$.population') je;

.print Scout found a diverse population (recency, frequency, monetary):
.print the particles concentrate near the most query-relevant archetypes
.print and throw the odd outlier -- the same population the naming step
.print below turns into business language.
SELECT * FROM bi_scout_result;

.print
.print Naming the segments Scout actually found, in business language:
SELECT fractal_reason(
    'each item is a (recency, frequency, monetary) customer profile in [-1,1], where recency -1 is very recent, frequency/monetary +1 is high. Name and describe each distinct segment in one line.',
    (SELECT json_group_array(feature_vec) FROM bi_scout_result)
);

.print
.print ================================================================
.print Demo complete. Tables left in place for inspection. Clean up with:
.print   DROP TABLE bi_customer_features, bi_orders, bi_customers;
.print (the bi_* TEMP tables and the bi_generated.sql / bi_trend.sql
.print spool files evaporate with the connection / live in the current
.print directory, overwritten each run.)
.print ================================================================