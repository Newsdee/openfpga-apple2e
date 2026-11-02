@echo off
setlocal
rem ============================================================================
rem run_hdv_matrix.bat - HDV sim-host boot matrix, manual launch
rem
rem Usage:
rem   run_hdv_matrix.bat                full matrix (smoke + v1-v8)
rem   run_hdv_matrix.bat v1_healthy     single variant, no smoke (~10 min wall)
rem (2026-11-01, expert-review design; see docs/REVIEW_RESULTS_HDV_SIMHOST_2026-11-01.md)
rem
rem What it does, in order:
rem   1. relinks obj_dir\Vtb_pocket_boot.exe from the existing objects
rem      (fresh PE = fresh hash if the host AV layer is in hash-grace mode)
rem   2. AV probe: runs --help; if the PE is killed (exit 127, zero output)
rem      it waits 90 s and retries up to 3 times
rem   3. baseline WOZ smoke (proves the TB edits did not break the default
rem      path) - failure does NOT block the matrix (known sim storage-drain
rem      stall keeps MT=0; the HDV verdict is independent)
rem   4. the HDV variants, each with its own relink+probe (the AV block
rem      flaps, so every variant gets a fresh PE):
rem         v1_healthy    0x008A mount at reset release+50us    BASELINE
rem         v2_latemount  mount 120 ms after release (post-scan)
rem         v3_failat3    fetch #3 answered ok err=1
rem         v4_stall3     fetch #3 answered 200 ms late
rem         v5_dtonly     datatable-only mount, no 0x008A
rem         v6_gap50      healthy host, 50-cycle DMA gaps
rem         v7_nearmiss   mount 25 ms after release (scan edge)
rem         v8_nomount    never mounted - ROM falls back to C600 (rc=5 expected)
rem      Per-variant machine-time CEILING (fast-matrix config): healthy
rem      runs early-exit at milestones+200 ms settle; the ceiling only
rem      bounds fall-through/fault variants (v2/v8 never hit milestones).
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
rem Budget is a CEILING per variant (fast-matrix config 2026-11-01: the
rem sim runs ~1800x slower than realtime, so a 10 s ceiling meant ~5 h
rem wall per fall-through variant). Healthy runs early-exit at
rem milestones+200 ms settle; the ceiling only bounds runs that never
rem reach the milestones. Set per variant below.
set "BUDGET=1000"
set "PATH=C:\msys64\ucrt64\bin;%PATH%"

echo === HDV sim-host matrix, 2026-11-01 ===
echo working dir: %CD%
echo hdv image: %HDV%

if not exist "%GPP%" goto noenv
if not exist "%HDV%" goto nohdv
if not exist obj_dir\pocket_main.o goto noobj
rem ------------------------------------------------------------------
rem Optional single-variant mode: run_hdv_matrix.bat <variant>
rem (skips the WOZ smoke; runs with that variant's own ceiling)
rem (the --hdv "%HDV%" arg is prepended in :single_run; SVARGS holds only
rem quote-free extra flags - nested quotes inside a paren block break cmd)
rem ------------------------------------------------------------------
if "%~1"=="" goto fullflow
if "%~1"=="v1_healthy"   (set "SV=v1_healthy"& set "BUDGET=1000"& set "SVARGS="& goto avcheck)
if "%~1"=="v2_latemount" (set "SV=v2_latemount"& set "BUDGET=300"& set "SVARGS=--mount-ms 120"& goto avcheck)
if "%~1"=="v3_failat3"   (set "SV=v3_failat3"& set "BUDGET=500"& set "SVARGS=--fail-at 3"& goto avcheck)
if "%~1"=="v4_stall3"    (set "SV=v4_stall3"& set "BUDGET=700"& set "SVARGS=--stall-at 3 --stall-ms 200"& goto avcheck)
if "%~1"=="v5_dtonly"    (set "SV=v5_dtonly"& set "BUDGET=1000"& set "SVARGS=--hdv-no008a --hdv-dt"& goto avcheck)
if "%~1"=="v6_gap50"     (set "SV=v6_gap50"& set "BUDGET=1000"& set "SVARGS=--gap 50"& goto avcheck)
if "%~1"=="v7_nearmiss"  (set "SV=v7_nearmiss"& set "BUDGET=500"& set "SVARGS=--mount-ms 25"& goto avcheck)
if "%~1"=="v8_nomount"   (set "SV=v8_nomount"& set "BUDGET=300"& set "SVARGS=--hdv-nomount"& goto avcheck)
echo unknown variant: %~1
echo valid: v1_healthy v2_latemount v3_failat3 v4_stall3 v5_dtonly v6_gap50 v7_nearmiss v8_nomount
goto end
:fullflow

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
if defined SV goto single_run

echo === baseline WOZ smoke ===
rem 300 ms ceiling: the smoke gate (100 ms) early-exits when healthy
rem (~4 min wall); a stalled smoke (known storage-drain stall) costs
rem ~9 min wall instead of ~60 (was 2 s ceiling; fast-matrix 2026-11-01).
%EXE% --smoke --budget-ms 300
if errorlevel 1 goto smoke_warn
goto matrix
:smoke_warn
echo !!! BASELINE WOZ SMOKE FAILED (known mt=0 finding; does not block HDV)
echo !!! ROM scans slot 7 (HD) first - the HDV verdict stands on its own.
:single_run
call :variant %SV% --hdv "%HDV%" %SVARGS%
goto end

:matrix
set "BUDGET=1000"
call :variant v1_healthy --hdv "%HDV%"
set "BUDGET=300"
call :variant v2_latemount --hdv "%HDV%" --mount-ms 120
set "BUDGET=500"
call :variant v3_failat3 --hdv "%HDV%" --fail-at 3
set "BUDGET=700"
call :variant v4_stall3 --hdv "%HDV%" --stall-at 3 --stall-ms 200
set "BUDGET=1000"
call :variant v5_dtonly --hdv "%HDV%" --hdv-no008a --hdv-dt
set "BUDGET=1000"
call :variant v6_gap50 --hdv "%HDV%" --gap 50
set "BUDGET=500"
call :variant v7_nearmiss --hdv "%HDV%" --mount-ms 25
set "BUDGET=300"
call :variant v8_nomount --hdv "%HDV%" --hdv-nomount

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
echo === [%VN] relink + AV probe, attempt %AVTRY% of 3 ===
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
echo === [%VN] running, budget %BUDGET% ms machine time ===
%EXE% --budget-ms %BUDGET% %2 %3 %4 %5 %6 %7 > hdvrun_%VN%\run.log 2>&1
set "RC=%errorlevel%"
mkdir hdvrun_%VN%\frames 2>nul
copy /y pocket_boot_shots\*.ppm hdvrun_%VN%\frames\ >nul 2>nul
echo === [%VN] rc=%RC% - key log lines ===
type hdvrun_%VN%\run.log | findstr /R /C:"HDV RUN END" /C:"HDVFAIL" /C:"PAST-EOF" /C:"HDVTGT UNEXPECTED" /C:"0x008A mount" /C:"datat"
echo.
exit /b 0

:variant_blocked
echo !!! [%VN] AV block persisting after 3 tries - variant skipped
echo.
exit /b 0

:end
echo === matrix complete, results in hdvrun_* folders ===
echo next: compare v1 frames against the hardware NO FILE screen, and check
echo v1 run.log for HDVFETCH blk=41904 and blk=41907
exit /b 0
