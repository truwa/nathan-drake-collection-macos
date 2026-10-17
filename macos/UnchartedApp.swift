import AppKit
import SwiftUI

struct GameRow: Identifiable {
    let id: String
    let title: String
    var available: Bool
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var dumpPath: String?
    @Published var games: [GameRow] = [
        GameRow(id: "u1", title: "Drake's Fortune", available: false),
        GameRow(id: "u2", title: "Among Thieves", available: false),
        GameRow(id: "u3", title: "Drake's Deception", available: false),
    ]
    @Published var status = "Choose the folder that contains the game dump."
    @Published var log = ""
    @Published var running = false
    @Published var runningGame: String?

    private var dumpURL: URL?
    private var gameProcess: Process?
    private var logTimer: Timer?

    func restore() {
        if let data = UserDefaults.standard.data(forKey: "dumpBookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                adopt(url)
                return
            }
            stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                adopt(url)
                return
            }
        }
        if let path = UserDefaults.standard.string(forKey: "dumpPath"),
           FileManager.default.fileExists(atPath: path) {
            adopt(URL(fileURLWithPath: path))
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the folder that contains eboot.bin."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store(url)
        adopt(url)
    }

    private func store(_ url: URL) {
        let scoped = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let plain = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        if let data = scoped ?? plain {
            UserDefaults.standard.set(data, forKey: "dumpBookmark")
        }
        UserDefaults.standard.set(url.path, forKey: "dumpPath")
    }

    func play(_ game: GameRow, display: String, metalHud: Bool) {
        guard let dumpURL, game.available, !running else { return }
        running = true
        runningGame = game.title
        status = "Starting \(game.title)…"
        log = ""
        let process = Process()
        process.executableURL = pythonURL
        var arguments = [launcherURL.path, "--dump", dumpURL.path, "--exe", game.id, "--display", display]
        if metalHud {
            arguments.append("--metal-hud")
        }
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self else { return }
                self.logTimer?.invalidate()
                self.running = false
                self.runningGame = nil
                self.gameProcess = nil
                self.status = ended.terminationStatus == 0 ? "\(game.title) closed." : "\(game.title) stopped (\(ended.terminationStatus))."
            }
        }
        do {
            try process.run()
            gameProcess = process
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let text = String(data: handle.availableData, encoding: .utf8) ?? ""
                guard !text.isEmpty else { return }
                Task { @MainActor in self?.log += text }
            }
            watchGameLog()
        } catch {
            running = false
            status = "Cannot start: \(error.localizedDescription)"
        }
    }

    func stop() {
        logTimer?.invalidate()
        gameProcess?.terminate()
    }

    private func adopt(_ url: URL) {
        dumpURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        let resolved = resolveDump(url)
        dumpURL = resolved
        dumpPath = resolved.path
        refresh()
    }

    private func resolveDump(_ url: URL) -> URL {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("eboot.bin").path) {
            return url
        }
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        let matches = children.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("eboot.bin").path) }
        return matches.count == 1 ? matches[0] : url
    }

    private func refresh() {
        guard let dumpURL else { return }
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [launcherURL.path, "--dump", dumpURL.path, "--list"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try? process.run()
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var found = games
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 3, let index = found.firstIndex(where: { $0.id == fields[0] }) else { continue }
            found[index].available = fields[2] == "yes"
        }
        games = found
        if games.contains(where: { $0.available }) {
            status = "Choose a game."
        } else {
            status = "That folder has no eboot.bin."
        }
    }

    private func watchGameLog() {
        logTimer?.invalidate()
        let url = gameLogURL
        logTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8), !text.isEmpty else { return }
                self.log = text
            }
        }
    }

    private var resources: URL {
        Bundle.main.resourceURL ?? URL(fileURLWithPath: ".")
    }

    private var pythonURL: URL {
        let bundled = resources.appendingPathComponent("python/bin/python3")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        return URL(fileURLWithPath: "/opt/homebrew/bin/python3")
    }

    private var launcherURL: URL {
        resources.appendingPathComponent("engine/launch.py")
    }

    private var gameLogURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Uncharted MacOS/prefix/drive_c/uncharted-out.txt")
    }
}

private struct CreditEntry: Identifiable {
    let id = UUID()
    let text: String
    var url: URL?
}

private struct CreditBlock: Identifiable {
    let id = UUID()
    let heading: String
    let lines: [CreditEntry]
}

