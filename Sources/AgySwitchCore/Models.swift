import Foundation

public struct AppError: LocalizedError {
    public let message: String

    // Call sites supply fixed text, never values from a log or credential.
    init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct Identity: Equatable {
    public let email: String
    public let authMethod: String

    public static func parse(_ raw: Data) throws -> Identity {
        let prefix = Data("go-keyring-base64:".utf8)
        var bytes = raw
        if bytes.starts(with: [48, 120]) || bytes.starts(with: [48, 88]) {
            if let decoded = Data(hexBytes: bytes.dropFirst(2)) { bytes = decoded }
        } else if let decoded = Data(hexBytes: bytes) {
            bytes = decoded
        }
        if bytes.starts(with: prefix) {
            guard let decoded = Data(base64Encoded: Data(bytes.dropFirst(prefix.count))) else {
                throw invalid
            }
            bytes = decoded
        }
        // Python json.loads(bytes) also accepts a UTF-8 BOM and UTF-16/32.
        guard let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let email = object["id_token_email"] as? String, Validation.emailIsValid(email),
              let method = object["auth_method"] as? String, Validation.authMethod.matchesWhole(method),
              object["token"] is [String: Any], object["writer_id"] is String else {
            throw invalid
        }
        return Identity(email: email, authMethod: method)
    }

    private static let invalid = AppError("agy 凭证格式或字段无效。")
}

extension Data {
    init?<Bytes: Collection>(hexBytes: Bytes) where Bytes.Element == UInt8 {
        guard !hexBytes.isEmpty, hexBytes.count.isMultiple(of: 2) else { return nil }
        func digit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
        var result = Data(capacity: hexBytes.count / 2)
        var input = hexBytes.makeIterator()
        while let a = input.next(), let b = input.next() {
            guard let high = digit(a), let low = digit(b) else { return nil }
            result.append(high << 4 | low)
        }
        self = result
    }

    var hex: String {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }
}

extension NSRegularExpression {
    func matchesWhole(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..., in: value)
        return firstMatch(in: value, range: range)?.range == range
    }
}

enum Validation {
    static let alias = try! NSRegularExpression(pattern: #"[A-Za-z0-9][A-Za-z0-9_.-]{0,47}"#)
    static let emailPattern = #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9-]+(?:.[A-Za-z0-9-]+)+"#
    static let email = try! NSRegularExpression(pattern: emailPattern)
    static let authMethod = try! NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9_.-]{0,31}"#)
    static let accountID = try! NSRegularExpression(pattern: #"[0-9a-f]{64}"#)
    static func emailIsValid(_ value: String) -> Bool { value.count <= 254 && email.matchesWhole(value) }
    static func timestamp(_ value: Double) -> Bool { (0...253_402_300_799).contains(value) && value.isFinite }
}

public enum VaultStore: String, Codable {
    case keychain, file
}

public enum ExhaustionReason: String, Codable, Equatable {
    case manual, nextMarkExhausted = "next_mark_exhausted"
    case resource = "RESOURCE_EXHAUSTED", quota = "QUOTA_EXHAUSTED"
    case stopReason = "STOP_REASON_QUOTA_EXHAUSTED", errorCode = "ERROR_CODE_RESOURCE_EXHAUSTED"
    case capacity = "MODEL_CAPACITY_EXHAUSTED", http429 = "HTTP_429"
}

public struct Account: Codable, Equatable, Identifiable {
    public let accountID: String
    public var alias: String
    public var email: String
    public var authMethod: String
    public let store: VaultStore
    public let addedAt: Double
    public var lastUsedAt: Double
    public var cooldownUntil: Double?
    public var exhaustedReason: ExhaustionReason?
    public var id: String { accountID }

