@echo off
setlocal
rem ============================================================================
rem run_sta_report.bat - TimeQuest SDRAM timing path report.
rem Reads the EXISTING fitted database (no recompile) and writes
rem   src\fpga\sdram_timing_paths.txt
rem then the assistant reads that file to pinpoint the failing block.
rem ============================================================================
cd /d E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket\src\fpga
set "QSH=C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sh.exe"

if not exist "%QSH%" goto noq

echo.
echo Running TimeQuest report from the fitted database - no recompile.
echo This reads the existing db and writes sdram_timing_paths.txt.
echo.
set "QSTA=C:\intelFPGA_lite\17.0\quartus\bin64\quartus_sta.exe"
"%QSTA%" apf_stream_video --report_script=sta_body.tcl
echo.

if exist "sdram_timing_paths.txt" goto done
echo No sdram_timing_paths.txt was written. See the output above.
goto end

:done
echo.
echo WROTE: %CD%\sdram_timing_paths.txt
echo Tell the assistant it is done - it will read the file and pinpoint the failing block.

:end
echo.
pause
exit /b 0

:noq
echo ERROR: quartus_sh.exe not found at:
echo   %QSH%
echo If your Quartus is elsewhere, edit the QSH line near the top of this file.
echo.
pause
exit /b 1
