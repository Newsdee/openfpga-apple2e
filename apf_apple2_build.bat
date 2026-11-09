@echo off
rem ============================================================
rem Apple IIe Pocket core build (device 5CEBA4F23C8, Quartus Prime
rem Lite/Standard, Cyclone V)
rem
rem Compiles the apf_apple2 revision (top entity apf_top_apple2) - the
rem shipping Apple IIe core - and stages the result into
rem sd_root\Cores\Newsdee.Apple2e as bitstream.rbf_r.
rem
rem Requires: Quartus on PATH, MSYS2 UCRT64 python.
rem
rem To compile in the Quartus UI instead, open:
rem   src\fpga\apf_apple2.qsf
rem ============================================================
setlocal

set "REPO=%~dp0"
if "%REPO:~ -1%"=="\" set "REPO=%REPO:~0,-1%"
set "PY=C:\msys64\ucrt64\bin\python.exe"
if not exist "%PY%" goto :missingpy

set "PROTODIR=%REPO%\sd_root\Cores\Newsdee.Apple2e"
set "RBFR_OUT=%REPO%\output\bitstream_apple2.rbf_r"
set "RBFR_PKG=%PROTODIR%\bitstream.rbf_r"
set "RBF_SRC=%REPO%\src\fpga\output_files_apple2e\apf_apple2.rbf"

cd /d "%REPO%\src\fpga"

echo === [1/3] Quartus full compile (apf_apple2) ===
quartus_sh --flow compile apf_apple2
if errorlevel 1 goto :err

if not exist "%RBF_SRC%" goto :errrbf

echo === [2/3] Convert raw .rbf -^> APF .rbf_r ===
if not exist "%REPO%\output" mkdir "%REPO%\output"
"%PY%" "%REPO%\tools\rbf2rbf_r.py" "%RBF_SRC%" "%RBFR_OUT%"
if errorlevel 1 goto :err

echo === [3/3] Stage the bitstream into %PROTODIR% ===
if not exist "%PROTODIR%" mkdir "%PROTODIR%"
copy /y "%RBFR_OUT%" "%RBFR_PKG%" >nul
if errorlevel 1 goto :err
for %%M in (core.json data.json interact.json video.json input.json variants.json audio.json) do (
    if not exist "%PROTODIR%\%%M" goto :errmanifest
    rem Guard: the repo root must NOT hold a second copy of any manifest.
    rem sd_root\Cores\Newsdee.Apple2e is the single source of
    rem truth; root-level copies drifted silently until removed 2026-10-24.
    if exist "%REPO%\%%M" goto :errrootjson
)

echo.
echo DONE. Apple IIe core staged at %PROTODIR%
echo   bitstream.rbf_r = freshly built apf_apple2 (reversed).
echo   Copy "Cores\Newsdee.Apple2e" to the SD card root to test.
echo   Fit report: %REPO%\src\fpga\output_files_apple2e\apf_apple2.fit.summary
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

:errrootjson
echo FAILED: a manifest JSON exists at the repository root (%REPO%)
echo         Manifests live ONLY in sd_root\Cores\Newsdee.Apple2e\ -
echo         delete the root copy, it will drift from the real one. See README.md.
endlocal
pause
exit /b 1

:errmanifest
echo FAILED: a manifest is missing from %PROTODIR%
endlocal
pause
exit /b 1

:err
echo FAILED - see output above.
endlocal
pause
exit /b 1
