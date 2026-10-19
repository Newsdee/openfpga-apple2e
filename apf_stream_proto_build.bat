@echo off
rem ============================================================
rem Phase 1 streaming-prototype build for Analogue Pocket
rem (device 5CEBA4F23C8, Quartus Prime Lite/Standard, Cyclone V)
rem
rem EXPERIMENTAL - see docs/NES_REFERENCE_STREAMING_RECOMMENDATION_2026-10-19.md
rem
rem Compiles the apf_stream_proto revision (top entity apf_top_proto), which
rem streams the native Apple II raster (560x192 @ 14.318 MHz) straight to the
rem APF DDR pad with NO frame buffer. Stages the result into a SEPARATE
rem experimental core package (Newsdee.Apple2eStreamProto) so the working
rem Newsdee.Apple2e package is never touched.
rem
rem Requires: Quartus on PATH, MSYS2 UCRT64 python.
rem
rem To compile in the Quartus UI instead, open:
rem   src\fpga\apf_stream_proto.qsf
rem ============================================================
setlocal

set "REPO=%~dp0"
if "%REPO:~ -1%"=="\" set "REPO=%REPO:~0,-1%"
set "PY=C:\msys64\ucrt64\bin\python.exe"
if not exist "%PY%" goto :missingpy

set "PROTODIR=%REPO%\sd_root\Cores\Newsdee.Apple2eStreamProto"
set "RBFR_OUT=%REPO%\output\bitstream_streamproto.rbf_r"
set "RBFR_PKG=%PROTODIR%\bitstream.rbf_r"
set "RBF_SRC=%REPO%\src\fpga\output_files_apple2e\apf_stream_proto.rbf"

cd /d "%REPO%\src\fpga"

echo === [1/3] Quartus full compile (apf_stream_proto) ===
quartus_sh --flow compile apf_stream_proto
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
)

echo.
echo DONE. Phase 1 streaming-prototype staged at %PROTODIR%
echo   bitstream.rbf_r = freshly built apf_stream_proto (reversed).
echo   Copy "Cores\Newsdee.Apple2eStreamProto" to the SD card root to test.
echo   Fit report: %REPO%\src\fpga\output_files_apple2e\apf_stream_proto.fit.summary
echo   NOTE: this is the EXPERIMENTAL pattern build, not the working core.
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
echo FAILED: a manifest is missing from %PROTODIR%
endlocal
pause
exit /b 1

:err
echo FAILED - see output above.
endlocal
pause
exit /b 1
