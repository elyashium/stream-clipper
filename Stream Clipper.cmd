@echo off
rem Double-click to open the Stream Clipper window.
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0stack\gui.ps1"
