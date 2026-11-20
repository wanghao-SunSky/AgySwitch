import AgySwitchCore
import AgySwitchUI
import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    private let model = MenuModel()
    private let work = LocalWork()
    private let preferences = UserDefaults.standard
    private let loginItem = LoginItem()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var feedbackExpiry: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.register(defaults: ["autoWatchEnabled": false, "defaultCooldownSeconds": 18_000])
        model.automatic = preferences.bool(forKey: "autoWatchEnabled")
        let cooldown = preferences.integer(forKey: "defaultCooldownSeconds")
        if [18_000, 10_800, 3_600].contains(cooldown) { model.cooldown = cooldown }
        model.opensAtLogin = (try? loginItem.enabled()) ?? false
        model.send = { [weak self] in self?.handle($0) }
        work.onUpdate = { [weak self] in self?.watcherUpdated($0) }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let icon = NSImage(systemSymbolName: MenuPopoverView.symbol, accessibilityDescription: "AgySwitch")?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
            icon?.isTemplate = true
            button.image = icon
            button.target = self
            button.action = #selector(togglePopover)
            button.setAccessibilityLabel("AgySwitch")
        }
        statusItem = item
        updateTooltip()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let host = NSHostingController(rootView: MenuPopoverView(model: model) { [weak self] height in
            guard height > 0 else { return }
            self?.popover.contentSize = NSSize(width: MenuPopoverView.width, height: ceil(height))
        })
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize

        work.configure(automatic: model.automatic, cooldown: model.cooldown)
        reload()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        work.finish { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            reload()
        }
    }

    private func handle(_ action: MenuAction) {
        switch action {
        case .refresh: reload(showFeedback: true)
        case .inspect:
            run { try $0.inspect(logDirectory: LocalWork.logDirectory) } message: { result in
                let login = result.hasLogin ? "当前登录可读" : "当前未登录"
                let logs = result.logsReadable ? "日志可读" : "日志目录缺失或不可读"
                let vault = result.invalidVaultCount == 0 ? "快照检查通过" : "\(result.invalidVaultCount) 个快照异常"
                return MenuFeedback(result.invalidVaultCount == 0 ? .info : .warning,
                                    "\(login) · \(result.accountCount) 个账号", detail: "\(logs) · \(vault)")
            }
        case .openLogs:
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: LocalWork.logDirectory.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                NSWorkspace.shared.open(LocalWork.logDirectory)
            } else {
                show(MenuFeedback(.warning, "日志目录尚未创建", detail: "运行 agy 后可在这里打开。"))
            }
        case .toggleLoginItem:
            do {
                model.opensAtLogin = try loginItem.toggle()
                show(MenuFeedback(.success, model.opensAtLogin ? "下次登录时启动" : "已关闭登录时启动"))
            } catch {
                show(MenuFeedback(.warning, "无法更新登录时启动设置"))
            }
        case .quit:
            NSApp.terminate(nil)
        case let .save(alias, email):
            run { try $0.save(alias: alias, expectedEmail: email) } message: { MenuFeedback(.success, "已保存 " + $0.alias) }
        case let .select(id):
            run(mutatingLogin: true, { try $0.switchTo(accountID: id) }, message: switchFeedback)
        case .next:
            run(mutatingLogin: true, { try $0.next() }, message: switchFeedback)
        case let .rename(id, alias):
            run { try $0.rename(accountID: id, alias: alias) } message: { _ in MenuFeedback(.success, "别名已更新") }
        case let .remove(id):
            run { try $0.remove(accountID: id) } message: { _ in MenuFeedback(.success, "已移除账号") }
        case let .cooldown(id, mark):
            let seconds = mark ? Double(model.cooldown) : nil
            run { try $0.cooldown(accountID: id, seconds: seconds) } message: { _ in
                MenuFeedback(.success, mark ? "已标记冷却" : "已清除冷却")
            }
        case let .setAutomatic(enabled):
            model.automatic = enabled
            preferences.set(enabled, forKey: "autoWatchEnabled")
            if !enabled { model.listening = false }
            work.configure(automatic: enabled, cooldown: model.cooldown)
            if enabled { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
            updateTooltip()
        case let .setDefaultCooldown(seconds):
            model.cooldown = seconds
            preferences.set(seconds, forKey: "defaultCooldownSeconds")
            work.configure(automatic: model.automatic, cooldown: seconds)
        }
    }

    private func watcherUpdated(_ update: LocalWork.Update) {
        switch update {
        case let .listening(listening):
            model.listening = model.automatic && listening
            updateTooltip()
        case let .switched(result):
            if result.changed { notify(alias: result.target) }
            show(switchFeedback(result))
            reload()
        case let .warning(message):
            if model.automatic { show(MenuFeedback(.warning, message)) }
            reload()
        }
    }

    private func updateTooltip() {
        let current = model.pool.registry.accounts.first { $0.accountID == model.pool.activeID }?.alias
            ?? model.pool.currentEmail ?? "未登录"
        statusItem?.button?.toolTip = "AgySwitch · \(current)\(model.listening ? " · 监听中" : "")"
    }

    private func reload(showFeedback: Bool = false) {
        guard !model.busy else { return }
        model.busy = true
        work.refresh { [weak self] result in
            guard let self else { return }
            model.busy = false
            switch result {
            case let .success(snapshot):
                model.pool = snapshot
                updateTooltip()
                if showFeedback { show(MenuFeedback(.success, "账号池已刷新")) }
            case let .failure(error):
                show(MenuFeedback(.warning, safeMessage(error)))
            }
        }
    }

    private func run<T>(mutatingLogin: Bool = false, _ action: @escaping (AccountPool) throws -> T,
                        message: @escaping (T) -> MenuFeedback) {
        guard !model.busy else { return }
        model.busy = true
        work.perform(mutatingLogin: mutatingLogin, action) { [weak self] result, snapshot in
            guard let self else { return }
            model.busy = false
            if case let .success(pool) = snapshot {
                model.pool = pool
                updateTooltip()
            }
            switch result {
            case let .success(value): show(message(value))
            case let .failure(error): show(MenuFeedback(.warning, safeMessage(error)))
            }
        }
    }

    private func switchFeedback(_ outcome: SwitchOutcome) -> MenuFeedback {
        if !outcome.changed { return MenuFeedback(.info, "正在使用 " + outcome.target) }
        return MenuFeedback(.success, "已切至 " + outcome.target, detail: "新开或重启 agy / T3 会话生效")
    }

    private func show(_ feedback: MenuFeedback) {
        feedbackExpiry?.cancel()
        model.feedback = feedback
        let clear = DispatchWorkItem { [weak self] in self?.model.feedback = nil }
        feedbackExpiry = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + (feedback.kind == .warning ? 8 : 5), execute: clear)
    }

    private func notify(alias: String) {
        let content = UNMutableNotificationContent()
        content.title = "AgySwitch 已切至 " + alias
        content.body = "新开或重启 agy / T3 会话生效。"
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            guard error != nil else { return }
            Self.fallbackNotify(alias: alias)
        }
    }

    nonisolated private static func fallbackNotify(alias: String) {
        let script = """
        on run argv
        display notification ("已切至 " & (item 1 of argv) & "，新开或重启 agy / T3 会话生效。") with title "AgySwitch"
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, alias]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}

@main
struct AgySwitchApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let applicationDelegate = ApplicationDelegate()
        application.setActivationPolicy(.accessory)
        application.delegate = applicationDelegate
        withExtendedLifetime(applicationDelegate) { application.run() }
    }
}
