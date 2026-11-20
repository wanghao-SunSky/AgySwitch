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
    private var language: DisplayLanguage { model.displayLanguage }

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.register(defaults: ["autoWatchEnabled": false, "defaultCooldownSeconds": 18_000,
                                        AppLanguage.preferenceKey: AppLanguage.system.rawValue])
        model.language = preferences.string(forKey: AppLanguage.preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        model.automatic = preferences.bool(forKey: "autoWatchEnabled")
        let cooldown = preferences.integer(forKey: "defaultCooldownSeconds")
        if [18_000, 10_800, 3_600].contains(cooldown) { model.cooldown = cooldown }
        model.opensAtLogin = (try? loginItem.enabled()) ?? false
        model.send = { [weak self] in self?.handle($0) }
        work.onUpdate = { [weak self] in self?.watcherUpdated($0) }
        NotificationCenter.default.addObserver(self, selector: #selector(systemLocaleChanged),
                                               name: NSLocale.currentLocaleDidChangeNotification, object: nil)

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

    @objc private func systemLocaleChanged() {
        model.refreshDisplayLanguage()
        updateTooltip()
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
                return MenuFeedback(result.invalidVaultCount == 0 ? .info : .warning,
                                    .statusTitle(signedIn: result.hasLogin, accountCount: result.accountCount),
                                    detail: .statusDetail(logsReadable: result.logsReadable,
                                                          invalidVaultCount: result.invalidVaultCount))
            }
        case .openLogs:
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: LocalWork.logDirectory.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                NSWorkspace.shared.open(LocalWork.logDirectory)
            } else {
                show(MenuFeedback(.warning, .logsMissing, detail: .logsMissingHint))
            }
        case .toggleLoginItem:
            do {
                model.opensAtLogin = try loginItem.toggle()
                show(MenuFeedback(.success, model.opensAtLogin ? .loginItemEnabled : .loginItemDisabled))
            } catch {
                show(MenuFeedback(.warning, .loginItemFailed))
            }
        case .quit:
            NSApp.terminate(nil)
        case let .save(alias, email):
            run { try $0.save(alias: alias, expectedEmail: email) } message: { MenuFeedback(.success, .saved($0.alias)) }
        case let .select(id):
            run(mutatingLogin: true, { try $0.switchTo(accountID: id) }, message: switchFeedback)
        case .next:
            run(mutatingLogin: true, { try $0.next() }, message: switchFeedback)
        case let .rename(id, alias):
            run { try $0.rename(accountID: id, alias: alias) } message: { _ in MenuFeedback(.success, .aliasUpdated) }
        case let .remove(id):
            run { try $0.remove(accountID: id) } message: { _ in MenuFeedback(.success, .accountRemoved) }
        case let .cooldown(id, mark):
            let seconds = mark ? Double(model.cooldown) : nil
            run { try $0.cooldown(accountID: id, seconds: seconds) } message: { _ in
                MenuFeedback(.success, mark ? .cooldownMarked : .cooldownCleared)
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
        case let .setLanguage(language):
            model.language = language
            preferences.set(language.rawValue, forKey: AppLanguage.preferenceKey)
            updateTooltip()
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
        case let .warning(error):
            if model.automatic { show(MenuFeedback(.warning, error.text)) }
            reload()
        }
    }

    private func updateTooltip() {
        let current = model.pool.registry.accounts.first { $0.accountID == model.pool.activeID }?.alias
            ?? model.pool.currentEmail ?? language[.signedOut]
        let monitoring = model.listening ? [language[.monitoring]] : []
        statusItem?.button?.toolTip = (["AgySwitch", current] + monitoring).joined(separator: " · ")
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
                if showFeedback { show(MenuFeedback(.success, .poolRefreshed)) }
            case let .failure(error):
                show(MenuFeedback(.warning, AppError(redacting: error).text))
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
            case let .failure(error): show(MenuFeedback(.warning, AppError(redacting: error).text))
            }
        }
    }

    private func switchFeedback(_ outcome: SwitchOutcome) -> MenuFeedback {
        MenuFeedback.switchResult(target: outcome.target, changed: outcome.changed)
    }

    private func show(_ feedback: MenuFeedback) {
        feedbackExpiry?.cancel()
        model.feedback = feedback
        let clear = DispatchWorkItem { [weak self] in self?.model.feedback = nil }
        feedbackExpiry = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + (feedback.kind == .warning ? 8 : 5), execute: clear)
    }

    private func notify(alias: String) {
        let title = LocalizedText.switched(alias).localized(in: language)
        let body = language[.reopenSession]
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            guard error != nil else { return }
            Self.fallbackNotify(title: title, body: body)
        }
    }

    nonisolated private static func fallbackNotify(title: String, body: String) {
        let script = """
        on run argv
        display notification (item 2 of argv) with title "AgySwitch" subtitle (item 1 of argv)
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, title, body]
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
