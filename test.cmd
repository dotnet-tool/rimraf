@if not defined _echo @echo off
powershell -NoProfile -ExecutionPolicy Unrestricted -Command "& """%~dp0eng/common/build.ps1""" -test %*"
exit /b %ERRORLEVEL%