import Foundation

/// Retries execute on their owner's serial queue. Registration/cancellation are
/// synchronous: a new reconnect cannot race an actor hop from the previous one.
/// Entries are consumed immediately before execution, so an already-enqueued
/// work item is still suppressed by cancel/group replacement/session changes.
final class RetryScheduler: @unchecked Sendable {
    private struct Entry {
        let id: UUID
        let label: String
        let group: String?
        let sessionID: UUID?
        let work: DispatchWorkItem
    }

    private let lock = NSLock()
    private let queue: DispatchQueue
    private var sessionID: UUID?
    private var entries: [Entry] = []

    init(queue: DispatchQueue = .main) { self.queue = queue }

    var currentSessionID: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return sessionID
    }

    func bind(sessionID: UUID, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard self.sessionID != sessionID else { return }
        removeAll(reason: "bind(\(reason)) → session \(sessionID.uuidString.prefix(8))")
        self.sessionID = sessionID
    }

    @discardableResult
    func schedule(label: String, group: String? = nil, delay: TimeInterval,
                  body: @escaping @Sendable () -> Void) -> Bool {
        guard delay.isFinite, delay >= 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        if let group { removeGroup(group, reason: "thay bằng [\(label)] cùng nhóm") }
        let id = UUID()
        let work = DispatchWorkItem { [weak self] in self?.run(id, body: body) }
        entries.append(Entry(id: id, label: label, group: group, sessionID: sessionID, work: work))
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[RETRY] Đã lập lịch [\(label)]\(group.map { " (nhóm \($0))" } ?? "") delay=\(String(format: "%.1f", delay))s — tổng \(entries.count) retry đang chờ"))
        queue.asyncAfter(deadline: .now() + delay, execute: work)
        return true
    }

    private func run(_ id: UUID, body: @Sendable () -> Void) {
        lock.lock()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            lock.unlock()
            return
        }
        let entry = entries.remove(at: index)
        let valid = entry.sessionID == sessionID && !entry.work.isCancelled
        lock.unlock()
        // CoreBluetooth callbacks and retry bodies use the same serial queue.
        // A teardown on that queue cannot interleave validation and execution.
        if valid { body() }
    }

    func cancelGroup(_ group: String, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        removeGroup(group, reason: reason)
    }

    private func removeGroup(_ group: String, reason: String) {
        let matching = entries.filter { $0.group == group }
        guard !matching.isEmpty else { return }
        matching.forEach { $0.work.cancel() }
        entries.removeAll { $0.group == group }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[RETRY] Hủy nhóm '\(group)' (\(matching.map(\.label).joined(separator: ", "))) — \(reason)"))
    }

    func cancelGroups(_ groups: [String], reason: String) {
        lock.lock()
        defer { lock.unlock() }
        groups.forEach { removeGroup($0, reason: reason) }
    }

    func cancelAll(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        removeAll(reason: reason)
    }

    private func removeAll(reason: String) {
        guard !entries.isEmpty else { return }
        PersistentLogger.shared.append(BLELogEntry(timestamp: Date(), level: .info,
            message: "[RETRY] Hủy toàn bộ \(entries.count) retry — \(reason)"))
        entries.forEach { $0.work.cancel() }
        entries.removeAll()
    }

    func pendingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }
}
