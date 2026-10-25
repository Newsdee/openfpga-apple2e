@echo off
rem ============================================================
rem  phase_a_run.bat - Phase A evidence for the RAM zero-init
rem  experiment (TASK_RAM_FILE_INITIALIZATION_2026-10-25), in one run:
rem
rem    [1/4] sim behavior matrix   (MSYS bash: preflight + 7-build matrix;
rem           needs the host AV to allow freshly linked C++ PEs - if the
rem           AV block is active the step reports 127s and the bat
rem           continues; rerun with "sim" when the block lifts)
rem    [2/4] A&S plain fresh control   (~15 s)
rem    [3/4] A&S none probe            (~15 s)
rem    [4/4] A&S file candidate        (the measurement: ~15 s to ~20 min)
rem
rem  Usage:  phase_a_run.bat [sim|q]
rem    (no arg)  everything;  sim = sim matrix only;  q = A&S steps only
rem
rem  Safety: A&S steps are SKIPPED (not queued) if any other Quartus
rem  process is running - one Quartus at a time. Rerun when free.
rem  Each probe has its own directory/database/reports.
rem
rem  Logs:   tools\ram_repro_file\logs\
rem ============================================================
setlocal
set REPO=E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket
set PROBE=%REPO%\tools\ram_repro_file
set BASH=C:\msys64\usr\bin\bash.exe
set QM=C:\intelFPGA_lite\17.0\quartus\bin64\quartus_map.exe
set PY=C:\msys64\ucrt64\bin\python.exe
set IMG=%REPO%\src\fpga\rtl\roms\ram_zero_64k.hex
set LOGDIR=%PROBE%\logs
if not exist "%LOGDIR%" mkdir "%LOGDIR%"
set MODE=%~1
if "%MODE%"=="" set MODE=all
echo === Phase A run: %MODE%  (%date% %time%) ===

if /i "%MODE%"=="q" goto sim_done

echo.
echo [1/4] sim behavior matrix, bash run_tb.sh ...
"%BASH%" "%PROBE%/run_tb.sh" > "%LOGDIR%\sim_matrix.log" 2>&1
set SIMRC=%ERRORLEVEL%
findstr /c:"TB-MATRIX PASS" /c:"TB-MATRIX FAIL" "%LOGDIR%\sim_matrix.log"
echo sim-matrix rc=%SIMRC%   note: 127-class run failures mean the host AV block on fresh C++ PEs is active; rerun phase_a_run.bat sim when it lifts
:sim_done

set QBUSY=0
tasklist /fi "imagename eq quartus.exe" /fo csv /nh 2>nul | findstr /i "quartus" >nul && set QBUSY=1
tasklist /fi "imagename eq quartus_map.exe" /fo csv /nh 2>nul | findstr /i "quartus" >nul && set QBUSY=1
if /i "%MODE%"=="sim" goto done
if "%QBUSY%"=="1" goto busy

echo.
echo [preflight] canonical zero image:
"%PY%" "%PROBE%\validate_ram_image.py" "%IMG%" --zeros
if errorlevel 1 goto preflight_fail

echo.
echo [2/4] A&S plain fresh control ...
call :map_step "plain fresh control" "%REPO%\tools\ram_repro_plain_fresh" ram_repro_plain_fresh
echo.
echo [3/4] A&S none probe ...
call :map_step "none probe, no initialization" "%REPO%\tools\ram_repro_none" ram_repro_none
echo.
echo [4/4] A&S file candidate ...
call :map_step "file candidate, $readmemh zero image" "%REPO%\tools\ram_repro_file" ram_repro_file

goto done
:busy
echo.
echo A^&S steps SKIPPED: another Quartus process is running. Rerun later:  phase_a_run.bat q
goto done
:preflight_fail
echo PREFLIGHT FAIL - A^&S steps not launched. Fix the image, rerun.
goto done

:map_step
set STEP=%~1
set PDIR=%~2
set REV=%~3
cd /d "%PDIR%"
if exist "%REV%.map.rpt" del "%REV%.map.rpt" "%REV%.map.summary" 2>nul
echo "A&S step %STEP% start %date% %time%" >> "%LOGDIR%\phase_a_latest.log"
for %%f in (*.v *.qsf *.qpf) do certutil -hashfile "%%f" SHA256 >> "%LOGDIR%\phase_a_latest.log"
echo "image sha:" >> "%LOGDIR%\phase_a_latest.log"
"%PY%" "%PROBE%\validate_ram_image.py" "%IMG%" --zeros >> "%LOGDIR%\phase_a_latest.log" 2>&1
"%QM%" %REV% --read_settings_files=on --write_settings_files=off > "%LOGDIR%\as_%REV%.log" 2>&1
set MRC=%ERRORLEVEL%
echo "A&S step %STEP% rc=%MRC% end %date% %time%" >> "%LOGDIR%\phase_a_latest.log"
if exist "%REV%.map.summary" findstr /c:"Analysis & Synthesis Status" /c:"Total registers" "%REV%.map.summary" >> "%LOGDIR%\phase_a_latest.log"
if exist "%REV%.map.rpt" findstr /c:"Info: Elapsed time" /c:"Info: Total CPU time" /c:"Total RAM bits" "%REV%.map.rpt" >> "%LOGDIR%\phase_a_latest.log"
echo   rc=%MRC%
if exist "%REV%.map.summary" findstr /c:"Analysis & Synthesis Status" /c:"Total registers" "%REV%.map.summary"
if exist "%REV%.map.rpt" findstr /c:"Info: Elapsed time" /c:"Info: Total CPU time" /c:"Total RAM bits" "%REV%.map.rpt"
exit /b 0

:done
echo.
echo === Phase A done. Log summary: %LOGDIR%\phase_a_latest.log ===
if exist "%LOGDIR%\phase_a_latest.log" type "%LOGDIR%\phase_a_latest.log"
echo Logs kept in %LOGDIR%
endlocal
