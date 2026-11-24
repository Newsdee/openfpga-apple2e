@echo off
rem run_control.bat - build + run tb_woz_mb_control (WOZ multi-block port, step 1)
rem
rem Usage: run_control.bat [PORT]   (PORT=0 default: 0.4.4 controller baseline;
rem                                PORT=1: ported multi-block controller)
rem
rem Usage: run_control.bat [PORT]   (PORT=0 default: 0.4.4 controller baseline;
rem                                PORT=1: ported multi-block controller)
rem
rem PASS marker: "TB WOB MB CONTROL: ALL PASS (PORT=N)"
rem The METRIC lines are the step-1 control numbers:
rem   cyc = machine cycles (69.844 ns each), ack = host round trips,
rem   fetch = SDRAM window fills, ready_wait = cycles awaiting sector_ready.
rem rc=127 with zero output = host AV killed the fresh PE; re-run this .bat
rem (it always relinks, which buys a new AV grace window).

if "%1"=="" set PORT=0
if "%1"=="1" set PORT=1
if "%1"=="2" set PORT=2
if not defined PORT set PORT=0
if not "%PORT%"=="0" if not "%PORT%"=="1" if not "%PORT%"=="2" (
  echo usage: run_control.bat 0, 1 or 2
  exit /b 2
)

set PATH=C:\msys64\tmp\makeshim;C:\msys64\ucrt64\bin;C:\msys64\usr\bin;%PATH%
set TMP=C:\msys64\tmp
set TEMP=C:\msys64\tmp
set TMPDIR=C:\msys64\tmp
set VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
set SHELL=C:\msys64\usr\bin\sh

set ROOT=E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket-wozmb
set OBJ=%ROOT%\verilog\obj_mb_control_%PORT%

if not exist "%TMP%\makeshim" mkdir "%TMP%\makeshim"
copy /Y C:\msys64\ucrt64\bin\mingw32-make.exe %TMP%\makeshim\make.exe >nul 2>&1

rem ---- image (deterministic byte oracle) ----
cd /d "%ROOT%"
if not exist verilog\woz_mb\mb_image2.hex (
  C:\msys64\ucrt64\bin\python.exe verilog\woz_mb\gen_mb_image2.py verilog\woz_mb\mb_image2.hex
  if errorlevel 1 goto :img_fail
)

rem ---- verilate ----
set VDEF=
if "%PORT%"=="1" set VDEF=-DPORT_NEW
if "%PORT%"=="2" set VDEF=-DPORT_NEW -DTRANSPORT_MB
verilator_bin --binary --timing -j 4 --top tb_woz_mb_control %VDEF% ^
  -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch ^
  --Mdir "%OBJ%" ^
  src/fpga/core/woz/woz_floppy_controller.sv ^
  src/fpga/core/woz/woz_bram.sv ^
  src/fpga/core/apple2e/sdram_woz_transport.v ^
  src/fpga/core/apple2e/sdram_woz_transport_mb.v ^
  src/fpga/core/apple2e/sdram_sector_fetch.v ^
  src/fpga/core/apple2e/sdram_word_owner.v ^
  src/fpga/core/apple2e/io_sdram_pocket.v ^
  src/fpga/apf/common.v ^
  verilog/tb/tb_dram_model.sv ^
  verilog/woz_mb/tb_woz_mb_control.sv > "%OBJ%.log" 2>&1
if errorlevel 1 goto :verilator_fail
findstr /C:"%%Error" "%OBJ%.log" >nul && goto :verilator_fail

rem ---- link ----
cd /d "%OBJ%"
mingw32-make -f Vtb_woz_mb_control.mk Vtb_woz_mb_control >> "%OBJ%.log" 2>&1
if errorlevel 1 goto :link_fail
if not exist Vtb_woz_mb_control.exe goto :link_fail

rem ---- run (fresh PE: run immediately inside the AV grace window) ----
cd /d "%ROOT%"
verilog\obj_mb_control_%PORT%\Vtb_woz_mb_control.exe
set RUNRC=%ERRORLEVEL%
if "%RUNRC%"=="127" goto :av_killed
if not "%RUNRC%"=="0" goto :run_fail
echo.
echo CONTROL: PASS PORT=%PORT% - see METRIC lines above
exit /b 0

:img_fail
echo ERROR: image generation failed
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
