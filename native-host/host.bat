@echo off
rem Chrome execs this; keep stdout clean - only host.ps1 writes the framed reply.
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0host.ps1"
