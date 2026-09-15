<#
.SYNOPSIS
    easy_install.ps1: the "easy button" for FractalSQL on SQLite for
    Windows. One command gets you from a bare Windows box to a working
    install with reasoning configured. PowerShell counterpart to
    scripts/easy_install.sh (Linux/macOS); same design, Windows-native
    underneath.

.DESCRIPTION
    Detects the sqlite3 CLI (or -Sqlite3Path for a manual override —
    the sqlite.org CLI is a standalone exe, no registry, no service).
    Offers to download+install the matching .msi if the extension
    isn't installed. Runs the same reasoning-provider wizard as
    easy_install.sh: writes a load_fractalsql.sql bootstrap snippet
    (SQLite configuration is per-connection fractalsql_set() state —
    there are no GUCs to persist) and runs a smoke test.

    No telemetry. This script never reports usage, provider choice, or
    success or failure anywhere. That's deliberate, matching FractalSQL's
    own "sovereign reasoning" positioning: your infra choices stay yours.

    Uninstall = file removal. Nothing is registered anywhere.

.PARAMETER Sqlite3Path
    Full path to sqlite3.exe to target. Optional; defaults to the
    first sqlite3.exe on PATH.

.PARAMETER Provider
    ollama | openai-compatible | skip

.PARAMETER Yes
    Pre-confirm every prompt (needed for CI/non-interactive use).

.PARAMETER NoInstall
    Don't offer to install a missing .msi.

.PARAMETER DryRun
    Print what would happen, change nothing.

.PARAMETER Uninstall
    Remove the installed files + snippet.

.PARAMETER Version
    Package version to install. Defaults to this script's own embedded
    version.

.EXAMPLE
    .\easy_install.ps1
    .\easy_install.ps1 -Provider ollama -Yes
#>

param(
    [string]$Sqlite3Path,
    [ValidateSet('ollama', 'openai-compatible', 'skip')][string]$Provider,
    [string]$Url,
    [string]$Model,
    [string]$Token,
    [string]$EmbedUrl,
    [string]$EmbedModel,
    [string]$Think,
    [string]$ThinkProvider,
    [switch]$Yes,
    [switch]$NoInstall,
    [switch]$DryRun,
    [switch]$Uninstall,
    [string]$Version
)

$ErrorActionPreference = 'Stop'

# --- version -----------------------------------------------------------
# Stamped in by release.yml at build time (the placeholder below is
# replaced with the tag version before this file is uploaded as a
# release asset). Falls back to reading src/fsql_sqlite_internal.h
# directly when run from a repo checkout during development, matching
# easy_install.sh's identical fallback.
$FsqlVersion = '@@FSQL_VERSION@@'
if ($FsqlVersion -eq '@@FSQL_VERSION@@') {
    $srcFile = Join-Path $PSScriptRoot '..\..\src\fsql_sqlite_internal.h'
    if (Test-Path $srcFile) {
        $m = Select-String -Path $srcFile -Pattern '^#define FSQL_SQLITE_VERSION_STR   "(.*)"$' | Select-Object -First 1
        if ($m) { $FsqlVersion = $m.Matches[0].Groups[1].Value }
    }
}
if (-not $Version) { $Version = $FsqlVersion }
if (-not $Version) { throw "could not determine a version to install. Pass -Version X.Y.Z" }

$Repo = 'FractalSQLabs/fractalsql-sqlite'
$InstallDir = 'C:\Program Files\FractalSQL'
$Snippet = Join-Path $InstallDir 'load_fractalsql.sql'
# The bootstrap snippet's per-user fallback destination, used when the
# install dir can't be written without an elevated shell (Write-SnippetFile
# below).
$UserSnippet = Join-Path $env:USERPROFILE 'load_fractalsql.sql'

