import Darwin
import Foundation

struct QuotaEvent: Equatable {
    let reason: ExhaustionReason
    var resetAt: Double?
    let email: String?
}

enum QuotaParser {
    // Logs may include arbitrary prompt text and credentials. Only typed event fields leave this parser.
    private static let glog = regex(#"^([IWEF])\d{4}\s+\d{2}:\d{2}:\d{2}(?:\.\d+)?\s+\d+\s+([^:\]\r\n]+):\d+\]\s*"#)
    private static let signals: [(ExhaustionReason, String)] = [
        (.stopReason, "STOP_REASON_QUOTA_EXHAUSTED"),
        (.errorCode, "ERROR_CODE_RESOURCE_EXHAUSTED"),
        (.capacity, "MODEL_CAPACITY_EXHAUSTED"),
        (.resource, "RESOURCE_EXHAUSTED|ResourceExhausted"),
        (.quota, #"QUOTA_EXHAUSTED|out\s+of\s+quota|quota\s+(?:exhausted|exceeded)|individual\s+quota\s+reached"#),
        (.http429, #"(?:HTTP(?:/\d+(?:\.\d+)?)?\s+|(?:status(?:[ _-]code)?|code)["']?\s*(?:[=:]\s*|\s+)["']?)429|Too\s+Many\s+Requests"#)
    ]
    private static let signal = regex(#"(?<!\w)(?:"# + signals.map { "(" + $0.1 + ")" }.joined(separator: "|") + #")(?!\w)"#, insensitive: true)
    private static let errorContext = regex(#"\b(?:error|failed|failure|exception|denied|rejected|returned|request|response|status|rate[ -]limit(?:ed)?)\b"#, insensitive: true)
    private static let nonError = regex(
        #"\b(?:retry_model_capacity_exhausted|model[ _-]config(?:uration)?|feature[ _-]flag|loaded\s+config|retry[ _-]policy|example\s+(?:error|status)|expected\s+status|oauth\s+setup\s+failed|dynamic\s+client\s+registration|client\s+registration\s+failed|invalid_client_metadata|mcp\s+server)\b|^(?:user\s+prompt|model\s+output|prompt\s+text|response\s+text)\s*[:=]|^Monitor\s+\S+\s+FINISHED\b"#,
        insensitive: true
    )
    private static let ignoredSource = regex(
        #"^(?:mcp[_a-z0-9-]*|.*_mcp(?:_.*)?|.*plugin.*|runner|browser|web[_a-z0-9-]*|fetch[_a-z0-9-]*|extract_searchable_content|reconcile_summaries|cache)\.go$"#,
        insensitive: true
    )
    private static let googleQuotaContext = regex(
        #"\b(?:cloudcode-pa\.googleapis\.com|aicode\.googleapis\.com|STOP_REASON_QUOTA_EXHAUSTED|ERROR_CODE_RESOURCE_EXHAUSTED|MODEL_CAPACITY_EXHAUSTED|RESOURCE_EXHAUSTED|ResourceExhausted|QUOTA_EXHAUSTED|out\s+of\s+quota|quota\s+(?:exhausted|exceeded|will\s+reset)|individual\s+quota\s+reached)\b"#,
        insensitive: true
    )
    private static let resetField = #"(?:reset[_ -]?time|quota[_ -]?reset[_ -]?time)"#
    private static let relativeField = #"(?:try\s+again\s+in|retry[ _-]*after|(?:quota\s+(?:will\s+)?)?resets?\s+(?:in|after))"#
    private static let absolute = regex(#"\b"# + resetField + #"["']?\s*[:=]\s*["']?(\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2})(\.\d+)?([Zz]|[+-]\d{2}:?\d{2})?"#, insensitive: true)
    private static let relative = regex(#"\b"# + relativeField + #"(?:["']?\s*[:=])?\s*["']?((?:[0-9]{1,8}[ \t\r\n\f\x0B]*[dhms][ \t\r\n\f\x0B]*)+)(?![A-Za-z0-9_])"#, insensitive: true)
    private static let durationPart = regex(#"([0-9]{1,8})\s*([dhms])"#, insensitive: true)
    private static let resetContinuation = regex(#"^[\s{"']*(?:"# + resetField + "|" + relativeField + #")\b"#, insensitive: true)
    private static let account = regex(#"\b(?:id_token_email|idTokenEmail|account_email|accountEmail)["']?\s*[:=]\s*["']?("# + Validation.emailPattern + ")", insensitive: true)
    private static let authResult = regex(#"\bapplyAuthResult:\s*email=("# + Validation.emailPattern + ")", insensitive: true)

    static func event(in lines: [String], now: Double, owner: String?) -> QuotaEvent? {
        var ignoringContinuation = false
        return event(in: lines, now: now, owner: owner, ignoringContinuation: &ignoringContinuation)
    }

    static func event(in lines: [String], now: Double, owner: String?,
                      ignoringContinuation: inout Bool) -> QuotaEvent? {
        for (index, line) in lines.enumerated() {
            let (body, severity, source) = split(line)
            if severity != nil {
                ignoringContinuation = isIgnoredEntry(source: source, body: body)
            }
            guard !ignoringContinuation, first(nonError, in: body) == nil,
                  let matched = first(signal, in: body), let range = Range(matched.range, in: body) else {
                continue
            }
            if severity == "I", first(errorContext, in: body) == nil,
               !body[..<range.lowerBound].trimmingCharacters(in: CharacterSet(charactersIn: " {\"'")).isEmpty {
                continue
            }
            guard let reasonIndex = signals.indices.first(where: { matched.range(at: $0 + 1).location != NSNotFound })
            else { continue }
            let reason = signals[reasonIndex].0
            let before = lines[max(index - 4, 0)..<index].reversed().map(split)
                .prefix { $0.1 == nil }.map { $0.0 }.reversed()
            let after = continuation(lines[(index + 1)..<min(lines.count, index + 12)])
            let context = ([body] + before + after).joined(separator: "\n")
            if reason == .http429, severity == "W" || severity == "I", first(googleQuotaContext, in: context) == nil {
                continue
            }
            let email = first(account, in: context).flatMap { capture($0, at: 1, in: context)?.lowercased() } ?? owner
            return QuotaEvent(reason: reason, resetAt: resetAt(in: context, now: now), email: email)
        }
        return nil
    }

    static func authEmail(in lines: [String]) -> String? {
        var latest: String?
        for line in lines {
            let (body, _, source) = split(line)
            if let source, source.lowercased() != "server_oauth.go" { continue }
            if let match = first(authResult, in: body), let email = capture(match, at: 1, in: body) {
                latest = email.lowercased()
            }
        }
        return latest
    }

    static func continuation<S: Sequence>(_ lines: S) -> [String] where S.Element == String {
        lines.map(split).prefix { body, severity, _ in
            severity == nil || first(resetContinuation, in: body) != nil
        }.map { $0.0 }
    }

    static func resetAt(in text: String, now: Double) -> Double? {
        for match in absolute.matches(in: text, range: fullRange(text)) {
            guard let stamp = capture(match, at: 1, in: text) else { continue }
            let base = stamp.uppercased().replacingOccurrences(of: " ", with: "T")
            let zone = capture(match, at: 3, in: text)?.uppercased()
            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.calendar = Calendar(identifier: .iso8601)
            parser.isLenient = false
            parser.dateFormat = zone == nil ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd'T'HH:mm:ssXXXXX"
            let normalized = zone.map {
                $0.count == 5 ? String($0.prefix(3)) + ":" + String($0.suffix(2)) : $0
            } ?? ""
            guard let date = parser.date(from: base + normalized) else { continue }
            let fraction = capture(match, at: 2, in: text).flatMap { Double("0" + $0) } ?? 0
            let time = date.timeIntervalSince1970 + fraction
            if Validation.timestamp(time), time > now { return time }
        }
        for match in relative.matches(in: text, range: fullRange(text)) {
            guard let duration = capture(match, at: 1, in: text) else { continue }
            let total = durationPart.matches(in: duration, range: fullRange(duration)).reduce(0.0) { total, part in
                let number = capture(part, at: 1, in: duration).flatMap(Double.init) ?? 0
                let unit = capture(part, at: 2, in: duration)?.lowercased()
                let seconds: Double = unit == "d" ? 86_400 : unit == "h" ? 3600 : unit == "m" ? 60 : 1
                return total + number * seconds
            }
            if total > 0, total <= 253_402_300 { return now + total }
        }
        return nil
    }

    private static func isIgnoredEntry(source: String?, body: String) -> Bool {
        if let source, first(ignoredSource, in: source) != nil { return true }
        return first(nonError, in: body) != nil
    }

    private static func split(_ line: String) -> (String, String?, String?) {
        guard let prefix = first(glog, in: line), let range = Range(prefix.range, in: line) else {
            return (String(line.drop(while: \.isWhitespace)), nil, nil)
        }
        let rawSource = capture(prefix, at: 2, in: line)
        let source = rawSource?.split(separator: "/").last.map(String.init)
        return (String(line[range.upperBound...]), capture(prefix, at: 1, in: line), source)
    }

    private static func regex(_ pattern: String, insensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: insensitive ? .caseInsensitive : [])
    }
    private static func fullRange(_ value: String) -> NSRange { NSRange(value.startIndex..., in: value) }
    private static func first(_ regex: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        regex.firstMatch(in: text, range: fullRange(text))
    }
    private static func capture(_ match: NSTextCheckingResult, at index: Int, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
}

final class LogTail {
    private struct FileID: Hashable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int
    }

    private struct Cursor {
        var owner: String?
        var offset: off_t = 0
        var fragment = Data()
        var discarding = false
        var ignoringContinuation = false
        var needsHeaderOwner = false
        var pending: QuotaEvent?
        var retired = false

        mutating func read(fd: Int32, size: off_t) throws -> [String] {
            if size < offset {
                offset = 0
                fragment = Data()
                discarding = false
                ignoringContinuation = false
                needsHeaderOwner = false
                pending = nil
            }
            guard size > offset else { return [] }
            var buffer = [UInt8](repeating: 0, count: 256 * 1024)
            let count = pread(fd, &buffer, buffer.count, offset)
            guard count >= 0 else { throw LogTail.unreadable }
            offset += off_t(count)
            var chunk = Data(buffer.prefix(count))
            if discarding {
                guard let newline = chunk.firstIndex(of: 10) else { return [] }
                chunk = Data(chunk.suffix(from: newline + 1))
                discarding = false
            }
            let maxLine = 128 * 1024
            fragment.append(chunk)
            let lines = fragment.split(separator: 10, omittingEmptySubsequences: false)
            fragment = Data(lines.last ?? Data())
            if fragment.count > maxLine {
                fragment = Data()
                discarding = true
            }
            return lines.dropLast().compactMap {
                $0.count <= maxLine ? String(decoding: $0, as: UTF8.self) : nil
            }
        }
    }

    let directory: URL
    private var cursors: [FileID: Cursor] = [:]
    static let unreadable = AppError.watchUnreadable

    init(directory: URL) { self.directory = directory }

    func start(owner: String?) throws {
        try forEachFile { id, fd, size in
            var cursor = Cursor(owner: owner, offset: size, needsHeaderOwner: size > 0)
            if size > 0 {
                var last: UInt8 = 0
                cursor.discarding = pread(fd, &last, 1, size - 1) != 1 || last != 10
            }
            cursors[id] = cursor
        }
    }

    func poll(owner: () throws -> String?, now: Double, detect: Bool) throws -> [QuotaEvent] {
        var visible: Set<FileID> = []
        var newOwner: String?
        var didReadOwner = false
        var events: [QuotaEvent] = []
        try forEachFile { id, fd, size in
            guard visible.insert(id).inserted else { return }
            if cursors[id] == nil {
                if !didReadOwner {
                    newOwner = try owner()
                    didReadOwner = true
                }
                cursors[id] = Cursor(owner: newOwner)
            }
            guard var cursor = cursors[id], !cursor.retired else { return }
            let lines = try cursor.read(fd: fd, size: size)
            if !lines.isEmpty {
                if cursor.needsHeaderOwner {
                    cursor.needsHeaderOwner = false
                    if let headerEmail = Self.readHeaderAuthEmail(fd: fd, limit: min(size, 64 * 1024)) {
                        cursor.owner = headerEmail
                    }
                }
                if let lineEmail = QuotaParser.authEmail(in: lines) {
                    cursor.owner = lineEmail
                }
            }
            if var pending = cursor.pending {
                if detect {
                    pending.resetAt = QuotaParser.resetAt(in: QuotaParser.continuation(lines.prefix(6)).joined(separator: "\n"), now: now)
                    events.append(pending)
                }
                cursor.pending = nil
            }
            if detect, let event = QuotaParser.event(in: lines, now: now, owner: cursor.owner,
                                                     ignoringContinuation: &cursor.ignoringContinuation) {
                if event.resetAt != nil { events.append(event) }
                else { cursor.pending = event }
            }
            cursors[id] = cursor
        }
        cursors = cursors.filter { visible.contains($0.key) }
        return events
    }

    private static func readHeaderAuthEmail(fd: Int32, limit: off_t) -> String? {
        guard limit > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(limit))
        let count = pread(fd, &buffer, buffer.count, 0)
        guard count > 0 else { return nil }
        let text = String(decoding: buffer.prefix(count), as: UTF8.self)
        return QuotaParser.authEmail(in: text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }

    func retireExisting() {
        for key in Array(cursors.keys) { cursors[key] = Cursor(owner: nil, retired: true) }
        // A file can appear between the last poll and the switch.
        try? forEachFile { id, _, _ in cursors[id] = Cursor(owner: nil, retired: true) }
    }

    private func forEachFile(_ body: (FileID, Int32, off_t) throws -> Void) throws {
        let files: [String]
        do { files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return // agy may not have created the log directory yet.
        } catch { throw Self.unreadable }
        for name in files where name.hasSuffix(".log") && (name.hasPrefix("cli-") || name.hasPrefix("acp-server-")) {
            let fd = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            let id = FileID(device: info.st_dev, inode: info.st_ino, birthSeconds: info.st_birthtimespec.tv_sec,
                            birthNanoseconds: info.st_birthtimespec.tv_nsec)
            try body(id, fd, info.st_size)
        }
    }
}

public final class AutoSwitchWatcher {
    private let tail: LogTail
    private let pool: AccountPool
    private let clock: () -> Double
    private let monotonic: () -> Double
    private let debounce: Double
    private var nextAttempt = -Double.infinity

    public init(pool: AccountPool, directory: URL, debounce: Double = 30,
                clock: @escaping () -> Double = { Date().timeIntervalSince1970 },
                monotonic: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) throws {
        self.pool = pool
        self.clock = clock
        self.monotonic = monotonic
        self.debounce = debounce
        tail = LogTail(directory: directory)
        try tail.start(owner: pool.currentEmail())
    }

    public func poll(cooldown: Double) throws -> SwitchOutcome? {
        let now = clock()
        let events = try tail.poll(owner: pool.currentEmail, now: now, detect: monotonic() >= nextAttempt)
        for event in events {
            guard let email = event.email, monotonic() >= nextAttempt else { continue }
            do {
                let until = event.resetAt ?? now + cooldown
                guard let result = try pool.onQuota(email: email, until: until, reason: event.reason) else { continue }
                tail.retireExisting()
                nextAttempt = monotonic() + debounce
                return result
            } catch {
                nextAttempt = monotonic() + debounce
                throw error
            }
        }
        return nil
    }

    public func didSwitchManually() {
        tail.retireExisting()
        nextAttempt = monotonic() + debounce
    }
}
