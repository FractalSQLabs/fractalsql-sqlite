<#
.SYNOPSIS
    build_test.ps1 -- post-build validation gate runner for
    fractalsql-sqlite. Native PowerShell port of build_test.sh; same 27
    gates, same titles, same assertion messages, same pass/fail/skip
    posture. This is the Windows build arbiter the .sh's MSYS branch
    defers to.

.DESCRIPTION
    Builds (or accepts a prebuilt) extension and validates it against a
    THROWAWAY fixture database (a plain file under the temp root, opened
    in WAL mode and torn down on exit) -- no server install, no admin.

    Every sqlite3 invocation is a FRESH connection (fractalsql_set()
    config is per-connection state), so every call carries its own
    config preamble exactly as build_test.sh does.

    Gates (see build_test.sh for the full rationale behind each):
      01  build              scripts\windows\build.bat (MSVC); falls back
                             to the prebuilt dist\windows\fractalsql.dll
                             when no cl/vcvars is resolvable
      02  smoke              load + version + fractal_search convergence
      03  schema_context     PK / NOT NULL / FK introspection + auto-
                             discovery (no COMMENT analog -- SQLite
                             tables have no comments)
      04  text_to_sql        allowlist fuzz matrix + never-executes
                             proof (uses tests\mock_reasoning_plugin.c)
      05  evil_overread      guard-page (VirtualAlloc/VirtualProtect via
                             tests\windows\evil_nonterminating_plugin_
                             win.c; the POSIX variant needs mmap/mprotect
                             which mingw gcc has no header for) non-
                             terminated response survives at GENERATE,
                             REVIEW, and bare fractal_reason() -- a crash
                             kills the sqlite3 PROCESS (abnormal exit
                             without a clean SQL error)
      06  crash_recovery     deliberately-segfaulting plugin: the sqlite3
                             process dies; the DB is reopened and the
                             prior canary row must be intact (WAL
                             recovery) (uses tests\evil_crash_plugin.c)
      07  evil_lying_length  guard_ai_response_len rejects an implausible
                             claimed length before any read, at GENERATE,
                             REVIEW, and bare fractal_reason()
                             (uses tests\evil_lying_length_plugin.c)
      08  authz              sqlite3_set_authorizer denial honored inside
                             fractal_schema_context's introspection
                             (python driver)
      09  guc_superuser      relative/traversal reasoning_plugin paths
                             rejected at fractalsql_set time
      10  dos_and_injection  512-table cap fires at 513; an SQL-
                             injection-shaped table name is skipped by
                             introspection (never smuggled into SQL text)
                             and provably never executed
      11  scout              fractal_search_explore: full population returned,
                             JSON-parseable, dispersed across distinct
                             points
      12  soak               SOAK_WORKERS concurrent python connections x
                             SOAK_ITERS mixed benign calls each
      13  siu_mode           text_to_sql_allowed_statements=select_insert_
                             update: INSERT/UPDATE returned (never
                             executed), DDL/DELETE still rejected
      14  retry              max_attempts=2 retry-with-feedback
                             (uses tests\retry_reasoning_plugin.c)
      15  embed              fractal_embed() + the vectorizer: real
                             dispatch through the EMBED tier, NULL input,
                             bad plugin path, over-limit embedding array
                             (tests\evil_embed_plugin.c), injection-shaped
                             source_table, double-create
      16  embed_authz        vectorizer create-time validation +
                             authorizer denial inside the PK probe
      17  embed_soak         100-row queue drained by repeated
                             process_queue(batch=20) in ONE connection
      18  embed_crash        deliberately-segfaulting plugin mid-
                             process_queue(); a fresh connection must
                             find the DB intact and gate 15's persisted
                             embeddings preserved
      19  sfs_bounds         input-side guards: over-arena vector (via
                             the float32 BLOB path -- the TEXT path clamps
                             silently), empty vector, dim mismatch,
                             injection-shaped explore query
      20  api_func           fractal_reason happy path + NULL rejections,
                             malformed explore options leniency,
                             process_queue bounds, stale_after reclaim
      21  fuzz_smoke         FUZZ ONLY (-Fuzz, not in DEFAULT/QUICK).
                             Builds + briefly runs (FSQL_FUZZ_TIME
                             seconds each, default 30) libFuzzer drivers
                             against the 3 hand-rolled parsers in
                             src\fsql_parse.c. Needs a libFuzzer-capable
                             clang; skips cleanly if none is found. No
                             fixture DB needed.
      22  v2_functions       dimension (dfa/boxcount/drift), portfolio
                             (+ cov-length rejection, pareto dormant
                             path), domain geometry (vascular/cortical/
                             nerve/morphological), search_telemetry,
                             hybrid/cross-modal guards, explain_result/
                             detect_collapse/diversify
      23  agents             the registered C agents with a reasoning
                             canary: search_agent/rag_agent/sql_agent/
                             plan_explore/trajectory_predict/detect_loop/
                             telemetry/trajectory/hybrid/cross_modal +
                             the three guards
      24  enterprise         dormant enterprise path: ledger/audit
                             surface cleanly rejected; a bogus
                             enterprise_lib surfaces the load failure
      25  enterprise_stress  self-skips unless an enterprise core is
                             vendored in include/ (none is, on the
                             community drop)
      26  enterprise_signature  load-before-signature ordering
      27  think              THINK-effort config forwarding via
                             tests\think_reasoning_plugin.c's dump file
      28  review_isolation   fractal_text_to_sql()'s REVIEW step
                             dispatches on its own reasoning tier, not
                             T2S: GENERATE still runs under T2S's
                             forced RESPONSE_MODE=code, but REVIEW
                             (text_to_sql_use_review=on) must see it
                             unset (uses tests\mock_reasoning_plugin_
                             win.c's per-call RESPONSE_MODE dump)
      29  domain_agents      smoke gate for the sixteen installable
                             Domain Agent engines (src\fsql_domain_
                             agents.c): three representative engines
                             (anomaly_triage, recall_hybrid,
                             regime_triage) run end-to-end against the
                             real primitives they compose

    Gate sets:
      QUICK   = 01 02                                   post-edit sanity
      DEFAULT = 01..20, 22..29                          pre-push / CI
      FUZZ    = 21                                      opt-in only

.PARAMETER Gate
    Run a single gate by number (e.g. -Gate 05).

.PARAMETER Quick
    Gates 01-02 only.

.PARAMETER Fuzz
    Gate 21 only -- libFuzzer smoke. Set FSQL_FUZZ_TIME (seconds per
    target, default 30) to run longer than the pre-push smoke budget.

.PARAMETER Ext
    Prebuilt extension override (skips gate 01's build). Same purpose as
    build_test.sh's FSQL_EXT; the FSQL_EXT environment variable works too.

.PARAMETER TimeoutMult
    Scales gate 06/18's recovery-poll budget. Defaults from
    FSQL_TEST_TIMEOUT_MULT (1 when unset), auto-bumped to 8 under
    -Asan/-Ubsan unless passed explicitly.

.PARAMETER Asan
    Rebuilds fractalsql.dll with MSVC /fsanitize=address over the same
    src\*.c file list scripts\windows\build.bat compiles, into a
    separate dist\windows-asan\ tree. Only this repo's own source is
    instrumented; the vendored core archive is linked as-is.

.PARAMETER Ubsan
    Same as -Asan but via clang-cl and -fsanitize=undefined (native
    cl.exe has no UBSan support), into dist\windows-ubsan\. Mutually
    exclusive with -Asan.

.PARAMETER List
    Print the gate sets and exit.

.EXAMPLE
    PS> .\build_test.ps1                    # DEFAULT
    PS> .\build_test.ps1 -Quick
    PS> .\build_test.ps1 -Fuzz              # gate 21 only
    PS> .\build_test.ps1 -Asan              # DEFAULT gates against an ASan build
    PS> .\build_test.ps1 -Ubsan             # DEFAULT gates against a UBSan build
    PS> .\build_test.ps1 -Gate 04

.NOTES
    Toolchain: sqlite3 CLI on PATH (or FSQL_SQLITE3), python with the
    stdlib sqlite3 module (FSQL_PYTHON), gcc for the fixture plugins
    (FSQL_CC), MSVC cl/vcvarsall for gate 01 (or a prebuilt
    dist\windows\fractalsql.dll), clang-cl (PATH, VS's "C++ Clang tools
    for Windows" component, or standalone LLVM) additionally for -Ubsan.
    The fixture plugins' hardcoded
    "/tmp/..." file contracts resolve against the host process's CURRENT
    DRIVE, so BTROOT is pinned to <drive>:\tmp (mirroring build_test.sh's
    MSYS pinning) and the harness does all fixture-file I/O through it.
#>
[CmdletBinding()]
param(
    [string]$Gate,
    [switch]$Quick,
    [switch]$Fuzz,
    [string]$Ext,
    [int]$TimeoutMult = 0,
    [switch]$List,
    [switch]$Asan,
    [switch]$Ubsan
)

if ($Asan -and $Ubsan) {
    throw "-Asan and -Ubsan are mutually exclusive -- each rebuilds its own separate dist\ tree. Run one at a time."
}

$ErrorActionPreference = 'Continue'
try { $PSNativeCommandArgumentPassing = 'Standard' } catch { }

$script:Here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $script:Here

# ---------------------------------------------------------------------------
# BTROOT: the directory the fixture plugins' hardcoded "/tmp/..." contracts
# actually resolve to. The plugins run inside the host process (sqlite3.exe)
# whose CRT resolves a literal "/tmp/x" against the process's CURRENT DRIVE,
# so the harness pins <drive>:\tmp (created if needed) and does all of its
# own fixture-file I/O through the same place. Mirrors build_test.sh's MSYS
# pinning (BTROOT=/c/tmp there, BTROOTW=c:/tmp).
# ---------------------------------------------------------------------------
$script:Drive = 'C'
$d = Get-Location
if ($d -and $d.Drive) { $script:Drive = $d.Drive.Name }
$script:BTROOT = "${script:Drive}:\tmp"
if (-not (Test-Path -LiteralPath $script:BTROOT)) {
    New-Item -ItemType Directory -Force $script:BTROOT | Out-Null
}
if (-not (Test-Path -LiteralPath $script:BTROOT)) {
    Write-Host "ERROR: cannot create ${script:BTROOT} -- the fixture plugins hardcode"
    Write-Host "       /tmp/... paths that resolve to ${script:BTROOT} on Windows."
    exit 1
}

$script:DEFAULT_GATES = @('01', '02', '03', '04', '05', '06', '07', '08', '09', '10',
                          '11', '12', '13', '14', '15', '16', '17', '18', '19', '20',
                          '22', '23', '24', '25', '26', '27', '28', '29', '30', '31', '32')
$script:QUICK_GATES = @('01', '02')
$script:FUZZ_GATES = @('21')

if ($TimeoutMult -gt 0) {
    $script:TimeoutMult = $TimeoutMult
}
elseif ($env:FSQL_TEST_TIMEOUT_MULT) {
    $script:TimeoutMult = [int]$env:FSQL_TEST_TIMEOUT_MULT
}
elseif ($Asan -or $Ubsan) {
    # Sanitizer overhead needs headroom against gate 06/18's crash-recovery poll budget.
    $script:TimeoutMult = 8
}
else {
    $script:TimeoutMult = 1
}

# Inherited by every child process this script spawns (sqlite3.exe included).
if ($Asan) { $env:ASAN_OPTIONS = 'halt_on_error=1:print_stats=0' }
if ($Ubsan) { $env:UBSAN_OPTIONS = 'print_stacktrace=1:halt_on_error=1' }

# PATH -> vswhere-resolved VC\Tools\Llvm\x64\bin\clang-cl.exe -> standalone LLVM.
function Find-ClangCl {
    $candidate = Get-Command clang-cl.exe -ErrorAction SilentlyContinue
    if ($candidate) { return $candidate.Source }
    $VsWhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $VsWhere) {
        $vsPath = & $VsWhere -latest -products * -property installationPath 2>$null
        if ($vsPath) {
            $vsClang = Join-Path $vsPath 'VC\Tools\Llvm\x64\bin\clang-cl.exe'
            if (Test-Path $vsClang) { return $vsClang }
        }
    }
    $standalone = 'C:\Program Files\LLVM\bin\clang-cl.exe'
    if (Test-Path $standalone) { return $standalone }
    throw "-Ubsan requested but clang-cl.exe not found (checked PATH, VS's 'C++ Clang tools for Windows' component, standalone LLVM)."
}
$script:ClangCl = $null
if ($Ubsan) {
    $script:ClangCl = Find-ClangCl
    Write-Host "Using clang-cl: $script:ClangCl"
}

# --- colours ---------------------------------------------------------------
# ANSI only when stdout is a real console (mirrors the sh's `[[ -t 1 ]]`).
$script:G = ''; $script:R = ''; $script:Y = ''; $script:Z = ''
if (-not [Console]::IsOutputRedirected) {
    $script:G = "$( [char]27 )[32m"
    $script:R = "$( [char]27 )[31m"
    $script:Y = "$( [char]27 )[33m"
    $script:Z = "$( [char]27 )[0m"
}
function Pass { param([string]$Msg) Write-Host "  [$($script:G)PASS$($script:Z)] $Msg" }
function Fail { param([string]$Msg) Write-Host "  [$($script:R)FAIL$($script:Z)] $Msg"; $script:Failed = 1 }
function Skip { param([string]$Msg) Write-Host "  [$($script:Y)SKIP$($script:Z)] $Msg" }

# --- state -----------------------------------------------------------------
$script:Ext = ''        # relative form for the sqlite3 CLI's .load (the
                        # absolute form carries a space, which the shell's
                        # .load tokenizer splits on -- the .sh sidesteps the
                        # same way by keeping CWD at the repo root)
$script:ExtAbs = ''     # absolute form (LoadLibrary/python side: spaces fine)
$script:ExtLoad = ''    # the path handed to -cmd ".load ..."
$script:Db = ''
$script:Sqlite3 = ''; $script:Py = ''; $script:Cc = ''
$script:PlugDir = ''
$script:Mock = ''; $script:EvilNt = ''; $script:Lying = ''; $script:Crash = ''
$script:Retry = ''; $script:Think = ''; $script:MockEmb = ''; $script:EvilEmb = ''
$script:Failed = 0
$script:SqlqRc = 0
$script:LastAgentOut = ''

# Fixed file contracts the fixture plugins hardcode (see each plugin's
# header comment). The plugins run inside the host process and do their own
# fopen()s, so the harness must write these through BTROOT.
$script:SqlTxt = Join-Path $script:BTROOT 'fractalsql_bt_sql.txt'
$script:EvilTrig = Join-Path $script:BTROOT 'fractalsql_bt_evil_trigger_call.txt'
$script:RetryPrompt = Join-Path $script:BTROOT 'fractalsql_bt_retry_prompt.txt'
$script:ThinkDump = Join-Path $script:BTROOT 'fractalsql_bt_think_dump.txt'
$script:ReviewDump = Join-Path $script:BTROOT 'fractalsql_bt_review_env_dump.txt'
# tests\windows\evil_nonterminating_plugin_win.c reads its trigger file
# through a bare CWD-relative name; sqlite3.exe's CWD is the repo root, so
# gate 05 mirrors the trigger file there too (cleaned up below).
$script:EvilTrigRepo = Join-Path $script:Here 'fractalsql_bt_evil_trigger_call.txt'

function Invoke-Cleanup {
    if ($script:PlugDir -and (Test-Path -LiteralPath $script:PlugDir)) {
        cmd /c "rmdir /s /q $script:PlugDir" 2>$null | Out-Null
    }
    foreach ($f in @($script:SqlTxt, $script:EvilTrig, $script:RetryPrompt,
                     $script:ThinkDump, $script:ReviewDump, $script:EvilTrigRepo,
                     (Join-Path $script:BTROOT 'fractalsql_bt_build_cmd.bat'))) {
        if ($f -and (Test-Path -LiteralPath $f)) { [IO.File]::Delete($f) }
    }
    Get-ChildItem -LiteralPath $script:BTROOT -Filter 'fractalsql_bt_*_plugin.*' `
        -ErrorAction SilentlyContinue |
        ForEach-Object { [IO.File]::Delete($_.FullName) }
    # Gate 01's build log: keep it when a gate failed (the [FAIL] line
    # names it) -- the .sh has no analog since its gate 01 does not build.
    if ($script:Failed -ne 1) {
        $bl = Join-Path $script:BTROOT 'fractalsql_bt_build.log'
        if (Test-Path -LiteralPath $bl) { [IO.File]::Delete($bl) }
    }
}

# --- toolchain -------------------------------------------------------------
function Find-Toolchain {
    if ($env:FSQL_SQLITE3) {
        $script:Sqlite3 = $env:FSQL_SQLITE3
    }
    else {
        $c = Get-Command sqlite3 -ErrorAction SilentlyContinue
        if ($c) { $script:Sqlite3 = $c.Source }
    }
    # gcc first on Windows: there is no cc(1) convention here, and the
    # Strawberry mingw gcc is the known-good fixture-plugin compiler.
    if ($env:FSQL_CC) {
        $script:Cc = $env:FSQL_CC
    }
    else {
        foreach ($n in @('gcc', 'cc', 'clang')) {
            $c = Get-Command $n -ErrorAction SilentlyContinue
            if ($c) { $script:Cc = $c.Source; break }
        }
    }
    # python3/python, probed for the stdlib sqlite3 module (the Windows
    # Store alias stub resolves on PATH but cannot actually run code).
    if ($env:FSQL_PYTHON) {
        $script:Py = $env:FSQL_PYTHON
    }
    else {
        foreach ($n in @('python3', 'python')) {
            $c = Get-Command $n -ErrorAction SilentlyContinue
            if (-not $c) { continue }
            & $c.Source -c 'import sqlite3' *> $null
            if ($LASTEXITCODE -eq 0) { $script:Py = $c.Source; break }
        }
    }
}

# resolve_ext -- locate the built extension when gate 01 did not run
# (single -Gate invocations, fuzz-only runs).
function Resolve-Ext {
    if ($script:Ext) { return $true }
    $distSubdir = if ($Asan) { 'dist\windows-asan' } elseif ($Ubsan) { 'dist\windows-ubsan' } else { 'dist\windows' }
    $script:Ext = "$distSubdir\fractalsql.dll"
    $script:ExtAbs = Join-Path $script:Here "$distSubdir\fractalsql.dll"
    # The shell's .load tokenizer splits on whitespace, so the absolute path
    # (which contains "Daniel Gardiner") cannot be handed to it -- use the
    # CWD-relative form. Anything crossing into python/LoadLibrary gets the
    # absolute form, where spaces are fine.
    $script:ExtLoad = if ($script:ExtAbs.StartsWith($script:Here, [StringComparison]::OrdinalIgnoreCase)) {
        $script:Ext
    }
    else { $script:ExtAbs }
    return (Test-Path -LiteralPath $script:ExtAbs)
}

# --- fixture-DB helpers ----------------------------------------------------

# Run SQL through a FRESH connection with the extension loaded.
# Each argument is one statement; a script can also be piped on stdin.
# Config is per-connection, so every gate invocation carries its own
# fractalsql_set() preamble -- the SQLite analog of pg_set_guc().
function Sqlq {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
        [string[]]$Stmts
    )
    $base = @('-batch', '-bail', '-cmd', ".load $($script:ExtLoad)", $script:Db)
    $hasDq = $false
    foreach ($s in $Stmts) { if ($s -and $s.Contains('"')) { $hasDq = $true; break } }
    if ($hasDq) {
        # Statements carrying embedded double quotes: hand them to the
        # shell as a piped script instead of argv. Windows PowerShell <7.3
        # mangles embedded quotes when building a native argv (and even
        # pwsh's escaped form is a needless risk), while stdin consumes the
        # identical statements verbatim.
        $tmp = Join-Path $script:PlugDir 'sqlq_stdin.sql'
        $lines = foreach ($s in $Stmts) { if ($s -match ';\s*$') { $s } else { "$s;" } }
        [IO.File]::WriteAllText($tmp, (($lines -join "`n") + "`n"))
        $scriptText = [IO.File]::ReadAllText($tmp)
        $out = & $script:Sqlite3 @base $scriptText 2>&1
    }
    else {
        $out = & $script:Sqlite3 @base @Stmts 2>&1
    }
    $script:SqlqRc = $LASTEXITCODE
    return [string](($out | ForEach-Object { "$_" }) -join "`n")
}

# Expect a clean SQL error containing $Want from a fresh connection;
# any other outcome (success, crash, different error) fails.
function ExpectErr {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Want,
        [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Stmts
    )
    $r = Sqlq @Stmts
    $rc = $script:SqlqRc
    # Fixed-string match: want patterns carry regex metacharacters
    # verbatim (e.g. "alpha_weight must be in [0,1]").
    if ($rc -ne 0 -and $r.Contains($Want)) { return $true }
    $r300 = if ($r.Length -gt 300) { $r.Substring(0, 300) } else { $r }
    Write-Host "      expected error `"$Want`", got rc=${rc}: $r300"
    return $false
}

# The crash discriminator: a clean SQL error prints "Runtime error: ..."
# (or, for per-argument SQL, "Error in <N>th command line argument: ...")
# and exits non-zero; a segfault kills the process with no such line.
function Test-Crashed {
    param([string]$R, [int]$Rc)
    if ($Rc -eq 0) { return $false }
    if ($R.Contains('Runtime error') -or $R.Contains('command line argument')) { return $false }
    return $true
}

function Set-EvilTrigger {
    param([string]$Value)
    [IO.File]::WriteAllText($script:EvilTrig, "$Value`n")
    [IO.File]::WriteAllText($script:EvilTrigRepo, "$Value`n")
}

function BtSetup {
    if (-not $script:Sqlite3) {
        Fail 'runtime setup: no sqlite3 CLI on PATH (set FSQL_SQLITE3)'
        return $false
    }
    if (-not (Resolve-Ext)) {
        Fail 'runtime setup: no extension found -- run gate 01 or set FSQL_EXT'
        return $false
    }
    $script:Db = Join-Path $script:PlugDir 'bt.db'

    # Fixture DB: a throwaway file in WAL mode (WAL so gate 12's
    # concurrent worker connections share it).
    if (Test-Path -LiteralPath $script:PlugDir) {
        cmd /c "rmdir /s /q $script:PlugDir" 2>$null | Out-Null
    }
    New-Item -ItemType Directory -Force $script:PlugDir | Out-Null
    & $script:Sqlite3 $script:Db 'PRAGMA journal_mode=WAL;' *> $null
    if ($LASTEXITCODE -ne 0) {
        Fail "runtime setup: cannot initialize $($script:Db)"
        return $false
    }

    # Shared fixtures. Kept minimal so gate 03's auto-discovery
    # assertions stay meaningful; gate-specific tables are created by
    # their own gates.
    $ddl = @'
CREATE TABLE bt_customers(
      id INTEGER PRIMARY KEY, name TEXT NOT NULL, status TEXT);
    CREATE TABLE bt_orders(
      id INTEGER PRIMARY KEY,
      customer_id INTEGER NOT NULL REFERENCES bt_customers(id),
      total INTEGER NOT NULL);
    CREATE TABLE bt_explore(id INTEGER PRIMARY KEY, embedding TEXT);
    WITH RECURSIVE c(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM c WHERE x<59)
    INSERT INTO bt_explore(embedding)
    SELECT CASE x%3
             WHEN 0 THEN (CASE x%2 WHEN 0 THEN '1.00,0.05,0.00,0.00'
                                   ELSE '0.95,0.05,0.00,0.00' END)
             WHEN 1 THEN (CASE x%2 WHEN 0 THEN '0.05,1.00,0.00,0.00'
                                   ELSE '0.05,0.95,0.00,0.00' END)
             ELSE        (CASE x%2 WHEN 0 THEN '0.05,0.00,1.00,0.00'
                                   ELSE '0.05,0.00,0.95,0.00' END)
           END
    FROM c;
    CREATE TABLE bt_telemetry(id INTEGER PRIMARY KEY, vec TEXT);
    INSERT INTO bt_telemetry(vec) VALUES
      ('0.6,0.8,0.0,0.0'),('0.1,0.2,-0.3,0.4'),('0.9,0.1,0.0,0.0'),
      ('0.5,0.5,0.5,0.5'),('0.0,0.0,0.0,1.0'),('0.2,0.2,0.2,0.2'),
      ('0.8,0.6,0.0,0.0'),('0.0,0.9,0.1,0.0');
    CREATE TABLE bt_corpus(id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
    INSERT INTO bt_corpus(body, emb) VALUES
      ('doc-a about cosine metrics','1.0,0.05,0.0,0.0'),
      ('doc-b about vector stores','1.0,0.1,0.0,0.0'),
      ('doc-c about fractal search','0.05,1.0,0.0,0.0'),
      ('doc-d on SFS optimization','0.1,0.95,0.0,0.0'),
      ('doc-e on embedding tiers','0.05,0.0,1.0,0.0'),
      ('doc-f on queue processing','0.0,0.05,0.95,0.0');
    CREATE TABLE bt_traj(id INTEGER PRIMARY KEY, vec TEXT);
    INSERT INTO bt_traj(vec) VALUES
      ('0.0,0.0,0.0,0.0'),('0.1,0.0,0.0,0.0'),('0.2,0.0,0.0,0.0'),
      ('0.3,0.0,0.0,0.0'),('0.4,0.0,0.0,0.0');
    CREATE TABLE bt_soak(worker INTEGER, it INTEGER, tag TEXT);
'@
    & $script:Sqlite3 $script:Db $ddl *> $null
    if ($LASTEXITCODE -ne 0) {
        Fail 'runtime setup: fixture DDL failed'
        return $false
    }

    Compile-Plugins
    return $true
}

# The tests\*.c fixtures are host-agnostic reasoning-ABI plugins: the
# extension dlopens them via fsql_load_reasoning, so they build the same
# way on every host (gcc -shared -fPIC -std=c99 -Iinclude; mingw gcc
# auto-exports the entry symbol, no .def file needed).
function Compile-Plugins {
    $names = @('mock_reasoning_plugin', 'evil_lying_length_plugin',
               'evil_crash_plugin', 'retry_reasoning_plugin',
               'think_reasoning_plugin', 'mock_embed_plugin',
               'evil_embed_plugin')
    foreach ($name in $names) {
        $log = Join-Path $script:PlugDir "$name.log"
        & $script:Cc -shared -fPIC -std=c99 -Iinclude "tests/$name.c" `
            -o (Join-Path $script:PlugDir "$name.dll") 1>$log 2>&1
        if ($LASTEXITCODE -ne 0) {
            Add-Content -LiteralPath (Join-Path $script:PlugDir 'compile_failures') -Value $name
        }
    }
    # evil_nonterminating: the POSIX fixture needs mmap/mprotect (sys/
    # mman.h), which mingw gcc has no header for -- the same reason the
    # MSYS runner skips gate 05. The Windows port of the identical
    # guard-page technique (tests\windows\evil_nonterminating_plugin_win.c,
    # VirtualAlloc/VirtualProtect) builds with the same gcc line, so gate
    # 05 actually runs here instead of skipping.
    $name = 'evil_nonterminating_plugin'
    $log = Join-Path $script:PlugDir "$name.log"
    & $script:Cc -shared -fPIC -std=c99 -Iinclude `
        'tests/windows/evil_nonterminating_plugin_win.c' `
        -o (Join-Path $script:PlugDir "$name.dll") 1>$log 2>&1
    if ($LASTEXITCODE -ne 0) {
        Add-Content -LiteralPath (Join-Path $script:PlugDir 'compile_failures') -Value $name
    }
    # Canonical plugin paths: native backslash form, so the configured path
    # equals its realpath (fsql_load_reasoning's anti-symlink check
    # compares the strings exactly). Join-Path already answers in that form.
    $script:Mock = Join-Path $script:PlugDir 'mock_reasoning_plugin.dll'
    $script:EvilNt = Join-Path $script:PlugDir 'evil_nonterminating_plugin.dll'
    $script:Lying = Join-Path $script:PlugDir 'evil_lying_length_plugin.dll'
    $script:Crash = Join-Path $script:PlugDir 'evil_crash_plugin.dll'
    $script:Retry = Join-Path $script:PlugDir 'retry_reasoning_plugin.dll'
    $script:Think = Join-Path $script:PlugDir 'think_reasoning_plugin.dll'
    $script:MockEmb = Join-Path $script:PlugDir 'mock_embed_plugin.dll'
    $script:EvilEmb = Join-Path $script:PlugDir 'evil_embed_plugin.dll'
}

# Skip a gate whose fixture plugin did not compile (platform-limited
# plugin) -- the same probe-compile posture build_test.sh takes.
function HavePlugin { param([string]$Path) Test-Path -LiteralPath $Path }

# Called by every python-driven gate (08, 12, 16, 19, 25, 31) after its own
# no-python skip check. Under -Asan/-Ubsan, python's load_extension() of the
# instrumented DLL hits a Windows-only "file already exists" error -- not a
# bug in the extension (a bare LoadLibraryW on the same DLL succeeds, the
# plain build never hits it, and every sqlite3.exe-CLI gate loading the same
# sanitizer DLL works fine). Root cause still open; skipping costs nothing
# since these gates never got past the load anyway.
function Skip-IfPySanitizerBlocked {
    param([string]$Label)
    if ($Asan -or $Ubsan) {
        Skip "$Label (python load_extension() under -Asan/-Ubsan hits a known Windows harness issue)"
        return $true
    }
    return $false
}

# PyRun <name> -- run an embedded python driver; each driver is written to
# $PlugDir and receives the DB/extension paths via env.
function PyRun {
    param([string]$Name)
    $env:FSQL_BT_DB = $script:Db
    $env:FSQL_BT_EXT = $script:ExtAbs
    & $script:Py (Join-Path $script:PlugDir "$Name.py")
}

function Write-TextFile {  # no-BOM, exact content (no added trailing newline)
    param([string]$Path, [string]$Content)
    [IO.File]::WriteAllText($Path, $Content)
}

# bash has no float compare -- a one-shot python float check (skipped
# cleanly where python is absent, with the integer-equality case still
# covered by the caller).
function PyAbsLt1e6 { param([string]$V)
    if (-not $script:Py) { return ($V -eq '0' -or $V -eq '0.0') }
    & $script:Py -c "import sys; sys.exit(0 if abs(float('''$V'''))<1e-6 else 1)" *> $null
    return ($LASTEXITCODE -eq 0)
}

# helper: expect a text_to_sql rejection containing $Want (or PASS if $Want
# empty). $Label is prefixed with the calling gate's own number since this
# helper is shared by gates 04 and 13.
function T2sExpect {
    param([string]$Canned, [string]$Want, [string]$Label)
    [IO.File]::WriteAllText($script:SqlTxt, $Canned)
    $r = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:Mock)');" `
        "SELECT fractalsql_set('text_to_sql_allowed_statements','select');" `
        "SELECT fractal_text_to_sql('q');"
    $rc = $script:SqlqRc
    if (-not $Want) {
        if ($rc -eq 0) { Pass "$Label → returned" }
        else { Fail "$Label (expected PASS): $r" }
    }
    else {
        if ($rc -ne 0 -and $r.Contains($Want)) { Pass "$Label → rejected ($Want)" }
        else { Fail "${Label}: got '$r' (want '$Want')" }
    }
}

# ======================================================================
# Gates
# ======================================================================

# Shared by the plain build.bat path and the -Asan/-Ubsan paths below.
function Resolve-SqliteDir {
    if ($env:FSQL_SQLITE_DIR) { return $env:FSQL_SQLITE_DIR }
    $sib = [IO.Path]::GetFullPath((Join-Path $script:Here '..\fractalsql-core\fsql_sqlite_ledger\src'))
    if (Test-Path -LiteralPath (Join-Path $sib 'sqlite3ext.h')) { return $sib }
    return 'C:\deps\sqlite'
}

# /GL+/LTCG dropped (incompatible with /fsanitize=address); /MT unchanged.
# The vendored core .lib is linked as-is, unrebuilt. Requires cl.exe already
# on PATH (a Developer Command Prompt / activated MSVC shell).
function Build-AsanExtension {
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        throw "cl.exe not on PATH. Activate MSVC first (Native Tools Command Prompt / ilammy/msvc-dev-cmd)."
    }
    $outDir = Join-Path $script:Here 'dist\windows-asan'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $sqliteDir   = Resolve-SqliteDir
    $coreVariant = if ($env:CORE_VARIANT) { $env:CORE_VARIANT } else { 'community-sovereign-c' }
    $coreLib     = Join-Path $script:Here "include\windows-x86_64\fractalsql-$coreVariant.lib"
    if (-not (Test-Path -LiteralPath $coreLib)) { throw "vendored core library not found: $coreLib" }
    $sovereignDefine = if ($coreVariant -like '*sovereign*') { '/DFSQL_SQLITE_SOVEREIGN' } else { $null }

    $srcFiles = @(Get-ChildItem -Path (Join-Path $script:Here 'src\*.c') | ForEach-Object { $_.FullName })
    $dll = Join-Path $outDir 'fractalsql.dll'

    $commonCompileArgs = @(
        '/nologo', '/MT', '/O2', '/fsanitize=address', '/Zi', '/c',
        '/DWIN32', '/D_WINDOWS', '/DFSQL_STATIC'
    )
    if ($sovereignDefine) { $commonCompileArgs += $sovereignDefine }
    $commonCompileArgs += @("/I$sqliteDir", "/I$(Join-Path $script:Here 'include')", "/I$(Join-Path $script:Here 'src')")

    $objs = @()
    foreach ($src in $srcFiles) {
        $obj = Join-Path $outDir ([IO.Path]::GetFileNameWithoutExtension($src) + '.obj')
        & cl.exe @commonCompileArgs "/Fo$obj" $src
        if ($LASTEXITCODE -ne 0) { throw "ASan compile failed for $(Split-Path -Leaf $src) (exit $LASTEXITCODE)" }
        $objs += $obj
    }

    $linkArgs = @('/nologo', '/LD') + $objs + @(
        "/Fe$dll",
        '/link', '/DEBUG',
        '/EXPORT:sqlite3_fractalsql_init',
        $coreLib, 'bcrypt.lib'
    )
    & cl.exe @linkArgs
    if ($LASTEXITCODE -ne 0) { throw "ASan link failed for $dll (exit $LASTEXITCODE)" }
    if (-not (Test-Path -LiteralPath $dll)) { throw "ASan build did not produce $dll" }
    Write-Host ("  -> {0} ({1:N0} bytes)" -f $dll, (Get-Item $dll).Length)
    return $dll
}

# Same structure as Build-AsanExtension above, via clang-cl.
function Build-UbsanExtension {
    $outDir = Join-Path $script:Here 'dist\windows-ubsan'
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null

    $sqliteDir   = Resolve-SqliteDir
    $coreVariant = if ($env:CORE_VARIANT) { $env:CORE_VARIANT } else { 'community-sovereign-c' }
    $coreLib     = Join-Path $script:Here "include\windows-x86_64\fractalsql-$coreVariant.lib"
    if (-not (Test-Path -LiteralPath $coreLib)) { throw "vendored core library not found: $coreLib" }
    $sovereignDefine = if ($coreVariant -like '*sovereign*') { '/DFSQL_SQLITE_SOVEREIGN' } else { $null }

    $srcFiles = @(Get-ChildItem -Path (Join-Path $script:Here 'src\*.c') | ForEach-Object { $_.FullName })
    $dll = Join-Path $outDir 'fractalsql.dll'

    # /MD, not /MT: LLVM's prebuilt clang_rt.ubsan_standalone-x86_64.lib
    # expects dynamic-CRT import-thunk symbols.
    $commonCompileArgs = @(
        '/nologo', '/MD', '/O2', '-fsanitize=undefined', '/Zi', '/c',
        '/DWIN32', '/D_WINDOWS', '/DFSQL_STATIC'
    )
    if ($sovereignDefine) { $commonCompileArgs += $sovereignDefine }
    $commonCompileArgs += @("/I$sqliteDir", "/I$(Join-Path $script:Here 'include')", "/I$(Join-Path $script:Here 'src')")

    $objs = @()
    foreach ($src in $srcFiles) {
        $obj = Join-Path $outDir ([IO.Path]::GetFileNameWithoutExtension($src) + '.obj')
        & $script:ClangCl @commonCompileArgs "/Fo$obj" $src
        if ($LASTEXITCODE -ne 0) { throw "UBSan compile failed for $(Split-Path -Leaf $src) (exit $LASTEXITCODE)" }
        $objs += $obj
    }

    $linkArgs = @('/nologo', '/LD') + $objs + @(
        "/Fe$dll",
        '/link', '/DEBUG',
        '/EXPORT:sqlite3_fractalsql_init',
        $coreLib, 'bcrypt.lib'
    )
    & $script:ClangCl @linkArgs
    if ($LASTEXITCODE -ne 0) { throw "UBSan link failed for $dll (exit $LASTEXITCODE)" }
    if (-not (Test-Path -LiteralPath $dll)) { throw "UBSan build did not produce $dll" }
    Write-Host ("  -> {0} ({1:N0} bytes)" -f $dll, (Get-Item $dll).Length)
    return $dll
}

function Gate-01-Build {
    $extOpt = if ($Ext) { $Ext } elseif ($env:FSQL_EXT) { $env:FSQL_EXT } else { '' }
    if ($extOpt) {
        $script:Ext = $extOpt
        $script:ExtAbs = if ([IO.Path]::IsPathRooted($extOpt)) { $extOpt }
                         else { Join-Path $script:Here $extOpt }
        $script:ExtLoad = if ($script:ExtAbs.StartsWith($script:Here, [StringComparison]::OrdinalIgnoreCase)) {
            $script:Ext
        }
        else { $script:ExtAbs }
        if (Test-Path -LiteralPath $script:ExtAbs) {
            Pass "01 build (FSQL_EXT override: $($script:Ext))"
        }
        else {
            Fail "01 build: FSQL_EXT=$($script:Ext) does not exist"
        }
        return
    }

    if ($Asan -or $Ubsan) {
        $sanTag = if ($Asan) { 'ASan' } else { 'UBSan' }
        try {
            $dll = if ($Asan) { Build-AsanExtension } else { Build-UbsanExtension }
        }
        catch {
            Fail "01 build [$sanTag]: $($_.Exception.Message)"
            return
        }
        $distSubdir = if ($Asan) { 'dist\windows-asan' } else { 'dist\windows-ubsan' }
        $script:Ext = "$distSubdir\fractalsql.dll"
        $script:ExtAbs = $dll
        $script:ExtLoad = $script:Ext
        Pass "01 build (MSVC via Build-${sanTag}Extension) [$sanTag]"
        return
    }

    # The Windows build arbiter is scripts\windows\build.bat (MSVC) --
    # gate 01 actually runs it (the POSIX runner only consumes the prebuilt
    # DLL, since Git Bash has no make + sqlite3ext.h pair).
    $buildLog = Join-Path $script:BTROOT 'fractalsql_bt_build.log'
    $vcvars = Get-ChildItem 'C:\Program Files\Microsoft Visual Studio\*\*\VC\Auxiliary\Build\vcvarsall.bat' `
        -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    $clCmd = Get-Command cl -ErrorAction SilentlyContinue
    $sqliteDir = Resolve-SqliteDir

    if (-not $clCmd -and -not $vcvars) {
        # No MSVC anywhere: fall back to the prebuilt artifact, mirroring
        # build_test.sh's MSYS-branch wording.
        if (Test-Path -LiteralPath (Join-Path $script:Here 'dist\windows\fractalsql.dll')) {
            $script:Ext = 'dist\windows\fractalsql.dll'
            $script:ExtAbs = Join-Path $script:Here 'dist\windows\fractalsql.dll'
            $script:ExtLoad = $script:Ext
            Pass '01 build (prebuilt MSVC artifact; full MSVC build runs via build_test.ps1)'
        }
        else {
            Fail '01 build: no dist\windows\fractalsql.dll (run scripts\windows\build.bat)'
        }
        return
    }

    $boot = Join-Path $script:BTROOT 'fractalsql_bt_build_cmd.bat'
    $lines = @('@echo off')
    if ($vcvars) { $lines += "call `"$vcvars`" x64 >nul 2>&1" }
    $lines += "set `"SQLITE_DIR=$sqliteDir`""
    $lines += "call `"$script:Here\scripts\windows\build.bat`""
    $lines += 'exit /b %ERRORLEVEL%'
    [IO.File]::WriteAllLines($boot, $lines)
    [IO.File]::WriteAllLines($buildLog, @("=== gate 01: MSVC build via scripts\windows\build.bat (SQLITE_DIR=$sqliteDir) ==="))
    # BTROOT is <drive>:\tmp -- never a spaced path -- so the boot script
    # needs no embedded quoting (cmd cannot parse PS's \" escape form).
    & cmd /c "call $boot" *>> $buildLog
    $rc = $LASTEXITCODE
    if ($rc -eq 0 -and (Test-Path -LiteralPath (Join-Path $script:Here 'dist\windows\fractalsql.dll'))) {
        $script:Ext = 'dist\windows\fractalsql.dll'
        $script:ExtAbs = Join-Path $script:Here 'dist\windows\fractalsql.dll'
        $script:ExtLoad = $script:Ext
        Pass '01 build (MSVC via scripts\windows\build.bat)'
    }
    else {
        Fail "01 build — see $buildLog"
        # MSVC diagnostics often lack the literal "error:" string
        # ("fatal error C1083", "error LNK2001:"), so match broadly and
        # fall back to the log tail — otherwise the failure prints
        # nothing at all (observed on the windows-2022 gates).
        $hits = Get-Content -LiteralPath $buildLog -ErrorAction SilentlyContinue |
            Select-String -Pattern 'error|LNK|fatal|unresolved' | Select-Object -First 6
        if ($hits) {
            $hits | ForEach-Object { Write-Host "         $($_.Line)" }
        }
        else {
            Write-Host "         (no error-pattern lines; log tail:)"
            Get-Content -LiteralPath $buildLog -ErrorAction SilentlyContinue -Tail 12 |
                ForEach-Object { Write-Host "         $_" }
        }
    }
}

function Gate-02-Smoke {
    $ver = Sqlq 'SELECT fractalsql_version();'
    if ($ver -eq '2.0.0') { Pass "02 smoke: version=$ver" }
    else { Fail "02 smoke: version='$ver' (want 2.0.0)" }
    # fractal_search convergence: self-distance ~0
    $d = Sqlq "SELECT fractal_search('0.6,0.8,0.0,0.0','0.6,0.8,0.0,0.0');"
    if ($d -eq '0.0' -or (PyAbsLt1e6 $d)) { Pass "02 smoke: fractal_search self-distance=$d" }
    else { Fail "02 smoke: self-distance='$d'" }
    # ...and a nontrivial one: query at a corpus corner converges to ~its twin
    $d2 = Sqlq "SELECT fractal_search('0.1,0.2,-0.3,0.4','0.1,0.2,-0.3,0.4');"
    if (PyAbsLt1e6 $d2) { Pass "02 smoke: fractal_search convergence=$d2" }
    else { Fail "02 smoke: convergence=$d2" }
    $ed = Sqlq 'SELECT fractalsql_edition();'
    if ($ed -eq 'Community') { Pass "02 smoke: edition=$ed" }
    else { Fail "02 smoke: edition='$ed'" }
    # fractal_search_debug returns the FULL fsql_search_ptr result JSON
    # (not just the best_point extraction fractal_search uses) -- assert
    # the best_point key survives.
    $dbg = Sqlq "SELECT fractal_search_debug('0.6,0.8,0.0,0.0');"
    if ($dbg.Contains('best_point')) { Pass '02 smoke: fractal_search_debug has best_point' }
    else { Fail "02 smoke: fractal_search_debug='$dbg'" }
}

function Gate-03-SchemaContext {
    $ctx = Sqlq 'SELECT fractal_schema_context();'
    if ($ctx.Contains('id INTEGER PK')) { Pass '03 schema_context: PK' }
    else { Fail '03 schema_context: PK' }
    if ($ctx.Contains('name TEXT NOT NULL')) { Pass '03 schema_context: NOT NULL' }
    else { Fail '03 schema_context: NOT NULL' }
    if ($ctx.Contains('FOREIGN KEY (customer_id) REFERENCES bt_customers(id)')) {
        Pass '03 schema_context: FK'
    }
    else { Fail "03 schema_context: FK ($ctx)" }
    # auto-discovery (0-arg): must find both fixture tables on its own.
    # Relies on this gate running before gate 10 floods the schema.
    if ($ctx.Contains('bt_customers') -and $ctx.Contains('bt_orders')) {
        Pass '03 schema_context: auto-discovery finds both tables'
    }
    else { Fail "03 schema_context: auto-discovery='$ctx'" }
    # COMMENT ON TABLE has no SQLite analog (structural N/A) -- no comment
    # assertion here.
}

function Gate-04-TextToSql {
    T2sExpect 'SELECT count(*) FROM bt_orders' '' '04 valid-SELECT'
    T2sExpect 'SELECT 1; DROP TABLE bt_orders' 'exactly one SQL' '04 stacked'
    T2sExpect 'DROP TABLE bt_orders' 'not permitted' '04 DDL'
    T2sExpect 'DELETE FROM bt_orders' 'not permitted' '04 DELETE'
    # SQLite has no data-modifying CTE syntax: the WITH..DELETE form dies
    # at parse ("near \"DELETE\": syntax error"). The message below
    # documents the select-mode write posture for anything else that
    # parses.
    T2sExpect 'WITH d AS (DELETE FROM bt_orders RETURNING *) SELECT * FROM d' 'SQL does not parse' '04 modifying-CTE'
    T2sExpect 'SELECT nope FROM bt_orders' 'SQL does not parse' '04 bad-column'
    T2sExpect 'this is not sql at all ##' 'is not permitted' '04 unparseable'
    T2sExpect 'EXPLAIN SELECT 1' 'statement type "EXPLAIN" is not permitted' '04 EXPLAIN'
    $n = (& $script:Sqlite3 $script:Db 'SELECT count(*) FROM bt_orders;' 2>&1 |
        ForEach-Object { "$_" }) -join "`n"
    if ($n -eq '0') { Pass '04 never-executes (bt_orders still empty)' }
    else { Fail "04 never-executes: row count=$n" }
    # auto-discovery: the full GENERATE -> ALLOWLIST -> prepare pipeline
    # works off the auto-built schema context (0-arg registration).
    [IO.File]::WriteAllText($script:SqlTxt, 'SELECT count(*) FROM bt_orders')
    $auto = Sqlq "SELECT fractalsql_set('reasoning_plugin','$($script:Mock)');" "SELECT fractal_text_to_sql('q');"
    if ($script:SqlqRc -eq 0) {
        Pass '04 auto-discovery: text_to_sql off the auto-built context'
    }
    else { Fail "04 auto-discovery: got '$auto'" }
}

# Guard-page plugin: the response is deliberately NOT NUL-terminated and
# sits flush against an unmapped page, so any over-read SIGSEGVs instantly.
# Proves the pnstrdup(summary, summary_len) fix holds at all three call
# sites. Re-aim: the crash kills the whole sqlite3 process, so "survived"
# means the process exited (rc==0 or a clean SQL error).
function Gate-05-EvilOverread {
    if (-not (HavePlugin $script:EvilNt)) {
        Skip '05 evil_overread (evil_nonterminating_plugin did not build on this platform)'
        return
    }
    function Survived {
        param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Stmts)
        $r = Sqlq @Stmts
        $rc = $script:SqlqRc
        if (Test-Crashed $r $rc) {
            $r200 = if ($r.Length -gt 200) { $r.Substring(0, 200) } else { $r }
            Write-Host "      output: $r200"
            return $false
        }
        return $true
    }
    # The plugin reads its canned SQL from this env (inherited by the
    # in-process plugin). tests\windows\evil_nonterminating_plugin_win.c
    # hardcodes the same "SELECT 1" canned SQL, so the env override is
    # carried for fidelity with the POSIX fixture even though the Windows
    # variant ignores it.
    $env:FSQL_EVIL_SQL_FILE = $script:SqlTxt
    Set-EvilTrigger '1'
    if (Survived "SELECT fractalsql_set('reasoning_plugin','$($script:EvilNt)');" "SELECT fractal_text_to_sql('q');") {
        Pass '05 evil_overread: GENERATE path (non-terminated guard-page response) survived'
    }
    else { Fail '05 evil_overread: GENERATE path crashed the process' }
    if (Survived "SELECT fractalsql_set('reasoning_plugin','$($script:EvilNt)');" "SELECT fractal_reason('q','ctx');") {
        Pass '05 evil_overread: bare fractal_reason() survived'
    }
    else { Fail '05 evil_overread: bare fractal_reason() crashed the process' }
    Set-EvilTrigger '2'
    if (Survived "SELECT fractalsql_set('reasoning_plugin','$($script:EvilNt)');" `
            "SELECT fractalsql_set('text_to_sql_use_review','on');" `
            "SELECT fractal_text_to_sql('q');") {
        Pass '05 evil_overread: REVIEW path survived'
    }
    else { Fail '05 evil_overread: REVIEW path crashed the process' }
    $env:FSQL_EVIL_SQL_FILE = $null
    Set-EvilTrigger '1'
}

function Gate-06-CrashRecovery {
    if (-not (HavePlugin $script:Crash)) {
        Skip '06 crash_recovery (evil_crash_plugin did not build)'
        return
    }
    # Canary committed by a prior connection.
    $null = Sqlq 'CREATE TABLE IF NOT EXISTS bt_crash_canary(
          id INTEGER PRIMARY KEY, note TEXT);'
    $null = Sqlq 'DELETE FROM bt_crash_canary;'
    $null = Sqlq "INSERT INTO bt_crash_canary VALUES (42, 'pre-crash');"

    Set-EvilTrigger '1'
    $r = Sqlq "SELECT fractalsql_set('reasoning_plugin','$($script:Crash)');" `
        "SELECT fractal_reason('q','ctx');"
    $rc = $script:SqlqRc
    if (-not (Test-Crashed $r $rc)) {
        Fail "06 crash_recovery: expected a process crash, got rc=$rc out='$r'"
        return
    }
    Pass "06 crash_recovery: sqlite3 process died (rc=$rc)"

    # Recovery: poll until the dead process's locks release and the DB
    # reopens cleanly (WAL/journal replay on the next open), then the
    # prior data must be intact.
    $deadline = [DateTime]::UtcNow.AddSeconds(30.0 * $script:TimeoutMult)
    while ($true) {
        $out = (& $script:Sqlite3 $script:Db 'PRAGMA integrity_check;' 2>&1 |
            ForEach-Object { "$_" }) -join "`n"
        if (($out -split "`r?`n") -contains 'ok') { break }
        if ([DateTime]::UtcNow -ge $deadline) {
            Fail "06 crash_recovery: DB did not recover (integrity: $out)"
            return
        }
        Start-Sleep -Seconds 1
    }
    Pass '06 crash_recovery: DB reopened, integrity ok (WAL recovery)'
    $n = (& $script:Sqlite3 $script:Db "SELECT count(*) FROM bt_crash_canary WHERE id=42 AND note='pre-crash';" 2>&1 |
        ForEach-Object { "$_" }) -join "`n"
    if ($n -eq '1') { Pass '06 crash_recovery: canary row intact after crash' }
    else { Fail "06 crash_recovery: canary lost (count=$n)" }
}

function Gate-07-EvilLyingLength {
    if (-not (HavePlugin $script:Lying)) {
        Skip '07 evil_lying_length (evil_lying_length_plugin did not build)'
        return
    }
    function ExpectRej {
        param([string]$Label, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Stmts)
        $r = Sqlq @Stmts
        $rc = $script:SqlqRc
        if (Test-Crashed $r $rc) {
            Fail "07 $Label — process crashed — $r"
        }
        elseif ($r.Contains('implausible response length')) {
            Pass "07 $Label rejected cleanly"
        }
        else {
            Fail "07 $Label — expected rejection, got: $r"
        }
    }
    Set-EvilTrigger '1'
    ExpectRej 'GENERATE path' "SELECT fractalsql_set('reasoning_plugin','$($script:Lying)');" `
        "SELECT fractal_text_to_sql('q');"
    ExpectRej 'bare fractal_reason()' "SELECT fractalsql_set('reasoning_plugin','$($script:Lying)');" `
        "SELECT fractal_reason('q');"
    Set-EvilTrigger '2'
    ExpectRej 'REVIEW path' "SELECT fractalsql_set('reasoning_plugin','$($script:Lying)');" `
        "SELECT fractalsql_set('text_to_sql_use_review','on');" `
        "SELECT fractal_text_to_sql('q');"
    Set-EvilTrigger '1'
}

function Write-PyGate08 { param([string]$Path)
    $content = @'
import os, sqlite3, sys

db, ext = os.environ["FSQL_BT_DB"], os.environ["FSQL_BT_EXT"]
SQLITE_READ, SQLITE_DENY, SQLITE_OK = 20, 1, 0

con = sqlite3.connect(db)
con.enable_load_extension(True)
con.load_extension(ext)

# Control: allow-all authorizer -> schema_context sees the fixtures.
con.set_authorizer(lambda *a: SQLITE_OK)
try:
    v = con.execute("SELECT fractal_schema_context()").fetchone()[0]
    assert "bt_customers" in v, "control: fixture tables missing from context"
except Exception as e:
    print("FAIL control: %s" % e)
    sys.exit(1)

# Boundary: deny the introspection of bt_customers — both the PRAGMA
# table_info form (what schema_context actually issues per table; on
# builds without the bound-pragma form the argument arrives as arg2)
# and any direct READ of the table. The introspection must fail, and
# the error text must not carry the denied table's column detail.
SQLITE_PRAGMA = 19

def deny_read(action, arg1, arg2, db_name, trigger):
    if (action == SQLITE_PRAGMA and arg1 == "table_info"
            and arg2 == "bt_customers"):
        return SQLITE_DENY
    if action == SQLITE_READ and arg1 == "bt_customers":
        return SQLITE_DENY
    return SQLITE_OK

con.set_authorizer(deny_read)
try:
    v = con.execute("SELECT fractal_schema_context()").fetchone()[0]
    print("FAIL: schema_context returned data despite a denied introspection of bt_customers")
    sys.exit(1)
except sqlite3.Error as e:
    msg = str(e)
    if "name TEXT" in msg:
        print("FAIL: authorizer-denied error leaked schema detail: %s" % msg[:200])
        sys.exit(1)
    print("OK: denied read surfaced as a clean error (no leak): %s" % msg[:120])
    sys.exit(0)
'@
    [IO.File]::WriteAllText($Path, $content.Replace("`r`n", "`n"))
}

function Gate-08-Authz {
    if (-not $script:Py) {
        Skip '08 authz (no python3 with the stdlib sqlite3 module)'
        return
    }
    if (Skip-IfPySanitizerBlocked '08 authz') { return }
    Write-PyGate08 (Join-Path $script:PlugDir 'py_gate08.py')
    PyRun 'py_gate08'
    if ($LASTEXITCODE -eq 0) {
        Pass '08 authz: authorizer denial honored inside schema_context, no leak'
    }
    else { Fail '08 authz: see driver output above' }
}

function Gate-09-GucSuperuser {
    # Re-aim of PG's non-superuser GUC rejection: the same boundary is
    # enforced at fractalsql_set time -- a path key must be absolute with
    # no traversal segments, whatever the caller's privileges.
    if (ExpectErr 'must be an absolute path with no ''..'' segments' `
            "SELECT fractalsql_set('reasoning_plugin','plugins/mock.so');") {
        Pass '09 guc_superuser: relative reasoning_plugin rejected'
    }
    else { Fail '09 guc_superuser: relative path accepted' }
    if (ExpectErr 'must be an absolute path with no ''..'' segments' `
            "SELECT fractalsql_set('reasoning_plugin','$($script:BTROOT)\..\evil.dll');") {
        Pass '09 guc_superuser: traversal reasoning_plugin rejected'
    }
    else { Fail '09 guc_superuser: traversal path accepted' }
    # Control: the canonical absolute form is accepted (no load happens
    # at set time -- set-time validation only).
    $r = Sqlq "SELECT fractalsql_set('reasoning_plugin','$($script:Mock)');"
    if ($r -eq 'ok') { Pass '09 guc_superuser: canonical absolute path accepted' }
    else { Fail "09 guc_superuser: canonical path rejected: $r" }
}

function Gate-10-DosAndInjection {
    # 512-cap fires via DISCOVERY (513 tables in the DB), not an array
    # argument -- fractal_schema_context() is 0-arg here.
    $flood = (0..512 | ForEach-Object { "CREATE TABLE bt_dos_$($_)(id INTEGER);" }) -join "`n"
    $flood | & $script:Sqlite3 $script:Db *> $null
    if (ExpectErr 'more than 512 tables/views found' 'SELECT fractal_schema_context();') {
        Pass '10 dos_and_injection: 512-table cap fires at 513'
    }
    else { Fail '10 dos_and_injection: cap did not fire at 513 tables' }
    # Drop the flood before the injection case -- the cap fires at
    # discovery time and would mask it otherwise.
    $drop = (0..512 | ForEach-Object { "DROP TABLE bt_dos_$($_);" }) -join "`n"
    $drop | & $script:Sqlite3 $script:Db *> $null
    # An injection-shaped table name can be created literally (quoted);
    # schema_context must NOT carry it into SQL text -- introspection is
    # SKIPPED for names that cannot be safely embedded, and nothing is
    # ever executed.
    $null = Sqlq 'CREATE TABLE "bt; DROP TABLE bt_customers--"(id INTEGER);'
    $r = Sqlq 'SELECT fractal_schema_context();'
    $rc = $script:SqlqRc
    if ($rc -eq 0 -and -not $r.Contains('bt; DROP TABLE')) {
        Pass '10 dos_and_injection: injection-shaped name omitted from context (skipped, not smuggled)'
    }
    else { Fail "10 dos_and_injection: injection-shaped name carried into context: $r" }
    if ($rc -eq 0 -and $r.Contains('bt_customers')) {
        Pass '10 dos_and_injection: safe tables still introspected alongside the skip'
    }
    else { Fail "10 dos_and_injection: safe table introspection lost: $r" }
    $n = (& $script:Sqlite3 $script:Db "SELECT count(*) FROM sqlite_master WHERE name='bt_customers';" 2>&1 |
        ForEach-Object { "$_" }) -join "`n"
    if ($n -eq '1') { Pass '10 dos_and_injection: bt_customers survived (nothing executed)' }
    else { Fail '10 dos_and_injection: bt_customers missing — injection executed' }
}
function Gate-11-Scout {
    $r = Sqlq "SELECT fractal_search_explore(embedding, '1.0,0.05,0.0,0.0') FROM bt_explore;"
    $rc = $script:SqlqRc
    if ($rc -ne 0) {
        Fail "11 scout: fractal_search_explore failed: $r"
        return
    }
    if (-not $script:Py) {
        if ($r.Contains('population')) {
            Pass '11 scout: population key present (python absent, JSON unverified)'
        }
        else { Fail "11 scout: no population key: $r" }
        return
    }
    $code = @'
import json, sys
d = json.loads(sys.stdin.read())
pop = d.get("population")
assert pop and len(pop) >= 5, "population missing/short: %s" % (pop and len(pop))
groups = {round(p[0], 1) for p in pop}
assert len(groups) >= 2, "population collapsed onto one point group: %s" % groups
print("ok: %d population points, %d distinct x-groups" % (len(pop), len(groups)))
'@
    # $code embeds literal double quotes ("population", ...) -- passed
    # via -c as a single argv element to python.exe, those get mangled
    # by Windows PowerShell <7.3's native-argv construction (same class
    # of bug Sqlq's $hasDq stdin path works around for sqlite3.exe).
    # Writing the script to a file sidesteps argv quoting entirely; $r
    # (the JSON under test) still rides in over stdin, unaffected.
    $pyTmp = Join-Path $script:PlugDir 'gate11_check.py'
    [IO.File]::WriteAllText($pyTmp, $code)
    $r | & $script:Py $pyTmp *> $null
    if ($LASTEXITCODE -eq 0) {
        Pass '11 scout: population returned and disperses across distinct points'
    }
    else { Fail "11 scout: population JSON/distinctness check failed: $r" }
    # Options-JSON variant accepted. The JSON rides inside a SQL
    # single-quoted literal, so the embedded double quotes are legal SQL
    # here (PS doubling "" turns them into real quotes; Sqlq then routes
    # the whole statement through the stdin pipe instead of argv).
    $r = Sqlq "SELECT fractal_search_explore(embedding, '1.0,0.05,0.0,0.0',
            '{""population_size"":24,""iterations"":12}') FROM bt_explore;"
    if ($script:SqlqRc -eq 0) { Pass '11 scout: options-JSON variant accepted' }
    else { Fail "11 scout: options variant failed: $r" }
}

function Write-PyGate12 { param([string]$Path)
    $content = @'
import os, sqlite3, subprocess, sys

db, ext = os.environ["FSQL_BT_DB"], os.environ["FSQL_BT_EXT"]
workers = int(os.environ.get("SOAK_WORKERS", "6"))
iters = int(os.environ.get("SOAK_ITERS", "15"))

WORKER = r'''
import json, sqlite3, sys
db, ext, wid, iters = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
con = sqlite3.connect(db, timeout=30)
con.enable_load_extension(True)
con.load_extension(ext)
for i in range(iters):
    d = con.execute(
        "SELECT fractal_search('0.6,0.8,0.0,0.0','0.6,0.8,0.0,0.0')"
    ).fetchone()[0]
    if abs(d) > 1e-6:
        raise SystemExit("worker %s iter %s: dist %r" % (wid, i, d))
    con.execute("INSERT INTO bt_soak(worker, it) VALUES (?,?)", (wid, i))
    if i % 5 == 4:
        r = con.execute(
            "SELECT fractal_search_explore(embedding, '1.0,0.05,0.0,0.0') FROM bt_explore"
        ).fetchone()[0]
        json.loads(r)
con.commit()
print("worker %s ok" % wid)
'''
with open(os.path.join(os.path.dirname(db), "g12_worker.py"), "w") as f:
    f.write(WORKER)

procs = [subprocess.Popen([sys.executable,
                           os.path.join(os.path.dirname(db), "g12_worker.py"),
                           db, ext, str(w), str(iters)],
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
         for w in range(workers)]
bad = 0
for w, p in enumerate(procs):
    out = p.communicate()[0].decode(errors="replace")
    if p.returncode != 0:
        bad += 1
        print("worker %s rc=%s: %s" % (w, p.returncode, out.strip()[:300]))

con = sqlite3.connect(db, timeout=30)
con.enable_load_extension(True)
con.load_extension(ext)
n = con.execute("SELECT count(*) FROM bt_soak").fetchone()[0]
expected = workers * iters
assert n == expected, "expected %d soak rows, found %d" % (expected, n)
r = con.execute(
    "SELECT fractal_search('0.6,0.8,0.0,0.0','0.6,0.8,0.0,0.0')"
).fetchone()[0]
assert abs(r) < 1e-6, "DB not responsive after soak: %r" % r
assert bad == 0, "%d worker(s) failed" % bad
print("SOAK OK: %d workers x %d iters, %d rows" % (workers, iters, n))
'@
    [IO.File]::WriteAllText($Path, $content.Replace("`r`n", "`n"))
}

function Gate-12-Soak {
    if (-not $script:Py) {
        Skip '12 soak (no python3 with the stdlib sqlite3 module)'
        return
    }
    if (Skip-IfPySanitizerBlocked '12 soak') { return }
    if ($env:SOAK_WORKERS) { $soakW = $env:SOAK_WORKERS } else { $soakW = '6' }
    if ($env:SOAK_ITERS)   { $soakI = $env:SOAK_ITERS }   else { $soakI = '15' }
    $env:SOAK_WORKERS = $soakW
    $env:SOAK_ITERS = $soakI
    Write-PyGate12 (Join-Path $script:PlugDir 'py_gate12.py')
    PyRun 'py_gate12'
    if ($LASTEXITCODE -eq 0) {
        Pass "12 soak: $soakW workers x $soakI iters, DB responsive after"
    }
    else { Fail '12 soak: see driver output above' }
}

function Gate-13-SiuMode {
    # allowlist widened to select+insert+update: the widened classes come
    # back as text (never executed); DDL/DELETE stay rejected.
    function Siu {
        param([string]$Canned, [string]$Want, [string]$Label)
        [IO.File]::WriteAllText($script:SqlTxt, $Canned)
        $r = Sqlq `
            "SELECT fractalsql_set('reasoning_plugin','$($script:Mock)');" `
            "SELECT fractalsql_set('text_to_sql_allowed_statements',
            'select_insert_update');" `
            "SELECT fractal_text_to_sql('q');"
        $rc = $script:SqlqRc
        if (-not $Want) {
            if ($rc -eq 0) { Pass "13 $Label → returned" }
            else { Fail "13 $Label (expected return): $r" }
        }
        else {
            if ($rc -ne 0 -and $r.Contains($Want)) { Pass "13 $Label → rejected ($Want)" }
            else { Fail "13 ${Label}: got '$r' (want '$Want')" }
        }
    }
    $null = Sqlq 'DELETE FROM bt_orders;'
    Siu 'INSERT INTO bt_orders(id, customer_id, total) VALUES (777,1,10)' '' 'widened INSERT'
    Siu 'UPDATE bt_orders SET total=999' '' 'widened UPDATE'
    Siu 'DELETE FROM bt_orders' 'not permitted' 'DELETE stays rejected'
    Siu 'DROP TABLE bt_orders' 'not permitted' 'DDL stays rejected'
    $n = (& $script:Sqlite3 $script:Db 'SELECT count(*) FROM bt_orders;' 2>&1 |
        ForEach-Object { "$_" }) -join "`n"
    if ($n -eq '0') { Pass '13 widened classes never executed (bt_orders still empty)' }
    else { Fail "13 widened classes executed (count=$n)" }
}

function Gate-14-Retry {
    if (-not (HavePlugin $script:Retry)) {
        Skip '14 retry (retry_reasoning_plugin did not build)'
        return
    }
    if (Test-Path -LiteralPath $script:RetryPrompt) { [IO.File]::Delete($script:RetryPrompt) }
    $r = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:Retry)');" `
        "SELECT fractalsql_set('text_to_sql_max_attempts','2');" `
        "SELECT fractal_text_to_sql('q');"
    if ($script:SqlqRc -eq 0 -and $r.Contains('SELECT 1')) {
        Pass '14 retry: attempt 1 rejected, attempt 2 succeeded'
    }
    else {
        Fail "14 retry: got '$r'"
        return
    }
    $prompt = if (Test-Path -LiteralPath $script:RetryPrompt) {
        [IO.File]::ReadAllText($script:RetryPrompt)
    }
    else { '' }
    if ($prompt -and $prompt.Contains('not permitted')) {
        Pass '14 retry: rejection reason threaded into the attempt-2 prompt'
    }
    else { Fail '14 retry: attempt-2 prompt missing the rejection reason' }
}

function Gate-15-Embed {
    # fractal_embed() itself — real dispatch through the EMBED tier.
    $d = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:MockEmb)');" `
        "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" `
        "SELECT fractal_vector_dims(fractal_embed('hello'));"
    $lastLine = (($d -split "`r?`n") | Select-Object -Last 1)
    if ($lastLine -eq '3') {
        Pass '15 embed: fractal_embed returns the canned 3-dim vector'
    }
    else { Fail "15 embed: dims='$d'" }
    if (ExpectErr 'fractal_embed: input must not be NULL' 'SELECT fractal_embed(NULL);') {
        Pass '15 embed: NULL input rejected'
    }
    else { Fail '15 embed: NULL input not rejected' }
    if (ExpectErr 'reasoning plugin not configured' "SELECT fractal_embed('x');") {
        Pass '15 embed: unconfigured embed errors with the set() hint'
    }
    else { Fail '15 embed: unconfigured embed did not error' }
    if (ExpectErr 'http_embed_url is not configured' `
            "SELECT fractalsql_set('reasoning_plugin','$($script:MockEmb)');" `
            "SELECT fractal_embed('x');") {
        Pass '15 embed: chat-only config rejected (no http_url fallback)'
    }
    else { Fail '15 embed: missing http_embed_url did not error' }
    if (ExpectErr 'failed to load reasoning plugin' `
            "SELECT fractalsql_set('reasoning_plugin','C:\nonexistent\nope.dll');" `
            "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" `
            "SELECT fractal_embed('x');") {
        Pass '15 embed: unloadable plugin errors clearly'
    }
    else { Fail '15 embed: bad plugin path did not error' }
    if (HavePlugin $script:EvilEmb) {
        if (ExpectErr 'could not parse embedding response' `
                "SELECT fractalsql_set('reasoning_plugin','$($script:EvilEmb)');" `
                "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" `
                "SELECT fractal_embed('x');") {
            Pass '15 embed: over-limit (16385-elem) response rejected'
        }
        else { Fail '15 embed: over-limit response not rejected' }
    }
    else {
        Skip '15 embed over-limit (evil_embed_plugin did not build)'
    }

    # The vectorizer: create / backfill / process_queue / status / write-back.
    # All in ONE connection (the registry+queue are TEMP).
    $r = Sqlq `
        'CREATE TABLE bt_vembed(
        id INTEGER PRIMARY KEY, body TEXT, emb TEXT);' `
        "INSERT INTO bt_vembed(body) VALUES ('a'),('b'),('c');" `
        "SELECT fractalsql_set('reasoning_plugin','$($script:MockEmb)');" `
        "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" `
        "SELECT fractal_vectorizer_create('bt_vembed','body','emb');" `
        "SELECT 'PROCESSED=' || fractal_vectorizer_process_queue(10);" `
        "SELECT 'DONE=' || n FROM fractal_vectorizer_status
      WHERE status='done';" `
        "SELECT 'D3=' || count(*) FROM bt_vembed
      WHERE fractal_vector_dims(emb)=3;" `
        "SELECT fractal_vectorizer_create('bt_vembed','body','emb');"
    # (-bail stops the invocation on the trailing double-create; the
    # assertions above still see everything printed before it. The
    # double-create MUST ride the same connection — the registry+queue
    # are TEMP, so a fresh connection would see an empty registry.)
    if ($r.Contains('PROCESSED=3') -and $r.Contains('DONE=3') -and $r.Contains('D3=3')) {
        Pass '15 vectorizer: create/backfill/process/status/write-back'
    }
    else { Fail "15 vectorizer: got '$r'" }
    if ($r.Contains('already exists')) { Pass '15 vectorizer: double-create rejected' }
    else { Fail '15 vectorizer: double-create accepted' }
    if (ExpectErr 'invalid identifier' `
            "SELECT fractal_vectorizer_create('bt; DROP TABLE bt_vembed--',
        'body','emb');") {
        Pass '15 vectorizer: injection-shaped source_table rejected'
    }
    else { Fail '15 vectorizer: injection-shaped source_table accepted' }
    # pause/resume/drop surface: a paused vectorizer defers (0 processed).
    $r = Sqlq `
        'CREATE TABLE bt_vsoak_stub(
        id INTEGER PRIMARY KEY, body TEXT, emb TEXT);' `
        "INSERT INTO bt_vsoak_stub(body) VALUES ('p');" `
        "SELECT fractalsql_set('reasoning_plugin','$($script:MockEmb)');" `
        "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" `
        "SELECT fractal_vectorizer_create('bt_vsoak_stub','body','emb');" `
        'SELECT fractal_vectorizer_pause(1);' `
        "SELECT 'P=' || fractal_vectorizer_process_queue(10);" `
        'SELECT fractal_vectorizer_resume(1);' `
        'SELECT fractal_vectorizer_drop(1);' `
        'SELECT 1;'
    if ($r.Contains('P=0')) {
        Pass '15 vectorizer: pause defers processing, resume/drop clean'
    }
    else { Fail "15 vectorizer: pause path: $r" }
}

