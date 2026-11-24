@echo off
rem run_t5_scanwin.bat - build + run tb_woz_scanwin (scan-window flux check)
rem
rem Narrow repro for ADDENDUM_WOZ_LOAD_IOERR_SCAN_WINDOW_2026-11-22:
rem instantiates only woz_floppy_controller + woz_bram with a fake host;
rem no SDRAM stack, runs ~4 ms of sim time (seconds of wall time).
rem
rem PASS marker: "TB WOZ SCANWIN: ALL PASS"
rem On the PRE-FIX RTL this TB FAILS with "scan-window silence: bit_count=0".
rem rc=127 with zero output = host AV killed the fresh PE; just re-run
rem (this script always relinks, which buys a new AV grace window).

set PATH=C:\msys64\tmp\makeshim;C:\msys64\ucrt64\bin;C:\msys64\usr\bin;%PATH%
set TMP=C:\msys64\tmp
set TEMP=C:\msys64\tmp
set TMPDIR=C:\msys64\tmp
set VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
set SHELL=C:\msys64\usr\bin\sh

set ROOT=E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket
set OBJ=%ROOT%\verilog\obj_dir_tb_woz_scanwin_wt
set W=%ROOT%/src/fpga/core/woz

if not exist "%TMP%\makeshim" mkdir "%TMP%\makeshim"
copy /Y C:\msys64\ucrt64\bin\mingw32-make.exe %TMP%\makeshim\make.exe >nul 2>&1

rem ---- verilate (fresh Mdir each time; cheap for this TB) ----
cd /d "%ROOT%"
verilator_bin --binary --timing -j 4 --top tb_woz_scanwin ^
  -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch ^
  --Mdir "%OBJ%" ^
  "%W%/woz_floppy_controller.sv" "%W%/woz_bram.sv" ^
  verilog/tb/tb_woz_scanwin.sv > "%OBJ%.log" 2>&1
if errorlevel 1 goto :verilator_fail
findstr /C:"%%Error" "%OBJ%.log" >nul && goto :verilator_fail

rem ---- link (make recipe shell must be sh, not cmd) ----
cd /d "%OBJ%"
mingw32-make -f Vtb_woz_scanwin.mk Vtb_woz_scanwin >> "%OBJ%.log" 2>&1
if errorlevel 1 goto :link_fail
if not exist Vtb_woz_scanwin.exe goto :link_fail

rem ---- run (fresh PE: run immediately inside the AV grace window) ----
Vtb_woz_scanwin.exe
set RUNRC=%ERRORLEVEL%
if "%RUNRC%"=="127" goto :av_killed
if not "%RUNRC%"=="0" goto :run_fail
echo.
echo T5 SCANWIN: PASS - see "ALL PASS" line above
exit /b 0

:verilator_fail
echo ERROR: verilator failed - see %OBJ%.log
type "%OBJ%.log" | findstr /C:"%%Error"
exit /b 2

:link_fail
echo ERROR: link failed - see %OBJ%.log
exit /b 3

:av_killed
echo ERROR: rc=127 zero output - host AV killed the fresh PE, or missing
echo   ucrt64 DLLs on PATH. Just re-run this .bat (relink buys a new window);
echo   if it persists, the AV block is in Phase 2 - try again later.
exit /b 127

:run_fail
echo TB FAILED: exit code %RUNRC% - inspect FAIL lines above
exit /b %RUNRC%
