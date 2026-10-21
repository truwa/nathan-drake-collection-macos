import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

private enum SupportFolder {
    static let url: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NathanDrakeCollection", isDirectory: true)
    }()
}

struct GameRow: Identifiable {
    let id: String
    let title: String
    var available: Bool
    var note = ""
}

struct PortSettings: Codable, Equatable {
    var qualityPreset = "medium"
    var displayMode = "windowed"
    var resolution = "1920x1080"
    var aspect = "16:9"
    var upscaler = "off"
    var upscale = "off"
    var aa = "off"
    var vsync = true
    var rcas = true
    var rcasStrength = "75"
    var showFPS = false
    var fpsLimit = "60"
    var framesQueued = "1"
    var asyncShaders = true
    var multithreaded = false
    var jobSleep = "on"
    var language = "1"
    var unlock = false
    var cheats: [String] = []
    var appearance = "system"
    var showLog = false
    var metalHUD = false
    var logLevel = "normal"

    enum CodingKeys: String, CodingKey {
        case qualityPreset = "quality_preset"
        case displayMode = "display_mode"
        case resolution, aspect, upscaler, upscale, aa, vsync, rcas
        case rcasStrength = "rcas_strength"
        case showFPS = "show_fps"
        case fpsLimit = "fps_limit"
        case framesQueued = "frames_queued"
        case asyncShaders = "async_shaders"
        case multithreaded
        case jobSleep = "job_sleep"
        case language, unlock, cheats, appearance
        case showLog = "show_log"
        case metalHUD = "metal_hud"
        case logLevel = "log_level"
    }

