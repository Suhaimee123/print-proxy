# คู่มือทำความเข้าใจ MeeSystemPos Print Proxy

โปรเจกต์นี้เป็นตัวกลางระหว่างเว็บ MeeSystemPos กับเครื่องพิมพ์ใบเสร็จในเครือข่าย LAN

```text
เว็บ MeeSystemPos
       |
       | ส่งงานพิมพ์ไปยัง http://localhost:3001
       v
MeeSystemPos Print Proxy
       |
       | ส่งข้อมูล ESC/POS ไปยัง Printer IP พอร์ต 9100
       v
เครื่องพิมพ์ใบเสร็จ
```

## โปรเจกต์นี้มีไว้ทำอะไร

เว็บเบราว์เซอร์ไม่สามารถส่งข้อมูลไปยังเครื่องพิมพ์ใบเสร็จผ่าน LAN ได้โดยตรง จึงต้องมี Print Proxy รันอยู่ในเครื่องของร้าน

หน้าที่ของ Print Proxy คือ:

1. รับคำสั่งจากเว็บ POS
2. แปลงข้อความหรือรูปภาพเป็นรูปแบบ ESC/POS
3. เชื่อมต่อไปยัง IP ของเครื่องพิมพ์
4. พิมพ์ใบเสร็จหรือสั่งเปิดลิ้นชักเก็บเงิน

## ลำดับการทำงาน

สมมติเครื่องพิมพ์มี IP `192.168.1.100`

1. พนักงานเปิด Print Proxy
2. Print Proxy เปิด HTTP server ที่พอร์ต `3001`
3. เว็บ POS ส่งงานไปที่ `http://localhost:3001/print`
4. Print Proxy ส่งงานต่อไปยัง `192.168.1.100:9100`
5. เครื่องพิมพ์พิมพ์ใบเสร็จ

`localhost` หมายถึงคอมพิวเตอร์เครื่องที่เปิดเว็บ POS อยู่ ไม่ใช่เซิร์ฟเวอร์บนอินเทอร์เน็ต

## โครงสร้างโปรเจกต์

```text
print-proxy/
├── macos/
│   ├── print-proxy-macos.app
│   └── menu.swift
├── windows/
│   ├── print-proxy-win.exe
│   ├── windows-tray.c
│   ├── windows-tray.rc
│   └── build-windows.sh
├── server.js
├── package.json
├── package-lock.json
├── README.md
└── PROJECT-GUIDE.md
```

## ไฟล์สำคัญ

### `server.js`

นี่คือหัวใจหลักของระบบและใช้ร่วมกันทั้ง Windows และ macOS

ทำหน้าที่:

- เปิดพอร์ต `3001`
- รับคำสั่งพิมพ์จากเว็บ POS
- แปลงรูปภาพเป็นข้อมูล ESC/POS
- ส่งข้อมูลไปยังเครื่องพิมพ์พอร์ต `9100`
- สั่งเปิดลิ้นชักเก็บเงิน
- อ่าน Printer IP จากไฟล์ config

### โฟลเดอร์ `macos`

ไฟล์พร้อมใช้งานคือ `macos/print-proxy-macos.app`

เมื่อเปิดแอป:

- ไม่มีหน้าต่าง Terminal ค้าง
- มีไอคอนเครื่องพิมพ์บน Menu Bar
- สามารถดูสถานะ พิมพ์ทดสอบ ตั้งค่า IP, Restart, Stop และ Quit ได้
- มี server binary ฝังอยู่ภายในแอป

`macos/menu.swift` คือ source code ของ Menu Bar app

Mac app เป็น ARM64 แต่ server ภายในเป็น x86-64 จึงใช้ Rosetta ในการรัน

### โฟลเดอร์ `windows`

ไฟล์พร้อมใช้งานคือ `windows/print-proxy-win.exe`

เมื่อเปิดแอป:

- ไม่มีหน้าต่าง Command Prompt ค้าง
- มีไอคอนเครื่องพิมพ์ใน System Tray
- สามารถดูสถานะ พิมพ์ทดสอบ ตั้งค่า IP, Restart, Stop และ Quit ได้
- ไม่ต้องติดตั้ง Node.js
- Server ถูกฝังอยู่ในไฟล์ `.exe`

`windows/windows-tray.c` คือ source ของ Windows System Tray app และ `windows/windows-tray.rc` ใช้ฝัง server กับข้อมูลเวอร์ชันลงใน `.exe`

## ตำแหน่ง Config และ Log

macOS:

```text
~/Library/Application Support/MeeSystemPos/
```

Windows:

```text
%APPDATA%\MeeSystemPos\
```

ตัวอย่าง `printer-config.json`:

```json
{
  "printerIp": "192.168.1.100"
}
```

ปกติไม่จำเป็นต้องเปิดแก้เอง เพราะสามารถตั้งค่า IP จากเมนูของแอปได้

## API ที่เว็บ POS ใช้

### ตรวจสอบสถานะ

```http
GET http://localhost:3001/status
```

ตัวอย่างผลตอบกลับ:

```json
{
  "status": "online",
  "printerIp": "192.168.1.100",
  "port": 3001
}
```

### สั่งพิมพ์

```http
POST http://localhost:3001/print
```

### สั่งเปิดลิ้นชัก

```http
POST http://localhost:3001/kick
```

## วิธีนำไปใช้ที่ร้าน

### Windows

1. ส่งไฟล์ `windows/print-proxy-win.exe` ไปยังเครื่องร้าน
2. ดับเบิลคลิกไฟล์
3. กรอก IP Address ของเครื่องพิมพ์
4. รอให้ไอคอนปรากฏใน System Tray
5. เปิดเว็บ POS แล้วทดลองพิมพ์

### macOS

1. ส่ง `macos/print-proxy-macos.app` ไปยังเครื่องร้าน
2. เปิดแอป
3. ตั้งค่า IP จากไอคอนเครื่องพิมพ์บน Menu Bar
4. รอให้สถานะเป็น Online
5. เปิดเว็บ POS แล้วทดลองพิมพ์

## สิ่งสำคัญที่ควรรู้

- คอมพิวเตอร์และเครื่องพิมพ์ต้องอยู่ในวง LAN เดียวกัน
- เครื่องพิมพ์ต้องรองรับ ESC/POS ผ่านพอร์ต `9100`
- IP เครื่องพิมพ์ควรเป็น IP คงที่
- Print Proxy ต้องเปิดอยู่ก่อนสั่งพิมพ์
- Windows อาจแสดง SmartScreen เพราะ `.exe` ยังไม่มี Code Signing Certificate
- Mac เครื่องใหม่ต้องมี Rosetta เพราะ server ภายในเป็น x86-64
- พอร์ต `3001` ต้องไม่ถูกโปรแกรมอื่นใช้งาน
- ระบบปัจจุบันไม่มี authentication และอนุญาต CORS ทั้งหมด จึงควรใช้ภายในเครือข่ายร้านที่เชื่อถือได้

## สรุป

`server.js` คือเครื่องยนต์หลักของระบบ ส่วนแอปใน `macos/` และ `windows/` คือหน้าควบคุมเครื่องยนต์สำหรับแต่ละระบบ
