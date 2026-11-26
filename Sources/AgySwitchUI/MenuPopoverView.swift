import AgySwitchCore
import SwiftUI

public enum MenuAction {
    case refresh, checkLogin, inspect, openLogs, toggleLoginItem, quit
    case reloadClients, setAutoReload(Bool)
    case beginAddAccount
    case save(alias: String, email: String)
    case select(String), next, rename(id: String, alias: String), remove(String)
    case cooldown(id: String, mark: Bool)
    case setAutomatic(Bool), setDefaultCooldown(Int)
    case setLanguage(AppLanguage)
}

public struct MenuFeedback: Equatable {
    public enum Kind { case success, info, warning }

    public let kind: Kind
    public let title: LocalizedText
    public let detail: LocalizedText?
    public let offersReload: Bool

    public init(_ kind: Kind, _ title: LocalizedText, detail: LocalizedText? = nil, offersReload: Bool = false) {
        self.offersReload = offersReload
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    public init(_ kind: Kind, _ title: AppLabel, detail: AppLabel? = nil) {
        self.init(kind, title.text, detail: detail?.text)
    }

    public static func switchResult(target: String, changed: Bool, offersReload: Bool = false) -> Self {
        if changed { return Self(.success, .switched(target), detail: AppLabel.reopenSession.text, offersReload: offersReload) }
        return Self(.info, .alreadyUsing(target))
    }

    var icon: String {
        switch kind {
        case .success: return "checkmark.circle"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.circle"
        }
    }
}

public final class MenuModel: ObservableObject {
    @Published public private(set) var pool: PoolSnapshot
    @Published var hoveredAccount: String?

    @MainActor func hover(_ id: String, inside: Bool) {
        if inside {
            if hoveredAccount != id { hoveredAccount = id }
        } else if hoveredAccount == id {
            clearHover()
        }
    }

    @MainActor public func clearHover() {
        if hoveredAccount != nil { hoveredAccount = nil }
    }

    @Published public var autoReload = false
    @Published public var automatic: Bool
    @Published public var listening: Bool
    @Published public var cooldown: Int
    @Published public var opensAtLogin: Bool
    @Published public var feedback: MenuFeedback?
    @Published public private(set) var refreshError: AppError?
    @Published public var accountActionInProgress = false
    @Published public var pendingClientReloads = 0
    public var busy: Bool { accountActionInProgress || pendingClientReloads > 0 }
    @Published public var showsAddAccount = false
    @Published public var signInStarted = false {
        didSet { updateLoginPolling() }
    }
    private var popoverVisible = false
    private var loginPoll: Timer?
    @Published public var language: AppLanguage {
        didSet { refreshDisplayLanguage() }
    }
    @Published public private(set) var displayLanguage: DisplayLanguage

    public var send: (MenuAction) -> Void = { _ in }

    public init(pool: PoolSnapshot = PoolSnapshot(), automatic: Bool = false, listening: Bool = false,
                cooldown: Int = 18_000, opensAtLogin: Bool = false, feedback: MenuFeedback? = nil,
                language: AppLanguage = .system) {
        self.pool = pool
        self.automatic = automatic
        self.listening = listening
        self.cooldown = cooldown
        self.opensAtLogin = opensAtLogin
        self.feedback = feedback
        self.language = language
        displayLanguage = language.resolved()
    }

    public func refreshDisplayLanguage() {
        let resolved = language.resolved()
        if displayLanguage != resolved { displayLanguage = resolved }
    }

    @discardableResult
    public func updatePool(_ snapshot: PoolSnapshot) -> Bool {
        if refreshError != nil { refreshError = nil }
        if signInStarted, snapshot.currentEmail != nil {
            finishSignIn()
        }
        guard pool != snapshot else { return false }
        pool = snapshot
        return true
    }

    public func reportRefreshFailure(_ error: Error) {
        let safe = AppError(redacting: error)
        if refreshError != safe { refreshError = safe }
    }

