import SwiftUI
import AppKit

// MARK: - Small building blocks

struct Ring: View {
    let phase: Engine.Phase
    let progress: Double
    @State private var spin = false
    @State private var pulse = false

    private var colors: [Color] {
        switch phase {
        case .done:   return [Color(red: 0.25, green: 0.90, blue: 0.60), Color(red: 0.10, green: 0.75, blue: 0.75)]
        case .failed: return [Color(red: 1.0, green: 0.55, blue: 0.35), Color(red: 0.95, green: 0.35, blue: 0.45)]
        default:      return [Theme.accentA, Theme.accentB]
        }
    }

    var body: some View {
        let gradient = AngularGradient(gradient: Gradient(colors: colors + [colors[0]]), center: .center)
        ZStack {
            Circle().fill(colors[0].opacity(0.16)).blur(radius: 34).scaleEffect(pulse ? 1.06 : 0.86)
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 12)
            if phase == .scanning {
                Circle().trim(from: 0, to: 0.28)
                    .stroke(gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
            } else {
                Circle().trim(from: 0, to: CGFloat(phase == .cleaning ? max(progress, 0.04) : 1))
                    .stroke(gradient, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if phase == .cleaning {
                    Circle().trim(from: 0, to: 0.07)
                        .stroke(Color.white.opacity(0.55), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .padding(-12)
                }
            }
        }
        .onAppear {
            withAnimation(Animation.linear(duration: 1.2).repeatForever(autoreverses: false)) { spin = true }
            withAnimation(Animation.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

struct Spinner: View {
    var size: CGFloat = 14
    @State private var spin = false
    var body: some View {
        Circle().trim(from: 0, to: 0.7)
            .stroke(Theme.accentA, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .onAppear { withAnimation(Animation.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true } }
    }
}

struct PrimaryLabel: View {
    let label: AnyView
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        label
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(enabled ? 1 : 0.5))
            .padding(.horizontal, 26).padding(.vertical, 11)
            .background(
                ZStack {
                    if enabled { Capsule().fill(Theme.accent) } else { Capsule().fill(Color.white.opacity(0.10)) }
                }
            )
            .shadow(color: Theme.accentB.opacity(enabled ? 0.45 : 0), radius: 10, y: 3)
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: pressed)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryLabel(label: AnyView(configuration.label), pressed: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundColor(Color.white.opacity(configuration.isPressed ? 0.95 : 0.75))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.09)))
    }
}

struct Card<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.stroke, lineWidth: 1))
    }
}

struct Badge: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundColor(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
    }
}

struct DiskBar: View {
    let disk: DiskInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule().fill(Theme.accent).frame(width: max(8, g.size.width * CGFloat(disk.fraction)))
                }
            }
            .frame(height: 8)
            Text(disk.total > 0 ? "\(Fmt.gb(disk.free)) free of \(Fmt.gb(disk.total))" : "Reading disk…")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(Theme.dim)
        }
    }
}

// MARK: - Root

enum Tab: String, CaseIterable {
    case clean = "Clean", files = "Large Files", history = "History", settings = "Settings"
    var symbol: String {
        switch self {
        case .clean: return "sparkles"
        case .files: return "doc.text.magnifyingglass"
        case .history: return "clock"
        case .settings: return "gearshape"
        }
    }
}

struct RootView: View {
    @ObservedObject var e = Engine.shared
    @State private var tab: Tab = {
        let raw = ProcessInfo.processInfo.environment["WISP_TAB"] ?? ""
        return Tab.allCases.first { $0.rawValue.lowercased().hasPrefix(raw.lowercased()) && !raw.isEmpty } ?? .clean
    }()

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.background.edgesIgnoringSafeArea(.all)
            VStack(spacing: 0) {
                TabBar(tab: $tab).padding(.top, 12).padding(.bottom, 6)
                Group {
                    switch tab {
                    case .clean:    CleanView(e: e)
                    case .files:    LargeFilesView(e: e)
                    case .history:  HistoryView(e: e)
                    case .settings: SettingsView(e: e)
                    }
                }
            }
            if let t = e.toast {
                Text(t)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(Color.black.opacity(0.75)))
                    .overlay(Capsule().stroke(Theme.stroke, lineWidth: 1))
                    .padding(.bottom, 18)
                    .transition(AnyTransition.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 700, idealWidth: 780, maxWidth: .infinity, minHeight: 560, idealHeight: 680, maxHeight: .infinity)
    }
}

