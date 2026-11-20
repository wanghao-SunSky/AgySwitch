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

    func perform<T>(mutatingLogin: Bool = false, _ action: @escaping (AccountPool) throws -> T,
                    completion: @escaping (Result<T, Error>, Result<PoolSnapshot, Error>) -> Void) {
        queue.async {
            let outcome = Result { try action(self.pool) }
            if mutatingLogin, case let .success(value) = outcome,
               let result = value as? SwitchOutcome, result.changed {
                self.watcher?.didSwitchManually()
            }
            let snapshot = Result { try self.pool.snapshot() }
            DispatchQueue.main.async { completion(outcome, snapshot) }
        }
    }

    func refresh(_ completion: @escaping (Result<PoolSnapshot, Error>) -> Void) {
        queue.async {
            let snapshot = Result { try self.pool.snapshot() }
            DispatchQueue.main.async { completion(snapshot) }
        }
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
            DispatchQueue.main.async { completion() }
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
