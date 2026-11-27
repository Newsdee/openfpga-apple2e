@echo off
rem run_hdv_snd.bat - build + run the HDV seek-sound voice TB
rem (PLAN_HDV_PROCEDURAL_SEEK_SOUND_2026-11-26 step 1+2)
rem
rem Phase A: renders hdv_seek_render.wav (48k mono, preview onset times,
rem          UNNORMALIZED - true mixer gain)
rem Phase B (+EVENTS): trigger/acceptance checks
rem
rem PASS markers: "TB: rendered N samples" (A) /
rem               "TB HDV SEEK SOUND EVENTS: ALL PASS" (B)
rem rc=127 with zero output = host AV killed the fresh PE; re-run.

setlocal
set PATH=C:\msys64\tmp\makeshim;C:\msys64\ucrt64\bin;C:\msys64\usr\bin;%PATH%
set TMP=C:\msys64\tmp
set TEMP=C:\msys64\tmp
set TMPDIR=C:\msys64\tmp
set VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator
set SHELL=C:\msys64\usr\bin\sh

set ROOT=E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket-hdvsnd
set HERE=%ROOT%\verilog\hdv_snd
set OBJ=%HERE%\obj_dir

if not exist "%TMP%\makeshim" mkdir "%TMP%\makeshim"
copy /Y C:\msys64\ucrt64\bin\mingw32-make.exe %TMP%\makeshim\make.exe >nul 2>&1

cd /d "%HERE%"
if exist "%OBJ%\Vtb_hdv_seek_sound.exe" del /q "%OBJ%\Vtb_hdv_seek_sound.exe"

verilator_bin --binary --timing -j 4 --top tb_hdv_seek_sound ^
  --Mdir "%OBJ%" ^
  -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch ^
  -Wno-DECLFILENAME ^
  tb_hdv_seek_sound.sv ^
  "%ROOT%\src\fpga\core\sound\hdv_seek_sound.sv" ^
  > build.log 2>&1
if errorlevel 1 goto :verilator_fail
findstr /C:"%%Error" build.log >nul && goto :verilator_fail
if not exist "%OBJ%\Vtb_hdv_seek_sound.exe" goto :verilator_fail

rem ---- Phase A: voice render ----
"%OBJ%\Vtb_hdv_seek_sound.exe" +PCM=hdv_seek_render.pcm
set RC_A=%ERRORLEVEL%
if "%RC_A%"=="127" goto :av_killed
if not "%RC_A%"=="0" goto :run_fail
C:\msys64\ucrt64\bin\python.exe pcm2wav.py hdv_seek_render.pcm hdv_seek_render.wav
if errorlevel 1 goto :run_fail
C:\msys64\ucrt64\bin\python.exe pcm2wav.py hdv_seek_render_a.pcm hdv_seek_render_a.wav
if errorlevel 1 goto :run_fail
C:\msys64\ucrt64\bin\python.exe pcm2wav.py hdv_seek_render_b.pcm hdv_seek_render_b.wav
if errorlevel 1 goto :run_fail

rem ---- Phase B: event acceptance ----
"%OBJ%\Vtb_hdv_seek_sound.exe" +EVENTS
set RC_B=%ERRORLEVEL%
if "%RC_B%"=="127" goto :av_killed
if not "%RC_B%"=="0" goto :run_fail

echo.
echo HDV_SND: PASS - hdv_seek_render.wav + events all pass
exit /b 0

:verilator_fail
echo HDV_SND: FAIL - verilator build; see build.log
exit /b 1
:av_killed
echo HDV_SND: AV killed the fresh PE (rc=127). Re-run this .bat later.
exit /b 127
:run_fail
echo HDV_SND: FAIL - simulation reported failures
exit /b 1