# The sqlite3 CLI's .load tokenizer splits on whitespace and mangles
# backslashes inside "..."-quoted paths, so "C:\Program Files\..." (the
# default install dir, which always contains a space) fails to load with
# "The specified module could not be found." Windows' LoadLibrary accepts
# forward slashes, so hand the CLI this form everywhere. Anything going
# straight to LoadLibrary (fractalsql_set('reasoning_plugin', ...) below,
# python-side load_extension) can keep the backslash form.
$ExtLoad = "$InstallDir\fractalsql.dll".Replace('\', '/')

# --- output helpers ------------------------------------------------------
function Write-Step { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor White }
function Write-Ok   { param([string]$Msg) Write-Host "  [OK] $Msg" -ForegroundColor Green }
function Write-Warn2 { param([string]$Msg) Write-Host "  [!] $Msg" -ForegroundColor Yellow }
function Write-Die   { param([string]$Msg) Write-Host "  [X] $Msg" -ForegroundColor Red; exit 1 }

# Doubles any single quote in a value before it goes inside a SQL string
# literal. Values here come from user input (a URL, a model name, a
# token), and a literal quote in one of them would otherwise break the
# fractalsql_set() call's syntax in the snippet.
function SqlQuote { param([string]$Value) $Value -replace "'", "''" }

# True when this (probably non-elevated) process can create files in
# $Dir. The default install dir is under Program Files, which needs an
# elevated shell -- the wizard decides the snippet's destination up
# front (before the header is built, since the header names the path)
# and falls back to a per-user copy when the install dir isn't
# writable: same keys, same .load line, just a different path.
function Test-DirWritable {
    param([string]$Dir)
    try {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        $probe = Join-Path $Dir ('.fsql_write_test' + [guid]::NewGuid())
        [IO.File]::WriteAllText($probe, 'x')
        Remove-Item -Force $probe
        return $true
    } catch {
        return $false
    }
}

# --- prompting -----------------------------------------------------------
# Unlike `curl | bash`, `iwr ... | iex` does not hijack Read-Host's
# console input the same way piped stdin does in bash. Read-Host talks
# to the console host directly. Still wrapped for a clear error instead
# of an opaque exception in a genuinely non-interactive host (a
# scheduled task, some CI runners), where -Yes / explicit params are
# required instead.
function Confirm-Step {
    param([string]$Question)
    if ($Yes) { Write-Ok "$Question -> yes (-Yes)"; return $true }
    try {
        $reply = Read-Host "$Question [Y/n]"
    } catch {
        Write-Die "'$Question' needs an answer but this doesn't look like an interactive session. Pass -Yes, or the specific parameter for what you're trying to set."
    }
    return ($reply -eq '' -or $reply -match '^[Yy]')
}

function Prompt-Value {
    param([string]$Question, [string]$Default = '')
    try {
        if ($Default) {
            $reply = Read-Host "$Question [$Default]"
            if (-not $reply) { return $Default }
            return $reply
        } else {
            return Read-Host $Question
        }
    } catch {
        if ($Default) { return $Default }
        Write-Die "'$Question' needs an answer but this doesn't look like an interactive session. Pass the corresponding parameter."
    }
}

function Prompt-Secret {
    param([string]$Question)
    try {
        $secure = Read-Host $Question -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    } catch {
        Write-Die "'$Question' needs an answer but this doesn't look like an interactive session. Pass -Token."
    }
}

# --- detect ----------------------------------------------------------------
function Get-Sqlite3 {
    if ($Sqlite3Path) {
        if (-not (Test-Path $Sqlite3Path)) {
            Write-Die "-Sqlite3Path '$Sqlite3Path' doesn't exist"
        }
        return $Sqlite3Path
    }
    $cmd = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Die "no sqlite3.exe found on PATH. Install it (winget install SQLite.SQLite, or download the sqlite-tools zip from sqlite.org) and re-run, or pass -Sqlite3Path."
    }
    return $cmd.Source
}

function Test-Installed {
    return (Test-Path (Join-Path $InstallDir 'fractalsql.dll'))
}

