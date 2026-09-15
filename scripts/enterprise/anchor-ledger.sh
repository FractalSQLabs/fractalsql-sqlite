#!/bin/bash
#
# scripts/enterprise/anchor-ledger.sh — external anchoring for the
# enterprise decision-audit ledger (fractalsql_ledger).
#
# What this closes: fractal_ledger_verify() proves nothing in the
# MIDDLE of the chain was altered or removed (every row's entry_hash
# recomputes from its own payload/mac and matches the next row's
# prev_hash). It cannot prove nothing was TRUNCATED off the very END --
# there's nothing after the last row to notice its absence. That needs
# an anchor outside this database: a record of "the chain's tip was X
# as of this time," written somewhere the database file's own owner
# can't quietly rewrite. This script produces that record; you decide
# where it lives (see the PUBLISH step below). No extension load is
# needed here -- the anchor only reads plain columns with SQLite's
# built-in hex()/strftime(), it never calls a fractal_* function.
#
# Usage (as a cron job, one line per chain you want anchored):
#   */15 * * * * /path/to/anchor-ledger.sh /path/to/app.sqlite 1 >> /var/log/fractalsql/anchor.log
#   */15 * * * * /path/to/anchor-ledger.sh /path/to/app.sqlite 2 >> /var/log/fractalsql/anchor.log
#
# Arguments: the database file, then the ledger `kind` to anchor --
# 1 = QTL (fractal_ledger_flush), 2 = the general decision-audit chain
# (fractal_audit_log). Anchor whichever your audit scope covers; most
# CISO reviews want both.
#
# Verifying an anchor later: an anchor record is only useful if you can
# re-derive it. Given an anchored (kind, id, entry_hash), confirm the
# LIVE table still has a row at that id, for that kind, with that exact
# entry_hash:
#   SELECT hex(entry_hash) = '<anchored hex, uppercase>'
#   FROM fractalsql_ledger WHERE kind = <kind> AND id = <anchored id>;
# false or no row = the row was altered, or the chain was rewound past
# it -- either way, tampering after the anchor was taken.

set -euo pipefail

DB="${1:?usage: anchor-ledger.sh <db-file> <kind> (1=QTL, 2=decision-audit)}"
KIND="${2:?usage: anchor-ledger.sh <db-file> <kind> (1=QTL, 2=decision-audit)}"
SQLITE3="${SQLITE3:-sqlite3}"

# The tip only -- O(1), no full chain walk needed to anchor (that's
# what fractal_ledger_verify() is for, on your own audit cadence).
ROW="$("${SQLITE3}" -readonly -noheader -separator '|' "${DB}" \
    "SELECT id, hex(entry_hash), CAST(strftime('%s', updated_at) AS INTEGER)
     FROM fractalsql_ledger WHERE kind = ${KIND} ORDER BY id DESC LIMIT 1;")"

if [[ -z "${ROW}" ]]; then
    echo "anchor-ledger: no rows for kind=${KIND} yet -- nothing to anchor" >&2
    exit 0
fi

IFS='|' read -r ID ENTRY_HASH UPDATED_EPOCH <<< "${ROW}"
ANCHORED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RECORD="anchor db=${DB} kind=${KIND} id=${ID} entry_hash=${ENTRY_HASH} row_updated=${UPDATED_EPOCH} anchored_at=${ANCHORED_AT}"

# --- PUBLISH: pick (or combine) whichever of these match your actual
# compliance posture. The point is that this record ends up somewhere
# the database file's own owner can't retroactively edit -- stdout
# alone (the default) does NOT satisfy that; redirect it yourself (see
# the crontab line above) or uncomment a sink below.

echo "${RECORD}"

# SIEM via syslog (logger ships to whatever your syslog daemon forwards
# to -- most SIEMs ingest this natively):
# logger -t fractalsql-ledger-anchor "${RECORD}"

# Object-lock storage (S3 Object Lock / WORM-mode bucket -- requires
# the bucket already have Object Lock enabled; a normal bucket does NOT
# give you this guarantee):
# echo "${RECORD}" | aws s3 cp - "s3://your-anchor-bucket/fractalsql/kind-${KIND}/${ANCHORED_AT}.txt"

# Email (any MTA on the box; a compliance mailbox nobody with DB access
# can also purge is the point):
# echo "${RECORD}" | mail -s "FractalSQL ledger anchor (kind=${KIND})" compliance@example.com
