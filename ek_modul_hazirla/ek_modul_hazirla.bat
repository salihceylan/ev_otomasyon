@echo off
chcp 65001 > nul
title EK MODUL HAZIRLAMA ARACI
cd /d "%~dp0"
echo ========================================================
echo  AHBU Ev Otomasyonu - Ek Modul Hazirlama Araci (Python 3.11)
echo ========================================================
set "PY=C:\Users\fingonancalime\AppData\Local\Programs\Python\Python311\python.exe"
if not exist "%PY%" (
    echo [HATA] Python 3.11 bulunamadi: %PY%
    pause
    exit /b 1
)
"%PY%" ek_modul_hazirla.py
pause