struct TabBar: View {
    @Binding var tab: Tab
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { tab = t } }) {
                    HStack(spacing: 6) {
                        Image(systemName: t.symbol).font(.system(size: 12, weight: .semibold))
                        Text(t.rawValue).font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(tab == t ? .white : Theme.dim)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(tab == t ? Color.white.opacity(0.14) : Color.clear))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.05)))
    }
}

// MARK: - Clean tab

struct CleanView: View {
    @ObservedObject var e: Engine
    var body: some View {
        VStack(spacing: 14) {
            Hero(e: e).padding(.horizontal, 30).padding(.top, 14)

            if !e.busyApps.isEmpty && (e.phase == .ready || e.phase == .done) {
                HStack(spacing: 8) {
                    Image(systemName: "pause.circle.fill").foregroundColor(Theme.warn)
                    Text("Open right now, so skipped: " + e.busyApps.joined(separator: ", ") + ". Quit them and rescan to include their caches.")
                        .font(.system(size: 11, design: .rounded)).foregroundColor(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warn.opacity(0.08)))
                .padding(.horizontal, 30)
            }

            if e.phase == .ready && !e.categories.isEmpty {
                HStack {
                    Text("\(e.categories.count) categories found")
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(Theme.dim)
                    Spacer()
                    Button("Safe only") { e.selectSafeOnly() }.buttonStyle(PlainButtonStyle())
                    Text("·").foregroundColor(Theme.faint)
                    Button("None") { e.selectNone() }.buttonStyle(PlainButtonStyle())
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(Theme.accentA)
                .padding(.horizontal, 32)
            }

            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    Color.clear.frame(height: 0).id("top")
                    if e.categories.isEmpty && (e.phase == .ready || e.phase == .done) {
                        Card {
                            VStack(spacing: 6) {
                                Image(systemName: "checkmark.seal").font(.system(size: 26, weight: .light)).foregroundColor(Theme.good)
                                Text("Nothing worth cleaning right now.")
                                    .font(.system(size: 13, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.85))
                            }.frame(maxWidth: .infinity).padding(28)
                        }
                    }
                    ForEach(e.categories) { cat in
                        CategoryRow(e: e, cat: cat)
                            .transition(AnyTransition.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 8)
            }
            .onChange(of: e.phase) { _ in proxy.scrollTo("top", anchor: .top) }
            }

            HStack(spacing: 6) {
                Image(systemName: "lock.shield").font(.system(size: 11))
                Text("Only caches and rebuildable files are touched. Documents, logins, passkeys and passwords never are.")
                    .font(.system(size: 11, design: .rounded))
            }
            .foregroundColor(Theme.faint)
            .padding(.bottom, 14)
        }
    }
}

struct Hero: View {
    @ObservedObject var e: Engine

