import Cocoa

// MARK: - 配置

let sampleInterval: TimeInterval = 15
let csvEveryN = 4
let chartWindowPoints = 180
let axisMin = 20
let axisMax = 90
let rescanEveryTicks = 4

let smartctlPath = ("~/.local/bin/smartctl" as NSString).expandingTildeInPath
let csvPath = ("~/Library/Logs/tb-monitor.csv" as NSString).expandingTildeInPath
let alertPath = ("~/Library/Logs/tb-alerts.log" as NSString).expandingTildeInPath

func threshold() -> Int {
    let v = UserDefaults.standard.integer(forKey: "threshold")
    return v > 0 ? v : 75
}

// MARK: - 数据模型

struct Drive {
    var key: String
    var device: String
    var devType: String
    var model: String
    var serial: String
    var isTB: Bool
    var hasTemp: Bool

    var shortName: String {
        let tokens = model.split(separator: " ").map(String.init)
        var brand = tokens.first ?? model
        if brand.hasPrefix("APPLE") { brand = "内置盘" }
        // 找形如 2TB / 500GB 的容量
        let cap = tokens.first { t in
            let up = t.uppercased()
            return (up.hasSuffix("TB") || up.hasSuffix("GB")) && up.first?.isNumber == true
        }
        if let c = cap { return "\(brand) \(c)" }
        return model.count > 14 ? String(model.prefix(14)) : model
    }
}

struct Readings {
    var comp: Int?
    var s1: Int?
    var s2: Int?
    var warn: String = "NA"
}

struct Row {
    var t: String
    var s1: Int?
    var s2: Int?
}

struct Stats {
    var max = 0
    var min = 0
    var hot = 0
    var samples = 0
    var avg = 0.0
}

// MARK: - 工具

func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func valueAfterColon(_ s: String) -> String {
    guard let colon = s.firstIndex(of: ":") else { return "" }
    return String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
}

func leadingInt(_ s: String) -> Int? {
    let t = valueAfterColon(s)
    return Int(t.prefix(while: { $0.isNumber }))
}

// MARK: - 设备发现

func listExternalDevices() -> [String] {
    let out = shell("/usr/sbin/diskutil", ["list", "external"])
    var devs: [String] = []
    for line in out.split(separator: "\n") {
        let t = String(line)
        guard t.contains("(external, physical)"), let r = t.range(of: " (") else { continue }
        devs.append(String(t[t.startIndex..<r.lowerBound]))
    }
    return devs
}

func scanDrives() -> [Drive] {
    var list: [Drive] = []
    for dev in listExternalDevices() {
        let info = shell(smartctlPath, ["-d", "auto", "-i", dev])
        var model = ""
        var serial = ""
        for l in info.split(separator: "\n") {
            let t = String(l)
            if t.hasPrefix("Model Number:") { model = valueAfterColon(t) }
            else if t.hasPrefix("Device Model:") { model = valueAfterColon(t) }
            else if t.hasPrefix("Serial Number:") { serial = valueAfterColon(t) }
        }
        if model.isEmpty { continue }

        let probe = shell(smartctlPath, ["-d", "auto", "-A", dev])
        let hasTemp = probe.contains("Temperature Sensor 1:") || probe.contains("Temperature:")

        let dinfo = shell("/usr/sbin/diskutil", ["info", dev])
        let isUSB = dinfo.contains("Protocol:") && dinfo.contains("USB")

        let key = serial.isEmpty ? dev : serial
        list.append(Drive(key: key, device: dev, devType: "auto",
                          model: model, serial: serial, isTB: !isUSB, hasTemp: hasTemp))
    }
    return list
}

