<p align="center">
  <img src="../FractalSQLforSQLite.jpg" alt="FractalSQL for SQLite" width="720">
</p>

# Enterprise Tier — CISO Decision Audit & Quantized Ternary Ledger (QTL)

QTL is a tamper-evident audit ledger for agent and optimizer decisions. The
mechanism is described in full below.

The core FractalSQL extension (Discovery, Cognition, and Agency) works fine
on its own; none of it needs anything described on this page. This tier
exists for regulated environments that need to prove what an agent decided,
not just claim it: every optimizer call and agent decision can write a
tamper-evident record a CISO or auditor can verify, rather than a log line
they simply have to trust.

**SQLite delivery.** The ledger/audit core symbols are enterprise-gated in
the vendored core drop — absent from the community sovereign archive, on
Windows and Linux alike (the vendor header marks them "absent from a
community-compiled object", and a static link proves it). The SQLite
integration loads the separately licensed FractalSQL Enterprise core at
call time: set the `enterprise_lib` config key to the library's path and
the ledger surface resolves its core symbols through it
(`src/fsql_enterprise.c`, one load attempt per connection). Without it,
every ledger-management call returns a clean
`fractalsql: enterprise tier not loaded` error; the **HMAC envelope**
(below) is community code and works regardless. Before loading, the
library's detached Ed25519 signature (a sibling `<path>.sig` file, 64 raw
bytes) is verified against a fixed FractalSQLabs signing public key
embedded in `src/fsql_enterprise.c` (a small vendored, verify-only Ed25519
implementation — no external crypto dependency, matching how the HMAC
envelope below vendors its own SHA-256). **Signature verification is
mandatory by default**: the library must carry a verifying `.sig` sidecar
or the load is refused. `enterprise_require_signature` is a SQL-settable
key, and every principal that can run SQL can call `fractalsql_set()` — so
that key can only ever *strengthen* the check, never weaken it below the
default. Weakening it back to the original "loading unverified is the
operator's choice" behavior (missing `.sig` loads, present-but-wrong
signature always refused) requires setting `FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1`
in the process environment — something no SQL statement can do. The path is
locked once a library has loaded; re-point it by reopening the connection.
The gate is `fractalsql_set('enterprise_lib', ...)` plus a fresh
connection — no config-file edit or reload step.

The nine functions operate on the same in-memory context the search engine
already built (eight ledger-management functions plus `fractal_audit_unpack`
for CISO decode), and the ledger persists through the storage VFS into the
`fractalsql_ledger` table as a genuine tamper-evident **append-only hash
chain** — created lazily as:

```sql
CREATE TABLE IF NOT EXISTS fractalsql_ledger(
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  kind       INTEGER NOT NULL,
  payload    BLOB NOT NULL,
  mac        BLOB,                 -- HMAC-SHA256 tag (32B), NULL when the key is unset
  prev_hash  BLOB NOT NULL,        -- entry_hash of the prior row for this kind; all-zero(32) = genesis
  entry_hash BLOB NOT NULL,        -- SHA256(prev_hash || payload || mac) -- the chain link
  sealed     INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL DEFAULT (datetime('now')))
```

Each row links to its predecessor via `entry_hash`, so a rewritten row
breaks the chain and a deleted row leaves a visible gap in the `id`
sequence — the same integrity model detailed under **Integrity model**
below. A pre-chain install (the older single-row-per-kind snapshot shape)
is detected and migrated automatically on first use: nothing worth
preserving from that shape, so it starts a fresh chain.

