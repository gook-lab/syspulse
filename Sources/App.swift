import SwiftUI

@main
enum Entry {
    @MainActor static func main() {
        // --snapshot <png> [--tab apps]: 팝오버 화면을 이미지로 저장하고 끝낸다 (화면 녹화 권한 없이 UI 확인용)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count {
            let tab = args.firstIndex(of: "--tab").flatMap { $0 + 1 < args.count ? ListTab(rawValue: args[$0 + 1]) : nil }
            let width = args.firstIndex(of: "--width").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
            let duration = args.firstIndex(of: "--duration").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
            Snapshot.render(to: args[index + 1], tab: tab ?? .agents, confirmFirst: args.contains("--confirm-first"),
                            quittingFirst: args.contains("--quitting-first"),
                            width: width.map { CGFloat($0) }, light: args.contains("--light"), duration: duration)
            return
        }
        // --jump <pid>: 에이전트 줄 클릭과 같은 이동을 한 번 해 보고 끝낸다 (개발 확인용)
        if let index = args.firstIndex(of: "--jump"), index + 1 < args.count, let pid = pid_t(args[index + 1]) {
            SessionJump.jump(pid: pid, cwd: FileManager.default.currentDirectoryPath)
            RunLoop.main.run(until: Date().addingTimeInterval(3))
            return
        }
        SysPulseApp.main()
    }
}

struct SysPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var monitor = SystemMonitor.shared

    var body: some Scene {
        MenuBarExtra {
            DetailView(monitor: monitor)
        } label: {
            Image(nsImage: monitor.menuBarImage)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: WindowController.pinnedKey) {
            WindowController.shared.showPinned()
        }
        // 메뉴 막대 항목이 자리를 잡은 뒤에 노치에 가렸는지 본다
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { WindowController.shared.checkMenuBarVisibility() }
        }
    }
}

// 화면 고정 창(항상 위) + 노치 안내 창
@MainActor
final class WindowController: NSObject, NSWindowDelegate {
    static let shared = WindowController()
    static let pinnedKey = "pinned"

    private var pinned: NSPanel?
    private var help: NSWindow?

    var isPinned: Bool { pinned != nil }

    func togglePinned() {
        if let pinned { pinned.close() } else { showPinned() }
    }

    func showPinned() {
        closeMenuBarPopover()
        if let pinned {
            pinned.orderFrontRegardless()
            return
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 640),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.title = "SysPulse"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        let hosting = NSHostingView(rootView: DetailView(monitor: .shared, mode: .pinned))
        hosting.sizingOptions = [] // 내용 높이에 창을 묶지 않는다 — 세로는 자유, 넘치면 스크롤
        panel.contentView = hosting
        panel.contentMinSize = NSSize(width: 240, height: 200) // 좁으면 줄을 접고, 640 이상이면 두 열로 바뀐다
        panel.delegate = self
        if !panel.setFrameUsingName("SysPulsePinned") { placeTopRight(panel) }
        panel.setFrameAutosaveName("SysPulsePinned")
        panel.orderFrontRegardless()
        pinned = panel
        UserDefaults.standard.set(true, forKey: Self.pinnedKey)
        FileHandle.standardError.write(Data(
            "[syspulse:pinned] frame=\(panel.frame) visible=\(panel.isVisible) screen=\(panel.screen?.localizedName ?? "-")\n".utf8))
        if let dir = ProcessInfo.processInfo.environment["SYSPULSE_DEBUG_DIR"] { capture(panel, to: dir) }
    }