function Write-PyGate16 { param([string]$Path)
    $content = @'
import os, sqlite3, sys

db, ext = os.environ["FSQL_BT_DB"], os.environ["FSQL_BT_EXT"]
SQLITE_PRAGMA, SQLITE_DENY, SQLITE_OK = 19, 1, 0

con = sqlite3.connect(db)
con.enable_load_extension(True)
con.load_extension(ext)
con.execute("CREATE TABLE IF NOT EXISTS bt_vauthz("
            "id INTEGER PRIMARY KEY, body TEXT, emb TEXT)")
con.execute("INSERT INTO bt_vauthz(body) VALUES ('x')")

# Control: allow-all authorizer -> the PK probe reads its PRAGMA and
# create() succeeds.
con.set_authorizer(lambda *a: SQLITE_OK)
try:
    con.execute("SELECT fractal_vectorizer_create("
                "'bt_vauthz','body','emb')").fetchone()
    print("OK control: vectorizer_create succeeded with allow-all")
except sqlite3.Error as e:
    print("FAIL control: create failed under allow-all authorizer: %s" % e)
    sys.exit(1)

# Boundary: deny the PRAGMA read the PK probe depends on -> create()
# must fail with a clean error (no crash, no silent wrong behavior).
def deny_pragma(action, arg1, arg2, db_name, trigger):
    if action == SQLITE_PRAGMA and (arg1 or "").startswith("table_info"):
        return SQLITE_DENY
    return SQLITE_OK

con.set_authorizer(deny_pragma)
try:
    con.execute("SELECT fractal_vectorizer_create("
                "'bt_vauthz','body','emb')").fetchone()
    print("FAIL: vectorizer_create succeeded despite a denied PRAGMA read")
    sys.exit(1)
except sqlite3.Error as e:
    print("OK boundary: denied PK probe surfaced as a clean error: %s"
          % str(e)[:120])
    sys.exit(0)
'@
    [IO.File]::WriteAllText($Path, $content.Replace("`r`n", "`n"))
}

