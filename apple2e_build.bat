@echo off
rem ============================================================
rem Apple IIe: build the apple2e_core revision for Analogue Pocket
rem (device 5CEBA4F23C8, Quartus Prime Lite/Standard, Cyclone V)
rem
rem Requires: Quartus on PATH, MSYS2 UCRT64 python.
rem Flow:  compile apple2e_core
rem        -> reverse output_files_apple2e\apple2e_core.rbf to .rbf_r
rem        -> stage the freshly-built bitstream into the AUTHORITATIVE
rem           Apple IIe package: sd_root\Cores\Newsdee.Apple2e
rem
rem This is the Apple IIe build. p0_build.bat is the (unmodified)
rem core-TEMPLATE regression path - it must not be used to ship the core.
rem
rem To compile in the Quartus UI instead, open:
rem   src\fpga\apple2e_core.qsf
rem ============================================================
setlocal

rem Derive the repo root from this script's own location (no hardcoded path).
set "REPO=%~dp0"
if "%REPO:~ -1%"=="\" set "REPO=%REPO:~0,-1%"
set "PY=C:\msys64\ucrt64\bin\python.exe"
if not exist "%PY%" goto :missingpy

set "COREDIR=%REPO%\sd_root\Cores\Newsdee.Apple2e"
set "RBFR_OUT=%REPO%\output\bitstream.rbf_r"
set "RBFR_PKG=%COREDIR%\bitstream.rbf_r"
set "RBF_SRC=%REPO%\src\fpga\output_files_apple2e\apple2e_core.rbf"

cd /d "%REPO%\src\fpga"

echo === [1/3] Quartus full compile (apple2e_core) ===
quartus_sh --flow compile apple2e_core
if errorlevel 1 goto :err

if not exist "%RBF_SRC%" goto :errrbf

echo === [2/3] Convert raw .rbf -^> APF .rbf_r ===
if not exist "%REPO%\output" mkdir "%REPO%\output"
"%PY%" "%REPO%\tools\rbf2rbf_r.py" "%RBF_SRC%" "%RBFR_OUT%"
if errorlevel 1 goto :err

echo === [3/3] Stage the bitstream into %COREDIR% ===
if not exist "%COREDIR%" mkdir "%COREDIR%"
copy /y "%RBFR_OUT%" "%RBFR_PKG%" >nul
if errorlevel 1 goto :err
rem Verify every Apple IIe manifest is present (never stage template metadata).
for %%M in (core.json data.json interact.json video.json input.json variants.json audio.json) do (
    if not exist "%COREDIR%\%%M" goto :errmanifest
)

echo.
echo DONE. Apple IIe package staged at %COREDIR%
echo   bitstream.rbf_r = freshly built apple2e_core (reversed).
echo   Copy "Cores\Newsdee.Apple2e" to the SD card root.
echo   Fit report: %REPO%\src\fpga\output_files_apple2e\apple2e_core.fit.summary
endlocal
pause
exit /b 0

:missingpy
echo FAILED: MSYS2 UCRT64 python not found at %PY%
endlocal
pause
exit /b 1

:errrbf
echo FAILED: %RBF_SRC% not found after compile (assembler did not run?)
endlocal
pause
exit /b 1

:errmanifest
echo FAILED: an Apple IIe manifest is missing from %COREDIR%
endlocal
pause
exit /b 1

:err
echo FAILED - see output above.
endlocal
pause
exit /b 1