| Function | Purpose |
| --- | --- |
| `fractal_ledger_flush()` | Encode truth + shadow ledgers into a QTL blob and append it to the chain (returns `'ok'`). |
| `fractal_ledger_load()` | Hydrate the in-memory ledgers from the chain's latest entry (verifies only the tip, O(1)). |
| `fractal_ledger_verify([kind])` | Walk the ENTIRE chain for `kind` (default 1) and return a TEXT JSON audit report: `{"ok":true,"rows_verified":N}` or `{"ok":false,"first_failure_id":ID,"reason":"..."}`. Pure read-only forensic query — works even without `enterprise_lib` loaded. |
| `fractal_ledger_compact()` | Defragment / re-pack the in-memory QTL representation. |
| `fractal_ledger_reset_soft()` | Soft-reset ledger counters without dropping history. |
| `fractal_ledger_reset_hard()` | Hard-reset the ledgers to empty. |
| `fractal_ledger_truth_count()` | Truth-side entry count. |
| `fractal_ledger_shadow_count()` | Shadow-side entry count. |
| `fractal_audit_unpack(blob)` | Decode a persisted QTL blob into its audit JSON (TEXT). |

**`fractal_audit_log(entry_type, payload)`**: the general decision-audit
record. **Enterprise-gated**, same as the eight ledger-management functions
above — returns `fractalsql: enterprise tier not loaded` without
`enterprise_lib` configured. Takes two **TEXT** arguments (SQLite has no
jsonb — the payload is stored verbatim, not re-parsed) and appends a row to
the same chain machinery as above, under `kind=2` — a second, independent
chain alongside `kind=1`'s QTL blobs (`fractal_ledger_verify(2)` walks it
separately from the QTL chain). `fractal_text_to_sql`,
`fractal_optimize_portfolio`, `fractal_optimize_portfolio_multimodal`,
`fractal_optimize_portfolio_multimodal_pareto`, and every decision-making
agent (`fractal_agent_anomaly_triage`, `_allocate`, `_route_task`,
`_outlier_intercept`, `_data_analyst`, `_patient_deterioration_triage`,
`_schedule_workload`, `_rebalance_sibling`, `_detour_classify`,
`_track_anomaly`, `_network_coverage_alert`, `_regime_triage`, and
`_diverse_portfolios`) log to it automatically — silently skipped on a
community-only connection, so none of them ever depend on a license to keep
working. Query the chain directly:

```sql
SELECT kind, updated_at, fractal_audit_unpack(payload)
  FROM fractalsql_ledger WHERE kind = 2;
```

**`fractal_optimize_portfolio_multimodal()`**: like `fractal_optimize_portfolio`
but runs several independent restarts and returns up to `n_restarts`
structurally distinct portfolios instead of one: candidates within
`quality_frac` of the best Sharpe found, no two sharing more than
`overlap_threshold` of their assets. Same entropy engine as the single-best
version. **Enterprise-gated**: its core symbol ships only in the licensed
enterprise core, so the function resolves it through `enterprise_lib` and
returns `fractalsql: enterprise tier not loaded` without one. It returns
its candidates as one TEXT JSON document.

**`fractal_optimize_portfolio_multimodal_pareto()`**: Pareto-front sibling of
the function above: same `n_restarts` independent searches, but scores each
by decomposed **return/risk** instead of scalar Sharpe and reduces them to a
genuine non-dominated Pareto front (NSGA-II crowding-distance truncation past
`max_front`) rather than sharpe-threshold + asset-overlap selection. Purely
additive, doesn't change the sibling function's semantics. All three
`fractal_optimize_portfolio*` functions also accept `use_obl`
(Opposition-Based Learning: evaluate each SFS trial candidate's
bound-reflected opposite, keep whichever fits better) and `diffusion_mode`
(`'gaussian'` default or `'levy'`, a heavy-tailed Mantegna-algorithm step
that can help escape local optima on highly multimodal problems). The
`fractal_agent_diverse_portfolios` agent exposes both via the
`objective_mode` field of its options JSON (`'sharpe'` or `'pareto'`).

**Append-only chain, not a snapshot.** The ledger is a genuine history: every
row links to its predecessor via `entry_hash = SHA256(prev_hash || payload ||
mac)`, and writes are plain `INSERT`s, never `UPDATE`/upsert. A rewritten
row breaks the chain; a deleted row leaves a visible gap in the `id`
sequence. This holds **even without a MAC key**: `entry_hash` covers the
payload unconditionally, so a byte-flip anywhere in history is structurally
detectable, not just cryptographically. Set the `enterprise_ledger_key`
config key per connection —

