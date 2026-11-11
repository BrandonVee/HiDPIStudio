import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    let model = DisplayModel()
    let daily = DailyControlManager()
    let workspace = VirtualWorkspace()
    let layouts = LayoutProfileManager()
    let shortcuts = StudioShortcutManager()
    let brightnessSync = BrightnessSyncManager()
    let autoRestore = AutoRestoreManager()
    let nativeKeys = NativeBrightnessKeyManager()
    private var subscriptions = Set<AnyCancellable>()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let statusPopover = NSPopover()
    private var statusPanelLocalMonitor: Any?
    private var statusPanelGlobalMonitor: Any?
    private var statusPanelResignObserver: NSObjectProtocol?
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = AppBranding.icon { NSApp.applicationIconImage = icon }
        model.externalOperationBlocked = { [weak self] in
            guard let self else { return true }
            // UI availability checks need display identity flags, not every supported mode.
            let otherVirtual = DisplayCore.onlineIDs().contains {
                $0 != self.model.virtualSourceID
                    && CGDisplayVendorNumber($0) == 0x4844 && CGDisplayModelNumber($0) == 0x5354
            }
            return self.layouts.isPending || self.layouts.isBusy || self.workspace.isBusy
                || self.workspace.hasConnectedScreens || otherVirtual || self.autoRestore.isBusy
        }
        layouts.isBlocked = { [weak self] in
            guard let self else { return true }
            return self.model.hasPendingConfiguration || self.model.isBusy || self.workspace.isBusy
                || self.workspace.hasConnectedScreens
        }
        workspace.isBlocked = { [weak self] in
            guard let self else { return true }
            return self.model.hasPendingConfiguration || self.model.isBusy || self.layouts.isPending
                || self.layouts.isBusy || self.autoRestore.isBusy
        }
        daily.isBlocked = { [weak self] in
            guard let self else { return true }
            return self.model.hasTrial || self.model.isBusy || self.layouts.isPending || self.layouts.isBusy
                || self.workspace.isBusy || self.autoRestore.isBusy
        }
        brightnessSync.isBlocked = { [weak self] in
            guard let self else { return true }
            return self.model.hasPendingConfiguration || self.model.isBusy || self.layouts.isPending
                || self.layouts.isBusy || self.workspace.isBusy || self.workspace.hasConnectedScreens
                || self.autoRestore.isBusy
        }
        autoRestore.isBlocked = { [weak self] in
            guard let self else { return true }
            return self.model.hasPendingConfiguration || self.model.isBusy || self.layouts.isPending
                || self.layouts.isBusy || self.workspace.isBusy || self.workspace.hasConnectedScreens
        }
        daily.onManualBrightnessRequest = { [weak self] id, value in
            self?.brightnessSync.noteManualChange(displayID: id, value: value)
        }
        brightnessSync.onApplied = { [weak self] reading in self?.daily.acceptObservedBrightness(reading) }
        nativeKeys.canHandle = { [weak self] id in self?.daily.nativeReading(for: id) != nil }
        nativeKeys.isBlocked = { [weak self] in self?.daily.isBlocked() ?? true }
        nativeKeys.onAdjust = { [weak self] id, delta in self?.daily.adjustBrightness(displayID: id, delta: delta) }
        model.$remaining.dropFirst().sink { [weak self] value in
            if value > 0 { self?.manualDisplayOperationStarted() }
        }.store(in: &subscriptions)
        layouts.$remaining.dropFirst().sink { [weak self] value in
            if value > 0 { self?.manualDisplayOperationStarted() }
        }.store(in: &subscriptions)
        workspace.$isBusy.dropFirst().sink { [weak self] value in
            if value { self?.manualDisplayOperationStarted() }
        }.store(in: &subscriptions)
        autoRestore.$isBusy.dropFirst().sink { [weak self] value in
            if value { self?.brightnessSync.suspendForConfiguration() }
        }.store(in: &subscriptions)
        nativeKeys.$enabled.sink { [weak self] value in
            if value { self?.daily.refreshScreens() }
        }.store(in: &subscriptions)
        autoRestore.start(layouts: layouts)
        brightnessSync.start()
        nativeKeys.restorePreference()
        shortcuts.onOpen = { [weak self] in self?.showWindow() }
        shortcuts.onFavorite = { [weak self] index in self?.openFavorite(at: index) }
        shortcuts.onProfile = { [weak self] index in self?.openProfile(at: index) }
        shortcuts.onResetFilters = { [weak self] in self?.daily.resetAll() }
        shortcuts.onBrightness = { [weak self] delta in
            guard let self else { return }
            self.daily.adjustBrightness(displayID: self.model.selectedDisplay, delta: delta)
        }
        shortcuts.restorePreference()
        // Each manager observes screen changes itself. Avoid a second delayed
        // refresh that repeats DDC reads and republishes unchanged UI state.
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 HiDPI Studio", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(withTitle: "导出显示诊断", action: #selector(exportDiagnostics), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 HiDPI Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = AppBranding.menuBarIcon()
        statusItem?.button?.setAccessibilityLabel("HiDPI Studio")
        statusItem?.button?.toolTip = "HiDPI Studio · 显示控制中心（右键打开快捷菜单）"
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(toggleStatusPanel(_:))
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusPopover.behavior = .transient
        statusPopover.delegate = self

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "HiDPI Studio"
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(
            rootView: StudioView(
                model: model, daily: daily, workspace: workspace, layouts: layouts, shortcuts: shortcuts,
                brightnessSync: brightnessSync, autoRestore: autoRestore, nativeKeys: nativeKeys))
        window.minSize = NSSize(width: 900, height: 748)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        showWindow()
    }
    @objc private func toggleStatusPanel(_ sender: NSStatusBarButton) {
        guard !terminating else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusPopover.performClose(nil)
            let menu = NSMenu()
            menuNeedsUpdate(menu)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
            return
        }
        if statusPopover.isShown {
            statusPopover.performClose(nil)
            return
        }
        let width = min(460, (sender.window?.screen?.visibleFrame.width ?? 1440) - 40)
        let panel = StatusPanelView(
            model: model, daily: daily, layouts: layouts, workspace: workspace,
            autoRestore: autoRestore,
            openSection: { [weak self] in self?.openStatusSection($0) },
            refresh: { [weak self] in self?.refreshFromStatus() },
            quit: { NSApp.terminate(nil) }, panelWidth: width)
        let controller = NSHostingController(rootView: panel)
        // Let the popover follow the two-column control cards and inline trial notices.
        controller.sizingOptions = [.preferredContentSize]
        statusPopover.contentViewController = controller
        statusPopover.contentSize = controller.view.fittingSize
        statusPopover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        daily.refreshSystemBrightness(displayID: model.selectedDisplay)
        statusPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        startStatusPanelMonitoring()
        statusPopover.contentViewController?.view.window?.makeKey()
        sender.highlight(true)
    }

    private func startStatusPanelMonitoring() {
        stopStatusPanelMonitoring()
        // A status-item popover can become key while the app remains inactive.
        // In that case transient behavior alone does not always dismiss it when
        // the desktop is clicked. Cover clicks in both this app and other apps.
        statusPanelGlobalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.statusPopover.performClose(nil)
        }
        statusPanelLocalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self, self.statusPopover.isShown else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.statusPopover.performClose(nil)
                    return nil
                }
                return event
            }
            // Native picker/menu windows must finish their own interaction.
            if event.window?.level == .popUpMenu { return event }
            let panelWindow = self.statusPopover.contentViewController?.view.window
            var eventWindow = event.window
            while let window = eventWindow {
                if window === panelWindow || window === self.statusItem?.button?.window { return event }
                eventWindow = window.parent
            }
            self.statusPopover.performClose(nil)
            return event
        }
        statusPanelResignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
        ) { [weak self] _ in
            self?.statusPopover.performClose(nil)
        }
    }

    private func stopStatusPanelMonitoring() {
        if let monitor = statusPanelLocalMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = statusPanelGlobalMonitor { NSEvent.removeMonitor(monitor) }
        if let observer = statusPanelResignObserver { NotificationCenter.default.removeObserver(observer) }
        statusPanelLocalMonitor = nil
        statusPanelGlobalMonitor = nil
        statusPanelResignObserver = nil
    }

    func popoverWillClose(_ notification: Notification) {
        stopStatusPanelMonitoring()
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
        // Each opening gets fresh local UI state without retaining hidden controls.
        statusPopover.contentViewController = nil
    }

    private func openStatusSection(_ section: StudioSection) {
        if layouts.isPending || layouts.isBusy {
            model.activeSection = .layouts
        } else if model.hasTrial || model.isBusy {
            model.activeSection = .resolution
        } else {
            model.activeSection = section
        }
        showWindow()
    }

    private func refreshFromStatus() {
        guard !model.hasTrial, !model.isBusy, !layouts.isPending, !layouts.isBusy,
            !workspace.isBusy, !autoRestore.isBusy
        else { return }
        model.refresh()
        brightnessSync.refreshScreens()
        daily.refreshSystemBrightness(displayID: model.selectedDisplay)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        func item(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return entry
        }
        let summary = NSMenuItem(title: model.currentDisplay?.name ?? "未连接显示器", action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        if let display = model.currentDisplay, let mode = model.renderedMode(for: display) {
            let detail = NSMenuItem(
                title: mode.sizeLabel + " · " + mode.rateLabel + (mode.isHiDPI ? " · HiDPI" : ""),
                action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
        }
        menu.addItem(.separator())
        menu.addItem(item("打开 HiDPI Studio", symbol: "macwindow", action: #selector(showWindow)))
        let favorites = NSMenuItem(title: "收藏分辨率", action: nil, keyEquivalent: "")
        favorites.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        let favoriteMenu = NSMenu()
        favoriteMenu.autoenablesItems = false
        for favorite in daily.favorites {
            let entry = item(
                favorite.name + " · " + favorite.displayName, symbol: "display",
                action: #selector(applyFavoriteMenu(_:)))
            entry.representedObject = favorite.id.uuidString
            entry.isEnabled =
                !daily.isBlocked() && !model.hasPendingConfiguration && !workspace.hasConnectedScreens
                && !model.externalOperationBlocked() && favorite.identity.resolve() != nil
            favoriteMenu.addItem(entry)
        }
        if daily.favorites.isEmpty {
            let empty = NSMenuItem(title: "暂无收藏", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            favoriteMenu.addItem(empty)
        }
        favorites.submenu = favoriteMenu
        menu.addItem(favorites)
        let profiles = NSMenuItem(title: "布局预设", action: nil, keyEquivalent: "")
        profiles.image = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        let profileMenu = NSMenu()
        profileMenu.autoenablesItems = false
        for profile in layouts.profiles {
            let entry = item(profile.name, symbol: "rectangle.3.group", action: #selector(applyProfileMenu(_:)))
            entry.representedObject = profile.id.uuidString
            entry.isEnabled = layouts.canModify && layouts.unavailableReason(for: profile) == nil
            profileMenu.addItem(entry)
        }
        if layouts.profiles.isEmpty {
            let empty = NSMenuItem(title: "暂无预设", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            profileMenu.addItem(empty)
        }
        profiles.submenu = profileMenu
        menu.addItem(profiles)
        menu.addItem(.separator())
        let clear = item("移除全部软件滤镜", symbol: "camera.filters", action: #selector(resetFilters))
        clear.isEnabled = daily.activeFilterCount > 0 && !daily.isBlocked()
        menu.addItem(clear)
        let restore = item("恢复本次分辨率设置", symbol: "arrow.uturn.backward", action: #selector(restore))
        restore.isEnabled = model.hasChanges && !model.isBusy && !model.hasTrial && !model.externalOperationBlocked()
        menu.addItem(restore)
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "退出 HiDPI Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }
    private func openFavorite(at index: Int) {
        guard daily.favorites.indices.contains(index) else { return }
        applyFavorite(id: daily.favorites[index].id)
    }
    private func openProfile(at index: Int) {
        guard layouts.profiles.indices.contains(index) else { return }
        applyProfile(id: layouts.profiles[index].id)
    }
    private func applyFavorite(id: UUID) {
        guard readyToChangeDisplay() else { return }
        model.activeSection = .resolution
        showWindow()
        daily.applyFavorite(id: id, displayModel: model)
    }
    private func applyProfile(id: UUID) {
        guard readyToChangeDisplay() else { return }
        model.activeSection = .layouts
        showWindow()
        layouts.applyProfile(id: id)
    }
    @objc private func applyFavoriteMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        applyFavorite(id: id)
    }
    @objc private func applyProfileMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value) else { return }
        applyProfile(id: id)
    }
    @objc private func resetFilters() { daily.resetAll() }
    @objc private func exportDiagnostics() { model.exportDiagnostics() }
    private func manualDisplayOperationStarted() {
        brightnessSync.suspendForConfiguration()
        if !autoRestore.isBusy { autoRestore.cancelPendingForUserChange() }
    }
    private func readyToChangeDisplay() -> Bool {
        if autoRestore.isBusy {
            model.activeSection = .automation
            showWindow()
            return false
        }
        if layouts.isPending || layouts.isBusy {
            model.activeSection = .layouts
            showWindow()
            return false
        }
        if model.hasPendingConfiguration || model.isBusy {
            model.activeSection = .resolution
            showWindow()
            return false
        }
        if workspace.isBusy || workspace.hasConnectedScreens {
            model.activeSection = .virtual
            showWindow()
            return false
        }
        return true
    }
    @objc func showWindow() {
        statusPopover.performClose(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func restore() { Task { @MainActor in await model.restoreAll() } }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "HiDPI Studio",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "development",
            .credits: NSAttributedString(
                string: "独立实现的 macOS 显示管理工具\nHiDPI · 软件滤镜 · 虚拟屏幕 · 画中画 · 布局预设\n与 BetterDisplay 无关联"),
        ])
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
        stopStatusPanelMonitoring()
        statusPopover.performClose(nil)
        nativeKeys.shutdown()
        autoRestore.shutdown()
        brightnessSync.shutdown()
        subscriptions.removeAll()
        shortcuts.shutdown()
        daily.shutdown()
        Task { @MainActor in
            await autoRestore.waitForShutdown()
            await layouts.shutdown()
            await model.shutdown()
            await workspace.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
