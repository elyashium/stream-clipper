@echo off
rem Lets cmd.exe users type "clipper setup" without touching PowerShell's execution policy.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clipper.ps1" %*
