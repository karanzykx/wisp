import SwiftUI
import AppKit

struct DiskInfo: Equatable {
    var total: Double = 0
    var free: Double = 0
    var fraction: Double { total > 0 ? min(max((total - free) / total, 0), 1) : 0 }
}

/// Runs the bundled wisp.sh engine and turns its "@@" protocol lines into state.
/// The app never deletes anything itself: every removal happens inside the script,
/// behind the script's own allowlist guard.
final class Engine: ObservableObject {
    static let shared = Engine()
    enum Phase { case scanning, ready, cleaning, done, failed }
    enum TestState: Equatable { case idle, running, passed([String]), failed([String]) }

    // Clean tab
    @Published var phase: Phase = .scanning
    @Published var categories: [Category] = []
    @Published var busyApps: [String] = []
    @Published var status = "Looking for junk…"
    @Published var progress = 0.0
    @Published var freedKB = 0.0
    @Published var errorText = ""
    @Published var disk = DiskInfo()
    @Published var toast: String?

    // History
    @Published var history: [RunRecord] = []

    // Large files
    @Published var bigFiles: [BigFile] = []
    @Published var hints: [Hint] = []
    @Published var insightsLoading = false
    @Published var insightsLoaded = false

    // Settings
    @Published var logDays: Int { didSet { UserDefaults.standard.set(logDays, forKey: "logDays") } }
    @Published var depDays: Int { didSet { UserDefaults.standard.set(depDays, forKey: "depDays") } }
    @Published var keepEntries: [String] = []
    @Published var rootEntries: [String] = []
    @Published var testState: TestState = .idle
    @Published var scriptVersion = ""

    private var procs: [String: Process] = [:]
    private var readySince = Date.distantFuture
    private var result: [String]?
    private var errorCode: String?
    private var toastToken = 0

    static let isSnapshotRun = ProcessInfo.processInfo.environment["WISP_SNAPSHOT"] != nil

    private init() {
        let d = UserDefaults.standard
        let ld = d.integer(forKey: "logDays"); logDays = ld > 0 ? ld : 7
        let dd = d.integer(forKey: "depDays"); depDays = dd >= 14 ? dd : 90
        if let data = d.data(forKey: "history"),
           let list = try? JSONDecoder().decode([RunRecord].self, from: data) { history = list }
        reloadConfig()
        refreshDisk()
    }

    // MARK: Derived

    var selectedKB: Double { categories.filter { $0.selected && $0.state == .idle && $0.kb > 0 }.reduce(0) { $0 + $1.kb } }
    var selectedCount: Int { categories.filter { $0.selected }.count }
    var totalKB: Double { categories.filter { $0.kb > 0 }.reduce(0) { $0 + $1.kb } }
    var lifetimeKB: Double { history.reduce(0) { $0 + $1.freedKB } }

    /// The category the script is working on: the first selected one, in script order, not yet finished.
    var currentCategoryID: String? {
        categories.filter { $0.selected && $0.state == .idle }.min { $0.order < $1.order }?.id
    }

    private var rules: [String] { ["--days", "\(logDays)", "--dep-days", "\(depDays)"] }

    // MARK: Scan & clean

    func scan() {
        guard procs["main"] == nil else { return }
        phase = .scanning; categories = []; busyApps = []; progress = 0
        status = "Looking for junk…"; result = nil; errorCode = nil; freedKB = 0
        refreshDisk()
        let started = runScript(tag: "main", ["--dry-run", "--yes", "--app", "--no-report"] + rules,
                                onEvent: { [weak self] in self?.handle($0) },
                                onExit: { [weak self] code in self?.finishScan(code) })
        if !started { fail("The cleaning script could not be started.") }
    }

