@echo off
rem SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
rem SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
rem
rem mcp\scripts\windows\build.bat: the Windows leg of the MCP plugin server.
rem Mirrors this repo's own Windows build story: VS 2022 (cl.exe, resolved via
rem vswhere), OpenSSL 3.x from vcpkg's x64-windows-static triplet (the same
rem dependency the sibling repos' build.bat resolve via VCPKG_ROOT / OPENSSL_DIR),
rem the repo's vendored sqlite3 amalgamation, and ws2_32 only for the optional
rem HTTP transport's socket layer.
rem
rem Usage: build.bat [output-dir]        (default: dist\windows-mcp inside mcp\)
rem Builds mcp\<output>\fractalsql-sqlite-mcp.exe.

setlocal enabledelayedexpansion
set SCRIPT_DIR=%~dp0
set MCP_DIR=%SCRIPT_DIR%..\..
set REPO_DIR=%MCP_DIR%\..
set OUTDIR=%~1
if "%OUTDIR%"=="" set OUTDIR=%MCP_DIR%\dist\windows-mcp

rem Resolve the VS installation (BuildTools or full VS).
rem Save the caller's VCPKG_ROOT (CI or a developer's shell) BEFORE
rem vcvars64.bat runs: newer VS versions (reproduced on a GitHub-hosted
rem windows-latest runner once it moved to VS "18"'s bundled vcpkg
rem integration) have vcvars64.bat set its OWN VCPKG_ROOT pointing at
rem VS's bundled (and here, empty) vcpkg tree, silently clobbering
rem whatever the caller already had pointed at a real openssl install --
rem exactly backwards from the "VCPKG_ROOT wins" resolution order below.
set INCOMING_VCPKG_ROOT=%VCPKG_ROOT%
set VSPATH=
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
if exist "%VSWHERE%" (
  for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSPATH=%%i
)
if "%VSPATH%"=="" set VSPATH=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools
if not exist "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" (
  echo FATAL: no Visual Studio 2022 VC tools found ^(set VSPATH or install the C++ workload^) 1>&2
  exit /b 1
)
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 (
  echo FATAL: vcvars64 failed 1>&2
  exit /b 1
)
if not "%INCOMING_VCPKG_ROOT%"=="" set VCPKG_ROOT=%INCOMING_VCPKG_ROOT%

rem Resolve OpenSSL (vcpkg triplet, exactly the sibling repos' pattern).
rem VCPKG_ROOT wins; else the sibling-of-repo checkout (..\github\vcpkg);
rem else VS's bundled vcpkg.
set OPENSSL_DIR=%VCPKG_ROOT%\installed\x64-windows-static
if not exist "%OPENSSL_DIR%\include\openssl\evp.h" (
  set CANDIDATE=%REPO_DIR%\..\vcpkg
  if exist "!CANDIDATE!\installed\x64-windows-static\include\openssl\evp.h" (
    set OPENSSL_DIR=!CANDIDATE!\installed\x64-windows-static
  )
)
if not exist "%OPENSSL_DIR%\include\openssl\evp.h" (
  echo FATAL: OpenSSL for MSVC not found: install via "vcpkg install openssl:x64-windows-static" and set VCPKG_ROOT 1>&2
  exit /b 1
)
if not exist "%SQLITE_DIR%" set SQLITE_DIR=%REPO_DIR%\deps\sqlite
if not exist "%SQLITE_DIR%\sqlite3.c" (
  echo FATAL: vendored amalgamation not found at %SQLITE_DIR%\sqlite3.c 1>&2
  exit /b 1
)

if not exist "%OUTDIR%" mkdir "%OUTDIR%"

rem /MT (static CRT) matches the vcpkg x64-windows-static triplet and yields a
rem self-contained binary, mirroring the release-posture of the rest of this
rem repo's Windows artifacts.
cl.exe /nologo /std:c++17 /utf-8 /EHsc /MT /O2 /W3 ^
  /DFSQL_MCP_VERSION="\"2.0.7\"" ^
  /I "%MCP_DIR%\vendor" /I "%MCP_DIR%\src" /I "%SQLITE_DIR%" ^
  /I "%OPENSSL_DIR%\include" ^
  "%SQLITE_DIR%\sqlite3.c" ^
  "%MCP_DIR%\src\*.cpp" "%MCP_DIR%\src\adapters\*.cpp" ^
  /Fo"%OUTDIR%\\" ^
  /Fe"%OUTDIR%\fractalsql-sqlite-mcp.exe" ^
  /link /LIBPATH:"%OPENSSL_DIR%\lib" libssl.lib libcrypto.lib ws2_32.lib advapi32.lib user32.lib crypt32.lib
if errorlevel 1 (
  echo FATAL: mcp build failed 1>&2
  exit /b 1
)
echo mcp build OK: %OUTDIR%\fractalsql-sqlite-mcp.exe
endlocal
exit /b 0