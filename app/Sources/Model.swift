import SwiftUI
import AppKit

// MARK: - Formatting

enum Fmt {
    /// kb < 0 means "size not measured" (the category runs a command instead of deleting listed files).
    static func size(_ kb: Double) -> String {
        if kb < 0 { return "n/a" }
        if kb >= 1_048_576 { return String(format: "%.2f GB", kb / 1_048_576) }
        if kb >= 1024 { return String(format: "%.0f MB", kb / 1024) }
        return String(format: "%.0f KB", kb)
    }

    static func gb(_ bytes: Double) -> String {
        String(format: "%.1f GB", bytes / 1_073_741_824)
    }

    static func pretty(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + String(path.dropFirst(home.count)) }
        return path
    }
}

// MARK: - Theme

enum Theme {
    static let bgTop = Color(red: 0.07, green: 0.09, blue: 0.16)
    static let bgBottom = Color(red: 0.04, green: 0.05, blue: 0.09)
    static let card = Color.white.opacity(0.055)
    static let stroke = Color.white.opacity(0.09)
    static let dim = Color.white.opacity(0.55)
    static let faint = Color.white.opacity(0.35)
    static let accentA = Color(red: 0.30, green: 0.85, blue: 1.0)
    static let accentB = Color(red: 0.45, green: 0.50, blue: 1.0)
    static let good = Color(red: 0.30, green: 0.92, blue: 0.62)
    static let warn = Color(red: 1.0, green: 0.72, blue: 0.30)
    static let bad = Color(red: 1.0, green: 0.45, blue: 0.45)
    static let windowColor = NSColor(red: 0.055, green: 0.07, blue: 0.125, alpha: 1)

    static var accent: LinearGradient {
        LinearGradient(gradient: Gradient(colors: [accentA, accentB]), startPoint: .leading, endPoint: .trailing)
    }
    static var background: LinearGradient {
        LinearGradient(gradient: Gradient(colors: [bgTop, bgBottom]), startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Cleaning model

enum Risk: String {
    case safe, rebuild, redownload, reinstall, review, permanent

    init(raw: String) { self = Risk(rawValue: raw) ?? .review }

    var label: String {
        switch self {
        case .safe: return "Safe"
        case .rebuild: return "Rebuilds"
        case .redownload: return "Re-downloads"
        case .reinstall: return "Reinstall"
        case .review: return "Review"
        case .permanent: return "Permanent"
        }
    }
    var color: Color {
        switch self {
        case .safe: return Theme.good
        case .rebuild, .redownload: return Theme.accentA
        case .reinstall, .review: return Theme.warn
        case .permanent: return Theme.bad
        }
    }
    /// Anything that is not instantly and silently regenerated gets a confirmation before it runs.
    var needsConfirm: Bool { self == .reinstall || self == .review || self == .permanent }
}

struct CleanItem: Identifiable, Hashable {
    let path: String
    var kb: Double
    var id: String { path }
}

enum CatState: Equatable { case idle, done(Double) }

struct Category: Identifiable {
    let id: String
    var order: Int
    var title: String
    var risk: Risk
    var kb: Double
    var symbol: String
    var desc: String
    var items: [CleanItem] = []
    var selected: Bool
    var state: CatState = .idle
}

struct BigFile: Identifiable {
    let path: String
    let kb: Double
    let kind: String            // "user" or "app"
    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var canTrash: Bool { kind == "user" }
}

struct Hint: Identifiable {
    let path: String
    let kb: Double
    let advice: String
    var id: String { path }
}

struct RunRecord: Codable, Identifiable {
    var id = UUID()
    var date: Date
    var freedKB: Double
    var categories: [String]
}

// MARK: - Config files shared with the script (~/.config/wisp)

enum Config {
    static var dir: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/wisp") }

    private static func lines(_ name: String) -> [String] {
        let text = (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
        return text.components(separatedBy: "\n")
    }
    private static func strip(_ line: String) -> String {
        let noComment = line.components(separatedBy: "#").first ?? ""
        return noComment.trimmingCharacters(in: .whitespaces)
    }
    private static func write(_ name: String, _ lines: [String]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let body = lines.joined(separator: "\n") + "\n"
        try? body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    static func entries(_ name: String) -> [String] { lines(name).map(strip).filter { !$0.isEmpty } }

    static func add(_ name: String, _ entry: String) {
        guard !entries(name).contains(entry) else { return }
        var l = lines(name)
        while l.last == "" { l.removeLast() }
        l.append(entry)
        write(name, l)
    }

    static func remove(_ name: String, _ entry: String) {
        var l = lines(name).filter { strip($0) != entry }
        while l.last == "" { l.removeLast() }
        write(name, l)
    }

    /// Stores a path as "~/…" when it is inside the home folder.
    static func storable(_ url: URL) -> String { Fmt.pretty(url.path) }
}

// MARK: - Animated number

struct CountingSize: AnimatableModifier {
    var kb: Double
    var animatableData: Double {
        get { kb }
        set { kb = newValue }
    }
    func body(content: Content) -> some View { Text(Fmt.size(kb)) }
}