    var body: some View {
        HStack(spacing: 28) {
            ZStack {
                Ring(phase: e.phase, progress: e.progress)
                center
            }
            .frame(width: 148, height: 148)

            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundColor(.white)
                Text(subtitle).font(.system(size: 12, design: .rounded)).foregroundColor(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true).frame(minHeight: 30, alignment: .topLeading)
                DiskBar(disk: e.disk).frame(maxWidth: 360)
                actions
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var center: some View {
        switch e.phase {
        case .scanning:
            Image(systemName: "sparkles").font(.system(size: 40, weight: .light)).foregroundColor(.white.opacity(0.85))
        case .ready:
            VStack(spacing: 2) {
                Text("").modifier(CountingSize(kb: e.selectedKB))
                    .font(.system(size: 28, weight: .bold, design: .rounded)).foregroundColor(.white)
                Text("selected").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(Theme.dim)
            }
        case .cleaning:
            Text("\(Int(e.progress * 100))%").font(.system(size: 36, weight: .bold, design: .rounded)).foregroundColor(.white)
        case .done:
            VStack(spacing: 2) {
                Image(systemName: "checkmark").font(.system(size: 30, weight: .bold)).foregroundColor(Theme.good)
                Text(Fmt.size(e.freedKB)).font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(.white)
                Text("freed").font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(Theme.dim)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle").font(.system(size: 38, weight: .light))
                .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.4))
        }
    }

    private var title: String {
        switch e.phase {
        case .scanning: return "Scanning your Mac…"
        case .ready:    return e.categories.isEmpty ? "Your Mac is already clean" : "Ready to clean"
        case .cleaning: return "Cleaning…"
        case .done:     return "All done"
        case .failed:   return "Something went wrong"
        }
    }

    private var subtitle: String {
        switch e.phase {
        case .scanning, .cleaning: return e.status
        case .ready:
            if e.categories.isEmpty { return "There is nothing left that is safe to remove." }
            return "\(e.selectedCount) of \(e.categories.count) selected · \(Fmt.size(e.totalKB)) found in total. Expand a category to see exactly what is in it."
        case .done:     return "\(Fmt.gb(e.disk.free)) is now free on your disk."
        case .failed:   return e.errorText
        }
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 10) {
            switch e.phase {
            case .ready:
                Button(action: startClean) {
                    Text(e.selectedCount == 0 ? "Select something to clean"
                         : (e.selectedKB > 0 ? "Clean \(Fmt.size(e.selectedKB))" : "Clean selected"))
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(e.selectedCount == 0)
                Button("Rescan") { e.scan() }.buttonStyle(SoftButtonStyle())
            case .cleaning:
                HStack(spacing: 8) { Spinner(); Text("Working. You can keep using your Mac.")
                    .font(.system(size: 12, design: .rounded)).foregroundColor(Theme.dim) }
            case .done, .failed:
                Button("Scan again") { e.scan() }.buttonStyle(PrimaryButtonStyle())
                Button("View log") { e.openLogs() }.buttonStyle(SoftButtonStyle())
            case .scanning:
                EmptyView()
            }
        }
        .frame(height: 38)
    }

    private func startClean() {
        let risky = e.riskyCategoriesSelected()
        if !risky.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Include items that are not instantly restored?"
            alert.informativeText = risky.map { "• \($0.title) (\($0.risk.label))" }.joined(separator: "\n")
                + "\n\nThese cost time or cannot be undone. Review the list before you continue."
            alert.addButton(withTitle: "Clean")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        e.clean()
    }
}

struct CategoryRow: View {
    @ObservedObject var e: Engine
    let cat: Category
    @State private var expanded: Bool = {
        let e = ProcessInfo.processInfo.environment["WISP_EXPAND"]   // screenshot hook: "first" expands the top row
        return e != nil
    }()

    private var working: Bool { e.phase == .cleaning && e.currentCategoryID == cat.id }

