import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit
import SwiftUI

final class ScreenPreviewController: ObservableObject {
    @Published private(set) var activeIDs = Set<CGDirectDisplayID>()
    @Published private(set) var startingIDs = Set<CGDirectDisplayID>()
    @Published var error: String?
    private var sessions: [CGDirectDisplayID: PreviewSession] = [:]
    private var generations: [CGDirectDisplayID: UUID] = [:]
    private var identities: [CGDirectDisplayID: DisplayIdentity] = [:]
    private var isShuttingDown = false

    var hasScreenRecordingAccess: Bool { CGPreflightScreenCaptureAccess() }
    @MainActor func acceptedFrameCount(for displayID: CGDirectDisplayID) -> Int {
        sessions[displayID]?.acceptedFrameCount ?? 0
    }

    /// This is called only from the user's Preview button. Never request capture
    /// access at startup, while enumerating displays, or during automatic tests.
    @MainActor func start(displayID: CGDirectDisplayID, name: String) async {
        guard !isShuttingDown, !startingIDs.contains(displayID) else { return }
        if let existing = sessions[displayID] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        error = nil
        guard sessions.count + startingIDs.count < 4 else {
            error = "最多同时打开 4 个屏幕预览。"
            return
        }
        guard DisplayCore.onlineIDs().contains(displayID), let identity = DisplayIdentity.capture(displayID) else {
            error = "显示器已断开，请刷新后重试。"
            return
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            error = "屏幕预览需要“屏幕与系统音频录制”权限。请在系统设置中允许 HiDPI Studio；授权后可能需要重新打开应用。"
            return
        }
        let generation = UUID()
        generations[displayID] = generation
        identities[displayID] = identity
        startingIDs.insert(displayID)
        defer { if generations[displayID] == generation { startingIDs.remove(displayID) } }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !isShuttingDown, generations[displayID] == generation else { return }
            guard identity.matches(displayID) else { throw DisplayFailure(message: "显示器已变化，请为当前屏幕重新启动预览。") }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw DisplayFailure(message: "该屏幕当前不可捕获，可能已断开或处于镜像从屏状态。")
            }
            let ownApplications = content.applications.filter {
                $0.processID == ProcessInfo.processInfo.processIdentifier
                    || (Bundle.main.bundleIdentifier != nil && $0.bundleIdentifier == Bundle.main.bundleIdentifier)
            }
            let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let dimensions = Self.previewSize(width: display.width, height: display.height)
            config.width = dimensions.width
            config.height = dimensions.height
            config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            config.queueDepth = 3
            config.showsCursor = true
            config.capturesAudio = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            if #available(macOS 14.0, *) { config.preservesAspectRatio = true }

            let session = PreviewSession(name: name, width: display.width, height: display.height)
            session.onClose = { [weak self] in Task { @MainActor in await self?.stop(displayID: displayID) } }
            session.onFailure = { [weak self] message in
                Task { @MainActor in
                    guard let self, self.generations[displayID] == generation else { return }
                    self.error = message
                    await self.stop(displayID: displayID)
                }
            }
            let stream = SCStream(filter: filter, configuration: config, delegate: session)
            session.stream = stream
            try stream.addStreamOutput(session, type: .screen, sampleHandlerQueue: .main)
            sessions[displayID] = session
            try await stream.startCapture()
            guard !isShuttingDown, generations[displayID] == generation else {
                try? await stream.stopCapture()
                session.window.close()
                return
            }
            activeIDs.insert(displayID)
            session.window.makeKeyAndOrderFront(nil)
            session.watchdog = Task { @MainActor [weak self, weak session] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled, let self, let session,
                    self.generations[displayID] == generation, !session.receivedFrame
                else { return }
                self.error = "未收到有效预览画面。请检查录屏权限及屏幕连接，然后重试。"
                await self.stop(displayID: displayID)
            }
        } catch {
            guard generations[displayID] == generation else { return }
            self.error = "无法启动屏幕预览：\(error.localizedDescription)"
            await stop(displayID: displayID)
        }
    }

    @MainActor func stop(displayID: CGDirectDisplayID) async {
        generations[displayID] = nil
        identities[displayID] = nil
        startingIDs.remove(displayID)
        activeIDs.remove(displayID)
        guard let session = sessions.removeValue(forKey: displayID) else { return }
        session.watchdog?.cancel()
        session.onClose = nil
        session.onFailure = nil
        session.window.close()
        if let stream = session.stream { try? await stream.stopCapture() }
        session.video.displayLayer.flushAndRemoveImage()
    }

    @MainActor func stopAll() async {
        isShuttingDown = true
        for id in Set(sessions.keys).union(startingIDs) { await stop(displayID: id) }
    }

    func refreshScreens() {
        let online = Set(DisplayCore.onlineIDs())
        let missing = Set(sessions.keys).union(startingIDs).filter {
            !online.contains($0) || identities[$0]?.matches($0) != true
        }
        for id in missing { Task { @MainActor [weak self] in await self?.stop(displayID: id) } }
    }

    static func previewSize(width: Int, height: Int) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (1920, 1080) }
        let scale = min(1, min(1920 / Double(width), 1080 / Double(height)))
        return (max(2, Int(Double(width) * scale) / 2 * 2), max(2, Int(Double(height) * scale) / 2 * 2))
    }
}