func readDrive(_ d: Drive) -> Readings {
    var r = Readings()
    guard d.hasTemp else { return r }
    let out = shell(smartctlPath, ["-d", d.devType, "-A", d.device])
    if out.isEmpty { return r }
    for line in out.split(separator: "\n") {
        let l = String(line)
        if l.hasPrefix("Temperature Sensor 1:") { r.s1 = leadingInt(l) }
        else if l.hasPrefix("Temperature Sensor 2:") { r.s2 = leadingInt(l) }
        else if l.hasPrefix("Temperature:") { r.comp = leadingInt(l) }
        else if l.hasPrefix("Critical Warning:") { r.warn = valueAfterColon(l) }
    }
    return r
}

// MARK: - 存储

func stamp() -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date())
}

func appendCSV(_ d: Drive, _ r: Readings) {
    let line = "\(stamp()),\(r.comp.map(String.init) ?? "NA"),\(r.s1.map(String.init) ?? "NA"),\(r.s2.map(String.init) ?? "NA"),\(r.warn),-,\(d.key)\n"
    if let h = FileHandle(forWritingAtPath: csvPath) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); h.closeFile()
    } else {
        try? ("时间,复合,主控,闪存,告警,链路,设备\n" + line).write(toFile: csvPath, atomically: true, encoding: .utf8)
    }
}

func loadRows(_ key: String, _ primaryKey: String?, _ n: Int) -> [Row] {
    guard let text = try? String(contentsOfFile: csvPath, encoding: .utf8) else { return [] }
    var rows: [Row] = []
    for line in text.split(separator: "\n").dropFirst() {
        let c = line.split(separator: ",")
        guard c.count >= 4 else { continue }
        if c.count >= 7 {
            if String(c[6]) != key { continue }
        } else if key != primaryKey {
            continue
        }
        rows.append(Row(t: String(c[0]), s1: Int(c[2]), s2: Int(c[3])))
    }
    return Array(rows.suffix(n))
}

func humanDuration(_ s: TimeInterval) -> String {
    let total = Int(s)
    let d = total / 86400, h = (total % 86400) / 3600, m = (total % 3600) / 60
    if d > 0 { return "\(d) 天 \(h) 小时" }
    if h > 0 { return "\(h) 小时 \(m) 分" }
    return "\(m) 分"
}

func todayStats(_ key: String, _ primaryKey: String?) -> Stats {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    let today = f.string(from: Date())
    var st = Stats()
    st.min = 999
    var sum = 0
    for r in loadRows(key, primaryKey, 100000) where r.t.hasPrefix(today) {
        st.samples += 1
        guard let v = r.s1 else { continue }
        if v > st.max { st.max = v }
        if v < st.min { st.min = v }
        if v >= threshold() { st.hot += 1 }
        sum += v
    }
    if st.samples == 0 || st.min == 999 { st.min = 0 }
    st.avg = st.samples > 0 ? Double(sum) / Double(st.samples) : 0
    return st
}

func notifyUser(_ msg: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "display notification \"\(msg)\" with title \"硬盘温度\" sound name \"Ping\""]
    try? p.run()
}

