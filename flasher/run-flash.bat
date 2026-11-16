@echo off
rem Flesher yadra MeruDevTools dlya Xiaomi Mi 12 Lite (taoyao), versiya 1.2
rem SPDX-License-Identifier: LicenseRef-MeruDevTools
rem Copyright (c) 2026 Meddax (meru_ii) and the MeruDevTools team. License: LICENSE-flash.txt
rem Windows launcher: all the work is done by run-flash.ps1 next to this file
rem (Windows PowerShell 5.1). This file must stay pure ASCII with CRLF line ends.
rem   run-flash.bat                       menu
rem   run-flash.bat install [zip]         and the other words of: run-flash.bat help
rem   a kernel zip dropped on this file   install that zip
rem No cd and no blocks in parentheses: the folder may hold spaces, brackets,
rem ampersands, percent and exclamation signs and Cyrillic letters.
rem Started from Explorer (double click, drop) or from PowerShell, cmd's own
rem command line holds this file's name: run-flash.ps1 then reads the
rem arguments from RUNFLASH_CMDLINE (taken with delayed expansion, where "&"
rem stays plain text) instead of the arguments (cut at an unquoted "&" of a
rem dropped path), and waits for a key at the end so the window stays open.
rem RUNFLASH_BATF (this file's full path) tells it where its own name ends.
rem Exit codes of run-flash.ps1 are passed on: 0 done, 10 stopped (nothing
rem written), 11 cancelled, 12 original images put back, 13 attention.
setlocal EnableExtensions DisableDelayedExpansion
set "HERE=%~dp0"
if not exist "%HERE%run-flash.ps1" goto missing
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" set "PSEXE=powershell.exe"
set "RUNFLASH_BAT=%~nx0"
set "RUNFLASH_BATF=%~f0"
set "RUNFLASH_CMDLINE="
set "RF_OWN="
setlocal EnableDelayedExpansion
set "RUNFLASH_CMDLINE=!cmdcmdline!"
set "RF_X=!RUNFLASH_CMDLINE:%~nx0=!"
if not "!RF_X!"=="!RUNFLASH_CMDLINE!" set "RF_OWN=1"
setlocal DisableDelayedExpansion
if defined RF_OWN goto own
"%PSEXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%HERE%run-flash.ps1" %*
goto after
:own
"%PSEXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%HERE%run-flash.ps1" --cmdline
:after
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" exit /b 0
if "%RC%"=="10" exit /b 10
if "%RC%"=="11" exit /b 11
if "%RC%"=="12" exit /b 12
if "%RC%"=="13" exit /b 13
echo.
echo Oshibka: ne udalos' zapustit' PowerShell (kod %RC%).
echo Nuzhen Windows PowerShell 5.1 - on vstroen v Windows 10 i 11.
echo Na rabochem kompyutere zapusk skriptov mozhet zapreshchat' administrator.
pause
exit /b 1
:missing
echo.
echo Ryadom s run-flash.bat net fajla run-flash.ps1.
echo Raspakujte VES' ZIP-arkhiv v obychnuyu papku (pravoj knopkoj - Izvlech' vse)
echo i zapustite run-flash.bat iz raspakovannoj papki.
pause
exit /b 1