function Gate-16-EmbedAuthz {
    # create-time validation (PG's create-time source_table ownership
    # maps to these guards — role grants have no SQLite analog).
    # A nonexistent table is indistinguishable from a PK-less one here:
    # PRAGMA table_info on a missing table returns no rows, so the create
    # answers the same "no single-column primary key" error (the probe
    # PRAGMA doesn't fail on a missing table — SQLite's shape).
    if (ExpectErr 'has no single-column primary key' `
            "SELECT fractal_vectorizer_create('bt_nonexistent_xyz',
        'body','emb');") {
        Pass '16 embed_authz: nonexistent source table rejected (no-PK error)'
    }
    else { Fail '16 embed_authz: nonexistent source table accepted' }
    $null = Sqlq 'CREATE TABLE bt_nopk(a INTEGER, b TEXT, emb TEXT);'
    if (ExpectErr 'has no single-column primary key' `
            "SELECT fractal_vectorizer_create('bt_nopk','b','emb');") {
        Pass '16 embed_authz: missing-PK table rejected'
    }
    else { Fail '16 embed_authz: missing-PK table accepted' }
    $null = Sqlq 'CREATE TABLE bt_compk(a INTEGER, b INTEGER, emb TEXT,
          PRIMARY KEY(a,b));'
    if (ExpectErr 'has no single-column primary key' `
            "SELECT fractal_vectorizer_create('bt_compk','b','emb');") {
        Pass '16 embed_authz: composite-PK table rejected'
    }
    else { Fail '16 embed_authz: composite-PK table accepted' }
    if (-not $script:Py) {
        Skip '16 embed_authz authorizer driver (no python3 sqlite3 stdlib)'
        return
    }
    if (Skip-IfPySanitizerBlocked '16 embed_authz authorizer driver') { return }
    Write-PyGate16 (Join-Path $script:PlugDir 'py_gate16.py')
    PyRun 'py_gate16'
    if ($LASTEXITCODE -eq 0) {
        Pass '16 embed_authz: authorizer denial honored inside the PK probe'
    }
    else { Fail '16 embed_authz: see driver output above' }
}

function Gate-17-EmbedSoak {
    # 100-row queue drained by repeated process_queue(batch=20) calls in
    # ONE connection (TEMP state): zero double-processing shows up as
    # done=100 / failed=0 with the last call returning 0.
    & $script:Sqlite3 $script:Db @'
    CREATE TABLE bt_vsoak(id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
    WITH RECURSIVE c(x) AS (VALUES(1)
                             UNION ALL SELECT x+1 FROM c WHERE x<100)
    INSERT INTO bt_vsoak(body) SELECT 'doc-' || x FROM c;
'@ *> $null
    if ($LASTEXITCODE -ne 0) {
        Fail '17 embed_soak: bt_vsoak setup failed'
        return
    }
    $r = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:MockEmb)');" `
        "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" `
        "SELECT fractal_vectorizer_create('bt_vsoak','body','emb');" `
        "SELECT 'P=' || fractal_vectorizer_process_queue(20);" `
        "SELECT 'P=' || fractal_vectorizer_process_queue(20);" `
        "SELECT 'P=' || fractal_vectorizer_process_queue(20);" `
        "SELECT 'P=' || fractal_vectorizer_process_queue(20);" `
        "SELECT 'P=' || fractal_vectorizer_process_queue(20);" `
        "SELECT 'P=' || fractal_vectorizer_process_queue(20);" `
        "SELECT 'DONE=' || COALESCE(SUM(n),0) FROM fractal_vectorizer_status
      WHERE status='done';" `
        "SELECT 'FAILED=' || COALESCE(SUM(n),0) FROM fractal_vectorizer_status
      WHERE status='failed';"
    $pcnt = (($r -split "`r?`n") | Where-Object { $_ -eq 'P=20' }).Count
    if ($pcnt -eq 5 -and $r.Contains('DONE=100') -and $r.Contains('FAILED=0')) {
        Pass '17 embed_soak: 100 rows processed exactly once (5x20, then 0)'
    }
    else { Fail "17 embed_soak: got '$r'" }
}

