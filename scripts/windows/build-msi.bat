@echo off
REM scripts/windows/build-msi.bat
REM
REM Packages fractalsql.dll (pre-built by build.bat) into a Windows
REM MSI using the WiX Toolset.
REM
REM Prerequisites
REM   * WiX Toolset v3.x installed (candle.exe / light.exe on PATH).
REM     Download from https://github.com/wixtoolset/wix3/releases
REM   * dist\windows\fractalsql.dll already built via
REM     scripts\windows\build.bat.
REM   * A README.txt in dist\windows\ (scripts/windows/README.txt
REM     template is shipped in-repo; copy and customize as needed).

setlocal ENABLEEXTENSIONS ENABLEDELAYEDEXPANSION

set REPO_ROOT=%~dp0..\..
pushd %REPO_ROOT%

if not exist "dist\windows\fractalsql.dll" (
    echo ==^> ERROR: dist\windows\fractalsql.dll missing — run build.bat first
    popd
    exit /b 1
)
REM MSI_VERSION: the version stamped into the MSI's ProductVersion and
REM the output filename. release.yml passes it from the release tag.
REM No env var means a plain local run (or install-test.yml's default):
REM fall back to the version string the extension itself reports
REM (FSQL_SQLITE_VERSION_STR in src\fsql_sqlite_internal.h, which
REM fractalsql_version() returns), so the MSI never drifts from the
REM DLL it wraps.
if not "%MSI_VERSION%"=="" goto have_version
REM findstr's space-separated args are OR'ed patterns; /C: is required
REM for one pattern that itself contains spaces (a plain -R match here
REM also catches the header guard and every other #define line, and
REM tokens=3 of the LAST one would win).
for /f "tokens=3" %%v in ('findstr /R /C:"^#define FSQL_SQLITE_VERSION_STR" src\fsql_sqlite_internal.h') do set MSI_VERSION=%%v
:have_version
set MSI_VERSION=%MSI_VERSION:"=%
if "%MSI_VERSION%"=="" (
    echo ==^> ERROR: could not determine MSI_VERSION — set the env var or check src\fsql_sqlite_internal.h
    popd & exit /b 1
)

if not exist "dist\windows\README.txt" (
    echo ==^> generating dist\windows\README.txt
    (
      echo FractalSQL for SQLite, Community Edition %MSI_VERSION%
      echo.
      echo After install, load the extension in any SQLite session:
      echo.
      echo     sqlite3 mydb.sqlite -cmd ".load fractalsql" ^
          -cmd "SELECT fractalsql_edition();"
      echo.
      echo By default the installer prepends the install folder to
      echo the system PATH so `.load fractalsql` resolves without a
      echo full path. To suppress that step on a silent install:
      echo.
      echo     msiexec /i FractalSQL-SQLite-%MSI_VERSION%-x64.msi ADDTOPATH=0
      echo.
      echo One arch variant ships on each release:
      echo     FractalSQL-SQLite-%MSI_VERSION%-x64.msi    64-bit Intel/AMD
    ) > dist\windows\README.txt
)
if not exist "obj" mkdir obj
if not exist "dist\windows" mkdir dist\windows

REM MSI_ARCH drives both candle's -arch flag and the output MSI's
REM filename. Values: x64 (default) | arm64. The x86 and arm64 legs
REM are dormant until the core foundry ships windows-x86 /
REM windows-arm64 drops; the WXS would cope via $(sys.BUILDARCH)
REM when they return.
if "%MSI_ARCH%"=="" set MSI_ARCH=x64

set WXS=scripts\windows\fractalsql.wxs
set MSI=dist\windows\FractalSQL-SQLite-%MSI_VERSION%-%MSI_ARCH%.msi

echo ==^> MSI_VERSION = %MSI_VERSION%
echo ==^> MSI_ARCH = %MSI_ARCH%
echo ==^> MSI      = %MSI%

REM -arch propagates into $(sys.BUILDARCH) inside the WXS, which
REM sets <Package Platform="…"/> and keeps ICE80 happy about the
REM component/directory bitness pairing. -dMSI_VERSION feeds the
REM WXS's own <?ifndef MSI_VERSION?> default (ProductVersion), so
REM the MSI's version matches the filename and the tag it came from.
candle -nologo -arch %MSI_ARCH% -dMSI_VERSION=%MSI_VERSION% -out obj\fractalsql.wixobj %WXS%
if errorlevel 1 (
    echo ==^> candle failed
    popd & exit /b 1
)

light -nologo ^
      -ext WixUIExtension ^
      -ext WixUtilExtension ^
      -out %MSI% ^
      obj\fractalsql.wixobj
if errorlevel 1 (
    echo ==^> light failed
    popd & exit /b 1
)

echo ==^> Built %MSI%
dir %MSI%

popd
endlocal
