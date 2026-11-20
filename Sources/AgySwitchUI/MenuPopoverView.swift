import AgySwitchCore
import SwiftUI

public enum MenuAction {
    case refresh, inspect, openLogs, toggleLoginItem, quit
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

    public init(_ kind: Kind, _ title: LocalizedText, detail: LocalizedText? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
    }

    public init(_ kind: Kind, _ title: AppLabel, detail: AppLabel? = nil) {
        self.init(kind, title.text, detail: detail?.text)
    }

    public static func switchResult(target: String, changed: Bool) -> Self {
        if changed { return Self(.success, .switched(target), detail: AppLabel.reopenSession.text) }
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
    @Published public var pool: PoolSnapshot
    @Published public var automatic: Bool
    @Published public var listening: Bool
    @Published public var cooldown: Int
    @Published public var opensAtLogin: Bool
    @Published public var feedback: MenuFeedback?
    @Published public var busy = false
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
}

struct PopoverHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

public struct MenuPopoverView: View {
    public static let width: CGFloat = 316
    public static let symbol = "arrow.left.arrow.right"

    @ObservedObject private var model: MenuModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @State private var editor: Editor?
    @State private var input = ""
    @State private var removal: Account?
    private let previewActiveID: String?
    private let referenceDate: Date?
    private let onResize: (CGFloat) -> Void

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

    public init(model: MenuModel, onResize: @escaping (CGFloat) -> Void = { _ in }) {
        self.model = model
        previewActiveID = nil
        referenceDate = nil
        self.onResize = onResize
    }

    init(model: MenuModel, previewActiveID: String?, referenceDate: Date) {
        self.model = model
        self.previewActiveID = previewActiveID
        self.referenceDate = referenceDate
        onResize = { _ in }
    }

    private var activeID: String? { previewActiveID ?? model.pool.activeID }
    private var accounts: [Account] { model.pool.registry.accounts }
    private var language: DisplayLanguage { model.displayLanguage }
    private var availableToSave: String? {
        model.pool.activeID == nil ? model.pool.currentEmail : nil
    }

    public var body: some View {
        VStack(spacing: 10) {
            header
            hairline
            if let email = availableToSave {
                saveCapsule(email)
                    .transition(.opacity)
            }
            accountList
            hairline
            footer
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: PopoverHeight.self, value: geometry.size.height)
            }
        }
        .onPreferenceChange(PopoverHeight.self, perform: onResize)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.feedback)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: availableToSave)
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
                .help(language[model.listening ? .listening : .listenerUnavailable])
                .accessibilityLabel(language[model.listening ? .listening : .listenerStopped])
            Spacer()
            Button { model.send(.refresh) } label: {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(QuietIconStyle())
            .disabled(model.busy)
            .accessibilityLabel(language[.refresh])
            .help(language[.refreshHelp])
            Menu {
                Menu(language[.language]) {
                    Picker(language[.language], selection: Binding(get: { model.language },
                                                                  set: { model.send(.setLanguage($0)) })) {
                        ForEach(AppLanguage.allCases, id: \.self) { option in
                            Text(option.menuTitle(in: language)).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Divider()
                Button(language[model.opensAtLogin ? .disableLoginItem : .enableLoginItem]) { model.send(.toggleLoginItem) }
                Button(language[.openLogs]) { model.send(.openLogs) }
                Button(language[.inspect]) { model.send(.inspect) }
                Divider()
                Button(language[.quit]) { model.send(.quit) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 22, height: 23)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(language[.more])
            .help(language[.moreHelp])
        }
        .padding(.leading, 3)
        .frame(height: 26)
    }

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 0.5)
            .accessibilityHidden(true)
    }

    private func saveCapsule(_ email: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(language[.unsavedAccount])
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .fixedSize()
                    Text(email).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 2)
                if editor != .save(email) {
                    Button(language[.save]) { begin(.save(email), value: model.pool.suggestedAlias) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(model.busy)
                }
            }
            if editor == .save(email) { aliasEditor(.save(email)) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    @ViewBuilder private var accountList: some View {
        if accounts.isEmpty {
            if availableToSave == nil {
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
                           busy: model.busy, select: { model.send(.select(account.id)) },
                           cooldown: { model.send(.cooldown(id: account.id, mark: $0)) },
                           rename: { begin(.rename(account.id), value: account.alias) },
                           remove: { removal = account })
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
                .help(language[.defaultCooldownHelp])

                Toggle("", isOn: Binding(get: { model.automatic }, set: { model.send(.setAutomatic($0)) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.accentColor)
                    .controlSize(.mini)
                    .accessibilityLabel(language[.autoSwitch])
                    .help(language[.autoSwitchHelp])
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
                    if model.busy {
                        ProgressView().controlSize(.mini).accessibilityLabel(language[.loadingPool])
                    } else {
                        Text("⌘↩")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionBarStyle())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.busy || accounts.isEmpty || (accounts.count == 1 && activeID != nil))

            if let feedback = model.feedback {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: feedback.icon)
                        .foregroundStyle(feedback.kind == .success ? Color.accentColor : Color.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feedback.title.localized(in: language)).fontWeight(.medium)
                        if let detail = feedback.detail { Text(detail.localized(in: language)).foregroundStyle(.secondary) }
                    }
                }
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.045)))
                .transition(.opacity)
            }
        }
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

private struct QuietIconStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        Icon(label: configuration.label, pressed: configuration.isPressed, enabled: enabled)
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

private struct AccountRow: View {
    let account: Account
    let active: Bool
    let date: Date?
    let language: DisplayLanguage
    let busy: Bool
    let select: () -> Void
    let cooldown: (Bool) -> Void
    let rename: () -> Void
    let remove: () -> Void

    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { timeline in
            let now = (date ?? timeline.date).timeIntervalSince1970
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
            .buttonStyle(.plain)
            .disabled(busy)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Color.accentColor.opacity(hovered ? 0.15 : 0.10)
                          : Color.primary.opacity(hovered ? 0.065 : 0))
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.13), value: hovered)
            .onHover { hovered = $0 }
            .contextMenu {
                if account.cooldownUntil != nil { Button(language[.clearCooldown]) { cooldown(false) } }
                if !cooling { Button(language[.markCooldown]) { cooldown(true) } }
                Button(language[.renameAlias]) { rename() }
                Divider()
                Button(language[.removeAccount], role: .destructive) { remove() }
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