    init() {}

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        qualityPreset = try box.decodeIfPresent(String.self, forKey: .qualityPreset) ?? "medium"
        displayMode = try box.decodeIfPresent(String.self, forKey: .displayMode) ?? "windowed"
        resolution = try box.decodeIfPresent(String.self, forKey: .resolution) ?? "1920x1080"
        aspect = try box.decodeIfPresent(String.self, forKey: .aspect) ?? "16:9"
        upscaler = try box.decodeIfPresent(String.self, forKey: .upscaler) ?? "off"
        upscale = try box.decodeIfPresent(String.self, forKey: .upscale) ?? "off"
        aa = try box.decodeIfPresent(String.self, forKey: .aa) ?? "off"
        vsync = try box.decodeIfPresent(Bool.self, forKey: .vsync) ?? true
        rcas = try box.decodeIfPresent(Bool.self, forKey: .rcas) ?? true
        rcasStrength = try box.decodeIfPresent(String.self, forKey: .rcasStrength) ?? "75"
        showFPS = try box.decodeIfPresent(Bool.self, forKey: .showFPS) ?? false
        fpsLimit = try box.decodeIfPresent(String.self, forKey: .fpsLimit) ?? "60"
        framesQueued = try box.decodeIfPresent(String.self, forKey: .framesQueued) ?? "1"
        asyncShaders = try box.decodeIfPresent(Bool.self, forKey: .asyncShaders) ?? true
        multithreaded = try box.decodeIfPresent(Bool.self, forKey: .multithreaded) ?? false
        jobSleep = try box.decodeIfPresent(String.self, forKey: .jobSleep) ?? "on"
        language = try box.decodeIfPresent(String.self, forKey: .language) ?? "1"
        unlock = try box.decodeIfPresent(Bool.self, forKey: .unlock) ?? false
        cheats = try box.decodeIfPresent([String].self, forKey: .cheats) ?? []
        appearance = try box.decodeIfPresent(String.self, forKey: .appearance) ?? "system"
        showLog = try box.decodeIfPresent(Bool.self, forKey: .showLog) ?? false
        metalHUD = try box.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        logLevel = try box.decodeIfPresent(String.self, forKey: .logLevel) ?? "normal"
    }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var dumpPath: String?
    @Published var updatePath: String?
    @Published var games: [GameRow] = [
        GameRow(id: "u1", title: "1. Drake's Fortune", available: false),
        GameRow(id: "u2", title: "2. Among Thieves", available: false),
        GameRow(id: "u3", title: "3. Drake's Deception", available: false),
    ]
    @Published var gameVersion = ""
    @Published var titleID = ""
    @Published var status = "Choose the game folder you own."
    @Published var log = ""
    @Published var running = false
    @Published var runningGame: String?
    @Published var runningGameID: String?
    @Published var nativeReady = false
    @Published var showCredits = false
    @Published var showGameSettings = false
    @Published var settings = PortSettings()
    @Published var runtimeBlock: String?

    nonisolated static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        if let version, !version.isEmpty { return version }
        return "1.0"
    }

    private var dumpURL: URL?
    private var updateURL: URL?
    private var gameProcess: Process?
    private var logTimer: Timer?
    private var windowTimer: Timer?
    private var sawGameWindow = false
    private var windowGonePolls = 0
    private var ignoredUpdate = false
    private var logRemainder = ""
    private var logFileLength = 0
    private var seenLogLines: [String: Int] = [:]

    func restore() {
        runtimeBlock = runtimeRequirement()
        loadSettings()
        detectNative()
        if let url = restoreBookmark("dumpBookmark") {
            adoptDump(url)
        }
        if let url = restoreBookmark("updateBookmark") {
            adoptUpdate(url, fromUser: false)
        }
        inspect()
    }

    func chooseDump() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the Nathan Drake Collection folder you own. It needs eboot.bin and sce_sys."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        storeBookmark("dumpBookmark", "dumpPath", url)
        adoptDump(url, announce: true)
        ignoredUpdate = false
        inspect()
    }

    func chooseUpdate() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the extracted update 1.02 folder, only if it is dumped apart from the game."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let dumpURL, url.standardizedFileURL == dumpURL.standardizedFileURL {
            alert("That is the game folder itself.", "Choose the update's folder.")
            return
        }
        storeBookmark("updateBookmark", "updatePath", url)
        ignoredUpdate = false
        adoptUpdate(url, fromUser: true)
        inspect()
    }

    func clearUpdate() {
        updateURL?.stopAccessingSecurityScopedResource()
        updateURL = nil
        updatePath = nil
        ignoredUpdate = true
        UserDefaults.standard.removeObject(forKey: "updateBookmark")
        UserDefaults.standard.removeObject(forKey: "updatePath")
        inspect()
    }

    func play(_ game: GameRow) {
        guard game.available, !running else { return }
        if let runtimeBlock {
            alert("This Mac cannot run the games.", runtimeBlock)
            return
        }
        guard nativeReady else {
            alert("The native runtime is missing.", "This app needs the BilalReloaded probe. Rebuild NathanDrakeCollection.app.")
            return
        }
        guard dumpURL != nil else {
            chooseDump()
            return
        }
        if gameVersion.hasPrefix("01.00") || (gameVersion == "1.00") {
            if updateURL == nil {
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "This dump is version 1.00, without update 1.02."
                alert.informativeText = "Most of this port's fixes are written for update 1.02. Dump that update from your PS4 and choose it here, or extract it next to the game folder as a -patch folder."
                alert.addButton(withTitle: "Play anyway")
                alert.addButton(withTitle: "Not Now")
                if alert.runModal() != .alertFirstButtonReturn { return }
            }
        }
        saveSettings()
        running = true
        runningGame = game.title
        runningGameID = game.id
        sawGameWindow = false
        windowGonePolls = 0
        status = "Starting \(game.title)…"
        clearLog()
        let process = Process()
        process.executableURL = pythonURL
        process.environment = portEnvironment()
        var arguments = [launcherURL.path, "--dump", dumpURL!.path, "--exe", game.id, "--settings", settingsURL.path]
        if let updateURL {
            arguments += ["--update", updateURL.path]
        } else if ignoredUpdate {
            arguments.append("--no-update")
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
                    self.appendLog(text)
                }
            }
            watchGameLog()
            watchGameWindow()
        } catch {
            running = false
            status = "Cannot start: \(error.localizedDescription)"
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

    func clearLog() {
        log = ""
        logRemainder = ""
        logFileLength = 0
        seenLogLines.removeAll()
    }

    func openSaveFolder() {
        let folder = SupportFolder.url.appendingPathComponent("user", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    func applyPreset(_ name: String) {
        settings.qualityPreset = name
        switch name {
        case "low":
            settings.resolution = "1920x1080"
            settings.upscaler = "fsr1"
            settings.upscale = "performance"
            settings.aa = "off"
            settings.fpsLimit = "60"
            settings.rcas = true
            settings.rcasStrength = "75"
        case "high":
            settings.resolution = "2560x1440"
            settings.upscaler = "off"
            settings.upscale = "off"
            settings.fpsLimit = "60"
            settings.rcas = true
            settings.rcasStrength = "50"
        case "ultra":
            settings.resolution = "3840x2160"
            settings.upscaler = "off"
            settings.upscale = "off"
            settings.fpsLimit = "120"
            settings.rcas = true
            settings.rcasStrength = "50"
        default:
            settings.qualityPreset = "medium"
            settings.resolution = "1920x1080"
            settings.upscaler = "off"
            settings.upscale = "off"
            settings.aa = "off"
            settings.fpsLimit = "60"
            settings.rcas = true
            settings.rcasStrength = "75"
        }
        settings.framesQueued = "1"
        settings.vsync = true
        settings.asyncShaders = true
        saveSettings()
    }

    func markCustom() {
        if settings.qualityPreset != "custom" {
            settings.qualityPreset = "custom"
        }
        saveSettings()
    }

    private func adoptDump(_ url: URL, announce: Bool = false) {
        dumpURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        dumpURL = resolveFolder(url)
        dumpPath = dumpURL?.path
        if announce, let dumpURL, !FileManager.default.fileExists(atPath: dumpURL.appendingPathComponent("eboot.bin").path) {
            alert("That folder is not the Nathan Drake Collection dump.",
                  "Choose the folder you own with eboot.bin, sce_sys, and the u1data, u2data, and u3data folders.")
        }
    }

    private func adoptUpdate(_ url: URL, fromUser: Bool) {
        updateURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        let resolved = resolveFolder(url)
        updateURL = resolved
        updatePath = resolved.path
        if fromUser {
            let hasBoot = FileManager.default.fileExists(atPath: resolved.appendingPathComponent("eboot.bin").path)
            let hasSFO = FileManager.default.fileExists(atPath: resolved.appendingPathComponent("sce_sys/param.sfo").path)
            if !hasBoot || !hasSFO {
                alert("That is not an update folder.", "It needs eboot.bin and sce_sys/param.sfo.")
            }
        }
    }

    private func resolveFolder(_ url: URL) -> URL {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("eboot.bin").path) {
            return url
        }
        let nested = url.appendingPathComponent("uroot")
        if FileManager.default.fileExists(atPath: nested.appendingPathComponent("eboot.bin").path) {
            return nested
        }
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        let matches = children.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("eboot.bin").path) }
        return matches.count == 1 ? matches[0] : url
    }

    private func inspect() {
        guard let dumpURL else {
            games = games.map { GameRow(id: $0.id, title: $0.title, available: false) }
            status = "Choose the game folder you own."
            return
        }
        runPort(["--inspect", "--dump", dumpURL.path] + (updateURL.map { ["--update", $0.path] } ?? [])) { [weak self] line in
            guard let self else { return }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { return }
            switch fields[0] {
            case "native":
                self.nativeReady = !fields[1].isEmpty
            case "version":
                self.gameVersion = fields[1]
            case "title":
                self.titleID = fields[1]
            case "update":
                if self.updateURL == nil, !self.ignoredUpdate, !fields[1].isEmpty {
                    self.adoptUpdate(URL(fileURLWithPath: fields[1]), fromUser: false)
                }
            case "u1", "u2", "u3":
                let available = fields.count > 2 && fields[2] == "yes"
                let note = fields.count > 3 ? fields[3] : ""
                if let index = self.games.firstIndex(where: { $0.id == fields[0] }) {
                    var rows = self.games
                    rows[index].available = available
                    rows[index].note = available ? "" : (note.isEmpty ? "Missing files" : "Missing \(note)")
                    self.games = rows
                }
            default:
                break
            }
        } onExit: { [weak self] _ in
            guard let self else { return }
            if self.games.allSatisfy(\.available) {
                self.status = self.gameVersion.isEmpty ? "Choose a game." : "Version \(self.gameVersion). Choose a game."
            } else if self.games.contains(where: \.available) {
                self.status = "Some of the game files are missing."
            } else {
                self.status = "This folder is not the collection dump."
            }
        }
    }

    private func detectNative() {
        runPort(["--native-status"]) { [weak self] line in
            self?.nativeReady = line.hasPrefix("native\t") && line.count > "native\t".count
        } onExit: { [weak self] _ in
            guard let self, !self.nativeReady else { return }
            self.status = "The native BilalReloaded runtime was not found."
        }
    }

    private func storeBookmark(_ bookmarkKey: String, _ pathKey: String, _ url: URL) {
        let scoped = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let plain = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        if let data = scoped ?? plain {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
        UserDefaults.standard.set(url.path, forKey: pathKey)
    }

    private func restoreBookmark(_ key: String) -> URL? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }

    private func loadSettings() {
        let url = settingsURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PortSettings.self, from: data) else { return }
        settings = decoded
    }

    func saveSettings() {
        try? FileManager.default.createDirectory(at: SupportFolder.url, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(settings) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    private var settingsURL: URL {
        SupportFolder.url.appendingPathComponent("launcher.json")
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
        SupportFolder.url.appendingPathComponent("native-boot.log")
    }

    private func portEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let bundled = resources.appendingPathComponent("native")
        if FileManager.default.isExecutableFile(atPath: bundled.appendingPathComponent("gow3_pc/out/gow3-probe").path) {
            env["UNCHARTED_NATIVE"] = bundled.path
        }
        return env
    }

    private func runPort(_ arguments: [String], onLine: @escaping (String) -> Void, onExit: ((Int32) -> Void)? = nil) {
        let process = Process()
        process.executableURL = pythonURL
        process.environment = portEnvironment()
        process.arguments = [launcherURL.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let buffer = LineBuffer()
        process.terminationHandler = { ended in
            let leftover = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            Task { @MainActor in
                for line in buffer.take(leftover) { onLine(line) }
                onExit?(ended.terminationStatus)
            }
        }
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let text = String(data: handle.availableData, encoding: .utf8) ?? ""
            Task { @MainActor in
                for line in buffer.take(text) { onLine(line) }
            }
        }
        do {
            try process.run()
        } catch {
            status = "Cannot start the launcher: \(error.localizedDescription)"
            onExit?(1)
        }
    }

    private func watchGameLog() {
        logTimer?.invalidate()
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pullLog()
            }
        }
    }

    private func pullLog() {
        guard let handle = try? FileHandle(forReadingFrom: gameLogURL) else { return }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        if size < logFileLength { logFileLength = 0 }
        guard size > logFileLength else { return }
        do {
            try handle.seek(toOffset: UInt64(logFileLength))
            let data = handle.readDataToEndOfFile()
            logFileLength = size
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                appendLog(text)
            }
        } catch {
            return
        }
    }

    private func appendLog(_ text: String) {
        logRemainder += text
        let ended = text.hasSuffix("\n") || text.hasSuffix("\r")
        var parts = logRemainder.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if ended {
            logRemainder = ""
        } else {
            logRemainder = parts.popLast() ?? ""
        }
        let kept = parts.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let problem = Self.isProblem(trimmed)
            switch settings.logLevel {
            case "errors":
                guard problem else { return nil }
            case "verbose":
                break
            default:
                guard problem || Self.isNormal(trimmed) else { return nil }
            }
            let count = (seenLogLines[trimmed] ?? 0) + 1
            seenLogLines[trimmed] = count
            if seenLogLines.count > 4_000 { seenLogLines.removeAll() }
            if count > 2 || (count == 2 && settings.logLevel != "verbose") { return nil }
            return count == 1 ? trimmed : trimmed + " (repeating)"
        }
        guard !kept.isEmpty else { return }
        log += kept.joined(separator: "\n") + "\n"
        if log.count > 100_000 {
            let tail = String(log.suffix(80_000))
            if let newline = tail.firstIndex(of: "\n") {
                log = String(tail[tail.index(after: newline)...])
            } else {
                log = tail
            }
        }
        noteSwitch(in: kept.joined(separator: "\n"))
    }

    private static func isProblem(_ text: String) -> Bool {
        let folded = text.lowercased()
        return ["cannot", "failed", "not found", "error", "exception", "assert", "fatal"].contains { folded.contains($0) }
    }

    private static func isNormal(_ text: String) -> Bool {
        let folded = text.lowercased()
        return folded.hasPrefix("engine:") || folded.hasPrefix("game:") || folded.hasPrefix("update:")
            || folded.hasPrefix("log:") || folded.hasPrefix("patched:") || folded.hasPrefix("status ")
            || folded.contains("starting") || folded.contains("guest image")
    }

    private func noteSwitch(in text: String) {
        if text.contains("Starting") || text.contains("Guest image") {
            if let runningGame, !status.hasPrefix("Playing") {
                status = "Playing \(runningGame)."
            }
        }
    }

    private func watchGameWindow() {
        windowTimer?.invalidate()
        windowTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollWindow()
            }
        }
    }

    private func pollWindow() {
        guard running else { return }
        let apps = NSWorkspace.shared.runningApplications
        let probe = apps.contains { app in
            let name = app.localizedName?.lowercased() ?? ""
            let bundle = app.bundleIdentifier?.lowercased() ?? ""
            return name.contains("gow3-probe") || name.contains("uncharted") && !bundle.contains("nathandrakecollection")
        }
        if probe {
            sawGameWindow = true
            windowGonePolls = 0
        } else if sawGameWindow {
            windowGonePolls += 1
            if windowGonePolls >= 3 {
                stop()
            }
        }
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

private func runtimeRequirement() -> String? {
    let version = ProcessInfo.processInfo.operatingSystemVersion
    if version.majorVersion < 26 {
        return "This build needs macOS 26 or newer."
    }
    var info = utsname()
    uname(&info)
    let machine = withUnsafePointer(to: &info.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
    if !machine.hasPrefix("arm") {
        return "This build needs Apple Silicon (M1 or newer). Intel Macs are not supported."
    }
    let rosetta = [
        "/Library/Apple/usr/libexec/oah/libRosettaRuntime",
        "/usr/libexec/rosetta",
    ].contains { FileManager.default.fileExists(atPath: $0) }
    if !rosetta {
        return "Rosetta 2 is required. Install it with: softwareupdate --install-rosetta --agree-to-license"
    }
    return nil
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

private let languages: [(String, String)] = [
    ("1", "English (US)"), ("18", "English (UK)"), ("2", "Français"), ("4", "Deutsch"),
    ("5", "Italiano"), ("3", "Español (España)"), ("20", "Español (Latinoamérica)"),
    ("7", "Português (Portugal)"), ("17", "Português (Brasil)"), ("6", "Nederlands"),
    ("14", "Dansk"), ("15", "Norsk"), ("13", "Svenska"), ("12", "Suomi"), ("16", "Polski"),
    ("23", "Čeština"), ("25", "Ελληνικά"), ("8", "Русский"), ("19", "Türkçe"),
    ("0", "日本語"), ("9", "한국어"), ("10", "中文 (繁體)"),
]

private let creditBlocks: [CreditBlock] = [
    CreditBlock(heading: "Nathan Drake Collection", lines: [
        CreditEntry(text: "Drake's Fortune"),
        CreditEntry(text: "Among Thieves"),
        CreditEntry(text: "Drake's Deception"),
        CreditEntry(text: "A Mac launcher for the BilalReloaded PC port"),
        CreditEntry(text: "The games are not included"),
    ]),
    CreditBlock(heading: "The games", lines: [
        CreditEntry(text: "Naughty Dog"),
        CreditEntry(text: "Sony Interactive Entertainment"),
        CreditEntry(text: "Bluepoint Games"),
        CreditEntry(text: "Not affiliated with Sony, Naughty Dog or Bluepoint"),
    ]),
    CreditBlock(heading: "PC port", lines: [
        CreditEntry(text: "BilalReloaded", url: URL(string: "https://github.com/bc160201983")),
        CreditEntry(text: "Original Bloodborne / Uncharted lineage by SuperMedo",
                    url: URL(string: "https://github.com/Supermedo/uncharted_pc")),
    ]),
    CreditBlock(heading: "KosmicKrisp", lines: [
        CreditEntry(text: "Mesa Vulkan on Metal"),
        CreditEntry(text: "MIT"),
        CreditEntry(text: "docs.mesa3d.org", url: URL(string: "https://docs.mesa3d.org/drivers/kosmickrisp.html")),
    ]),
    CreditBlock(heading: "This launcher", lines: [
        CreditEntry(text: "Version \(LauncherModel.appVersion)"),
        CreditEntry(text: "MacGameTest", url: URL(string: "https://www.youtube.com/@MacGameTest")),
        CreditEntry(text: "github.com/truwa/uncharted-trilogy-macos", url: URL(string: "https://github.com/truwa/uncharted-trilogy-macos")),
    ]),
]

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

struct ContentView: View {
    @EnvironmentObject private var model: LauncherModel
    @EnvironmentObject private var updates: AppUpdateModel
    @Environment(\.openWindow) private var openWindow
    @State private var optionsOpen = false
    @State private var contentHeight: CGFloat = 0
    @State private var systemScheme = Self.systemColorScheme()

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 10) {
                Text("The games are not included. Point this app at a dump you own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                folderRow("Game folder", path: model.dumpPath, action: model.chooseDump)
                HStack(alignment: .firstTextBaseline) {
                    folderRow("Update folder (optional)", path: model.updatePath, action: model.chooseUpdate)
                    if model.updatePath != nil {
                        Button("Clear", action: model.clearUpdate)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                }
                if !model.gameVersion.isEmpty || !model.titleID.isEmpty {
                    Text([model.titleID, model.gameVersion.isEmpty ? nil : "version \(model.gameVersion)"]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
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
                                model.play(game)
                            }
                        }
                        .disabled(updates.busy || (model.runningGameID != game.id && (!game.available || model.running || model.runtimeBlock != nil)))
                    }
                }
                Text("Insert or R3 + L2 opens the port menu while in the game.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(model.status)
                Foldout("Launcher options", isExpanded: $optionsOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Appearance")
                            Picker("Appearance", selection: $model.settings.appearance) {
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
                            Picker("Start the game in", selection: $model.settings.displayMode) {
                                Text("Window").tag("windowed")
                                Text("Borderless").tag("borderless")
                                Text("Full Screen").tag("fullscreen")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 420)
                        }
                        HStack {
                            Text("Logging")
                            Picker("Logging", selection: $model.settings.logLevel) {
                                Text("Errors").tag("errors")
                                Text("Normal").tag("normal")
                                Text("Verbose").tag("verbose")
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(maxWidth: 280)
                            .disabled(model.running)
                        }
                        HStack(spacing: 20) {
                            Toggle("Show log", isOn: $model.settings.showLog)
                            Toggle("Metal HUD", isOn: $model.settings.metalHUD)
                                .disabled(model.running)
                        }
                    }
                    .padding(.top, 4)
                }
                if model.settings.showLog {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Spacer()
                            Button("Copy") { copyLog() }
                            Button("Save…") { saveLog() }
                            Button("Clear") { model.clearLog() }
                        }
                        .controlSize(.small)
                        .disabled(model.log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        LogText(text: model.log)
                            .frame(height: 120)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                            .overlay(alignment: .topLeading) {
                                if model.log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("No log yet.")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .padding(8)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                }
                HStack {
                    Text("Version \(LauncherModel.appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Game Settings…") { openWindow(id: "game-settings") }
                    Button("Check for Updates") { updates.check() }
                        .disabled(model.running || updates.busy)
                    Button("Credits & Licenses") { model.showCredits = true }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeight.self, value: proxy.size.height)
            })
            if model.showCredits {
                CreditsRoll { model.showCredits = false }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .background(WindowHeight(height: contentHeight))
        .frame(minWidth: 720)
        .onPreferenceChange(ContentHeight.self) { height in
            if height > 160 { contentHeight = height }
        }
        .preferredColorScheme(preferredScheme)
        .onAppear {
            optionsOpen = false
            systemScheme = Self.systemColorScheme()
            applyAppearance()
            model.restore()
        }
        .onChange(of: model.showCredits) { _, showing in
            if showing { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onChange(of: model.settings.appearance) { _, _ in
            systemScheme = Self.systemColorScheme()
            applyAppearance()
        }
        .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))) { _ in
            systemScheme = Self.systemColorScheme()
            if model.settings.appearance == "system" { applyAppearance() }
        }
        .onChange(of: model.settings) { _, _ in model.saveSettings() }
        .onChange(of: model.showGameSettings) { _, show in
            if show {
                openWindow(id: "game-settings")
                model.showGameSettings = false
            }
        }
    }

    private func copyLog() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(model.log, forType: .string)
    }

    private func saveLog() {
        let text = model.log
        let panel = NSSavePanel()
        panel.title = "Save log"
        panel.nameFieldStringValue = "nathan-drake-collection-log.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                Task { @MainActor in
                    model.status = "Could not save the log."
                }
            }
        }
    }

    private static func systemColorScheme() -> ColorScheme {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }

    private func folderRow(_ title: String, path: String?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: action) {
                Label("\(title):", systemImage: "folder")
                    .font(.headline)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            Text(path ?? "Not chosen")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(.secondary)
        }
    }

    private func cover(_ game: GameRow) -> some View {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("covers/\(game.id).jpg")
        let dumpIcon = model.dumpPath.map { URL(fileURLWithPath: $0).appendingPathComponent("sce_sys/icon0.png") }
        let image = bundled.flatMap { NSImage(contentsOf: $0) }
            ?? dumpIcon.flatMap { NSImage(contentsOf: $0) }
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

    private var preferredScheme: ColorScheme {
        switch model.settings.appearance {
        case "light": return .light
        case "dark": return .dark
        default: return systemScheme
        }
    }

    private func applyAppearance() {
        let name: NSAppearance.Name? = switch model.settings.appearance {
        case "light": .aqua
        case "dark": .darkAqua
        default: nil
        }
        let resolved = name.flatMap { NSAppearance(named: $0) }
        NSApp.appearance = resolved
        for window in NSApp.windows {
            window.appearance = resolved
        }
    }
}

