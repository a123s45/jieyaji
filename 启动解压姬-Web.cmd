@echo off
setlocal
rem 解压姬 Web 版启动器：自动找一个「装了 flask 和 pywebview」的 Python，
rem 不再写死 C:\Python314，别人克隆到别的机器也能直接双击。
set "APP=%~dp0jieyaji_web.py"
if not exist "%APP%" (
  echo   [x] 找不到 jieyaji_web.py，请把本文件放在程序目录里
  pause
  exit /b 1
)

set "FOUND="
rem 1) PATH 里的 pythonw
for %%P in (pythonw.exe) do call :probe "%%~$PATH:P"
rem 2) 常见安装位置：用户目录安装 / 全机器安装
call :probe "%LOCALAPPDATA%\Programs\Python\Python314\pythonw.exe"
call :probe "%LOCALAPPDATA%\Programs\Python\Python313\pythonw.exe"
call :probe "%LOCALAPPDATA%\Programs\Python\Python312\pythonw.exe"
call :probe "C:\Python314\pythonw.exe"
call :probe "C:\Python313\pythonw.exe"
call :probe "C:\Python312\pythonw.exe"

if not defined FOUND goto nodeps

start "" "%FOUND%" "%APP%"
exit /b 0

rem ---- 试探某个 pythonw：同目录下的 python.exe 能 import flask+webview 才算可用
:probe
if defined FOUND exit /b 0
if "%~1"=="" exit /b 0
if not exist "%~1" exit /b 0
set "PYE=%~dp1python.exe"
if not exist "%PYE%" exit /b 0
"%PYE%" -c "import flask, webview" >nul 2>nul
if errorlevel 1 exit /b 0
set "FOUND=%~1"
exit /b 0

:nodeps
echo.
echo   [x] 没找到可用的 Python（需要 flask + pywebview）
echo.
echo   1) 安装 Python 3.14（和仓库自带的 bin\pylibs 匹配）:
echo        https://www.python.org/downloads/
echo      安装时勾选 "Add python.exe to PATH"
echo.
echo   2) 装依赖（在命令行、本目录下执行）:
echo        pip install -r requirements.txt
echo.
echo   3) 再双击本文件
echo.
pause
exit /b 1