```sql
SELECT fractalsql_set('enterprise_ledger_key', '<high-entropy secret>');
```

— to additionally **HMAC-SHA256-tag** each payload (stored in the `mac`
column), authenticating it against forgery by anyone who doesn't hold the
key. `fractal_ledger_load()` checks only the chain's tip on every call
(cheap, O(1)); `fractal_ledger_verify()` walks the full chain for a periodic
or on-demand CISO audit (O(n), not run automatically). A key-configured load
of a row written *without* the key is refused ("written before the key was
set") rather than silently trusted. Key changes take effect at the next
flush/load without re-wiring anything. With no key configured, the chain's
structural integrity (the `entry_hash`/`prev_hash` links) is still checked —
only the MAC layer is skipped. One honest limit: the chain can prove nothing
in the *middle* was altered or removed, but it can't prove nothing was
truncated off the very *end*: there's nothing after the last row to notice
its absence. That needs an external anchor (e.g. publishing the head hash
somewhere independent). See **External anchoring** below for a ready-to-use
recipe. Apply the key on every connection that touches the ledger (the
easy_install wizard's `load_fractalsql.sql` snippet is the standard place —
protect that file like a credential, since it carries the key in plain
text).

### External anchoring (closing the truncation gap)

`scripts/enterprise/anchor-ledger.sh` periodically records the chain's tip
(`kind`, `id`, `entry_hash`) somewhere outside this database: a place the
database file's own owner can't retroactively edit. Run it on a schedule
(cron, systemd timer) per `kind` you audit:

```bash
*/15 * * * * /path/to/anchor-ledger.sh /path/to/app.sqlite 1 >> /var/log/fractalsql/anchor.log
*/15 * * * * /path/to/anchor-ledger.sh /path/to/app.sqlite 2 >> /var/log/fractalsql/anchor.log
```

The script itself only formats and prints the anchor record — no extension
load required, since it only reads plain columns with SQLite's built-in
`hex()`/`strftime()`. Where it *publishes* to (syslog for SIEM ingestion, an
S3 Object Lock bucket, a compliance mailbox) is a few commented-out lines
you uncomment for your own environment; see the script's own header for
each option and why plain stdout redirection alone doesn't satisfy the
guarantee.

To verify an anchor later, confirm the live table still has a row at the
anchored `id`, for that `kind`, with that exact `entry_hash`:

```sql
SELECT hex(entry_hash) = '<anchored hex, uppercase>'
FROM fractalsql_ledger WHERE kind = <kind> AND id = <anchored id>;
```

`false` or no matching row means the row was altered, or the chain was
rewound past it, after the anchor was taken.

**Detached signature verification (mandatory by default).** The 8-symbol
link-proof check in `fsql_enterprise_ensure()` only proves a file has the
right function *names*. A tampered file with the same names sails through
it untouched, so a valid detached Ed25519 signature (a sibling `<path>.sig`
file, 64 raw bytes) against a fixed FractalSQLabs public key is required
before the library is loaded. Because `enterprise_require_signature` is
SQL-settable and therefore not an operator control on its own, the default
is strict and the *opt-out* lives in the environment:
`FSQL_ENTERPRISE_ALLOW_UNVERIFIED=1` in the process environment restores
the original permissive behavior (missing `.sig` loads; the SQL key then
governs as before). An **invalid** signature (present but wrong) is always
refused regardless of any setting: unambiguous tamper evidence, unlike a
merely absent file. The library path is locked once a library has loaded
successfully — re-point it by reopening the connection. New enterprise
releases only need a fresh signature from the same long-lived key; this
extension never needs rebuilding, preserving the drop-in-library design a
hash pin would have broken.

---

For enterprise editions, licensing, and support, contact
**enterprise@fractalsqlabs.com**.
