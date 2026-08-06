import Cocoa
import Foundation

class StatusBarApp: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var serverProcess: Process?
    var lastLaunchError: String?
    let proxyUrl = "http://localhost:3001/status"

    // Binary อยู่ภายใน app bundle เสมอ
    var serverBinPath: String {
        return Bundle.main.resourcePath.map { "\($0)/print-proxy-server-bin" } ?? ""
    }

    // Config อยู่ที่ ~/Library/Application Support/MeeSystemPos/
    var configDir: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MeeSystemPos").path
    }
    var configPath: String { "\(configDir)/printer-config.json" }
    var logPath: String { "\(configDir)/print-proxy.log" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        if let button = statusItem.button {
            if let icon = NSImage(systemSymbolName: "printer.fill", accessibilityDescription: "MeeSystemPos Print Proxy") {
                icon.isTemplate = true
                button.image = icon
            } else {
                button.title = "🖨"
            }
            button.toolTip = "MeeSystemPos Print Proxy"
        }
        setupMenu()
        launchServer()
        timer = Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(pollStatus), userInfo: nil, repeats: true)
        pollStatus()
    }

    func setupMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "MeeSystemPos Print Proxy", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let s = NSMenuItem(title: "สถานะ: กำลังเช็ค...", action: nil, keyEquivalent: "")
        s.tag = 1; s.isEnabled = false
        menu.addItem(s)

        let ip = NSMenuItem(title: "IP: -", action: nil, keyEquivalent: "")
        ip.tag = 2; ip.isEnabled = false
        menu.addItem(ip)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "เปิดหน้าสถานะ", action: #selector(openStatus), keyEquivalent: "b"))
        menu.addItem(NSMenuItem(title: "พิมพ์ทดสอบ", action: #selector(testPrint), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "เปิด Log", action: #selector(openLog), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "ตั้งค่า IP เครื่องพิมพ์...", action: #selector(openSetup), keyEquivalent: "s"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Restart", action: #selector(restart), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Stop", action: #selector(stopServer), keyEquivalent: "p"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "ออกจากโปรแกรม (Quit)", action: #selector(quit), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func launchServer() {
        guard !isPortInUse() else { return }
        guard FileManager.default.fileExists(atPath: serverBinPath) else {
            lastLaunchError = "ไม่พบ server binary"
            updateStatus("สถานะ: 🔴 ไม่พบ server binary")
            return
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            openSetup()
            return
        }

        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        p.arguments = ["-x86_64", serverBinPath, "--run"]
        p.currentDirectoryURL = URL(fileURLWithPath: configDir)
        var environment = ProcessInfo.processInfo.environment
        environment["PRINT_PROXY_CONFIG_DIR"] = configDir
        p.environment = environment

        if let log = FileHandle(forWritingAtPath: logPath) {
            log.seekToEndOfFile()
            p.standardOutput = log
            p.standardError = log
        }

        p.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                self?.serverProcess = nil
                if process.terminationStatus != 0 {
                    self?.lastLaunchError = "server หยุดทำงาน (code \(process.terminationStatus))"
                    self?.updateStatus("สถานะ: 🔴 เปิด server ไม่สำเร็จ — ดู Log")
                }
            }
        }

        do {
            try p.run()
            serverProcess = p
            lastLaunchError = nil
            updateStatus("สถานะ: 🟡 กำลังเริ่ม server...")
        } catch {
            lastLaunchError = error.localizedDescription
            updateStatus("สถานะ: 🔴 เปิด server ไม่สำเร็จ — ดู Log")
            appendLog("Launch error: \(error.localizedDescription)\n")
        }
    }

    func isPortInUse() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-Pi", ":3001", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        p.standardOutput = pipe
        try? p.run()
        p.waitUntilExit()
        return !pipe.fileHandleForReading.readDataToEndOfFile().isEmpty
    }

    @objc func pollStatus() {
        guard let url = URL(string: proxyUrl) else { return }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            var s = "สถานะ: 🔴 Offline"; var i = "IP: -"
            if let d = data,
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               j["status"] as? String == "online" {
                s = "สถานะ: 🟢 Online"
                if let ipv = j["printerIp"] as? String { i = "IP: \(ipv)" }
                self?.lastLaunchError = nil
            } else if self?.lastLaunchError != nil {
                s = "สถานะ: 🔴 เปิด server ไม่สำเร็จ — ดู Log"
            }
            DispatchQueue.main.async {
                self?.statusItem.menu?.item(withTag: 1)?.title = s
                self?.statusItem.menu?.item(withTag: 2)?.title = i
            }
        }.resume()
    }

    @objc func openStatus() {
        NSWorkspace.shared.open(URL(string: "http://localhost:3001/status")!)
    }

    @objc func testPrint() {
        guard let url = URL(string: "http://localhost:3001/print") else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let date = formatter.string(from: Date())
        var printerIp = "-"
        if let data = FileManager.default.contents(atPath: configPath),
           let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let ip = config["printerIp"] as? String {
            printerIp = ip
        }
        let text = """

        ================================
          MeeSystemPos - TEST PRINT
          Date: \(date)
          Printer IP: \(printerIp)
          Status: OK
        ================================


        """
        guard let body = try? JSONSerialization.data(withJSONObject: ["text": text]) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        updateStatus("สถานะ: 🟡 กำลังพิมพ์ทดสอบ...")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let success = error == nil && statusCode == 200 && data.flatMap {
                (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["success"] as? Bool
            } == true
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = success ? "พิมพ์ทดสอบสำเร็จ" : "พิมพ์ทดสอบไม่สำเร็จ"
                if success {
                    alert.informativeText = "ส่งใบพิมพ์ทดสอบไปยังเครื่องพิมพ์ \(printerIp) แล้ว"
                    alert.alertStyle = .informational
                } else {
                    alert.informativeText = error?.localizedDescription ?? "กรุณาตรวจสอบสถานะ Print Proxy, IP และการเชื่อมต่อเครื่องพิมพ์"
                    alert.alertStyle = .warning
                }
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
                self?.pollStatus()
            }
        }.resume()
    }

    @objc func openLog() {
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc func openSetup() {
        // สร้าง config dir ถ้าไม่มี
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)

        // เขียน setup script ที่ run server binary และบันทึก config ไว้ที่ Application Support
        let script = """
        #!/bin/bash
        mkdir -p "\(configDir)"
        cd "\(configDir)"
        arch -x86_64 "\(serverBinPath)"
        """
        let tmpScript = "/tmp/meesystempos-setup.command"
        try? script.write(toFile: tmpScript, atomically: true, encoding: .utf8)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+x", tmpScript]
        try? chmod.run(); chmod.waitUntilExit()

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [tmpScript]
        try? open.run()
    }

    @objc func stopServer() {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-t", "-i:3001"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        try? lsof.run(); lsof.waitUntilExit()
        let pids = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for pid in pids.split(separator: "\n") {
            let k = Process()
            k.executableURL = URL(fileURLWithPath: "/bin/kill")
            k.arguments = [String(pid)]
            try? k.run(); k.waitUntilExit()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.pollStatus() }
    }

    @objc func restart() {
        stopServer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.launchServer()
            self.pollStatus()
        }
    }

    @objc func quit() {
        stopServer()
        NSApplication.shared.terminate(nil)
    }

    func updateStatus(_ title: String) {
        statusItem.menu?.item(withTag: 1)?.title = title
    }

    func appendLog(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        if let log = FileHandle(forWritingAtPath: logPath) {
            log.seekToEndOfFile()
            log.write(data)
            try? log.close()
        }
    }
}

let app = NSApplication.shared
let del = StatusBarApp()
app.delegate = del
app.run()