    var body: some View {
        Card {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    leading
                    Image(systemName: cat.symbol)
                        .font(.system(size: 15, weight: .medium)).foregroundColor(cat.risk.color)
                        .frame(width: 34, height: 34)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(cat.risk.color.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(cat.title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(.white)
                            Badge(text: cat.risk.label, color: cat.risk.color)
                        }
                        Text(cat.desc).font(.system(size: 11, design: .rounded)).foregroundColor(Theme.dim)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    trailing
                }
                .padding(14)
                .contentShape(Rectangle())
                .onTapGesture { if !cat.items.isEmpty { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } }

                if expanded && !cat.items.isEmpty {
                    Divider().background(Theme.stroke)
                    VStack(spacing: 0) {
                        ForEach(Array(cat.items.sorted { $0.kb > $1.kb }.prefix(40))) { item in
                            ItemRow(e: e, cat: cat, item: item)
                        }
                        if cat.items.count > 40 {
                            Text("… and \(cat.items.count - 40) smaller items")
                                .font(.system(size: 11, design: .rounded)).foregroundColor(Theme.faint).padding(10)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .opacity(e.phase == .cleaning && !cat.selected ? 0.45 : 1)
    }

    @ViewBuilder private var leading: some View {
        if e.phase == .ready {
            Button(action: { e.toggle(cat.id) }) { Check(on: cat.selected) }.buttonStyle(PlainButtonStyle())
        } else if case .done = cat.state {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundColor(Theme.good)
                .frame(width: 22, height: 22)
        } else if working {
            Spinner(size: 18).frame(width: 22, height: 22)
        } else {
            Check(on: cat.selected).opacity(0.5)
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 10) {
            if case .done(let kb) = cat.state {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(kb > 0 ? Fmt.size(kb) : "Done").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(Theme.good)
                    Text("freed").font(.system(size: 10, design: .rounded)).foregroundColor(Theme.faint)
                }
            } else {
                Text(Fmt.size(cat.kb)).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.9))
            }
            if !cat.items.isEmpty {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.faint)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
    }
}

struct Check: View {
    let on: Bool
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Color.white.opacity(0.3), lineWidth: 1.5)
            if on {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent)
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
            }
        }
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
}

struct ItemRow: View {
    @ObservedObject var e: Engine
    let cat: Category
    let item: CleanItem

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text((item.path as NSString).lastPathComponent)
                    .font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.9)).lineLimit(1)
                Text(Fmt.pretty((item.path as NSString).deletingLastPathComponent))
                    .font(.system(size: 10, design: .rounded)).foregroundColor(Theme.faint).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if item.kb > 0 {
                Text(Fmt.size(item.kb)).font(.system(size: 11, weight: .medium, design: .rounded)).foregroundColor(Theme.dim)
            }
            if Engine.isDemo || FileManager.default.fileExists(atPath: item.path) {
                Button(action: { e.reveal(item.path) }) { Image(systemName: "magnifyingglass") }
                    .buttonStyle(PlainButtonStyle()).foregroundColor(Theme.dim).help("Show in Finder")
                if e.phase == .ready {
                    Button(action: { e.keep(path: item.path, in: cat.id) }) { Image(systemName: "shield") }
                        .buttonStyle(PlainButtonStyle()).foregroundColor(Theme.accentA).help("Never clean this")
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
    }
}

// MARK: - Large files tab

struct LargeFilesView: View {
    @ObservedObject var e: Engine
    @State private var pending: BigFile?

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Large files").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundColor(.white)
                    Text("Files over 250 MB found through Spotlight. Nothing is removed automatically. You decide, and anything you remove goes to the Trash first.")
                        .font(.system(size: 12, design: .rounded)).foregroundColor(Theme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Rescan") { e.loadInsights(force: true) }.buttonStyle(SoftButtonStyle()).disabled(e.insightsLoading)
            }
            .padding(.horizontal, 30).padding(.top, 14)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if e.insightsLoading {
                        HStack(spacing: 10) { Spinner(); Text("Looking for big files…").font(.system(size: 12, design: .rounded)).foregroundColor(Theme.dim) }
                            .padding(24)
                    } else if e.bigFiles.isEmpty && e.hints.isEmpty {
                        Card { Text("No files over 250 MB were found.").font(.system(size: 12, design: .rounded))
                            .foregroundColor(Theme.dim).frame(maxWidth: .infinity).padding(24) }
                    }
                    ForEach(e.bigFiles) { f in
                        BigFileRow(e: e, file: f, ask: { pending = $0 })
                    }
                    if !e.hints.isEmpty {
                        Text("Big folders worth a manual look")
                            .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(Theme.dim)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
                        ForEach(e.hints) { h in
                            Card {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(Fmt.pretty(h.path)).font(.system(size: 12, weight: .semibold, design: .rounded))
                                            .foregroundColor(.white).lineLimit(1).truncationMode(.middle)
                                        Text(h.advice).font(.system(size: 11, design: .rounded)).foregroundColor(Theme.dim)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 8)
                                    Text(Fmt.size(h.kb)).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.9))
                                    Button(action: { e.reveal(h.path) }) { Image(systemName: "magnifyingglass") }
                                        .buttonStyle(PlainButtonStyle()).foregroundColor(Theme.dim)
                                }
                                .padding(12)
                            }
                        }
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 16)
            }
        }
        .onAppear { e.loadInsights() }
        .alert(item: $pending) { f in
            Alert(title: Text("Move “\(f.name)” to the Trash?"),
                  message: Text("\(Fmt.pretty(f.path))\n\(Fmt.size(f.kb)). You can undo this with Put Back in the Trash."),
                  primaryButton: .destructive(Text("Move to Trash")) { e.trash(f) },
                  secondaryButton: .cancel())
        }
    }
}