    /// Only ever called from a deliberate click on the Clean button.
    func clean() {
        guard phase == .ready, Date().timeIntervalSince(readySince) > 1.0, !Engine.isSnapshotRun else { return }
        let ids = categories.filter { $0.selected }.map { $0.id }
        guard !ids.isEmpty else { return }
        phase = .cleaning; progress = 0; status = "Starting…"; result = nil; errorCode = nil
        let started = runScript(tag: "main", ["--yes", "--app", "--no-report", "--only", ids.joined(separator: ",")] + rules,
                                onEvent: { [weak self] in self?.handle($0) },
                                onExit: { [weak self] code in self?.finishClean(code) })
        if !started { fail("The cleaning script could not be started.") }
    }

    func riskyCategoriesSelected() -> [Category] {
        categories.filter { $0.selected && $0.risk.needsConfirm }
    }

    func toggle(_ id: String) {
        guard phase == .ready, let i = categories.firstIndex(where: { $0.id == id }) else { return }
        categories[i].selected.toggle()
    }

    func selectSafeOnly() {
        for i in categories.indices { categories[i].selected = categories[i].risk == .safe }
    }
    func selectNone() {
        for i in categories.indices { categories[i].selected = false }
    }

    /// Adds a path to the never-touch list and drops it from the current results.
    func keep(path: String, in catID: String) {
        Config.add("keep.txt", Config.storable(URL(fileURLWithPath: path)))
        reloadConfig()
        guard let i = categories.firstIndex(where: { $0.id == catID }) else { return }
        if let item = categories[i].items.first(where: { $0.path == path }) {
            categories[i].items.removeAll { $0.path == path }
            if categories[i].kb > 0 { categories[i].kb = max(categories[i].kb - item.kb, 0) }
        }
        if categories[i].items.isEmpty && categories[i].kb >= 0 && categories[i].kb < 1 { categories.remove(at: i) }
        showToast("Kept. It will never be cleaned.")
    }

    // MARK: Event handling

    private func handle(_ p: [String]) {
        guard let kind = p.first else { return }
        switch kind {
        case "STEP":
            if p.count > 2, let n = Double(p[1]), let t = Double(p[2]), t > 0 {
                withAnimation(.easeInOut(duration: 0.45)) { progress = max(0, min((n - 1) / t, 1)) }
            }
        case "SECTION":
            guard p.count > 1 else { return }
            status = (phase == .cleaning ? "Cleaning " : "Looking at ") + Engine.sectionName(p[1]) + "…"
        case "BUSY":
            guard p.count > 1, phase == .scanning else { return }
            for raw in p[1].components(separatedBy: ", ") {
                let name = Engine.friendly(raw.trimmingCharacters(in: .whitespaces))
                if !name.isEmpty, !name.contains("."), !busyApps.contains(name) { busyApps.append(name) }
            }
        case "CAT":
            guard phase == .scanning, p.count >= 8 else { return }
            let c = Category(id: p[1], order: categories.count, title: p[2], risk: Risk(raw: p[3]),
                             kb: Double(p[4]) ?? -1, symbol: p[6], desc: p[7], selected: p[5] == "y")
            withAnimation(.easeOut(duration: 0.3)) { categories.append(c) }
        case "ITEM":
            guard phase == .scanning, p.count >= 4, let i = categories.firstIndex(where: { $0.id == p[1] }) else { return }
            categories[i].items.append(CleanItem(path: p[3], kb: Double(p[2]) ?? 0))
        case "CATDONE":
            guard phase == .cleaning, p.count >= 3, let i = categories.firstIndex(where: { $0.id == p[1] }) else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { categories[i].state = .done(Double(p[2]) ?? 0) }
        case "RESULT": result = p
        case "ERROR": errorCode = p.count > 1 ? p[1] : "unknown"
        default: break
        }
    }

    private func finishScan(_ code: Int32) {
        if let e = errorCode { fail(e == "busy" ? "Another clean is already running." : "The scan was interrupted."); return }
        guard let r = result, r.count >= 5 else { fail("The scan stopped unexpectedly (code \(code)). Open the log for details."); return }
        for i in categories.indices where categories[i].kb < 0 { categories[i].kb = -1 }
        withAnimation(.easeOut(duration: 0.4)) {
            progress = 1
            categories.sort { ($0.kb < 0 ? 0 : $0.kb) > ($1.kb < 0 ? 0 : $1.kb) }
            phase = .ready
        }
        readySince = Date()
        refreshDisk()
    }

