import Foundation

public struct ModelQuota: Equatable, Sendable {
    public struct Bucket: Equatable, Sendable {
        public let window: String
        public let fraction: Double
        public let reset: Date?

        public init(window: String, fraction: Double, reset: Date? = nil) {
            self.window = window
            self.fraction = fraction
            self.reset = reset
        }
    }

    public let family: String
    public let buckets: [Bucket]

    public init(family: String, buckets: [Bucket]) {
        self.family = family
        self.buckets = buckets
    }
}

public enum QuotaError: Error { case expired, unavailable }

public enum QuotaClient {
    private struct Summary: Decodable {
        struct Group: Decodable {
            struct Bucket: Decodable {
                let refreshWindowLabel: String?
                let window: String?
                let remainingFraction: Double?
                let resetTime: String?
            }
            let displayName: String
            let buckets: [Bucket]?
        }
        let groups: [Group]?
    }

    private struct Envelope: Decodable {
        let quotaSummary: Summary?
    }

    public static func parse(_ data: Data) throws -> [ModelQuota] {
        let decoder = JSONDecoder()
        let summary = try decoder.decode(Envelope.self, from: data).quotaSummary
            ?? decoder.decode(Summary.self, from: data)
        let dates = ISO8601DateFormatter()
        let fractionalDates = ISO8601DateFormatter()
        fractionalDates.formatOptions.insert(.withFractionalSeconds)
        let rows = (summary.groups ?? []).compactMap { group -> ModelQuota? in
            let buckets = (group.buckets ?? []).compactMap { item -> ModelQuota.Bucket? in
                let fraction = item.remainingFraction ?? 0
                guard let window = item.refreshWindowLabel ?? item.window, !window.isEmpty,
                      (0...1).contains(fraction) else { return nil }
                let reset = item.resetTime.flatMap { dates.date(from: $0) ?? fractionalDates.date(from: $0) }
                return .init(window: window, fraction: fraction, reset: reset)
            }
            guard !group.displayName.isEmpty, !buckets.isEmpty else { return nil }
            return ModelQuota(family: group.displayName, buckets: buckets)
        }
        guard !rows.isEmpty else { throw QuotaError.unavailable }
        return rows
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public static func fetch(accessToken: String) async throws -> [ModelQuota] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        func read(_ request: URLRequest) async throws -> [ModelQuota] {
            let (data, response) = try await session.data(for: request)
            return try decode(data, status: (response as? HTTPURLResponse)?.statusCode)
        }
        var primary = URLRequest(url: URL(string: "https://aicode.googleapis.com/v1alpha:fetchQuotaStatus")!)
        primary.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        primary.timeoutInterval = 10
        let groups = try await read(primary)

        var hub = URLRequest(url: URL(string: "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary")!)
        hub.timeoutInterval = 4
        hub.httpMethod = "POST"
        hub.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        hub.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The Hub product segment selects additional desktop quota groups, including Argon.
        hub.setValue("antigravity/hub/2.34.0 (os_type=darwin; arch=arm64)", forHTTPHeaderField: "User-Agent")
        hub.httpBody = Data("{}".utf8)
        for _ in 0..<2 {
            try Task.checkCancellation()
            guard let extra = try? await read(hub) else { break }
            if let merged = supplement(groups, with: extra) { return merged }
        }
        try Task.checkCancellation()
        return groups
    }

    static func supplement(_ primary: [ModelQuota], with hub: [ModelQuota]) -> [ModelQuota]? {
        // Some Hub responses report every bucket as fresh. Compare the shared windows
        // before accepting a Hub-only group. Running estimates can drift within a window.
        var matched = false
        var result = primary
        for (index, group) in primary.enumerated() {
            guard let peer = hub.first(where: { $0.family == group.family }) else { continue }
            for bucket in group.buckets {
                guard let other = peer.buckets.first(where: { $0.window == bucket.window }) else { continue }
                guard (bucket.fraction == 1) == (other.fraction == 1) else { return nil }
                if bucket.fraction < 1, bucket.reset != other.reset { return nil }
                matched = true
            }
            let windows = Set(group.buckets.map(\.window))
            result[index] = ModelQuota(family: group.family,
                                       buckets: group.buckets + peer.buckets.filter { !windows.contains($0.window) })
        }
        guard matched else { return nil }
        let families = Set(primary.map(\.family))
        return result + hub.filter { !families.contains($0.family) }
    }

    static func decode(_ data: Data, status code: Int?) throws -> [ModelQuota] {
        if code == 401 { throw QuotaError.expired }
        guard code == 200 else { throw QuotaError.unavailable }
        return try parse(data)
    }
}

@MainActor public final class QuotaCache {
    private var entries: [String: (until: Date, rows: [ModelQuota])] = [:]
    private var pending: [String: Task<[ModelQuota], Error>] = [:]
    private var generation = 0
    private let now: () -> Date
    public init(now: @escaping () -> Date = Date.init) { self.now = now }

    public func rows(for id: String, load: @escaping () async throws -> [ModelQuota]) async throws -> [ModelQuota] {
        if let entry = entries[id], entry.until > now() { return entry.rows }
        if let task = pending[id] { return try await task.value }
        let task = Task { try await load() }
        pending[id] = task
        let started = generation
        defer { if generation == started { pending[id] = nil } }
        let result = try await task.value
        guard started == generation else { throw CancellationError() }
        entries[id] = (now().addingTimeInterval(300), result)
        return result
    }

    public func cancelRequests() {
        generation += 1
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }

    public func invalidate() {
        cancelRequests()
        entries.removeAll()
    }
}