private final class PreviewVideoView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    private let waiting = NSTextField(labelWithString: "正在等待画面…")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        waiting.textColor = .white
        waiting.alignment = .center
        waiting.font = .systemFont(ofSize: 13)
        addSubview(waiting)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
        waiting.frame = NSRect(x: 10, y: bounds.midY - 12, width: max(0, bounds.width - 20), height: 24)
    }
    func showFrame(_ buffer: CMSampleBuffer) -> Bool {
        if displayLayer.status == .failed { displayLayer.flush() }
        guard displayLayer.isReadyForMoreMediaData else { return false }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true)
            as? [NSMutableDictionary]
        {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately as String] = true
        }
        displayLayer.enqueue(buffer)
        guard displayLayer.status != .failed else { return false }
        waiting.isHidden = true
        return true
    }
    func showPaused(_ message: String) {
        displayLayer.flushAndRemoveImage()
        waiting.stringValue = message
        waiting.isHidden = false
    }
}

private final class PreviewSession: NSObject, SCStreamOutput, SCStreamDelegate, NSWindowDelegate {
    let window: NSWindow
    let video: PreviewVideoView
    var stream: SCStream?
    private(set) var acceptedFrameCount = 0
    var receivedFrame: Bool { acceptedFrameCount > 0 }
    var watchdog: Task<Void, Never>?
    var onClose: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(name: String, width: Int, height: Int) {
        let size = ScreenPreviewController.previewSize(width: width, height: height)
        let scale = min(720 / Double(size.width), 450 / Double(size.height))
        let rect = NSRect(x: 0, y: 0, width: Double(size.width) * scale, height: Double(size.height) * scale)
        window = NSWindow(
            contentRect: rect, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
            defer: false)
        video = PreviewVideoView(frame: rect)
        super.init()
        window.title = "屏幕预览 · \(name) · 只读"
        window.level = .floating
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.minSize = NSSize(width: 280, height: 180)
        window.contentAspectRatio = NSSize(width: size.width, height: size.height)
        window.contentView = video
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        {
            switch status {
            case .blank, .suspended:
                video.showPaused("屏幕画面已暂停，等待恢复…")
                return
            case .stopped:
                video.showPaused("屏幕预览已停止")
                return
            case .complete: break
            default: return  // Idle/started notifications do not contain a new frame.
            }
        }
        guard sampleBuffer.dataReadiness == .ready,
            let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
            CVPixelBufferGetWidth(pixels) > 0, CVPixelBufferGetHeight(pixels) > 0
        else { return }
        if video.showFrame(sampleBuffer) { acceptedFrameCount += 1 }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onFailure?("预览已停止：\(error.localizedDescription)") }
    }
}

struct ScreenPreviewsView: View {
    let screens: [DisplayInfo]
    @ObservedObject var controller: ScreenPreviewController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("屏幕画中画").font(.system(size: 15, weight: .semibold))
            Text("将屏幕放到可缩放的悬浮窗口中查看。最高 1080p / 30 fps，无音频；预览窗口不转发鼠标操作。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = controller.error {
                Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if !controller.hasScreenRecordingAccess {
                Text("首次点击“预览”时，macOS 会请求录屏权限；授权后可能需要重新打开应用。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(screens) { screen in
                HStack(spacing: 12) {
                    Image(systemName: screen.isBuiltin ? "laptopcomputer" : "display").frame(width: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(screen.name).font(.system(size: 13, weight: .medium))
                        Text(screen.current.map { $0.sizeLabel + " · " + $0.rateLabel } ?? "模式暂不可读")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if controller.startingIDs.contains(screen.id) {
                        ProgressView().controlSize(.small)
                        Button("取消") { Task { @MainActor in await controller.stop(displayID: screen.id) } }
                    } else if controller.activeIDs.contains(screen.id) {
                        Button("显示窗口") {
                            Task { @MainActor in await controller.start(displayID: screen.id, name: screen.name) }
                        }
                        Button("停止预览") { Task { @MainActor in await controller.stop(displayID: screen.id) } }
                    } else {
                        Button("预览") {
                            Task { @MainActor in await controller.start(displayID: screen.id, name: screen.name) }
                        }
                    }
                }.padding(.vertical, 6)
            }
            Text("为避免画面递归，预览会排除 HiDPI Studio 自身的窗口。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
