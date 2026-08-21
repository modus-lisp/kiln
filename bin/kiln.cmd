@echo off
setlocal enabledelayedexpansion
REM  kiln.cmd -- kiln on Windows.
REM
REM  Windows is a CLIENT here, not a host: the container half is Linux (and
REM  Apple's container at that), and `kiln local' would need McCLIM plus a pty
REM  that Windows has no equivalent of.  What Windows can do is look at a desktop
REM  running somewhere else, which is `view', and that is what this supports.
REM
REM    kiln view [host] [port]      default 127.0.0.1 5901
REM    kiln build-view              force a rebuild of glass-view.exe
REM
REM  Everything else -- build, run, config, bundle -- lives in bin/kiln on a
REM  POSIX box.

set HERE=%~dp0
for %%I in ("%HERE%..") do set KILN=%%~fI
for %%I in ("%KILN%\..") do set ROOT=%%~fI
set STATE=%KILN%\.kiln-win
set EXE=%STATE%\glass-view.exe

set CMD=%1
if "%CMD%"=="" set CMD=view
if /I "%CMD%"=="help" goto usage
if /I "%CMD%"=="--help" goto usage
if /I "%CMD%"=="/?" goto usage

REM ---- find an SBCL -----------------------------------------------------------
set SBCL=
where sbcl.exe >nul 2>&1 && for /f "delims=" %%S in ('where sbcl.exe') do set SBCL=%%S
if not defined SBCL if exist "%STATE%\sbcl\PFiles\Steel Bank Common Lisp\sbcl.exe" (
  set SBCL=%STATE%\sbcl\PFiles\Steel Bank Common Lisp\sbcl.exe
  set SBCL_HOME=%STATE%\sbcl\PFiles\Steel Bank Common Lisp
)
if not defined SBCL if exist "%ROOT%\vendor\sbcl-win.msi" (
  echo kiln: unpacking SBCL ^(no install -- an administrative extract^)
  if not exist "%STATE%" mkdir "%STATE%"
  msiexec /a "%ROOT%\vendor\sbcl-win.msi" /qn TARGETDIR="%STATE%\sbcl"
  set /a n=0
  :waitsbcl
  if exist "%STATE%\sbcl\PFiles\Steel Bank Common Lisp\sbcl.exe" goto gotsbcl
  set /a n+=1
  if !n! GEQ 60 goto nosbcl
  timeout /t 1 /nobreak >nul
  goto waitsbcl
  :gotsbcl
  set SBCL=%STATE%\sbcl\PFiles\Steel Bank Common Lisp\sbcl.exe
  set SBCL_HOME=%STATE%\sbcl\PFiles\Steel Bank Common Lisp
)
if not defined SBCL goto nosbcl

REM ---- SDL2.dll must sit beside the exe ---------------------------------------
if not exist "%STATE%" mkdir "%STATE%"
if not exist "%STATE%\SDL2.dll" (
  if exist "%ROOT%\vendor\SDL2.dll" (
    copy /y "%ROOT%\vendor\SDL2.dll" "%STATE%\" >nul
  ) else (
    echo kiln: SDL2.dll not found.  Put one in "%ROOT%\vendor\SDL2.dll"
    echo       ^(from https://github.com/libsdl-org/SDL/releases, the win32-x64 zip^)
    exit /b 1
  )
)

if /I "%CMD%"=="build-view" ( del /q "%EXE%" 2>nul )
if not exist "%EXE%" goto buildexe
goto runview

:buildexe
if not exist "%ROOT%\glass-sdl\bin\build-exe.lisp" (
  echo kiln: no glass-sdl beside kiln ^(looked in "%ROOT%\glass-sdl"^)
  echo       kiln expects the sibling checkouts: kiln\, glass-sdl\, glass\, cram\
  exit /b 1
)
echo kiln: building glass-view.exe ^(once; a minute or so^)
"%SBCL%" --dynamic-space-size 2048 --script "%ROOT%\glass-sdl\bin\build-exe.lisp" "%EXE%"
if not exist "%EXE%" (
  echo kiln: the build did not produce "%EXE%"
  exit /b 1
)

:runview
set VHOST=%2
set VPORT=%3
if "%CMD%"=="view" goto haveargs
REM  build-view with no run
if /I "%CMD%"=="build-view" ( echo kiln: built "%EXE%" & exit /b 0 )
:haveargs
if "%VHOST%"=="" set VHOST=127.0.0.1
if "%VPORT%"=="" set VPORT=5901
echo kiln: viewing %VHOST%:%VPORT%
"%EXE%" %VHOST% %VPORT%
exit /b %ERRORLEVEL%

:nosbcl
echo kiln: no SBCL found.
echo       Put sbcl.exe on PATH, or drop the Windows msi at "%ROOT%\vendor\sbcl-win.msi"
echo       ^(https://sourceforge.net/projects/sbcl/files/sbcl/ -- x86-64-windows-binary.msi^)
exit /b 1

:usage
echo kiln on Windows -- the client half.
echo.
echo   kiln view [host] [port]    a native window onto a glass desktop
echo   kiln build-view            rebuild glass-view.exe
echo.
echo Windows is a client here: build/run/config/bundle live in bin/kiln on POSIX.
exit /b 0