function Gate-18-EmbedCrash {
    if (-not (HavePlugin $script:Crash)) {
        Skip '18 embed_crash (evil_crash_plugin did not build)'
        return
    }
    & $script:Sqlite3 $script:Db @'
    CREATE TABLE bt_vcrash(id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
    INSERT INTO bt_vcrash(body) VALUES ('a'),('b');
'@ *> $null
    $r = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:Crash)');" `
        "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" `
        "SELECT fractal_vectorizer_create('bt_vcrash','body','emb');" `
        'SELECT fractal_vectorizer_process_queue(10);'
    $rc = $script:SqlqRc
    if (-not (Test-Crashed $r $rc)) {
        Fail "18 embed_crash: expected a process crash mid-queue, got rc=$rc"
        return
    }
    Pass "18 embed_crash: sqlite3 process died mid-process_queue (rc=$rc)"
    # A fresh connection must find the DB intact and the persisted
    # embeddings (gate 15's write-back) preserved. The TEMP queue state
    # died with the connection — no stuck-'processing' rows are even
    # possible, which is the structural difference from PG's queue.
    $deadline = [DateTime]::UtcNow.AddSeconds(30.0 * $script:TimeoutMult)
    while ($true) {
        $out = (& $script:Sqlite3 $script:Db 'PRAGMA integrity_check;' 2>&1 |
            ForEach-Object { "$_" }) -join "`n"
        if (($out -split "`r?`n") -contains 'ok') { break }
        if ([DateTime]::UtcNow -ge $deadline) {
            Fail "18 embed_crash: DB did not recover (integrity: $out)"
            return
        }
        Start-Sleep -Seconds 1
    }
    Pass '18 embed_crash: DB reopened, integrity ok'
    $n = (& $script:Sqlite3 $script:Db 'SELECT count(*) FROM bt_vcrash;' 2>&1 |
        ForEach-Object { "$_" }) -join "`n"
    if ($n -eq '2') { Pass '18 embed_crash: source rows intact after the crash' }
    else { Fail "18 embed_crash: source rows damaged (count=$n)" }
    $n = (& $script:Sqlite3 -cmd ".load $($script:ExtLoad)" $script:Db `
            'SELECT count(*) FROM bt_vembed
    WHERE fractal_vector_dims(emb)=3;' 2>&1 |
        ForEach-Object { "$_" }) -join "`n"
    if ($n -eq '3') {
        Pass '18 embed_crash: persisted embeddings from gate 15 preserved'
    }
    else { Fail "18 embed_crash: persisted embeddings damaged (count=$n)" }
}

function Write-PyGate19 { param([string]$Path)
    $content = @'
import os, sqlite3, struct, sys

db, ext = os.environ["FSQL_BT_DB"], os.environ["FSQL_BT_EXT"]
con = sqlite3.connect(db, timeout=30)
con.enable_load_extension(True)
con.load_extension(ext)

# Over-arena vector (ARENA_MAX_DIM=4096): the parse rejects it. The
# TEXT path clamps silently at the cap, so the over-budget rejection
# is only reachable through the float32 BLOB path, where
# fsql_parse_blob_vector refuses count > cap outright (4097 floats).
blob = struct.pack("<4097f", *([0.1] * 4097))
try:
    con.execute("SELECT fractal_search(?, ?)", (blob, blob)).fetchone()
except sqlite3.OperationalError as e:
    if "invalid vector" in str(e):
        print("OK: over-arena BLOB rejected: %s" % str(e)[:120])
        sys.exit(0)
    print("FAIL: over-arena BLOB rejected with the wrong error: %s" % e)
    sys.exit(1)
print("FAIL: over-arena BLOB accepted")
sys.exit(1)
'@
    [IO.File]::WriteAllText($Path, $content.Replace("`r`n", "`n"))
}

function Gate-19-SfsBounds {
    # Over-arena vector (ARENA_MAX_DIM=4096): the parse rejects it. The
    # TEXT path clamps at the cap (lenient surface), so the over-budget
    # rejection is exercised through the float32 BLOB path — a
    # 4097-float BLOB answers "invalid vector (expect CSV/JSON text or
    # float32 BLOB)" without ever reaching the solver.
    if (-not $script:Py) {
        Skip '19 sfs_bounds over-arena (no python3 with the stdlib sqlite3 module)'
    }
    elseif (Skip-IfPySanitizerBlocked '19 sfs_bounds over-arena') {
        # skipped
    }
    else {
        Write-PyGate19 (Join-Path $script:PlugDir 'py_gate19.py')
        PyRun 'py_gate19'
        if ($LASTEXITCODE -eq 0) { Pass '19 sfs_bounds: over-arena vector rejected' }
        else { Fail '19 sfs_bounds: over-arena vector accepted' }
    }
    if (ExpectErr 'invalid vector' "SELECT fractal_search('','1.0');") {
        Pass '19 sfs_bounds: empty vector rejected'
    }
    else { Fail '19 sfs_bounds: empty vector accepted' }
    if (ExpectErr 'query dim mismatch with vector' `
            "SELECT fractal_search('0.1,0.2','0.1,0.2,0.3');") {
        Pass '19 sfs_bounds: query/vector dim mismatch rejected'
    }
    else { Fail '19 sfs_bounds: dim mismatch accepted' }
    # fractal_search_explore folds its argument errors into its own aggregate
    # input-error message (the embed/query parse happens inside the
    # aggregate step, not per-row).
    if (ExpectErr 'fractal_search_explore input error' `
            "SELECT fractal_search_explore(embedding, '0.1,0.2,0.3,0.4,0.5')
       FROM bt_explore;") {
        Pass '19 sfs_bounds: explore dim mismatch rejected'
    }
    else { Fail '19 sfs_bounds: explore dim mismatch accepted' }
    # Injection-shaped query text: rejected as malformed, and provably
    # never executed.
    if (ExpectErr 'fractal_search_explore input error' `
            "SELECT fractal_search_explore(embedding,
        '0.1); DROP TABLE bt_explore--') FROM bt_explore;") {
        Pass '19 sfs_bounds: injection-shaped query rejected as malformed'
    }
    else { Fail '19 sfs_bounds: injection-shaped query accepted' }
    $n = (& $script:Sqlite3 $script:Db 'SELECT count(*) FROM bt_explore;' 2>&1 |
        ForEach-Object { "$_" }) -join "`n"
    if ($n -eq '60') { Pass '19 sfs_bounds: bt_explore survived (nothing executed)' }
    else { Fail "19 sfs_bounds: bt_explore damaged (count=$n)" }
}

function Gate-20-ApiFunc {
    # fractal_reason happy-path correctness through the chat tier (the
    # bare call gets the fenced form — RESPONSE_MODE is t2s-internal).
    [IO.File]::WriteAllText($script:SqlTxt, 'canary-reason-response')
    $r = Sqlq "SELECT fractalsql_set('reasoning_plugin','$($script:Mock)');" `
        "SELECT fractal_reason('q');"
    if ($r.Contains('canary-reason-response')) {
        Pass '20 api_func: fractal_reason returns the canned response'
    }
    else { Fail "20 api_func: fractal_reason='$r'" }
    if (ExpectErr 'fractal_reason: query must not be NULL' 'SELECT fractal_reason(NULL);') {
        Pass '20 api_func: fractal_reason(NULL) rejected'
    }
    else { Fail '20 api_func: fractal_reason(NULL) not rejected' }
    if (ExpectErr 'expects a TEXT question' 'SELECT fractal_text_to_sql(NULL);') {
        Pass '20 api_func: fractal_text_to_sql(NULL) rejected'
    }
    else { Fail '20 api_func: fractal_text_to_sql(NULL) not rejected' }
    # Options-JSON: the params surface is LENIENT here — a truncated JSON
    # prefix parses as far as it can and the rest clamps to defaults (the
    # same rc=0 shape gate 11's options variant accepts), so the
    # errorable boundary is only exercised via vector parse errors in
    # gate 19. Assert the documented behavior: malformed options still
    # return a full result.
    $opts = Sqlq "SELECT fractal_search_explore('1.0,0.0,0.0,0.0','1.0,0.0,0.0,0.0',
    '{""population_size"":');"
    if ($script:SqlqRc -eq 0 -and $opts.Contains('best_point')) {
        Pass '20 api_func: malformed explore options are lenient (clamped)'
    }
    else { Fail "20 api_func: malformed explore options errored: $opts" }
    # process_queue argument bounds.
    if (ExpectErr 'batch_size must be 1..' 'SELECT fractal_vectorizer_process_queue(0);') {
        Pass '20 api_func: process_queue(0) rejected'
    }
    else { Fail '20 api_func: process_queue(0) accepted' }
    if (ExpectErr 'stale_after must be a positive' `
            'SELECT fractal_vectorizer_process_queue(10, 0);') {
        Pass '20 api_func: process_queue(stale_after=0) rejected'
    }
    else { Fail '20 api_func: process_queue(stale_after=0) accepted' }
    # Stale-reclaim, staged directly: a claim stranded 7200s ago is
    # reclaimed (stale_after=60) and processed; the within-window control
    # row is left alone.
    $r2 = Sqlq `
        'CREATE TABLE bt_vstale(
        id INTEGER PRIMARY KEY, body TEXT, emb TEXT);' `
        "INSERT INTO bt_vstale(id, body)
      VALUES (995,'a'),(996,'b'),(997,'c'),(998,'d'),(999,'e');" `
        "SELECT fractalsql_set('reasoning_plugin','$($script:MockEmb)');" `
        "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" `
        "SELECT fractal_vectorizer_create('bt_vstale','body','emb');" `
        "UPDATE fractal_vectorizer_queue
      SET status='processing',
          processing_started_at=
            CAST(strftime('%s','now') AS INTEGER) - 7200
      WHERE source_pk_value='999';" `
        "UPDATE fractal_vectorizer_queue
      SET status='processing',
          processing_started_at=CAST(strftime('%s','now') AS INTEGER)
      WHERE source_pk_value='998';" `
        'SELECT fractal_vectorizer_process_queue(100, 60);' `
        "SELECT source_pk_value || ':' || status
       FROM fractal_vectorizer_queue ORDER BY id;"
    if ($r2.Contains('999:done') -and $r2.Contains('998:processing')) {
        Pass '20 api_func: stale claim reclaimed; fresh claim left alone'
    }
    else { Fail "20 api_func: stale reclaim staging: $r2" }
}

function Gate-21-FuzzSmoke {
    $fuzzcc = $env:FSQL_FUZZ_CC
    if (-not $fuzzcc) {
        $c = Get-Command clang -ErrorAction SilentlyContinue
        if ($c) { $fuzzcc = $c.Source }
    }
    if (-not $fuzzcc) {
        Skip '21 fuzz_smoke (no clang on PATH — libFuzzer drivers need it)'
        return
    }
    # libFuzzer capability probe. On Windows, lld-link cannot take a user
    # main() alongside -fsanitize=fuzzer (duplicate main symbol), so the
    # probe mirrors the real targets' shape instead — a bare
    # LLVMFuzzerTestOneInput stub, exactly what gets linked in the real
    # drivers. (Divergence from build_test.sh's `int main(void)` probe,
    # forced by the Windows toolchain.)
    $probe = Join-Path $script:PlugDir 'probe.c'
    Write-TextFile $probe 'int LLVMFuzzerTestOneInput(const unsigned char*d, unsigned long s){(void)d;(void)s;return 0;}'
    & $fuzzcc -fsanitize=fuzzer -O0 $probe `
        -o (Join-Path $script:PlugDir 'fuzz_probe.exe') `
        1>(Join-Path $script:PlugDir 'probe.log') 2>&1
    if ($LASTEXITCODE -ne 0) {
        Skip "21 fuzz_smoke ($([IO.Path]::GetFileName($fuzzcc)) lacks -fsanitize=fuzzer)"
        return
    }
    $fuzzTime = if ($env:FSQL_FUZZ_TIME) { $env:FSQL_FUZZ_TIME } else { '30' }
    foreach ($t in @('fuzz_parse_embedding_array', 'fuzz_extract_best_point',
                     'fuzz_extract_population')) {
        $src = "tests/fuzz/$t.c"
        & $fuzzcc -O1 -g -fsanitize=fuzzer -Iinclude -Isrc $src src/fsql_parse.c `
            -o (Join-Path $script:PlugDir "$t.exe") `
            1>(Join-Path $script:PlugDir "$t.log") 2>&1
        if ($LASTEXITCODE -ne 0) {
            Fail "21 fuzz_smoke: $t failed to build — see $(Join-Path $script:PlugDir "$t.log")"
            continue
        }
        # libFuzzer on Windows will not create the output seed corpus dir
        # itself (the POSIX side gets it implicitly) — pre-create it.
        $seed = Join-Path $script:PlugDir "${t}_seed"
        New-Item -ItemType Directory -Force $seed | Out-Null
        & (Join-Path $script:PlugDir "$t.exe") tests/fuzz/corpus_extract_population $seed `
            "-max_total_time=$fuzzTime" -print_final_stats=1 `
            1>(Join-Path $script:PlugDir "$t.run.log") 2>&1
        $rc = $LASTEXITCODE
        if ($rc -eq 0) {
            Pass "21 fuzz_smoke: $t ($fuzzTime s, corpus-seeded)"
        }
        else {
            Fail "21 fuzz_smoke: $t exited rc=$rc — see $(Join-Path $script:PlugDir "$t.run.log")"
            Get-Content (Join-Path $script:PlugDir "$t.run.log") -Tail 5 `
                -ErrorAction SilentlyContinue |
                ForEach-Object { Write-Host "         $_" }
        }
    }
}

