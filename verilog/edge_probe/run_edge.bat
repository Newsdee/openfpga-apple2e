@echo off
rem run_edge.bat - build + run tb_video_edge (PLAN_VIDEO_40COL_ENCODER_EDGE)
rem
rem Usage: run_edge.bat [MODE] [PRESET] [CAPLINE]
rem   MODE    = gr | t40 | t80 | hgr   (default gr)
rem   PRESET  = colour preset word for bridge $01F00004 (default 0)
rem   CAPLINE = machine scanline to capture, 0-based after VBL fall
rem             (defaults: gr=67, t40=83, t80=83, hgr=80)
rem
rem PASS marker: "TB VIDEO EDGE: ALL PASS"
rem Outputs (in this directory): edge_<mode>_p<preset>.csv / .ppm
rem rc=127 with zero output = host AV killed the fresh PE; re-run this .bat
rem (it always relinks, which buys a new AV grace window).
rem
rem Expected marker windows per mode (DE samples, cols*14; derived from
rem fixture_gen.py layout, NOT from a capture):
rem   gr/t40: col0=0..13, col19=266..279, col20=280..293, col39=546..559
rem   t80 (aux display cols 0,38,78 + main 79; 7 samples/col): 0..6, 266..272,
rem     546..552, 553..559
rem   hgr: HGR pixels are 2 DE samples wide: bytes 0-1 -> 0..27,
rem     bytes 26-27 -> 364..391, bytes 38-39 -> 532..559

setlocal
if "%1"=="" (set MODE=gr) else (set MODE=%1)
if "%2"=="" (set PRESET=0) else (set PRESET=%2)

set CAPLINE=%3
if not "%CAPLINE%"=="" goto :havecap
if "%MODE%"=="gr"  set CAPLINE=67
if "%MODE%"=="t40" set CAPLINE=83
if "%MODE%"=="t80" set CAPLINE=83
if "%MODE%"=="hgr" set CAPLINE=80
if "%MODE%"=="dhgr" set CAPLINE=80
:havecap

set MEXP=0,13;266,279;280,293;546,559
if "%MODE%"=="hgr" set MEXP=0,27;364,391;532,559
if "%MODE%"=="t80" set MEXP=0,6;266,272;546,552;553,559
rem dhgr: no marker scoreboard (different pixel grid + line map); the
rem left-edge timeline + DE geometry are the measurement here.
if "%MODE%"=="dhgr" set MEXP=

set PATH=C:\msys64\tmp\makeshim;C:\msys64\ucrt64\bin;C:\msys64\usr\bin;%PATH%
set TMP=C:\msys64\tmp
set TEMP=C:\msys64\tmp
set TMPDIR=C:\msys64\tmp
set VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
set SHELL=C:\msys64\usr\bin\sh

set ROOT=E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket-video
set HERE=%ROOT%\verilog\edge_probe
set VERILOG=%ROOT%\verilog
set OBJ=%HERE%\obj_dir

if not exist "%TMP%\makeshim" mkdir "%TMP%\makeshim"
copy /Y C:\msys64\ucrt64\bin\mingw32-make.exe %TMP%\makeshim\make.exe >nul 2>&1

rem ---- stage ROMs (CWD-relative $readmemh paths; CWD = edge_probe\) ----
cd /d "%HERE%"
if not exist rtl\roms mkdir rtl\roms
copy /Y "%ROOT%\src\fpga\rtl\roms\apple2e.hex" rtl\roms\ >nul
if errorlevel 1 goto :stage_fail
copy /Y "%ROOT%\src\fpga\rtl\roms\video2.hex" rtl\roms\ >nul
if errorlevel 1 goto :stage_fail
copy /Y "%ROOT%\src\fpga\rtl\roms\ram_zero_64k.hex" rtl\roms\ >nul
if errorlevel 1 goto :stage_fail
copy /Y "%ROOT%\src\fpga\rtl\roms\hddrom.hex" rtl\roms\ >nul
if errorlevel 1 goto :stage_fail

