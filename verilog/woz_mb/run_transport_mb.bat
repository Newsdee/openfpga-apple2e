@echo off
rem run_transport_mb.bat - build + run tb_woz_transport_mb (step 3 burst DUT)
rem
rem PASS marker: "TB WOX TRANSPORT MB: ALL PASS (nfail=0)"
rem rc=127 with zero output = host AV killed the fresh PE; re-run this .bat
rem (it always relinks, which buys a new AV grace window).

set PATH=C:\msys64\tmp\makeshim;C:\msys64\ucrt64\bin;C:\msys64\usr\bin;%PATH%
set TMP=C:\msys64\tmp
set TEMP=C:\msys64\tmp
set TMPDIR=C:\msys64\tmp
set VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
set SHELL=C:\msys64\usr\bin\sh

set ROOT=E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket-wozmb
set OBJ=%ROOT%\verilog\obj_mb_transport

if not exist "%TMP%\makeshim" mkdir "%TMP%\makeshim"
copy /Y C:\msys64\ucrt64\bin\mingw32-make.exe %TMP%\makeshim\make.exe >nul 2>&1

rem ---- verilate ----
cd /d "%ROOT%"
verilator_bin --binary --timing -j 4 --top tb_woz_transport_mb ^
  -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch ^
  --Mdir "%OBJ%" ^
  src/fpga/core/apple2e/sdram_woz_transport_mb.v ^
  src/fpga/core/apple2e/sdram_sector_fetch.v ^
  src/fpga/core/apple2e/sdram_word_owner.v ^
  src/fpga/core/apple2e/io_sdram_pocket.v ^
  src/fpga/apf/common.v ^
  verilog/tb/tb_dram_model.sv ^
  verilog/woz_mb/tb_woz_transport_mb.sv > "%OBJ%.log" 2>&1
if errorlevel 1 goto :verilator_fail
findstr /C:"%%Error" "%OBJ%.log" >nul && goto :verilator_fail

rem ---- link ----
cd /d "%OBJ%"
mingw32-make -f Vtb_woz_transport_mb.mk Vtb_woz_transport_mb >> "%OBJ%.log" 2>&1
if errorlevel 1 goto :link_fail
if not exist Vtb_woz_transport_mb.exe goto :link_fail

rem ---- run (fresh PE: run immediately inside the AV grace window) ----
cd /d "%ROOT%"
verilog\obj_mb_transport\Vtb_woz_transport_mb.exe
set RUNRC=%ERRORLEVEL%
if "%RUNRC%"=="127" goto :av_killed
if not "%RUNRC%"=="0" goto :run_fail
echo.
echo TRANSPORT_MB: PASS - see OK lines above
exit /b 0

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
