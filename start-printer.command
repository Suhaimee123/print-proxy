#!/bin/bash
echo -e "\033[36m=========================================\033[0m"
echo -e "\033[32m   Starting MeeSystemPos Print Proxy...  \033[0m"
echo -e "\033[33m   กรุณาอย่าปิดหน้าต่างนี้ขณะใช้งานระบบ    \033[0m"
echo -e "\033[36m=========================================\033[0m"

# ย้ายเข้าไปยังโฟลเดอร์เดียวกับสคริปต์
cd "$(dirname "$0")"

# เช็คว่าติดตั้ง node_modules หรือยัง ถ้ายังให้ติดตั้งก่อน
if [ ! -d "node_modules" ]; then
    echo "Installing dependencies..."
    npm install
fi

# รันเซิร์ฟเวอร์
node server.js
