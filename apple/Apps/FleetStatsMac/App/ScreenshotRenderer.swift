#if DEBUG
import AppKit
import FleetKit
import SwiftUI

@MainActor
enum ScreenshotRenderer {
    static func renderAll(to outputDir: URL) {
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let (store, updater, supervisor) = makeDemoEnvironment()
        let mbpID = store.hosts[0].id
        let linuxID = store.hosts[2].id

        // 1. Render individual real SwiftUI views at 2x Retina in dark mode
        let menuBarImg = renderView(
            MenuBarStripView(store: store, config: MenuBarStripConfig(), onSelectZone: { _ in })
                .frame(height: 26),
            size: NSSize(width: 196, height: 26)
        )

        store.selectedHostID = mbpID
        store.selectedTab = .cpu
        store.showingEvents = false
        let cpuPopover = renderView(
            PopoverRootView(store: store, updater: updater, onOpenSettings: {}, onQuit: {}),
            size: NSSize(width: 430, height: 540),
            windowBackground: NSColor(red: 0.115, green: 0.122, blue: 0.145, alpha: 1.0)
        )

        store.selectedHostID = linuxID
        store.selectedTab = .ram
        let ramPopover = renderView(
            PopoverRootView(store: store, updater: updater, onOpenSettings: {}, onQuit: {}),
            size: NSSize(width: 430, height: 540),
            windowBackground: NSColor(red: 0.115, green: 0.122, blue: 0.145, alpha: 1.0)
        )

        store.selectedHostID = mbpID
        store.selectedTab = .ssd
        let ssdPopover = renderView(
            PopoverRootView(store: store, updater: updater, onOpenSettings: {}, onQuit: {}),
            size: NSSize(width: 430, height: 540),
            windowBackground: NSColor(red: 0.115, green: 0.122, blue: 0.145, alpha: 1.0)
        )

        store.selectedHostID = mbpID
        store.selectedTab = .network
        let netPopover = renderView(
            PopoverRootView(store: store, updater: updater, onOpenSettings: {}, onQuit: {}),
            size: NSSize(width: 430, height: 540),
            windowBackground: NSColor(red: 0.115, green: 0.122, blue: 0.145, alpha: 1.0)
        )

        let settingsImg = renderView(
            SettingsView(store: store, supervisor: supervisor, updater: updater, selectedPane: .fleet)
                .frame(width: 760, height: 560),
            size: NSSize(width: 760, height: 560),
            windowBackground: NSColor(red: 0.125, green: 0.130, blue: 0.150, alpha: 1.0)
        )

        // 2. Compose polished Retina presentation frames
        let hero = composeHero(menuBar: menuBarImg, leftPopover: ramPopover, rightPopover: cpuPopover)
        savePNG(hero, to: outputDir.appendingPathComponent("hero.png"))

        let ssdNet = composeDualPopovers(
            leftPopover: ssdPopover,
            rightPopover: netPopover,
            leftCaption: "Storage · Internal + External Volumes & Live I/O",
            rightCaption: "Network · Interfaces, Tailscale IPs & Top Processes"
        )
        savePNG(ssdNet, to: outputDir.appendingPathComponent("ssd-network.png"))

        let settingsFrame = composeSettings(settingsImage: settingsImg)
        savePNG(settingsFrame, to: outputDir.appendingPathComponent("settings.png"))

        NSLog("FleetStats: rendered README screenshots to \(outputDir.path)")
    }

    // MARK: - View Capture via Real NSWindow + NSHostingView (2x Retina Dark Mode)

    private static func renderView<V: View>(
        _ view: V,
        size: NSSize,
        windowBackground: NSColor = .clear
    ) -> NSImage {
        let darkAppearance = NSAppearance(named: .darkAqua)
        let framed = view
            .environment(\.colorScheme, .dark)
            .frame(width: size.width, height: size.height)

        let hosting = NSHostingView(rootView: framed)
        hosting.appearance = darkAppearance
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = windowBackground.cgColor

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -4000, y: -4000), size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = darkAppearance
        window.backgroundColor = windowBackground
        window.isOpaque = windowBackground.alphaComponent >= 0.99
        window.contentView = hosting
        window.orderFrontRegardless()

