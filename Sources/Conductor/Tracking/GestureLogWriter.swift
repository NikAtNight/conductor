import Darwin
import Foundation

/// Owns the file handle and a bounded queue. Only the worker encodes or writes records.
final class GestureLogWriter: @unchecked Sendable {
    enum Line {
        case frame(GestureLog.Frame)
        case setup(GestureLog.Setup, Double)
        case note(GestureLog.Note)

        func encode(with encoder: JSONEncoder) throws -> Data {
            switch self {
            case .frame(let frame): return try encoder.encode(frame)
            case .setup(let setup, let time): return try encoder.encode(SetupLine(time: time, setup: setup))
            case .note(let note): return try encoder.encode(note)
            }
        }

        var isSetup: Bool { if case .setup = self { return true }; return false }
        private struct SetupLine: Encodable { var time: Double; var setup: GestureLog.Setup }
    }

    struct Diagnostics: Equatable {
        var pendingLines = 0
        var highWaterMark = 0
        var droppedLines = 0
        var writtenLines = 0
        var failedLines = 0
        var enqueueMs = 0.0
        var maxEnqueueMs = 0.0
        var encodeMs = 0.0
        var maxEncodeMs = 0.0
        var writeMs = 0.0
        var maxWriteMs = 0.0
        var finalizationError: String?
    }

    private let condition = NSCondition()
    private let queue = DispatchQueue(label: "conductor.log-writer", qos: .utility)
    private let handle: FileHandle
    private let activeURL: URL
    private let finalURL: URL
    private let capacity: Int
    private let beforeWrite: (() throws -> Void)?
    private var lines: [Line] = []
    private var draining = false
    private var finishing = false
    private var finished = false
    private var writeFailure: String?
    private var completions: [@Sendable () -> Void] = []
    private var stats = Diagnostics()