function Find-Awk {
    $c = Get-Command awk -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @('C:\Program Files\Git\usr\bin\awk.exe')) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $root = $git.Source -replace '\\cmd\\git\.exe$', ''
        $a = Join-Path $root 'usr\bin\awk.exe'
        if (Test-Path -LiteralPath $a) { return $a }
    }
    return $null
}

# awk BEGIN-block fixtures below all embed literal double quotes (format
# strings, empty-string literals like out=""). Passed straight to awk.exe
# as one argv element, those get mangled by Windows PowerShell <7.3's
# native-argv construction -- the same class of bug Sqlq's $hasDq stdin
# path already works around for sqlite3.exe (see its comment). awk has no
# stdin-script mode, so write the program to a file and use -f instead;
# that sidesteps argv quoting entirely. This is why the s32 fixture above
# (Python-generated whenever Python is present, using only single-quoted
# Python string literals) always worked while the awk-generated fixtures
# below did not: Python's script text here never contains a double quote.
function Invoke-Awk {
    param([string]$Awk, [string]$Program)
    $tmp = Join-Path $script:PlugDir 'gate22_awk_prog.awk'
    [IO.File]::WriteAllText($tmp, $Program)
    & $Awk -f $tmp 2>$null
}

function Gate-22-V2Functions {
    $awk = Find-Awk
    # s32: the deterministic 32-point series. Python preferred (the .sh's
    # own preference) -- same formula either way, so the fixture is
    # byte-identical to build_test.sh's.
    if ($script:Py) {
        $s32 = & $script:Py -c "import math
print(','.join('%.6f' % math.sin(i/4.0) for i in range(32)))"
    }
    elseif ($awk) {
        $s32 = Invoke-Awk $awk 'BEGIN{for(i=0;i<32;i++)printf "%s%.6f",(i?",":""),sin(i/4.0)}'
    }
    else { $s32 = '' }
    if (ExpectErr 'series needs >= 16 points' `
            "SELECT fractal_dimension_dfa('1.0,2.0,3.0');") {
        Pass '22 v2_functions: short-series DFA rejected'
    }
    else { Fail '22 v2_functions: short-series DFA accepted' }
    $r = Sqlq "SELECT fractal_dimension_dfa('$s32');"
    if ($script:SqlqRc -eq 0 -and ($r -match '(?m)^-?[0-9]')) {
        Pass '22 v2_functions: DFA returns a numeric exponent'
    }
    else { Fail "22 v2_functions: DFA happy path: $r" }
    # Drift: 200-point series, window 64 — the core's box needs window+16
    # points of recent history AND a deep-enough baseline (window 16/n 32
    # is exactly on the printed boundary and the core still declines).
    if ($awk) {
        $s200 = Invoke-Awk $awk 'BEGIN{out=""; for(i=1;i<=200;i++){v=sin(i/3.0)+i*0.001;
    if(i>1)out=out","; out=out sprintf("%.6f",v)} print out}'
    }
    else {
        $s200 = & $script:Py -c "import math
print(','.join('%.6f' % (math.sin(i/3.0)+i*0.001) for i in range(1,201)))"
    }
    $r = Sqlq "SELECT fractal_dimension_drift('$s200', 64);"
    if ($script:SqlqRc -eq 0 -and $r.Contains('recent_alpha')) {
        Pass '22 v2_functions: drift returns the JSON triple'
    }
    else { Fail "22 v2_functions: drift happy path: $r" }
    if (ExpectErr 'window must be > 0' `
            "SELECT fractal_dimension_drift('$s32', 0);") {
        Pass '22 v2_functions: drift window<=0 rejected'
    }
    else { Fail '22 v2_functions: drift window<=0 accepted' }
    # Box-counting fixtures: bottom out in box-counting, which needs
    # >= 3 valid epsilon buckets — enough points AND enough scale dynamic
    # range; an exactly-regular 9-point lattice silently fails the
    # filter (PG's gate-22 fixture note). 40 jittered points dim 2.
    if ($awk) {
        # Git's BWK awk reproduces the .sh fixtures byte-for-byte
        # (srand(42) seeds identically).
        $boxpts = Invoke-Awk $awk 'BEGIN{srand(42); out="";
    for(i=1;i<=40;i++){x=i+rand()*0.01; y=i*0.5+rand()*0.01;
    if(i>1) out=out","; out=out x","y} print out}'
    }
    else {
        # No awk: replicate the fixture with python's seeded RNG (values
        # differ from awk's rand() sequence but the shape/amplitude are
        # identical — 40 jittered points, jitter amplitude 0.01).
        $boxpts = & $script:Py -c "import random
random.seed(42)
print(','.join('%s,%s' % (i+random.random()*0.01, i*0.5+random.random()*0.01) for i in range(1,41)))"
    }
    $r = Sqlq "SELECT fractal_dimension_boxcount('$boxpts', 2);"
    if ($script:SqlqRc -eq 0 -and ($r -match '(?m)^-?[0-9]')) {
        Pass '22 v2_functions: boxcount returns a numeric dimension'
    }
    else { Fail "22 v2_functions: boxcount happy path: $r" }
    if (ExpectErr 'need >= 8 points' `
            "SELECT fractal_dimension_boxcount('0,0,1,0,0,1,1,1', 2);") {
        Pass '22 v2_functions: degenerate boxcount rejected'
    }
    else { Fail '22 v2_functions: degenerate boxcount accepted' }
    # Portfolio: happy path + cov-shape rejection + dormant pareto path.
    $r = Sqlq "SELECT fractal_optimize_portfolio(
              '0.10,0.12,0.07',
              '0.04,0.01,0.005,0.01,0.06,0.01,0.005,0.01,0.05',
              2, 42);"
    if ($script:SqlqRc -eq 0 -and $r.Contains('{')) {
        Pass '22 v2_functions: portfolio returns JSON'
    }
    else { Fail "22 v2_functions: portfolio happy path: $r" }
    if (ExpectErr 'must be n_assets^2' `
            "SELECT fractal_optimize_portfolio(
        '0.10,0.12,0.07',
        '0.04,0.01,0.005,0.01,0.06,0.01,0.005,0.01,0.05,0.9',
        2, 42);") {
        Pass '22 v2_functions: non-square cov rejected'
    }
    else { Fail '22 v2_functions: non-square cov accepted' }
    if (ExpectErr 'enterprise tier not loaded' `
            "SELECT fractal_optimize_portfolio_multimodal_pareto(
        '0.10,0.12,0.07',
        '0.04,0.01,0.005,0.01,0.06,0.01,0.005,0.01,0.05',
        2, 42);") {
        Pass '22 v2_functions: pareto dormant path (no enterprise core)'
    }
    else { Fail '22 v2_functions: pareto path did not surface the dormant error' }
    # Domain geometry: synthetic node/edge payloads with the same shapes
    # PG's gate used (30-node 3D vessel chain with per-edge arc lengths;
    # 80-node 2D fiber grid).
    if ($awk) {
        $vasc = @(Invoke-Awk $awk 'BEGIN{
    srand(1); n=30; nc=""; el=""; al="";
    for (i=0;i<n;i++) { x=i; y=rand()*0.01; z=rand()*0.01;
      xs[i]=x; ys[i]=y; zs[i]=z; if (i>0) nc=nc","; nc=nc x","y","z; }
    for (i=0;i<n-1;i++) { if (i>0) { el=el","; al=al","; }
      el=el i","(i+1);
      dx=xs[i+1]-xs[i]; dy=ys[i+1]-ys[i]; dz=zs[i+1]-zs[i];
      al=al sqrt(dx*dx+dy*dy+dz*dz); }
    print nc; print el; print al;
  }')
        $vasc_nc = $vasc[0]; $vasc_el = $vasc[1]; $vasc_al = $vasc[2]
    }
    else {
        $vasc = @(& $script:Py -c "import math, random
random.seed(1); n=30
pts=[(i, random.random()*0.01, random.random()*0.01) for i in range(n)]
print(','.join('%s,%s,%s'%p for p in pts))
print(','.join('%s,%s'%(i,i+1) for i in range(n-1)))
print(','.join('%.6g'%math.dist(pts[i],pts[i+1]) for i in range(n-1)))" 2>$null)
        $vasc_nc = $vasc[0]; $vasc_el = $vasc[1]; $vasc_al = $vasc[2]
    }
    $r = Sqlq "SELECT fractal_vascular_network('$vasc_nc', '$vasc_el', '$vasc_al');"
    if ($script:SqlqRc -eq 0 -and $r.Contains('fractal_dimension')) {
        Pass '22 v2_functions: vascular returns the JSON triple'
    }
    else { Fail "22 v2_functions: vascular: $r" }
    $r = Sqlq "SELECT fractal_cortical_folding(
              '0,0,0, 1,0,0, 1,1,0, 0,1,0, 0,0,1, 1,0,1, 1,1,1, 0,1,1',
              '0,1,2, 0,2,3, 4,5,6, 4,6,7');"
    if ($script:SqlqRc -eq 0 -and $r.Contains('gyrification_index')) {
        Pass '22 v2_functions: cortical returns the gyrification triple'
    }
    else { Fail "22 v2_functions: cortical: $r" }
    if ($awk) {
        $nerve = @(Invoke-Awk $awk 'BEGIN{
    srand(2); n=80; nc=""; el="";
    for (i=0;i<n;i++) { x=i; y=(i%2==0?0:1)+rand()*0.01;
      if (i>0) nc=nc","; nc=nc x","y; }
    for (i=0;i<n-1;i++) { if (i>0) el=el","; el=el i","(i+1); }
    print nc; print el;
  }')
        $nerve_nc = $nerve[0]; $nerve_el = $nerve[1]
    }
    else {
        $nerve = @(& $script:Py -c "import random
random.seed(2); n=80
pts=[(i, (0 if i%2==0 else 1)+random.random()*0.01) for i in range(n)]
print(','.join('%s,%s'%p for p in pts))
print(','.join('%s,%s'%(i,i+1) for i in range(n-1)))" 2>$null)
        $nerve_nc = $nerve[0]; $nerve_el = $nerve[1]
    }
    $r = Sqlq "SELECT fractal_nerve_plexus_metric('$nerve_nc', 2, '$nerve_el');"
    if ($script:SqlqRc -eq 0 -and $r.Contains('fiber_length_density')) {
        Pass '22 v2_functions: nerve plexus returns its JSON'
    }
    else { Fail "22 v2_functions: nerve: $r" }
    $r = Sqlq "SELECT fractal_morphological_complexity('$boxpts', 2);"
    if ($script:SqlqRc -eq 0 -and $r.Contains('lacunarity')) {
        Pass '22 v2_functions: morphology returns dimension+lacunarity'
    }
    else { Fail "22 v2_functions: morphology: $r" }
    # Diversify state + telemetry ground truth.
    $r = Sqlq `
        'SELECT fractal_diversify_enable();' `
        "SELECT fractal_diversify_set_params('{}');" `
        'SELECT fractal_diversify_current_dq();' `
        'SELECT fractal_diversify_overhead_p99_us();' `
        'SELECT fractal_diversify_disable();'
    if ($script:SqlqRc -eq 0) {
        Pass '22 v2_functions: diversify state machine cycles cleanly'
    }
    else { Fail "22 v2_functions: diversify: $r" }
    $r = Sqlq "SELECT fractal_search_telemetry(
              'bt_telemetry', 'vec', '0.6,0.8,0.0,0.0', 2);"
    if ($script:SqlqRc -eq 0 -and $r.Contains('id')) {
        Pass '22 v2_functions: search_telemetry returns ground-truth rows'
    }
    else { Fail "22 v2_functions: telemetry: $r" }
    if (ExpectErr 'k must be > 0' `
            "SELECT fractal_search_telemetry('bt_telemetry','vec',
        '0.6,0.8,0.0,0.0', 0);") {
        Pass '22 v2_functions: telemetry k<=0 rejected'
    }
    else { Fail '22 v2_functions: telemetry k<=0 accepted' }
    $r = Sqlq "SELECT fractal_search_trajectory(
              'bt_traj', 'vec', '0.0,0.0,0.0,0.0',
              '0.3,0.0,0.0,0.0', 3);"
    if ($script:SqlqRc -eq 0 -and $r.Contains('{')) {
        Pass '22 v2_functions: search_trajectory returns JSON'
    }
    else { Fail "22 v2_functions: search_trajectory: $r" }
    $r = Sqlq 'SELECT fractal_explain_result();' `
        'SELECT fractal_detect_collapse();'
    if ($script:SqlqRc -eq 0) {
        Pass '22 v2_functions: explain_result/detect_collapse respond'
    }
    else { Fail "22 v2_functions: explain/detect_collapse: $r" }
}

