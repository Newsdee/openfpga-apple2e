@echo off
rem ---------------------------------------------------------------------------
rem repackage.bat -- turn a freshly-compiled .rbf into the Pocket bitstream
rem and stage it in the core dir. Run AFTER a successful:
rem     cd /d %ROOT%\src\fpga
rem     quartus_sh --flow compile apf_stream_video
rem It: 1) re-reverses the .rbf to .rbf_r, 2) stages it into the core dir,
rem      3) prints the SHA-256 so a stale card bitstream is detectable.
rem Then copy the whole Newsdee.Apple2eStreamVideo dir to the Pocket SD card.
rem ---------------------------------------------------------------------------
setlocal
set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"

set "RBF=%ROOT%\src\fpga\output_files_apple2e\apf_stream_video.rbf"
set "DEST=%ROOT%\sd_root\Cores\Newsdee.Apple2eStreamVideo\bitstream.rbf_r"
set "PY=C:\msys64\ucrt64\bin\python.exe"
set "SCRIPT=%ROOT%\tools\rbf2rbf_r.py"

if not exist "%RBF%" goto nobuild
if not exist "%PY%" goto nopy

echo === converting %RBF% ===
"%PY%" "%SCRIPT%" "%RBF%" "%DEST%"
if errorlevel 1 goto fail

echo.
echo Staged: %DEST%
echo Core dir: %ROOT%\sd_root\Cores\Newsdee.Apple2eStreamVideo
echo Copy that directory to the Pocket SD card under Cores\, then reboot.
echo.
echo SHA-256 of the new bitstream.rbf_r:
"%PY%" -c "import hashlib;print(hashlib.sha256(open(r'%DEST%','rb').read()).hexdigest())"
goto end

:nobuild
echo ERROR: %RBF% not found. Did the compile succeed?
goto end
:nopy
echo ERROR: MSYS python not found at %PY%
goto end
:fail
echo ERROR: rbf2rbf_r conversion failed
endlocal
exit /b 1
:end
endlocal
exit /b 0
