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
        guard readPrinterIp() != nil else {
            openSetup()
            return
        }

        guard canRunX86Binary() else {
            lastLaunchError = "ต้องติดตั้ง Rosetta 2"
            updateStatus("สถานะ: 🔴 ต้องติดตั้ง Rosetta 2")
            appendLog("Rosetta 2 is required to run the embedded x86_64 server.\n")
            showRosettaAlert()
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
            appendLog("\n--- Launch \(ISO8601DateFormatter().string(from: Date())) ---\n")
            appendLog("Config: \(configPath)\nServer: \(serverBinPath)\n")
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

    func readPrinterIp() -> String? {
        guard let data = FileManager.default.contents(atPath: configPath),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ip = config["printerIp"] as? String,
              isValidIPv4(ip) else { return nil }
        return ip
    }

    func isValidIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3, let number = Int(part) else { return false }
            return number >= 0 && number <= 255
        }
    }

    func canRunX86Binary() -> Bool {
        #if arch(arm64)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", "/usr/bin/true"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
        #else
        return true
        #endif
    }

    func showRosettaAlert() {
        let alert = NSAlert()
        alert.messageText = "ต้องติดตั้ง Rosetta 2"
        alert.informativeText = "Print Server ภายในเป็น x86_64 กรุณาเปิด Terminal แล้วรันคำสั่งนี้:\n\nsoftwareupdate --install-rosetta --agree-to-license\n\nเมื่อติดตั้งเสร็จให้กด Restart จากเมนูแอป"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "ตกลง")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
        let printerIp = readPrinterIp() ?? "-"
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
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        var suggestedIp = readPrinterIp() ?? ""

        while true {
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            input.placeholderString = "เช่น 192.168.1.100"
            input.stringValue = suggestedIp

            let alert = NSAlert()
            alert.messageText = "ตั้งค่า IP เครื่องพิมพ์"
            alert.informativeText = "กรอก IPv4 Address ของเครื่องพิมพ์ที่อยู่ในเครือข่ายเดียวกับ Mac"
            alert.accessoryView = input
            alert.addButton(withTitle: "บันทึก")
            alert.addButton(withTitle: "ยกเลิก")
            NSApp.activate(ignoringOtherApps: true)
            input.becomeFirstResponder()

            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let ip = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidIPv4(ip) else {
                suggestedIp = ip
                let warning = NSAlert()
                warning.messageText = "IP Address ไม่ถูกต้อง"
                warning.informativeText = "กรุณากรอกในรูปแบบ เช่น 192.168.1.100"
                warning.alertStyle = .warning
                warning.runModal()
                continue
            }

            do {
                let data = try JSONSerialization.data(withJSONObject: ["printerIp": ip], options: [.prettyPrinted, .sortedKeys])
                try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
                appendLog("Saved printer IP: \(ip)\n")
                if isPortInUse() {
                    stopServer()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.launchServer() }
                } else {
                    launchServer()
                }
            } catch {
                lastLaunchError = error.localizedDescription
                let failure = NSAlert()
                failure.messageText = "บันทึกการตั้งค่าไม่สำเร็จ"
                failure.informativeText = error.localizedDescription
                failure.alertStyle = .critical
                failure.runModal()
            }
            return
        }
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
