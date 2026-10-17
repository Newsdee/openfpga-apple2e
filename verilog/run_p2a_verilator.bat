@echo off
rem run_p2a_verilator.bat - build if needed, then run the P2a machine+adapter
rem harness. The DUT's $readmemh paths are CWD-relative, so the exe runs with
rem CWD at the Apple-II_MiSTer repo root (which has rtl/roms/*.hex).
setlocal
cd /d %~dp0

rem The ucrt64 PE needs its sibling DLLs (libwinpthread-1.dll, libgmp-10.dll, ...)
rem C:\msys64\ucrt64\bin is only implicitly on PATH under an MSYS shell.
set UCRT64_BIN=C:\msys64\ucrt64\bin
set "PATH=%UCRT64_BIN%;%PATH%"

if not exist obj_dir_p2a\Vtb_apf_video.exe (
    call build_p2a_verilator.bat
    if errorlevel 1 exit /b 1
)

pushd ..\..\Apple-II_MiSTer
..\apple2e-pocket\verilog\obj_dir_p2a\Vtb_apf_video.exe %*
set RC=%ERRORLEVEL%
popd
exit /b %RC%
