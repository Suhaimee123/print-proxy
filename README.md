# MeeSystemPos Print Service

Print Service สำหรับเชื่อมต่อระบบ MeeSystemPos กับเครื่องพิมพ์ใบเสร็จแบบหัวความร้อน (Thermal Printer) ผ่านระบบเครือข่าย (LAN).

## โครงสร้างโปรเจกต์

```text
print-proxy/
├── macos/
│   ├── print-proxy-macos.app   # แอปพร้อมใช้งานสำหรับ Mac
│   └── menu.swift              # Source ของ Menu Bar app
├── windows/
│   ├── print-proxy-win.exe     # แอปพร้อมใช้งานสำหรับ Windows
│   ├── windows-tray.c          # Source ของ System Tray app
│   ├── windows-tray.rc         # Windows resources
│   └── build-windows.sh        # Build script
├── server.js                   # Print server ที่ใช้ร่วมกัน
├── package.json
└── README.md
```

## วิธีใช้งาน

### 1. สำหรับ Windows
1. เข้าโฟลเดอร์ `windows` แล้วดับเบิ้ลคลิก `print-proxy-win.exe`
2. ครั้งแรกที่เปิด โปรแกรมจะถาม IP Address ของเครื่องพิมพ์ ให้กรอก IP เช่น `192.168.1.100`
3. โปรแกรมจะทำงานในพื้นหลังโดยไม่มีหน้าต่าง Command Prompt และมีไอคอนเครื่องพิมพ์ใน System Tray
4. คลิกไอคอนเพื่อดูสถานะ ตั้งค่า IP, Restart, Stop หรือ Quit

Config และ log จะอยู่ที่ `%APPDATA%\MeeSystemPos\`

ตัว `.exe` ฝัง Node.js server ไว้ภายในแล้ว จึงไม่ต้องติดตั้ง Node.js บนเครื่อง Windows

### 2. สำหรับ macOS
1. เข้าโฟลเดอร์ `macos` แล้วดับเบิ้ลคลิก `print-proxy-macos.app`
2. โปรแกรมจะทำงานในพื้นหลังโดยไม่มี Terminal และมีไอคอนเครื่องพิมพ์บน Menu Bar
3. คลิกไอคอนเพื่อดูสถานะ ตั้งค่า IP, Restart, Stop หรือ Quit

Config และ log จะอยู่ที่ `~/Library/Application Support/MeeSystemPos/`

### 3. สำหรับ Linux
```bash
cd /path/to/print-proxy
npm install
node server.js
```

## IP Address เครื่องพิมพ์

ตั้งค่าจากเมนูของแอป หรือแก้ไข `printer-config.json` ในโฟลเดอร์ config ของระบบ
```json
{
  "printerIp": "192.168.1.xxx"
}
```
