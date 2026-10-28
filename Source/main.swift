import AppKit
import QuartzCore
import ApplicationServices

struct TrackState {
    var title = "Spotify 黑膠"
    var artist = "播放一首歌，讓唱片轉起來"
    var artworkURL = ""
    var playing = false
    var available = false
    var permissionDenied = false
}

final class SpotifyBridge {
    private let queue = DispatchQueue(label: "vinyl.spotify")
    private var busy = false
    var onUpdate: ((TrackState) -> Void)?
    static var running: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first
    }
    func refresh() {
        guard !busy else { return }
        guard Self.running != nil else {
            onUpdate?(TrackState(title: "Spotify 尚未開啟", artist: "點一下中央按鈕開啟 Spotify"))
            return
        }
        busy = true
        queue.async {
            var error: NSDictionary?
            let source = """
            with timeout of 3 seconds
                tell application id "com.spotify.client"
                    set isPlaying to (player state is playing)
                    try
                        set t to current track
                        return {isPlaying, name of t, artist of t, artwork url of t}
                    on error
                        return {isPlaying, "Spotify", "請先在 Spotify 選擇歌曲", ""}
                    end try
                end tell
            end timeout
            """
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            var state = TrackState()
            if let error = error {
                let denied = (error[NSAppleScript.errorNumber] as? Int) == -1743
                state.title = denied ? "需要 Spotify 控制權限" : "正在等待 Spotify"
                state.artist = denied ? "從選單列開啟自動化設定" : "Spotify 回應錯誤 \(error[NSAppleScript.errorNumber] ?? "未知")"
                NSLog("Spotify bridge: %@", error)
                state.permissionDenied = denied
            } else if let result = result, result.numberOfItems == 4 {
                state.playing = result.atIndex(1)?.booleanValue ?? false
                state.title = result.atIndex(2)?.stringValue ?? "Spotify"
                state.artist = result.atIndex(3)?.stringValue ?? ""
                state.artworkURL = result.atIndex(4)?.stringValue ?? ""
                state.available = true
            }
            let finalState = state
            DispatchQueue.main.async {
                self.busy = false
                self.onUpdate?(finalState)
            }
        }
    }
    func command(_ command: String) {
        guard ["playpause", "next track", "previous track"].contains(command) else { return }
        guard Self.running != nil else { openSpotify(); return }
        queue.async {
            var error: NSDictionary?
            NSAppleScript(source: "with timeout of 3 seconds\n tell application id \"com.spotify.client\" to \(command)\nend timeout")?.executeAndReturnError(&error)
            DispatchQueue.main.async { self.refresh() }
        }
    }
    func openSpotify() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

