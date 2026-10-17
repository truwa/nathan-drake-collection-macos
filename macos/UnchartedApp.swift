import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum SupportFolder {
    static let url: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let current = base.appendingPathComponent("Nathan Drake Collection", isDirectory: true)
        let previous = base.appendingPathComponent("Uncharted MacOS", isDirectory: true)
        if FileManager.default.fileExists(atPath: previous.path),
           !FileManager.default.fileExists(atPath: current.path) {
            try? FileManager.default.moveItem(at: previous, to: current)
        }
        return current
    }()
}

struct GameRow: Identifiable {
    let id: String
    let title: String
    var available: Bool
    var note = ""
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var dumpPath: String?
    @Published var games: [GameRow] = [
        GameRow(id: "u1", title: "1. Drake's Fortune", available: false),
        GameRow(id: "u2", title: "2. Among Thieves", available: false),
        GameRow(id: "u3", title: "3. Drake's Deception", available: false),
    ]
    @Published var status = "Choose the folder that contains the game dump."
    @Published var log = ""
    @Published var running = false
    @Published var runningGame: String?
    @Published var runningGameID: String?
    @Published var portVersion = ""
    @Published var portUpdate: String?
    @Published var wineVersion = ""
    @Published var updating = false
    @Published var showCredits = false

    nonisolated static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let version, !version.isEmpty { return version }
        return "1.0"
    }

    private var dumpURL: URL?
    private var gameProcess: Process?
    private var logTimer: Timer?
    private var windowTimer: Timer?
    private var sawGameWindow = false
    private var windowGonePolls = 0
    private var portCheckReported = false

    func restore() {
        loadPortVersion()
        loadWineVersion()
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
        panel.message = "Choose the Nathan Drake Collection dump you own. It needs eboot.bin, big2-ps4_Shipping.elf, and big3-ps4_Shipping.elf."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store(url)
        adopt(url, announce: true)
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
        if !wineReady {
            if wineInstalled {
                beginWineSetup(force: false)
            } else {
                confirmWineDownload(force: false)
            }
            return
        }
        running = true
        runningGame = game.title
        runningGameID = game.id
        sawGameWindow = false
        windowGonePolls = 0
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
                self.windowTimer?.invalidate()
                let title = self.runningGame ?? game.title
                let alreadyNoted = self.status.hasSuffix("closed.") || self.status.hasSuffix("stopped.")
                self.running = false
                self.runningGame = nil
                self.runningGameID = nil
                self.gameProcess = nil
                self.sawGameWindow = false
                if !alreadyNoted {
                    self.status = ended.terminationStatus == 0 ? "\(title) closed." : "\(title) stopped."
                }
            }
        }
        do {
            try process.run()
            gameProcess = process
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let text = String(data: handle.availableData, encoding: .utf8) ?? ""
                guard !text.isEmpty else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.log += text
                    self.noteSwitch(in: text)
                }
            }
            watchGameLog()
            watchGameWindow()
        } catch {
            running = false
            status = "Cannot start: \(error.localizedDescription)"
        }
    }

    func killWine() {
        logTimer?.invalidate()
        windowTimer?.invalidate()
        gameProcess?.terminate()
        running = false
        runningGame = nil
        runningGameID = nil
        gameProcess = nil
        sawGameWindow = false
        status = "Stopping Wine processes…"
        runPort(["--kill-wine"]) { [weak self] line in
            guard let self, line.hasPrefix("status ") else { return }
            self.status = String(line.dropFirst("status ".count))
        } onExit: { [weak self] code in
            guard let self, !self.status.hasPrefix("Wine processes") else { return }
            self.status = code == 0 ? "Wine processes stopped." : "Could not stop the Wine processes."
        }
    }

    func stop() {
        logTimer?.invalidate()
        windowTimer?.invalidate()
        if let runningGame, !status.hasSuffix("closed.") {
            status = "\(runningGame) stopped."
        }
        gameProcess?.terminate()
    }

    private func adopt(_ url: URL, announce: Bool = false) {
        dumpURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        let resolved = resolveDump(url)
        dumpURL = resolved
        dumpPath = resolved.path
        refresh()
        guard announce else { return }
        let missing = games.filter { !$0.available }
        guard !missing.isEmpty else { return }
        let alert = NSAlert()
        if games.contains(where: \.available) {
            alert.messageText = "Some game files are missing."
            alert.alertStyle = .informational
        } else {
            alert.messageText = "That folder is not the Nathan Drake Collection dump."
            alert.alertStyle = .warning
        }
        alert.informativeText = missing.map { "\($0.title): \($0.note)" }.joined(separator: "\n")
            + "\n\nChoose the folder you own with eboot.bin, big2-ps4_Shipping.elf, big3-ps4_Shipping.elf, and the u1data, u2data, and u3data folders."
        alert.runModal()
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
        let specs = [
            ("u1", "1. Drake's Fortune", "eboot.bin", "u1data"),
            ("u2", "2. Among Thieves", "big2-ps4_Shipping.elf", "u2data"),
            ("u3", "3. Drake's Deception", "big3-ps4_Shipping.elf", "u3data"),
        ]
        let rows: [GameRow] = specs.map { id, title, file, data in
            var missing: [String] = []
            var isDirectory = ObjCBool(false)
            let fileURL = dumpURL.appendingPathComponent(file)
            if !FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) || isDirectory.boolValue {
                missing.append(file)
            }
            isDirectory = ObjCBool(false)
            let dataURL = dumpURL.appendingPathComponent(data)
            if !FileManager.default.fileExists(atPath: dataURL.path, isDirectory: &isDirectory) || !isDirectory.boolValue {
                missing.append(data)
            }
            return GameRow(id: id, title: title, available: missing.isEmpty,
                           note: missing.isEmpty ? "" : "Missing " + missing.joined(separator: ", "))
        }
        games = rows
        if rows.allSatisfy(\.available) {
            status = "Choose a game."
        } else if rows.contains(where: \.available) {
            status = "Some of the game files are missing."
        } else {
            status = "This folder is not the collection dump."
        }
    }

    func checkApp() {
        guard !updating else { return }
        updating = true
        let current = Self.appVersion
        Task {
            let result = await Self.latestAppRelease()
            updating = false
            let alert = NSAlert()
            switch result {
            case .failure:
                alert.alertStyle = .warning
                alert.messageText = "Could not check for an app update."
                alert.informativeText = "The launcher's release page did not answer."
                alert.runModal()
            case .success(let release) where Self.isNewer(Self.versionKey(release.tag), than: Self.versionKey(current)):
                alert.alertStyle = .informational
                alert.messageText = "Launcher \(Self.displayVersion(release.tag)) is available."
                alert.informativeText = "This copy is \(current)."
                alert.addButton(withTitle: "Open Release Page")
                alert.addButton(withTitle: "OK")
                if alert.runModal() == .alertFirstButtonReturn, let page = release.page {
                    NSWorkspace.shared.open(page)
                }
            case .success:
                alert.alertStyle = .informational
                alert.messageText = "The launcher is up to date."
                alert.informativeText = "This copy is \(current)."
                alert.runModal()
            }
        }
    }

    func openSaveFolder() {
        let folder = SupportFolder.url.appendingPathComponent("user", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    private struct AppRelease {
        var tag: String
        var page: URL?
    }

    private static func latestAppRelease() async -> Result<AppRelease, Error> {
        guard let endpoint = URL(string: "https://api.github.com/repos/truwa/uncharted-trilogy-macos/releases/latest") else {
            return .failure(URLError(.badURL))
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("uncharted-macos", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = (json["tag_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !tag.isEmpty else {
                return .failure(URLError(.badServerResponse))
            }
            let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            return .success(AppRelease(tag: tag, page: page))
        } catch {
            return .failure(error)
        }
    }

    private static func versionKey(_ text: String) -> [Int] {
        text.drop(while: { $0 == "v" || $0 == "V" }).split(separator: ".").compactMap { part in
            let digits = part.prefix(while: \.isNumber)
            return Int(digits)
        }
    }

    private static func isNewer(_ latest: [Int], than current: [Int]) -> Bool {
        guard !latest.isEmpty else { return false }
        let count = max(latest.count, current.count)
        for index in 0..<count {
            let left = index < latest.count ? latest[index] : 0
            let right = index < current.count ? current[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func displayVersion(_ tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        return text
    }

    private var wineInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: SupportFolder.url.appendingPathComponent("wine/bin/wine").path)
    }

    private var wineReady: Bool {
        wineInstalled && FileManager.default.fileExists(atPath: SupportFolder.url.appendingPathComponent("prefix/system.reg").path)
    }

    func prepareWine() {
        if wineReady {
            loadWineVersion()
            return
        }
        guard !updating else { return }
        if !wineInstalled {
            DispatchQueue.main.async { [weak self] in self?.confirmWineDownload(force: false) }
            return
        }
        beginWineSetup(force: false)
    }

    func updateWine() {
        guard !updating, !running else { return }
        confirmWineDownload(force: true)
    }

    private func confirmWineDownload(force: Bool) {
        guard !updating else { return }
        if !force, wineInstalled { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        if force {
            alert.messageText = "Update Wine"
            alert.informativeText = "The latest WineHQ macOS build will be downloaded, about 180 MB. It replaces the Wine copy used by this launcher. Saves and settings stay."
        } else {
            alert.messageText = "Wine will be downloaded"
            alert.informativeText = "The launcher does not include Wine. The latest WineHQ macOS build is about 180 MB. It is downloaded once, then a private Wine environment is created."
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn {
            beginWineSetup(force: force)
        } else if !wineInstalled {
            status = "Wine is downloaded before a game can start."
        }
    }

    private func beginWineSetup(force: Bool) {
        guard !updating else { return }
        updating = true
        status = !force && wineInstalled ? "Creating the Wine environment…" : "Downloading Wine…"
        runPort([force ? "--update-wine" : "--setup-wine"]) { [weak self] line in
            guard let self else { return }
            if line.hasPrefix("progress ") {
                let phase = self.status.hasPrefix("Creating") ? "Creating the Wine environment" : "Downloading Wine"
                if phase == "Downloading Wine" {
                    self.status = "Downloading Wine… \(line.dropFirst("progress ".count))%"
                }
            } else if line.hasPrefix("status ") {
                self.status = String(line.dropFirst("status ".count))
            } else if line.hasPrefix("installed wine ") {
                self.wineVersion = String(line.dropFirst("installed wine ".count))
            } else if line.hasPrefix("ready ") {
                self.wineVersion = String(line.dropFirst("ready ".count))
            }
        } onExit: { [weak self] code in
            guard let self else { return }
            self.updating = false
            self.loadWineVersion()
            if code != 0 {
                self.status = "Wine setup did not finish. Open the launcher again to retry."
            } else if self.dumpURL == nil {
                self.status = "Choose the folder that contains the game dump."
            } else {
                self.refresh()
            }
        }
    }

    func checkPort() {
        guard !updating else { return }
        updating = true
        portCheckReported = false
        runPort(["--check-port"]) { [weak self] line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { return }
            self?.portCheckReported = true
            self?.portVersion = fields[0]
            self?.portUpdate = fields.count >= 3 && !fields[2].isEmpty ? fields[1] : nil
        } onExit: { [weak self] code in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                self.updating = false
                let alert = NSAlert()
                if code != 0 || !self.portCheckReported {
                    alert.alertStyle = .warning
                    alert.messageText = "Could not check for a port update."
                    alert.informativeText = "The port's release page did not answer."
                } else if let update = self.portUpdate {
                    alert.alertStyle = .informational
                    alert.messageText = "Windows port \(update) is available."
                    alert.informativeText = "This copy is \(self.portVersion). Update installs the new one. Saves and settings stay."
                } else {
                    alert.alertStyle = .informational
                    alert.messageText = "The Windows port is up to date."
                    alert.informativeText = "This copy is \(self.portVersion)."
                }
                alert.runModal()
            }
        }
    }

    func downloadPort() {
        guard !running, !updating else { return }
        updating = true
        status = "Downloading the Windows port…"
        runPort(["--download-port"]) { [weak self] line in
            guard let self else { return }
            if line.hasPrefix("progress ") {
                self.status = "Downloading the Windows port… \(line.dropFirst("progress ".count))%"
            } else if line.hasPrefix("status ") {
                self.status = String(line.dropFirst("status ".count))
            } else if line.hasPrefix("installed ") {
                self.portVersion = String(line.dropFirst("installed ".count))
                self.portUpdate = nil
                self.status = "Windows port \(self.portVersion) installed. Saves and settings were kept."
            } else if line.hasPrefix("Cannot launch:") {
                self.status = line
            }
        } onExit: { [weak self] code in
            guard let self else { return }
            self.updating = false
            if code != 0, !self.status.hasPrefix("Windows port") {
                self.status = "The Windows port update did not finish."
            }
        }
    }

    func installPortZip() {
        guard !running, !updating else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.zip]
        panel.prompt = "Update"
        panel.message = "Choose an uncharted-windows.zip you downloaded."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        updating = true
        status = "Installing the Windows port…"
        runPort(["--install-port", url.path]) { [weak self] line in
            guard let self, line.hasPrefix("installed ") else { return }
            self.portVersion = String(line.dropFirst("installed ".count))
            self.portUpdate = nil
            self.status = "Windows port \(self.portVersion) installed. Saves and settings were kept."
        } onExit: { [weak self] code in
            guard let self else { return }
            self.updating = false
            if code != 0 {
                self.status = "That zip is not an Uncharted Windows port build."
            }
        }
    }

    private func runPort(_ arguments: [String], onLine: @escaping (String) -> Void, onExit: @escaping (Int32) -> Void) {
        let process = Process()
        process.executableURL = pythonURL
        process.arguments = [launcherURL.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = LineBuffer()
        process.terminationHandler = { ended in
            Task { @MainActor in onExit(ended.terminationStatus) }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            let lines = buffer.take(text)
            guard !lines.isEmpty else { return }
            Task { @MainActor in lines.forEach(onLine) }
        }
        try? process.run()
    }

    private func noteSwitch(in text: String) {
        guard let range = text.range(of: "Switching to ") else { return }
        let filename = text[range.upperBound...].prefix { !$0.isNewline }
            .trimmingCharacters(in: .whitespaces)
        let match: (String, String)?
        switch filename {
        case "eboot.bin": match = ("u1", "1. Drake's Fortune")
        case "big2-ps4_Shipping.elf": match = ("u2", "2. Among Thieves")
        case "big3-ps4_Shipping.elf": match = ("u3", "3. Drake's Deception")
        default: match = nil
        }
        guard let match else { return }
        runningGameID = match.0
        runningGame = match.1
        windowGonePolls = 0
        status = "\(match.1) is running."
    }

    private func watchGameWindow() {
        windowTimer?.invalidate()
        sawGameWindow = false
        windowGonePolls = 0
        windowTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollGameWindow() }
        }
    }

    private func pollGameWindow() {
        guard running, let process = gameProcess, process.isRunning else { return }
        if gameWindowVisible(root: process.processIdentifier) {
            sawGameWindow = true
            windowGonePolls = 0
            if let runningGame, status.hasPrefix("Starting") {
                status = "\(runningGame) is running."
            }
            return
        }
        guard sawGameWindow else { return }
        windowGonePolls += 1
        if windowGonePolls >= 6 {
            if let runningGame { status = "\(runningGame) closed." }
            stop()
        }
    }

    private func gameWindowVisible(root: Int32) -> Bool {
        let pids = family(of: root)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in list {
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid) else { continue }
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                  let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                  width > 100, height > 100 else { continue }
            return true
        }
        return false
    }

    private func family(of root: Int32) -> Set<Int32> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ax", "-o", "pid=,ppid="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [root] }
        process.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        var children: [Int32: [Int32]] = [:]
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { continue }
            children[parent, default: []].append(pid)
        }
        var seen: Set<Int32> = []
        var queue = [root]
        while let pid = queue.popLast() {
            if !seen.insert(pid).inserted { continue }
            queue.append(contentsOf: children[pid] ?? [])
        }
        return seen
    }

    private func loadWineVersion() {
        let url = SupportFolder.url.appendingPathComponent("WINE_VERSION")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !version.isEmpty { wineVersion = version }
    }

    private func loadPortVersion() {
        let installed = SupportFolder.url.appendingPathComponent("port/PORT_VERSION")
        let bundled = resources.appendingPathComponent("port/PORT_VERSION")
        let url = FileManager.default.fileExists(atPath: installed.path) ? installed : bundled
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !version.isEmpty { portVersion = version }
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
        SupportFolder.url.appendingPathComponent("prefix/drive_c/uncharted-out.txt")
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
        CreditEntry(text: "Original port by SuperMedo", url: URL(string: "https://github.com/Supermedo/uncharted_pc")),
        CreditEntry(text: "GPL-2.0"),
        CreditEntry(text: "github.com/Supermedo/uncharted_pc", url: URL(string: "https://github.com/Supermedo/uncharted_pc")),
    ]),
    CreditBlock(heading: "Wine", lines: [
        CreditEntry(text: "LGPL-2.1-or-later"),
        CreditEntry(text: "Downloaded on first launch"),
        CreditEntry(text: "macOS build by Gcenx", url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/latest")),
    ]),
    CreditBlock(heading: "KosmicKrisp", lines: [
        CreditEntry(text: "Mesa 26.3.0-devel"),
        CreditEntry(text: "MIT"),
        CreditEntry(text: "docs.mesa3d.org", url: URL(string: "https://docs.mesa3d.org/drivers/kosmickrisp.html")),
    ]),
    CreditBlock(heading: "This launcher", lines: [
        CreditEntry(text: "Version \(LauncherModel.appVersion)"),
        CreditEntry(text: "MacGameTest", url: URL(string: "https://www.youtube.com/@MacGameTest")),
        CreditEntry(text: "youtube.com/@MacGameTest", url: URL(string: "https://www.youtube.com/@MacGameTest")),
        CreditEntry(text: "github.com/truwa/uncharted-trilogy-macos", url: URL(string: "https://github.com/truwa/uncharted-trilogy-macos")),
        CreditEntry(text: "Mac changes are applied at launch"),
    ]),
]