private let creditBlocks: [CreditBlock] = [
    CreditBlock(heading: "Nathan Drake Collection", lines: [
        CreditEntry(text: "Drake's Fortune"),
        CreditEntry(text: "Among Thieves"),
        CreditEntry(text: "Drake's Deception"),
        CreditEntry(text: "A launcher for the PS4 games"),
        CreditEntry(text: "through the Windows port, under Wine"),
        CreditEntry(text: "The games are not included"),
    ]),
    CreditBlock(heading: "The games", lines: [
        CreditEntry(text: "Naughty Dog"),
        CreditEntry(text: "Sony Interactive Entertainment"),
    ]),
    CreditBlock(heading: "Windows port", lines: [
        CreditEntry(text: "GPL-2.0"),
        CreditEntry(text: "github.com/Supermedo/uncharted_pc", url: URL(string: "https://github.com/Supermedo/uncharted_pc")),
    ]),
    CreditBlock(heading: "Wine 11.18", lines: [
        CreditEntry(text: "LGPL-2.1-or-later"),
        CreditEntry(text: "gitlab.winehq.org/wine/wine", url: URL(string: "https://gitlab.winehq.org/wine/wine/-/releases/wine-11.18")),
        CreditEntry(text: "macOS build by Gcenx", url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.18")),
    ]),
    CreditBlock(heading: "KosmicKrisp", lines: [
        CreditEntry(text: "Mesa 26.3.0-devel"),
        CreditEntry(text: "MIT"),
        CreditEntry(text: "docs.mesa3d.org", url: URL(string: "https://docs.mesa3d.org/drivers/kosmickrisp.html")),
    ]),
    CreditBlock(heading: "This launcher", lines: [
        CreditEntry(text: "Mac changes are applied at launch"),
        CreditEntry(text: "NVIDIA DLSS is not included"),
    ]),
]

private struct CreditsRoll: View {
    var onClose: () -> Void
    @State private var accumulated: TimeInterval = 0
    @State private var segmentStart = Date()
    @State private var paused = false
    @State private var contentHeight: CGFloat = 900

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let elapsed = accumulated + (paused ? 0 : timeline.date.timeIntervalSince(segmentStart))
                    let travel = geo.size.height + contentHeight
                    let cycle = travel > 1 ? CGFloat(elapsed * 36).truncatingRemainder(dividingBy: travel) : 0
                    credits
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: RollHeight.self, value: proxy.size.height)
                        })
                        .frame(maxWidth: .infinity)
                        .offset(y: geo.size.height - cycle)
                }
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.14),
                        .init(color: .black, location: 0.86),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            VStack {
                HStack {
                    Spacer()
                    Button("Close", action: onClose)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
            }
            .padding(16)
        }
        .onPreferenceChange(RollHeight.self) { contentHeight = $0 }
        .onHover { inside in
            let now = Date()
            if inside, !paused {
                accumulated += now.timeIntervalSince(segmentStart)
                paused = true
            } else if !inside, paused {
                segmentStart = now
                paused = false
            }
        }
    }

    private var credits: some View {
        VStack(spacing: 48) {
            ForEach(creditBlocks) { block in
                VStack(spacing: 8) {
                    Text(block.heading)
                        .font(.title2)
                        .fontWeight(.semibold)
                    ForEach(block.lines) { line in
                        if let url = line.url {
                            Link(line.text, destination: url)
                                .underline()
                        } else {
                            Text(line.text)
                        }
                    }
                    .font(.body)
                }
                .multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(Color(white: 0.92))
        .padding(.horizontal, 40)
        .frame(maxWidth: 520)
    }
}

private struct RollHeight: PreferenceKey {
    static var defaultValue: CGFloat = 900
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct ContentView: View {
    @StateObject private var model = LauncherModel()
    @State private var showCredits = false
    @AppStorage("displayMode") private var displayMode = "window"
    @AppStorage("showLog") private var showLog = false
    @AppStorage("metalHud") private var metalHud = false

    private func cover(_ id: String) -> some View {
        let url = Bundle.main.resourceURL?.appendingPathComponent("covers/\(id).jpg")
        let image = url.flatMap { NSImage(contentsOf: $0) }
        return Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(nsColor: .quaternaryLabelColor)
            }
        }
        .frame(width: 168, height: 94)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
            Text("The PS4 Nathan Drake Collection, through the Windows port.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Text(model.dumpPath ?? "No game folder chosen")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose Folder…", action: model.chooseFolder)
            }
            ForEach(model.games) { game in
                HStack(spacing: 12) {
                    cover(game.id)
                        .opacity(game.available ? 1 : 0.35)
                    Text(game.title)
                    Spacer()
                    Button("Play") { model.play(game, display: displayMode, metalHud: metalHud) }
                        .disabled(!game.available || model.running)
                }
            }
            HStack {
                Picker("Display", selection: $displayMode) {
                    Text("Window").tag("window")
                    Text("Full Screen").tag("fullscreen")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                Spacer()
                Button(model.runningGame.map { "Stop \($0)" } ?? "Stop", action: model.stop)
                    .disabled(!model.running)
            }
            HStack(spacing: 20) {
                Toggle("Show log", isOn: $showLog)
                Toggle("Metal HUD", isOn: $metalHud)
                    .disabled(model.running)
            }
            Text("L3 + R3 opens the port menu.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(model.status)
            if showLog {
                ScrollView {
                    Text(model.log.isEmpty ? "No log yet." : model.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(model.log.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .textSelection(.enabled)
                }
                .frame(height: 180)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
            }
            HStack {
                Spacer()
                Button("Credits & Licenses") { showCredits = true }
            }
            }
            .padding(20)
            if showCredits {
                CreditsRoll { showCredits = false }
            }
        }
        .frame(minWidth: 720, minHeight: 680)
        .onAppear { model.restore() }
    }
}

@main
struct UnchartedApp: App {
    var body: some Scene {
        WindowGroup("Nathan Drake Collection") {
            ContentView()
        }
    }
}
