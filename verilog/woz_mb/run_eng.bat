@echo off
rem run_eng.bat - build + run tb_woz_mb_eng (step 4: engine-level
rem multi-block controller differential, fake host)
rem
rem PASS marker: "TB WOB MB ENG: ALL PASS (nfail=0)"
rem rc=127 with zero output = host AV killed the fresh PE; re-run this .bat
rem (it always relinks, which buys a new AV grace window).

set PATH=C:\msys64\tmp\makeshim;C:\msys64\ucrt64\bin;C:\msys64\usr\bin;%PATH%
set TMP=C:\msys64\tmp
set TEMP=C:\msys64\tmp
set TMPDIR=C:\msys64\tmp
set VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
set SHELL=C:\msys64\usr\bin\sh

set ROOT=E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket-wozmb
set OBJ=%ROOT%\verilog\obj_mb_eng

if not exist "%TMP%\makeshim" mkdir "%TMP%\makeshim"
copy /Y C:\msys64\ucrt64\bin\mingw32-make.exe %TMP%\makeshim\make.exe >nul 2>&1

rem ---- images (deterministic byte oracles; CWD-relative for $readmemh) ----
cd /d "%ROOT%\verilog\woz_mb"
C:\msys64\ucrt64\bin\python.exe gen_mb_eng_image.py > "%OBJ%_img.log" 2>&1
if errorlevel 1 goto :img_fail

cd /d "%ROOT%"

rem ---- verilate ----
verilator_bin --binary --timing -j 4 --top tb_woz_mb_eng ^
  -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch ^
  --Mdir "%OBJ%" ^
  src/fpga/core/woz/woz_floppy_controller.sv ^
  src/fpga/core/woz/woz_bram.sv ^
  verilog/woz_mb/tb_woz_mb_eng.sv > "%OBJ%.log" 2>&1
if errorlevel 1 goto :verilator_fail
findstr /C:"%%Error" "%OBJ%.log" >nul && goto :verilator_fail

rem ---- link ----
cd /d "%OBJ%"
mingw32-make -f Vtb_woz_mb_eng.mk Vtb_woz_mb_eng >> "%OBJ%.log" 2>&1
if errorlevel 1 goto :link_fail
if not exist Vtb_woz_mb_eng.exe goto :link_fail

rem ---- run (images are CWD-relative: run from verilog/woz_mb) ----
cd /d "%ROOT%\verilog\woz_mb"
%ROOT%\verilog\obj_mb_eng\Vtb_woz_mb_eng.exe
set RUNRC=%ERRORLEVEL%
if "%RUNRC%"=="127" goto :av_killed
if not "%RUNRC%"=="0" goto :run_fail
echo.
echo ENG: PASS - see OK lines above
exit /b 0

:img_fail
echo ERROR: image generation failed
type "%OBJ%_img.log"
exit /b 4

:verilator_fail
echo ERROR: verilator failed - see %OBJ%.log
type "%OBJ%.log" | findstr /C:"%%Error"
exit /b 2

:link_fail
echo ERROR: link failed - see %OBJ%.log
type "%OBJ%.log" | findstr /C:"%%Error"
exit /b 3

:av_killed
echo ERROR: rc=127 zero output - host AV killed the fresh PE, or missing
echo   ucrt64 DLLs on PATH. Just re-run this .bat (relink buys a new window);
echo   if it persists, the AV block is in Phase 2 - try again later.
exit /b 127

:run_fail
echo TB FAILED: exit code %RUNRC% - inspect FAIL lines above
exit /b %RUNRC%
