@echo off
title MeeSystemPos - Print Service
echo =========================================
echo    Starting MeeSystemPos Print Proxy...
echo    กรุณาอย่าปิดหน้าต่างนี้ขณะใช้งานระบบ
echo =========================================
cd /d "%~dp0"
:: เช็คว่าติดตั้ง node_modules หรือยัง ถ้ายังให้ติดตั้งก่อน
if not exist "node_modules\" (
    echo Installing dependencies...
    call npm install
)
:: รันเซิร์ฟเวอร์
node server.js
pause
