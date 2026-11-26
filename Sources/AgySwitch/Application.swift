import AgySwitchCore
import AgySwitchUI
import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = MenuModel()
    private let clientReloader = ClientReloader(processes: LocalProcessControl(), desktop: WorkspaceDesktopControl())
    private let autoReloadKey = "autoReloadClientsOnSwitch"
    private var clientReloadTask: Task<Void, Never>?
    private let work = LocalWork()
    private let preferences = UserDefaults.standard
    private let loginItem = LoginItem()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var feedbackExpiry: DispatchWorkItem?
    private var reloading = false
    private var refreshFeedbackRequested = false
    private var language: DisplayLanguage { model.displayLanguage }

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.register(defaults: [autoReloadKey: false, "quotaOnHover": true, "autoWatchEnabled": false, "defaultCooldownSeconds": 18_000,
                                        AppLanguage.preferenceKey: AppLanguage.system.rawValue])
        model.language = preferences.string(forKey: AppLanguage.preferenceKey).flatMap(AppLanguage.init(rawValue:)) ?? .system
        model.quotaEnabled = preferences.bool(forKey: "quotaOnHover")
        model.loadQuota = { [work] id in
            try await work.loadQuota(accountID: id, executable: Self.agyExecutable())
        }
        model.autoReload = preferences.bool(forKey: autoReloadKey)
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
        popover.animates = false
        popover.delegate = self
        let host = NSHostingController(rootView: MenuPopoverView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host

        work.configure(automatic: model.automatic, cooldown: model.cooldown)
        reload()
    }

    @objc private func systemLocaleChanged() {
        model.refreshDisplayLanguage()
        updateTooltip()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.clearHover(cancelRequests: true)
        work.finish { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            presentPopover()
            reload()
        }
    }

    private func presentPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidShow(_ notification: Notification) {
        model.setPopoverVisible(true)
    }

    func popoverWillClose(_ notification: Notification) {
        model.clearHover()
        model.setPopoverVisible(false)
    }

    private func handle(_ action: MenuAction) {
        switch action {
        case .setQuotaOnHover(let enabled):
            model.quotaEnabled = enabled
            if !enabled { model.clearHover(cancelRequests: true) }
            preferences.set(enabled, forKey: "quotaOnHover")
        case .setAutoReload(let enabled):
            model.autoReload = enabled
            preferences.set(enabled, forKey: autoReloadKey)
        case .reloadClients:
            guard !model.busy else { return }
            reloadClients()
        case .refresh:
            model.refreshQuota()
            reload(showFeedback: true)
        case .checkLogin: reload()
        case .beginAddAccount: beginAddAccount()
        case .inspect:
            run({ try $0.inspect(logDirectory: LocalWork.logDirectory) }, snapshot: \.snapshot) { result in
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
            run({ try $0.save(alias: alias, expectedEmail: email).snapshot }, snapshot: \.self) { [weak self] _ in
                self?.model.finishSignIn()
                return MenuFeedback(.success, .saved(alias))
            }
        case let .select(id):
            switchAccount { try $0.switchTo(accountID: id) }
        case .next:
            switchAccount { try $0.next() }
        case let .rename(id, alias):
            run({ try $0.rename(accountID: id, alias: alias) }, snapshot: \.self) { _ in MenuFeedback(.success, .aliasUpdated) }
        case let .remove(id):
            run({ try $0.remove(accountID: id) }, snapshot: \.self) { _ in MenuFeedback(.success, .accountRemoved) }
        case let .cooldown(id, mark):
            let seconds = mark ? Double(model.cooldown) : nil
            run({ try $0.cooldown(accountID: id, seconds: seconds) }, snapshot: \.self) { _ in
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
            if result.changed && model.autoReload {
                reloadClients(switchedTo: result.target, login: result.reloadLogin, notifyOnCompletion: true)
            } else {
                if result.changed { notify(alias: result.target, body: language[.reopenSession]) }
                show(.switchResult(target: result.target, changed: result.changed))
            }
            applySnapshot(result.snapshot)
        case let .warning(error):
            if model.automatic { show(MenuFeedback(.warning, error.text)) }
            reload()
        }
    }

    private func updateTooltip() {
        let current = model.refreshError?.text.localized(in: language)
            ?? model.pool.registry.accounts.first { $0.accountID == model.pool.activeID }?.alias
            ?? model.pool.currentEmail ?? language[.signedOut]
        let monitoring = model.listening ? [language[.monitoring]] : []
        statusItem?.button?.toolTip = (["AgySwitch", current] + monitoring).joined(separator: " · ")
    }

    private func reload(showFeedback: Bool = false) {
        guard !model.busy else { return }
        refreshFeedbackRequested = refreshFeedbackRequested || showFeedback
        guard !reloading else { return }
        reloading = true
        work.refresh { [weak self] result in
            guard let self else { return }
            let showFeedback = refreshFeedbackRequested
            refreshFeedbackRequested = false
            reloading = false
            switch result {
            case let .success(snapshot):
                applySnapshot(snapshot)
                if showFeedback { show(MenuFeedback(.success, .poolRefreshed)) }
            case let .failure(error):
                model.reportRefreshFailure(error)
                updateTooltip()
            }

        }
    }

    private func beginAddAccount() {
        guard !model.busy else { return }
        guard let executable = Self.agyExecutable() else {
            show(MenuFeedback(.warning, AppError.agyNotFound.text))
            return
        }
        let workspace = NSWorkspace.shared
        guard let terminal = workspace.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            show(MenuFeedback(.warning, AppError.terminalLaunch.text))
            return
        }
        let script: URL
        do { script = try TerminalCommand.create(for: executable) }
        catch {
            show(MenuFeedback(.warning, AppError.terminalLaunch.text))
            return
        }
        let reopening = model.signInStarted
        model.accountActionInProgress = true
        work.perform({ pool in
            try reopening ? pool.snapshot() : pool.beginAddAccount()
        }, changedLogin: { _ in !reopening }) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(snapshot):
                applySnapshot(snapshot)
                if reopening, snapshot.currentEmail != nil {
                    try? FileManager.default.removeItem(at: script)
                    model.accountActionInProgress = false
                    return
                }
            case let .failure(error):
                try? FileManager.default.removeItem(at: script)
                model.accountActionInProgress = false
                show(MenuFeedback(.warning, AppError(redacting: error).text))
                reload()
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            workspace.open([script], withApplicationAt: terminal, configuration: configuration) { [weak self] _, error in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    model.accountActionInProgress = false
                    if error == nil {
                        feedbackExpiry?.cancel()
                        model.feedback = nil
                        model.signInStarted = true
                        if popover.isShown { reload() }
                    } else {
                        try? FileManager.default.removeItem(at: script)
                        show(MenuFeedback(.warning, AppError.terminalLaunch.text))
                    }
                }
            }
        }
    }

    private static func agyExecutable() -> URL? {
        let files = FileManager.default
        let installerDirectory = files.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = [installerDirectory, "/opt/homebrew/bin", "/usr/local/bin"] + path.split(separator: ":").map(String.init)
        return directories.lazy.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("agy")
        }.first { url in
            var isDirectory: ObjCBool = false
            return files.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && files.isExecutableFile(atPath: url.path)
        }
    }

    private func applySnapshot(_ snapshot: PoolSnapshot) {
        let hadError = model.refreshError != nil
        if model.updatePool(snapshot) || hadError { updateTooltip() }
    }

    private func run<T>(_ action: @escaping (AccountPool) throws -> T, snapshot: KeyPath<T, PoolSnapshot>,
                        changedLogin: @escaping (T) -> Bool = { _ in false },
                        message: @escaping (T) -> MenuFeedback?) {
        guard !model.busy else { return }
        model.accountActionInProgress = true
        work.perform(action, changedLogin: changedLogin) { [weak self] result in
            guard let self else { return }
            model.accountActionInProgress = false
            switch result {
            case let .success(value):
                if let feedback = message(value) { show(feedback) }
                applySnapshot(value[keyPath: snapshot])
            case let .failure(error):
                show(MenuFeedback(.warning, AppError(redacting: error).text))
                reload() // An operation can fail after a verified Keychain write.
            }
        }
    }

    private func switchAccount(_ action: @escaping (AccountPool) throws -> SwitchOutcome) {
        run(action, snapshot: \.snapshot, changedLogin: \.changed) { [self] outcome in
            model.finishSignIn()
            if outcome.changed && model.autoReload {
                reloadClients(switchedTo: outcome.target, login: outcome.reloadLogin)
                return nil
            }
            return .switchResult(target: outcome.target, changed: outcome.changed, offersReload: !model.autoReload)
        }
    }

    private func reloadClients(switchedTo alias: String? = nil, login: ReloadLogin? = nil, notifyOnCompletion: Bool = false) {
        // A watcher event can arrive while a menu-initiated reload is waiting for desktop exit.
        let previous = clientReloadTask
        model.pendingClientReloads += 1
        feedbackExpiry?.cancel()
        model.feedback = MenuFeedback(.info, .reloadingClients)
        clientReloadTask = Task {
            await previous?.value
            defer {
                model.pendingClientReloads -= 1
                if model.pendingClientReloads == 0 { clientReloadTask = nil }
            }
            let target: ReloadLogin?
            do {
                if let login { target = login }
                else { target = try await work.read { try $0.currentReloadLogin() } }
            } catch { show(MenuFeedback(.warning, AppError(redacting: error).text)); return }
            let outcome = await clientReloader.reloadClients {
                if let target { try await work.read { try $0.verifyAfterReload(target) } }
            }
            let detail = LocalizedText.reloadSummary(outcome)
            show(MenuFeedback(outcome.hasWarning ? .warning : .info,
                              alias.map(LocalizedText.switched) ?? AppLabel.reloadResult.text, detail: detail))
            if notifyOnCompletion, let alias { notify(alias: alias, body: detail.localized(in: language)) }

        }
    }

    private func show(_ feedback: MenuFeedback) {
        feedbackExpiry?.cancel()
        model.feedback = feedback
        let clear = DispatchWorkItem { [weak self] in self?.model.feedback = nil }
        feedbackExpiry = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + (feedback.offersReload ? 10 : feedback.kind == .warning ? 8 : 5), execute: clear)
    }

    private func notify(alias: String, body: String) {
        let title = LocalizedText.switched(alias).localized(in: language)
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
