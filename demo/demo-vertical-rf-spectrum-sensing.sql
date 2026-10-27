-- demo/demo-vertical-rf-spectrum-sensing.sql
--
-- Industry vertical: RF and signal-interference monitoring -- spectrum
-- sensing for telecom operators, spectrum regulators, satellite ground
-- stations and any site that must notice when a carrier, a beacon or a
-- telemetry link loses its structure (interference, jamming, a failing
-- transmitter).  DOMAIN kit showcasing the short-time spectral entropy
-- primitive, fractal_spectrogram_entropy, composed with the periodogram
-- and change-point localization:
--
--   * fractal_periodogram -- WHICH frequencies dominate a whole capture.
--   * fractal_spectrogram_entropy -- HOW ORDERED the spectrum is, window
--     by window: low = energy in a few frequencies (a beacon, a locked
--     carrier), high = spread across the band (noise, jamming).
--   * fractal_change_point_detect -- WHEN the order changed, taken
--     straight from the entropy series (the function returns a bare
--     array, so it feeds the next call as-is).
--
-- Prerequisites: extension loaded.  Everything except the closing
-- fractal_reason() runs with no model at all (raw primitives); the
-- narrative needs the reasoning plugin (clean hint without one; see
-- ../docs/reasoning-setup.md).
--
-- Run (one invocation):
--   sqlite3 -cmd ".load /usr/local/lib/sqlite3/fractalsql" ":memory:" \
--     ".read demo/demo-vertical-rf-spectrum-sensing.sql"
--
-- Notes:
--   * Fully deterministic fixture: noise comes from an integer LCG in a
--     recursive CTE, not random().
--   * Three channels x 256 samples of received level.  CH-A is a beacon
--     (a period-8 tone plus a little noise) that is JAMMED from sample
--     161: the tone is replaced by wideband noise.  CH-B is steady noise
--     (an empty channel).  CH-C is a steady period-16 telemetry carrier.
--   * Calibration: a pure tone reads about 0.2-0.4 after the Hann taper,
--     white noise about 0.9 (a noise periodogram is itself randomly
--     distributed, so it does not reach 1.0).  Window 32 / hop 16 gives
--     15 frames per channel; boundary indices are FRAME indices, so
--     sample position = frame_index * hop.
--
-- Safe to re-run: the rfs_* tables are dropped and recreated each time.

.timer on

.print === 0. Sanity check: extension loaded? ===
SELECT fractalsql_edition(), fractalsql_version();

-- ------------------------------------------------------------------
-- 1. Capture: 3 channels x 256 samples.
-- ------------------------------------------------------------------
.print
.print === 1. Capture: 3 channels x 256 samples ===

DROP TABLE IF EXISTS rfs_capture;
CREATE TABLE rfs_capture (
    channel TEXT,
    seq     INTEGER,
    level   REAL,
    PRIMARY KEY (channel, seq)
);

WITH RECURSIVE n(ch, t, x) AS (
       SELECT 'CH-A', 1, 1001 UNION ALL SELECT 'CH-B', 1, 2002 UNION ALL SELECT 'CH-C', 1, 3003
       UNION ALL
       SELECT ch, t + 1, (x * 1103515245 + 12345) % 2147483648 FROM n WHERE t < 256),
     u AS (SELECT ch, t, (((x / 65536) % 1000) - 500) / 500.0 AS noise FROM n)
INSERT INTO rfs_capture (channel, seq, level)
SELECT ch, t,
       CASE ch
         WHEN 'CH-A' THEN CASE WHEN t <= 160 THEN sin(2 * 3.141592653589793 * t / 8.0) + 0.1 * noise
                               ELSE 1.2 * noise END
         WHEN 'CH-B' THEN 1.2 * noise
         ELSE sin(2 * 3.141592653589793 * t / 16.0) + 0.1 * noise
       END
FROM u;

SELECT channel, count(*) AS samples FROM rfs_capture GROUP BY channel ORDER BY channel;

