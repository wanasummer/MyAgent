@echo off
rem MyAgent launcher (Windows)
rem Priority: .\bin\sbcl.exe (bundled) > MYAGENT_SBCL > PATH > common install dirs
rem NOTE: '<nul' on chcp is required, otherwise chcp consumes stdin and the CLI exits at once.
chcp 65001 >nul <nul
setlocal

set "SBCL_EXE="

rem 1) bundled runtime inside the project
if exist "%~dp0bin\sbcl.exe" (
    set "SBCL_EXE=%~dp0bin\sbcl.exe"
    set "SBCL_HOME=%~dp0bin"
)

rem 2) explicit override
if not defined SBCL_EXE if defined MYAGENT_SBCL if exist "%MYAGENT_SBCL%" set "SBCL_EXE=%MYAGENT_SBCL%"

rem 3) PATH
if not defined SBCL_EXE for /f "delims=" %%I in ('where sbcl.exe 2^>nul') do if not defined SBCL_EXE set "SBCL_EXE=%%I"

rem 4) common install locations
if not defined SBCL_EXE for %%P in (
    "%ProgramFiles%\Steel Bank Common Lisp\sbcl.exe"
    "%ProgramW6432%\Steel Bank Common Lisp\sbcl.exe"
    "%ProgramFiles%\SBCL\sbcl.exe"
    "%USERPROFILE%\scoop\shims\sbcl.exe"
    "%USERPROFILE%\scoop\apps\sbcl\current\sbcl.exe"
    "C:\ProgramData\chocolatey\bin\sbcl.exe"
) do if not defined SBCL_EXE if exist "%%~P" set "SBCL_EXE=%%~P"

if not defined SBCL_EXE (
    echo [MyAgent] SBCL not found.
    echo   Put the SBCL runtime into .\bin\  ^(sbcl.exe + sbcl.core + contrib\^),
    echo   or install SBCL, or set MYAGENT_SBCL to the full path of sbcl.exe
    pause
    exit /b 1
)

rem SBCL_HOME detection for non-bundled installs
if "%SBCL_HOME%"=="" (
    for %%H in (
        "%USERPROFILE%\scoop\apps\sbcl\current"
        "%ProgramFiles%\Steel Bank Common Lisp"
        "%ProgramW6432%\Steel Bank Common Lisp"
    ) do if not defined SBCL_HOME if exist "%%~H\sbcl.core" set "SBCL_HOME=%%~H"
)

"%SBCL_EXE%" --noinform --load "%~dp0run.lisp" -- %*
if errorlevel 1 pause
