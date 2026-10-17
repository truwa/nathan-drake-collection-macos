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

    func play(_ game: GameRow) {
        guard let dumpURL, game.available, !running else { return }
        running = true
        status = "Starting \(game.title)…"
        log = ""
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [launcherURL.path, "--dump", dumpURL.path, "--exe", game.id]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self else { return }
                self.logTimer?.invalidate()
                self.running = false
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

    func showLicenses() {
        let notices = resources.appendingPathComponent("NOTICES.txt")
        if FileManager.default.fileExists(atPath: notices.path) {
            NSWorkspace.shared.open(notices)
            return
        }
        status = "License notices are beside the app sources (NOTICES.txt)."
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

struct ContentView: View {
    @StateObject private var model = LauncherModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Runs the Uncharted Windows port under Wine.")
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
                HStack {
                    Text(game.title)
                    Spacer()
                    Button("Play") { model.play(game) }
                        .disabled(!game.available || model.running)
                }
            }
            Text(model.status)
            ScrollView {
                Text(model.log.isEmpty ? " " : model.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            HStack {
                if model.running {
                    Button("Stop", action: model.stop)
                }
                Spacer()
                Button("Licenses") { model.showLicenses() }
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 480)
        .onAppear { model.restore() }
    }
}

@main
struct UnchartedApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