struct BigFileRow: View {
    @ObservedObject var e: Engine
    let file: BigFile
    let ask: (BigFile) -> Void

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "doc.fill").font(.system(size: 15)).foregroundColor(file.canTrash ? Theme.accentA : Theme.faint)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(0.07)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(file.name).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(.white)
                            .lineLimit(1).truncationMode(.middle)
                        if !file.canTrash { Badge(text: "App data", color: Theme.faint) }
                    }
                    Text(Fmt.pretty((file.path as NSString).deletingLastPathComponent))
                        .font(.system(size: 10, design: .rounded)).foregroundColor(Theme.faint).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(Fmt.size(file.kb)).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(.white.opacity(0.9))
                Button(action: { e.reveal(file.path) }) { Image(systemName: "magnifyingglass") }
                    .buttonStyle(PlainButtonStyle()).foregroundColor(Theme.dim).help("Show in Finder")
                if file.canTrash {
                    Button(action: { ask(file) }) { Image(systemName: "trash") }
                        .buttonStyle(PlainButtonStyle()).foregroundColor(Theme.bad).help("Move to Trash")
                }
            }
            .padding(12)
        }
    }
}

extension BigFile: Equatable {
    static func == (a: BigFile, b: BigFile) -> Bool { a.path == b.path }
}

// MARK: - History tab

struct HistoryView: View {
    @ObservedObject var e: Engine

    private static let formatter: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("History").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundColor(.white)
                    Text(e.history.isEmpty ? "Your cleans will show up here."
                         : "\(Fmt.size(e.lifetimeKB)) freed across \(e.history.count) clean\(e.history.count == 1 ? "" : "s").")
                        .font(.system(size: 12, design: .rounded)).foregroundColor(Theme.dim)
                }
                Spacer()
                if !e.history.isEmpty { Button("Clear") { e.clearHistory() }.buttonStyle(SoftButtonStyle()) }
            }
            .padding(.horizontal, 30).padding(.top, 14)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(e.history) { r in
                        Card {
                            HStack(spacing: 12) {
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundColor(Theme.good)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(HistoryView.formatter.string(from: r.date))
                                        .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(.white)
                                    Text(r.categories.joined(separator: " · "))
                                        .font(.system(size: 11, design: .rounded)).foregroundColor(Theme.dim).lineLimit(2)
                                }
                                Spacer(minLength: 8)
                                Text(Fmt.size(r.freedKB)).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundColor(Theme.good)
                            }
                            .padding(12)
                        }
                    }
                }
                .padding(.horizontal, 30).padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Settings tab

struct SettingsView: View {
    @ObservedObject var e: Engine
    @State private var keepText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Settings").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundColor(.white)

                section("Never clean these",
                        "Anything listed here is skipped by every clean, no matter what. Add a file, a folder, or an app-folder name such as Cursor.") {
                    ForEach(e.keepEntries, id: \.self) { entry in
                        listRow(entry) { e.removeKeep(entry) }
                    }
                    if e.keepEntries.isEmpty { Text("Nothing added yet.").font(.system(size: 11, design: .rounded)).foregroundColor(Theme.faint) }
                    HStack(spacing: 8) {
                        TextField("Folder name or ~/path", text: $keepText, onCommit: addTyped)
                            .textFieldStyle(RoundedBorderTextFieldStyle()).font(.system(size: 12))
                        Button("Add") { addTyped() }.buttonStyle(SoftButtonStyle())
                        Button("Choose…") { choose(directoriesOnly: false) { e.addKeep(Config.storable($0)) } }.buttonStyle(SoftButtonStyle())
                    }
                }