    public func setPopoverVisible(_ visible: Bool) {
        popoverVisible = visible
        updateLoginPolling()
    }

    private func updateLoginPolling() {
        guard signInStarted, popoverVisible else {
            loginPoll?.invalidate()
            loginPoll = nil
            return
        }
        guard loginPoll == nil else { return }
        let timer = Timer(fire: Date(timeIntervalSinceNow: 2), interval: 2, repeats: true) { [weak self] _ in
            self?.send(.checkLogin)
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        loginPoll = timer
    }

    deinit { loginPoll?.invalidate() }

    public func finishSignIn() {
        guard signInStarted else { return }
        signInStarted = false
        showsAddAccount = false
    }

    public var unsavedEmail: String? { pool.activeID == nil ? pool.currentEmail : nil }
}

public struct MenuPopoverView: View {
    public static let width: CGFloat = 316
    public static let symbol = "arrow.left.arrow.right"

    @ObservedObject private var model: MenuModel
    @FocusState private var focused: Bool
    @State private var editor: Editor?
    @State private var input = ""
    @State private var removal: Account?
    private let referenceDate: Date?

    private enum Editor: Equatable {
        case save(String), rename(String)

        var buttonTitle: AppLabel {
            switch self {
            case .save: return .save
            case .rename: return .rename
            }
        }

        var placeholder: AppLabel {
            switch self {
            case .save: return .aliasPlaceholder
            case .rename: return .newAliasPlaceholder
            }
        }
    }

    public init(model: MenuModel) {
        self.model = model
        referenceDate = nil
    }

    init(model: MenuModel, referenceDate: Date) {
        self.model = model
        self.referenceDate = referenceDate
    }

    private var activeID: String? { model.pool.activeID }
    private var accounts: [Account] { model.pool.registry.accounts }
    private var language: DisplayLanguage { model.displayLanguage }

    public var body: some View {
        VStack(spacing: 10) {
            header
            hairline
            if let error = model.refreshError {
                feedbackView(MenuFeedback(.warning, error.text))
            }
            if model.showsAddAccount { addAccountCard }
            if let email = model.unsavedEmail {
                saveCapsule(email)
            }
            accountList
            hairline
            footer
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.pool.currentEmail) { _ in
            if case .save = editor { editor = nil }
        }
        .onChange(of: model.pool.registry) { registry in
            switch editor {
            case .save where model.pool.activeID != nil:
                editor = nil
            case let .rename(id):
                let alias = registry.accounts.first { $0.id == id }?.alias
                if alias == nil || alias == input { editor = nil }
            default:
                break
            }
        }
        .alert(language[.confirmRemove], isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
               presenting: removal) { account in
            Button(language[.cancel], role: .cancel) { removal = nil }
            Button(language[.remove], role: .destructive) { model.send(.remove(account.id)); removal = nil }
        } message: { account in
            Text(LocalizedText.removeConfirmation(account.alias).localized(in: language))
        }
        .environment(\.locale, Locale(identifier: language.rawValue))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("AgySwitch")
                .font(.system(size: 14, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Circle()
                .fill(model.listening ? Color.green : Color.secondary.opacity(0.38))
                .frame(width: 5, height: 5)
                .accessibilityLabel(language[model.listening ? .listening : .listenerStopped])
            Spacer()
            Button { model.showsAddAccount.toggle() } label: {
                Image(systemName: "plus")
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(model.showsAddAccount ? 0.14 : 0)))
            }
            .buttonStyle(QuietIconStyle())
            .accessibilityLabel(language[.addAccount])
            .accessibilityAddTraits(model.showsAddAccount ? .isSelected : [])

            Button { model.send(.refresh) } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(QuietIconStyle())
            .disabled(model.busy)
            .accessibilityLabel(language[.refresh])
            MoreButton(model: model)
        }
        .padding(.leading, 3)
        .frame(height: 26)
    }

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
            .accessibilityHidden(true)
    }