    init(activeURL: URL, finalURL: URL, capacity: Int, beforeWrite: (() throws -> Void)?) throws {
        self.activeURL = activeURL
        self.finalURL = finalURL
        self.capacity = max(1, capacity)
        self.beforeWrite = beforeWrite
        let fd = open(activeURL.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            close(fd)
            throw error
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        lines.reserveCapacity(self.capacity)
    }

    var diagnostics: Diagnostics {
        condition.lock(); defer { condition.unlock() }
        return stats
    }

    func append(_ line: Line) {
        let start = DispatchTime.now().uptimeNanoseconds
        condition.lock()
        guard !finishing else { condition.unlock(); return }
        if writeFailure != nil {
            stats.droppedLines += 1
            recordEnqueue(start)
            condition.unlock()
            return
        }
        let previousDrops = stats.droppedLines
        if lines.count == capacity {
            // A setup changes how later frames replay. Retain it by dropping one pending frame.
            if line.isSetup {
                let index = lines.lastIndex(where: { !$0.isSetup }) ?? 0
                lines.remove(at: index)
            } else {
                stats.droppedLines += 1
                recordEnqueue(start)
                let dropped = stats.droppedLines
                condition.unlock()
                reportDrop(dropped)
                return
            }
            stats.droppedLines += 1
        }
        lines.append(line)
        stats.pendingLines = lines.count
        stats.highWaterMark = max(stats.highWaterMark, lines.count)
        recordEnqueue(start)
        scheduleDrain()
        let dropped = stats.droppedLines
        condition.unlock()
        if dropped != previousDrops { reportDrop(dropped) }
    }

    private func recordEnqueue(_ start: UInt64) {
        stats.enqueueMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        stats.maxEnqueueMs = max(stats.maxEnqueueMs, stats.enqueueMs)
    }

    private func reportDrop(_ count: Int) {
        if count == 1 || count.nonzeroBitCount == 1 {
            NSLog("Conductor: gesture log writer dropped \(count) records because its queue is full")
        }
    }

    func finish(completion: @escaping @Sendable () -> Void) {
        condition.lock()
        if finished {
            condition.unlock()
            queue.async(execute: completion)
            return
        }
        finishing = true
        completions.append(completion)
        scheduleDrain()
        condition.unlock()
    }

    func finishAndWait() {
        finish(completion: {})
        condition.lock()
        while !finished { condition.wait() }
        condition.unlock()
    }

    private func scheduleDrain() {
        guard !draining else { return }
        draining = true
        queue.async { [self] in drain() }
    }

    private func drain() {
        let encoder = JSONEncoder()
        while true {
            condition.lock()
            if lines.isEmpty {
                if finishing {
                    condition.unlock()
                    finalize()
                } else {
                    draining = false
                    condition.unlock()
                }
                return
            }
            let line = lines.removeFirst()
            stats.pendingLines = lines.count
            condition.unlock()
            let encodeStart = DispatchTime.now().uptimeNanoseconds
            let data: Data
            do {
                var encoded = try line.encode(with: encoder)
                encoded.append(0x0A)
                data = encoded
            } catch {
                condition.lock()
                stats.failedLines += 1
                condition.unlock()
                NSLog("Conductor: gesture log encoding failed: \(error)")
                continue
            }
            let encodeMs = elapsed(encodeStart)
            let writeStart = DispatchTime.now().uptimeNanoseconds
            do {
                try beforeWrite?()
                try handle.write(contentsOf: data)
                let writeMs = elapsed(writeStart)
                condition.lock()
                stats.writtenLines += 1
                stats.encodeMs = encodeMs
                stats.maxEncodeMs = max(stats.maxEncodeMs, encodeMs)
                stats.writeMs = writeMs
                stats.maxWriteMs = max(stats.maxWriteMs, writeMs)
                condition.unlock()
            } catch {
                condition.lock()
                stats.failedLines += 1
                stats.droppedLines += lines.count
                lines.removeAll(keepingCapacity: true)
                stats.pendingLines = 0
                writeFailure = String(describing: error)
                condition.unlock()
                // Appending after a partial file write could corrupt a later record. Keep this
                // file interrupted so startup recovery can trim its incomplete final line.
                NSLog("Conductor: gesture log write failed; recording paused: \(error)")
            }
        }
    }

    private func elapsed(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func finalize() {
        var errorMessage: String?
        do {
            try Self.withLifecycleLock(directory: activeURL.deletingLastPathComponent()) {
                // Recovery holds this same lock, so it cannot claim the file between close and rename.
                try handle.close()
                if let writeFailure {
                    errorMessage = writeFailure
                    return
                }
                try FileManager.default.moveItem(at: activeURL, to: finalURL)
            }
        } catch {
            errorMessage = String(describing: error)
            try? handle.close()
            NSLog("Conductor: gesture log finalization failed: \(error)")
        }
        condition.lock()
        stats.finalizationError = errorMessage
        finished = true
        let callbacks = completions
        completions.removeAll()
        condition.broadcast()
        condition.unlock()
        for callback in callbacks { callback() }
    }

    /// Serializes creation and recovery with the close-and-rename step across app processes.
    static func withLifecycleLock<T>(directory: URL, _ body: () throws -> T) throws -> T {
        let lockURL = directory.appending(path: ".recording-lifecycle.lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return try body()
    }

    @discardableResult
    static func recover(directory: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        do {
            return try withLifecycleLock(directory: directory) {
                let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                var recovered: [URL] = []
                for active in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard active.lastPathComponent.hasPrefix("gestures-"), active.lastPathComponent.hasSuffix(".jsonl.inprogress") else { continue }
                    let fd = open(active.path, O_RDWR | O_NOFOLLOW)
                    guard fd >= 0 else { continue }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    defer { try? handle.close() }
                    // Each active writer holds this lock until it closes. Other app instances stay live.
                    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { continue }
                    do {
                        let destination = active.deletingPathExtension()
                        // A conflicting completed file is evidence to keep both files untouched.
                        guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
                        try trimIncompleteLine(handle)
                        try handle.close()
                        try FileManager.default.moveItem(at: active, to: destination)
                        recovered.append(destination)
                    } catch {
                        NSLog("Conductor: interrupted gesture log recovery failed: \(error)")
                    }
                }
                return recovered
            }
        } catch {
            NSLog("Conductor: interrupted gesture log recovery failed: \(error)")
            return []
        }
    }

    private static func trimIncompleteLine(_ handle: FileHandle) throws {
        let end = try handle.seekToEnd()
        var offset = end
        while offset > 0 {
            let count = min(offset, 64 * 1024)
            offset -= count
            try handle.seek(toOffset: offset)
            let data = try handle.read(upToCount: Int(count)) ?? Data()
            if let newline = data.lastIndex(of: 0x0A) {
                try handle.truncate(atOffset: offset + UInt64(newline) + 1)
                return
            }
        }
        try handle.truncate(atOffset: 0)
    }
}