        // Allow SwiftUI & Swift Charts a few runloop ticks to lay out completely
        for _ in 0..<8 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            hosting.layoutSubtreeIfNeeded()
        }

        let scale: CGFloat = 2.0
        let pxW = Int(size.width * scale)
        let pxH = Int(size.height * scale)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pxW,
            pixelsHigh: pxH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            window.orderOut(nil)
            return NSImage(size: size)
        }
        rep.size = size

        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)

        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: - Presentation Compositors

    private static func composeHero(menuBar: NSImage, leftPopover: NSImage, rightPopover: NSImage) -> NSImage {
        let size = NSSize(width: 1060, height: 690)
        return drawCanvas(size: size) { ctx in
            drawBackdrop(ctx: ctx, size: size)

            // Authentic macOS dark menu bar strip across top
            let barH: CGFloat = 32
            let barRect = NSRect(x: 0, y: size.height - barH, width: size.width, height: barH)
            NSColor(red: 0.08, green: 0.10, blue: 0.16, alpha: 0.88).setFill()
            barRect.fill()
            NSColor.white.withAlphaComponent(0.10).setFill()
            NSRect(x: 0, y: size.height - barH, width: size.width, height: 1).fill()

            // Left menu bar hints
            let menuAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: NSColor.white.withAlphaComponent(0.88)
            ]
            let regularMenuAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.75)
            ]
            "".draw(at: NSPoint(x: 18, y: size.height - 23), withAttributes: menuAttrs)
            "Finder".draw(at: NSPoint(x: 42, y: size.height - 23), withAttributes: menuAttrs)
            "File    Edit    View    Go    Window    Help".draw(at: NSPoint(x: 98, y: size.height - 23), withAttributes: regularMenuAttrs)

            // Right menu bar clock
            "Wed 11:42 AM".draw(at: NSPoint(x: size.width - 102, y: size.height - 23), withAttributes: regularMenuAttrs)

            // Highlighted pill around our real MenuBarStripView on the right side (authentic macOS),
            // aligned directly over the right (Local Mac) popover
            let popY: CGFloat = 68
            let leftX: CGFloat = 75
            let rightX: CGFloat = 555

            let stripW: CGFloat = 196
            let stripX: CGFloat = rightX + 215 - stripW / 2
            let pillRect = NSRect(x: stripX - 6, y: size.height - barH + 2, width: stripW + 12, height: barH - 4)
            let pillPath = NSBezierPath(roundedRect: pillRect, xRadius: 5, yRadius: 5)
            NSColor.white.withAlphaComponent(0.14).setFill()
            pillPath.fill()
            menuBar.draw(in: NSRect(x: stripX, y: size.height - barH + 3, width: stripW, height: 26))

            // Subtle popover triangle pointing from MenuBarStripView down to the right popover
            let arrowX = rightX + 215
            let arrowPath = NSBezierPath()
            arrowPath.move(to: NSPoint(x: arrowX - 10, y: popY + 540))
            arrowPath.line(to: NSPoint(x: arrowX, y: popY + 551))
            arrowPath.line(to: NSPoint(x: arrowX + 10, y: popY + 540))
            arrowPath.close()
            NSColor(red: 0.115, green: 0.122, blue: 0.145, alpha: 1.0).setFill()
            arrowPath.fill()

            drawWindowCard(ctx: ctx, image: leftPopover, at: NSPoint(x: leftX, y: popY), cornerRadius: 14, drawTrafficLights: false)
            drawWindowCard(ctx: ctx, image: rightPopover, at: NSPoint(x: rightX, y: popY), cornerRadius: 14, drawTrafficLights: false)

            // Crisp bottom captions
            drawCaption("Remote Linux via Tailscale · PSI Memory Pressure & OOM Scores", centerX: leftX + 215, y: 26)
            drawCaption("Local Mac · Menu Bar Strip, Apple Silicon P/E Cores & Live Telemetry", centerX: rightX + 215, y: 26)
        }
    }

    private static func composeDualPopovers(
        leftPopover: NSImage,
        rightPopover: NSImage,
        leftCaption: String,
        rightCaption: String
    ) -> NSImage {
        let size = NSSize(width: 1060, height: 650)
        return drawCanvas(size: size) { ctx in
            drawBackdrop(ctx: ctx, size: size)
            let leftX: CGFloat = 75
            let rightX: CGFloat = 555
            let popY: CGFloat = 66
            drawWindowCard(ctx: ctx, image: leftPopover, at: NSPoint(x: leftX, y: popY), cornerRadius: 14, drawTrafficLights: false)
            drawWindowCard(ctx: ctx, image: rightPopover, at: NSPoint(x: rightX, y: popY), cornerRadius: 14, drawTrafficLights: false)
            drawCaption(leftCaption, centerX: leftX + 215, y: 24)
            drawCaption(rightCaption, centerX: rightX + 215, y: 24)
        }
    }

    private static func composeSettings(settingsImage: NSImage) -> NSImage {
        let size = NSSize(width: 920, height: 670)
        return drawCanvas(size: size) { ctx in
            drawBackdrop(ctx: ctx, size: size)
            let winX = (size.width - settingsImage.size.width) / 2
            let winY: CGFloat = 62
            drawWindowCard(ctx: ctx, image: settingsImage, at: NSPoint(x: winX, y: winY), cornerRadius: 12, drawTrafficLights: true)
            drawCaption("Fleet Management · 1-Click Tailscale Discovery & Per-Machine Alert Thresholds", centerX: size.width / 2, y: 22)
        }
    }

    private static func drawCanvas(size: NSSize, draw: (CGContext) -> Void) -> NSImage {
        let scale: CGFloat = 2.0
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        let gctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = gctx
        gctx.cgContext.interpolationQuality = .high
        draw(gctx.cgContext)
        NSGraphicsContext.restoreGraphicsState()

        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    private static func drawBackdrop(ctx: CGContext, size: NSSize) {
        let rect = NSRect(origin: .zero, size: size)
        let bgPath = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
        bgPath.addClip()

        let grad = NSGradient(colors: [
            NSColor(red: 0.055, green: 0.085, blue: 0.165, alpha: 1.0),
            NSColor(red: 0.085, green: 0.125, blue: 0.225, alpha: 1.0),
            NSColor(red: 0.045, green: 0.070, blue: 0.135, alpha: 1.0)
        ])
        grad?.draw(in: rect, angle: -32)

        // Soft ambient color glows matching the FleetStats Telemetry Ring palette
        ctx.saveGState()
        let space = CGColorSpaceCreateDeviceRGB()
        if let cyanGlow = CGGradient(
            colorsSpace: space,
            colors: [
                NSColor(red: 0.15, green: 0.65, blue: 0.98, alpha: 0.22).cgColor,
                NSColor(red: 0.15, green: 0.65, blue: 0.98, alpha: 0.0).cgColor
            ] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawRadialGradient(
                cyanGlow,
                startCenter: CGPoint(x: size.width * 0.22, y: size.height * 0.78),
                startRadius: 0,
                endCenter: CGPoint(x: size.width * 0.22, y: size.height * 0.78),
                endRadius: size.width * 0.45,
                options: []
            )
        }
        if let indigoGlow = CGGradient(
            colorsSpace: space,
            colors: [
                NSColor(red: 0.48, green: 0.34, blue: 0.98, alpha: 0.20).cgColor,
                NSColor(red: 0.48, green: 0.34, blue: 0.98, alpha: 0.0).cgColor
            ] as CFArray,
            locations: [0, 1]
        ) {
            ctx.drawRadialGradient(
                indigoGlow,
                startCenter: CGPoint(x: size.width * 0.80, y: size.height * 0.25),
                startRadius: 0,
                endCenter: CGPoint(x: size.width * 0.80, y: size.height * 0.25),
                endRadius: size.width * 0.48,
                options: []
            )
        }
        ctx.restoreGState()
    }

    private static func drawWindowCard(
        ctx: CGContext,
        image: NSImage,
        at origin: NSPoint,
        cornerRadius: CGFloat,
        drawTrafficLights: Bool
    ) {
        let rect = NSRect(origin: origin, size: image.size)

        // Soft ambient drop shadow
        ctx.saveGState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowOffset = NSSize(width: 0, height: -14)
        shadow.shadowBlurRadius = 32
        shadow.set()
        NSColor(red: 0.115, green: 0.122, blue: 0.145, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        ctx.restoreGState()

        // Clipped window content
        ctx.saveGState()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        image.draw(in: rect)

        if drawTrafficLights {
            let colors: [NSColor] = [
                NSColor(red: 1.0, green: 0.37, blue: 0.34, alpha: 1.0),
                NSColor(red: 1.0, green: 0.74, blue: 0.18, alpha: 1.0),
                NSColor(red: 0.15, green: 0.79, blue: 0.25, alpha: 1.0)
            ]
            for (i, c) in colors.enumerated() {
                let dotRect = NSRect(
                    x: rect.minX + 14 + CGFloat(i) * 20,
                    y: rect.maxY - 22,
                    width: 12,
                    height: 12
                )
                c.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
        }
        ctx.restoreGState()

        // Crisp macOS glass hairline border
        let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        border.lineWidth = 1.0
        NSColor.white.withAlphaComponent(0.16).setStroke()
        border.stroke()
    }

    private static func drawCaption(_ text: String, centerX: CGFloat, y: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.76)
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let sz = str.size()
        str.draw(at: NSPoint(x: centerX - sz.width / 2, y: y))
    }

    private static func savePNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    // MARK: - Realistic Privacy-Safe Demo Fleet Data

    private static func makeDemoEnvironment() -> (FleetStore, AppUpdater, LocalAgentSupervisor) {
        let store = FleetStore()
        let updater = AppUpdater()
        let supervisor = LocalAgentSupervisor()

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)

        let mbp = FleetHostConfig(name: "mbp", address: "127.0.0.1", port: 9470, isLocal: true, enabled: true)
        let mini = FleetHostConfig(name: "mini", address: "mini.tailnet.ts.net", port: 9470, isLocal: false, enabled: true)
        let linux = FleetHostConfig(name: "tower", address: "tower.tailnet.ts.net", port: 9470, isLocal: false, enabled: true)
        let imac = FleetHostConfig(name: "imac", address: "imac.tailnet.ts.net", port: 9470, isLocal: false, enabled: true)

        store.hosts = [mbp, mini, linux, imac]
        store.states = [:]
        // Prevent any stray unread badge if local agent responds during offscreen layout
        for h in store.hosts {
            store.clearedBeforeMs[h.id] = nowMs + 86_400_000
        }

        let mbpState = HostRuntimeState()
        mbpState.status = .online
        mbpState.agentVersion = "0.1.15"
        mbpState.lastSeenAt = Date()
        mbpState.snapshot = decodeSnapshot(makeMacBookSnapshotJSON(nowMs: nowMs))
        mbpState.livePoints = makeHistory(nowMs: nowMs, cpuBase: 32, memBase: 58, netUpBase: 410_000, netDownBase: 4_350_000)
        store.states[mbp.id] = mbpState

        let miniState = HostRuntimeState()
        miniState.status = .online
        miniState.agentVersion = "0.1.15"
        miniState.lastSeenAt = Date()
        miniState.snapshot = decodeSnapshot(makeMacMiniSnapshotJSON(nowMs: nowMs))
        miniState.livePoints = makeHistory(nowMs: nowMs, cpuBase: 14, memBase: 44, netUpBase: 85_000, netDownBase: 320_000)
        store.states[mini.id] = miniState

        let linuxState = HostRuntimeState()
        linuxState.status = .online
        linuxState.agentVersion = "0.1.14"
        linuxState.lastSeenAt = Date()
        linuxState.snapshot = decodeSnapshot(makeLinuxSnapshotJSON(nowMs: nowMs))
        linuxState.livePoints = makeHistory(nowMs: nowMs, cpuBase: 61, memBase: 74, netUpBase: 1_200_000, netDownBase: 6_400_000)
        store.states[linux.id] = linuxState

        let imacState = HostRuntimeState()
        imacState.status = .online
        imacState.agentVersion = "0.1.15"
        imacState.lastSeenAt = Date()
        imacState.snapshot = decodeSnapshot(makeIMacSnapshotJSON(nowMs: nowMs))
        imacState.livePoints = makeHistory(nowMs: nowMs, cpuBase: 18, memBase: 51, netUpBase: 40_000, netDownBase: 180_000)
        store.states[imac.id] = imacState

        store.selectedHostID = mbp.id
        return (store, updater, supervisor)
    }

    private static func decodeSnapshot(_ json: String) -> HostSnapshot {
        try! FleetJSON.makeDecoder().decode(HostSnapshot.self, from: Data(json.utf8))
    }

    private static func makeHistory(
        nowMs: Int64,
        cpuBase: Double,
        memBase: Double,
        netUpBase: Double,
        netDownBase: Double
    ) -> [HistoryPoint] {
        var pts: [HistoryPoint] = []
        let count = 60
        for i in 0..<count {
            let t = Double(i) / Double(count)
            let ts = nowMs - Int64((count - i) * 2000)
            let wave = sin(t * .pi * 5.0) * 11.0 + cos(t * .pi * 11.0) * 5.0
            let cpu = max(4.0, min(95.0, cpuBase + wave))
            let mem = max(20.0, min(95.0, memBase + sin(t * .pi * 2.0) * 3.5))
            let upWave = 0.72 + 0.28 * sin(t * .pi * 4.2 + 0.4) + 0.14 * cos(t * .pi * 9.0)
            let downWave = 0.70 + 0.30 * sin(t * .pi * 3.4 - 0.6) + 0.16 * cos(t * .pi * 7.6)
            let up = UInt64(max(12_000, netUpBase * upWave))
            let down = UInt64(max(45_000, netDownBase * downWave))
            let readWave = 0.65 + 0.32 * sin(t * .pi * 3.8) + 0.15 * cos(t * .pi * 8.5)
            let writeWave = 0.60 + 0.28 * cos(t * .pi * 4.4 + 0.8) + 0.14 * sin(t * .pi * 9.2)
            let readBps = UInt64(max(4_000_000, 34_000_000 * readWave))
            let writeBps = UInt64(max(2_000_000, 18_000_000 * writeWave))
            let json = """
            {
              "timestamp": \(ts),
              "cpu_pct": \(cpu),
              "cpu_max_pct": \(min(99.0, cpu + 6.0)),
              "mem_used_pct": \(mem),
              "mem_max_pct": \(min(99.0, mem + 2.0)),
              "mem_pressure_pct": \(mem * 0.85),
              "swap_used_pct": 12.0,
              "disk_primary_pct": 61.2,
              "disk_read_bps": \(readBps),
              "disk_write_bps": \(writeBps),
              "net_up_bps": \(up),
              "net_down_bps": \(down),
              "top_cpu_proc": "swift-frontend",
              "top_mem_proc": "Xcode"
            }
            """
            if let pt = try? FleetJSON.makeDecoder().decode(HistoryPoint.self, from: Data(json.utf8)) {
                pts.append(pt)
            }
        }
        return pts
    }

    private static func makeMacBookSnapshotJSON(nowMs: Int64) -> String {
        let pCoreVals = [54.0, 48.0, 62.0, 41.0, 38.0, 51.0, 29.0, 44.0, 36.0, 27.0, 33.0, 22.0]
        let eCoreVals = [18.0, 14.0, 21.0, 11.0]
        var coresJSON: [String] = []
        for (i, v) in pCoreVals.enumerated() {
            coresJSON.append(#"{"index":\#(i),"usage_pct":\#(v),"kind":"performance"}"#)
        }
        for (i, v) in eCoreVals.enumerated() {
            coresJSON.append(#"{"index":\#(pCoreVals.count + i),"usage_pct":\#(v),"kind":"efficiency"}"#)
        }
        return """
        {
          "timestamp": \(nowMs),
          "host": {
            "hostname": "macbook-pro",
            "os": "macos",
            "os_version": "macOS 15.4",
            "arch": "aarch64",
            "uptime_secs": 412800,
            "boot_id": "mbp-boot-1",
            "cpu_model": "Apple M4 Max"
          },
          "cpu": {
            "total_pct": 34.2,
            "user_pct": 26.8,
            "system_pct": 7.4,
            "iowait_pct": 0.0,
            "idle_pct": 65.8,
            "load_avg": [3.42, 3.18, 2.84],
            "cores": [\(coresJSON.joined(separator: ","))],
            "top_processes": [
              {"pid": 4812, "name": "swift-frontend", "user": "dev", "cpu_pct": 148.4, "memory_bytes": 2415919104},
              {"pid": 3104, "name": "cargo", "user": "dev", "cpu_pct": 82.6, "memory_bytes": 1181116006},
              {"pid": 1920, "name": "Xcode", "user": "dev", "cpu_pct": 34.1, "memory_bytes": 5905580032},
              {"pid": 842, "name": "WindowServer", "user": "_windowserver", "cpu_pct": 16.5, "memory_bytes": 966367641},
              {"pid": 2219, "name": "Safari", "user": "dev", "cpu_pct": 9.2, "memory_bytes": 3328599654}
            ]
          },
          "memory": {
            "total_bytes": 68719476736,
            "used_bytes": 39857296506,
            "used_pct": 58.0,
            "app_bytes": 27487790694,
            "wired_bytes": 8053063680,
            "compressed_bytes": 4316442132,
            "cached_bytes": 16106127360,
            "free_bytes": 12756052870,
            "swap_used_bytes": 1073741824,
            "swap_total_bytes": 2147483648,
            "pressure_level": "normal",
            "pressure_pct": 42.0,
            "psi_some_avg10": null,
            "psi_full_avg10": null,
            "top_processes": [
              {"pid": 1920, "name": "Xcode", "user": "dev", "memory_bytes": 5905580032, "oom_score": null},
              {"pid": 2219, "name": "Safari", "user": "dev", "memory_bytes": 3328599654, "oom_score": null},
              {"pid": 4812, "name": "swift-frontend", "user": "dev", "memory_bytes": 2415919104, "oom_score": null},
              {"pid": 3104, "name": "cargo", "user": "dev", "memory_bytes": 1181116006, "oom_score": null}
            ]
          },
          "disks": {
            "primary_used_pct": 61.2,
            "total_read_bps": 48234496,
            "total_write_bps": 23068672,
            "volumes": [
              {
                "id": "disk3s1s1",
                "name": "Macintosh HD",
                "mount_point": "/",
                "filesystem": "apfs",
                "is_external": false,
                "is_primary": true,
                "total_bytes": 2000000000000,
                "used_bytes": 1224000000000,
                "free_bytes": 776000000000,
                "used_pct": 61.2,
                "read_bps": 32505856,
                "write_bps": 18874368
              },
              {
                "id": "disk6s1",
                "name": "Thunderbolt Scratch",
                "mount_point": "/Volumes/Scratch",
                "filesystem": "apfs",
                "is_external": true,
                "is_primary": false,
                "total_bytes": 4000000000000,
                "used_bytes": 1720000000000,
                "free_bytes": 2280000000000,
                "used_pct": 43.0,
                "read_bps": 15728640,
                "write_bps": 4194304
              }
            ],
            "top_processes": [
              {"pid": 3104, "name": "cargo", "user": "dev", "read_bps": 28311552, "write_bps": 15728640, "total_bps": 44040192},
              {"pid": 4812, "name": "swift-frontend", "user": "dev", "read_bps": 12582912, "write_bps": 5242880, "total_bps": 17825792},
              {"pid": 1920, "name": "Xcode", "user": "dev", "read_bps": 4194304, "write_bps": 1572864, "total_bps": 5767168},
              {"pid": 512, "name": "mds_stores", "user": "root", "read_bps": 2097152, "write_bps": 524288, "total_bps": 2621440}
            ]
          },
          "network": {
            "upload_bps": 419430,
            "download_bps": 4404019,
            "interfaces": [
              {
                "name": "en0",
                "display_name": "Wi-Fi",
                "is_up": true,
                "is_physical": true,
                "ipv4": ["192.168.1.42"],
                "ipv6": ["fe80::1a2b:3c4d:5e6f"],
                "upload_bps": 290816,
                "download_bps": 3670016
              },
              {
                "name": "utun4",
                "display_name": "Tailscale",
                "is_up": true,
                "is_physical": false,
                "ipv4": ["100.64.0.12"],
                "ipv6": ["fd7a:115c:a1e0::12"],
                "upload_bps": 128614,
                "download_bps": 734003
              }
            ],
            "top_processes": [
              {"pid": 2219, "name": "Safari", "user": "dev", "upload_bps": 112640, "download_bps": 2621440, "total_bps": 2734080},
              {"pid": 3104, "name": "cargo", "user": "dev", "upload_bps": 81920, "download_bps": 1153433, "total_bps": 1235353},
              {"pid": 604, "name": "Tailscale", "user": "dev", "upload_bps": 143360, "download_bps": 491520, "total_bps": 634880},
              {"pid": 5510, "name": "ssh", "user": "dev", "upload_bps": 49152, "download_bps": 98304, "total_bps": 147456}
            ]
          },
          "active_alerts": []
        }
        """
    }

    private static func makeLinuxSnapshotJSON(nowMs: Int64) -> String {
        var coresJSON: [String] = []
        for i in 0..<16 {
            let v = 45.0 + Double((i * 13) % 38)
            coresJSON.append(#"{"index":\#(i),"usage_pct":\#(v),"kind":"standard"}"#)
        }
        return """
        {
          "timestamp": \(nowMs),
          "host": {
            "hostname": "linux-tower",
            "os": "linux",
            "os_version": "Debian 12 (bookworm)",
            "arch": "x86_64",
            "uptime_secs": 1843200,
            "boot_id": "linux-boot-9",
            "cpu_model": "AMD Ryzen 9 7950X"
          },
          "cpu": {
            "total_pct": 61.4,
            "user_pct": 52.1,
            "system_pct": 7.8,
            "iowait_pct": 1.5,
            "idle_pct": 38.6,
            "load_avg": [8.64, 7.92, 7.15],
            "cores": [\(coresJSON.joined(separator: ","))],
            "top_processes": [
              {"pid": 14201, "name": "ollama", "user": "ollama", "cpu_pct": 412.0, "memory_bytes": 25769803776},
              {"pid": 9821, "name": "postgres", "user": "postgres", "cpu_pct": 68.4, "memory_bytes": 8589934592},
              {"pid": 4412, "name": "dockerd", "user": "root", "cpu_pct": 24.2, "memory_bytes": 3221225472}
            ]
          },
          "memory": {
            "total_bytes": 68719476736,
            "used_bytes": 50852412784,
            "used_pct": 74.0,
            "app_bytes": 42949672960,
            "wired_bytes": 4294967296,
            "compressed_bytes": 0,
            "cached_bytes": 11811160064,
            "free_bytes": 6055903888,
            "swap_used_bytes": 536870912,
            "swap_total_bytes": 17179869184,
            "pressure_level": "warn",
            "pressure_pct": 74.0,
            "psi_some_avg10": 1.42,
            "psi_full_avg10": 0.18,
            "top_processes": [
              {"pid": 14201, "name": "ollama", "user": "ollama", "memory_bytes": 25769803776, "oom_score": 412},
              {"pid": 9821, "name": "postgres", "user": "postgres", "memory_bytes": 8589934592, "oom_score": 148},
              {"pid": 18240, "name": "python3", "user": "dev", "memory_bytes": 6442450944, "oom_score": 115},
              {"pid": 4412, "name": "dockerd", "user": "root", "memory_bytes": 3221225472, "oom_score": 42},
              {"pid": 1102, "name": "redis-server", "user": "redis", "memory_bytes": 1610612736, "oom_score": 28}
            ]
          },
          "disks": {
            "primary_used_pct": 48.6,
            "total_read_bps": 12582912,
            "total_write_bps": 8388608,
            "volumes": [
              {
                "id": "/dev/nvme0n1p2",
                "name": "Root (/)",
                "mount_point": "/",
                "filesystem": "ext4",
                "is_external": false,
                "is_primary": true,
                "total_bytes": 2000000000000,
                "used_bytes": 972000000000,
                "free_bytes": 1028000000000,
                "used_pct": 48.6,
                "read_bps": 12582912,
                "write_bps": 8388608
              }
            ],
            "top_processes": []
          },
          "network": {
            "upload_bps": 1258291,
            "download_bps": 6710886,
            "interfaces": [
              {
                "name": "tailscale0",
                "display_name": "Tailscale",
                "is_up": true,
                "is_physical": false,
                "ipv4": ["100.64.0.42"],
                "ipv6": ["fd7a:115c:a1e0::42"],
                "upload_bps": 1258291,
                "download_bps": 6710886
              }
            ],
            "top_processes": []
          },
          "active_alerts": []
        }
        """
    }

    private static func makeMacMiniSnapshotJSON(nowMs: Int64) -> String {
        """
        {
          "timestamp": \(nowMs),
          "host": {
            "hostname": "mac-mini",
            "os": "macos",
            "os_version": "macOS 15.4",
            "arch": "aarch64",
            "uptime_secs": 1209600,
            "boot_id": "mini-boot-1",
            "cpu_model": "Apple M4 Pro"
          },
          "cpu": {
            "total_pct": 14.2, "user_pct": 10.5, "system_pct": 3.7, "iowait_pct": 0.0, "idle_pct": 85.8,
            "load_avg": [1.4, 1.3, 1.2], "cores": [{"index": 0, "usage_pct": 14.0, "kind": "performance"}], "top_processes": []
          },
          "memory": {
            "total_bytes": 25769803776, "used_bytes": 11338713661, "used_pct": 44.0,
            "app_bytes": 7516192768, "wired_bytes": 2684354560, "compressed_bytes": 1138166333,
            "cached_bytes": 8589934592, "free_bytes": 5841155523, "swap_used_bytes": 0, "swap_total_bytes": 0,
            "pressure_level": "normal", "pressure_pct": 32.0, "psi_some_avg10": null, "psi_full_avg10": null, "top_processes": []
          },
          "disks": { "primary_used_pct": 38.0, "total_read_bps": 0, "total_write_bps": 0, "volumes": [], "top_processes": [] },
          "network": { "upload_bps": 85000, "download_bps": 320000, "interfaces": [], "top_processes": [] },
          "active_alerts": []
        }
        """
    }

    private static func makeIMacSnapshotJSON(nowMs: Int64) -> String {
        """
        {
          "timestamp": \(nowMs),
          "host": {
            "hostname": "imac-studio",
            "os": "macos",
            "os_version": "macOS 15.3",
            "arch": "x86_64",
            "uptime_secs": 864000,
            "boot_id": "imac-boot-1",
            "cpu_model": "Intel Core i9-10910"
          },
          "cpu": {
            "total_pct": 18.5, "user_pct": 14.0, "system_pct": 4.5, "iowait_pct": 0.0, "idle_pct": 81.5,
            "load_avg": [1.8, 1.6, 1.5], "cores": [{"index": 0, "usage_pct": 18.0, "kind": "standard"}], "top_processes": []
          },
          "memory": {
            "total_bytes": 34359738368, "used_bytes": 17523466567, "used_pct": 51.0,
            "app_bytes": 12884901888, "wired_bytes": 3221225472, "compressed_bytes": 1417339207,
            "cached_bytes": 9663676416, "free_bytes": 7172595385, "swap_used_bytes": 0, "swap_total_bytes": 0,
            "pressure_level": "normal", "pressure_pct": 36.0, "psi_some_avg10": null, "psi_full_avg10": null, "top_processes": []
          },
          "disks": { "primary_used_pct": 52.0, "total_read_bps": 0, "total_write_bps": 0, "volumes": [], "top_processes": [] },
          "network": { "upload_bps": 40000, "download_bps": 180000, "interfaces": [], "top_processes": [] },
          "active_alerts": []
        }
        """
    }
}
#endif
