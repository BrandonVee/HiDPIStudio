import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
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
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.externalOperationBlocked = { [weak self] in
            guard let self else { return true }
            let otherVirtual = DisplayCore.displays().contains { $0.isStudioVirtual && $0.id != self.model.virtualSourceID }
            return self.layouts.isPending || self.layouts.isBusy || self.workspace.isBusy || self.workspace.hasConnectedScreens || otherVirtual || self.autoRestore.isBusy
        }
        layouts.isBlocked = { [weak self] in
            guard let self else { return true }
            return self.model.hasPendingConfiguration || self.model.isBusy || self.workspace.isBusy || self.workspace.hasConnectedScreens
        }
        workspace.isBlocked = { [weak self] in
            guard let self else { return true }
            return self.model.hasPendingConfiguration || self.model.isBusy || self.layouts.isPending || self.layouts.isBusy || self.autoRestore.isBusy
        }
        daily.isBlocked = { [weak self] in
            guard let self else { return true }
            return self.model.hasTrial || self.model.isBusy || self.layouts.isPending || self.layouts.isBusy || self.workspace.isBusy || self.autoRestore.isBusy
        }
        brightnessSync.isBlocked = { [weak self] in
            guard let self else { return true }
            return self.model.hasPendingConfiguration || self.model.isBusy || self.layouts.isPending || self.layouts.isBusy || self.workspace.isBusy || self.workspace.hasConnectedScreens || self.autoRestore.isBusy
        }
        autoRestore.isBlocked = { [weak self] in
            guard let self else { return true }
            return self.model.hasPendingConfiguration || self.model.isBusy || self.layouts.isPending || self.layouts.isBusy || self.workspace.isBusy || self.workspace.hasConnectedScreens
        }
        daily.onManualBrightnessRequest = { [weak self] id, value in self?.brightnessSync.noteManualChange(displayID: id, value: value) }
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
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 HiDPI Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu; menu.addItem(editItem)
        NSApp.mainMenu = menu

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "display", accessibilityDescription: "HiDPI Studio")
        let statusMenu = NSMenu()
        statusMenu.delegate = self
        menuNeedsUpdate(statusMenu)
        statusItem?.menu = statusMenu

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "HiDPI Studio"
        window.contentView = NSHostingView(rootView: StudioView(model: model, daily: daily, workspace: workspace, layouts: layouts, shortcuts: shortcuts, brightnessSync: brightnessSync, autoRestore: autoRestore, nativeKeys: nativeKeys))
        window.minSize = NSSize(width: 900, height: 748)
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        showWindow()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = menu.addItem(withTitle: "打开 HiDPI Studio", action: #selector(showWindow), keyEquivalent: "")
        open.target = self
        let favorites = NSMenuItem(title: "收藏分辨率", action: nil, keyEquivalent: "")
        let favoriteMenu = NSMenu()
        for item in daily.favorites {
            let entry = favoriteMenu.addItem(withTitle: item.name + " · " + item.mode.label, action: #selector(applyFavoriteMenu(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = item.id.uuidString
        }
        if daily.favorites.isEmpty { favoriteMenu.addItem(withTitle: "暂无收藏", action: nil, keyEquivalent: "") }
        favorites.submenu = favoriteMenu; menu.addItem(favorites)
        let profiles = NSMenuItem(title: "显示配置", action: nil, keyEquivalent: "")
        let profileMenu = NSMenu()
        for item in layouts.profiles {
            let entry = profileMenu.addItem(withTitle: item.name, action: #selector(applyProfileMenu(_:)), keyEquivalent: "")
            entry.target = self; entry.representedObject = item.id.uuidString
        }
        if layouts.profiles.isEmpty { profileMenu.addItem(withTitle: "暂无预设", action: nil, keyEquivalent: "") }
        profiles.submenu = profileMenu; menu.addItem(profiles)
        menu.addItem(.separator())
        let clear = menu.addItem(withTitle: "移除全部软件滤镜", action: #selector(resetFilters), keyEquivalent: ""); clear.target = self
        let restore = menu.addItem(withTitle: "恢复本次分辨率设置", action: #selector(restore), keyEquivalent: ""); restore.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 HiDPI Studio", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
    private func openFavorite(at index: Int) {
        guard daily.favorites.indices.contains(index), readyToChangeDisplay() else { return }
        model.activeSection = .resolution; showWindow()
        daily.applyFavorite(id: daily.favorites[index].id, displayModel: model)
    }
    private func openProfile(at index: Int) {
        guard layouts.profiles.indices.contains(index), readyToChangeDisplay() else { return }
        model.activeSection = .layouts; showWindow()
        layouts.applyProfile(id: layouts.profiles[index].id)
    }
    @objc private func applyFavoriteMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value), readyToChangeDisplay() else { return }
        model.activeSection = .resolution; showWindow(); daily.applyFavorite(id: id, displayModel: model)
    }
    @objc private func applyProfileMenu(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let id = UUID(uuidString: value), readyToChangeDisplay() else { return }
        model.activeSection = .layouts; showWindow(); layouts.applyProfile(id: id)
    }
    @objc private func resetFilters() { daily.resetAll() }
    private func manualDisplayOperationStarted() {
        brightnessSync.suspendForConfiguration()
        if !autoRestore.isBusy { autoRestore.cancelPendingForUserChange() }
    }
    private func readyToChangeDisplay() -> Bool {
        if layouts.isPending || layouts.isBusy { model.activeSection = .layouts; showWindow(); return false }
        if model.hasPendingConfiguration || model.isBusy { model.activeSection = .resolution; showWindow(); return false }
        if workspace.isBusy || workspace.hasConnectedScreens { model.activeSection = .virtual; showWindow(); return false }
        return true
    }
    @objc func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func restore() { Task { @MainActor in await model.restoreAll() } }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "HiDPI Studio", .applicationVersion: "2.3",
            .credits: NSAttributedString(string: "独立实现的 macOS 显示管理工具\nHiDPI · 软件滤镜 · 虚拟屏幕 · 画中画 · 布局预设\n与 BetterDisplay 无关联")])
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        terminating = true
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