    private var addAccountCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(language[.addAccount])
                .font(.system(size: 12, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            if model.signInStarted {
                Text(language[accounts.isEmpty ? .addFirstAccountAfterLaunch : .addAccountAfterLaunch])
                if model.pool.currentEmail == nil {
                    signInButton(.reopenSignIn)
                }
            } else {
                Text(language[.addAccountGuide])
                signInButton(.signInToAnotherAccount)
                Text(language[.manualSignInGuide])
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.045)))
    }

    private func signInButton(_ title: AppLabel) -> some View {
        Button(language[title]) { model.send(.beginAddAccount) }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(model.busy)
    }

    private func saveCapsule(_ email: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(language[.unsavedAccount])
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .fixedSize()
                    Text(email).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 2)
                if editor != .save(email) {
                    Button(language[.save]) { model.send(.save(alias: model.pool.suggestedAlias, email: email)) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(model.busy)
                        .contextMenu {
                            Button(language[.renameAlias]) { begin(.save(email), value: model.pool.suggestedAlias) }
                        }
                }
            }
            if editor == .save(email) { aliasEditor(.save(email)) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.09)))
    }

    @ViewBuilder private var accountList: some View {
        if accounts.isEmpty {
            if model.unsavedEmail == nil && model.refreshError == nil {
                HStack(spacing: 9) {
                    Image(systemName: "person.2").font(.system(size: 15)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(language[.noAccounts]).font(.system(size: 12, weight: .medium))
                        Text(language[.noAccountsHint])
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 9)
            }
        } else if accounts.count > 7 {
            ScrollView { rows }.frame(height: 305)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(accounts) { account in
                AccountRow(account: account, active: activeID == account.id, date: referenceDate, language: language,
                           busy: model.busy, hovered: model.hoveredAccount == account.id, select: { model.send(.select(account.id)) },
                           cooldown: { model.send(.cooldown(id: account.id, mark: $0)) },
                           rename: { begin(.rename(account.id), value: account.alias) },
                           remove: { removal = account })
                    .onHover { model.hover(account.id, inside: $0) }
                if editor == .rename(account.id) {
                    aliasEditor(.rename(account.id))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Text(language[.autoSwitch])
                    .font(.system(size: 12.5, weight: .regular))
                    .fixedSize()
                Spacer(minLength: 4)
                Menu {
                    ForEach([18_000, 10_800, 3_600], id: \.self) { seconds in
                        let duration = LocalizedText.hours(seconds / 3600).localized(in: language)
                        Button {
                            model.send(.setDefaultCooldown(seconds))
                        } label: {
                            if model.cooldown == seconds {
                                Label(duration, systemImage: "checkmark")
                            } else {
                                Text(duration)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(model.cooldown / 3600)h").monospacedDigit()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .semibold))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(language[.defaultCooldown])
                .accessibilityValue(LocalizedText.hours(model.cooldown / 3600).localized(in: language))

                Toggle("", isOn: Binding(get: { model.automatic }, set: { model.send(.setAutomatic($0)) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.accentColor)
                    .controlSize(.mini)
                    .accessibilityLabel(language[.autoSwitch])
            }
            .padding(.horizontal, 3)

            Button { model.send(.next) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold))
                    Text(language[.switchNext])
                        .font(.system(size: 12, weight: .medium))
                        .fixedSize()
                    Spacer(minLength: 4)
                    ZStack(alignment: .trailing) {
                        if model.busy {
                            ProgressView().controlSize(.mini).accessibilityLabel(language[.working])
                        } else {
                            Text("⌘↩")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 24, height: 18, alignment: .trailing)
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionBarStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.busy || accounts.isEmpty || (accounts.count == 1 && activeID != nil))

            // Reserve room for action feedback so its arrival and expiry don't move the controls.
            ZStack(alignment: .topLeading) {
                if let feedback = model.feedback {
                    ViewThatFits(in: .vertical) {
                        feedbackView(feedback).fixedSize(horizontal: false, vertical: true)
                        ScrollView { feedbackView(feedback) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 48, alignment: .topLeading)
        }
    }

    private func feedbackView(_ feedback: MenuFeedback) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: feedback.icon)
                .foregroundStyle(feedback.kind == .warning ? Color.orange : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(feedback.title.localized(in: language)).fontWeight(.medium)
                    if feedback.offersReload && !model.autoReload {
                        Spacer(minLength: 2)
                        Button(language[.reloadClients]) { model.send(.reloadClients) }
                            .controlSize(.mini)
                            .fixedSize()
                            .disabled(model.busy)
                    }
                }
                if let detail = feedback.detail { Text(detail.localized(in: language)).foregroundStyle(.secondary) }
            }
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    private func aliasEditor(_ editing: Editor) -> some View {
        HStack(spacing: 6) {
            TextField(language[editing.placeholder], text: $input)
                .font(.system(size: 12))
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit { submit(editing) }
                .onExitCommand { editor = nil }
            Button(language[editing.buttonTitle]) { submit(editing) }
                .controlSize(.small)
                .disabled(input.isEmpty || model.busy)
            Button { editor = nil } label: {
                Image(systemName: "xmark").frame(width: 18, height: 20)
            }
            .buttonStyle(QuietIconStyle())
            .accessibilityLabel(language[.cancelEdit])
        }
    }

    private func begin(_ editing: Editor, value: String) {
        input = value
        editor = editing
    }

    private func submit(_ editing: Editor) {
        guard !input.isEmpty, !model.busy else { return }
        switch editing {
        case let .save(email): model.send(.save(alias: input, email: email))
        case let .rename(id):
            if accounts.first(where: { $0.id == id })?.alias == input {
                editor = nil
            } else {
                model.send(.rename(id: id, alias: input))
            }
        }
    }
}

struct MoreButton: View {
    @ObservedObject var model: MenuModel
    @State private var anchor = NSView()
    @State private var tracking = false

    private struct Anchor: NSViewRepresentable {
        let view: NSView
        func makeNSView(context: Context) -> NSView { view }
        func updateNSView(_ view: NSView, context: Context) {}
    }

    private final class Item: NSMenuItem {
        private let actionBody: () -> Void
        init(_ title: String, action: @escaping () -> Void) {
            actionBody = action
            super.init(title: title, action: #selector(invoke), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError("Programmatic menu item") }
        @objc private func invoke() { actionBody() }
    }

    var body: some View {
        Button {
            let menu = makeMenu()
            tracking = true
            DispatchQueue.main.async {
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -3), in: anchor)
                tracking = false
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 24)
        }
        .buttonStyle(QuietIconStyle(tracking: tracking))
        .background(Anchor(view: anchor))
        .accessibilityLabel(model.displayLanguage[.more])
    }

    func makeMenu() -> NSMenu {
        let language = model.displayLanguage
        let menu = NSMenu()
        menu.autoenablesItems = false
        let languages = NSMenu()
        for option in AppLanguage.allCases {
            let item = Item(option.menuTitle(in: language)) { model.send(.setLanguage(option)) }
            item.state = model.language == option ? .on : .off
            languages.addItem(item)
        }
        let languageItem = NSMenuItem(title: language[.language], action: nil, keyEquivalent: "")
        menu.addItem(languageItem)
        languageItem.submenu = languages
        menu.addItem(.separator())
        func add(_ label: AppLabel, _ action: MenuAction, checked: Bool = false, enabled: Bool = true) {
            let item = Item(language[label]) { model.send(action) }
            item.state = checked ? .on : .off
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add(.autoReload, .setAutoReload(!model.autoReload), checked: model.autoReload)
        add(.reloadMenu, .reloadClients, enabled: !model.busy)
        menu.addItem(.separator())
        add(model.opensAtLogin ? .disableLoginItem : .enableLoginItem, .toggleLoginItem)
        add(.openLogs, .openLogs)
        add(.inspect, .inspect)
        menu.addItem(.separator())
        add(.quit, .quit)
        menu.items.last?.keyEquivalent = "q"
        return menu
    }
}

private struct QuietIconStyle: ButtonStyle {
    var tracking = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Icon(label: configuration.label, pressed: configuration.isPressed || tracking, enabled: enabled)
    }

    private struct Icon<Label: View>: View {
        let label: Label
        let pressed: Bool
        let enabled: Bool
        @State private var hovered = false
        var body: some View {
            label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(enabled ? 1 : 0.45)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(pressed ? 0.12 : hovered && enabled ? 0.06 : 0)))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

private struct ActionBarStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Bar(label: configuration.label, pressed: configuration.isPressed, enabled: enabled)
    }

    private struct Bar<Label: View>: View {
        let label: Label
        let pressed: Bool
        let enabled: Bool
        @State private var hovered = false

        var body: some View {
            label
                .foregroundStyle(enabled ? .primary : .secondary)
                .opacity(enabled ? 1 : 0.48)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(pressed ? 0.11 : hovered && enabled ? 0.08 : 0.05))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

private struct RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(RoundedRectangle(cornerRadius: 10)
            .fill(Color.primary.opacity(configuration.isPressed ? 0.09 : 0)))
    }
}

private struct AccountRow: View {
    let account: Account
    let active: Bool
    let date: Date?
    let language: DisplayLanguage
    let busy: Bool
    let hovered: Bool
    let select: () -> Void
    let cooldown: (Bool) -> Void
    let rename: () -> Void
    let remove: () -> Void

    @State private var countdownDate = Date.now

    var body: some View {
        let now = (date ?? countdownDate).timeIntervalSince1970
        let cooling = account.cooling(at: now)
        Button(action: select) {
            HStack(spacing: 8) {
                rowIdentity
                Spacer(minLength: 1)
                if active {
                    Label(language[.active], systemImage: "checkmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .fixedSize()
                } else if cooling, let until = account.cooldownUntil {
                    let remaining = LocalizedText.cooldownCountdown(until - now)
                    Text(remaining.localized(in: language))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10, weight: .medium))
                        .accessibilityLabel(LocalizedText.cooldownEndsIn(remaining).localized(in: language))
                        .fixedSize()
                    dot(.orange)
                } else {
                    dot(.green).accessibilityLabel(language[.available])
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 43)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
        .disabled(busy)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? Color.accentColor.opacity(hovered ? 0.15 : 0.10)
                      : Color.primary.opacity(hovered ? 0.065 : 0))
        }
        .contextMenu {
            if account.cooldownUntil != nil { Button(language[.clearCooldown]) { cooldown(false) } }
            if !cooling { Button(language[.markCooldown]) { cooldown(true) } }
            Button(language[.renameAlias]) { rename() }
            Divider()
            Button(language[.removeAccount], role: .destructive) { remove() }
        }
        .task(id: account.cooldownUntil) {
            guard date == nil, let until = account.cooldownUntil else { return }
            countdownDate = .now
            while !Task.isCancelled {
                let remaining = until - countdownDate.timeIntervalSince1970
                guard remaining > 0 else { return }
                do { try await Task.sleep(for: .seconds(min(15, remaining))) }
                catch { return }
                countdownDate = .now
            }
        }
    }

    private var rowIdentity: some View {
        VStack(alignment: .leading, spacing: 2.5) {
            Text(account.alias)
                .font(.system(size: 12.5, weight: active ? .semibold : .medium))
                .lineLimit(1)
            Text(account.email)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 5, height: 5).padding(.trailing, 3)
    }
}
