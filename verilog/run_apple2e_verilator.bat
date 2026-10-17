@echo off
rem run the Apple IIe Pocket core Verilator smoke harness
setlocal
set SCRIPT_DIR=%~dp0
set UCRT64_BIN=C:\msys64\ucrt64\bin
set SIM=%SCRIPT_DIR%obj_dir_apple2e\Vtb_apple2e_smoke.exe
if not exist "%SIM%" (
    echo Error: %SIM% not found. Run build_apple2e_verilator.bat first.
    exit /b 1
)
set "PATH=%UCRT64_BIN%;%PATH%"
pushd "%SCRIPT_DIR%"
"%SIM%" %*
set RESULT=%ERRORLEVEL%
popd
exit /b %RESULT%
