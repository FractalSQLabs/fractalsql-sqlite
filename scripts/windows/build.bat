@echo off
REM scripts/windows/build.bat
REM
REM Builds fractalsql.dll on Windows with the MSVC toolchain — pure C
REM (multi-TU, src\*.c) statically linked against the vendored core
REM archive, matching the Linux posture: zero runtime dependency on the
REM Visual C++ Redistributable.
REM
REM Prerequisites
REM   * Visual Studio Build Tools (cl.exe on PATH — run from a
REM     Developer Command Prompt, or invoke vcvarsall.bat first).
REM   * SQLite SDK headers (sqlite3ext.h). Download from sqlite.org.
REM   * The vendored core drop in include\windows-x86_64\ (shipped with
REM     this repo) — fractalsql-community-sovereign-c.lib by default.
REM     (Windows archives drop the "lib" prefix the Linux drops use.)
REM
REM Environment overrides
REM   SQLITE_DIR       directory holding sqlite3ext.h
REM   OUT_DIR          output directory for fractalsql.dll
REM   CORE_VARIANT     core archive variant (default
REM                    community-sovereign-c; use community-minimal-c
REM                    for the degraded-surface build)
REM
REM Invocation
REM   scripts\windows\build.bat
REM   -- or --
REM   set SQLITE_DIR=C:\deps\sqlite-amalgamation-3460000
REM   set OUT_DIR=dist\windows
REM   scripts\windows\build.bat

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

if "%SQLITE_DIR%"=="" set SQLITE_DIR=C:\deps\sqlite
if "%OUT_DIR%"==""    set OUT_DIR=dist\windows
if "%CORE_VARIANT%"=="" set CORE_VARIANT=community-sovereign-c

if not exist "%OUT_DIR%" mkdir "%OUT_DIR%"

set CORE_LIB=include\windows-x86_64\fractalsql-%CORE_VARIANT%.lib
if not exist "%CORE_LIB%" (
    echo ==^> ERROR: vendored core archive not found: %CORE_LIB%
    echo         Refresh include\ from the core drop first.
    exit /b 1
)

echo ==^> SQLITE_DIR    = %SQLITE_DIR%
echo ==^> OUT_DIR       = %OUT_DIR%
echo ==^> CORE_LIB      = %CORE_LIB%

REM cl.exe flags:
REM   /MT       static CRT (no MSVC runtime DLL dependency)
REM   /GL       whole program optimization
REM   /LTCG     link-time code generation (needed when /GL is active)
REM   /O2       optimize for speed
REM   /std:c11  pure C — this is a C extension, no libstdc++
REM   /DWIN32 /D_WINDOWS
REM   /DFSQL_STATIC   vendored-core linkage contract: static consumers
REM                   get plain symbols instead of dllimport __imp_ refs
REM   /DFSQL_SQLITE_SOVEREIGN — compile the sovereign surface in when a
REM                   sovereign variant is linked (mirrors the Makefile)
REM   /LD       build a DLL
REM
REM bcrypt.lib is required: the core's entropy source calls
REM BCryptGenRandom.
REM
REM The /EXPORT:sqlite3_fractalsql_init line makes the SQLite loader
REM find the entry symbol even with default link visibility.

set SOVEREIGN_DEFINE=/DFSQL_SQLITE_SOVEREIGN
echo %CORE_VARIANT% | findstr /C:"sovereign" >nul
if errorlevel 1 set SOVEREIGN_DEFINE=

set SRC_LIST=
for %%f in (src\*.c) do set SRC_LIST=!SRC_LIST! %%f

cl.exe /nologo /MT /GL /O2 /std:c11 ^
    /DWIN32 /D_WINDOWS %SOVEREIGN_DEFINE% /DFSQL_STATIC ^
    /I"%SQLITE_DIR%" /Iinclude /Isrc ^
    /LD %SRC_LIST% ^
    /Fo"%OUT_DIR%\\" ^
    /Fe"%OUT_DIR%\fractalsql.dll" ^
    /link /LTCG ^
        /EXPORT:sqlite3_fractalsql_init ^
        "%CORE_LIB%" bcrypt.lib

if errorlevel 1 (
    echo.
    echo ==^> BUILD FAILED
    exit /b 1
)

echo.
echo ==^> Built %OUT_DIR%\fractalsql.dll
dir "%OUT_DIR%\fractalsql.dll"

endlocal