-- ------------------------------------------------------------------
-- 2. Which frequencies dominate each channel (periodogram).  freq is
-- cycles per sample; 1/freq is samples per cycle.  CH-A is polluted by
-- its jammed second half but still shows the 1/8 beacon; CH-B has no
-- dominant line; CH-C is the 1/16 carrier.
-- ------------------------------------------------------------------
.print
.print === 2. Dominant frequency per channel (fractal_periodogram) ===

SELECT channel,
       round(json_extract(p, '$.freqs[0]'), 4)       AS top_freq,
       round(1.0 / json_extract(p, '$.freqs[0]'), 1) AS samples_per_cycle
FROM (SELECT channel,
             fractal_periodogram(
               (SELECT '[' || group_concat(printf('%.5f', level), ',') || ']'
                  FROM (SELECT level FROM rfs_capture c2
                         WHERE c2.channel = c.channel ORDER BY seq)), 1) AS p
        FROM (SELECT DISTINCT channel FROM rfs_capture) c)
ORDER BY channel;

-- ------------------------------------------------------------------
-- 3. How ordered is each channel, window by window
-- (fractal_spectrogram_entropy: window 32, hop 16 -> 15 frames).
-- ------------------------------------------------------------------
.print
.print === 3. Per-frame spectral entropy (fractal_spectrogram_entropy) ===

DROP TABLE IF EXISTS rfs_entropy;
CREATE TABLE rfs_entropy AS
SELECT channel,
       fractal_spectrogram_entropy(
         (SELECT '[' || group_concat(printf('%.5f', level), ',') || ']'
            FROM (SELECT level FROM rfs_capture c2
                   WHERE c2.channel = c.channel ORDER BY seq)), 32, 16) AS ent
  FROM (SELECT DISTINCT channel FROM rfs_capture) c;

SELECT channel, json_array_length(ent) AS frames,
       round((SELECT min(value) FROM json_each(ent)), 3) AS min_entropy,
       round((SELECT max(value) FROM json_each(ent)), 3) AS max_entropy,
       round((SELECT avg(value) FROM json_each(ent)), 3) AS mean_entropy
FROM rfs_entropy ORDER BY channel;

.print --- CH-A frame by frame: ordered, then jammed ---
SELECT je.key AS frame, je.key * 16 AS first_sample, round(je.value, 3) AS entropy
FROM rfs_entropy e, json_each(e.ent) je WHERE e.channel = 'CH-A' ORDER BY je.key;

-- ------------------------------------------------------------------
-- 4. When did CH-A lose its structure?  fractal_change_point_detect on
-- the entropy series (window 3 frames, threshold 8.0 pooled-stddev
-- units).  The jam begins at sample 161; frame 9 (samples 144-175) is the
-- first to contain it, and that is the boundary reported.  A clean
-- channel's entropy series is nearly constant, so its pooled standard
-- deviation is tiny and a low threshold would flag measurement jitter --
-- keep the threshold high for entropy series.
-- ------------------------------------------------------------------
.print
.print === 4. Where the order changed (change-point on the entropy series) ===

SELECT channel,
       fractal_change_point_detect(ent, 3, 8.0) AS change_points
FROM rfs_entropy ORDER BY channel;

-- ------------------------------------------------------------------
-- 5. Reasoning: the interference triage narrative (plugin-gated; the
-- clean hint is the expected output without one).
-- ------------------------------------------------------------------
.print
.print === 5. Reasoning: interference triage ===

SELECT fractal_reason(
    'one-line RF interference triage: which channel lost its structure, when, and the likely cause',
    json_object(
      'ch_a_entropy',        json((SELECT ent FROM rfs_entropy WHERE channel = 'CH-A')),
      'ch_a_change_points',  json((SELECT fractal_change_point_detect(ent, 3, 8.0)
                                     FROM rfs_entropy WHERE channel = 'CH-A')),
      'ch_b_mean_entropy',   (SELECT round(avg(value), 3) FROM rfs_entropy e, json_each(e.ent)
                               WHERE e.channel = 'CH-B')));

.print
.print === Demo complete ===
.print Tables left in place for inspection. Clean up with:
.print   DROP TABLE rfs_capture; DROP TABLE rfs_entropy;
