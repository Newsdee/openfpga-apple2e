@echo off
rem One-shot AV window: stop the McAfee WPS / real-time-protection
rem services, run the pending sims, then ALWAYS restart them.
rem HOW TO RUN: right-click this file - Run as administrator.
rem Exposure: host firewall/HIPS + real-time scan are OFF only for the
rem duration of the sim run (a few minutes). Owner's machine, owner's call.
setlocal
cd /d E:\MiSTer\Apple-II_FPGAdev\apple2e-pocket

rem --- elevation check (High Mandatory Level = S-1-16-12288) ---
whoami /groups | findstr /c:"S-1-16-12288" >nul
if errorlevel 1 (
  echo NOT ELEVATED - right-click this file and choose Run as administrator
  exit /b 2
)

echo Stopping McAfee services: McComponentHostService, mccspsvc, mc-fw-host
sc stop McComponentHostService >nul 2>&1
sc stop mccspsvc >nul 2>&1
sc stop mc-fw-host >nul 2>&1
rem Hold the hourly self-updater so it cannot restart the services mid-run
schtasks /Change /TN McUpdaterModuleTask /DISABLE >nul 2>&1

rem sc stop is async - poll until they are actually down (up to 12 s)
set /a T=0
:waitstop
sc query mc-fw-host | findstr RUNNING >nul
if errorlevel 1 goto allstopped
set /a T+=1
if %T% GEQ 12 goto stillup
timeout /t 1 /nobreak >nul
goto waitstop
:stillup
echo WARNING: second stop attempt ...
sc stop McComponentHostService >nul 2>&1
sc stop mccspsvc >nul 2>&1
sc stop mc-fw-host >nul 2>&1
set /a T=0
:waitstop2
sc query mc-fw-host | findstr RUNNING >nul
if errorlevel 1 goto allstopped
set /a T+=1
if %T% GEQ 12 goto giveup
timeout /t 1 /nobreak >nul
goto waitstop2
:giveup
echo NOTE: mc-fw-host would not stop - a watchdog or kernel component may hold it. Sims may still be blocked.
goto runthem
:allstopped
echo All McAfee services stopped.

echo.
echo Running pending sims ...
:runthem
call tools\run_pending_sims.bat
set SR=%errorlevel%

echo.
echo Restarting McAfee services ...
sc start McComponentHostService >nul 2>&1
sc start mccspsvc >nul 2>&1
sc start mc-fw-host >nul 2>&1
schtasks /Change /TN McUpdaterModuleTask /ENABLE >nul 2>&1
rem poll until back up (up to 12 s)
set /a T=0
:waitstart
sc query mc-fw-host | findstr RUNNING >nul
if not errorlevel 1 goto allup
set /a T+=1
if %T% GEQ 12 goto notup
timeout /t 1 /nobreak >nul
goto waitstart
:notup
echo WARNING: services did not confirm RUNNING within 12 s - check services.msc
sc query mc-fw-host | findstr RUNNING >nul && echo mc-fw-host: RUNNING || echo WARNING mc-fw-host NOT running
sc query mccspsvc | findstr RUNNING >nul && echo mccspsvc: RUNNING || echo WARNING mccspsvc NOT running
sc query McComponentHostService | findstr RUNNING >nul && echo McComponentHostService: RUNNING || echo WARNING McComponentHostService NOT running
goto :final
:allup
echo McAfee services back up.

:final
if "%SR%"=="0" (
  echo SIMS GREEN and McAfee restored
  exit /b 0
)
echo SIMS result rc=%SR% - McAfee restored
exit /b %SR%
