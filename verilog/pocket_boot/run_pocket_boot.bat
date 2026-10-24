@echo off
rem ============================================================================
rem run_pocket_boot.bat - build (if needed) and run the interactive Pocket
rem boot-debug harness.  Usage (from any cmd):
rem
rem   run_pocket_boot.bat                      (rebuild if missing, then run)
rem   run_pocket_boot.bat build                (force rebuild, then run)
rem   run_pocket_boot.bat smoke                (headless smoke test, no window)
rem   run_pocket_boot.bat build smoke          (rebuild, then headless smoke)
rem   extra args pass through to the exe (e.g. --budget-ms 300000 --woz FILE)
rem
rem AV note: freshly linked exes can be killed by the host AV layer outside
rem a short grace window - this script always relinks and launches in one
rem chained command, which is the reliable pattern on this host.
rem ============================================================================
setlocal enabledelayedexpansion
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
rem "smoke" and "build" accepted in ANY position ("build smoke" used to drop
rem --smoke because only %1 was checked - found 2026-10-24: the run then
rem launched the interactive window instead of headless smoke). Note: rem
rem only comments ONE line in cmd - no wrapped comment blocks.
set "ARGS="
set "SMOKE=0"
rem delayed expansion required: %ARGS% inside a for body expands once at
rem parse time, so accumulation must use !ARGS! (or only the last arg
rem survives)
for %%A in (%*) do (
    if /I "%%A"=="smoke" (
        set "SMOKE=1"
        set "ARGS=!ARGS! --smoke"
    ) else if /I "%%A" neq "build" set "ARGS=!ARGS! %%A"
)
if "!SMOKE!"=="1" echo run_pocket_boot: headless smoke (no window)
if "!SMOKE!"=="0" echo run_pocket_boot: interactive (window)
set "PATH=%UCRT64_BIN%;%PATH%"
pushd "%HERE%"
"%EXE%" %ARGS%
set RC=%ERRORLEVEL%
popd
exit /b %RC%