    public init(accountID: String, alias: String, email: String, authMethod: String = "oauth",
                store: VaultStore = .keychain, addedAt: Double = 0, lastUsedAt: Double = 0,
                cooldownUntil: Double? = nil, exhaustedReason: ExhaustionReason? = nil) {
        self.accountID = accountID
        self.alias = alias
        self.email = email
        self.authMethod = authMethod
        self.store = store
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
        self.cooldownUntil = cooldownUntil
        self.exhaustedReason = exhaustedReason
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case accountID = "account_id", alias, email, authMethod = "auth_method", store
        case addedAt = "added_at", lastUsedAt = "last_used_at"
        case cooldownUntil = "cooldown_until", exhaustedReason = "exhausted_reason"
    }

    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: Registry.AnyKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: Set(CodingKeys.allCases.map(\.rawValue))) else {
            throw Registry.invalid
        }
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try fields.decode(String.self, forKey: .accountID)
        alias = try fields.decode(String.self, forKey: .alias)
        email = try fields.decode(String.self, forKey: .email)
        authMethod = try fields.decode(String.self, forKey: .authMethod)
        store = try fields.decode(VaultStore.self, forKey: .store)
        addedAt = try fields.decode(Double.self, forKey: .addedAt)
        lastUsedAt = try fields.decode(Double.self, forKey: .lastUsedAt)
        cooldownUntil = try fields.decodeIfPresent(Double.self, forKey: .cooldownUntil)
        exhaustedReason = try fields.decodeIfPresent(ExhaustionReason.self, forKey: .exhaustedReason)
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(accountID, forKey: .accountID)
        try fields.encode(alias, forKey: .alias)
        try fields.encode(email, forKey: .email)
        try fields.encode(authMethod, forKey: .authMethod)
        try fields.encode(store, forKey: .store)
        try fields.encode(addedAt, forKey: .addedAt)
        try fields.encode(lastUsedAt, forKey: .lastUsedAt)
        try fields.encode(cooldownUntil, forKey: .cooldownUntil)
        try fields.encode(exhaustedReason, forKey: .exhaustedReason)
    }

    var isValid: Bool {
        Validation.accountID.matchesWhole(accountID) && Validation.alias.matchesWhole(alias)
        && Validation.emailIsValid(email) && Validation.authMethod.matchesWhole(authMethod)
        && Validation.timestamp(addedAt) && Validation.timestamp(lastUsedAt)
        && (cooldownUntil.map { Validation.timestamp($0) && exhaustedReason != nil } ?? (exhaustedReason == nil))
    }

    public func cooling(at now: Double) -> Bool { cooldownUntil.map { $0 > now } ?? false }
}

public struct Registry: Codable, Equatable {
    public var accounts: [Account]
    public var lastActiveAlias: String?

    public init(accounts: [Account] = [], lastActiveAlias: String? = nil) {
        self.accounts = accounts
        self.lastActiveAlias = lastActiveAlias
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, accounts, lastActiveAlias = "last_active_alias"
    }

    struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static let invalid = AppError("registry.json 格式无效，请检查账号池元数据。")

    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: AnyKey.self)
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        guard Set(all.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)),
              try fields.decode(Int.self, forKey: .version) == 1 else { throw Self.invalid }
        accounts = try fields.decode([Account].self, forKey: .accounts)
        lastActiveAlias = try fields.decodeIfPresent(String.self, forKey: .lastActiveAlias)
        guard isValid else { throw Self.invalid }
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(1, forKey: .version)
        try fields.encode(accounts, forKey: .accounts)
        try fields.encode(lastActiveAlias, forKey: .lastActiveAlias)
    }

    var isValid: Bool {
        accounts.allSatisfy(\.isValid)
        && Set(accounts.map(\.accountID)).count == accounts.count
        && Set(accounts.map { $0.email.lowercased() }).count == accounts.count
        && Set(accounts.map { $0.alias.lowercased() }).count == accounts.count
        && (lastActiveAlias.map { alias in accounts.contains { $0.alias == alias } } ?? true)
    }

    func index(email: String) -> Int? {
        accounts.firstIndex { $0.email.lowercased() == email.lowercased() }
    }

    func index(alias: String) -> Int? {
        accounts.firstIndex { $0.alias.lowercased() == alias.lowercased() }
    }
}
