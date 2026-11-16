@echo off
rem Sborshchik logov MeruDevTools dlya Xiaomi Mi 12 Lite (taoyao), versiya 0.20
rem SPDX-License-Identifier: LicenseRef-MeruDevTools
rem Copyright (c) 2026 Meddax (meru_ii) and the MeruDevTools team. License: LICENSE.txt
rem Windows launcher: all the work is done by run-check.ps1 next to this file
rem (Windows PowerShell 5.1). This file must stay pure ASCII with CRLF line ends.
rem   run-check.bat                 menu
rem   run-check.bat MODE            prep, hotspot, mic, deep, deep hotspot,
rem                                 charge MINUTES, charge-pull, help
rem No cd and no blocks in parentheses: the folder may hold spaces, brackets,
rem ampersands, percent and exclamation signs and Cyrillic letters.
setlocal EnableExtensions DisableDelayedExpansion
set "HERE=%~dp0"
if not exist "%HERE%run-check.ps1" goto missing
if not exist "%HERE%taoyao-check.sh" goto missing
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"
"%PSEXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%HERE%run-check.ps1" %*
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" exit /b 0
if "%RC%"=="10" exit /b 10
if "%RC%"=="11" exit /b 11
echo.
echo Oshibka: ne udalos' zapustit' PowerShell (kod %RC%).
echo Nuzhen Windows PowerShell 5.1 - on vstroen v Windows 10 i 11.
echo Na rabochem kompyutere zapusk skriptov mozhet zapreshchat' administrator.
pause
exit /b 1
:missing
echo.
echo Ryadom s run-check.bat net fajlov run-check.ps1 i taoyao-check.sh.
echo Raspakujte VES' ZIP-arkhiv v obychnuyu papku (pravoj knopkoj - Izvlech' vse)
echo i zapustite run-check.bat iz raspakovannoj papki.
pause
exit /b 1
