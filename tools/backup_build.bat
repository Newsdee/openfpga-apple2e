@echo off
rem ---------------------------------------------------------------------------
rem backup_build.bat -- archive the current build for backtracking.
rem
rem   tools\backup_build.bat <tag>
rem     e.g. tools\backup_build.bat 2026-10-25_1524_bisect_yflip_ovl
rem
rem Copies (before the NEXT compile overwrites output_files_apple2e\):
rem   - the fresh .rbf
rem   - the staged bitstream.rbf_r + core.json + interact.json (manifest state
rem     matters: host behavior depends on it, not just the bitstream)
rem and prints both SHA-256s for the build record.
rem Hand-write builds\<tag>\NOTE.md after hardware results are known
rem (identity, resources, timing, disk/joy test outcomes).
rem ---------------------------------------------------------------------------
setlocal
set "TOOLDIR=%~dp0"
set "ROOT=%TOOLDIR:~0,-1%"
set "ROOT=%ROOT%\.."

if "%~1"=="" (
    echo usage: backup_build.bat ^<tag^>
    exit /b 1
)
set "TAG=%~1"
set "PY=C:\msys64\ucrt64\bin\python.exe"

set "OUT=%ROOT%\builds\%TAG%"
if exist "%OUT%" (
    echo ERROR: %OUT% already exists - pick a new tag
    goto end
)
mkdir "%OUT%"

copy /Y "%ROOT%\src\fpga\output_files_apple2e\apf_stream_video.rbf" "%OUT%\" >nul || goto fail
for %%f in (bitstream.rbf_r core.json interact.json) do (
    if not exist "%ROOT%\sd_root\Cores\Newsdee.Apple2eStreamVideo\%%f" goto missing
    copy /Y "%ROOT%\sd_root\Cores\Newsdee.Apple2eStreamVideo\%%f" "%OUT%\" >nul
)

echo === archived build %TAG% -> %OUT% ===
"%PY%" -c "import hashlib,os;p=r'%OUT%\apf_stream_video.rbf';print('rbf     sha256', hashlib.sha256(open(p,'rb').read()).hexdigest(), os.path.getsize(p))"
"%PY%" -c "import hashlib,os;p=r'%OUT%\bitstream.rbf_r';print('rbf_r   sha256', hashlib.sha256(open(p,'rb').read()).hexdigest(), os.path.getsize(p))"
echo NOTE.md: write the identity/resources/timing/HW-results record.
goto end

:missing
echo ERROR: staged manifest file missing in sd_root core dir
goto fail
:fail
rmdir /S /Q "%OUT%" 2>nul
echo ERROR: backup failed - nothing archived
exit /b 1
:end
endlocal
exit /b 0