func hex(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

let cardBG = hex(29, 32, 38)
let cardBorder = hex(255, 255, 255, 0.07)
let textMain = hex(238, 240, 244)
let textDim = hex(140, 148, 160)
let accentOrange = hex(255, 159, 67)
let accentGreen = hex(62, 207, 142)
let accentRed = hex(229, 72, 77)
let accentTeal = hex(64, 200, 214)

// MARK: - 仪表盘

final class DashboardView: NSView {
    var drives: [Drive] = []
    var selected = 0
    var rows: [Row] = []
    var latest = Readings()
    var stats = Stats()
    var connected: String = "--"
    var interfaceText: String = "--"
    var emptyHint: String = "正在积累数据"
    weak var owner: AppDelegate?
    private var hitAreas: [(NSRect, String)] = []

    override var isFlipped: Bool { true }

    private func card(_ r: NSRect) {
        let p = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
        cardBG.setFill(); p.fill()
        cardBorder.setStroke(); p.lineWidth = 1; p.stroke()
    }

    private func text(_ s: String, _ r: NSRect, _ size: CGFloat, _ color: NSColor,
                      _ weight: NSFont.Weight = .regular, _ align: NSTextAlignment = .left) {
        let ps = NSMutableParagraphStyle()
        ps.alignment = align
        ps.lineBreakMode = .byTruncatingTail
        let a = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: ps
        ])
        a.draw(in: r)
    }

    private func dot(_ c: CGPoint, _ color: NSColor, _ d: CGFloat = 7) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x, y: c.y, width: d, height: d)).fill()
    }

    private func rowItem(_ r: NSRect, _ label: String, _ value: String, _ color: NSColor?) {
        dot(CGPoint(x: r.minX, y: r.minY + 5), color ?? hex(255, 255, 255, 0.20), 8)
        text(label, NSRect(x: r.minX + 17, y: r.minY, width: r.width * 0.6, height: 20), 13, textDim)
        text(value, NSRect(x: r.minX, y: r.minY, width: r.width, height: 20), 15, textMain, .semibold, .right)
    }

    private func lineChart(_ rect: NSRect) {
        let gutter: CGFloat = 26
        let plot = NSRect(x: rect.minX + gutter, y: rect.minY, width: rect.width - gutter, height: rect.height - 16)
        let lo = Double(axisMin), hi = Double(axisMax)
        let span = hi - lo

        func py(_ v: Int) -> CGFloat {
            plot.maxY - plot.height * CGFloat(Double(v) - lo) / CGFloat(span)
        }

        var v = axisMin
        while v <= axisMax {
            let y = py(v)
            let p = NSBezierPath()
            p.move(to: CGPoint(x: plot.minX, y: y))
            p.line(to: CGPoint(x: plot.maxX, y: y))
            p.lineWidth = 0.5
            hex(255, 255, 255, 0.07).setStroke()
            p.stroke()
            if v != axisMin && v != axisMax {
                text("\(v)°", NSRect(x: rect.minX - 2, y: y - 7, width: gutter - 4, height: 14),
                     9.5, textDim, .regular, .right)
            }
            v += 10
        }

        // 有温度数据的点少于两个就不画图，避免空网格
        guard rows.compactMap({ $0.s1 }).count > 1 else {
            text(emptyHint, plot, 11, textDim, .regular, .center)
            return
        }

        let wy = py(84)
        let wp = NSBezierPath()
        wp.move(to: CGPoint(x: plot.minX, y: wy))
        wp.line(to: CGPoint(x: plot.maxX, y: wy))
        wp.lineWidth = 1
        wp.setLineDash([3, 3], count: 2, phase: 0)
        accentRed.withAlphaComponent(0.55).setStroke()
        wp.stroke()
        wp.setLineDash(nil, count: 0, phase: 0)
        text("84°", NSRect(x: plot.maxX - 26, y: wy - 15, width: 24, height: 13),
             9, accentRed.withAlphaComponent(0.85), .medium, .right)

        let n = rows.count
        func px(_ i: Int) -> CGFloat {
            plot.minX + plot.width * CGFloat(i) / CGFloat(max(n - 1, 1))
        }

        func line(_ get: (Row) -> Int?, _ color: NSColor, _ width: CGFloat) {
            let path = NSBezierPath()
            var started = false
            for (i, r) in rows.enumerated() {
                guard let val = get(r) else { continue }
                let pt = CGPoint(x: px(i), y: py(val))
                if !started { path.move(to: pt); started = true } else { path.line(to: pt) }
            }
            path.lineWidth = width
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        }
        line({ $0.s2 }, accentGreen, 1.5)
        line({ $0.s1 }, accentOrange, 2)

        if let last = rows.last, let val = last.s1 {
            dot(CGPoint(x: px(n - 1) - 2.5, y: py(val) - 2.5), accentOrange, 5)
        }

        for i in [0, n / 2, n - 1] where i >= 0 && i < n {
            let short = String(rows[i].t.suffix(8).prefix(5))
            let x = min(max(px(i) - 18, plot.minX), plot.maxX - 36)
            text(short, NSRect(x: x, y: rect.maxY - 12, width: 36, height: 12), 9, textDim, .regular, .center)
        }
    }

    private func chip(_ r: NSRect, _ label: String, _ key: String, _ active: Bool) {
        let p = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
        (active ? hex(255, 255, 255, 0.13) : hex(255, 255, 255, 0.05)).setFill(); p.fill()
        (active ? accentOrange.withAlphaComponent(0.55) : hex(255, 255, 255, 0.09)).setStroke()
        p.lineWidth = 1; p.stroke()
        text(label, NSRect(x: r.minX + 4, y: r.minY + r.height / 2 - 9, width: r.width - 8, height: 20),
             12, active ? textMain : textDim, active ? .semibold : .medium, .center)
        hitAreas.append((r, key))
    }

    override func draw(_ dirtyRect: NSRect) {
        hex(15, 17, 21).setFill()
        bounds.fill()
        hitAreas.removeAll()

        let pad: CGFloat = 12, gap: CGFloat = 10
        let inner = bounds.width - pad * 2
        let th = threshold()

        let pickerH: CGFloat = 30
        let pickerY = pad
        if drives.isEmpty {
            chip(NSRect(x: pad, y: pickerY, width: inner, height: pickerH), "未检测到外接硬盘", "none", false)
        } else if drives.count == 1 {
            chip(NSRect(x: pad, y: pickerY, width: inner, height: pickerH), drives[0].shortName, "select0", true)
        } else {
            let n = min(drives.count, 3)
            let cw = (inner - gap * CGFloat(n - 1)) / CGFloat(n)
            for i in 0..<n {
                chip(NSRect(x: pad + CGFloat(i) * (cw + gap), y: pickerY, width: cw, height: pickerH),
                     drives[i].shortName, "select\(i)", i == selected)
            }
        }

        let top = pickerY + pickerH + gap

        let h1: CGFloat = 250
        let aRect = NSRect(x: pad, y: top, width: inner, height: h1)
        card(aRect)
        let ar = aRect.insetBy(dx: 13, dy: 11)
        dot(CGPoint(x: ar.minX, y: ar.minY + 5), accentOrange, 8)
        text("硬盘温度", NSRect(x: ar.minX + 17, y: ar.minY, width: ar.width - 17, height: 22), 13.5, textMain, .semibold)

        let s1v = latest.s1 ?? 0
        let stColor: NSColor = latest.s1 == nil ? textDim : (s1v >= th ? accentRed : (s1v >= th - 10 ? accentOrange : accentGreen))
        let stText = latest.s1 == nil ? "无数据" : (s1v >= th ? "过热" : (s1v >= th - 10 ? "偏热" : "正常"))
        text(stText, NSRect(x: ar.minX, y: ar.minY, width: ar.width, height: 22), 14, stColor, .semibold, .right)

        let big = latest.s1.map { "\($0)" } ?? "--"
        text(big, NSRect(x: ar.minX, y: ar.minY + 20, width: 110, height: 48), 38, textMain, .semibold)
        text("℃", NSRect(x: ar.minX + 58, y: ar.minY + 38, width: 24, height: 24), 16, textDim, .medium)

        let chartRect = NSRect(x: ar.minX, y: ar.minY + 86, width: ar.width, height: aRect.height - 109)
        lineChart(chartRect)

        let legend: [(String, NSColor)] = [("主控", accentOrange), ("闪存", accentGreen)]
        var lx = ar.minX
        for (label, color) in legend {
            dot(CGPoint(x: lx, y: ar.minY + 74), color, 8)
            text(label, NSRect(x: lx + 13, y: ar.minY + 69, width: 40, height: 16), 11, textDim)
            lx += 52
        }
        text("阈值 \(th)℃", NSRect(x: ar.minX, y: ar.minY + 69, width: ar.width, height: 16), 11, textDim, .regular, .right)

        let h2: CGFloat = 180
        let bRect = NSRect(x: pad, y: top + h1 + gap, width: inner, height: h2)
        card(bRect)
        let br = bRect.insetBy(dx: 13, dy: 11)
        dot(CGPoint(x: br.minX, y: br.minY + 5), accentTeal, 8)
        text("读数与连接", NSRect(x: br.minX + 17, y: br.minY, width: br.width - 17, height: 22), 13.5, textMain, .semibold)

        let s1t = latest.s1.map { "\($0)℃" } ?? "--"
        let s2t = latest.s2.map { "\($0)℃" } ?? "--"
        rowItem(NSRect(x: br.minX, y: br.minY + 32, width: br.width, height: 20), "主控", s1t, accentOrange)
        rowItem(NSRect(x: br.minX, y: br.minY + 58, width: br.width, height: 20), "闪存", s2t, accentGreen)
        rowItem(NSRect(x: br.minX, y: br.minY + 84, width: br.width, height: 20), "连接时间", connected, nil)
        rowItem(NSRect(x: br.minX, y: br.minY + 110, width: br.width, height: 20), "接口", interfaceText,
                interfaceText.contains("雷雳") ? accentGreen : nil)
        let warnText = latest.warn == "0x00" ? "正常" : (latest.warn == "NA" ? "—" : latest.warn)
        rowItem(NSRect(x: br.minX, y: br.minY + 136, width: br.width, height: 20), "告警",
                warnText, latest.warn == "0x00" || latest.warn == "NA" ? nil : accentRed)

        let btnH: CGFloat = 36
        let btnY1 = top + h1 + gap + h2 + gap
        let row1 = [("数据日志", "csv"), ("告警日志", "alert"), ("HTML 报告", "report")]
        let bw1 = (inner - gap * 2) / 3
        for (i, it) in row1.enumerated() {
            chip(NSRect(x: pad + CGFloat(i) * (bw1 + gap), y: btnY1, width: bw1, height: btnH), it.0, it.1, false)
        }
        let btnY2 = btnY1 + btnH + 8
        let row2 = [("刷新", "refresh"), ("退出", "quit")]
        let bw2 = (inner - gap) / 2
        for (i, it) in row2.enumerated() {
            chip(NSRect(x: pad + CGFloat(i) * (bw2 + gap), y: btnY2, width: bw2, height: btnH), it.0, it.1, false)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (r, key) in hitAreas where r.contains(p) {
            owner?.runAction(key)
            return
        }
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var timer: Timer?
    var tick = 0
    var drives: [Drive] = []
    var readings: [String: Readings] = [:]
    var selected = 0
    var stats = Stats()
    var lastAlert: [String: Date] = [:]
    var since: [String: Double] = [:]
    var panel: NSWindow?
    var dashboard: DashboardView?

    var primaryKey: String? { drives.first?.key }

    func applicationDidFinishLaunching(_ note: Notification) {
        item = NSStatusBar.system.statusItem(withLength: 46)
        item.button?.title = "…"
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        item.button?.sendAction(on: [.leftMouseUp])

        drives = scanDrives()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: sampleInterval, repeats: true) { _ in
            self.refresh()
        }
        RunLoop.current.add(timer!, forMode: .common)

        if CommandLine.arguments.contains("--panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.showPanel() }
        }
    }

    func refresh() {
        tick += 1
        if tick % rescanEveryTicks == 0 {
            let found = scanDrives()
            if found.map({ $0.key }) != drives.map({ $0.key }) {
                drives = found
                selected = min(selected, max(drives.count - 1, 0))
            }
        }
        if tick == 1 && drives.isEmpty { drives = scanDrives() }

        var fresh: [String: Readings] = [:]
        for d in drives {
            let r = readDrive(d)
            fresh[d.key] = r
            if tick % csvEveryN == 1 { appendCSV(d, r) }
            checkAlert(d, r)
        }
        readings = fresh
        updateConnectionState(Array(fresh.keys))
        if selected < drives.count {
            stats = todayStats(drives[selected].key, primaryKey)
        }
        renderTitle()
        refreshPanel()
    }

    func renderTitle() {
        let temps = drives.compactMap { readings[$0.key]?.s1 }
        guard let hottest = temps.max() else {
            item.button?.title = "—°"
            return
        }
        let th = threshold()
        let color: NSColor = hottest >= th ? accentRed : (hottest >= th - 10 ? accentOrange : .labelColor)
        let attr = NSMutableAttributedString(string: "\(hottest)°")
        let range = NSRange(location: 0, length: attr.length)
        attr.addAttribute(.foregroundColor, value: color, range: range)
        attr.addAttribute(.font, value: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), range: range)
        item.button?.attributedTitle = attr
    }

    func updateConnectionState(_ present: [String]) {
        var dict = UserDefaults.standard.dictionary(forKey: "connectedSince") as? [String: Double] ?? [:]
        let now = Date().timeIntervalSince1970
        for k in present where dict[k] == nil { dict[k] = now }
        for k in dict.keys where !present.contains(k) { dict.removeValue(forKey: k) }
        UserDefaults.standard.set(dict, forKey: "connectedSince")
        since = dict
    }

    @objc func togglePanel() {
        if let w = panel, w.isVisible { w.orderOut(nil); return }
        showPanel()
        DispatchQueue.global().async {
            let found = scanDrives()
            DispatchQueue.main.async {
                if found.map({ $0.key }) != self.drives.map({ $0.key }) {
                    self.drives = found
                    self.selected = min(self.selected, max(self.drives.count - 1, 0))
                }
                self.refresh()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.refresh() }
    }

    @objc func showPanel() {
        if panel == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 596),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "硬盘温度"
            w.appearance = NSAppearance(named: .darkAqua)
            w.isReleasedWhenClosed = false
            w.titlebarAppearsTransparent = true
            w.backgroundColor = hex(15, 17, 21)
            w.center()
            let v = DashboardView(frame: w.contentView!.bounds)
            v.autoresizingMask = [.width, .height]
            v.owner = self
            w.contentView?.addSubview(v)
            panel = w
            dashboard = v
        }
        NSApp.activate(ignoringOtherApps: true)
        if let w = panel, let b = item.button, let bw = b.window {
            let anchor = bw.convertToScreen(b.convert(b.bounds, to: nil))
            let vf = (bw.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            var f = w.frame
            f.origin.x = min(max(anchor.midX - f.width / 2, vf.minX + 8), vf.maxX - f.width - 8)
            f.origin.y = anchor.minY - f.height - 6
            if f.origin.y < vf.minY + 8 { f.origin.y = vf.minY + 8 }
            w.setFrame(f, display: false)
        }
        panel?.makeKeyAndOrderFront(nil)
        refreshPanel()
    }

    func refreshPanel() {
        guard let v = dashboard else { return }
        v.drives = drives
        v.selected = selected
        if selected < drives.count {
            let d = drives[selected]
            v.rows = loadRows(d.key, primaryKey, chartWindowPoints)
            v.latest = readings[d.key] ?? Readings()
            v.stats = stats
            if let ts = since[d.key] {
                v.connected = humanDuration(Date().timeIntervalSince1970 - ts)
            } else {
                v.connected = "未连接"
            }
            if !d.hasTemp {
                v.interfaceText = "USB（不透传 SMART）"
                v.emptyHint = "该设备的桥芯片不透传温度数据"
            } else if !d.isTB {
                v.interfaceText = "USB"
                v.emptyHint = "正在积累数据"
            } else {
                v.interfaceText = "雷雳 / USB4"
                v.emptyHint = "正在积累数据"
            }
        } else {
            v.rows = []
            v.latest = Readings()
            v.connected = "未连接"
            v.interfaceText = "无设备"
        }
        v.needsDisplay = true
    }

    func runAction(_ key: String) {
        if key.hasPrefix("select"), let i = Int(key.dropFirst(6)) {
            selected = min(max(i, 0), max(drives.count - 1, 0))
            if selected < drives.count { stats = todayStats(drives[selected].key, primaryKey) }
            refreshPanel()
            return
        }
        switch key {
        case "csv": openCSV()
        case "alert": openAlerts()
        case "report": makeReport()
        case "refresh": refresh()
        case "quit": NSApp.terminate(nil)
        default: break
        }
    }

    func checkAlert(_ d: Drive, _ r: Readings) {
        guard let s1 = r.s1 else { return }
        let th = threshold()
        let badWarn = r.warn != "0x00" && r.warn != "NA"
        guard s1 >= th || badWarn else { return }
        if let last = lastAlert[d.key], Date().timeIntervalSince(last) < 1800 { return }
        lastAlert[d.key] = Date()
        var msg = "\(d.shortName) 主控 \(s1)℃"
        if badWarn { msg += "，告警 \(r.warn)" }
        notifyUser(msg)
        let log = "\(stamp())  \(d.model) 主控=\(s1) \(badWarn ? "Critical Warning = \(r.warn)" : "超过阈值 \(th)℃")\n"
        if let h = FileHandle(forWritingAtPath: alertPath) {
            h.seekToEndOfFile(); h.write(log.data(using: .utf8)!); h.closeFile()
        } else {
            try? log.write(toFile: alertPath, atomically: true, encoding: .utf8)
        }
    }

    @objc func makeReport() {
        guard selected < drives.count else { return }
        let d = drives[selected]
        let rows = loadRows(d.key, primaryKey, 2000)
        let html = buildReportHTML(d, rows)
        let out = ("~/Library/Logs/TBTemp-report.html" as NSString).expandingTildeInPath
        try? html.write(toFile: out, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(URL(fileURLWithPath: out))
    }

    @objc func openCSV() { NSWorkspace.shared.open(URL(fileURLWithPath: csvPath)) }
    @objc func openAlerts() {
        if FileManager.default.fileExists(atPath: alertPath) {
            NSWorkspace.shared.open(URL(fileURLWithPath: alertPath))
        }
    }
    @objc func quit() { NSApp.terminate(nil) }
}