function Gate-23-Agents {
    # The agents embed their query through the EMBED tier (canned
    # 3-dim), so this gate's corpus is 3-dim to match the canned embed.
    $null = Sqlq @'
    CREATE TABLE bt_agent_docs(
        id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
    INSERT INTO bt_agent_docs(body, emb) VALUES
      ('doc-a about cosine metrics','1.0,0.05,0.0'),
      ('doc-b about vector stores','1.0,0.1,0.0'),
      ('doc-c about fractal search','0.05,1.0,0.0'),
      ('doc-d on SFS optimization','0.1,0.95,0.0'),
      ('doc-e on embedding tiers','0.05,0.0,1.0'),
      ('doc-f on queue processing','0.0,0.05,0.95');
    CREATE TABLE bt_agent_empty(
      id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
    -- fractal_cross_modal_search concatenates its two modality vectors
    -- (morphology ++ clinical) into one query of their combined dim, so
    -- its corpus needs that combined dim, not bt_agent_docs's 3 (sized
    -- for the EMBED tier's canned output used by the search/rag agents
    -- above) -- a separate 6-dim (3+3) fixture, not a shared-table reuse.
    CREATE TABLE bt_agent_docs_xmodal(
        id INTEGER PRIMARY KEY, body TEXT, emb TEXT);
    INSERT INTO bt_agent_docs_xmodal(body, emb) VALUES
      ('xm-a morph-heavy','1.0,0.05,0.0,0.05,0.0,0.0'),
      ('xm-b balanced','0.5,0.5,0.0,0.5,0.5,0.0'),
      ('xm-c clinical-heavy','0.0,0.05,0.0,1.0,0.05,0.0');
'@
    if ($script:SqlqRc -ne 0) {
        Fail '23 agents: fixture setup failed'
        return
    }
    # Preamble shared by every agent invocation (chat + embed tiers both
    # served by the embed-capable mock; endpoint keys are dummies).
    $pre = @(
        "SELECT fractalsql_set('reasoning_plugin','$($script:MockEmb)');"
        "SELECT fractalsql_set('http_url','https://llm.invalid/v1');"
        "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');"
        "SELECT fractalsql_set('http_model','mock-model');"
    )
    function Agent {
        param([string]$Label, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Stmts)
        $r = Sqlq @pre @Stmts
        $rc = $script:SqlqRc
        if (Test-Crashed $r $rc) { Fail "23 $Label — process crashed" }
        elseif ($rc -ne 0) { Fail "23 ${Label}: $r" }
        else { Pass "23 $Label" }
        $script:LastAgentOut = $r
    }
    function AgentErr {
        param([string]$Label, [string]$Want, [Parameter(ValueFromRemainingArguments = $true)][string[]]$Stmts)
        if (ExpectErr $Want @pre @Stmts) { Pass "23 $Label" }
        else { Fail "23 $Label" }
        $script:LastAgentOut = ''
    }
    Agent 'search_agent embeds→scouts→synthesizes' `
        "SELECT fractal_search_agent('cosine metrics','bt_agent_docs','emb');"
    if ($script:LastAgentOut.Contains('"answer"') -and $script:LastAgentOut.Contains('"source_doc_ids"')) {
        Pass '23 search_agent returns the composite JSON'
    }
    else { Fail "23 search_agent JSON: $($script:LastAgentOut)" }
    Agent 'rag_agent single-turn RAG' `
        "SELECT fractal_rag_agent('embedding tiers','bt_agent_docs','emb');"
    Agent 'sql_agent T2S composition' `
        "SELECT fractal_sql_agent('count the orders');"
    if ($script:LastAgentOut.Contains('"generated_sql"')) {
        Pass '23 sql_agent returns the composite JSON'
    }
    else { Fail "23 sql_agent JSON: $($script:LastAgentOut)" }
    Agent 'plan_explore MCTS branches' `
        "SELECT fractal_agent_plan_explore('1.0,0.0,0.0',
      'bt_agent_docs','emb', 2);"
    if ($script:LastAgentOut.Contains('"branch_id"')) {
        Pass '23 plan_explore returns branch plans'
    }
    else { Fail "23 plan_explore JSON: $($script:LastAgentOut)" }
    Agent 'trajectory_predict over telemetry' `
        "SELECT fractal_agent_trajectory_predict('bt_traj','vec',3,2);"
    Agent 'detect_loop monitors a series' `
        "SELECT fractal_agent_detect_loop(
       '0.0,0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,0.0,0.1,
        0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,0.0,0.1,0.2,0.3');"
    if ($script:LastAgentOut -match '"is_loop_detected":(true|false)') {
        Pass '23 detect_loop returns the verdict'
    }
    else { Fail "23 detect_loop JSON: $($script:LastAgentOut)" }
    Agent 'telemetry + trajectory + hybrid + cross_modal + explain' `
        "SELECT fractal_search_telemetry('bt_agent_docs','emb',
       '1.0,0.0,0.0', 2);" `
        "SELECT fractal_hybrid_clinical_search('bt_agent_docs','emb',
       '1.0,0.0,0.0', '1,2,3', 2);" `
        "SELECT fractal_cross_modal_search('bt_agent_docs_xmodal','emb',
       '1.0,0.0,0.0', '0.0,1.0,0.0', 0.5, 2);" `
        'SELECT fractal_explain_result();'
    # Expected-error invocations: -bail stops at the first error, so the
    # two guards run as separate agent_err checks (a combined invocation
    # would never surface the second message).
    AgentErr 'cross_modal alpha_weight guard' 'alpha_weight must be in [0,1]' `
        "SELECT fractal_cross_modal_search('bt_agent_docs_xmodal','emb',
       '1.0,0.0,0.0', '0.0,1.0,0.0', 1.5, 2);"
    AgentErr 'hybrid k guard' 'k must be > 0' `
        "SELECT fractal_hybrid_clinical_search('bt_agent_docs','emb',
       'q', '1,2,3', 0);"
    AgentErr 'no-rows guard' 'no rows found in bt_agent_empty.emb' `
        "SELECT fractal_search_agent('q','bt_agent_empty','emb');"
}

function Gate-24-Enterprise {
    # The community archive carries no enterprise symbols: the ledger/
    # audit surface is registered but dormant, and must reject cleanly
    # (never crash, never silently no-op).
    if (ExpectErr 'enterprise tier not loaded' 'SELECT fractal_ledger_flush();') {
        Pass '24 enterprise: ledger_flush rejects cleanly (dormant tier)'
    }
    else { Fail '24 enterprise: ledger path did not surface the dormant error' }
    # audit_log now carries the same enterprise gate as the rest of the
    # ledger surface (PG parity fix — see gate 31 ledger_chain, which owns
    # this behavior in detail; previously this wrote unconditionally, a
    # real parity gap against PG's own ensure_enterprise_lib() check).
    if (ExpectErr 'enterprise tier not loaded' "SELECT fractal_audit_log('entry', '{}');") {
        Pass '24 enterprise: audit_log rejects cleanly (dormant tier)'
    }
    else { Fail '24 enterprise: audit_log did not surface the dormant-tier error' }
    # A bogus enterprise_lib must be an absolute path (the same set-time
    # path validation as the plugin keys — the native backslash form;
    # MSYS's argument conversion has no analog here), and the ledger call
    # then surfaces the load failure. With signature verification
    # mandatory by default the detached-signature check runs BEFORE the
    # dlopen, so a path with no sibling .sig refuses at that earlier gate
    # ("no signature found") rather than at the loader ("could not load");
    # either way it is a distinct message from the unconfigured
    # dormant-tier one.
    if (ExpectErr 'no signature found for enterprise library' `
            "SELECT fractalsql_set('enterprise_lib',
        'C:\nonexistent\fractalsql-enterprise.dll');" `
            'SELECT fractal_ledger_flush();') {
        Pass '24 enterprise: bogus enterprise_lib surfaces the load failure'
    }
    else { Fail '24 enterprise: bogus enterprise_lib did not surface the error' }
}

