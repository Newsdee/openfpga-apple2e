@echo off
setlocal
rem ============================================================================
rem run_kbd_suites.bat - build + run the docked USB HID keyboard TB
rem (tb_pocket_kbd, PLAN_USB_KEYBOARD_2026-11-02 WP4), from bare Windows cmd.
rem
rem Same shape as run_hdv_matrix.bat: a fresh-PE relink + AV probe with retries
rem (the host AV layer can hash-kill freshly linked C++ PEs - exit 127, zero
rem output; a fresh relink buys a new window). The difference: this is a
rem from-scratch Verilator --binary build (the HDV matrix only relinks an
rem existing obj_dir), so the Verilator build step is added up front.
rem
rem Usage:  run_kbd_suites.bat        (double-click, or from any cmd window)
rem Expect: the checks print "ok  : ..." and finally
rem         "=== tb_pocket_kbd: PASS (all checks) ==="   (exit code 0)
rem
rem Requires: the UCRT64 Verilator + g++ + mingw32-make under C:\msys64.
rem           CWD for the RUN is the Apple-II_MiSTer root (the font ROM
rem           $readmemh("rtl/roms/video2.hex") is CWD-relative).
rem ============================================================================
set "HERE=%~dp0"
cd /d "%HERE%"
set "VERILATOR=C:\msys64\ucrt64\bin\verilator_bin.exe"
set "MAKE=C:\msys64\ucrt64\bin\mingw32-make.exe"
set "GPP=C:\msys64\ucrt64\bin\g++.exe"
set "REPO=%HERE%.."
set "MISROOT=%HERE%..\..\Apple-II_MiSTer"
set "OBJ=%HERE%obj_dir_kbd_tb_pocket_kbd"
set "EXE=%OBJ%\Vtb_pocket_kbd.exe"
rem env for the from-scratch Verilator --binary build
set "VERILATOR_ROOT=C:/msys64/ucrt64/share/verilator"
set "TMP=C:/msys64/tmp"
set "TEMP=C:/msys64/tmp"
set "TMPDIR=C:/msys64/tmp"
rem make shim: the Verilator --binary link step calls bare `make`; the ucrt64
rem bin only ships mingw32-make.exe, so expose it as make.exe, first on PATH.
if not exist "C:/msys64/tmp/makeshim" mkdir "C:/msys64/tmp/makeshim"
copy /y "%MAKE%" "C:/msys64/tmp/makeshim/make.exe" >nul
set "PATH=C:/msys64/tmp/makeshim;C:/msys64/ucrt64/bin;C:/msys64/usr/bin;%PATH%"
set "SHELL=C:/msys64/usr/bin/sh"

echo === tb_pocket_kbd (docked USB HID keyboard) ===
echo working dir: %CD%

if not exist "%VERILATOR%" goto noenv
if not exist "%GPP%" goto noenv
if not exist "%MISROOT%\rtl\roms\video2.hex" goto nofont
if not exist "%OBJ%" mkdir "%OBJ%"

echo [build]  (Verilator --binary --timing; CWD = verilog\)
"%VERILATOR%" --binary --timing -j 4 --top tb_pocket_kbd -DJOY_TO_KEY=1 -Wno-fatal -Wno-undriven -Wno-unused -Wno-width -Wno-style -Wno-latch --Mdir "%OBJ%" "%REPO%\src\fpga\core\apple2e\apple2e_osk.v" "%REPO%\src\fpga\core\hid_to_ps2.sv" "%REPO%\machine\osk\virtual_keyboard_controller.sv" "%REPO%\machine\osk\virtual_keyboard_overlay.sv" "%REPO%\machine\keyboard.v" "%REPO%\machine\rom.v" "%REPO%\machine\apple2_font_rom.v" tb\tb_pocket_kbd.sv
if errorlevel 1 goto buildfail

echo [link + run]  (fresh PE each link; AV probe with retries)
set "AVTRY=0"
:runlink
set /a AVTRY+=1
if %AVTRY% GTR 3 goto avfail
echo link + run, attempt %AVTRY% of 3
pushd "%OBJ%"
"%MAKE%" -f Vtb_pocket_kbd.mk Vtb_pocket_kbd
if errorlevel 1 goto buildfail
popd
if not exist "%EXE%" goto buildfail
rem run with CWD at the Apple-II_MiSTer root (font ROM $readmemh is CWD-relative)
pushd "%MISROOT%"
"%EXE%"
set "RC=%ERRORLEVEL%"
popd
if not "%RC%"=="127" goto done
echo AV block active on fresh PE, waiting 90 s
timeout /t 90 /nobreak >nul
goto runlink
:done
echo [done] tb exit code %RC%
goto end

:buildfail
echo BUILD/LINK-FAIL (see the Verilator/make output above)
exit /b 1
:avfail
echo !!! AV block still active after 3 tries - relaunch this bat later.
exit /b 1
:noenv
echo MISSING UCRT64 Verilator/g++ under C:\msys64\ucrt64\bin
exit /b 2
:nofont
echo MISSING Apple-II_MiSTer root (font ROM) at: %MISROOT%
exit /b 2
:end
exit /b %RC%
