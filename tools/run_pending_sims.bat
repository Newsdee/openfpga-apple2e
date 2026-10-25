@echo off
rem Pending Phase-B simulation evidence: RAM zero-init sim matrix +
rem pocket_boot smoke + PDL probe. Run from any shell (double-click ok);
rem no MSYS2 knowledge needed - it calls the MSYS2 bash internally.
rem All build+run steps are chained inside to ride the AV grace window.
rem Exit 0 iff all green.
setlocal
cd /d E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket

rem MSYS directories on PATH BEFORE calling bash: a bash.exe spawned from
rem cmd inherits only the Windows PATH, so MSYS tools like dirname are
rem otherwise not found (the scripts set their own toolchain PATH after
rem their first line, which is too late for their cd "$(dirname "$0")").
set PATH=C:\msys64\usr\bin;C:\msys64\ucrt64\bin;C:\msys64\mingw64\bin;%PATH%

rem Locate the MSYS2 bash: ucrt64/mingw64 runtimes may not ship one -
rem the MSYS-runtime bash (usr\bin) always works for these scripts.
set BASH=C:\msys64\ucrt64\bin\bash.exe
if not exist "%BASH%" set BASH=C:\msys64\mingw64\bin\bash.exe
if not exist "%BASH%" set BASH=C:\msys64\usr\bin\bash.exe
if not exist "%BASH%" (
  echo FATAL: no MSYS2 bash found under C:\msys64 - install MSYS2
  exit /b 2
)

echo.
echo === 1 of 2: RAM zero-init sim matrix ===
"%BASH%" tools/ram_repro_file/run_tb.sh
if errorlevel 1 goto :matrix_bad

echo.
echo === 2 of 2: pocket_boot smoke + PDL probe ===
"%BASH%" verilog/pocket_boot/build.sh clean >nul
"%BASH%" verilog/pocket_boot/build.sh
if errorlevel 1 goto :smoke_build_bad
pushd verilog\pocket_boot
obj_dir\Vtb_pocket_boot.exe --smoke --budget-ms 5000 +PDLPROBE=1
set RC=%errorlevel%
popd
if not "%RC%"=="0" goto :smoke_run_bad

echo.
echo ALL PENDING SIMS GREEN
exit /b 0

:matrix_bad
echo MATRIX FAILED - see output above
exit /b 1
:smoke_build_bad
echo SMOKE BUILD FAILED
exit /b 1
:smoke_run_bad
echo SMOKE RUN FAILED rc=%RC%
if "%RC%"=="127" echo rc=127 means the host AV is killing freshly linked exes - just retry later
exit /b 1