# Python driver for gate 25: the enterprise QTL ledger under stress,
# concurrency, and MAC tamper-evidence, through the REAL vendored
# enterprise core end to end (FSQL_BT_ENT_LIB env is the core's
# absolute path). Structural tamper (mid-chain byte-flip), a deleted-
# row gap, and the snapshot -> chain schema migration are already fully
# covered by gate 31's storage-layer driver (built directly at the row
# level, so it needs no core at all) -- this driver does not repeat
# them. What it adds, and what genuinely needs a real core: fill-to-cap
# + churn through the real flush()/load() path (Phase A), cross-
# connection persistence and real concurrent writers serialized by
# ledger_chain_insert's BEGIN IMMEDIATE serializing concurrent writers
# (Phase C), and MAC-authenticated tamper-evidence through a real
# HMAC-tagged flush (Phase D), minus the phases gate 31 already owns.
#
# Hand-mirrored from build_test.sh's Write-PyGate25/Gate-25 by
# inspection, verified end to end on Linux under the sh runner against
# the real signed core -- not separately executed here, since the
# authoring environment has no Windows host to run PowerShell against.
function Write-PyGate25 { param([string]$Path)
    $content = @'
import os, sys, sqlite3, threading, json

db, ext = os.environ["FSQL_BT_DB"], os.environ["FSQL_BT_EXT"]
absw = os.environ["FSQL_BT_ENT_LIB"]

failed = False
def check(label, cond, detail=""):
    global failed
    if cond:
        print("OK: %s" % label)
    else:
        failed = True
        print("FAIL: %s%s" % (label, (" -- " + detail) if detail else ""))

def connect():
    con = sqlite3.connect(db)
    con.enable_load_extension(True)
    con.load_extension(ext)
    con.execute("PRAGMA busy_timeout=5000")
    con.execute("SELECT fractalsql_set('enterprise_lib', ?)", (absw,))
    return con

# ---- Phase A: fill-to-cap (64 truth + 64 shadow = 128) + 10 churn
# cycles. Truth/Shadow each cap at 64 (the core-level cap PG's own gate
# 25 documents); 64+64 with disjoint result_handles encodes all 128 (no
# QTL dedup).
try:
    con = connect()
    con.execute("DROP TABLE IF EXISTS fractalsql_ledger")
    con.execute("SELECT fractal_diversify_enable()")
    con.execute("SELECT fractal_ledger_reset_hard()")
    for i in range(1, 65):
        con.execute("SELECT fractal_feedback_report(?, 'positive')", (i,))
    for i in range(65, 129):
        con.execute("SELECT fractal_feedback_report(?, 'negative')", (i,))
    tc = con.execute("SELECT fractal_ledger_truth_count()").fetchone()[0]
    sc = con.execute("SELECT fractal_ledger_shadow_count()").fetchone()[0]
    con.execute("SELECT fractal_ledger_flush()")
    audit = con.execute(
        "SELECT fractal_audit_unpack(payload) FROM fractalsql_ledger "
        "WHERE kind=1 ORDER BY id DESC LIMIT 1").fetchone()[0]
    ev = len(json.loads(audit))
    check("Phase A fill: truth=64 shadow=64 events=128 after fill-to-cap",
          tc == 64 and sc == 64 and ev == 128,
          "truth=%s shadow=%s events=%s" % (tc, sc, ev))

    for c in range(1, 11):
        con.execute("SELECT fractal_ledger_reset_hard()")
        for i in range(1, 65):
            con.execute("SELECT fractal_feedback_report(?, 'positive')",
                        (i + 1000 * c,))
        for i in range(65, 129):
            con.execute("SELECT fractal_feedback_report(?, 'negative')",
                        (i + 1000 * c,))
        con.execute("SELECT fractal_ledger_flush()")
        con.execute("SELECT fractal_ledger_load()")
    tc = con.execute("SELECT fractal_ledger_truth_count()").fetchone()[0]
    sc = con.execute("SELECT fractal_ledger_shadow_count()").fetchone()[0]
    audit = con.execute(
        "SELECT fractal_audit_unpack(payload) FROM fractalsql_ledger "
        "WHERE kind=1 ORDER BY id DESC LIMIT 1").fetchone()[0]
    ev = len(json.loads(audit))
    check("Phase A churn: truth=64 shadow=64 events=128 after 10 flush/load cycles",
          tc == 64 and sc == 64 and ev == 128,
          "truth=%s shadow=%s events=%s" % (tc, sc, ev))
    con.close()
except sqlite3.Error as e:
    check("Phase A: fill-to-cap/churn completed without error", False, str(e))

# ---- Phase C(a): cross-connection persistence -- seed+flush on one
# connection, load+count on a FRESH one; counts must match (proves the
# table-backed VFS is connection-independent, not in-memory only).
try:
    con1 = connect()
    con1.execute("DROP TABLE IF EXISTS fractalsql_ledger")
    con1.execute("SELECT fractal_diversify_enable()")
    con1.execute("SELECT fractal_ledger_reset_hard()")
    for i in range(1, 11):
        con1.execute("SELECT fractal_feedback_report(?, 'positive')", (i,))
    for i in range(11, 21):
        con1.execute("SELECT fractal_feedback_report(?, 'negative')", (i,))
    con1.execute("SELECT fractal_ledger_flush()")
    con1.close()

    con2 = connect()
    con2.execute("SELECT fractal_ledger_load()")
    t2 = con2.execute("SELECT fractal_ledger_truth_count()").fetchone()[0]
    s2 = con2.execute("SELECT fractal_ledger_shadow_count()").fetchone()[0]
    con2.close()
    check("Phase C(a): cross-connection persistence -- fresh connection loaded 10/10",
          t2 == 10 and s2 == 10, "truth=%s shadow=%s" % (t2, s2))
except sqlite3.Error as e:
    check("Phase C(a): cross-connection persistence completed without error", False, str(e))

# ---- Phase C(b): 8 concurrent writers, each on its own connection,
# seed one event, flush. Fresh chain, pre-flushed with one row first so
# the workers append to an EXISTING chain (avoids a concurrent CREATE
# TABLE IF NOT EXISTS race). Invariant: 9 rows total (1 pre-flush + 8
# concurrent), the chain verifies as a single unforked line -- proving
# BEGIN IMMEDIATE actually serializes the read-head/link/insert
# sequence across real concurrent connections, not just within one --
# and the latest blob decodes.
try:
    setup = connect()
    setup.execute("DROP TABLE IF EXISTS fractalsql_ledger")
    setup.execute("SELECT fractal_diversify_enable()")
    setup.execute("SELECT fractal_feedback_report(0, 'positive')")
    setup.execute("SELECT fractal_ledger_flush()")
    setup.close()

    errors = []
    def worker(w):
        try:
            c = connect()
            c.execute("SELECT fractal_diversify_enable()")
            c.execute("SELECT fractal_feedback_report(?, 'positive')", (w,))
            c.execute("SELECT fractal_ledger_flush()")
            c.close()
        except Exception as e:
            errors.append("worker %d: %s" % (w, e))

    threads = [threading.Thread(target=worker, args=(w,)) for w in range(1, 9)]
    for t in threads: t.start()
    for t in threads: t.join()

    vcon = connect()
    rows = vcon.execute(
        "SELECT count(*) FROM fractalsql_ledger WHERE kind=1").fetchone()[0]
    report = json.loads(vcon.execute("SELECT fractal_ledger_verify()").fetchone()[0])
    latest = vcon.execute(
        "SELECT fractal_audit_unpack(payload) FROM fractalsql_ledger "
        "WHERE kind=1 ORDER BY id DESC LIMIT 1").fetchone()[0]
    vcon.close()
    json.loads(latest)  # must decode cleanly
    check("Phase C(b): 8 concurrent flushes -> 9 append-only rows, chain verifies as one unforked line",
          rows == 9 and report.get("ok") is True and not errors,
          "rows=%s verify=%s errors=%s" % (rows, report, errors))
except sqlite3.Error as e:
    check("Phase C(b): concurrent flush completed without error", False, str(e))

# ---- Phase D: MAC-authenticated tamper-evidence (enterprise_ledger_
# key). Phases A/C ran with the key UNSET (structural path, entry_hash
# only). D sets the key: flush tags the row with HMAC-SHA256 (assert
# length(mac)=32), load verifies; a payload byte-flip (length
# preserved, so it is a structural-blind tamper gate 31 never
# exercises) is rejected by the MAC; re-flush re-tags and load verifies
# clean again.
try:
    con = connect()
    con.execute("DROP TABLE IF EXISTS fractalsql_ledger")
    con.execute("SELECT fractalsql_set('enterprise_ledger_key', 'gate25-mac-key')")
    con.execute("SELECT fractal_diversify_enable()")
    con.execute("SELECT fractal_ledger_reset_hard()")
    con.execute("SELECT fractal_feedback_report(1, 'positive')")
    con.execute("SELECT fractal_ledger_flush()")
    row_id, mac_len, payload = con.execute(
        "SELECT id, length(mac), payload FROM fractalsql_ledger "
        "WHERE kind=1 ORDER BY id DESC LIMIT 1").fetchone()
    check("Phase D: flush tags the row with a 32-byte HMAC", mac_len == 32,
          "mac_len=%s" % mac_len)

    con.execute("SELECT fractal_ledger_load()")  # MAC verifies -> ok

    tampered = bytearray(payload)
    tampered[len(tampered) // 2] ^= 0xFF
    con.execute("UPDATE fractalsql_ledger SET payload=? WHERE id=?",
                (bytes(tampered), row_id))
    con.commit()  # close the implicit DML transaction before load()'s
                  # own internal BEGIN IMMEDIATE (else: "cannot start a
                  # transaction within a transaction")

    tamper_caught = False
    tamper_detail = ""
    try:
        con.execute("SELECT fractal_ledger_load()")
    except sqlite3.Error as e:
        tamper_detail = str(e)
        tamper_caught = "MAC verification failed" in tamper_detail
    check("Phase D: a structural-blind payload byte-flip is rejected by the MAC",
          tamper_caught, tamper_detail or "load did not raise")

    con.execute("SELECT fractal_ledger_reset_hard()")
    con.execute("SELECT fractal_feedback_report(1, 'positive')")
    con.execute("SELECT fractal_ledger_flush()")
    con.execute("SELECT fractal_ledger_load()")  # verifies clean again
    check("Phase D: re-flush re-tags and load verifies clean", True)
    con.close()
except sqlite3.Error as e:
    check("Phase D: MAC tamper-evidence flow completed without error", False, str(e))

sys.exit(1 if failed else 0)
'@
    [IO.File]::WriteAllText($Path, $content.Replace("`r`n", "`n"))
}

function Gate-25-EnterpriseStress {
    # Self-skips unless an enterprise core is vendored in include/ (none
    # is, on the community drop) -- same detection as gate 24. See
    # Write-PyGate25 above for what this gate covers and why.
    # Scoped to include/windows-x86_64 specifically, and to *.dll -- an
    # earlier version of this glob was -Recurse over all of include/
    # with no OS/extension filter, which also matches include/linux-
    # x86_64/libfractalsql-enterprise-*.so (real vendored file in this
    # tree) and windows-x86_64's own *.dll.sig sidecar. Get-ChildItem
    # -Recurse enumerates linux-x86_64 before windows-x86_64
    # alphabetically, so Select-Object -First 1 was silently handing
    # LoadLibraryA a Linux ELF .so -- a clean, deterministic load
    # failure regardless of signature settings (confirmed: this
    # reproduced even with enterprise_require_signature=off, which
    # only makes sense if the file itself was never a valid PE image
    # to begin with -- a hand-verified ctypes.WinDLL() load of the
    # correct windows-x86_64/*.dll path, by contrast, succeeds).
    $found = Get-ChildItem -Path 'include/windows-x86_64' `
        -Filter '*fractalsql-enterprise-*.dll' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $found) {
        Skip '25 enterprise_stress (no enterprise core vendored in include/)'
        return
    }
    if (-not $script:Py) {
        Skip '25 enterprise_stress driver (no python3 sqlite3 stdlib)'
        return
    }
    if (Skip-IfPySanitizerBlocked '25 enterprise_stress driver') { return }
    Write-PyGate25 (Join-Path $script:PlugDir 'py_gate25.py')
    $env:FSQL_BT_ENT_LIB = $found
    # Signature verification is mandatory by default (fsql_enterprise.c);
    # a dev drop is typically unsigned and this gate tests ledger
    # behavior, not the signature gate, so opt out the way a dev would.
    $env:FSQL_ENTERPRISE_ALLOW_UNVERIFIED = '1'
    PyRun 'py_gate25'
    Remove-Item Env:\FSQL_ENTERPRISE_ALLOW_UNVERIFIED -ErrorAction SilentlyContinue
    $rc = $LASTEXITCODE
    Remove-Item Env:\FSQL_BT_ENT_LIB -ErrorAction SilentlyContinue
    if ($rc -eq 0) {
        Pass '25 enterprise_stress: fill-to-cap+churn, concurrency, MAC tamper-evidence (see driver OK lines above)'
    } else {
        Fail '25 enterprise_stress: see driver output above'
    }
}

function Gate-26-EnterpriseSignature {
    # Ordering: the signature check is only reachable AFTER a successful
    # load. With no enterprise lib resolvable, enterprise_require_
    # signature=on must still surface the LOAD error, not a signature
    # error.
    $r = Sqlq "SELECT fractalsql_set('enterprise_require_signature','on');" `
        'SELECT fractal_ledger_flush();'
    $rc = $script:SqlqRc
    if ($rc -ne 0 -and $r.Contains('enterprise tier not loaded') `
            -and -not $r.Contains('no signature found')) {
        Pass '26 enterprise_signature: load error precedes the signature check'
    }
    else {
        Fail "26 enterprise_signature: got rc=${rc}: $r"
    }
}

function Gate-27-Think {
    if (-not (HavePlugin $script:Think)) {
        Skip '27 think (think_reasoning_plugin did not build)'
        return
    }
    function AssertDump {
        param([string]$Label, [string[]]$Pats)
        # Anchored line matches (the .sh greps ^pattern$ per line): strip
        # the anchors and require an exact line.
        $lines = if (Test-Path -LiteralPath $script:ThinkDump) {
            ([IO.File]::ReadAllText($script:ThinkDump)) -split "`r?`n"
        }
        else { @() }
        $ok = $true
        foreach ($p in $Pats) {
            $pat = $p.TrimStart('^').TrimEnd('$')
            if ($lines -notcontains $pat) { $ok = $false }
        }
        $dump = if (Test-Path -LiteralPath $script:ThinkDump) {
            [IO.File]::ReadAllText($script:ThinkDump)
        }
        else { '' }
        if ($ok) { Pass "27 think: $Label" }
        else { Fail "27 think: $Label — dump: $dump" }
    }
    # 1) fractal_reason's chat tier forwards all four keys.
    if (Test-Path -LiteralPath $script:ThinkDump) { [IO.File]::Delete($script:ThinkDump) }
    $null = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:Think)');" `
        "SELECT fractalsql_set('http_think','high');" `
        "SELECT fractalsql_set('http_think_provider','openai');" `
        "SELECT fractalsql_set('http_native_url','https://native.invalid/x');" `
        "SELECT fractalsql_set('http_num_ctx','8192');" `
        "SELECT fractal_reason('q');"
    AssertDump 'fractal_reason forwards the THINK block' `
        @('^THINK=high$', '^THINK_PROVIDER=openai$',
          '^NATIVE_URL=https://native.invalid/x$', '^NUM_CTX=8192$')
    # 2) fractal_text_to_sql's GENERATE step forwards them too.
    if (Test-Path -LiteralPath $script:ThinkDump) { [IO.File]::Delete($script:ThinkDump) }
    $null = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:Think)');" `
        "SELECT fractalsql_set('http_think','low');" `
        "SELECT fractalsql_set('http_think_provider','anthropic');" `
        "SELECT fractalsql_set('http_native_url','https://native.invalid/y');" `
        "SELECT fractalsql_set('http_num_ctx','4096');" `
        "SELECT fractal_text_to_sql('q');"
    AssertDump 'fractal_text_to_sql GENERATE forwards the THINK block' `
        @('^THINK=low$', '^THINK_PROVIDER=anthropic$',
          '^NATIVE_URL=https://native.invalid/y$', '^NUM_CTX=4096$')
    # 3) The EMBED tier must NOT see the THINK block (embed config lives
    # in its own env block; think keys are chat-effort only).
    if (Test-Path -LiteralPath $script:ThinkDump) { [IO.File]::Delete($script:ThinkDump) }
    $null = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:Think)');" `
        "SELECT fractalsql_set('http_think','high');" `
        "SELECT fractalsql_set('http_think_provider','openai');" `
        "SELECT fractalsql_set('http_native_url','https://native.invalid/x');" `
        "SELECT fractalsql_set('http_num_ctx','8192');" `
        "SELECT fractalsql_set('http_embed_url','https://embed.invalid/v1');" `
        "SELECT fractal_embed('x');"
    AssertDump 'fractal_embed sees NO THINK keys' `
        @('^THINK=(unset)$', '^THINK_PROVIDER=(unset)$')
}

# Regression test for FSQL_REASONING_TIER_REVIEW/apply_review_env():
# fractal_text_to_sql()'s REVIEW step must never dispatch under T2S's
# hard-forced RESPONSE_MODE=code (before the fix, t2s_review() shared
# FSQL_REASONING_TIER_T2S directly, so REVIEW's plain PASS/FAIL-then-
# explain text response could get run through the code-block extractor
# meant for GENERATE's fenced SQL). tests\mock_reasoning_plugin_win.c
# dumps RESPONSE_MODE (captured once at plugin init, the same instant
# the real reasoning-http plugin would capture it -- not re-read live
# on every generate() call) fresh on every generate() call, and REVIEW
# always runs last within one fractal_text_to_sql() call, so the dump
# file's content once the whole call returns reflects REVIEW's own env.
function Gate-28-ReviewIsolation {
    function AssertDump {
        param([string]$Label, [string]$Pat)
        $dump = if (Test-Path -LiteralPath $script:ReviewDump) {
            [IO.File]::ReadAllText($script:ReviewDump)
        }
        else { '' }
        $pat = $Pat.TrimStart('^').TrimEnd('$')
        $lines = $dump -split "`r?`n"
        if ($lines -contains $pat) { Pass "28 review_isolation: $Label" }
        else { Fail "28 review_isolation: $Label — dump: $dump" }
    }
    # 1) Regression guard: GENERATE alone (review off) still runs under
    # T2S's forced RESPONSE_MODE=code -- the split must not have
    # accidentally un-forced GENERATE's own tier.
    [IO.File]::WriteAllText($script:SqlTxt, 'SELECT 1')
    if (Test-Path -LiteralPath $script:ReviewDump) { [IO.File]::Delete($script:ReviewDump) }
    $null = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:Mock)');" `
        "SELECT fractal_text_to_sql('q');"
    AssertDump 'GENERATE still runs under T2S''s forced RESPONSE_MODE=code' '^RESPONSE_MODE=code$'
    # 2) The actual regression check: with review enabled, REVIEW's own
    # dispatch (the last generate() call within fractal_text_to_sql())
    # must NOT see RESPONSE_MODE=code.
    [IO.File]::WriteAllText($script:SqlTxt, 'SELECT 1')
    if (Test-Path -LiteralPath $script:ReviewDump) { [IO.File]::Delete($script:ReviewDump) }
    $null = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:Mock)');" `
        "SELECT fractalsql_set('text_to_sql_use_review','on');" `
        "SELECT fractal_text_to_sql('q');"
    AssertDump 'REVIEW never sees T2S''s forced RESPONSE_MODE=code' '^RESPONSE_MODE=(unset)$'
}

# Smoke gate for the sixteen installable Domain Agent engines
# (src\fsql_domain_agents.c), registered here as plain C SQL
# functions (SQLite has no server-side procedural language and no
# second extension artifact). Deliberately a smoke gate: proves
# representative engines (3 of 16) across the three composition shapes --
# table-backed + LLM (anomaly_triage), pure retrieval with a cohort
# filter and no LLM (recall_hybrid), array-in + LLM (regime_triage) --
# run end-to-end against the real primitives they compose, with a
# canary proving the reasoning step actually ran.
function Gate-29-DomainAgents {
    $null = Sqlq @'
    CREATE TABLE bt_da_logs(metric REAL, ts INTEGER, host TEXT);
    INSERT INTO bt_da_logs (metric, ts, host)
    SELECT 50.0 + (value % 8) * 1.3 + CASE WHEN value > 48 THEN 30.0 ELSE 0.0 END,
           value, 'host-1'
      FROM (WITH RECURSIVE c(value) AS (VALUES(1) UNION ALL SELECT value+1 FROM c WHERE value<96)
            SELECT value FROM c);
    CREATE TABLE bt_da_mem(id INTEGER, body TEXT, emb TEXT, kind TEXT);
    INSERT INTO bt_da_mem VALUES
      (1,'alpha','1.0,0.0,0.0','a'),(2,'beta','0.0,1.0,0.0','b'),(3,'gamma','0.9,0.1,0.0','a');
'@
    if ($script:SqlqRc -ne 0) {
        Fail '29 domain_agents: fixture setup failed'
        return
    }

    [IO.File]::WriteAllText($script:SqlTxt, 'domain-agent-canary')

    # --- 1: fractal_agent_anomaly_triage (table + drift + reason) ------
    $r1 = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:Mock)');" `
        "SELECT json_extract(fractal_agent_anomaly_triage('bt_da_logs','metric','ts','host','host-1',32),'`$.threat_score');"
    if ($r1 -match '(?m)^-?[0-9]+(\.[0-9]+)?$') {
        Pass '29 domain_agents: anomaly_triage threat_score is a real computed drift float'
    } else {
        Fail "29 domain_agents: expected a numeric threat_score, got: $r1"
    }

    $r1b = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:Mock)');" `
        "SELECT json_extract(fractal_agent_anomaly_triage('bt_da_logs','metric','ts','host','host-1',32),'`$.triage_summary');"
    if ($r1b.Contains('domain-agent-canary')) {
        Pass '29 domain_agents: anomaly_triage composes drift -> reason (reason step ran)'
    } else {
        Fail "29 domain_agents: expected the reasoning canary in triage_summary, got: $r1b"
    }

    $r2 = Sqlq "SELECT fractal_agent_anomaly_triage('bt_da_logs','metric','ts','host','no-such-host',32);"
    if ($r2.Contains('no rows in')) {
        Pass '29 domain_agents: anomaly_triage raises a clean ERROR when the filter matches no rows'
    } else {
        Fail "29 domain_agents: expected a no-rows ERROR, got: $r2"
    }

    # --- 2: fractal_agent_recall_hybrid (pure retrieval, cohort filter,
    # no LLM) -- the exact case a prior cohort-building bug broke (row_
    # number computed after WHERE-filtering instead of over the full
    # table), so this also guards that regression.
    $r3 = Sqlq "SELECT fractal_agent_recall_hybrid('bt_da_mem','emb','1.0,0.0,0.0','kind','a',5,'id','body');"
    if ($r3.Contains('"mem_id":1') -and $r3.Contains('"mem_id":3') -and -not $r3.Contains('"mem_id":2')) {
        Pass "29 domain_agents: recall_hybrid cohort filter includes only kind='a' rows"
    } else {
        Fail "29 domain_agents: expected mem_id 1 and 3 only (not 2), got: $r3"
    }

    # --- 3: fractal_agent_regime_triage (array-in + dfa/drift + reason) -
    $rnd = [System.Random]::new(7)
    $series = (0..99 | ForEach-Object { [Math]::Round(0.1 * $_ + ($rnd.NextDouble() - 0.5) * 0.05, 6) }) -join ','
    $r4 = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:Mock)');" `
        "SELECT json_extract(fractal_agent_regime_triage('$series',32),'`$.dfa_exponent');"
    if ($r4 -match '(?m)^-?[0-9]+(\.[0-9]+)?$') {
        Pass '29 domain_agents: regime_triage dfa_exponent is a real computed float'
    } else {
        Fail "29 domain_agents: expected a numeric dfa_exponent, got: $r4"
    }

    $r4b = Sqlq `
        "SELECT fractalsql_set('reasoning_plugin','$($script:Mock)');" `
        "SELECT json_extract(fractal_agent_regime_triage('$series',32),'`$.rationale');"
    if ($r4b.Contains('domain-agent-canary')) {
        Pass '29 domain_agents: regime_triage composes dfa+drift -> reason (reason step ran)'
    } else {
        Fail "29 domain_agents: expected the reasoning canary in rationale, got: $r4b"
    }

    [IO.File]::WriteAllText($script:SqlTxt, 'SELECT 1')
}

function Gate-30-FeatureStore {
    $r1 = Sqlq `
        "SELECT fractal_store_morphology(1, '0.0,0.0,0.0');" `
        "SELECT fractal_store_morphology(2, '1.0,0.0,0.0');" `
        "SELECT fractal_store_morphology(3, '5.0,5.0,5.0');"
    if ($r1 -eq "ok`nok`nok") {
        Pass '30 feature_store: fractal_store_morphology upserts, returns ok'
    } else {
        Fail "30 feature_store: expected three ok rows, got: $r1"
    }

    $r2 = Sqlq "SELECT fractal_mine_topology_negatives('0.0,0.0,0.0', 3);"
    # -like treats a bare '[' as the start of a wildcard character class,
    # not a literal bracket -- with only one matching ']' (at the very
    # end) the WHOLE pattern collapses into a single one-char class, which
    # can never match a JSON array string. Plain string ops sidestep it.
    if ($r2.StartsWith('[{"doc_id":1,"distance":0},{"doc_id":2,"distance":1},') `
            -and $r2.Contains('"doc_id":3') -and $r2.EndsWith(']')) {
        Pass '30 feature_store: mine_topology_negatives orders by ascending distance'
    } else {
        Fail "30 feature_store: expected doc_id 1,2,3 ascending, got: $r2"
    }

    $r3 = Sqlq "SELECT fractal_mine_topology_negatives('0.0,0.0,0.0', 1);"
    if ($r3 -eq '[{"doc_id":1,"distance":0}]') {
        Pass '30 feature_store: k caps the returned candidate count'
    } else {
        Fail "30 feature_store: expected exactly doc_id 1, got: $r3"
    }

    # Dimension-mismatched row must be skipped, not abort the scan.
    $r4 = Sqlq `
        "SELECT fractal_store_morphology(4, '0.1,0.1');" `
        "SELECT fractal_mine_topology_negatives('0.0,0.0,0.0', 10);"
    if ($r4.Contains('"doc_id":4')) {
        Fail "30 feature_store: expected dim-mismatched doc_id 4 to be skipped, got: $r4"
    } else {
        Pass '30 feature_store: dimension-mismatched row silently skipped, scan not aborted'
    }

    if (ExpectErr 'doc_id must be >= 0' "SELECT fractal_store_morphology(-1, '1.0');") {
        Pass '30 feature_store: negative doc_id rejected'
    } else {
        Fail '30 feature_store: negative doc_id should have raised a clean error'
    }

    if (ExpectErr 'k must be > 0' "SELECT fractal_mine_topology_negatives('0.0,0.0,0.0', 0);") {
        Pass '30 feature_store: non-positive k rejected'
    } else {
        Fail '30 feature_store: k=0 should have raised a clean error'
    }

    $r5 = Sqlq `
        "SELECT fractal_store_morphology(NULL, '1.0');" `
        "SELECT fractal_mine_topology_negatives(NULL, 3);"
    # Two NULL results each print as a blank line, so the joined string is
    # "`n" (one newline), not "" -- IsNullOrEmpty misses that; bash's
    # $(...) strips trailing newlines and sees a true empty string instead.
    if ([string]::IsNullOrWhiteSpace($r5)) {
        Pass '30 feature_store: NULL args are STRICT (NULL in, NULL out)'
    } else {
        Fail "30 feature_store: expected NULL/blank for NULL args, got: $r5"
    }
}

