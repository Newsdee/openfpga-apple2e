@echo off
rem ============================================================
rem P0: build the UNMODIFIED core-TEMPLATE for Analogue Pocket
rem (device 5CEBA4F23C8, Quartus Prime Lite/Standard, Cyclone V)
rem
rem This is the TEMPLATE regression path only (proves the untouched
rem core-template still builds). It does NOT build or stage the Apple IIe
rem core. To build the Apple IIe core, use apple2e_build.bat.
rem
rem Requires: Quartus on PATH, MSYS2 UCRT64 python.
rem Flow: compile ap_core -> reverse .rbf to .rbf_r -> stage the
rem       template SD layout (Cores\Developer.Core Template).
rem ============================================================
setlocal

rem Derive the repo root from this script's own location (no hardcoded path).
set "REPO=%~dp0"
if "%REPO:~ -1%"=="\" set "REPO=%REPO:~0,-1%"
set "PY=C:\msys64\ucrt64\bin\python.exe"
if not exist "%PY%" goto :missingpy
set "COREDIR=%REPO%\sd_root\Cores\Developer.Core Template"

cd /d "%REPO%\src\fpga"

echo === [1/3] Quartus full compile (ap_core, template) ===
quartus_sh --flow compile ap_core
if errorlevel 1 goto :err
if not exist "%REPO%\src\fpga\output_files\ap_core.rbf" goto :errrbf

echo === [2/3] Convert raw .rbf -^> APF .rbf_r ===
if not exist "%REPO%\output" mkdir "%REPO%\output"
"%PY%" "%REPO%\tools\rbf2rbf_r.py" "%REPO%\src\fpga\output_files\ap_core.rbf" "%REPO%\output\bitstream.rbf_r"
if errorlevel 1 goto :err

echo === [3/3] Stage template SD layout ===
if not exist "%COREDIR%" mkdir "%COREDIR%"
copy /y "%REPO%\core.json" "%REPO%\data.json" "%REPO%\interact.json" "%REPO%\video.json" "%REPO%\input.json" "%REPO%\variants.json" "%COREDIR%" >nul
if errorlevel 1 goto :err
copy /y "%REPO%\output\bitstream.rbf_r" "%COREDIR%" >nul
if errorlevel 1 goto :err

echo.
echo DONE (TEMPLATE). Copy %COREDIR% to the SD card root as "Cores\Developer.Core Template".
echo   (This is the template regression build, NOT the Apple IIe core.)
echo   Fit report: %REPO%\src\fpga\output_files\ap_core.fit.summary
endlocal
pause
exit /b 0

:missingpy
echo FAILED: MSYS2 UCRT64 python not found at %PY%
endlocal
pause
exit /b 1

:errrbf
echo FAILED: ap_core.rbf not found after compile (assembler did not run?)
endlocal
pause
exit /b 1

:err
echo FAILED - see output above.
endlocal
pause
exit /b 1
