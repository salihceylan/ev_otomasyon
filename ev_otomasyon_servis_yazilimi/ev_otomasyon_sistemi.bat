@echo off
title Ev Otomasyon Sistemi - Firmware Yukleyici
cd /d "%~dp0"
python ev_otomasyon_sistemi.py
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Bir hata olustu. Python yuklu oldugundan emin olun.
    pause
)

