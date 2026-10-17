@echo off
rem run_probe_verilator.bat - build if needed, then run the probe.
rem The DUT's $readmemh paths are CWD-relative, so the exe runs with CWD at
rem the Apple-II_MiSTer repo root (which has rtl/roms/*.hex).
rem Extra args are passed through: +cpu=0 (nmos6502) / +cpu=1 (wdc65c02, default).
setlocal
cd /d %~dp0

rem The ucrt64 PE needs its sibling DLLs (libwinpthread-1.dll, libgmp-10.dll, ...)
rem C:\msys64\ucrt64\bin is only implicitly on PATH under an MSYS shell.
set UCRT64_BIN=C:\msys64\ucrt64\bin
set "PATH=%UCRT64_BIN%;%PATH%"

if not exist obj_dir_probe\Vtb_native_probe.exe (
    call build_probe_verilator.bat
    if errorlevel 1 exit /b 1
)

pushd ..\..\Apple-II_MiSTer
..\apple2e-pocket\verilog\obj_dir_probe\Vtb_native_probe.exe %*
set RC=%ERRORLEVEL%
popd
exit /b %RC%