// MARK: - HTML 报告

func buildReportHTML(_ d: Drive, _ rows: [Row]) -> String {
    let w = 900.0, h = 340.0
    let left = 52.0, right = 16.0, top = 20.0, bottom = 28.0
    let pw = w - left - right, ph = h - top - bottom
    let lo = 20.0, hi = 90.0
    let n = rows.count

    func px(_ i: Int) -> Double { left + pw * Double(i) / Double(max(n - 1, 1)) }
    func py(_ v: Int) -> Double { top + ph - ph * (Double(v) - lo) / (hi - lo) }

    func poly(_ get: (Row) -> Int?) -> String {
        var pts: [String] = []
        for (i, r) in rows.enumerated() {
            guard let v = get(r) else { continue }
            pts.append(String(format: "%.1f,%.1f", px(i), py(v)))
        }
        return pts.joined(separator: " ")
    }

    var grid = ""
    var g = 20
    while g <= 90 {
        let y = py(g)
        grid += "<line x1=\"\(left)\" y1=\"\(y)\" x2=\"\(left + pw)\" y2=\"\(y)\" stroke=\"#2a2f3a\"/>"
        if g != 20 && g != 90 {
            grid += "<text x=\"\(left - 8)\" y=\"\(y + 4)\" fill=\"#8b93a1\" font-size=\"11\" text-anchor=\"end\">\(g)°</text>"
        }
        g += 10
    }
    let warnY = py(84)

    var ticks = ""
    for i in [0, n / 2, n - 1] where n > 0 && i >= 0 && i < n {
        let label = String(rows[i].t.suffix(8).prefix(5))
        ticks += "<text x=\"\(px(i))\" y=\"\(h - 8)\" fill=\"#8b93a1\" font-size=\"11\" text-anchor=\"middle\">\(label)</text>"
    }

    let temps = rows.compactMap { $0.s1 }
    let mx = temps.max() ?? 0
    let mn = temps.min() ?? 0
    let avg = temps.isEmpty ? 0 : temps.reduce(0, +) / temps.count

    return """
    <!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
    <title>\(d.model) 温度报告</title>
    <style>
      body{margin:0;padding:32px;background:#0f1115;color:#e6e8eb;
           font-family:-apple-system,"PingFang SC",sans-serif}
      h1{font-size:19px;margin:0 0 6px}
      .sub{color:#8b93a1;font-size:13px;margin-bottom:20px}
      .cards{display:flex;gap:10px;margin-bottom:18px;flex-wrap:wrap}
      .card{background:#171a21;border:1px solid #232833;border-radius:10px;padding:12px 16px}
      .card span{display:block;color:#8b93a1;font-size:12px;margin-bottom:6px}
      .card b{font-size:16px}
    </style></head><body>
    <h1>\(d.model)</h1>
    <div class="sub">序列号 \(d.serial)　接口 \(d.isTB ? "雷雳 / USB4" : "USB")　采样 \(n) 点　生成于 \(stamp())</div>
    <div class="cards">
      <div class="card"><span>最高主控</span><b>\(mx)℃</b></div>
      <div class="card"><span>最低主控</span><b>\(mn)℃</b></div>
      <div class="card"><span>平均主控</span><b>\(avg)℃</b></div>
      <div class="card"><span>超阈值次数</span><b>\(temps.filter { $0 >= threshold() }.count)</b></div>
    </div>
    <svg viewBox="0 0 \(w) \(h)" width="100%" style="max-width:\(w)px;background:#141821;border-radius:10px">
      \(grid)
      <line x1="\(left)" y1="\(warnY)" x2="\(left + pw)" y2="\(warnY)" stroke="#e5484d" stroke-dasharray="4 3" opacity="0.7"/>
      <text x="\(left + pw)" y="\(warnY - 5)" fill="#e5484d" font-size="10" text-anchor="end">84°</text>
      <polyline points="\(poly { $0.s2 })" fill="none" stroke="#3ecf8e" stroke-width="1.6"/>
      <polyline points="\(poly { $0.s1 })" fill="none" stroke="#ff9f43" stroke-width="2.2"/>
      \(ticks)
    </svg>
    <p style="color:#8b93a1;font-size:12px">橙线主控，绿线闪存。数据源 \(csvPath)</p>
    </body></html>
    """
}

