# MeeSystemPos Print Service

Print Service สำหรับเชื่อมต่อระบบ MeeSystemPos กับเครื่องพิมพ์ใบเสร็จแบบหัวความร้อน (Thermal Printer) ผ่านระบบเครือข่าย (LAN).

## โครงสร้างโปรเจกต์

```text
print-proxy/
├── macos/
│   ├── print-proxy-macos.app   # แอปพร้อมใช้งานสำหรับ Mac
│   ├── MeeSystemPos-Print-Proxy-macOS.zip # ไฟล์สำหรับส่งให้ผู้ใช้
│   ├── menu.swift              # Source ของ Menu Bar app
│   └── build-macos.sh          # Build และแพ็ก ZIP
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
4. คลิกไอคอนเพื่อดูสถานะ พิมพ์ทดสอบ ตั้งค่า IP, Restart, Stop หรือ Quit

Config และ log จะอยู่ที่ `%APPDATA%\MeeSystemPos\`

ตัว `.exe` ฝัง Node.js server ไว้ภายในแล้ว จึงไม่ต้องติดตั้ง Node.js บนเครื่อง Windows

### 2. สำหรับ macOS
1. ส่งไฟล์ `macos/MeeSystemPos-Print-Proxy-macOS.zip` ให้ผู้ใช้ แล้วแตก ZIP
2. ดับเบิ้ลคลิก `print-proxy-macos.app`
3. ครั้งแรกโปรแกรมจะแสดงหน้าต่างให้กรอก IP เครื่องพิมพ์ โดยไม่เปิด Terminal
4. โปรแกรมจะทำงานในพื้นหลังและมีไอคอนเครื่องพิมพ์บน Menu Bar
5. คลิกไอคอนเพื่อดูสถานะ พิมพ์ทดสอบ ตั้งค่า IP, Restart, Stop หรือ Quit

Apple Silicon ต้องมี Rosetta 2 สำหรับ server ที่ฝังอยู่ภายใน หากยังไม่มี แอปจะแสดงคำสั่งติดตั้งให้ชัดเจน

Config และ log จะอยู่ที่ `~/Library/Application Support/MeeSystemPos/`

#### หากสถานะเป็น Offline บน Mac เครื่องใหม่

1. รอประมาณ 10–20 วินาทีหลังเปิดแอป เพราะ server ต้องใช้เวลาเริ่มต้น
2. ตรวจว่ากรอก IP เครื่องพิมพ์แล้วจากเมนู `ตั้งค่า IP เครื่องพิมพ์...`
3. หากแอปแจ้งเรื่อง Rosetta ให้เปิด Terminal แล้วรัน `softwareupdate --install-rosetta --agree-to-license`
4. กด `Restart` จากเมนูแอป
5. หากยัง Offline ให้กด `เปิด Log` แล้วตรวจข้อความผิดพลาด

ควรส่งแอปด้วยไฟล์ ZIP ที่ build ไว้ ไม่ควรส่งโฟลเดอร์ `.app` แบบแยกไฟล์ เพราะสิทธิ์ executable และโครงสร้าง bundle อาจเสียระหว่างการส่ง

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