                section("Cleaning rules", "Applied the next time you scan.") {
                    Stepper(value: $e.logDays, in: 1...90) {
                        Text("Delete logs older than \(e.logDays) days").font(.system(size: 12, design: .rounded)).foregroundColor(.white.opacity(0.9))
                    }
                    Stepper(value: $e.depDays, in: 14...365, step: 7) {
                        Text("Call a project idle after \(e.depDays) days").font(.system(size: 12, design: .rounded)).foregroundColor(.white.opacity(0.9))
                    }
                }

                section("Project folders to check for old dependencies",
                        "Looked at automatically: ~/Projects, ~/Developer, ~/Code, ~/dev, ~/src, ~/workspace, ~/Sites, ~/git, ~/repos and the JetBrains project folders. Add others here. Desktop, Documents and Downloads are never scanned.") {
                    ForEach(e.rootEntries, id: \.self) { entry in
                        listRow(entry) { e.removeRoot(entry) }
                    }
                    HStack {
                        Button("Add folder…") {
                            choose(directoriesOnly: true) { url in
                                if url.path.hasPrefix(NSHomeDirectory() + "/") { e.addRoot(Config.storable(url)) }
                                else { e.showToast("Pick a folder inside your home folder.") }
                            }
                        }.buttonStyle(SoftButtonStyle())
                        Spacer()
                    }
                }

                section("Safety check",
                        "Runs the cleaner's built-in tests on this Mac: it must refuse documents, keychains, browser logins and passkeys, and only delete what it should.") {
                    HStack(spacing: 10) {
                        Button(action: { e.runSelfTest() }) { Text(e.testState == .running ? "Testing…" : "Run safety check") }
                            .buttonStyle(SoftButtonStyle()).disabled(e.testState == .running)
                        switch e.testState {
                        case .passed: Badge(text: "All checks passed", color: Theme.good)
                        case .failed: Badge(text: "A check failed. Do not clean", color: Theme.bad)
                        default: EmptyView()
                        }
                        Spacer()
                    }
                    switch e.testState {
                    case .passed(let l), .failed(let l):
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(l.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(size: 10, design: .monospaced)).foregroundColor(line.hasPrefix("✗") ? Theme.bad : Theme.dim)
                            }
                        }
                    default: EmptyView()
                    }
                }

                section("About", nil) {
                    Text("Wisp \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") · cleaner engine \(e.scriptVersion) · \(arch) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                        .font(.system(size: 11, design: .rounded)).foregroundColor(Theme.dim)
                    HStack { Button("Open log folder") { e.openLogs() }.buttonStyle(SoftButtonStyle()); Spacer() }
                }
            }
            .padding(.horizontal, 30).padding(.vertical, 16)
        }
        .onAppear { e.reloadConfig(); e.loadVersion() }
    }

    private var arch: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return "Intel"
        #endif
    }

    private func addTyped() {
        let t = keepText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        e.addKeep(t); keepText = ""
    }

    private func choose(directoriesOnly: Bool, _ done: @escaping (URL) -> Void) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = !directoriesOnly
        p.allowsMultipleSelection = true
        p.showsHiddenFiles = true
        p.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if p.runModal() == .OK { p.urls.forEach(done) }
    }

    private func section<C: View>(_ title: String, _ subtitle: String?, @ViewBuilder _ content: () -> C) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundColor(.white)
                if let s = subtitle {
                    Text(s).font(.system(size: 11, design: .rounded)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
                }
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func listRow(_ text: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Text(text).font(.system(size: 12, design: .rounded)).foregroundColor(.white.opacity(0.9)).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(PlainButtonStyle()).foregroundColor(Theme.faint).help("Remove")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
    }
}