# Runs one sqlite3 session with the extension loaded, returns trimmed
# stdout. $Sql accepts one statement or an array; -cmd flags keep the
# load + statements in ONE session (config is per-connection).
function Invoke-Sqlite {
    param([string]$SqliteBin, [string[]]$Sql, [string]$Db = ':memory:')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $SqliteBin
    $argList = @($Db, '-cmd', ".load `"$ExtLoad`"")
    foreach ($s in $Sql) { $argList += @($s) }
    foreach ($a in $argList) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $errOut = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0) { throw "sqlite3 failed: $errOut" }
    return $out.Trim()
}

# --- Phase B: install the package (default-on, confirmed) ------------------
function Install-Package {
    if (Test-Installed) { return }
    if ($NoInstall) {
        Write-Die "FractalSQL isn't installed yet. Grab the matching .msi from https://github.com/$Repo/releases and install it, then re-run this script (or drop -NoInstall)."
    }
    if (-not (Confirm-Step "FractalSQL isn't installed yet. Install it now?")) {
        Write-Die "Nothing to do without installing the package first. Re-run without -NoInstall, or install it yourself from https://github.com/$Repo/releases."
    }

    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { Write-Die "unsupported architecture (this script and the .msi are x64-only)" }
    $asset = "FractalSQL-SQLite-$Version-$arch.msi"
    $assetUrl = "https://github.com/$Repo/releases/download/v$Version/$asset"
    $tmp = Join-Path $env:TEMP "fsql-easy-install-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $msiPath = Join-Path $tmp $asset
        Write-Step "Downloading $asset..."
        # -UseBasicParsing: without it, older PowerShell/IE-engine
        # configurations throw an interactive "script code might run"
        # Y/N security prompt that sits outside this script's own
        # Confirm-Step/-Yes handling entirely and would silently block
        # a non-interactive run.
        Invoke-WebRequest -Uri $assetUrl -OutFile $msiPath -UseBasicParsing
        Write-Step "msiexec /i `"$msiPath`" /quiet /norestart"
        if (-not $DryRun) {
            $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msiPath`"", '/quiet', '/norestart') -Wait -PassThru
            if ($p.ExitCode -ne 0) { throw "msiexec exited with code $($p.ExitCode)" }
        }
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
    Write-Ok "Package installed."
}

# --- Phase C: the wizard -----------------------------------------------
function Invoke-Wizard {
    param([string]$SqliteBin)

    # Actual snippet destination, set below (may end up the per-user
    # fallback when the install dir isn't writable non-elevated).
    $snippetPath = $Snippet

    if (-not $Provider) {
        Write-Step "Reasoning provider:"
        Write-Host "  1) Local Ollama"
        Write-Host "  2) Cloud / OpenAI-compatible endpoint"
        Write-Host "  3) Skip: search-only install, configure reasoning later"
        $choice = Prompt-Value "Choice" "1"
        $Provider = switch ($choice) { '1' { 'ollama' } '2' { 'openai-compatible' } default { 'skip' } }
    }

    $pluginDll = Join-Path $InstallDir 'fractalsql-reasoning-http.dll'

    $cfg = [ordered]@{}
    switch ($Provider) {
        'ollama' {
            if (-not $Url) { $Url = Prompt-Value "Ollama chat URL" "http://localhost:11434/v1/chat/completions" }
            if (-not $Model) { $Model = Prompt-Value "Model" "gpt-oss:20b" }
            if (-not $EmbedUrl) { $EmbedUrl = Prompt-Value "Ollama embeddings URL" "http://localhost:11434/v1/embeddings" }
            if (-not $EmbedModel) { $EmbedModel = Prompt-Value "Embedding model" "nomic-embed-text" }
            if (-not $Think) { $Think = 'off' }
            if (-not $ThinkProvider) { $ThinkProvider = 'ollama' }
            $cfg['reasoning_plugin'] = "'$(SqlQuote $pluginDll)'"
            $cfg['http_url'] = "'$(SqlQuote $Url)'"
            $cfg['http_allow_plaintext'] = "'on'"
            $cfg['http_model'] = "'$(SqlQuote $Model)'"
            $cfg['http_embed_url'] = "'$(SqlQuote $EmbedUrl)'"
            $cfg['http_embed_model'] = "'$(SqlQuote $EmbedModel)'"
            $cfg['http_think'] = "'$(SqlQuote $Think)'"
            $cfg['http_think_provider'] = "'$(SqlQuote $ThinkProvider)'"
        }
        'openai-compatible' {
            if (-not $Url) { $Url = Prompt-Value "Chat completions URL" }
            if (-not $Url) { Write-Die "a URL is required for a cloud/OpenAI-compatible endpoint" }
            if (-not $Model) { $Model = Prompt-Value "Model" "gpt-4o-mini" }
            if (-not $Token) { $Token = Prompt-Secret "API token (masked, never logged)" }
            $cfg['reasoning_plugin'] = "'$(SqlQuote $pluginDll)'"
            $cfg['http_url'] = "'$(SqlQuote $Url)'"
            $cfg['http_token'] = "'$(SqlQuote $Token)'"
            $cfg['http_model'] = "'$(SqlQuote $Model)'"
            if ($Url -notlike 'https://*') {
                Write-Warn2 "That URL isn't https://. That's fine for localhost or a private LAN, but risky for anything else. Not blocking, just flagging it."
            }
        }
        'skip' {
            Write-Step "Skipping reasoning config. Search functions like fractal_search and fractal_search_explore work with no model."
        }
    }

    if ($Provider -ne 'skip') {
        Write-Step "About to write configuration to ${Snippet}:"
        foreach ($k in $cfg.Keys) {
            if ($k -eq 'http_token') { Write-Host "  fractalsql_set('http_token', '***')" }
            else { Write-Host "  fractalsql_set('$k', $($cfg[$k]))" }
        }
        if (-not (Confirm-Step "Write this configuration?")) { Write-Die "Aborted. Nothing was changed." }
        # Destination decided up front (the header below names the path
        # in its usage hint, so it must be known before that's built).
        # A non-elevated shell can't write under Program Files -- fall
        # back to a per-user copy: same keys, same .load line, just a
        # different path, and every later message names $snippetPath.
        if (-not $DryRun -and -not (Test-DirWritable $InstallDir)) {
            $snippetPath = $UserSnippet
            Write-Warn2 "Couldn't write to $Snippet (that path needs an elevated shell). Writing the snippet to $UserSnippet instead - same keys, same .load line."
        }
        if ($DryRun) {
            Write-Step "(-DryRun: snippet not written)"
        } else {
            # The bootstrap snippet: .load + one fractalsql_set per key.
            # SQLite configuration is per-connection state (no GUCs, no
            # reload), so every session that wants the reasoning tier
            # reads this snippet via -init or .read.
            $header = @"
-- load_fractalsql.sql - generated by easy_install.ps1 $Version
--
-- Per-session bootstrap for FractalSQL on SQLite. Run it with:
--     sqlite3 -init "$snippetPath" mydb.sqlite
-- or from inside a session:
--     .read "$snippetPath"
--
-- Configuration is per-connection (there are no GUCs to persist), so
-- this snippet runs on every session that wants the reasoning tier.
-- Search-only usage needs just the .load line below.

.load "$ExtLoad"
"@
            $lines = @($header)
            foreach ($k in $cfg.Keys) { $lines += "SELECT fractalsql_set('$k', $($cfg[$k]));" }
            New-Item -ItemType Directory -Force -Path (Split-Path $snippetPath -Parent) | Out-Null
            # ASCII file; default encoding fine. Protect the token.
            [IO.File]::WriteAllLines($snippetPath, $lines)
            Write-Ok "Reasoning configured in $snippetPath."
            if ($cfg.Contains('http_token')) {
                Write-Warn2 "Snippet contains your http_token in plain text - protect it like a credential (ACL restricted below)."
            }
            # Braced form: in "$env:USERNAME:R" the parser reads
            # USERNAME:R as ONE drive-qualified variable name, which
            # resolves to nothing - icacls then gets an empty /grant:r
            # argument ("Invalid parameter", exit 87) and the snippet
            # keeps its inherited ACL.
            icacls.exe $snippetPath /inheritance:r /grant:r "${env:USERNAME}:R" | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Warn2 "couldn't restrict the snippet's ACL (icacls exited $LASTEXITCODE) - the file keeps its inherited ACL."
            }
        }
    }

    if (-not $DryRun) {
        $ed = Invoke-Sqlite $SqliteBin "SELECT fractalsql_edition();"
        $ver = Invoke-Sqlite $SqliteBin "SELECT fractalsql_version();"
        Write-Ok "fractalsql_edition() = $ed, fractalsql_version() = $ver"
        if ($ver -ne $Version) {
            Write-Warn2 "That's not $Version, the version this script expected. The installed files themselves are out of date. Reinstall the current .msi from https://github.com/$Repo/releases to actually update fractalsql.dll, then re-run this script."
        }
        if ($Provider -ne 'skip' -and (Confirm-Step "Run a live reasoning smoke test (SELECT fractal_reason('say ok'))? A cloud endpoint may incur cost, and a cold local model can take several minutes the first time.")) {
            try {
                # .read inside a -cmd, NOT -init: the CLI runs the -init
                # file on its own open, and the fractalsql_set() state
                # written there does not reach the connection that
                # executes the command-line SQL afterwards (fractal_reason
                # then reports "reasoning plugin not configured"). .read
                # in the same session as the query is exactly the bash
                # wizard's form. Forward slashes + single quotes: same
                # form the snippet's own .load line uses, which the CLI's
                # dot-command tokenizer accepts with spaces in the path.
                $readSnippet = ".read '$($snippetPath.Replace('\', '/'))'"
                $reply = Invoke-Sqlite $SqliteBin @("-cmd", $readSnippet, "SELECT fractal_reason('say ok');")
                Write-Host "  $reply"
            } catch {
                Write-Warn2 "smoke error: $($_.Exception.Message)"
                Write-Warn2 "That failed. If it looks like a timeout on a slow/cold local model, give the model a minute and retry, or raise the plugin's wait ceiling first (FSQL_REASONING_HTTP_TIMEOUT_MS / FSQL_REASONING_HTTP_LOW_SPEED_SECS in the shell before starting sqlite3), or see docs/reasoning-setup.md's 'Handling Constrained Hardware' section."
            }
        }
    }

    Write-Host ""
    Write-Host "You're set up. Where next:" -ForegroundColor Green
    Write-Host "  - Pass the snippet to every session: sqlite3 -init `"$snippetPath`" mydb.sqlite"
    Write-Host "  - Cold Ollama models can take minutes on the first call; the reasoning"
    Write-Host "    plugin's FSQL_REASONING_HTTP_TIMEOUT_MS env var raises the wait."
    Write-Host "  - docs/starter-kits.md: industry-specific runnable examples"
    Write-Host "  - docs/api-agency.md: the built-in agents, full reference"
    Write-Host "  - docs/composition-guide.md: build your own agent"
    Write-Host "  - Re-run this script anytime to switch providers or models. It's"
    Write-Host "    safe, it just rewrites $snippetPath."
}

# --- -Uninstall ---------------------------------------------------------
function Invoke-Uninstall {
    Write-Step "This will remove the FractalSQL extension files and the generated snippet."
    if (Confirm-Step "Remove $InstallDir (fractalsql.dll, the reasoning plugin, and $Snippet) plus any per-user snippet?") {
        if ($DryRun) {
            Write-Step "(-DryRun: not actually removing)"
        } else {
            # $UserSnippet covers the per-user fallback a non-elevated
            # wizard run would have written to (see Invoke-Wizard);
            # SilentlyContinue because either or both may not exist.
            Remove-Item -Force `
                (Join-Path $InstallDir 'fractalsql.dll') `
                (Join-Path $InstallDir 'fractalsql-reasoning-http.dll') `
                $Snippet `
                $UserSnippet -ErrorAction SilentlyContinue
            Write-Ok "Files removed. Nothing was registered anywhere else - SQLite extensions leave no other trace."
        }
    }
    Write-Host "  To remove the package: uninstall 'FractalSQL for SQLite' from Windows Settings > Apps, or msiexec /x <product code>"
}

# --- main ------------------------------------------------------------------
$sqliteBin = Get-Sqlite3
Write-Step "Targeting sqlite3 CLI: $sqliteBin (install dir: $InstallDir)"

if ($Uninstall) {
    Invoke-Uninstall
    exit 0
}

Install-Package
Invoke-Wizard $sqliteBin