rem ---- APF template timescale patches (ps -> ns, see pocket_boot/build.sh) ----
perl -pe "s/`timescale\s*1\s*ps\s*\/\s*1\s*ps/`timescale 1ns\/1ps/" "%ROOT%\src\fpga\core\mf_pllbase.v" > mf_pllbase_sim.v
findstr /C:"timescale 1ns/1ps" mf_pllbase_sim.v >nul
if errorlevel 1 goto :stage_fail
perl -pe "s/`timescale\s*1\s*ps\s*\/\s*1\s*ps/`timescale 1ns\/1ps/" "%ROOT%\src\fpga\apf\mf_datatable.v" > mf_datatable_sim.v
findstr /C:"timescale 1ns/1ps" mf_datatable_sim.v >nul
if errorlevel 1 goto :stage_fail

rem ---- fixture ----
if not exist fixture_%MODE%.hex (
  C:\msys64\ucrt64\bin\python.exe fixture_gen.py
  if errorlevel 1 goto :stage_fail
)

set CSV=edge_%MODE%_p%PRESET%.csv
set PPM=edge_%MODE%_p%PRESET%.ppm

rem ---- verilate + link (always fresh: del exe first for the AV grace) ----
if exist "%OBJ%\Vtb_video_edge.exe" del /q "%OBJ%\Vtb_video_edge.exe"
verilator_bin --binary --timing -j 4 --top tb_video_edge ^
  --Mdir "%OBJ%" ^
  -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch ^
  -Wno-DECLFILENAME ^
  -DJOY_TO_KEY=1 ^
  tb_video_edge.sv ^
  "%VERILOG%\tb\tb_dram_model.sv" ^
  "%ROOT%\src\fpga\core\apple2e\apf_stream_video_top.v" ^
  "%ROOT%\src\fpga\core\apple2e\apf_stream_video.v" ^
  "%ROOT%\src\fpga\core\apple2e\apple2e_osk.v" ^
  "%ROOT%\src\fpga\core\apple2e\joystick_input.sv" ^
  "%ROOT%\src\fpga\core\apple2e\pdl_timer.v" ^
  "%ROOT%\src\fpga\core\apple2e\apf_stream_proto_pll.v" ^
  "%ROOT%\src\fpga\core\apple2e\apple2e_sdram_pll.v" ^
  "%ROOT%\src\fpga\core\apple2e\sdram_storage.v" ^
  "%ROOT%\src\fpga\core\apple2e\sdram_word_owner.v" ^
  "%ROOT%\src\fpga\core\apple2e\sdram_sector_fetch.v" ^
  "%ROOT%\src\fpga\core\apple2e\sdram_woz_transport.v" ^
  "%ROOT%\src\fpga\core\apple2e\woz_mount_ctl.v" ^
  "%ROOT%\src\fpga\core\apple2e\slot_fifo.v" ^
  "%ROOT%\src\fpga\core\apple2e\disk_store.v" ^
  "%ROOT%\src\fpga\core\apple2e\disk_verifier.v" ^
  "%ROOT%\src\fpga\core\apple2e\reboot_ctl.v" ^
  "%ROOT%\src\fpga\core\apple2e\ram_sweep_ctl.v" ^
  "%ROOT%\src\fpga\core\apple2e\io_sdram_pocket.v" ^
  "%ROOT%\src\fpga\core\apple2e\sdram_status_overlay.v" ^
  "%ROOT%\src\fpga\core\apple2e\speaker_i2s.v" ^
  "%ROOT%\src\fpga\core\apple2e\apple2e_ram_bank.v" ^
  "%ROOT%\src\fpga\core\apple2e\savestate_bridge.v" ^
  "%ROOT%\src\fpga\core\apple2e\savestate_slot.v" ^
  "%ROOT%\src\fpga\core\apple2e\savestate_manager.sv" ^
  "%ROOT%\src\fpga\core\sound\floppy_sound.sv" ^
  "%ROOT%\src\fpga\ip\debug_key.v" ^
  "%ROOT%\src\fpga\core\mockingboard\mockingboard.v" ^
  "%ROOT%\src\fpga\core\mockingboard\YM2149.sv" ^
  "%ROOT%\src\fpga\core\mockingboard\via6522.v" ^
  "%ROOT%\src\fpga\core\woz\disk_ii_rom.v" ^
  "%ROOT%\src\fpga\core\hdd.v" ^
  "%ROOT%\src\fpga\core\hdd_rom.v" ^
  "%ROOT%\src\fpga\core\hdv_bridge.sv" ^
  "%ROOT%\src\fpga\core\hid_to_ps2.sv" ^
  "%ROOT%\src\fpga\core\woz\disk_ii_woz.sv" ^
  "%ROOT%\src\fpga\core\woz\flux_drive.v" ^
  "%ROOT%\src\fpga\core\woz\woz_bram.sv" ^
  "%ROOT%\src\fpga\core\woz\woz_cell525.sv" ^
  "%ROOT%\src\fpga\core\woz\woz_floppy_controller.sv" ^
  "%ROOT%\src\fpga\core\core_bridge_cmd.v" ^
  mf_pllbase_sim.v ^
  "%ROOT%\src\fpga\core\mf_pllbase\mf_pllbase_0002.v" ^
  mf_datatable_sim.v ^
  "%ROOT%\src\fpga\apf\common.v" ^
  "%ROOT%\machine\apple2.v" ^
  "%ROOT%\machine\apple2_font_rom.v" ^
  "%ROOT%\machine\ramcard.v" ^
  "%ROOT%\machine\rom.v" ^
  "%ROOT%\machine\timing_generator.v" ^
  "%ROOT%\machine\keyboard.v" ^
  "%ROOT%\machine\video_generator.v" ^
  "%ROOT%\machine\cpu\nmos6502\cpu_65c02.sv" ^
  "%ROOT%\machine\cpu\nmos6502\cpu_alu.sv" ^
  "%ROOT%\machine\cpu\wdc65c02\cpu_65c02.sv" ^
  "%ROOT%\machine\cpu\wdc65c02\cpu_alu.sv" ^
  "%ROOT%\machine\osk\virtual_keyboard_controller.sv" ^
  "%ROOT%\machine\osk\virtual_keyboard_overlay.sv" ^
  "%ROOT%\machine\osk\joy_to_key.v" ^
  "%ROOT%\machine\video\video_pipeline_q17.sv" ^
  "%ROOT%\machine\video\apple_composite_q17.sv" ^
  "%ROOT%\machine\video\composite_decoder_q17.sv" ^
  "%ROOT%\machine\video\vga_controller.v" ^
  "%VERILOG%\stubs\altera_pll_sim.v" ^
  "%VERILOG%\stubs\altsyncram_sim.v" ^
  > build.log 2>&1
