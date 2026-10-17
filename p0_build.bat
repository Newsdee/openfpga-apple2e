@echo off
rem ============================================================
rem P0: build the UNMODIFIED core-template for Analogue Pocket
rem (device 5CEBA4F23C8, Quartus Prime Lite/Standard, Cyclone V)
rem
rem Requires: Quartus on PATH, MSYS2 UCRT64 python at the path below.
rem Flow: compile -> reverse .rbf to .rbf_r -> stage SD layout.
rem ============================================================
setlocal
set REPO=E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket
set PY=C:\msys64\ucrt64\bin\python.exe
cd /d %REPO%\src\fpga

echo === [1/3] Quartus full compile (ap_core) ===
quartus_sh --flow compile ap_core
if errorlevel 1 goto :err

echo === [2/3] Convert raw .rbf -> APF .rbf_r ===
%PY% %REPO%\tools\rbf2rbf_r.py %REPO%\src\fpga\output_files\ap_core.rbf %REPO%\output\bitstream.rbf_r
if errorlevel 1 goto :err

echo === [3/3] Stage SD layout (Cores\Developer.Core Template) ===
set COREDIR=%REPO%\sd_root\Cores\Developer.Core Template
if not exist "%COREDIR%" mkdir "%COREDIR%"
copy /y %REPO%\core.json %REPO%\data.json %REPO%\interact.json %REPO%\video.json %REPO%\input.json %REPO%\variants.json "%COREDIR%" >nul
copy /y %REPO%\output\bitstream.rbf_r "%COREDIR%" >nul
if errorlevel 1 goto :err

echo.
echo DONE. Copy %COREDIR% to the SD card root as "Cores\Developer.Core Template".
echo Check fit report: %REPO%\src\fpga\output_files\ap_core.fit.summary
endlocal
pause

exit /b 0

:err
echo FAILED - see output above.
endlocal
pause

exit /b 1
