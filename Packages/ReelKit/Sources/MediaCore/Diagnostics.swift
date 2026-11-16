import Foundation

/// A small on-device log of what the app did: player state changes, reconnects, source connections,
/// sync results and app lifecycle. Settings → Diagnostics shows it and can share the file.
///
/// It exists because the device's system log is not readable from a Mac without a wired debug
/// session, so "it just spun" was otherwise unanswerable. Never log credentials or full URLs with
/// user info; `safe(_:)` strips them.
public enum Diagnostics {
    public static let maxBytes = 1_000_000
    private static let queue = DispatchQueue(label: "reel.diagnostics", qos: .utility)
    private static var recentLines: [String] = []
    private static let recentLimit = 1000

    public static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("reel.log")
    }
    private static var rotatedURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("reel.previous.log") }

    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    /// `category` is a short tag such as "player", "source", "sync", "app", "scan".
    public static func log(_ category: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) [\(category)] \(message)"
        queue.async {
            recentLines.append(line)
            if recentLines.count > recentLimit { recentLines.removeFirst(recentLines.count - recentLimit) }
            let url = fileURL
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > maxBytes {
                try? FileManager.default.removeItem(at: rotatedURL)
                try? FileManager.default.moveItem(at: url, to: rotatedURL)
            }
            let data = (line + "\n").data(using: .utf8)!
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Newest first. Reads the file so lines from before this launch are included.
    public static func recent(limit: Int = 500) -> [String] {
        queue.sync {
            let onDisk = (try? String(contentsOf: fileURL, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
            return Array(onDisk.suffix(limit).reversed())
        }
    }

    public static func clear() {
        queue.sync {
            recentLines.removeAll()
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: rotatedURL)
        }
    }

    /// A URL with any user name and password removed, for logging.
    public static func safe(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.lastPathComponent }
        c.user = nil; c.password = nil
        if url.isFileURL { return "file:…/" + url.lastPathComponent }
        return c.url?.absoluteString.removingPercentEncoding ?? url.lastPathComponent
    }

    /// Device and app facts worth having at the top of a shared log.
    public static func header(appVersion: String, device: String, system: String) -> String {
        "Reel \(appVersion) on \(device), \(system)"
    }

    // MARK: - The main thread

    /// Times a piece of main-thread work and logs it under "main" when it took `threshold` or more,
    /// so a frozen screen can be put down to a named job. Wrap the known heavy jobs (a screen's
    /// rows, a sync batch, a probe) rather than guessing afterwards.
    @discardableResult
    public static func timeMain<T>(_ name: @autoclosure () -> String, threshold: TimeInterval = 0.5, _ work: () throws -> T) rethrows -> T {
        let began = Date()
        defer {
            let took = Date().timeIntervalSince(began)
            if took >= threshold { log("main", "\(name()) took \(String(format: "%.2f", took))s on the main thread") }
        }
        return try work()
    }

    nonisolated(unsafe) private static var watchingMainThread = false
    /// Set by whoever runs a long background start (VLC's library), so a busy stretch that
    /// coincides with it says so.
    nonisolated(unsafe) public static var backgroundStartInProgress: (() -> String?)?
    nonisolated(unsafe) private static var lastPong = Date()
    private static let pongLock = NSLock()

    /// A thread of its own pings the main thread four times a second and logs every stretch of a
    /// second or more during which the main thread answered nothing: "main thread busy for Ns
    /// (until HH:MM:SS)". The "took … on the main thread" lines from `timeMain` in the same
    /// window name the job; a stretch with none is work that is not yet wrapped. A late ping
    /// thread itself (the process starved or suspended) is reported as such, not as a busy main
    /// thread.
    public static func startMainThreadWatch() {
        guard !watchingMainThread else { return }
        watchingMainThread = true
        pongLock.withLock { lastPong = Date() }
        let mainThread = pthread_mach_thread_np(pthread_self())   // called from the main thread at launch
        let thread = Thread {
            var blockedSince: Date?
            var baseline: MainThreadSampler.Stats?
            var lastTick = Date()
            var sampled: Set<Int> = []
            while true {
                Thread.sleep(forTimeInterval: 0.25)
                let now = Date()
                let tickLate = now.timeIntervalSince(lastTick) - 0.25
                lastTick = now
                DispatchQueue.main.async { pongLock.withLock { lastPong = Date() } }
                let pong = pongLock.withLock { lastPong }
                let silent = now.timeIntervalSince(pong)
                if silent >= 1, blockedSince == nil { blockedSince = pong; sampled = []; baseline = MainThreadSampler.stats(mainThread) }
                // While the main thread is silent, capture what it is doing at 2, 5, 12 and 25 s in,
                // with how much CPU it has used and how many pages the process has read from storage
                // since the stall was noticed: computing shows as CPU close to the wall time, waiting on
                // cold storage as little CPU and many page-ins.
                if blockedSince != nil, tickLate < 1 {
                    for mark in [2, 5, 12, 25] where silent >= Double(mark) && !sampled.contains(mark) {
                        sampled.insert(mark)
                        let stats = MainThreadSampler.stats(mainThread)
                        let frames = MainThreadSampler.sample(mainThread)
                        log("main", "main thread at \(mark)s into the stall\(MainThreadSampler.describe(stats, since: baseline)): \(frames.isEmpty ? "(no frames)" : frames.joined(separator: " < "))")
                    }
                }
                if let since = blockedSince, pong > since {
                    // Recovered. The pong arrived at `pong`; the main thread was busy from `since`.
                    let busy = pong.timeIntervalSince(since)
                    blockedSince = nil
                    if tickLate > 1 {
                        log("main", "process starved or suspended for about \(String(format: "%.1f", busy))s (the watch thread itself was \(String(format: "%.1f", tickLate))s late)")
                    } else if busy >= 1 {
                        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; f.timeZone = TimeZone(identifier: "UTC")
                        let during = backgroundStartInProgress?().map { "; \($0) was running" } ?? ""
                        let used = MainThreadSampler.describe(MainThreadSampler.stats(mainThread), since: baseline)
                        log("main", "main thread busy for \(String(format: "%.1f", busy))s (from \(f.string(from: since)) until \(f.string(from: pong)) UTC)\(used)\(during)")
                    }
                }
            }
        }
        thread.name = "reel.mainThreadWatch"
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}


// MARK: - Sampling the main thread

/// A backtrace of the main thread taken from another thread, for the log, when the main thread has
/// not answered for seconds. Mach lets a process suspend one of its own threads, read its registers
/// and resume it; the frame-pointer chain is then read with `vm_read_overwrite` (never a raw
/// dereference: a stale frame must not crash the app) and only symbolicated after the resume, since
/// `dladdr` takes the dynamic loader's lock and the main thread may hold it. arm64 only; elsewhere
/// it returns nothing.
enum MainThreadSampler {
    /// What the thread and the process have done so far: the thread's CPU time and scheduler state,
    /// the process's page faults and page-ins (pages read back from storage).
    struct Stats {
        var cpu: Double
        var state: String
        var faults: Int
        var pageins: Int
    }

    static func stats(_ thread: thread_t) -> Stats? {
        var tinfo = thread_basic_info()
        var tcount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let tk = withUnsafeMutablePointer(to: &tinfo) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(tcount)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &tcount) }
        }
        var einfo = task_events_info()
        var ecount = mach_msg_type_number_t(MemoryLayout<task_events_info>.size / MemoryLayout<integer_t>.size)
        let ek = withUnsafeMutablePointer(to: &einfo) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(ecount)) { task_info(mach_task_self_, task_flavor_t(TASK_EVENTS_INFO), $0, &ecount) }
        }
        guard tk == KERN_SUCCESS, ek == KERN_SUCCESS else { return nil }
        let cpu = Double(tinfo.user_time.seconds + tinfo.system_time.seconds)
            + Double(tinfo.user_time.microseconds + tinfo.system_time.microseconds) / 1_000_000
        let state: String
        switch tinfo.run_state {
        case TH_STATE_RUNNING: state = "running"
        case TH_STATE_WAITING: state = "waiting"
        case TH_STATE_UNINTERRUPTIBLE: state = "waiting uninterruptibly"
        case TH_STATE_STOPPED: state = "stopped"
        case TH_STATE_HALTED: state = "halted"
        default: state = "state \(tinfo.run_state)"
        }
        return Stats(cpu: cpu, state: state, faults: Int(einfo.faults), pageins: Int(einfo.pageins))
    }

    /// " (CPU 0.3s, waiting; process page-ins +1234, faults +5678)", the deltas since `since`.
    static func describe(_ now: Stats?, since: Stats?) -> String {
        guard let now else { return "" }
        guard let since else { return " (\(now.state))" }
        return " (CPU \(String(format: "%.1f", now.cpu - since.cpu))s, \(now.state); process page-ins +\(now.pageins - since.pageins), faults +\(now.faults - since.faults))"
    }

    static func sample(_ thread: thread_t) -> [String] {
        #if arch(arm64)
        var addresses: [UInt] = []
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &state) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &count) }
        }
        let strip: (UInt64) -> UInt = { UInt($0 & 0x0000_007F_FFFF_FFFF) }   // pointer authentication bits off (arm64e)
        if kr == KERN_SUCCESS {
            addresses.append(strip(state.__pc))
            addresses.append(strip(state.__lr))
            var fp = strip(state.__fp)
            let task = mach_task_self_
            for _ in 0..<96 {
                guard fp > 0x1000, fp & 0xF == 0 else { break }
                var pair: (UInt64, UInt64) = (0, 0)
                var outsize: vm_size_t = 0
                let read = withUnsafeMutablePointer(to: &pair) { vm_read_overwrite(task, vm_address_t(fp), 16, vm_address_t(UInt(bitPattern: $0)), &outsize) }
                guard read == KERN_SUCCESS, outsize == 16 else { break }
                let next = strip(pair.0), ret = strip(pair.1)
                guard ret > 0x1000 else { break }
                addresses.append(ret)
                guard next > fp else { break }   // stacks grow down: the caller's frame is higher
                fp = next
            }
        }
        thread_resume(thread)
        guard kr == KERN_SUCCESS else { return [] }
        // Symbolicate only now, with the main thread running again (see above). System frameworks
        // on a device have their symbol names stripped ("<redacted>"); a run of such frames from one
        // image is folded to "CoreData ×9" so the named frames, Reel's among them, stay in view.
        var names: [String] = []
        var unnamedRun: (image: String, count: Int)?
        func flush() { if let r = unnamedRun { names.append(r.count == 1 ? "\(r.image)" : "\(r.image) ×\(r.count)"); unnamedRun = nil } }
        for addr in addresses {
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: addr), &info) != 0 else { flush(); names.append(String(format: "0x%lx", addr)); continue }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            if let sym = info.dli_sname.map({ String(cString: $0) }), sym != "<redacted>" {
                flush()
                names.append("\(image)`\(sym)+\(addr - UInt(bitPattern: info.dli_saddr))")
            } else if let r = unnamedRun, r.image == image {
                unnamedRun = (image, r.count + 1)
            } else {
                flush(); unnamedRun = (image, 1)
            }
        }
        flush()
        return names
        #else
        return []
        #endif
    }
}
