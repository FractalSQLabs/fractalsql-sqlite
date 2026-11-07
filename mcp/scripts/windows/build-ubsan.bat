@echo off
rem SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
rem SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
rem
rem mcp\scripts\windows\build-ubsan.bat: the UBSan build of the MCP server.
rem Same tree as build.bat, built with clang-cl -fsanitize=undefined; the first
rem undefined behavior aborts the server. /MT matches build.bat and the static
rem OpenSSL, and avoids a RuntimeLibrary mismatch against the C++ UBSan runtime.
rem
rem Usage: build-ubsan.bat [output-dir]   (default: dist\windows-mcp-ubsan in mcp\)

setlocal enabledelayedexpansion
set SCRIPT_DIR=%~dp0
set MCP_DIR=%SCRIPT_DIR%..\..
set REPO_DIR=%MCP_DIR%\..
set OUTDIR=%~1
if "%OUTDIR%"=="" set OUTDIR=%MCP_DIR%\dist\windows-mcp-ubsan

rem Save the caller's VCPKG_ROOT before vcvars64.bat runs -- see
rem build.bat's identical comment: newer VS versions' vcvars64.bat sets
rem its own VCPKG_ROOT (VS's bundled, usually-empty vcpkg), clobbering
rem whatever the caller already pointed at a real openssl install.
set INCOMING_VCPKG_ROOT=%VCPKG_ROOT%
set VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
set VSPATH=
if exist "%VSWHERE%" (
  for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSPATH=%%i
)
if "%VSPATH%"=="" set VSPATH=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools
if not exist "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" (
  echo FATAL: no Visual Studio 2022 VC tools found 1>&2
  exit /b 1
)
call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul 2>&1
if errorlevel 1 exit /b 1
if not "%INCOMING_VCPKG_ROOT%"=="" set VCPKG_ROOT=%INCOMING_VCPKG_ROOT%

rem clang-cl ships in VS's LLVM tools dir.
set CLANGCL=%VSPATH%\VC\Tools\Llvm\x64\bin\clang-cl.exe
if not exist "%CLANGCL%" set CLANGCL=clang-cl.exe

set OPENSSL_DIR=%VCPKG_ROOT%\installed\x64-windows-static
if not exist "%OPENSSL_DIR%\include\openssl\evp.h" (
  set CANDIDATE=%REPO_DIR%\..\vcpkg
  if exist "!CANDIDATE!\installed\x64-windows-static\include\openssl\evp.h" set OPENSSL_DIR=!CANDIDATE!\installed\x64-windows-static
)
if not exist "%OPENSSL_DIR%\include\openssl\evp.h" (
  echo FATAL: OpenSSL for MSVC not found: run vcpkg install openssl:x64-windows-static 1>&2
  exit /b 1
)
set SQLITE_DIR=%REPO_DIR%\deps\sqlite
if not exist "%SQLITE_DIR%\sqlite3.c" (
  echo FATAL: vendored amalgamation not found 1>&2
  exit /b 1
)

if not exist "%OUTDIR%" mkdir "%OUTDIR%"

rem /DNOMINMAX suppresses windows.h's function-like min()/max() macros so they
rem do not rewrite std::min/std::max -- see build.bat for the full rationale.
"%CLANGCL%" /std:c++17 /utf-8 /EHsc /Od /W3 /DNOMINMAX -fsanitize=undefined -fno-sanitize-recover=undefined ^
  /DFSQL_MCP_VERSION="\"2.0.12\"" ^
  /I "%MCP_DIR%\vendor" /I "%MCP_DIR%\src" /I "%SQLITE_DIR%" ^
  /I "%OPENSSL_DIR%\include" ^
  "%SQLITE_DIR%\sqlite3.c" ^
  "%MCP_DIR%\src\*.cpp" "%MCP_DIR%\src\adapters\*.cpp" ^
  /Fo"%OUTDIR%\\" ^
  /Fe"%OUTDIR%\fractalsql-sqlite-mcp.exe" ^
  /link /LIBPATH:"%OPENSSL_DIR%\lib" libssl.lib libcrypto.lib ws2_32.lib advapi32.lib user32.lib crypt32.lib
if errorlevel 1 (
  echo FATAL: ubsan mcp build failed 1>&2
  exit /b 1
)
echo ubsan mcp build OK: %OUTDIR%\fractalsql-sqlite-mcp.exe
endlocal
exit /b 0