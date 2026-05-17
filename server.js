const http = require('http');
const net = require('net');
const iconv = require('iconv-lite');
const fs = require('fs');
const readline = require('readline');
const path = require('path');

const isPkg = typeof process.pkg !== 'undefined';
// Save config in the same directory as the executable
const configPath = isPkg ? path.join(path.dirname(process.execPath), 'printer-config.json') : path.join(__dirname, 'printer-config.json');

/**
 * CONFIGURATION
 */
let PRINTER_IP = '192.168.1.220';
const PRINTER_PORT = 9100;
const PROXY_PORT = 3001;

// ESC/POS Commands
const ESC = '\x1B';
const GS = '\x1D';
const INITIALIZE = ESC + '@';
const CUT_PAPER = GS + 'V' + '\x41' + '\x00';

/**
 * Convert pixels to ESC/POS Raster format (GS v 0)
 */
function pixelsToRaster(pixels, width, height) {
    const widthBytes = Math.ceil(width / 8);
    const raster = Buffer.alloc(widthBytes * height);
    
    for (let y = 0; y < height; y++) {
        for (let x = 0; x < width; x++) {
            const idx = (y * width + x) * 4;
            const r = pixels[idx];
            const g = pixels[idx + 1];
            const b = pixels[idx + 2];
            const a = pixels[idx + 3];
            
            const luminance = (r * 0.299 + g * 0.587 + b * 0.114);
            const isBlack = a > 50 && luminance < 200; 
            
            if (isBlack) {
                const byteIdx = y * widthBytes + Math.floor(x / 8);
                raster[byteIdx] |= (1 << (7 - (x % 8)));
            }
        }
    }
    
    const header = Buffer.from([
        0x1d, 0x76, 0x30, 0x00,
        widthBytes & 0xff, (widthBytes >> 8) & 0xff,
        height & 0xff, (height >> 8) & 0xff
    ]);
    
    return Buffer.concat([header, raster]);
}

function startServer() {
    const server = http.createServer((req, res) => {
        res.setHeader('Access-Control-Allow-Origin', '*');
        res.setHeader('Access-Control-Allow-Methods', 'POST, OPTIONS');
        res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

        if (req.method === 'OPTIONS') {
            res.writeHead(204);
            res.end();
            return;
        }

        if (req.method === 'POST' && req.url === '/print') {
            let body = [];
            req.on('data', chunk => { body.push(chunk); });
            req.on('end', () => {
                try {
                    const fullBody = Buffer.concat(body).toString();
                    const data = JSON.parse(fullBody);
                    
                    console.log(`Received print request. Pixels: ${data.pixels ? data.pixels.length : 0}, Width: ${data.width}, Height: ${data.height}`);

                    const client = new net.Socket();
                    client.connect(PRINTER_PORT, PRINTER_IP, () => {
                        console.log(`Connected to printer ${PRINTER_IP}`);
                        client.write(Buffer.from(INITIALIZE, 'binary'));
                        
                        if (data.pixels && data.width && data.height) {
                            console.log('Printing Image...');
                            const raster = pixelsToRaster(data.pixels, data.width, data.height);
                            client.write(raster);
                        } else if (data.text) {
                            console.log('Printing Text...');
                            client.write(Buffer.from(ESC + 't' + '\x19', 'binary'));
                            client.write(iconv.encode(data.text, 'cp874'));
                        }
                        
                        client.write(Buffer.from(CUT_PAPER, 'binary'));
                        client.end();
                        res.writeHead(200, { 'Content-Type': 'application/json' });
                        res.end(JSON.stringify({ success: true }));
                    });

                    client.on('error', (err) => {
                        res.writeHead(500, { 'Content-Type': 'application/json' });
                        res.end(JSON.stringify({ success: false, error: err.message }));
                    });
                } catch (err) {
                    res.writeHead(400);
                    res.end();
                }
            });
        }

        if (req.method === 'POST' && req.url === '/kick') {
            console.log(`Received kick drawer request.`);
            const KICK_DRAWER = '\x1B\x70\x00\x19\xFA'; // ESC p 0 25 250
            
            const client = new net.Socket();
            client.connect(PRINTER_PORT, PRINTER_IP, () => {
                console.log(`Connected to printer ${PRINTER_IP} for kicking drawer`);
                client.write(Buffer.from(KICK_DRAWER, 'binary'));
                client.end();
                res.writeHead(200, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ success: true }));
            });

            client.on('error', (err) => {
                res.writeHead(500, { 'Content-Type': 'application/json' });
                res.end(JSON.stringify({ success: false, error: err.message }));
            });
        }
    });

    server.listen(PROXY_PORT, () => {
        console.log('\x1b[36m=========================================\x1b[0m');
        console.log(`\x1b[32m   Ready! Using Printer IP: ${PRINTER_IP}\x1b[0m`);
        console.log('\x1b[32m   MeeSystemPos Print Proxy is Running   \x1b[0m');
        console.log('\x1b[33m   กรุณาอย่าปิดหน้าต่างนี้ขณะใช้งานระบบ    \x1b[0m');
        console.log('\x1b[36m=========================================\x1b[0m');
    });
}

const rl = readline.createInterface({
    input: process.stdin,
    output: process.stdout
});

function askQuestion(query) {
    return new Promise(resolve => rl.question(query, resolve));
}

async function initConfig() {
    console.log('\x1b[36m=========================================\x1b[0m');
    console.log('\x1b[32m   MeeSystemPos - Print Proxy Setup      \x1b[0m');
    console.log('\x1b[36m=========================================\x1b[0m\n');

    let savedIp = null;
    if (fs.existsSync(configPath)) {
        try {
            const configData = JSON.parse(fs.readFileSync(configPath, 'utf8'));
            if (configData.printerIp) {
                savedIp = configData.printerIp;
            }
        } catch (e) {
            // ignore
        }
    }

    if (savedIp) {
        const answer = await askQuestion(`พบการตั้งค่า IP เดิม: \x1b[33m${savedIp}\x1b[0m\nต้องการใช้ IP นี้หรือไม่? (Y/n): `);
        if (answer.trim().toLowerCase() === 'n') {
            const newIp = await askQuestion('\nกรุณากรอก IP เครื่องปริ้นใหม่ (เช่น 192.168.1.100): ');
            if (newIp.trim()) PRINTER_IP = newIp.trim();
        } else {
            PRINTER_IP = savedIp;
        }
    } else {
        const newIp = await askQuestion('กรุณากรอก IP เครื่องปริ้น (เช่น 192.168.1.100): ');
        if (newIp.trim()) {
            PRINTER_IP = newIp.trim();
        }
    }

    rl.close();

    // Save config
    try {
        fs.writeFileSync(configPath, JSON.stringify({ printerIp: PRINTER_IP }, null, 2));
    } catch (e) {
        console.error('\n[Warning] ไม่สามารถบันทึกการตั้งค่าได้');
    }

    console.log('\nกำลังเปิดระบบ...\n');
    startServer();
}

initConfig();
