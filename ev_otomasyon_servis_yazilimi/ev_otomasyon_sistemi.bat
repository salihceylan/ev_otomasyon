@echo off
title Ev Otomasyon Sistemi - Firmware Yukleyici
cd /d "%~dp0"
rem Python secimi: once "py -3" (kurulu en yeni Python 3; rehber 3.11+ ister), yoksa PATH'teki "python".
set "PY=python"
py -3 -c "import sys" 1>nul 2>nul
if not errorlevel 1 set "PY=py -3"
rem Zorunlu kutuphaneler (requirements.txt): eksikse bir kez kurulur (internet gerekir). pyserial de kurulur.
%PY% -c "import qrcode, PIL" 1>nul 2>nul
if errorlevel 1 (
    echo Eksik Python kutuphaneleri kuruluyor: qrcode, Pillow, pyserial ...
    %PY% -m pip install --disable-pip-version-check -r requirements.txt
)
%PY% -c "import qrcode, PIL" 1>nul 2>nul
if errorlevel 1 (
    echo.
    echo Gerekli kutuphaneler kurulamadi. Internet baglantisini kontrol edip su komutu calistirin:
    echo     %PY% -m pip install -r requirements.txt
    pause
    exit /b 1
)
%PY% ev_otomasyon_sistemi.py
if errorlevel 1 (
    echo.
    echo Bir hata olustu. Yukaridaki hata metnini IT'ye iletin.
    pause
)