if errorlevel 1 goto :verilator_fail
findstr /C:"%%Error" build.log >nul && goto :verilator_fail
if not exist "%OBJ%\Vtb_video_edge.exe" goto :verilator_fail

rem ---- run (fresh PE: run immediately inside the AV grace window) ----
"%OBJ%\Vtb_video_edge.exe" +EDGEPROBE +FIX=fixture_%MODE%.hex +PRESET=%PRESET% +CAPLINE=%CAPLINE% +CSV=%CSV% +PPM=%PPM% +MEXP="%MEXP%" %4
set RUNRC=%ERRORLEVEL%
if "%RUNRC%"=="127" goto :av_killed
if not "%RUNRC%"=="0" goto :run_fail
echo.
echo EDGE: PASS mode=%MODE% preset=%PRESET% line=%CAPLINE% - CSV=%CSV% PPM=%PPM%
exit /b 0

:stage_fail
echo EDGE: FAIL - staging error (ROMs / timescale patch / fixture)
exit /b 1
:verilator_fail
echo EDGE: FAIL - verilator build; see build.log
exit /b 1
:av_killed
echo EDGE: AV killed the fresh PE (rc=127). Re-run this .bat later.
exit /b 127
:run_fail
echo EDGE: FAIL - simulation reported failures (rc=%RUNRC%)
exit /b 1
