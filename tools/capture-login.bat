@echo off
chcp 437 >nul
setlocal
set PROXY_PORT=8899
set HERE=%~dp0
set PROFILE=%TEMP%\capture-profile

echo ============================================================
echo   Campus Portal Capture Launcher
echo ============================================================
echo.
echo  1. A proxy window will open (port %PROXY_PORT%).
echo  2. A SEPARATE browser window will open, using that proxy.
echo     Your normal browser is NOT affected (separate profile).
echo  3. Log in to the campus portal in that window, normally.
echo  4. When done, close both windows.
echo.
echo  Everything is recorded to:
echo    %HERE%captured-requests.txt
echo    %HERE%captured-bodies\last-post-body.txt
echo.
echo ============================================================
echo.

REM ---------- clear old captures ----------
if exist "%HERE%captured-requests.txt" del /q "%HERE%captured-requests.txt"
if exist "%HERE%captured-bodies\last-post-body.txt" del /q "%HERE%captured-bodies\last-post-body.txt"
if exist "%HERE%captured-bodies\last-post-response.txt" del /q "%HERE%captured-bodies\last-post-response.txt"

REM ---------- find python ----------
set PY=
where python >nul 2>nul && set PY=python
if "%PY%"=="" (
  where py >nul 2>nul && set PY=py
)
if "%PY%"=="" (
  echo [ERROR] Python not found. Install Python 3 and retry.
  pause
  exit /b 1
)
echo Using python: %PY%

REM ---------- start proxy in its own window ----------
start "campus-capture-proxy" %PY% "%HERE%capture-proxy.py"
timeout /t 3 /nobreak >nul

REM ---------- find a browser ----------
set BROWSER=
if exist "%ProgramFiles%\Google\Chrome\Application\chrome.exe" set BROWSER=%ProgramFiles%\Google\Chrome\Application\chrome.exe
if not defined BROWSER if exist "%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe" set BROWSER=%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe
if not defined BROWSER if exist "%LocalAppData%\Google\Chrome\Application\chrome.exe" set BROWSER=%LocalAppData%\Google\Chrome\Application\chrome.exe
if not defined BROWSER if exist "%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe" set BROWSER=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe
if not defined BROWSER if exist "%ProgramFiles%\Microsoft\Edge\Application\msedge.exe" set BROWSER=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe

if not defined BROWSER (
  echo.
  echo [WARN] Chrome/Edge not found automatically.
  echo Please set your browser proxy manually to 127.0.0.1:%PROXY_PORT%
  echo and then open your campus portal page.
  echo.
  pause
  exit /b 0
)

echo Using browser: %BROWSER%
echo Launching with proxy 127.0.0.1:%PROXY_PORT% ...
start "" "%BROWSER%" --proxy-server="127.0.0.1:%PROXY_PORT%" --user-data-dir="%PROFILE%" --no-first-run --new-window

echo.
echo Done. Do the login in the new browser window.
echo Then close both windows.
echo.
pause