    // 처음 고정할 때는 마우스가 있는 화면의 오른쪽 위에 둔다 (그다음부터는 옮긴 자리를 기억)
    private func placeTopRight(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { panel.center(); return }
        let area = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 16, y: area.maxY - panel.frame.height - 16))
    }

    // 개발 확인용: 고정 창 내용만 PNG 로 저장 (화면 녹화 권한 없이, 다른 창은 안 담긴다)
    private func capture(_ panel: NSPanel, to dir: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let view = panel.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/pinned.png"))
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === pinned {
            pinned = nil
            UserDefaults.standard.set(false, forKey: Self.pinnedKey)
        } else if window === help {
            help = nil
        }
    }

    // 메뉴 막대 항목이 안 보이는 두 경우를 잡는다
    // - 오른쪽이 노치까지 차 있으면 macOS 는 새 항목(가장 왼쪽)을 노치 뒤·왼쪽으로 밀어 그리지 않는다
    //   (노치 왼쪽은 앱 메뉴 자리라, 노치 오른쪽에 온전히 들어간 항목만 보인다)
    // - 「메뉴 막대에 허용」이 꺼졌거나 넘쳐서 밀려나면 항목 창이 화면 밖으로 나간다
    func checkMenuBarVisibility() {
        // 화면마다 메뉴 막대가 있어 항목 창도 화면 수만큼 생긴다 — 하나라도 보이면 된다
        let items = NSApp.windows.filter { $0.className.contains("StatusBarWindow") }
        guard !items.isEmpty else { return }
        let visible = items.contains { item in
            guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(item.frame) }) else { return false }
            guard let right = screen.auxiliaryTopRightArea else { return true } // 노치 없는 화면
            return item.frame.minX >= screen.frame.maxX - right.width
        }
        let hidden = !visible
        let frames = items.map { "\(Int($0.frame.minX)),\(Int($0.frame.minY))" }.joined(separator: " ")
        FileHandle.standardError.write(Data("[syspulse:menubar] items=\(frames) hidden=\(hidden)\n".utf8))
        if hidden, !isPinned { showNotchHelp() }
    }

    private func showNotchHelp() {
        guard help == nil else { return }
        let view = NotchHelpView(
            openPinned: { [weak self] in self?.help?.close(); self?.showPinned() },
            dismiss: { [weak self] in self?.help?.close() })
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "SysPulse"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        help = window
    }

    // 고정 창을 띄울 때·세션 탭으로 이동할 때 열려 있던 메뉴 막대 팝오버는 닫는다
    func closeMenuBarPopover() {
        for window in NSApp.windows where window.className.contains("MenuBarExtra") && window.isVisible {
            window.orderOut(nil)
        }
    }
}

private struct NotchHelpView: View {
    let openPinned: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("메뉴 막대에 SysPulse 아이콘이 보이지 않습니다").font(.headline)
            Text("메뉴 막대 오른쪽이 노치까지 차 있으면 macOS 가 새 아이콘을 숨깁니다. 다른 아이콘을 하나 빼거나, 「메뉴 막대에 허용」에서 SysPulse 가 켜져 있는지 확인하세요.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("• 시스템 설정 → 메뉴 막대 → 「메뉴 막대에 허용」에서 SysPulse 켜기 · 안 쓰는 앱 끄기")
                Text("• 또는 ⌘ 를 누른 채 아이콘을 메뉴 막대 밖으로 끌어내기")
            }
            .font(.callout).foregroundStyle(.secondary)
            Text("그동안은 화면에 고정한 창으로 볼 수 있습니다.").font(.callout)
            HStack {
                Spacer()
                Button("닫기", action: dismiss)
                Button("고정 창으로 보기", action: openPinned).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

enum Snapshot {
    // --duration 초: 그동안 2초마다 샘플해 세션 추세까지 쌓는다 (추세는 2분 넘게 쌓여야 나온다)
    @MainActor static func render(to path: String, tab: ListTab, confirmFirst: Bool = false, quittingFirst: Bool = false,
                                  width: CGFloat? = nil,
                                  light: Bool = false, duration: Double? = nil) {
        let monitor = SystemMonitor(autoStart: false)
        let steps = duration.map { max(Int($0 / 2), 1) } ?? 8
        for _ in 0..<steps {
            Thread.sleep(forTimeInterval: duration == nil ? 0.4 : 2)
            monitor.sample()
        }
        if quittingFirst {
            // 끌 수 있는 첫 두 줄: 하나는 종료 중, 하나는 응답 없음
            for (index, row) in monitor.apps.filter(\.killable).prefix(2).enumerated() {
                monitor.previewQuitting(row.id, stalled: index == 1)
            }
        }
        for session in monitor.sessions {
            let trend = session.trend.map { "\($0 / 1_048_576)MB/\(session.trendMinutes)분" } ?? "-"
            FileHandle.standardError.write(Data(
                "[syspulse:session] \(session.project) cpu=\(Format.cpu(session.cpu)) trend=\(trend)\n".utf8))
        }
        let content = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("메뉴 막대").font(.caption).foregroundStyle(.secondary)
                Image(nsImage: monitor.menuBarImage).renderingMode(.template)
                    .foregroundStyle(light ? Color.black : Color.white)
            }
            .padding(.horizontal, 16).padding(.top, 12)
            DetailView(monitor: monitor, tabOverride: tab, previewConfirmFirstApp: confirmFirst, previewWidth: width)
        }
        .background(light ? Color(white: 0.96) : Color(red: 0.15, green: 0.15, blue: 0.16))
        .environment(\.colorScheme, light ? .light : .dark)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
              (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            exit(1)
        }
        print(path)
    }
}
