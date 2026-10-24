@echo off
rem ============================================================================
rem run_pocket_boot.bat - build (if needed) and run the interactive Pocket
rem boot-debug harness.  Usage (from any cmd):
rem
rem   run_pocket_boot.bat                      (rebuild if missing, then run)
rem   run_pocket_boot.bat build                (force rebuild, then run)
rem   run_pocket_boot.bat smoke                (headless smoke test, no window)
rem
rem AV note: freshly linked exes can be killed by the host AV layer outside
rem a short grace window - this script always relinks and launches in one
rem chained command, which is the reliable pattern on this host.
rem ============================================================================
setlocal
set BASH=C:\msys64\usr\bin\bash.exe
set HERE=%~dp0
set UCRT64_BIN=C:\msys64\ucrt64\bin
set EXE=%HERE%obj_dir\Vtb_pocket_boot.exe

if not exist "%EXE%" goto build
if /I "%1"=="build" goto build
goto run

:build
"%BASH%" "%HERE%build.sh" clean
if errorlevel 1 exit /b 1
"%BASH%" "%HERE%build.sh"
if errorlevel 1 exit /b 1

:run
set ARGS=
if /I "%~1"=="smoke" set ARGS=--smoke
rem pass through any remaining args (e.g. --woz FILE --seq around)
for %%A in (%*) do (
    if /I "%%A" neq "build" if /I "%%A" neq "smoke" set ARGS=%ARGS% %%A
)
set "PATH=%UCRT64_BIN%;%PATH%"
pushd "%HERE%"
"%EXE%" %ARGS%
set RC=%ERRORLEVEL%
popd
exit /b %RC%