// MARK: - 离屏渲染

if CommandLine.arguments.contains("--render") {
    let v = DashboardView(frame: NSRect(x: 0, y: 0, width: 320, height: 596))
    v.appearance = NSAppearance(named: .darkAqua)
    let ds = scanDrives()
    v.drives = ds
    let idx = (CommandLine.arguments.contains("--render-2") && ds.count > 1) ? 1 : 0
    v.selected = idx
    if ds.count > idx, true {
        let d = ds[idx]
        v.rows = loadRows(d.key, ds.first?.key, chartWindowPoints)
        v.latest = readDrive(d)
        v.stats = todayStats(d.key, ds.first?.key)
        let state = UserDefaults(suiteName: "com.leo.tbtemp")?.dictionary(forKey: "connectedSince") as? [String: Double] ?? [:]
        if let ts = state[d.key] {
            v.connected = humanDuration(Date().timeIntervalSince1970 - ts)
        }
        if !d.hasTemp {
            v.interfaceText = "USB（不透传 SMART）"
            v.emptyHint = "该设备的桥芯片不透传温度数据"
        } else {
            v.interfaceText = d.isTB ? "雷雳 / USB4" : "USB"
        }
    }
    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        if let d = rep.representation(using: .png, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: "/tmp/dash.png"))
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