    private func finishClean(_ code: Int32) {
        if let e = errorCode { fail(e == "busy" ? "Another clean is already running." : "The clean was interrupted."); return }
        guard let r = result, r.count >= 5, let kb = Double(r[2]), let before = Double(r[3]), let after = Double(r[4]) else {
            fail("The cleaner stopped unexpectedly (code \(code)). Open the log for details."); return
        }
        freedKB = max(kb, after - before)    // brew / docker / pnpm savings only show up as free space
        let names = categories.filter { $0.selected }.map { $0.title }
        history.insert(RunRecord(date: Date(), freedKB: freedKB, categories: names), at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: "history") }
        refreshDisk()
        withAnimation(.easeOut(duration: 0.4)) { progress = 1 }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.65)) { phase = .done }
    }

    private func fail(_ text: String) {
        errorText = text
        withAnimation { phase = .failed }
    }

    // MARK: Large files

    func loadInsights(force: Bool = false) {
        guard !Engine.isDemo, !insightsLoading, force || !insightsLoaded else { return }
        insightsLoading = true; bigFiles = []; hints = []
        let started = runScript(tag: "insights", ["--insights", "--app"], onEvent: { [weak self] p in
            guard let self = self, let kind = p.first else { return }
            if kind == "BIG", p.count >= 4, let kb = Double(p[1]) {
                self.bigFiles.append(BigFile(path: p[3], kb: kb, kind: p[2]))
            } else if kind == "HINT", p.count >= 4, let kb = Double(p[1]) {
                self.hints.append(Hint(path: p[2], kb: kb, advice: p[3]))
            }
        }, onExit: { [weak self] _ in
            self?.insightsLoading = false; self?.insightsLoaded = true
        })
        if !started { insightsLoading = false }
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Moves to the Trash (recoverable with Put Back). Only files in your own folders, never app data.
    func trash(_ file: BigFile) {
        let home = NSHomeDirectory()
        guard file.canTrash, file.path.hasPrefix(home + "/"), !file.path.hasPrefix(home + "/Library/") else { return }
        NSWorkspace.shared.recycle([URL(fileURLWithPath: file.path)]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if error == nil {
                    self.bigFiles.removeAll { $0.path == file.path }
                    self.showToast("Moved to the Trash. Use Put Back in the Trash to undo.")
                    self.refreshDisk()
                } else {
                    self.showToast("Could not move it to the Trash.")
                }
            }
        }
    }

    // MARK: Settings

    func reloadConfig() {
        if Engine.isDemo { return }
        keepEntries = Config.entries("keep.txt")
        rootEntries = Config.entries("roots.txt")
    }

    func removeKeep(_ e: String) { Config.remove("keep.txt", e); reloadConfig() }
    func addKeep(_ e: String) { Config.add("keep.txt", e); reloadConfig() }
    func removeRoot(_ e: String) { Config.remove("roots.txt", e); reloadConfig() }
    func addRoot(_ e: String) { Config.add("roots.txt", e); reloadConfig() }

    func runSelfTest() {
        guard testState != .running else { return }
        testState = .running
        capture(["--self-test"]) { [weak self] code, out in
            let lines = out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("✓") || $0.hasPrefix("✗") || $0.contains("passed") || $0.contains("FAILED") }
            self?.testState = code == 0 ? .passed(lines) : .failed(lines)
        }
    }

    func loadVersion() {
        if Engine.isDemo { return }
        capture(["--version"]) { [weak self] _, out in
            self?.scriptVersion = out.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "wisp ", with: "")
        }
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: "history")
    }

    // MARK: Misc

    func refreshDisk() {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? url.resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage else { return }
        withAnimation(.easeInOut(duration: 0.6)) { disk = DiskInfo(total: Double(total), free: Double(free)) }
    }

    func showToast(_ text: String) {
        toastToken += 1
        let token = toastToken
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self = self, self.toastToken == token else { return }
            withAnimation { self.toast = nil }
        }
    }

    func stopAll() { procs.values.forEach { $0.terminate() } }

    func openLogs() {
        let dir = NSHomeDirectory() + "/Library/Logs/Wisp"
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    static func sectionName(_ title: String) -> String {
        var t = title
        if let dot = t.firstIndex(of: "."), t[t.startIndex..<dot].allSatisfy({ $0.isNumber }) {
            t = String(t[t.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        if let paren = t.range(of: " (") { t = String(t[t.startIndex..<paren.lowerBound]) }
        return t
    }

    static func friendly(_ n: String) -> String {
        switch n {
        case "Code": return "VS Code"
        case "Google": return "Google Chrome"
        default: return n
        }
    }

    // MARK: Process plumbing

    private var scriptPath: String? { Bundle.main.path(forResource: "wisp", ofType: "sh") }

    @discardableResult
    private func runScript(tag: String, _ args: [String],
                           onEvent: @escaping ([String]) -> Void, onExit: @escaping (Int32) -> Void) -> Bool {
        guard procs[tag] == nil, let script = scriptPath else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        procs[tag] = proc

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var pending = Data()
            let handle = pipe.fileHandleForReading
            while true {
                let chunk = handle.availableData          // blocks; empty means end of output
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let nl = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex...nl)
                    guard line.hasPrefix("@@") else { continue }
                    let parts = line.dropFirst(2).components(separatedBy: "\t")
                    DispatchQueue.main.async { onEvent(parts) }
                }
            }
            proc.waitUntilExit()
            DispatchQueue.main.async {
                self?.procs[tag] = nil
                onExit(proc.terminationStatus)
            }
        }
        return true
    }

    private func capture(_ args: [String], _ done: @escaping (Int32, String) -> Void) {
        guard let script = scriptPath else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [script] + args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            proc.standardInput = FileHandle.nullDevice
            guard (try? proc.run()) != nil else { DispatchQueue.main.async { done(-1, "") }; return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            DispatchQueue.main.async { done(proc.terminationStatus, String(decoding: data, as: UTF8.self)) }
        }
    }

    // MARK: Sample data for screenshots (only with WISP_DEMO set; never runs the engine)

    static let isDemo = ProcessInfo.processInfo.environment["WISP_DEMO"] != nil

    func loadDemo(_ kind: String) {
        func cat(_ i: Int, _ id: String, _ title: String, _ risk: Risk, _ symbol: String, _ desc: String,
                 on: Bool, done: Bool = false, items: [(String, Double)] = []) -> Category {
            let kb = items.isEmpty ? -1 : items.reduce(0) { $0 + $1.1 }
            return Category(id: id, order: i, title: title, risk: risk, kb: kb, symbol: symbol, desc: desc,
                            items: items.map { CleanItem(path: NSHomeDirectory() + "/" + $0.0, kb: $0.1) },
                            selected: on, state: done ? .done(kb) : .idle)
        }
        let cleaning = kind == "cleaning", done = kind == "done"
        let working = cleaning || done
        categories = [
            cat(0, "xcode", "Xcode build data", .rebuild, "hammer",
                "DerivedData and simulator caches. Your next build is a full rebuild. Archives are never touched.", on: true, done: working,
                items: [("Library/Developer/Xcode/DerivedData/Shop-bkqzvwdc", 2_100_000), ("Library/Developer/Xcode/DerivedData/Atlas-fmwtqpal", 1_400_000), ("Library/Developer/CoreSimulator/Caches/dyld", 650_000)]),
            cat(1, "projdeps", "Old project dependencies", .reinstall, "folder",
                "node_modules, PHP vendor and Maven target folders of projects idle for 90+ days. One install command brings them back.", on: false,
                items: [("Projects/legacy-admin/node_modules", 1_700_000), ("Projects/blog-2022/node_modules", 980_000), ("Projects/api-v1/vendor", 620_000)]),
            cat(2, "pkgcaches", "Package download caches", .safe, "shippingbox",
                "npm, Yarn, Bun, pip, uv, Poetry, Composer, Ivy. Re-downloaded only when a project needs them again.", on: true, done: working,
                items: [(".npm/_cacache", 1_300_000), (".yarn/berry/cache", 640_000), (".cache/pip", 310_000)]),
            cat(3, "appcaches", "App caches", .safe, "square.stack.3d.up",
                "Temporary files that apps rebuild by themselves. Apple's own system caches are left alone.", on: true, done: done,
                items: [("Library/Caches/go-build", 410_000), ("Library/Caches/pip-tools", 180_000), ("Library/Caches/com.figma.Desktop", 120_000)]),
            cat(4, "browsers", "Browser caches", .safe, "globe",
                "Web page cache only. Sign-ins, passkeys, saved passwords, history and bookmarks are never touched.", on: true, done: done,
                items: [("Library/Caches/Firefox", 420_000), ("Library/Caches/Arc", 220_000)]),
            cat(5, "electron", "Editor & chat-app caches", .safe, "macwindow",
                "VS Code, Cursor, Slack, Docker Desktop… Only their cache folders; settings, extensions and workspaces stay.", on: true, done: done,
                items: [("Library/Application Support/Cursor/CachedData", 310_000), ("Library/Application Support/Slack/Cache", 150_000), ("Library/Application Support/Code/Cache", 60_000)]),
            cat(6, "brew", "Homebrew cleanup", .safe, "cup.and.saucer",
                "Old versions and downloads of formulae. Everything you have installed stays installed.", on: true, done: done, items: []),
            cat(7, "trash", "Empty the Trash", .permanent, "trash",
                "Permanent: items in the Trash cannot be recovered afterwards. Off by default.", on: false, items: [])
        ]
        categories[6].kb = 380_000
        busyApps = ["Google Chrome", "Slack"]
        status = "Cleaning Package download caches…"
        progress = 0.45
        freedKB = categories.filter { $0.selected && $0.kb > 0 }.reduce(0) { $0 + $1.kb }
        disk = DiskInfo(total: 494_384_795_648, free: done ? 186_000_000_000 : 168_000_000_000)

        bigFiles = [
            BigFile(path: NSHomeDirectory() + "/Movies/Conference-Talk-4K.mov", kb: 6_200_000, kind: "user"),
            BigFile(path: NSHomeDirectory() + "/Downloads/ubuntu-24.04-desktop-amd64.iso", kb: 5_800_000, kind: "user"),
            BigFile(path: NSHomeDirectory() + "/Projects/ml-experiments/checkpoints/model-final.safetensors", kb: 3_400_000, kind: "user"),
            BigFile(path: NSHomeDirectory() + "/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw", kb: 1_550_000, kind: "app")
        ]
        hints = [
            Hint(path: NSHomeDirectory() + "/.nvm/versions", kb: 2_190_000, advice: "nvm Node versions. Remove unused ones with 'nvm uninstall <version>'."),
            Hint(path: NSHomeDirectory() + "/Library/Developer/Xcode/Archives", kb: 1_340_000, advice: "Xcode archives. Delete old ones in Xcode → Window → Organizer.")
        ]
        insightsLoaded = true
        let day: TimeInterval = 86_400
        history = [
            RunRecord(date: Date().addingTimeInterval(-2 * day), freedKB: 6_400_000, categories: ["Xcode build data", "Package download caches", "Browser caches"]),
            RunRecord(date: Date().addingTimeInterval(-9 * day), freedKB: 3_100_000, categories: ["Package download caches", "App caches", "Editor & chat-app caches"]),
            RunRecord(date: Date().addingTimeInterval(-23 * day), freedKB: 8_900_000, categories: ["Xcode build data", "Old project dependencies", "Homebrew cleanup"])
        ]
        keepEntries = ["~/Library/Caches/com.spotify.client", "Obsidian"]
        rootEntries = ["~/Work/clients"]
        scriptVersion = "1.0.0"

        phase = cleaning ? .cleaning : (done ? .done : .ready)
        readySince = Date.distantPast
    }
}