private struct CreditsRoll: View {
    var onClose: () -> Void
    @State private var accumulated: TimeInterval = 0
    @State private var segmentStart = Date()
    @State private var paused = false
    @State private var canPause = false
    @State private var blockHeight: CGFloat = 640

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            GeometryReader { geo in
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    let elapsed = accumulated + (paused ? 0 : timeline.date.timeIntervalSince(segmentStart))
                    let travel = max(geo.size.height + blockHeight, 1)
                    let distance = CGFloat(elapsed * 32).truncatingRemainder(dividingBy: travel)
                    credits
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: RollHeight.self, value: proxy.size.height)
                        })
                        .frame(width: geo.size.width)
                        .offset(y: geo.size.height * 0.58 - distance)
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button("Close", action: onClose)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onPreferenceChange(RollHeight.self) { height in
            if height > 100 { blockHeight = height }
        }
        .onAppear {
            segmentStart = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { canPause = true }
        }
        .onHover { inside in
            guard canPause else { return }
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
        VStack(spacing: 36) {
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
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.primary)
        .focusEffectDisabled()
        .padding(.horizontal, 40)
    }
}

private struct RollHeight: PreferenceKey {
    static var defaultValue: CGFloat = 900
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private final class LineBuffer: @unchecked Sendable {
    private var text = ""
    func take(_ chunk: String) -> [String] {
        text += chunk
        var lines: [String] = []
        while let newline = text.firstIndex(of: "\n") {
            let line = text[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
            text = String(text[text.index(after: newline)...])
            if !line.isEmpty { lines.append(String(line)) }
        }
        return lines
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: LauncherModel
    @AppStorage("displayMode") private var displayMode = "window"
    @AppStorage("showLog") private var showLog = false
    @AppStorage("metalHud") private var metalHud = false
    @AppStorage("appearance") private var appearance = "system"
    @State private var dumpDetails = false
    @State private var optionsOpen = false
    @State private var contentHeight: CGFloat = 0

    private func cover(_ game: GameRow) -> some View {
        let installed = SupportFolder.url.appendingPathComponent("port/covers/\(game.id).jpg")
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("covers/\(game.id).jpg")
        let image = NSImage(contentsOf: installed) ?? bundled.flatMap { NSImage(contentsOf: $0) }
        let parts = game.title.split(separator: ".", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let number = parts.count > 1 ? parts[0] : ""
        let name = parts.count > 1 ? parts[1] : game.title
        return ZStack(alignment: .bottomLeading) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(nsColor: .quaternaryLabelColor)
            }
            LinearGradient(
                colors: [.clear, .black.opacity(0.2), .black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            VStack(alignment: .leading, spacing: 1) {
                if !number.isEmpty {
                    Text(number)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                }
                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(8)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
        }
        .frame(width: 148, height: 158)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.18)))
        .accessibilityLabel(game.title)
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
            Text("The PS4 Nathan Drake Collection, through the Windows port.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Button(action: model.chooseFolder) {
                    Label("Point to the Nathan Drake Collection dump you own:", systemImage: "folder")
                        .font(.headline)
                        .multilineTextAlignment(.leading)
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel("Point to the Nathan Drake Collection dump you own:")
                Spacer(minLength: 8)
                Button {
                    dumpDetails.toggle()
                } label: {
                    Image(systemName: dumpDetails ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(dumpDetails ? "Hide dump details" : "Show dump details")
            }
            if dumpDetails {
                Text("The folder needs eboot.bin, big2-ps4_Shipping.elf, big3-ps4_Shipping.elf, and the u1data, u2data, and u3data folders.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.dumpPath ?? "No game folder chosen")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.games) { game in
                HStack(spacing: 12) {
                    cover(game)
                        .opacity(game.available ? 1 : 0.35)
                    if !game.note.isEmpty {
                        Text(game.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(model.runningGameID == game.id ? "Stop" : "Play") {
                        if model.runningGameID == game.id {
                            model.stop()
                        } else {
                            model.play(game, display: displayMode, metalHud: metalHud)
                        }
                    }
                    .disabled(model.updating || (model.runningGameID != game.id && (!game.available || model.running)))
                }
            }
            Text("Insert, Left Shift + V, or L3 + R3 opens the port menu while in the game.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(model.status)
            DisclosureGroup("Options", isExpanded: $optionsOpen) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Appearance")
                        Picker("Appearance", selection: $appearance) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }
                    HStack {
                        Text("Start the game in")
                        Picker("Start the game in", selection: $displayMode) {
                            Text("Window").tag("window")
                            Text("Full Screen").tag("fullscreen")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 280)
                    }
                    HStack(spacing: 20) {
                        Toggle("Show log", isOn: $showLog)
                        Toggle("Metal HUD", isOn: $metalHud)
                            .disabled(model.running)
                    }
                    HStack {
                        Text(wineLabel)
                            .lineLimit(1)
                        Spacer()
                        Button("Kill all wine processes") { model.killWine() }
                            .disabled(model.updating)
                        Button("Update Wine") { model.updateWine() }
                            .disabled(model.running || model.updating)
                    }
                    HStack {
                        Text(portLabel)
                            .lineLimit(1)
                        Spacer()
                        Button("Check for Updates") { model.checkPort() }
                            .disabled(model.running || model.updating)
                        if let update = model.portUpdate {
                            Button("Update to \(update)") { model.downloadPort() }
                                .disabled(model.running || model.updating)
                        }
                        Button("Update from Zip…", action: model.installPortZip)
                            .disabled(model.running || model.updating)
                    }
                }
                .padding(.top, 4)
            }
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
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }
            HStack {
                Text("Version \(LauncherModel.appVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Credits & Licenses") { model.showCredits = true }
            }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeight.self, value: proxy.size.height)
            })
            if model.showCredits {
                CreditsRoll { model.showCredits = false }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowHeight(height: contentHeight))
        .frame(minWidth: 720)
        .onPreferenceChange(ContentHeight.self) { height in
            if height > 300 { contentHeight = height }
        }
        .preferredColorScheme(preferredScheme)
        .onAppear {
            dumpDetails = false
            optionsOpen = false
            applyAppearance()
            model.restore()
            model.prepareWine()
        }
        .onChange(of: model.showCredits) { _, showing in
            if showing { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onChange(of: appearance) { _, _ in applyAppearance() }
    }

    private var preferredScheme: ColorScheme? {
        switch appearance {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    private func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    private var wineLabel: String {
        if model.wineVersion.isEmpty { return "Wine downloads on first launch" }
        return "Wine \(model.wineVersion)"
    }

    private var portLabel: String {
        if model.portVersion.isEmpty { return "Windows port" }
        if model.portVersion == "unknown" { return "Windows port, version unknown" }
        if model.portVersion == "custom" { return "Windows port from a zip" }
        return "Windows port \(model.portVersion)"
    }
}

@main
struct UnchartedApp: App {
    @StateObject private var model = LauncherModel()

    var body: some Scene {
        WindowGroup("Nathan Drake Collection") {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 760, height: 640)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check App Updates") { model.checkApp() }
                    .disabled(model.updating)
                Button("Check for Windows Port Updates") { model.checkPort() }
                    .disabled(model.running || model.updating)
                Button("Open Game Save Folder") { model.openSaveFolder() }
                Button("Credits & Licenses") { model.showCredits = true }
            }
        }
    }
}

private struct ContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct WindowHeight: NSViewRepresentable {
    var height: CGFloat

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let height = height
        DispatchQueue.main.async {
            guard height > 200, let window = view.window else { return }
            if let applied = context.coordinator.applied, abs(applied - height) < 2 { return }
            var frame = window.frame
            let content = window.contentRect(forFrameRect: frame)
            let delta = height - content.height
            frame.size.height += delta
            frame.origin.y -= delta
            let minimum = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 720, height: height)).size
            window.minSize = minimum
            window.setFrame(frame, display: true, animate: context.coordinator.applied != nil)
            context.coordinator.applied = height
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var applied: CGFloat?
    }
}
