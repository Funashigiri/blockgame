@echo off
rem Builds the game into build\blockgame.exe.
rem Extra arguments go straight to the Odin compiler, e.g. "build.bat -debug".
setlocal

set ODIN="%~dp0tools\odin\odin.exe"
if not exist %ODIN% set ODIN=odin

if not exist "%~dp0build" mkdir "%~dp0build"

%ODIN% build "%~dp0src" -out:"%~dp0build\blockgame.exe" -o:speed -subsystem:windows %*
