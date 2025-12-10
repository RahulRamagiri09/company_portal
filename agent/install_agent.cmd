@echo off
mkdir "C:\Program Files\SSAgent" 2>nul
copy agent.ps1 "C:\Program Files\SSAgent\agent.ps1" /Y
powershell -Command "Register-ScheduledTask -Action (New-ScheduledTaskAction -Execute 'PowerShell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\SSAgent\agent.ps1" -ServerBaseUrl "http://10.0.0.49:5050" -ApiKey "CHANGE_ME"') -Trigger (New-ScheduledTaskTrigger -AtStartup) -TaskName 'SSAgent' -RunLevel Highest -User 'SYSTEM' -Force"
schtasks /run /tn SSAgent
echo Agent installed.