private struct PortSettingsView: View {
    @EnvironmentObject private var model: LauncherModel

    var body: some View {
        Form {
            Section("Quality") {
            labeled("Preset") {
                Picker("Quality", selection: qualityBinding) {
                    Text("Low").tag("low")
                    Text("Medium").tag("medium")
                    Text("High").tag("high")
                    Text("Ultra").tag("ultra")
                    if model.settings.qualityPreset == "custom" {
                        Text("Custom").tag("custom")
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            labeled("Display mode") {
                Picker("Display mode", selection: custom($model.settings.displayMode)) {
                    Text("Windowed").tag("windowed")
                    Text("Borderless").tag("borderless")
                    Text("Fullscreen").tag("fullscreen")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            labeled("Resolution") {
                Picker("Resolution", selection: custom($model.settings.resolution)) {
                    Text("540p").tag("960x540")
                    Text("720p").tag("1280x720")
                    Text("900p").tag("1600x900")
                    Text("1080p").tag("1920x1080")
                    Text("1440p").tag("2560x1440")
                    Text("1620p").tag("2880x1620")
                    Text("4K").tag("3840x2160")
                }
                .labelsHidden()
                .frame(maxWidth: 160)
            }
            labeled("Aspect ratio") {
                Picker("Aspect ratio", selection: custom($model.settings.aspect)) {
                    Text("16:10").tag("16:10")
                    Text("16:9").tag("16:9")
                    Text("21:9").tag("21:9")
                    Text("32:9").tag("32:9")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            labeled("Upscaling") {
                Picker("Upscaling", selection: custom($model.settings.upscaler)) {
                    Text("Off").tag("off")
                    Text("FSR 1").tag("fsr1")
                    Text("FSR 3.1").tag("fsr3")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if model.settings.upscaler != "off" {
                labeled("Upscaling quality") {
                    Picker("Upscaling quality", selection: custom($model.settings.upscale)) {
                        Text("Native AA").tag("off")
                        Text("Quality").tag("quality")
                        Text("Balanced").tag("balanced")
                        Text("Performance").tag("performance")
                        Text("Ultra Perf.").tag("ultra")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
            if model.settings.upscaler == "off" || model.settings.upscaler == "fsr1" {
                labeled("Anti-aliasing") {
                    Picker("Anti-aliasing", selection: custom($model.settings.aa)) {
                        Text("Off").tag("off")
                        Text("TAA").tag("taa")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }
            }
            Section("Performance") {
            labeled("Sharpening") {
                Picker("Sharpening", selection: sharpeningBinding) {
                    Text("Off").tag("off")
                    Text("25%").tag("25")
                    Text("50%").tag("50")
                    Text("75%").tag("75")
                    Text("100%").tag("100")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            labeled("Frame rate limit") {
                Picker("Frame rate limit", selection: custom($model.settings.fpsLimit)) {
                    ForEach(["30", "40", "45", "50", "55", "60", "75", "90", "100", "120"], id: \.self) { value in
                        Text(value == "60" ? "60 ★" : value).tag(value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 120)
            }
            labeled("Frames queued") {
                Picker("Frames queued", selection: custom($model.settings.framesQueued)) {
                    Text("1 ★").tag("1")
                    Text("2").tag("2")
                    Text("Unlimited").tag("0")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Toggle("VSync", isOn: custom($model.settings.vsync))
            Toggle("Show FPS counter", isOn: custom($model.settings.showFPS))
            Toggle("Compile shaders in the background", isOn: custom($model.settings.asyncShaders))
            Toggle("Multithreaded rendering (experimental)", isOn: custom($model.settings.multithreaded))
            labeled("Idle game threads") {
                Picker("Idle game threads", selection: custom($model.settings.jobSleep)) {
                    Text("Sleep ★").tag("on")
                    Text("Spin").tag("off")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            }
            Section("Game") {
            labeled("Game language") {
                Picker("Game language", selection: $model.settings.language) {
                    ForEach(languages, id: \.0) { value, name in
                        Text(name).tag(value)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            Toggle("Unlock all chapters", isOn: $model.settings.unlock)
            }
            Section {
                Button("Open Game Save Folder", action: model.openSaveFolder)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 420)
        .padding(.bottom, 8)
    }

    private var qualityBinding: Binding<String> {
        Binding(
            get: { model.settings.qualityPreset },
            set: { model.applyPreset($0) }
        )
    }

    private var sharpeningBinding: Binding<String> {
        Binding(
            get: { model.settings.rcas ? model.settings.rcasStrength : "off" },
            set: { value in
                if value == "off" {
                    model.settings.rcas = false
                } else {
                    model.settings.rcas = true
                    model.settings.rcasStrength = value
                }
                model.markCustom()
            }
        )
    }

    private func custom<T: Equatable>(_ binding: Binding<T>) -> Binding<T> {
        Binding(
            get: { binding.wrappedValue },
            set: {
                binding.wrappedValue = $0
                model.markCustom()
            }
        )
    }

    private func labeled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title)
            content()
                .frame(maxWidth: 320)
        }
    }
}

@main
struct NathanDrakeCollectionApp: App {
    @StateObject private var model = LauncherModel()
    @StateObject private var updates = AppUpdateModel()

    var body: some Scene {
        WindowGroup("Nathan Drake Collection") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updates)
                .onAppear {
                    updates.blockReason = {
                        if model.running {
                            return "Stop the game before updating the launcher."
                        }
                        return nil
                    }
                    if let reason = model.runtimeBlock {
                        let alert = NSAlert()
                        alert.alertStyle = .critical
                        alert.messageText = "This Mac cannot run the games."
                        alert.informativeText = reason
                        alert.runModal()
                    }
                }
        }
        .defaultSize(width: 760, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Game Settings…") { model.showGameSettings = true }
                Button("Check for Updates") { updates.check() }
                    .disabled(model.running || updates.busy)
                Button("Open Game Save Folder") { model.openSaveFolder() }
                Button("Credits & Licenses") { model.showCredits = true }
            }
        }

        Window("Game Settings", id: "game-settings") {
            PortSettingsView()
                .environmentObject(model)
        }
        .defaultSize(width: 560, height: 640)
    }
}

private struct LogText: NSViewRepresentable {
    var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.textColor = .labelColor
        guard textView.string != text else { return }
        let selected = textView.selectedRange()
        let stick = selected.length == 0 && isNearBottom(scroll)
        textView.string = text
        let length = (text as NSString).length
        if stick {
            textView.scrollToEndOfDocument(nil)
        } else if selected.location <= length {
            let range = NSRange(location: selected.location, length: min(selected.length, length - selected.location))
            textView.setSelectedRange(range)
        }
    }

    private func isNearBottom(_ scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return true }
        let visible = scroll.contentView.bounds
        let limit = document.frame.height - visible.height
        return visible.origin.y >= limit - 24
    }
}

private struct Foldout<Content: View>: View {
    var title: String
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content

    init(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text(title)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                content()
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
            let current = window.contentRect(forFrameRect: window.frame)
            guard abs(current.height - height) >= 2 else {
                context.coordinator.applied = height
                return
            }
            var frame = window.frame
            let delta = height - current.height
            frame.size.height += delta
            frame.origin.y -= delta
            window.minSize = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 720, height: height)).size
            window.setFrame(frame, display: true, animate: false)
            context.coordinator.applied = height
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var applied: CGFloat?
    }
}
