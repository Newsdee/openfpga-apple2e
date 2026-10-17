@echo off
rem build the APF Pocket Verilator smoke harness (MSYS2 UCRT64)
setlocal
set MSYS2_BASH=C:\msys64\usr\bin\bash.exe
if not exist "%MSYS2_BASH%" (
    echo Error: MSYS2 Bash not found at %MSYS2_BASH%
    exit /b 1
)
"%MSYS2_BASH%" "%~dp0verilate.sh" %*
exit /b %ERRORLEVEL%