final class VinylPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class VinylView: NSView {
    var state = TrackState() { didSet { updateArtwork(); needsDisplay = true; updateAccessibility() } }
    var command: ((String) -> Void)?
    var contextMenu: (() -> NSMenu)?
    var onDragEnd: (() -> Void)?
    private var artwork: NSImage?
    private var artworkURL = ""
    private var artworkTask: URLSessionDataTask?
    private var hovering = false
    private var hoverAmount: CGFloat = 0
    private var angle: CGFloat = 0
    private var lastTime = CACurrentMediaTime()
    private var animationTimer: Timer?
    private var tracking: NSTrackingArea?
    private var mouseStart = NSPoint.zero
    private var windowStart = NSPoint.zero
    private var dragging = false
    private var pressed: Int?
    private var buttons: [NSButton] = []
    var disc: NSRect { NSRect(x: 18, y: 18, width: bounds.width - 36, height: bounds.height - 36) }
    var isHoveredForTesting: Bool { hovering }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        for (i, label) in ["上一首", "播放或暫停", "下一首"].enumerated() {
            let button = NSButton(title: "", target: self, action: #selector(accessibleAction(_:)))
            button.tag = i
            button.isBordered = false
            button.image = NSImage(size: NSSize(width: 1, height: 1))
            button.setAccessibilityLabel(label)
            button.toolTip = label
            button.isHidden = true
            addSubview(button)
            buttons.append(button)
        }
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { animationTimer?.invalidate(); artworkTask?.cancel() }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func layout() {
        super.layout()
        for (i, button) in buttons.enumerated() { button.frame = buttonRect(i) }
    }
    @objc private func accessibleAction(_ button: NSButton) { activate(button.tag) }
    private func activate(_ index: Int) { command?(["previous track", "playpause", "next track"][index]) }
    private func updateAccessibility() {
        setAccessibilityLabel("\(state.title)，\(state.artist)")
        buttons[1].setAccessibilityLabel(state.playing ? "暫停" : "播放")
    }
    override func updateTrackingAreas() {
        if let tracking = tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }
    private func insideDisc(_ point: NSPoint) -> Bool {
        hypot(point.x - disc.midX, point.y - disc.midY) <= disc.width / 2
    }
    func setHover(_ value: Bool, immediately: Bool = false) {
        hovering = value
        if immediately { hoverAmount = value ? 1 : 0 }
        buttons.forEach { $0.isHidden = !value }
        needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) { setHover(insideDisc(convert(event.locationInWindow, from: nil))) }
    override func mouseMoved(with event: NSEvent) { setHover(insideDisc(convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    override func resetCursorRects() { addCursorRect(disc, cursor: .openHand) }
    override func rightMouseDown(with event: NSEvent) {
        if let menu = contextMenu?() { NSMenu.popUpContextMenu(menu, with: event, for: self) }
    }
    override func mouseDown(with event: NSEvent) {
        mouseStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin ?? .zero
        dragging = false
        let point = convert(event.locationInWindow, from: nil)
        pressed = hovering ? (0..<3).first(where: { buttonRect($0).contains(point) }) : nil
    }
    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        let delta = NSPoint(x: mouse.x - mouseStart.x, y: mouse.y - mouseStart.y)
        guard hypot(delta.x, delta.y) > 3 || dragging else { return }
        dragging = true
        pressed = nil
        NSCursor.closedHand.set()
        window?.setFrameOrigin(NSPoint(x: windowStart.x + delta.x, y: windowStart.y + delta.y))
    }
    override func mouseUp(with event: NSEvent) {
        if dragging { onDragEnd?() }
        else if let pressed = pressed, buttonRect(pressed).contains(convert(event.locationInWindow, from: nil)) { activate(pressed) }
        dragging = false
        pressed = nil
        NSCursor.openHand.set()
    }
    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTime, 0.1)
        lastTime = now
        guard window?.isVisible == true else { return }
        let target: CGFloat = hovering ? 1 : 0
        let changed = abs(hoverAmount - target) > 0.005
        if changed { hoverAmount += (target - hoverAmount) * min(CGFloat(dt) * 13, 1) }
        else { hoverAmount = target }
        let spin = state.playing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if spin { angle = (angle - CGFloat(dt) * 18).truncatingRemainder(dividingBy: 360) }
        if changed || spin { needsDisplay = true }
    }
    private func updateArtwork() {
        guard state.artworkURL != artworkURL else { return }
        artworkURL = state.artworkURL
        artworkTask?.cancel()
        artwork = nil
        guard let url = URL(string: artworkURL), url.scheme == "https" else { return }
        let expected = artworkURL
        artworkTask = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data = data, data.count < 12_000_000,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self = self, self.artworkURL == expected else { return }
                self.artwork = image
                self.needsDisplay = true
            }
        }
        artworkTask?.resume()
    }
    private func buttonRect(_ index: Int) -> NSRect {
        let s = disc.width / 240
        let size: CGFloat = index == 1 ? 44 : 36
        return NSRect(x: disc.midX + CGFloat(index - 1) * 52 * s - size * s / 2,
                      y: disc.midY - 28 * s - size * s / 2, width: size * s, height: size * s)
    }
    private func circle(_ rect: NSRect, _ color: NSColor) {
        color.setFill(); NSBezierPath(ovalIn: rect).fill()
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        let d = disc
        let center = NSPoint(x: d.midX, y: d.midY)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.40)
        shadow.shadowBlurRadius = 13; shadow.shadowOffset = NSSize(width: 0, height: -5); shadow.set()
        circle(d, NSColor(white: 0.055, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
        let body = NSBezierPath(ovalIn: d)
        NSGradient(colors: [NSColor(white: 0.18, alpha: 1), NSColor(white: 0.055, alpha: 1), NSColor(white: 0.105, alpha: 1)])!.draw(in: body, angle: -35)
        NSColor.white.withAlphaComponent(0.22).setStroke(); body.lineWidth = 0.8; body.stroke()
        NSGraphicsContext.saveGraphicsState()
        body.addClip()
        let ctx = NSGraphicsContext.current!.cgContext
        // Soft opposed highlights, like light crossing pressed vinyl grooves.
        for k in 0..<66 {
            let alpha = 0.0027 * sin(CGFloat(k) / 66 * .pi)
            let a = CGFloat(k) * .pi / 180
            let radius = d.width
            let p = NSBezierPath(); p.move(to: center)
            p.line(to: NSPoint(x: center.x + cos(a + 0.5) * radius, y: center.y + sin(a + 0.5) * radius))
            p.line(to: NSPoint(x: center.x + cos(a + 0.58) * radius, y: center.y + sin(a + 0.58) * radius)); p.close()
            NSColor.white.withAlphaComponent(alpha * 18).setFill(); p.fill()
            let mirror = AffineTransform(translationByX: center.x, byY: center.y)
            var t = mirror; t.rotate(byDegrees: 180); t.translate(x: -center.x, y: -center.y)
            p.transform(using: t); p.fill()
        }
        for i in 0..<39 {
            let inset = CGFloat(7 + i * 2) * d.width / 240
            let ring = NSBezierPath(ovalIn: d.insetBy(dx: inset, dy: inset))
            ring.lineWidth = i % 4 == 0 ? 0.7 : 0.4
            NSColor(white: i % 2 == 0 ? 1 : 0, alpha: i % 4 == 0 ? 0.10 : 0.17).setStroke(); ring.stroke()
        }
        let label = d.insetBy(dx: d.width * 0.285, dy: d.height * 0.285)
        circle(label.insetBy(dx: -3, dy: -3), NSColor.black.withAlphaComponent(0.8))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: label).addClip()
        ctx.translateBy(x: center.x, y: center.y); ctx.rotate(by: angle * .pi / 180); ctx.translateBy(x: -center.x, y: -center.y)
        if let artwork = artwork {
            let side = min(artwork.size.width, artwork.size.height)
            let source = NSRect(x: (artwork.size.width - side) / 2, y: (artwork.size.height - side) / 2, width: side, height: side)
            artwork.draw(in: label, from: source, operation: .sourceOver, fraction: 1)
        } else {
            NSGradient(colors: [NSColor(calibratedRed: 0.56, green: 0.68, blue: 0.49, alpha: 1), NSColor(calibratedRed: 0.12, green: 0.24, blue: 0.19, alpha: 1)])!.draw(in: NSBezierPath(ovalIn: label), angle: -60)
            drawText("SIDE A", in: NSRect(x: label.minX, y: center.y + 19, width: label.width, height: 15), size: 9, color: .white.withAlphaComponent(0.85), weight: .medium)
            drawText("VINYL", in: NSRect(x: label.minX, y: center.y - 30, width: label.width, height: 15), size: 10, color: .white.withAlphaComponent(0.85), weight: .semibold)
        }
        NSGraphicsContext.restoreGraphicsState()
        circle(NSRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10), NSColor(white: 0.05, alpha: 1))
        circle(NSRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4), NSColor(white: 0.55, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
        if hoverAmount > 0.005 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current!.cgContext.setAlpha(hoverAmount)
            circle(d, NSColor.black.withAlphaComponent(0.72))
            let s = d.width / 240
            drawText(state.title, in: NSRect(x: d.minX + 28 * s, y: center.y + 31 * s, width: d.width - 56 * s, height: 23 * s), size: max(14, 13 * s), color: .white, weight: .semibold)
            drawText(state.artist, in: NSRect(x: d.minX + 30 * s, y: center.y + 11 * s, width: d.width - 60 * s, height: 18 * s), size: max(11.5, 10 * s), color: .white.withAlphaComponent(0.70), weight: .regular)
            for i in 0..<3 {
                let r = buttonRect(i)
                circle(r, i == 1 ? .white : .white.withAlphaComponent(0.10))
                let symbol = i == 0 ? "backward.end.fill" : i == 2 ? "forward.end.fill" : state.playing ? "pause.fill" : "play.fill"
                let config = NSImage.SymbolConfiguration(pointSize: (i == 1 ? 17 : 13) * s, weight: .semibold)
                if let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config.applying(NSImage.SymbolConfiguration(paletteColors: [i == 1 ? .black : .white]))) {
                    let size = icon.size
                    let target = NSRect(x: r.midX - size.width / 2, y: r.midY - size.height / 2, width: size.width, height: size.height)
                    icon.draw(in: target)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }
    private func drawText(_ value: String, in rect: NSRect, size: CGFloat, color: NSColor, weight: NSFont.Weight) {
        let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byTruncatingTail
        (value as NSString).draw(in: rect, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var panel: VinylPanel!
    var record: VinylView!
    var statusItem: NSStatusItem!
    let bridge = SpotifyBridge()
    var pollTimer: Timer?
    var visibilityTimer: Timer?
    let preview = CommandLine.arguments.contains("--preview")
    var manuallyHidden = false
    var automatic: Bool {
        get { UserDefaults.standard.bool(forKey: "autoVisibility") }
        set { UserDefaults.standard.set(newValue, forKey: "autoVisibility") }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = preview ? 276 : UserDefaults.standard.double(forKey: "diameter")
        let side: CGFloat = size >= 196 && size <= 356 ? size : 276
        panel = VinylPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true; panel.isMovableByWindowBackground = false
        panel.delegate = self
        record = VinylView(frame: panel.contentView!.bounds)
        record.autoresizingMask = [.width, .height]
        panel.contentView = record
        record.command = { [weak self] command in self?.bridge.command(command) }
        record.contextMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        record.onDragEnd = { [weak self] in self?.keepOnScreen(); self?.savePosition() }
        resetPosition(restore: !preview)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "opticaldisc", accessibilityDescription: "Vinyl 黑膠播放器")
        statusItem.button?.toolTip = "Vinyl · Spotify 黑膠"
        statusItem.menu = makeMenu()
        bridge.onUpdate = { [weak self] state in self?.record.state = state }
        panel.orderFrontRegardless()
        if preview {
            record.state = TrackState(title: "Your music. On vinyl.", artist: "Spotify · Vinyl", playing: false, available: true)
            runPreview()
            return
        }
        bridge.refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.bridge.refresh() }
        visibilityTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.updateVisibility() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, checked: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
            item.state = checked ? .on : .off; menu.addItem(item)
        }
        let title = NSMenuItem(title: "Vinyl · Spotify 黑膠", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        menu.addItem(.separator())
        add(manuallyHidden ? "顯示唱片" : "隱藏唱片", #selector(toggleVisible))
        add("Spotify 收起後才顯示", #selector(toggleAutomatic), checked: automatic)
        add("開啟 Spotify", #selector(openSpotify))
        menu.addItem(.separator())
        add("小唱片", #selector(small)); add("中唱片", #selector(medium)); add("大唱片", #selector(large))
        add("重設位置", #selector(reset))
        menu.addItem(.separator())
        add("自動化權限設定…", #selector(permissions))
        add("結束 Vinyl", #selector(quit))
        return menu
    }
    func updateVisibility() {
        var show = !manuallyHidden
        if automatic, show {
            if let app = SpotifyBridge.running {
                // Window metadata needs no Accessibility permission. Minimized/hidden windows are absent.
                let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
                let spotifyVisible = windows.contains { info in
                    guard (info[kCGWindowOwnerPID as String] as? Int) == Int(app.processIdentifier),
                          (info[kCGWindowLayer as String] as? Int) == 0,
                          let bounds = info[kCGWindowBounds as String] as? [String: Any],
                          let w = bounds["Width"] as? Double, let h = bounds["Height"] as? Double else { return false }
                    return w > 200 && h > 200
                }
                show = !spotifyVisible
            } else { show = false }
        }
        if show && !panel.isVisible { panel.orderFrontRegardless() }
        else if !show && panel.isVisible { panel.orderOut(nil) }
    }
    func savePosition() {
        guard !preview else { return }
        UserDefaults.standard.set(panel.frame.minX, forKey: "windowX")
        UserDefaults.standard.set(panel.frame.minY, forKey: "windowY")
    }
    func keepOnScreen() {
        let screen = NSScreen.screens.max { a, b in
            let ia = a.visibleFrame.intersection(panel.frame), ib = b.visibleFrame.intersection(panel.frame)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: min(max(panel.frame.minX, frame.minX), frame.maxX - panel.frame.width), y: min(max(panel.frame.minY, frame.minY), frame.maxY - panel.frame.height))
        panel.setFrameOrigin(origin)
    }
    func resetPosition(restore: Bool) {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        var origin = NSPoint(x: visible.maxX - panel.frame.width - 26, y: visible.minY + 50)
        if restore && UserDefaults.standard.object(forKey: "windowX") != nil {
            origin = NSPoint(x: UserDefaults.standard.double(forKey: "windowX"), y: UserDefaults.standard.double(forKey: "windowY"))
        }
        panel.setFrameOrigin(origin); keepOnScreen()
    }
    @objc func toggleVisible() { manuallyHidden.toggle(); if !manuallyHidden { automatic = false }; updateVisibility(); statusItem.menu = makeMenu() }
    @objc func toggleAutomatic() { automatic.toggle(); manuallyHidden = false; updateVisibility(); statusItem.menu = makeMenu() }
    @objc func openSpotify() { bridge.openSpotify() }
    @objc func small() { resize(216) }
    @objc func medium() { resize(276) }
    @objc func large() { resize(336) }
    func resize(_ side: CGFloat) {
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        panel.setFrame(NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side), display: true)
        if !preview { UserDefaults.standard.set(side, forKey: "diameter") }; keepOnScreen(); savePosition()
    }
    @objc func reset() { resetPosition(restore: false); savePosition(); manuallyHidden = false; automatic = false; updateVisibility(); statusItem.menu = makeMenu() }
    @objc func screenChanged() { keepOnScreen() }
    @objc func permissions() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!) }
    @objc func quit() { NSApplication.shared.terminate(nil) }
    func runPreview() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let output = ProcessInfo.processInfo.environment["VINYL_PREVIEW_DIR"] ?? NSTemporaryDirectory()
            for (name, hover) in [("vinyl-idle.png", false), ("vinyl-hover.png", true)] {
                self.record.setHover(hover, immediately: true)
                self.record.displayIfNeeded()
                if let bitmap = self.record.bitmapImageRepForCachingDisplay(in: self.record.bounds) {
                    self.record.cacheDisplay(in: self.record.bounds, to: bitmap)
                    try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
                }
            }
            precondition(self.record.isHoveredForTesting)
            self.record.setHover(false, immediately: true)
            precondition(!self.record.isHoveredForTesting)
            self.resize(216); precondition(self.panel.frame.width == 216)
            self.resize(276); precondition(self.panel.frame.width == 276)
            self.panel.setFrameOrigin(NSPoint(x: -50000, y: -50000)); self.keepOnScreen()
            precondition(NSScreen.screens.contains { $0.visibleFrame.intersects(self.panel.frame) })
            print("PASS: idle/hover rendering, hover state, resizing, off-screen recovery")
            NSApplication.shared.terminate(nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
