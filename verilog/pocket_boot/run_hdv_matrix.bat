@echo off
setlocal
rem ============================================================================
rem run_hdv_matrix.bat - HDV sim-host boot matrix, manual launch
rem (2026-11-01, expert-review design; see docs/REVIEW_RESULTS_HDV_SIMHOST_2026-11-01.md)
rem
rem What it does, in order:
rem   1. relinks obj_dir\Vtb_pocket_boot.exe from the existing objects
rem      (fresh PE = fresh hash if the host AV layer is in hash-grace mode)
rem   2. AV probe: runs --help; if the PE is killed (exit 127, zero output)
rem      it waits 90 s and retries up to 3 times
rem   3. baseline WOZ smoke (proves the TB edits did not break the default
rem      path) - aborts the matrix if it fails
rem   4. the six HDV variants, each with its own relink+probe (the AV block
rem      flaps, so every variant gets a fresh PE):
rem         v1_healthy    0x008A mount 0.5 ms, healthy host     BASELINE
rem         v2_latemount  mount at 120 ms (after the ROM scan)
rem         v3_failat3    fetch #3 answered ok err=1
rem         v4_stall3     fetch #3 answered 200 ms late
rem         v5_dtonly     datatable-only mount, no 0x008A
rem         v6_gap50      healthy host, 50-cycle DMA gaps
rem      10 s machine-time budget each (HDV fast path: no WOZ load, boot
rem      is a few ms of machine time; 10 s covers boot + launcher + panic).
rem      Log + frame PPMs land in
rem      hdvrun_<name>\ (run.log, frames\). v1 is the verdict run: its log
rem      must contain HDVFETCH blk=41904 and blk=41907 for the Q6 gate.
rem
rem Total wall time when unblocked: roughly 2 hours.
rem Requires: objects in obj_dir\ are current (run build.sh after RTL edits),
rem g++ at C:\msys64\ucrt64\bin\g++.exe, and the HDV image at the default
rem path below (or edit HDV=).
rem ============================================================================
set "HERE=%~dp0"
cd /d "%HERE%"
set "GPP=C:\msys64\ucrt64\bin\g++.exe"
set "EXE=obj_dir\Vtb_pocket_boot.exe"
set "HDV=..\..\sd_root\Assets\apple2e\common\Total Replay v6.1.hdv"
set "BUDGET=10000"
set "PATH=C:\msys64\ucrt64\bin;%PATH%"

echo === HDV sim-host matrix, 2026-11-01 ===
echo working dir: %CD%
echo hdv image: %HDV%

if not exist "%GPP%" goto noenv
if not exist "%HDV%" goto nohdv
if not exist obj_dir\pocket_main.o goto noobj

:avcheck
set "AVTRY=0"
:avcheck_retry
set /a AVTRY+=1
if %AVTRY% GTR 3 goto avfail
echo relink + AV probe, attempt %AVTRY% of 3
"%GPP%" -O2 -o %EXE% obj_dir\pocket_main.o obj_dir\libVtb_pocket_boot.a obj_dir\libverilated.a obj_dir\Vtb_pocket_boot__ALL.a -lSDL2 -lopengl32 -lgdi32 -limm32
if errorlevel 1 goto avfail
%EXE% --help >nul 2>&1
if not errorlevel 1 goto avok
echo AV block active on fresh PEs, waiting 90 s
timeout /t 90 /nobreak >nul
goto avcheck_retry

:avok
echo AV clear, exe runs.

echo === baseline WOZ smoke ===
%EXE% --smoke
if errorlevel 1 goto smoke_warn
goto matrix
:smoke_warn
echo !!! BASELINE WOZ SMOKE FAILED (known mt=0 finding; does not block HDV)
echo !!! ROM scans slot 7 (HD) first - the HDV verdict stands on its own.
:matrix
call :variant v1_healthy --hdv "%HDV%"
call :variant v2_latemount --hdv "%HDV%" --mount-ms 120
call :variant v3_failat3 --hdv "%HDV%" --fail-at 3
call :variant v4_stall3 --hdv "%HDV%" --stall-at 3 --stall-ms 200
call :variant v5_dtonly --hdv "%HDV%" --hdv-no008a --hdv-dt
call :variant v6_gap50 --hdv "%HDV%" --gap 50

goto end

:noenv
echo MISSING: %GPP%
goto end
:nohdv
echo MISSING HDV image at: %HDV%
echo edit the HDV= line in this bat to point at the .hdv
goto end
:noobj
echo MISSING obj_dir objects - run build.sh first
goto end
:avfail
echo !!! AV block still active after 3 tries, aborting.
echo !!! The block flaps; relaunch this bat later.
goto end
:smokefail
rem (kept for reference; the matrix no longer aborts on smoke failure)
goto end

:variant
set "VN=%~1"
set "AVTRY=0"
:variant_retry
set /a AVTRY+=1
if %AVTRY% GTR 3 goto variant_blocked
echo === %VN, relink + AV probe, attempt %AVTRY% of 3 ===
"%GPP%" -O2 -o %EXE% obj_dir\pocket_main.o obj_dir\libVtb_pocket_boot.a obj_dir\libverilated.a obj_dir\Vtb_pocket_boot__ALL.a -lSDL2 -lopengl32 -lgdi32 -limm32
if errorlevel 1 goto variant_blocked
%EXE% --help >nul 2>&1
if not errorlevel 1 goto variant_run
echo AV block active, waiting 90 s
timeout /t 90 /nobreak >nul
goto variant_retry

:variant_run
rmdir /s /q hdvrun_%VN% 2>nul
mkdir hdvrun_%VN%
echo === %VN, running, budget %BUDGET% ms machine time ===
%EXE% --budget-ms %BUDGET% %2 %3 %4 %5 %6 %7 > hdvrun_%VN%\run.log 2>&1
set "RC=%errorlevel%"
mkdir hdvrun_%VN%\frames 2>nul
copy /y pocket_boot_shots\*.ppm hdvrun_%VN%\frames\ >nul 2>nul
echo === %VN rc=%RC: key log lines ===
type hdvrun_%VN%\run.log | findstr /R /C:"HDV RUN END" /C:"HDVFAIL" /C:"PAST-EOF" /C:"HDVTGT UNEXPECTED" /C:"0x008A mount" /C:"datat"
echo.
exit /b 0

:variant_blocked
echo !!! %VN, AV block persisting after 3 tries - variant skipped
echo.
exit /b 0

:end
echo === matrix complete, results in hdvrun_* folders ===
echo next: compare v1 frames against the hardware NO FILE screen, and check
echo v1 run.log for HDVFETCH blk=41904 and blk=41907
exit /b 0