# fractalsql_ledger's append-only hash chain (src/fsql_ledger.c), the
# B-full port of PG's real tamper-evident design -- replacing the old
# last-writer-wins snapshot. Plain Sqlq/ExpectErr assertions cover the
# enterprise gate and the "works with no enterprise_lib at all" contract;
# the storage-layer build/tamper/gap/migration/kind-independence checks
# need raw table manipulation with correctly chained SHA-256 hashes,
# which the sqlite3 CLI cannot compute -- that part runs as ONE python
# driver (same idiom as gate 08/16/19's Write-PyGateNN + PyRun).
#
# Sandbox note (disclosed, same limitation as gate 24/25): a community
# checkout carries no vendored enterprise core, so fractal_ledger_flush()
# and fractal_ledger_load() always report "enterprise tier not loaded" --
# there is no way to exercise the real end-to-end write path (core flush
# -> ledger_materialize -> chain insert) or the O(1) tip check inside
# fractal_ledger_load through the mandated SQL surface there. The driver
# below instead builds/mutates rows directly at the storage layer (the
# exact rows ledger_chain_insert would produce) and exercises
# fractal_ledger_verify(), which is deliberately NOT enterprise-gated (PG
# parity) and shares the same entry_hash/prev_hash recompute logic
# ledger_verify_tip uses for the O(1) load-time check -- so this is real
# coverage of the chain algorithm itself, just entered from a different
# call site than fractal_ledger_flush/load. A checkout with a vendored
# enterprise core would additionally get full end-to-end coverage through
# gate 25 (self-skips here for the same reason).
#
# This gate is hand-mirrored from build_test.sh's Gate 31 by inspection,
# not executed -- the authoring environment has no Windows host to run
# PowerShell against.
function Write-PyGate31 { param([string]$Path)
    $content = @'
import os, sqlite3, sys, hashlib

db, ext = os.environ["FSQL_BT_DB"], os.environ["FSQL_BT_EXT"]
con = sqlite3.connect(db)
con.enable_load_extension(True)
con.load_extension(ext)

failed = False
def check(label, cond, detail=""):
    global failed
    if cond:
        print("OK: %s" % label)
    else:
        failed = True
        print("FAIL: %s%s" % (label, (" -- " + detail) if detail else ""))

def verify(kind=None):
    if kind is None:
        row = con.execute("SELECT fractal_ledger_verify()").fetchone()
    else:
        row = con.execute("SELECT fractal_ledger_verify(?)", (kind,)).fetchone()
    return row[0]

def fresh_table():
    con.execute("DROP TABLE IF EXISTS fractalsql_ledger")
    con.execute("""CREATE TABLE fractalsql_ledger(
      id INTEGER PRIMARY KEY AUTOINCREMENT, kind INTEGER NOT NULL, payload BLOB NOT NULL,
      mac BLOB, prev_hash BLOB NOT NULL, entry_hash BLOB NOT NULL,
      sealed INTEGER NOT NULL DEFAULT 0, updated_at TEXT NOT NULL DEFAULT (datetime('now')))""")
    con.commit()

def append_row(kind, payload):
    # Mirrors ledger_chain_insert exactly: prev_hash = latest entry_hash
    # for this kind (or 32 zero bytes, genesis), entry_hash =
    # SHA256(prev_hash || payload) (no mac column populated here --
    # enterprise_ledger_key is unset in this driver, same as the mac-less
    # path ledger_chain_insert takes).
    row = con.execute(
        "SELECT entry_hash FROM fractalsql_ledger WHERE kind=? ORDER BY id DESC LIMIT 1",
        (kind,)).fetchone()
    prev = row[0] if row else b"\x00" * 32
    eh = hashlib.sha256(prev + payload).digest()
    con.execute(
        "INSERT INTO fractalsql_ledger(kind,payload,mac,prev_hash,entry_hash) VALUES(?,?,NULL,?,?)",
        (kind, payload, prev, eh))
    con.commit()
    return con.execute("SELECT max(id) FROM fractalsql_ledger WHERE kind=?", (kind,)).fetchone()[0]

# 1) A built 2-row chain (simulating two flushes) verifies clean.
fresh_table()
append_row(1, b"truth-blob-1")
append_row(1, b"truth-blob-2")
v = verify()
check("chain build: 2 appended rows verify clean",
      v == '{"ok":true,"rows_verified":2}', v)

# 2) Mutating the TIP row's payload directly is caught by verify()'s
# entry_hash recompute -- the same structural check ledger_verify_tip
# runs at O(1) load time.
tip_id = con.execute("SELECT max(id) FROM fractalsql_ledger WHERE kind=1").fetchone()[0]
con.execute("UPDATE fractalsql_ledger SET payload=? WHERE id=?", (b"TAMPERED", tip_id))
con.commit()
v = verify()
check("tamper detection: a mutated payload is caught by verify()",
      v.startswith('{"ok":false') and "entry_hash mismatch" in v, v)

# 3) Deleting a MIDDLE row out of a 3-row chain leaves a visible id gap.
fresh_table()
append_row(1, b"a")
mid_id = append_row(1, b"b")
append_row(1, b"c")
con.execute("DELETE FROM fractalsql_ledger WHERE id=?", (mid_id,))
con.commit()
v = verify()
check("deletion gap: a deleted middle row is reported as a sequence gap",
      v.startswith('{"ok":false') and "gap" in v, v)

# 4) The old last-writer-wins snapshot shape (no id column) migrates to
# the chain shape the first time the community-surface
# fractal_ledger_verify() touches it (same ensure_table path
# fractal_ledger_flush/load use, just reachable without enterprise).
# ensure_table's migration check only runs once per CONNECTION (the
# FsqlLedgerCtx.table_ready cache), so this needs a FRESH connection to
# see the old-shape table for the "first" time, same as a real upgrade.
con.execute("DROP TABLE IF EXISTS fractalsql_ledger")
con.execute("CREATE TABLE fractalsql_ledger(kind INTEGER PRIMARY KEY, "
            "payload BLOB NOT NULL, sealed BLOB, updated_at TEXT)")
con.execute("INSERT INTO fractalsql_ledger(kind, payload) VALUES(1, X'00')")
con.commit()
con2 = sqlite3.connect(db)
con2.enable_load_extension(True)
con2.load_extension(ext)
v = con2.execute("SELECT fractal_ledger_verify()").fetchone()[0]
cols = [r[1] for r in con2.execute("PRAGMA table_info(fractalsql_ledger)")]
con2.close()
check("migration: old snapshot shape replaced with the chain shape",
      "id" in cols and v == '{"ok":true,"rows_verified":0}',
      "cols=%s verify=%s" % (cols, v))

# 5) kind=1 and kind=2 are independent chains; the default/NULL arg
# targets kind=1, an explicit kind=2 reports on the other chain.
fresh_table()
append_row(1, b"t1"); append_row(1, b"t2")
append_row(2, b"a1"); append_row(2, b"a2"); append_row(2, b"a3")
v1, v2, vdef = verify(1), verify(2), verify()
check("kind independence: verify()/verify(1) agree and differ from verify(2)",
      v1 == vdef == '{"ok":true,"rows_verified":2}'
      and v2 == '{"ok":true,"rows_verified":3}',
      "v1=%s v2=%s vdef=%s" % (v1, v2, vdef))

sys.exit(1 if failed else 0)
'@
    [IO.File]::WriteAllText($Path, $content.Replace("`r`n", "`n"))
}

function Gate-31-LedgerChain {
    Sqlq 'DROP TABLE IF EXISTS fractalsql_ledger;' | Out-Null

    # The NEW parity fix this gate exists to pin: fractal_audit_log now
    # carries the same enterprise gate as the rest of the ledger surface
    # (previously it wrote unconditionally -- a real parity gap against PG,
    # which requires ensure_enterprise_lib() before writing).
    if (ExpectErr 'enterprise tier not loaded' "SELECT fractal_audit_log('test','{}');") {
        Pass '31 ledger_chain: fractal_audit_log now gated (enterprise tier not loaded)'
    } else {
        Fail '31 ledger_chain: fractal_audit_log did not surface the dormant-tier error'
    }

    # Reaffirm flush/load are still gated too (gate 24 already covers this
    # broadly; pinned here again because it's this gate's own subject).
    if (ExpectErr 'enterprise tier not loaded' 'SELECT fractal_ledger_flush();') {
        Pass '31 ledger_chain: fractal_ledger_flush still gated (dormant tier)'
    } else {
        Fail '31 ledger_chain: fractal_ledger_flush did not surface the dormant-tier error'
    }

    # fractal_ledger_verify() is the one function in this surface that is
    # NOT enterprise-gated (PG parity: a pure read-only forensic query) --
    # it must work standalone, creating an empty chain table on first touch.
    $vz = Sqlq 'SELECT fractal_ledger_verify();'
    if ($vz -eq '{"ok":true,"rows_verified":0}') {
        Pass '31 ledger_chain: fractal_ledger_verify() works with no enterprise_lib at all'
    } else {
        Fail "31 ledger_chain: expected an empty-chain report, got: $vz"
    }

    if (-not $script:Py) {
        Skip '31 ledger_chain storage-layer driver (no python3 sqlite3 stdlib)'
        return
    }
    if (Skip-IfPySanitizerBlocked '31 ledger_chain storage-layer driver') { return }
    Write-PyGate31 (Join-Path $script:PlugDir 'py_gate31.py')
    PyRun 'py_gate31'
    if ($LASTEXITCODE -eq 0) {
        Pass '31 ledger_chain: chain build/tamper/gap/migration/kind-independence (see driver OK lines above)'
    } else {
        Fail '31 ledger_chain: see driver output above'
    }
}

function Gate-32-EnterpriseSignatureReal {
    # Real Ed25519 detached-signature verification (src/fsql_ed25519.h,
    # vendored TweetNaCl -- see fsql_enterprise.c's header comment) for
    # the enterprise .dll loader. Self-skips on a community-only
    # checkout, same detection as gate 25 -- no enterprise core is
    # vendored in include/ here, so there is nothing to point
    # enterprise_lib at that would ever get past GetProcAddress symbol
    # resolution far enough to exercise Case A/B's "loads and works"
    # assertion.
    #
    # Mirrors PG's gate_26_enterprise_signature() scope exactly: it
    # does NOT test the "valid signature, actually verifies" happy
    # path either -- that needs the real FractalSQLabs release private
    # key, which lives offline and never belongs in either repo or its
    # test fixtures (see fsql_enterprise.c's FSQL_ENTERPRISE_PUBKEY
    # comment). What IS tested needs no key at all: a missing .sig
    # (soft unless require=on) and a well-formed-but-wrong .sig (always
    # hard-refused -- the one case that actually exercises the new
    # verify() call path, unlike A/B which only exercise presence-
    # checking), plus a wrong-length .sig (also always invalid, never
    # "missing").
    #
    # This gate is hand-mirrored from build_test.sh's Gate 32 by
    # inspection, not executed -- the authoring environment has no
    # Windows host to run PowerShell against.
    # Scoped to include/windows-x86_64 specifically, and to *.dll -- an
    # earlier version of this glob was -Recurse over all of include/
    # with no OS/extension filter, which also matches include/linux-
    # x86_64/libfractalsql-enterprise-*.so (real vendored file in this
    # tree) and windows-x86_64's own *.dll.sig sidecar. Get-ChildItem
    # -Recurse enumerates linux-x86_64 before windows-x86_64
    # alphabetically, so Select-Object -First 1 was silently handing
    # LoadLibraryA a Linux ELF .so -- a clean, deterministic load
    # failure regardless of signature settings (confirmed: this
    # reproduced even with enterprise_require_signature=off, which
    # only makes sense if the file itself was never a valid PE image
    # to begin with -- a hand-verified ctypes.WinDLL() load of the
    # correct windows-x86_64/*.dll path, by contrast, succeeds).
    $found = Get-ChildItem -Path 'include/windows-x86_64' `
        -Filter '*fractalsql-enterprise-*.dll' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if (-not $found) {
        Skip '32 enterprise_signature_real: skipped (community edition; no libfractalsql-enterprise-* in include/)'
        return
    }
    $sigPath = "$found.sig"
    Remove-Item -Force -ErrorAction SilentlyContinue $sigPath

    function New-RandomSigFile {
        param([string]$Path, [int]$Length)
        $bytes = New-Object byte[] $Length
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes)
        $rng.Dispose()
        [System.IO.File]::WriteAllBytes($Path, $bytes)
    }

    # ---- Case A: no .sig, FSQL_ENTERPRISE_ALLOW_UNVERIFIED opt-out +
    # require=off -- soft: still loads and works.
    $env:FSQL_ENTERPRISE_ALLOW_UNVERIFIED = '1'
    $ra = Sqlq `
        "SELECT fractalsql_set('enterprise_lib', '$found');" `
        "SELECT fractalsql_set('enterprise_require_signature','off');" `
        'SELECT fractal_ledger_reset_hard();'
    $rca = $script:SqlqRc
    Remove-Item Env:\FSQL_ENTERPRISE_ALLOW_UNVERIFIED -ErrorAction SilentlyContinue
    if ($rca -eq 0 -and -not $ra.Contains('enterprise tier not loaded')) {
        Pass '32 enterprise_signature_real Case A: missing .sig + env opt-out + require=off -- still loads and works'
    } else {
        Fail "32 enterprise_signature_real Case A: expected a clean load, got rc=${rca}: $ra"
    }

    # ---- Case B: no .sig, no env opt-out -- hard refusal even with
    # require=off (verification is mandatory without the opt-out).
    $rb = Sqlq `
        "SELECT fractalsql_set('enterprise_lib', '$found');" `
        "SELECT fractalsql_set('enterprise_require_signature','off');" `
        'SELECT fractal_ledger_reset_hard();'
    $rcb = $script:SqlqRc
    if ($rcb -ne 0 -and $rb.Contains('no signature found') `
            -and $rb.Contains('FSQL_ENTERPRISE_ALLOW_UNVERIFIED')) {
        Pass '32 enterprise_signature_real Case B: missing .sig, no env opt-out -- refused'
    } else {
        Fail "32 enterprise_signature_real Case B: expected a hard refusal, got rc=${rcb}: $rb"
    }

    # ---- Case C: garbage 64-byte .sig -- ALWAYS hard-refused, even
    # with require=off. The one case that actually exercises the new
    # verify() path (rejecting a well-formed-but-wrong signature).
    New-RandomSigFile -Path $sigPath -Length 64
    $rc = Sqlq `
        "SELECT fractalsql_set('enterprise_lib', '$found');" `
        "SELECT fractalsql_set('enterprise_require_signature','off');" `
        'SELECT fractal_ledger_reset_hard();'
    $rcc = $script:SqlqRc
    if ($rcc -ne 0 -and $rc.Contains('failed signature verification')) {
        Pass '32 enterprise_signature_real Case C: garbage .sig -- always refused regardless of require'
    } else {
        Fail "32 enterprise_signature_real Case C: expected a hard refusal on invalid signature, got rc=${rcc}: $rc"
    }

    # ---- Case D: wrong-length (32-byte) .sig -- also always invalid,
    # never treated as "missing".
    New-RandomSigFile -Path $sigPath -Length 32
    $rd = Sqlq `
        "SELECT fractalsql_set('enterprise_lib', '$found');" `
        "SELECT fractalsql_set('enterprise_require_signature','off');" `
        'SELECT fractal_ledger_reset_hard();'
    $rcd = $script:SqlqRc
    if ($rcd -ne 0 -and $rd.Contains('failed signature verification')) {
        Pass '32 enterprise_signature_real Case D: wrong-length .sig -- treated as invalid, not missing'
    } else {
        Fail "32 enterprise_signature_real Case D: expected a hard refusal on wrong-length signature, got rc=${rcd}: $rd"
    }

    Remove-Item -Force -ErrorAction SilentlyContinue $sigPath
}

# ======================================================================
# Runner
# ======================================================================

function Gate-Title { param([string]$G)
    switch ($G) {
        '01' { 'build' }             '02' { 'smoke' }
        '03' { 'schema_context' }    '04' { 'text_to_sql' }
        '05' { 'evil_overread' }     '06' { 'crash_recovery' }
        '07' { 'evil_lying_length' } '08' { 'authz' }
        '09' { 'guc_superuser' }     '10' { 'dos_and_injection' }
        '11' { 'scout' }             '12' { 'soak' }
        '13' { 'siu_mode' }          '14' { 'retry' }
        '15' { 'embed' }             '16' { 'embed_authz' }
        '17' { 'embed_soak' }        '18' { 'embed_crash' }
        '19' { 'sfs_bounds' }        '20' { 'api_func' }
        '21' { 'fuzz_smoke' }        '22' { 'v2_functions' }
        '23' { 'agents' }            '24' { 'enterprise' }
        '25' { 'enterprise_stress' } '26' { 'enterprise_signature' }
        '27' { 'think' }             '28' { 'review_isolation' }
        '29' { 'domain_agents' }     '30' { 'feature_store' }
        '31' { 'ledger_chain' }
        '32' { 'enterprise_signature_real' }
    }
}

function Invoke-Gate { param([string]$G)
    switch ($G) {
        '01' { Gate-01-Build }             '02' { Gate-02-Smoke }
        '03' { Gate-03-SchemaContext }     '04' { Gate-04-TextToSql }
        '05' { Gate-05-EvilOverread }      '06' { Gate-06-CrashRecovery }
        '07' { Gate-07-EvilLyingLength }   '08' { Gate-08-Authz }
        '09' { Gate-09-GucSuperuser }      '10' { Gate-10-DosAndInjection }
        '11' { Gate-11-Scout }             '12' { Gate-12-Soak }
        '13' { Gate-13-SiuMode }           '14' { Gate-14-Retry }
        '15' { Gate-15-Embed }             '16' { Gate-16-EmbedAuthz }
        '17' { Gate-17-EmbedSoak }         '18' { Gate-18-EmbedCrash }
        '19' { Gate-19-SfsBounds }         '20' { Gate-20-ApiFunc }
        '21' { Gate-21-FuzzSmoke }         '22' { Gate-22-V2Functions }
        '23' { Gate-23-Agents }            '24' { Gate-24-Enterprise }
        '25' { Gate-25-EnterpriseStress }  '26' { Gate-26-EnterpriseSignature }
        '27' { Gate-27-Think }             '28' { Gate-28-ReviewIsolation }
        '29' { Gate-29-DomainAgents }       '30' { Gate-30-FeatureStore }
        '31' { Gate-31-LedgerChain }
        '32' { Gate-32-EnterpriseSignatureReal }
    }
}

# --- main -------------------------------------------------------------------

$mode = 'default'
if ($List) {
    Write-Host "gates: $($script:DEFAULT_GATES -join ' ')"
    Write-Host "fuzz gates: $($script:FUZZ_GATES -join ' ')"
    exit 0
}
if ($Gate) {
    # Comma-separated list runs multiple gates in one invocation, sharing one bt.db.
    $gateList = $Gate -split ',' | ForEach-Object { $_.Trim() }
    foreach ($g in $gateList) {
        if ($script:DEFAULT_GATES -notcontains $g -and $script:FUZZ_GATES -notcontains $g) {
            Write-Host "unknown gate: $g (use 01..30)"
            exit 2
        }
    }
    $gates = $gateList
}
elseif ($Quick) { $mode = 'quick'; $gates = $script:QUICK_GATES }
elseif ($Fuzz)  { $mode = 'fuzz';  $gates = $script:FUZZ_GATES }
else            { $gates = $script:DEFAULT_GATES }

Find-Toolchain
$script:PlugDir = Join-Path $script:BTROOT "fractalsql_bt_$PID"

$sanSuffix = if ($Asan) { ' [ASan]' } elseif ($Ubsan) { ' [UBSan]' } else { '' }
Write-Host "fractalsql-sqlite build_test — $mode$sanSuffix — gates: $($gates -join ' ')"
Write-Host "tmp root: $($script:BTROOT) (db under it) | timeout x$($script:TimeoutMult)"

$ranSetup = $false
try {
    New-Item -ItemType Directory -Force $script:PlugDir | Out-Null
    foreach ($g in $gates) {
        Write-Host ""
        Write-Host "== gate ${g}: $(Gate-Title $g) =="
        if ($g -ne '01' -and $g -ne '21' -and -not $ranSetup) {
            if (-not (BtSetup)) {
                Write-Host 'runtime setup failed — aborting'
                exit 1
            }
            $ranSetup = $true
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Invoke-Gate $g
        $sw.Stop()
        Write-Host "   (gate $g took $([int]$sw.Elapsed.TotalSeconds)s)"
    }
}
finally {
    Invoke-Cleanup
}

if ($script:Failed -eq 1) {
    Write-Host ""
    Write-Host "$($script:R)FAILED$($script:Z) — see the [FAIL] lines above"
    exit 1
}
Write-Host ""
Write-Host "$($script:G)ALL GREEN$($script:Z) — $($gates.Count) gate(s) passed"
exit 0