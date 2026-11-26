import AgySwitchCore
import Foundation

final class LocalWork {
    enum Update {
        case listening(Bool)
        case switched(SwitchOutcome)
        case warning(AppError)
    }

    static let logDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".gemini/antigravity-cli/log", isDirectory: true)
    private let queue = DispatchQueue(label: "com.agyacct.agyswitch.local", qos: .userInitiated)
    private let pool = AccountPool()
    private var watcher: AutoSwitchWatcher?
    private var timer: DispatchSourceTimer?
    private var cooldown: Int = 18_000
    private var retryAt: Double = 0
    private var reportedWarning: AppError?
    var onUpdate: (Update) -> Void = { _ in }

    func perform<T>(_ action: @escaping (AccountPool) throws -> T, changedLogin: @escaping (T) -> Bool,
                    completion: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let outcome = Result { try action(self.pool) }
            if case let .success(value) = outcome, changedLogin(value) {
                self.watcher?.didSwitchManually()
            }
            DispatchQueue.main.async { completion(outcome) }
        }
    }

    func read<T>(_ operation: @escaping (AccountPool) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            perform(operation, changedLogin: { _ in false }) { continuation.resume(with: $0) }
        }
    }

    func refresh(_ completion: @escaping (Result<PoolSnapshot, Error>) -> Void) {
        queue.async {
            let snapshot = Result { try self.pool.snapshot() }
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    private let quotaWork = DispatchGroup()

    @MainActor func loadQuota(accountID: String, executable: URL?) async throws -> [ModelQuota] {
        try Task.checkCancellation()
        quotaWork.enter()
        defer { quotaWork.leave() }
        return try await pool.loadQuota(accountID: accountID, executable: executable)
    }

    func configure(automatic: Bool, cooldown: Int) {
        queue.async { [self] in
            self.cooldown = cooldown
            if automatic {
                guard self.timer == nil else { return }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
                timer.setEventHandler { [weak self] in self?.poll() }
                self.timer = timer
                timer.resume()
            } else {
                self.stopWatcher()
            }
        }
    }

    func finish(_ completion: @escaping () -> Void) {
        queue.async {
            self.stopWatcher()
            self.quotaWork.notify(queue: .main, execute: completion)
        }
    }

    private func stopWatcher() {
        timer?.cancel()
        timer = nil
        watcher = nil
        retryAt = 0
        reportedWarning = nil
        publish(.listening(false))
    }

    private func poll() {
        if watcher == nil {
            let now = ProcessInfo.processInfo.systemUptime
            guard now >= retryAt else { return }
            do {
                watcher = try AutoSwitchWatcher(pool: pool, directory: Self.logDirectory)
                reportedWarning = nil
                publish(.listening(true))
            } catch {
                retryAt = ProcessInfo.processInfo.systemUptime + 15
                warn(error)
            }
            return
        }
        do {
            if let outcome = try watcher?.poll(cooldown: Double(cooldown)) {
                publish(.switched(outcome))
            }
            reportedWarning = nil
        } catch {
            warn(error)
        }
    }

    private func warn(_ error: Error) {
        let warning = AppError(redacting: error)
        guard warning != reportedWarning else { return }
        reportedWarning = warning
        publish(.warning(warning))
    }

    private func publish(_ update: Update) {
        DispatchQueue.main.async { [weak self] in self?.onUpdate(update) }
    }
}
