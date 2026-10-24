//
//  LatexCompiler.swift
//  ResearchBase
//
//  Owner: Agent 24 · Features: F-33, L-04, L-07, L-08, L-10
//
//  Builds a draft with latexmk (pdflatex / xelatex / lualatex) or the bundled
//  Tectonic engine, turns the build log into clickable diagnostics, and
//  explains missing classes / packages / styles / fonts. Uses only Foundation
//  and PDFKit: it does not depend on any other new file.
//
//  PUBLIC API  (everything is nested in `LatexCompiler`; nothing global)
//    Engine            .pdflatex .xelatex .lualatex .tectonic
//                      init(storageValue:)  <- the `drafts.engine` column text
//                      storageValue, displayName
//    Settings          engine, shellEscape (false), cleanBuild, outputFolder (".build"),
//                      timeoutSeconds (60), texFolderOverride, minimumFreeBytes, runPreflight
//                      Settings.stored (UserDefaults), Settings.timeoutChoices [60, 180]
//    Installation      locateInstallation(settings:) -> texFolder, latexmk, kpsewhich,
//                      tlmgr, synctex, tectonic, hasSystemTeX, hasBundledEngine
//    Diagnostic        severity, category, file, line, message, context, help, code,
//                      missing (MissingResource), location, canJump
//    MissingResource   kind, name, tlmgrPackage, installCommand, explanation
//    BuildResult       ok, pdfURL, stalePDFURL, synctexURL, logURL, diagnostics,
//                      errorCount, warningCount, pages, duration, engineUsed,
//                      exitCode, timedOut, cancelled, rawOutput, command
//    build(draftFolder:mainFile:settings:libraryCitationKeys:) async -> BuildResult
//    cancel()                                  stops a running build
//    preflight(...) async / staticChecks(...)  the checks that run before a build
//    parseLog / parseLatexmkOutput / parseBibliographyLog   (pure, testable)
//    cleanBuildFiles(draftFolder:settings:includingPDF:) throws -> Int
//    hasEnoughDiskSpace(at:minimumBytes:) -> Bool
//    missingResource(kind:name:) -> MissingResource
//    runCommand(executable:arguments:workingDirectory:environment:timeout:) async
//
//  NOTES FOR OTHER OWNERS
//    * Output goes to <draft>/<outputFolder>/ (default `.build/`, hidden).
//      Snapshots / exports should skip that folder.
//    * SyncTeX file: BuildResult.synctexURL; the `synctex` binary:
//      Installation.synctex.
//    * Shell escape is OFF unless Settings.shellEscape is true.
//

import Foundation
import PDFKit

nonisolated final class LatexCompiler: @unchecked Sendable {

    // MARK: - Engine (L-07)

    nonisolated enum Engine: String, CaseIterable, Codable, Sendable, Identifiable {
        case pdflatex, xelatex, lualatex, tectonic

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .pdflatex: return "latexmk + pdflatex"
            case .xelatex: return "latexmk + xelatex"
            case .lualatex: return "latexmk + lualatex"
            case .tectonic: return "Bundled Tectonic (no install needed)"
            }
        }

        /// Text stored in `drafts.engine`.
        var storageValue: String {
            switch self {
            case .pdflatex: return "latexmk-pdflatex"
            case .xelatex: return "latexmk-xelatex"
            case .lualatex: return "latexmk-lualatex"
            case .tectonic: return "tectonic"
            }
        }

        /// Accepts the stored value and the display names; anything unknown is pdflatex.
        init(storageValue: String) {
            let s = storageValue.lowercased()
            if s.contains("tectonic") { self = .tectonic }
            else if s.contains("xelatex") { self = .xelatex }
            else if s.contains("lualatex") { self = .lualatex }
            else { self = .pdflatex }
        }

        var latexmkFlag: String? {
            switch self {
            case .pdflatex: return "-pdf"
            case .xelatex: return "-pdfxe"
            case .lualatex: return "-pdflua"
            case .tectonic: return nil
            }
        }
    }

    // MARK: - Settings (L-08)

    nonisolated struct Settings: Codable, Equatable, Sendable {
        var engine: Engine = .pdflatex
        /// Off by default. When on, external commands (minted, gnuplot...) may run.
        var shellEscape: Bool = false
        /// Wipe the output folder before building.
        var cleanBuild: Bool = false
        var outputFolder: String = ".build"
        var timeoutSeconds: Double = 60
        var texFolderOverride: String? = nil
        var minimumFreeBytes: Int64 = 50 * 1024 * 1024
        var runPreflight: Bool = true
        /// Use the bundled engine when no system TeX is found.
        var allowBundledFallback: Bool = true

        static let timeoutChoices: [Double] = [60, 180]
        static let defaults = Settings()

        init() {}

        init(engineStorageValue: String) {
            self.engine = Engine(storageValue: engineStorageValue)
        }

        var effectiveTimeout: TimeInterval { min(max(timeoutSeconds, 5), 3600) }

        /// A relative folder inside the draft; anything odd falls back to `.build`.
        var effectiveOutputFolder: String {
            var t = outputFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            t = t.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if t.isEmpty || t == "." || outputFolder.hasPrefix("/") || t.hasPrefix("~") || t.contains("..") || t.contains(":") {
                return ".build"
            }
            return t
        }

        private static let storeKey = "rbA24.latexBuildSettings"

        /// App-wide build settings kept in UserDefaults.
        static var stored: Settings {
            get {
                guard let data = UserDefaults.standard.data(forKey: storeKey),
                      let s = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
                return s
            }
            set {
                if let data = try? JSONEncoder().encode(newValue) {
                    UserDefaults.standard.set(data, forKey: storeKey)
                }
            }
        }
    }

    // MARK: - Installation

    nonisolated struct Installation: Equatable, Sendable {
        var texFolder: URL?
        var latexmk: URL?
        var kpsewhich: URL?
        var tlmgr: URL?
        var synctex: URL?
        var tectonic: URL?

        var hasSystemTeX: Bool { latexmk != nil }
        var hasBundledEngine: Bool { tectonic != nil }
        var summary: String {
            if let f = texFolder { return "TeX found in \(f.path)" }
            if tectonic != nil { return "Bundled engine (Tectonic)" }
            return "No TeX installation found"
        }
    }

    static func locateInstallation(settings: Settings = .defaults) -> Installation {
        let fm = FileManager.default
        var folders: [String] = []
        if let o = settings.texFolderOverride, !o.isEmpty { folders.append(o) }
        folders += ["/Library/TeX/texbin", "/usr/texbin", "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]
        folders += rbA24_versionedTeXFolders(root: "/usr/local/texlive")
        folders += rbA24_versionedTeXFolders(root: NSHomeDirectory() + "/Library/TinyTeX", direct: true)
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            folders += path.split(separator: ":").map(String.init)
        }
        func find(_ name: String) -> URL? {
            for f in folders {
                let p = (f as NSString).appendingPathComponent(name)
                if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
            }
            return nil
        }
        var inst = Installation()
        if let latexmk = find("latexmk") {
            inst.latexmk = latexmk
            inst.texFolder = latexmk.deletingLastPathComponent()
        }
        inst.kpsewhich = find("kpsewhich")
        inst.tlmgr = find("tlmgr")
        inst.synctex = find("synctex")
        if let b = Bundle.main.url(forAuxiliaryExecutable: "tectonic"), fm.isExecutableFile(atPath: b.path) {
            inst.tectonic = b
        } else if let r = Bundle.main.resourceURL?.appendingPathComponent("tectonic"), fm.isExecutableFile(atPath: r.path) {
            inst.tectonic = r
        } else {
            inst.tectonic = find("tectonic")
        }
        return inst
    }

    // MARK: - Diagnostics (L-04, L-10)

    nonisolated enum Severity: String, Codable, Sendable {
        case error, warning, info
        var rank: Int {
            switch self {
            case .error: return 0
            case .warning: return 1
            case .info: return 2
            }
        }
    }

    nonisolated enum Category: String, Codable, Sendable {
        case syntax, structure, package, file, reference, citation, bibliography, font, layout, system, other
    }

    nonisolated struct MissingResource: Equatable, Sendable {
        enum Kind: String, Sendable { case package, documentClass, bibStyle, font, file }
        var kind: Kind
        var name: String
        /// TeX Live package that provides it, when known.
        var tlmgrPackage: String?
        /// Text to run in Terminal, when there is one.
        var installCommand: String?
        var explanation: String
    }

    nonisolated struct Diagnostic: Identifiable, Equatable, Sendable {
        var severity: Severity
        var category: Category
        /// Path relative to the draft folder, nil when unknown.
        var file: String?
        var line: Int?
        var message: String
        var context: String?
        var help: String?
        /// Stable key used to merge duplicates (e.g. "missing-package:algorithm2e").
        var code: String?
        var missing: MissingResource?

        init(severity: Severity, category: Category = .other, file: String? = nil, line: Int? = nil,
             message: String, context: String? = nil, help: String? = nil, code: String? = nil,
             missing: MissingResource? = nil) {
            self.severity = severity
            self.category = category
            self.file = file
            self.line = line
            self.message = message
            self.context = context
            self.help = help
            self.code = code
            self.missing = missing
        }

        var id: String { "\(severity.rawValue)|\(file ?? "")|\(line ?? 0)|\(code ?? "")|\(message)" }
        var canJump: Bool { file != nil && line != nil }
        var location: String? {
            guard let f = file else { return nil }
            if let l = line { return "\(f):\(l)" }
            return f
        }
    }

    // MARK: - Result (F-33)

    nonisolated struct BuildResult: Sendable {
        var ok: Bool = false
        /// The PDF produced by THIS build (nil if none was written).
        var pdfURL: URL?
        /// An older PDF that is still on disk (last successful build), if this build wrote none.
        var stalePDFURL: URL?
        var synctexURL: URL?
        var logURL: URL?
        var diagnostics: [Diagnostic] = []
        var pages: Int?
        var duration: TimeInterval = 0
        var engineUsed: Engine?
        var exitCode: Int32?
        var timedOut: Bool = false
        var cancelled: Bool = false
        var rawOutput: String = ""
        var command: String = ""

        var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
        var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }
    }

    nonisolated struct CommandOutcome: Sendable {
        var exitCode: Int32?
        var output: String
        var timedOut: Bool
        var cancelled: Bool
        var launchError: String?
        var duration: TimeInterval
    }

    // MARK: - Instance state (one build at a time)

    private let lock = NSLock()
    private var building = false
    private var runningBox: rbA24_ProcessBox?

    init() {}

    var isBuilding: Bool {
        lock.lock(); defer { lock.unlock() }
        return building
    }

    func cancel() {
        lock.lock()
        let box = runningBox
        lock.unlock()
        box?.requestCancel()
    }

    // Small synchronous helpers: NSLock must not be used directly inside
    // `async` functions, so every lock/unlock pair lives here.

    /// Returns true when a build is already running; otherwise marks one as started.
    private func claimBuild() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if building { return true }
        building = true
        return false
    }

    private func releaseBuild() {
        lock.lock(); defer { lock.unlock() }
        building = false
        runningBox = nil
    }

    private func setRunningBox(_ box: rbA24_ProcessBox?) {
        lock.lock(); defer { lock.unlock() }
        runningBox = box
    }

    // MARK: - Build

    func build(draftFolder: URL,
               mainFile: String = "main.tex",
               settings: Settings = .defaults,
               libraryCitationKeys: Set<String>? = nil) async -> BuildResult {

        let started = Date()
        if claimBuild() {
            var r = BuildResult()
            r.diagnostics = [Diagnostic(severity: .error, category: .system, message: "A build is already running.", code: "busy")]
            return r
        }
        defer { releaseBuild() }

        func fail(_ d: Diagnostic) -> BuildResult {
            var r = BuildResult()
            r.diagnostics = [d]
            r.duration = Date().timeIntervalSince(started)
            return r
        }

        // 1. The main file must be a plain relative path inside the draft.
        let main = rbA24_normalizePath(mainFile.trimmingCharacters(in: .whitespaces), draft: nil)
        if main.isEmpty || main.hasPrefix("/") || main.contains("..") {
            return fail(Diagnostic(severity: .error, category: .file, message: "The main file name “\(mainFile)” is not valid.", code: "bad-main"))
        }
        let mainURL = draftFolder.appendingPathComponent(main)
        guard rbA24_isFile(mainURL) else {
            return fail(Diagnostic(severity: .error, category: .file, file: main,
                                   message: "The main file “\(main)” was not found in this draft.",
                                   help: "Check the main file name in the draft’s settings.", code: "missing-main"))
        }

        // 2. Disk space (clear message, draft untouched).
        if !Self.hasEnoughDiskSpace(at: draftFolder, minimumBytes: settings.minimumFreeBytes) {
            return fail(Self.diskSpaceDiagnostic())
        }

        // 3. Pick the engine.
        let installation = Self.locateInstallation(settings: settings)
        var engine = settings.engine
        var notes: [Diagnostic] = []
        if engine == .tectonic {
            if installation.tectonic == nil { return fail(Self.noEngineDiagnostic(bundledMissing: true)) }
        } else if installation.latexmk == nil {
            if settings.allowBundledFallback, installation.tectonic != nil {
                engine = .tectonic
                notes.append(Diagnostic(severity: .info, category: .system,
                                        message: "No system TeX was found, so the bundled engine (Tectonic) was used.",
                                        code: "bundled-fallback"))
            } else {
                return fail(Self.noEngineDiagnostic(bundledMissing: false))
            }
        }

        // 4. Prepare the output folder.
        let outName = settings.effectiveOutputFolder
        let outDir = draftFolder.appendingPathComponent(outName, isDirectory: true)
        if settings.cleanBuild { _ = try? Self.cleanBuildFiles(draftFolder: draftFolder, settings: settings, includingPDF: true) }
        do {
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            return fail(Diagnostic(severity: .error, category: .system,
                                   message: "Could not create the output folder “\(outName)”: \(error.localizedDescription)",
                                   help: "Make sure the draft folder is writable.", code: "outdir"))
        }
        Self.mirrorSubfolders(draft: draftFolder, outDir: outDir)

        // 5. Checks that run before the build.
        var preflightDiags: [Diagnostic] = []
        if settings.runPreflight {
            preflightDiags = Self.staticChecks(draftFolder: draftFolder, mainFile: main, outputFolder: outName,
                                               libraryCitationKeys: libraryCitationKeys)
            if engine != .tectonic {
                preflightDiags += await Self.packageChecks(draftFolder: draftFolder, mainFile: main, installation: installation)
            }
        }

        // 6. Run the engine.
        let stem = ((main as NSString).lastPathComponent as NSString).deletingPathExtension
        let pdfURL = outDir.appendingPathComponent(stem + ".pdf")
        let previousPDF = rbA24_isFile(pdfURL) ? pdfURL : nil

        let executable: URL
        let arguments: [String]
        if engine == .tectonic, let t = installation.tectonic {
            executable = t
            arguments = Self.tectonicArguments(mainFile: main, settings: settings)
        } else if let l = installation.latexmk {
            executable = l
            arguments = Self.latexmkArguments(engine: engine, mainFile: main, settings: settings)
        } else {
            return fail(Self.noEngineDiagnostic(bundledMissing: false))
        }
        let env = Self.buildEnvironment(texFolder: installation.texFolder ?? executable.deletingLastPathComponent())
        let commandText = ([executable.lastPathComponent] + arguments).joined(separator: " ")

        let box = rbA24_ProcessBox()
        setRunningBox(box)
        let outcome: CommandOutcome = await withTaskCancellationHandler {
            await box.run(executable: executable, arguments: arguments, cwd: draftFolder, env: env,
                          timeout: settings.effectiveTimeout)
        } onCancel: {
            box.requestCancel()
        }

        // 7. Read what the engine wrote.
        let logURL = outDir.appendingPathComponent(stem + ".log")
        let blgURL = outDir.appendingPathComponent(stem + ".blg")
        let logText = rbA24_readText(logURL)
        var logDiags: [Diagnostic]
        if logText.isEmpty {
            logDiags = Self.parseLog(outcome.output, mainFile: main, draftFolder: draftFolder)
        } else {
            logDiags = Self.parseLog(logText, mainFile: main, draftFolder: draftFolder)
            if engine == .tectonic { logDiags += Self.parseLog(outcome.output, mainFile: main, draftFolder: draftFolder) }
        }
        logDiags += Self.parseLatexmkOutput(outcome.output)
        logDiags += Self.parseBibliographyLog(rbA24_readText(blgURL), draftFolder: draftFolder)

        var extra: [Diagnostic] = []
        if let le = outcome.launchError {
            extra.append(Diagnostic(severity: .error, category: .system,
                                    message: "The build tool could not be started: \(le)", code: "launch"))
        }
        if outcome.timedOut {
            extra.append(Diagnostic(severity: .error, category: .system,
                                    message: "The build took longer than \(Int(settings.effectiveTimeout)) seconds and was stopped.",
                                    help: "Raise the timeout in Build settings, or check for an endless loop in your macros.",
                                    code: "timeout"))
        }
        if outcome.cancelled {
            extra.append(Diagnostic(severity: .info, category: .system, message: "The build was cancelled.", code: "cancelled"))
        }
        if outcome.output.contains("No space left on device") {
            extra.append(Self.diskSpaceDiagnostic())
        }

        // Preflight first: it knows the exact source line (TeX reports a missing package one line late).
        var diags = Self.mergeDiagnostics([extra, notes, preflightDiags, logDiags])

        // 8. Judge the result.
        let fresh = Self.isFresh(pdfURL, since: started)
        let hasError = diags.contains { $0.severity == .error }
        if let code = outcome.exitCode, code != 0, !hasError, !outcome.timedOut, !outcome.cancelled {
            diags.append(Diagnostic(severity: .error, category: .system,
                                    message: "The build failed (exit code \(code)) without an error line in the log.",
                                    help: "Open the raw output to see what the engine printed.", code: "exit-\(code)"))
        }

        var result = BuildResult()
        result.diagnostics = diags
        result.pdfURL = fresh ? pdfURL : nil
        result.stalePDFURL = fresh ? nil : previousPDF
        let sync = outDir.appendingPathComponent(stem + ".synctex.gz")
        result.synctexURL = rbA24_isFile(sync) ? sync : nil
        result.logURL = rbA24_isFile(logURL) ? logURL : nil
        result.engineUsed = engine
        result.exitCode = outcome.exitCode
        result.timedOut = outcome.timedOut
        result.cancelled = outcome.cancelled
        result.rawOutput = outcome.output
        result.command = commandText
        result.duration = Date().timeIntervalSince(started)
        result.ok = fresh && outcome.exitCode == 0 && !outcome.timedOut && !outcome.cancelled
            && !diags.contains { $0.severity == .error }
        result.pages = Self.pageCount(log: logText.isEmpty ? outcome.output : logText, pdf: fresh ? pdfURL : nil)
        return result
    }

    // MARK: - Command lines

    static func latexmkArguments(engine: Engine, mainFile: String, settings: Settings) -> [String] {
        var a: [String] = []
        if let f = engine.latexmkFlag { a.append(f) }
        // -norc: a project .latexmkrc could run any command, so it is ignored unless shell escape is on.
        if !settings.shellEscape { a.append("-norc") }
        a += ["-interaction=nonstopmode", "-file-line-error", "-synctex=1"]
        a.append("-outdir=" + settings.effectiveOutputFolder)
        a.append(settings.shellEscape ? "-latexoption=-shell-escape" : "-latexoption=-no-shell-escape")
        a.append(mainFile)
        return a
    }

    static func tectonicArguments(mainFile: String, settings: Settings) -> [String] {
        var a = [mainFile, "--outdir", settings.effectiveOutputFolder, "--synctex", "--keep-logs"]
        if settings.shellEscape { a += ["-Z", "shell-escape"] }
        return a
    }

    private static func buildEnvironment(texFolder: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        var parts = [texFolder.path]
        parts += (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        var seen = Set<String>()
        env["PATH"] = parts.filter { seen.insert($0).inserted }.joined(separator: ":")
        // Long log lines: no wrapping, so file names and messages stay on one line.
        env["max_print_line"] = "10000"
        env["error_line"] = "254"
        env["half_error_line"] = "238"
        env["TERM"] = "dumb"
        return env
    }

    // MARK: - Folders and disk

    /// True when the volume has at least `minimumBytes` free (or when it cannot be measured).
    static func hasEnoughDiskSpace(at url: URL, minimumBytes: Int64) -> Bool {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let n = values?.volumeAvailableCapacityForImportantUsage { return n >= minimumBytes }
        if let n = values?.volumeAvailableCapacity { return Int64(n) >= minimumBytes }
        return true
    }

    private static func diskSpaceDiagnostic() -> Diagnostic {
        Diagnostic(severity: .error, category: .system,
                   message: "There is not enough free disk space to write the PDF.",
                   help: "Your draft is safe and was not changed. Free some space or move the library to a larger disk, then build again.",
                   code: "disk-space")
    }

    private static func noEngineDiagnostic(bundledMissing: Bool) -> Diagnostic {
        if bundledMissing {
            return Diagnostic(severity: .error, category: .system,
                              message: "The bundled engine (Tectonic) is not installed.",
                              help: "Install it from Build settings, or choose latexmk with a system TeX installation.",
                              code: "no-engine")
        }
        return Diagnostic(severity: .error, category: .system,
                          message: "No TeX installation was found on this Mac.",
                          help: "Install MacTeX (or the smaller BasicTeX, for example with `brew install --cask basictex`), or use the bundled engine in Build settings.",
                          code: "no-engine")
    }

    /// `\include{chapters/a}` writes chapters/a.aux, so those folders must exist in the output folder.
    static func mirrorSubfolders(draft: URL, outDir: URL) {
        let fm = FileManager.default
        let outPath = outDir.resolvingSymlinksInPath().path
        guard let en = fm.enumerator(at: draft, includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        var count = 0
        while let url = en.nextObject() as? URL {
            count += 1
            if count > 3000 { break }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }
            if url.resolvingSymlinksInPath().path.hasPrefix(outPath) { en.skipDescendants(); continue }
            let rel = rbA24_relativePath(of: url, in: draft)
            try? fm.createDirectory(at: outDir.appendingPathComponent(rel, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    /// Removes build files. Keeps the PDF and SyncTeX file unless `includingPDF`.
    @discardableResult
    static func cleanBuildFiles(draftFolder: URL, settings: Settings = .defaults, includingPDF: Bool = false) throws -> Int {
        let fm = FileManager.default
        let out = draftFolder.appendingPathComponent(settings.effectiveOutputFolder, isDirectory: true)
        guard rbA24_isInside(out, draftFolder), fm.fileExists(atPath: out.path),
              let en = fm.enumerator(at: out, includingPropertiesForKeys: [.isDirectoryKey], options: []) else { return 0 }
        var files: [URL] = []
        while let u = en.nextObject() as? URL {
            let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if !isDir { files.append(u) }
        }
        var removed = 0
        for u in files {
            let name = u.lastPathComponent.lowercased()
            if !includingPDF && (name.hasSuffix(".pdf") || name.hasSuffix(".synctex.gz")) { continue }
            try fm.removeItem(at: u)
            removed += 1
        }
        return removed
    }

    private static func isFresh(_ url: URL, since: Date) -> Bool {
        guard let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return false }
        return m >= since.addingTimeInterval(-1)
    }

    private static func pageCount(log: String, pdf: URL?) -> Int? {
        if let c = rbA24_rxOutputWritten.captures(log), let n = Int(c[2]) { return n }
        if let pdf = pdf, let doc = PDFDocument(url: pdf) { return doc.pageCount }
        return nil
    }

    // MARK: - Running a command

    static func runCommand(executable: URL, arguments: [String], workingDirectory: URL? = nil,
                           environment: [String: String]? = nil, timeout: TimeInterval = 60) async -> CommandOutcome {
        let box = rbA24_ProcessBox()
        return await withTaskCancellationHandler {
            await box.run(executable: executable, arguments: arguments, cwd: workingDirectory, env: environment, timeout: timeout)
        } onCancel: {
            box.requestCancel()
        }
    }

    // MARK: - Merging

    /// Removes duplicates (same `code`, or identical text) and orders errors, warnings, info.
    static func mergeDiagnostics(_ lists: [[Diagnostic]]) -> [Diagnostic] {
        var result: [Diagnostic] = []
        var codeIndex: [String: Int] = [:]
        var seen = Set<String>()
        for d in lists.joined() {
            if let c = d.code {
                if let idx = codeIndex[c] {
                    if result[idx].line == nil && d.line != nil {
                        var merged = d
                        if merged.missing == nil { merged.missing = result[idx].missing }
                        if merged.help == nil { merged.help = result[idx].help }
                        result[idx] = merged
                    }
                    continue
                }
                codeIndex[c] = result.count
            }
            if !seen.insert(d.id).inserted { continue }
            result.append(d)
        }
        // Drop consequences of an earlier error.
        if result.contains(where: { $0.severity == .error && $0.code != "emergency-stop" && $0.code != "fatal" }) {
            result.removeAll { $0.code == "emergency-stop" || $0.code == "fatal" }
        }
        let ordered = result.enumerated().sorted {
            if $0.element.severity.rank != $1.element.severity.rank { return $0.element.severity.rank < $1.element.severity.rank }
            return $0.offset < $1.offset
        }
        return ordered.map { $0.element }
    }

    // MARK: - Missing package help (L-10)

    static func installCommand(forPackage name: String) -> String { "sudo tlmgr install \(name)" }

    static func missingResource(kind: MissingResource.Kind, name rawName: String) -> MissingResource {
        var base = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        for ext in [".sty", ".cls", ".bst"] where base.lowercased().hasSuffix(ext) {
            base = String(base.dropLast(ext.count))
        }
        let key = base.lowercased()
        switch kind {
        case .package:
            if let pkg = rbA24_packageTable[key] {
                return MissingResource(kind: kind, name: base, tlmgrPackage: pkg, installCommand: installCommand(forPackage: pkg),
                    explanation: "The LaTeX package “\(base)” is not installed. In Terminal run `\(installCommand(forPackage: pkg))`, then build again. (With the bundled engine, packages download automatically.)")
            }
            return MissingResource(kind: kind, name: base, tlmgrPackage: nil, installCommand: installCommand(forPackage: base),
                explanation: "The LaTeX package “\(base)” is not installed. Try `\(installCommand(forPackage: base))`. If that says the package is unknown, find the right one with `tlmgr search --global --file \"/\(base).sty\"`.")
        case .documentClass:
            if rbA24_manualClasses.contains(key) {
                return MissingResource(kind: kind, name: base, tlmgrPackage: nil, installCommand: nil,
                    explanation: "The class “\(base)” comes from the publisher’s template and is not part of TeX Live. Download the publisher’s template files and copy \(base).cls into the draft folder, next to main.tex.")
            }
            if let pkg = rbA24_classTable[key] {
                return MissingResource(kind: kind, name: base, tlmgrPackage: pkg, installCommand: installCommand(forPackage: pkg),
                    explanation: "The document class “\(base)” is not installed. In Terminal run `\(installCommand(forPackage: pkg))`, then build again.")
            }
            return MissingResource(kind: kind, name: base, tlmgrPackage: nil, installCommand: installCommand(forPackage: base),
                explanation: "The document class “\(base)” is not installed. Try `\(installCommand(forPackage: base))`. If the class comes from a publisher’s template, copy \(base).cls into the draft folder instead.")
        case .bibStyle:
            let pkg = rbA24_bstTable[key]
            let cmd = pkg.map { installCommand(forPackage: $0) }
            let how = cmd.map { "Run `\($0)`, or " } ?? ""
            return MissingResource(kind: kind, name: base, tlmgrPackage: pkg, installCommand: cmd,
                explanation: "The bibliography style “\(base).bst” was not found. \(how)copy \(base).bst into the draft folder next to main.tex.")
        case .font:
            return MissingResource(kind: kind, name: base, tlmgrPackage: nil, installCommand: nil,
                explanation: "The font “\(base)” is not installed on this Mac. Install it (Font Book), or pick another font. The xelatex and lualatex engines use fonts installed on the system.")
        case .file:
            return MissingResource(kind: kind, name: base, tlmgrPackage: nil, installCommand: nil,
                explanation: "The file “\(rawName)” was not found. Check the name and that it is inside the draft folder.")
        }
    }

    // MARK: - Log parsing (L-04)

    /// Reads a TeX `.log` (or raw engine output) into diagnostics.
    static func parseLog(_ log: String, mainFile: String = "main.tex", draftFolder: URL? = nil) -> [Diagnostic] {
        let lines = log.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        let main = rbA24_normalizePath(mainFile, draft: draftFolder)
        var out: [Diagnostic] = []
        var stack: [String] = []   // open files; "" = a parenthesis that is not a file
        var i = 0

        func sourceFiles() -> [String] {
            stack.filter { !$0.isEmpty }.map { rbA24_normalizePath($0, draft: draftFolder) }
        }
        func currentDraftFile() -> String? {
            for p in sourceFiles().reversed() where rbA24_isEditableSource(p) { return p }
            return nil
        }
        func topIsDraft() -> Bool {
            guard let top = sourceFiles().last else { return true }
            return rbA24_isEditableSource(top)
        }
        func updateStack(_ line: String) {
            let chars = Array(line)
            var k = 0
            while k < chars.count {
                let ch = chars[k]
                if ch == "(" {
                    var t = ""
                    var m = k + 1
                    while m < chars.count, !chars[m].isWhitespace, chars[m] != "(", chars[m] != ")" { t.append(chars[m]); m += 1 }
                    stack.append(rbA24_looksLikeTeXFile(t) ? t : "")
                    k = m
                    continue
                } else if ch == ")" {
                    if !stack.isEmpty { stack.removeLast() }
                }
                k += 1
            }
        }
        /// Finds "l.N text" after an error line. Returns (line number, context text).
        func lookahead(from start: Int) -> (Int?, String?) {
            var j = start
            while j < lines.count && j < start + 14 {
                let l = lines[j]
                // A following "Emergency stop" block carries the l.N of the real error, so read through it.
                if l.hasPrefix("! ") && !l.hasPrefix("! Emergency stop") { break }
                if let fc = rbA24_rxFileLine.captures(l), !fc[3].hasPrefix("Emergency stop") { break }
                if let c = rbA24_rxLineCtx.captures(l) {
                    let head = c[2].trimmingCharacters(in: .whitespaces)
                    var tail = ""
                    if j + 1 < lines.count { tail = lines[j + 1].trimmingCharacters(in: .whitespaces) }
                    let text = tail.isEmpty ? head : head + rbA24_hereMarker + tail
                    return (Int(c[1]), text)
                }
                j += 1
            }
            return (nil, nil)
        }

        while i < lines.count {
            let line = lines[i]

            // Error: ./file.tex:12: message
            if let c = rbA24_rxFileLine.captures(line) {
                let rawFile = c[1]
                let n = Int(c[2]) ?? 0
                var msg = c[3].trimmingCharacters(in: .whitespaces)
                let (_, ctx) = lookahead(from: i + 1)
                var file: String? = rbA24_normalizePath(rawFile, draft: draftFolder)
                var ln: Int? = n
                var prefix = ""
                if let f = file, !rbA24_isEditableSource(f) {
                    prefix = "In \((f as NSString).lastPathComponent): "
                    if let il = rbA24_inputLine(in: msg) { ln = il } else { ln = nil }
                    file = currentDraftFile() ?? main
                }
                if msg.isEmpty || msg == "." { msg = "TeX stopped here without a message." }
                var d: Diagnostic
                if msg.hasPrefix("Emergency stop") {
                    d = Diagnostic(severity: .error, category: .system, file: file, line: ln,
                                   message: "Emergency stop: an earlier error ended the build.", code: "emergency-stop")
                } else if msg.contains("Fatal error occurred") {
                    d = Diagnostic(severity: .error, category: .system, file: file, line: ln,
                                   message: "Fatal error: no PDF was produced.", code: "fatal")
                } else {
                    d = rbA24_makeError(message: prefix + msg, file: file, line: ln, context: ctx)
                }
                out.append(d)
                i += 1
                continue
            }

            // Error: ! message
            if line.hasPrefix("! ") {
                let msg = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                let (ln, ctx) = lookahead(from: i + 1)
                var file: String? = currentDraftFile() ?? main
                var useLine: Int? = ln
                var prefix = ""
                if !topIsDraft() {
                    if let top = sourceFiles().last { prefix = "In \((top as NSString).lastPathComponent): " }
                    useLine = rbA24_inputLine(in: msg)
                }
                if msg.hasPrefix("Emergency stop") {
                    out.append(Diagnostic(severity: .error, category: .system, file: file, line: useLine,
                                          message: "Emergency stop: an earlier error ended the build.", code: "emergency-stop"))
                } else {
                    if file == nil { file = main }
                    out.append(rbA24_makeError(message: prefix + msg, file: file, line: useLine, context: ctx))
                }
                i += 1
                continue
            }

            // Warning: LaTeX / Package / Class Warning
            if let c = rbA24_rxWarn.captures(line) {
                let source = c[1]
                var text = c[2]
                var j = i + 1
                if source.hasPrefix("Package ") || source.hasPrefix("Class ") || source.hasPrefix("Module ") {
                    let pkgName = source.split(separator: " ").last.map(String.init) ?? ""
                    while j < lines.count, let cc = rbA24_rxCont.captures(lines[j]), cc[1] == pkgName {
                        text += " " + cc[2]
                        j += 1
                    }
                }
                if let d = rbA24_makeWarning(source: source, text: text, file: currentDraftFile() ?? main) { out.append(d) }
                i = j
                continue
            }
            if let c = rbA24_rxPdfTeXWarn.captures(line) {
                out.append(Diagnostic(severity: .warning, category: .other, file: currentDraftFile() ?? main,
                                      message: "pdfTeX: " + c[2]))
                i += 1
                continue
            }

            // Layout: Overfull / Underfull boxes
            if let c = rbA24_rxBox.captures(line) {
                var ln: Int? = nil
                if let l = rbA24_rxLines.captures(line) { ln = Int(l[1]) }
                out.append(Diagnostic(severity: .warning, category: .layout, file: currentDraftFile() ?? main, line: ln,
                                      message: c[1].trimmingCharacters(in: .whitespaces),
                                      help: "Usually harmless. Rephrase the line, or allow hyphenation, to remove it."))
                i += 1
                continue
            }

            if line.hasPrefix("No pages of output") {
                out.append(Diagnostic(severity: .error, category: .structure, file: main,
                                      message: "The document produced no pages.",
                                      help: "Add some text between \\begin{document} and \\end{document}.", code: "no-pages"))
                i += 1
                continue
            }

            // Tectonic: "error: main.tex:5: message" / "warning: ..."
            if let c = rbA24_rxTectonicErr.captures(line) {
                if !c[3].contains("halted on potentially-recoverable") {
                    let f: String? = c[1].isEmpty ? nil : rbA24_normalizePath(c[1], draft: draftFolder)
                    out.append(rbA24_makeError(message: c[3], file: f ?? main, line: Int(c[2]), context: nil))
                }
                i += 1
                continue
            }
            if let c = rbA24_rxTectonicWarn.captures(line) {
                out.append(Diagnostic(severity: .warning, category: .other, file: currentDraftFile() ?? main, message: c[1]))
                i += 1
                continue
            }

            // "l.12 text" context lines belong to the error above; they do not open or close files.
            if rbA24_rxLineCtx.captures(line) != nil { i += 1; continue }
            updateStack(line)
            i += 1
        }
        return out
    }

    /// Messages that only latexmk prints.
    static func parseLatexmkOutput(_ text: String) -> [Diagnostic] {
        let lines = text.components(separatedBy: "\n")
        var out: [Diagnostic] = []
        var i = 0
        while i < lines.count {
            let l = lines[i]
            if let c = rbA24_rxMaxRuns.captures(l) {
                out.append(Diagnostic(severity: .warning, category: .reference,
                                      message: "The document did not settle after the maximum number of \(c[1]) runs, so cross-references may be wrong.",
                                      help: "Look for a \\label or \\ref whose result changes on every run.", code: "max-runs"))
            } else if l.hasPrefix("Latexmk: Bst file not found") {
                var j = i + 1
                while j < lines.count, lines[j].hasPrefix("  "), !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    out.append(rbA24_missingDiagnostic(kind: .bibStyle, name: lines[j].trimmingCharacters(in: .whitespaces), file: nil, line: nil))
                    j += 1
                }
                i = j
                continue
            }
            i += 1
        }
        return out
    }

    /// BibTeX / Biber log (`.blg`).
    static func parseBibliographyLog(_ text: String, draftFolder: URL? = nil) -> [Diagnostic] {
        var out: [Diagnostic] = []
        for l in text.components(separatedBy: "\n") {
            if let c = rbA24_rxBlgOpenDB.captures(l) {
                let name = c[1].trimmingCharacters(in: .whitespaces)
                out.append(Diagnostic(severity: .error, category: .bibliography,
                                      message: "The bibliography file “\(name)” could not be opened.",
                                      help: "Check that the .bib file named in \\bibliography{…} is inside the draft folder.",
                                      code: "missing-file:\(name)"))
            } else if let c = rbA24_rxBlgStyle.captures(l) {
                out.append(rbA24_missingDiagnostic(kind: .bibStyle, name: c[1].trimmingCharacters(in: .whitespaces), file: nil, line: nil))
            } else if let c = rbA24_rxBlgNoEntry.captures(l) {
                let key = c[1]
                out.append(Diagnostic(severity: .warning, category: .citation,
                                      message: "Citation “\(key)” has no entry in the bibliography file.",
                                      code: "cite-missing:\(key)"))
            } else if let c = rbA24_rxBlgLine.captures(l) {
                let file = rbA24_normalizePath(c[3].trimmingCharacters(in: .whitespaces), draft: draftFolder)
                out.append(Diagnostic(severity: .error, category: .bibliography, file: file, line: Int(c[2]),
                                      message: "Bibliography error: " + c[1].trimmingCharacters(in: .whitespaces)))
            } else if let c = rbA24_rxBiber.captures(l) {
                let sev: Severity = c[1] == "ERROR" ? .error : .warning
                if let k = rbA24_rxBlgNoEntry.captures(c[2]) {
                    out.append(Diagnostic(severity: .warning, category: .citation,
                                          message: "Citation “\(k[1])” has no entry in the bibliography file.",
                                          code: "cite-missing:\(k[1])"))
                } else {
                    out.append(Diagnostic(severity: sev, category: .bibliography, message: "Biber: " + c[2]))
                }
            }
        }
        return out
    }

    // MARK: - Checks before the build (L-04, L-10)

    /// Everything that needs the TeX installation (is each package / class / style installed?).
    static func preflight(draftFolder: URL, mainFile: String, settings: Settings = .defaults,
                          libraryCitationKeys: Set<String>? = nil) async -> [Diagnostic] {
        let inst = locateInstallation(settings: settings)
        var d = staticChecks(draftFolder: draftFolder, mainFile: mainFile, outputFolder: settings.effectiveOutputFolder,
                             libraryCitationKeys: libraryCitationKeys)
        d += await packageChecks(draftFolder: draftFolder, mainFile: mainFile, installation: inst)
        return mergeDiagnostics([d])
    }

    /// Pure source checks: no TeX needed.
    static func staticChecks(draftFolder: URL, mainFile: String, outputFolder: String = ".build",
                             libraryCitationKeys: Set<String>? = nil) -> [Diagnostic] {
        let main = rbA24_normalizePath(mainFile, draft: nil)
        let sources = rbA24_loadSources(draft: draftFolder, mainFile: main)
        guard let mainSource = sources.first else {
            return [Diagnostic(severity: .error, category: .file, file: main,
                               message: "The main file “\(main)” was not found in this draft.", code: "missing-main")]
        }
        var out: [Diagnostic] = []

        if rbA24_rxDocClass.captures(mainSource.masked) == nil {
            out.append(Diagnostic(severity: .error, category: .structure, file: main, line: 1,
                                  message: "There is no \\documentclass in \(main).",
                                  help: "The first line of the main file should be something like \\documentclass{article}.",
                                  code: "no-documentclass"))
        }

        for (idx, src) in sources.enumerated() {
            out += rbA24_structureDiagnostics(file: src.rel, masked: src.masked, isMain: idx == 0)
        }

        // Images
        var graphicDirs: [String] = []
        for src in sources {
            for h in rbA24_rxGraphicsPath.hits(in: src.masked) {
                for g in rbA24_rxBraceGroup.hits(in: h.groups[1]) { graphicDirs.append(g.groups[1]) }
            }
        }
        for src in sources {
            let idx = rbA24_LineIndex(src.masked)
            for h in rbA24_rxGraphic.hits(in: src.masked) {
                let name = h.groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if name.isEmpty || name.contains("\\") || name.contains("#") || name.hasPrefix("example-image") { continue }
                if !rbA24_graphicExists(name, dirs: graphicDirs, draft: draftFolder) {
                    out.append(Diagnostic(severity: .error, category: .file, file: src.rel, line: idx.line(at: h.location),
                                          message: "The image “\(name)” was not found in this draft.",
                                          help: "Put the file in the draft’s figures folder, or fix the path in \\includegraphics.",
                                          code: "missing-file:\(name)"))
                }
            }
        }

        // Bibliography files
        for src in sources {
            let idx = rbA24_LineIndex(src.masked)
            var names: [(String, Int)] = []
            for h in rbA24_rxBibliography.hits(in: src.masked) {
                for p in h.groups[1].split(separator: ",") {
                    var n = String(p).trimmingCharacters(in: .whitespaces)
                    if n.isEmpty || n.contains("\\") { continue }
                    if !n.lowercased().hasSuffix(".bib") { n += ".bib" }
                    names.append((n, idx.line(at: h.location)))
                }
            }
            for h in rbA24_rxAddBibResource.hits(in: src.masked) {
                let n = h.groups[1].trimmingCharacters(in: .whitespaces)
                if !n.isEmpty, !n.contains("\\"), !n.contains("://") { names.append((n, idx.line(at: h.location))) }
            }
            for (n, ln) in names where !rbA24_isFile(draftFolder.appendingPathComponent(n)) {
                out.append(Diagnostic(severity: .warning, category: .bibliography, file: src.rel, line: ln,
                                      message: "The bibliography file “\(n)” is not in this draft.",
                                      help: "Check the name, or regenerate refs.bib from the library.",
                                      code: "missing-file:\(n)"))
            }
        }

        // Citations (warnings)
        var known = libraryCitationKeys ?? []
        var haveKeySource = libraryCitationKeys != nil
        for url in rbA24_files(in: draftFolder, ext: "bib", skipFolder: outputFolder) {
            haveKeySource = true
            for h in rbA24_rxBibEntry.hits(in: rbA24_readText(url)) { known.insert(h.groups[1]) }
        }
        for src in sources { for h in rbA24_rxBibitem.hits(in: src.masked) { known.insert(h.groups[1].trimmingCharacters(in: .whitespaces)) } }
        if haveKeySource {
            for src in sources {
                let idx = rbA24_LineIndex(src.masked)
                for h in rbA24_rxCite.hits(in: src.masked) {
                    let cmd = h.groups[1].lowercased()
                    if cmd.contains("style") || cmd.contains("format") || cmd.hasPrefix("declare") { continue }
                    for k in h.groups[2].split(separator: ",") {
                        let key = String(k).trimmingCharacters(in: .whitespacesAndNewlines)
                        if key.isEmpty || key == "*" || key.contains("\\") || key.contains("#") { continue }
                        if !known.contains(key) {
                            out.append(Diagnostic(severity: .warning, category: .citation, file: src.rel, line: idx.line(at: h.location),
                                                  message: "Citation “\(key)” is not in the library.",
                                                  help: "Add the paper to the library, or fix the key.",
                                                  code: "cite-missing:\(key)"))
                        }
                    }
                }
            }
        }

        // Cross-references (warnings)
        var labels = Set<String>()
        for url in rbA24_files(in: draftFolder, ext: "tex", skipFolder: outputFolder) {
            let masked = rbA24_maskedSource(rbA24_readText(url))
            for h in rbA24_rxLabel.hits(in: masked) { labels.insert(h.groups[1].trimmingCharacters(in: .whitespaces)) }
        }
        for url in rbA24_files(in: draftFolder.appendingPathComponent(outputFolder, isDirectory: true), ext: "aux", skipFolder: nil) {
            for h in rbA24_rxNewLabel.hits(in: rbA24_readText(url)) { labels.insert(h.groups[1]) }
        }
        for src in sources {
            let idx = rbA24_LineIndex(src.masked)
            for h in rbA24_rxRef.hits(in: src.masked) {
                for k in h.groups[1].split(separator: ",") {
                    let key = String(k).trimmingCharacters(in: .whitespacesAndNewlines)
                    if key.isEmpty || key.contains("\\") || key.contains("#") { continue }
                    if !labels.contains(key) {
                        out.append(Diagnostic(severity: .warning, category: .reference, file: src.rel, line: idx.line(at: h.location),
                                              message: "Reference “\(key)” has no matching \\label.",
                                              help: "Check the spelling of the label, or add \\label{\(key)} next to the figure, table or section.",
                                              code: "ref-missing:\(key)"))
                    }
                }
            }
        }
        return mergeDiagnostics([out])
    }

    /// Asks kpsewhich which classes, packages and styles are missing.
    static func packageChecks(draftFolder: URL, mainFile: String, installation: Installation) async -> [Diagnostic] {
        guard let kpse = installation.kpsewhich else { return [] }
        let main = rbA24_normalizePath(mainFile, draft: nil)
        let sources = rbA24_loadSources(draft: draftFolder, mainFile: main)
        struct Need { var fileName: String; var kind: MissingResource.Kind; var name: String; var rel: String; var line: Int }
        var needs: [Need] = []
        var seen = Set<String>()
        func add(_ name: String, ext: String, kind: MissingResource.Kind, rel: String, line: Int) {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if n.isEmpty || n.contains("\\") || n.contains("#") { return }
            let fileName = n.lowercased().hasSuffix("." + ext) ? n : n + "." + ext
            if !seen.insert(fileName.lowercased()).inserted { return }
            if rbA24_isFile(draftFolder.appendingPathComponent(fileName)) { return }
            needs.append(Need(fileName: fileName, kind: kind, name: n, rel: rel, line: line))
        }
        for src in sources {
            let idx = rbA24_LineIndex(src.masked)
            for h in rbA24_rxDocClass.hits(in: src.masked) { add(h.groups[1], ext: "cls", kind: .documentClass, rel: src.rel, line: idx.line(at: h.location)) }
            for h in rbA24_rxUsePackage.hits(in: src.masked) {
                let ln = idx.line(at: h.location)
                for p in h.groups[1].split(separator: ",") { add(String(p), ext: "sty", kind: .package, rel: src.rel, line: ln) }
            }
            for h in rbA24_rxBibStyle.hits(in: src.masked) { add(h.groups[1], ext: "bst", kind: .bibStyle, rel: src.rel, line: idx.line(at: h.location)) }
        }
        if needs.isEmpty { return [] }

        let env = buildEnvironment(texFolder: installation.texFolder ?? kpse.deletingLastPathComponent())
        let outcome = await runCommand(executable: kpse, arguments: needs.map { $0.fileName }, workingDirectory: draftFolder,
                                       environment: env, timeout: 20)
        if outcome.launchError != nil || outcome.timedOut { return [] }
        var found = Set<String>()
        for l in outcome.output.components(separatedBy: "\n") {
            let t = l.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("/") || t.hasPrefix(".") { found.insert((t as NSString).lastPathComponent.lowercased()) }
        }
        var out: [Diagnostic] = []
        for n in needs where !found.contains((n.fileName as NSString).lastPathComponent.lowercased()) {
            out.append(rbA24_missingDiagnostic(kind: n.kind, name: n.name, file: n.rel, line: n.line))
        }
        return out
    }
}

// MARK: - Private helpers (all prefixed rbA24_)

nonisolated fileprivate struct rbA24_Hit {
    var groups: [String]
    var location: Int   // UTF-16 offset
}

nonisolated fileprivate struct rbA24_Regex {
    let re: NSRegularExpression

    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        // Patterns are constants checked by the unit tests.
        self.re = try! NSRegularExpression(pattern: pattern, options: options)
    }

    private func groups(_ m: NSTextCheckingResult, _ ns: NSString) -> [String] {
        var out: [String] = []
        for k in 0..<m.numberOfRanges {
            let r = m.range(at: k)
            out.append(r.location == NSNotFound ? "" : ns.substring(with: r))
        }
        return out
    }

    func captures(_ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        return groups(m, ns)
    }

    func hits(in s: String) -> [rbA24_Hit] {
        let ns = s as NSString
        return re.matches(in: s, options: [], range: NSRange(location: 0, length: ns.length)).map {
            rbA24_Hit(groups: groups($0, ns), location: $0.range.location)
        }
    }
}

nonisolated fileprivate let rbA24_rxFileLine = rbA24_Regex(#"^(.+?\.(?:tex|sty|cls|clo|def|cfg|ltx|bbl|aux|bib|fd|ldf|cnf|lbx|bbx|cbx|dtx|code|tikz|toc|lof|lot|out|mkii|mkiv|lua)):(\d+):[ \t]?(.*)$"#)
nonisolated fileprivate let rbA24_rxLineCtx = rbA24_Regex(#"^l\.(\d+)[ \t]?(.*)$"#)
nonisolated fileprivate let rbA24_rxWarn = rbA24_Regex(#"^(LaTeX Font|LaTeX|Package \S+|Class \S+|Module \S+) Warning: (.*)$"#)
nonisolated fileprivate let rbA24_rxPdfTeXWarn = rbA24_Regex(#"^(pdfTeX|LuaTeX|XeTeX) warning(?: \([^)]*\))?: (.*)$"#)
nonisolated fileprivate let rbA24_rxCont = rbA24_Regex(#"^\((\S+)\)\s+(.*)$"#)
nonisolated fileprivate let rbA24_rxBox = rbA24_Regex(#"^((?:Overfull|Underfull) \\[hv]box .*)$"#)
nonisolated fileprivate let rbA24_rxLines = rbA24_Regex(#"lines? (\d+)"#)
nonisolated fileprivate let rbA24_rxInputLine = rbA24_Regex(#"on input line (\d+)"#)
nonisolated fileprivate let rbA24_rxMissingFile = rbA24_Regex(#"File [`'‘]([^'’]+)['’] not found"#)
nonisolated fileprivate let rbA24_rxCantFind = rbA24_Regex(#"I can[\x27’]t find file [`\x27\x22‘]?([^\x27\x22’`]+)"#)
nonisolated fileprivate let rbA24_rxFontMissing = rbA24_Regex(#"The font [\x22“]([^\x22”]+)[\x22”] cannot be found"#)
nonisolated fileprivate let rbA24_rxCiteUndef = rbA24_Regex(#"Citation [`'‘](.+?)['’] on page \S+ undefined"#)
nonisolated fileprivate let rbA24_rxRefUndef = rbA24_Regex(#"Reference [`'‘](.+?)['’] on page \S+ undefined"#)
nonisolated fileprivate let rbA24_rxOutputWritten = rbA24_Regex(#"Output written on (.+?) \((\d+) pages?"#)
nonisolated fileprivate let rbA24_rxTectonicErr = rbA24_Regex(#"^error: (?:(.+?\.\w+):(\d+): )?(.*)$"#)
nonisolated fileprivate let rbA24_rxTectonicWarn = rbA24_Regex(#"^warning: (.*)$"#)
nonisolated fileprivate let rbA24_rxMaxRuns = rbA24_Regex(#"Latexmk: Maximum runs of (\S+) reached"#)
nonisolated fileprivate let rbA24_rxBlgOpenDB = rbA24_Regex(#"I couldn't open database file (.+)$"#)
nonisolated fileprivate let rbA24_rxBlgStyle = rbA24_Regex(#"I couldn't open style file (.+)$"#)
nonisolated fileprivate let rbA24_rxBlgNoEntry = rbA24_Regex(#"I didn't find a database entry for [\x22\x27](.+?)[\x22\x27]"#)
nonisolated fileprivate let rbA24_rxBlgLine = rbA24_Regex(#"^(.+?)---line (\d+) of file (.+)$"#)
nonisolated fileprivate let rbA24_rxBiber = rbA24_Regex(#"(ERROR|WARN) - (.*)$"#)

nonisolated fileprivate let rbA24_rxUsePackage = rbA24_Regex(#"\\(?:usepackage|RequirePackage)\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}"#)
nonisolated fileprivate let rbA24_rxDocClass = rbA24_Regex(#"\\documentclass\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}"#)
nonisolated fileprivate let rbA24_rxBibStyle = rbA24_Regex(#"\\bibliographystyle\s*\{([^}]*)\}"#)
nonisolated fileprivate let rbA24_rxBibliography = rbA24_Regex(#"\\bibliography\s*\{([^}]*)\}"#)
nonisolated fileprivate let rbA24_rxAddBibResource = rbA24_Regex(#"\\addbibresource\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}"#)
nonisolated fileprivate let rbA24_rxInput = rbA24_Regex(#"\\(?:input|include|subfile)\s*\{([^}]*)\}"#)
nonisolated fileprivate let rbA24_rxBeginEnd = rbA24_Regex(#"\\(begin|end)\s*\{([^}]*)\}"#)
nonisolated fileprivate let rbA24_rxGraphic = rbA24_Regex(#"\\includegraphics\*?\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}"#)
nonisolated fileprivate let rbA24_rxGraphicsPath = rbA24_Regex(#"\\graphicspath\s*\{((?:\s*\{[^}]*\}\s*)+)\}"#)
nonisolated fileprivate let rbA24_rxBraceGroup = rbA24_Regex(#"\{([^}]*)\}"#)
nonisolated fileprivate let rbA24_rxCite = rbA24_Regex(#"\\([A-Za-z]*cite[A-Za-z]*)\*?\s*(?:\[[^\]]*\]\s*){0,2}\{([^}]*)\}"#)
nonisolated fileprivate let rbA24_rxRef = rbA24_Regex(#"\\(?:ref|eqref|pageref|autoref|nameref|cref|Cref|cpageref|Cpageref|vref|Vref|labelcref|subref|autopageref)\*?\s*\{([^}]*)\}"#)
nonisolated fileprivate let rbA24_rxLabel = rbA24_Regex(#"\\label\s*\{([^}]*)\}"#)
nonisolated fileprivate let rbA24_rxNewLabel = rbA24_Regex(#"\\newlabel\{([^}]*)\}"#)
nonisolated fileprivate let rbA24_rxBibEntry = rbA24_Regex(#"@[A-Za-z]+\s*[\{\(]\s*([^,\s\}]+)\s*,"#)
nonisolated fileprivate let rbA24_rxBibitem = rbA24_Regex(#"\\bibitem\s*(?:\[[^\]]*\])?\s*\{([^}]*)\}"#)

// MARK: Paths and files

nonisolated fileprivate func rbA24_normalizePath(_ path: String, draft: URL?) -> String {
    var p = path.trimmingCharacters(in: .whitespaces)
    while p.hasPrefix("./") { p = String(p.dropFirst(2)) }
    if let d = draft, p.hasPrefix("/") {
        for base in [d.path, d.resolvingSymlinksInPath().path] where p.hasPrefix(base + "/") {
            return String(p.dropFirst(base.count + 1))
        }
    }
    return p
}

nonisolated fileprivate func rbA24_relativePath(of url: URL, in base: URL) -> String {
    let a = url.resolvingSymlinksInPath().path
    let b = base.resolvingSymlinksInPath().path
    return a.hasPrefix(b + "/") ? String(a.dropFirst(b.count + 1)) : a
}

nonisolated fileprivate func rbA24_isInside(_ child: URL, _ parent: URL) -> Bool {
    let c = child.resolvingSymlinksInPath().path
    let p = parent.resolvingSymlinksInPath().path
    return c.hasPrefix(p + "/") && c != p
}

/// A relative path that is not in a hidden folder and is not a generated file.
nonisolated fileprivate func rbA24_isEditableSource(_ path: String) -> Bool {
    if path.isEmpty || path.hasPrefix("/") || path.hasPrefix("~") { return false }
    if path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false }
    let ext = (path as NSString).pathExtension.lowercased()
    return !["aux", "out", "toc", "lof", "lot", "bbl", "blg", "log", "nav", "snm", "fls", "xdv", "bcf"].contains(ext)
}

nonisolated fileprivate func rbA24_looksLikeTeXFile(_ t: String) -> Bool {
    if t.isEmpty { return false }
    let ext = (t as NSString).pathExtension.lowercased()
    return ["tex", "sty", "cls", "clo", "def", "cfg", "fd", "ldf", "bbl", "aux", "out", "toc", "lof", "lot", "cnf",
            "lbx", "bbx", "cbx", "dtx", "code", "tikz", "ltx", "mkii", "mkiv", "lua", "bib"].contains(ext)
}

nonisolated fileprivate func rbA24_isFile(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
}

nonisolated fileprivate func rbA24_readText(_ url: URL) -> String {
    guard let d = try? Data(contentsOf: url) else { return "" }
    return String(decoding: d, as: UTF8.self)
}

nonisolated fileprivate func rbA24_files(in folder: URL, ext: String, skipFolder: String?) -> [URL] {
    let fm = FileManager.default
    guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
    var out: [URL] = []
    let skip = skipFolder.map { folder.appendingPathComponent($0, isDirectory: true).resolvingSymlinksInPath().path }
    while let u = en.nextObject() as? URL {
        let isDir = (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        if isDir {
            if let s = skip, u.resolvingSymlinksInPath().path == s { en.skipDescendants() }
            continue
        }
        if u.pathExtension.lowercased() == ext { out.append(u) }
        if out.count > 500 { break }
    }
    return out
}

nonisolated fileprivate func rbA24_versionedTeXFolders(root: String, direct: Bool = false) -> [String] {
    let fm = FileManager.default
    var out: [String] = []
    if direct {
        let bin = root + "/bin"
        for a in ((try? fm.contentsOfDirectory(atPath: bin)) ?? []).sorted() { out.append(bin + "/" + a) }
        return out
    }
    for year in ((try? fm.contentsOfDirectory(atPath: root)) ?? []).sorted(by: >) {
        let bin = root + "/" + year + "/bin"
        for a in ((try? fm.contentsOfDirectory(atPath: bin)) ?? []).sorted() { out.append(bin + "/" + a) }
    }
    return out
}

nonisolated fileprivate func rbA24_inputLine(in message: String) -> Int? {
    rbA24_rxInputLine.captures(message).flatMap { Int($0[1]) }
}

// MARK: Diagnostics builders

nonisolated fileprivate func rbA24_missingDiagnostic(kind: LatexCompiler.MissingResource.Kind, name: String,
                                         file: String?, line: Int?) -> LatexCompiler.Diagnostic {
    let res = LatexCompiler.missingResource(kind: kind, name: name)
    let title: String
    let code: String
    let category: LatexCompiler.Category
    switch kind {
    case .package: title = "The package “\(res.name)” is not installed."; code = "missing-package:\(res.name.lowercased())"; category = .package
    case .documentClass: title = "The document class “\(res.name)” is not installed."; code = "missing-class:\(res.name.lowercased())"; category = .package
    case .bibStyle: title = "The bibliography style “\(res.name)” was not found."; code = "missing-bst:\(res.name.lowercased())"; category = .bibliography
    case .font: title = "The font “\(res.name)” was not found."; code = "missing-font:\(res.name.lowercased())"; category = .font
    case .file: title = "The file “\(name)” was not found."; code = "missing-file:\(name)"; category = .file
    }
    return LatexCompiler.Diagnostic(severity: .error, category: category, file: file, line: line, message: title,
                                    help: res.explanation, code: code, missing: res)
}

/// Separates the text before and after the point where TeX stopped.
nonisolated fileprivate let rbA24_hereMarker = " ⟨here⟩ "

nonisolated fileprivate let rbA24_imageExts: Set<String> = ["png", "jpg", "jpeg", "pdf", "eps", "gif", "svg"]

nonisolated fileprivate func rbA24_makeError(message rawMessage: String, file: String?, line: Int?, context: String?) -> LatexCompiler.Diagnostic {
    var message = rawMessage
    if message.hasPrefix("LaTeX Error: ") { message = String(message.dropFirst("LaTeX Error: ".count)) }

    // Missing class / package / file (L-10)
    var missingName: String? = nil
    if let c = rbA24_rxMissingFile.captures(rawMessage) { missingName = c[1] }
    else if let c = rbA24_rxCantFind.captures(rawMessage) { missingName = c[1] }
    if let name = missingName {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "sty": return rbA24_missingDiagnostic(kind: .package, name: name, file: file, line: line)
        case "cls": return rbA24_missingDiagnostic(kind: .documentClass, name: name, file: file, line: line)
        case "bst": return rbA24_missingDiagnostic(kind: .bibStyle, name: name, file: file, line: line)
        default:
            var d = rbA24_missingDiagnostic(kind: .file, name: name, file: file, line: line)
            if rbA24_imageExts.contains(ext) {
                d.message = "The image “\(name)” was not found."
                d.help = "Put the file in the draft’s figures folder, or fix the path in \\includegraphics."
            } else if ext == "tex" || ext.isEmpty {
                d.message = "The included file “\(name)” was not found."
                d.help = "Check the name in \\input or \\include. The path starts at the draft folder."
            }
            return d
        }
    }
    if let c = rbA24_rxFontMissing.captures(rawMessage) {
        return rbA24_missingDiagnostic(kind: .font, name: c[1], file: file, line: line)
    }

    var category: LatexCompiler.Category = .syntax
    var help = rbA24_helpFor(message)
    if message.hasPrefix("Undefined control sequence") {
        if let ctx = context,
           let head = ctx.components(separatedBy: rbA24_hereMarker).first,
           let m = try? NSRegularExpression(pattern: #"(\\[A-Za-z@]+)\s*$"#),
           let r = m.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)) {
            let cs = (head as NSString).substring(with: r.range(at: 1))
            message = "Undefined command \(cs)"
        }
    }
    if message.contains("can't write on file") || message.contains("can’t write on file") {
        category = .system
        help = "The output folder is not writable, or the disk is full. Check free space and folder permissions."
    }
    return LatexCompiler.Diagnostic(severity: .error, category: category, file: file, line: line,
                                    message: message, context: context, help: help)
}

nonisolated fileprivate func rbA24_helpFor(_ message: String) -> String? {
    let table: [(String, String)] = [
        ("Undefined control sequence", "Check the spelling of the command, or load the package that defines it with \\usepackage{…}."),
        ("Missing $ inserted", "Math symbols such as _ and ^ need to be inside $…$. Escape a literal underscore as \\_."),
        ("Misplaced alignment tab", "A bare & is only allowed in tables. Write \\& for a literal ampersand."),
        ("File ended while scanning", "A brace or environment is not closed. Look above this line for a missing } or \\end."),
        ("Runaway argument", "A brace is not closed. Look for a missing } above this line."),
        ("Too many }", "There is an extra closing brace. Remove it, or add the matching {."),
        ("Extra }, or forgotten", "There is an extra } or a missing $ before it."),
        ("Environment", "Check the environment name, or load the package that provides it."),
        ("Paragraph ended before", "A blank line appeared inside a command argument. Remove the empty line."),
        ("TeX capacity exceeded", "A macro probably calls itself forever. Look at the most recent \\newcommand or \\def."),
        ("Unknown graphics extension", "Use PDF, PNG or JPG images. Convert SVG files to PDF first."),
        ("Option clash", "A package was loaded twice with different options. Load it once, with all options."),
    ]
    for (needle, text) in table where message.contains(needle) { return text }
    return nil
}

nonisolated fileprivate func rbA24_makeWarning(source: String, text rawText: String, file: String?) -> LatexCompiler.Diagnostic? {
    let text = rawText.trimmingCharacters(in: .whitespaces)
    if text.hasPrefix("There were undefined") || text.contains("may have changed") || text.hasPrefix("Please (re)run") { return nil }
    let ln = rbA24_inputLine(in: text)
    if let c = rbA24_rxCiteUndef.captures(text) {
        return LatexCompiler.Diagnostic(severity: .warning, category: .citation, file: file, line: ln,
                                        message: "Citation “\(c[1])” is not defined.",
                                        help: "Add the paper to the library, or fix the key. A citation also shows as undefined until the bibliography has been built once.",
                                        code: "cite-missing:\(c[1])")
    }
    if let c = rbA24_rxRefUndef.captures(text) {
        return LatexCompiler.Diagnostic(severity: .warning, category: .reference, file: file, line: ln,
                                        message: "Reference “\(c[1])” is not defined.",
                                        help: "Check the label name. A new label only resolves after a second run.",
                                        code: "ref-missing:\(c[1])")
    }
    var cat: LatexCompiler.Category = .other
    if source == "LaTeX Font" { cat = .font }
    var shown = text
    if source.hasPrefix("Package ") || source.hasPrefix("Class ") || source.hasPrefix("Module ") {
        shown = (source.split(separator: " ").last.map(String.init) ?? source) + ": " + text
    }
    return LatexCompiler.Diagnostic(severity: .warning, category: cat, file: file, line: ln, message: shown)
}

// MARK: Source masking and structure checks

nonisolated fileprivate struct rbA24_Source {
    var rel: String
    var masked: String
}

nonisolated fileprivate struct rbA24_LineIndex {
    private var starts: [Int] = [0]

    init(_ text: String) {
        let ns = text as NSString
        let len = ns.length
        var idx = 0
        while idx < len {
            if ns.character(at: idx) == 10 { starts.append(idx + 1) }
            idx += 1
        }
    }

    func line(at offset: Int) -> Int {
        var lo = 0
        var hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo + 1
    }
}

nonisolated fileprivate let rbA24_verbatimEnvs: Set<String> = ["verbatim", "verbatim*", "Verbatim", "Verbatim*", "lstlisting", "minted", "comment", "BVerbatim", "alltt"]

nonisolated fileprivate func rbA24_defSpec(_ name: String) -> (groups: Int, tex: Bool)? {
    switch name {
    case "def", "gdef", "edef", "xdef": return (1, true)
    case "AtBeginDocument", "AtEndDocument": return (1, false)
    case "newcommand", "renewcommand", "providecommand", "DeclareRobustCommand", "DeclareMathOperator",
         "NewEnviron", "newtcolorbox", "renewtcolorbox": return (2, false)
    case "newenvironment", "renewenvironment", "NewDocumentCommand", "RenewDocumentCommand",
         "ProvideDocumentCommand", "DeclareDocumentCommand": return (3, false)
    case "NewDocumentEnvironment", "RenewDocumentEnvironment", "ProvideDocumentEnvironment",
         "DeclareDocumentEnvironment": return (4, false)
    default: return nil
    }
}

/// Same text, but comments, \verb, verbatim blocks, escaped braces and macro definitions are
/// blanked out (newlines kept), so line numbers stay right and pairing checks do not misfire.
nonisolated fileprivate func rbA24_maskedSource(_ text: String) -> String {
    let b = Array(text.utf8)
    let n = b.count
    var out = b

    func blank(_ from: Int, _ to: Int) {
        var k = from
        let end = min(to, n)
        while k < end {
            if out[k] != 10 { out[k] = 32 }
            k += 1
        }
    }
    func isLetter(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 64 }
    func skipSpaces(_ p: Int) -> Int {
        var q = p
        while q < n, b[q] == 32 || b[q] == 9 || b[q] == 10 || b[q] == 13 { q += 1 }
        return q
    }
    func groupEnd(_ start: Int, open: UInt8, close: UInt8) -> Int? {
        var depth = 0
        var q = start
        while q < n {
            let c = b[q]
            if c == 92 { q += 2; continue }
            if c == 37 {
                while q < n && b[q] != 10 { q += 1 }
                continue
            }
            if c == open { depth += 1 }
            else if c == close {
                depth -= 1
                if depth == 0 { return q + 1 }
            }
            q += 1
        }
        return nil
    }
    func find(_ needle: [UInt8], from: Int) -> Int? {
        if needle.isEmpty || from >= n { return nil }
        var k = from
        while k + needle.count <= n {
            if b[k] == needle[0] {
                var m = 1
                while m < needle.count && b[k + m] == needle[m] { m += 1 }
                if m == needle.count { return k }
            }
            k += 1
        }
        return nil
    }

    var i = 0
    while i < n {
        let c = b[i]
        if c == 92 {
            var j = i + 1
            if j < n && isLetter(b[j]) {
                while j < n && isLetter(b[j]) { j += 1 }
            } else {
                j = min(j + 1, n)
            }
            let name = String(decoding: b[(i + 1)..<j], as: UTF8.self)

            // \{ \} \% are not braces / comments
            if j == i + 2, b[i + 1] == 123 || b[i + 1] == 125 || b[i + 1] == 37 {
                blank(i, j); i = j; continue
            }
            if name == "verb" {
                var k = j
                if k < n && b[k] == 42 { k += 1 }
                if k < n {
                    let d = b[k]
                    var e = k + 1
                    while e < n && b[e] != d && b[e] != 10 { e += 1 }
                    let endIdx = (e < n && b[e] == d) ? e + 1 : e
                    blank(i, endIdx); i = endIdx; continue
                }
            }
            if name == "begin" {
                let p = skipSpaces(j)
                if p < n, b[p] == 123, let ge = groupEnd(p, open: 123, close: 125) {
                    let env = String(decoding: b[(p + 1)..<(ge - 1)], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                    if rbA24_verbatimEnvs.contains(env) {
                        let endTok = Array("\\end{\(env)}".utf8)
                        if let r = find(endTok, from: ge) {
                            blank(i, r + endTok.count); i = r + endTok.count
                        } else {
                            blank(i, n); i = n
                        }
                        continue
                    }
                }
            }
            if let spec = rbA24_defSpec(name) {
                if spec.tex {
                    var q = j
                    var guardCount = 0
                    while q < n && b[q] != 123 && guardCount < 200 { q += 1; guardCount += 1 }
                    if q < n, b[q] == 123, let ge = groupEnd(q, open: 123, close: 125) {
                        blank(i, ge); i = ge; continue
                    }
                } else {
                    var q = j
                    if q < n && b[q] == 42 { q += 1 }
                    var groups = 0
                    var ok = true
                    while groups < spec.groups {
                        q = skipSpaces(q)
                        if q >= n { break }
                        if b[q] == 123 {
                            guard let ge = groupEnd(q, open: 123, close: 125) else { ok = false; break }
                            q = ge; groups += 1
                        } else if b[q] == 91 {
                            guard let ge = groupEnd(q, open: 91, close: 93) else { ok = false; break }
                            q = ge
                        } else if b[q] == 92 && groups == 0 {
                            var r = q + 1
                            if r < n && isLetter(b[r]) {
                                while r < n && isLetter(b[r]) { r += 1 }
                            } else {
                                r = min(r + 1, n)
                            }
                            q = r; groups += 1
                        } else {
                            break
                        }
                    }
                    if ok && groups > 0 { blank(i, q); i = q; continue }
                }
            }
            i = j
            continue
        }
        if c == 37 {
            var e = i
            while e < n && b[e] != 10 { e += 1 }
            blank(i, e); i = e; continue
        }
        i += 1
    }
    return String(decoding: out, as: UTF8.self)
}

/// The main file plus every file it \input / \include / \subfile reaches.
nonisolated fileprivate func rbA24_loadSources(draft: URL, mainFile: String) -> [rbA24_Source] {
    var result: [rbA24_Source] = []
    var queue = [rbA24_normalizePath(mainFile, draft: nil)]
    var seen = Set<String>()
    while !queue.isEmpty && result.count < 200 {
        let rel = queue.removeFirst()
        if !seen.insert(rel).inserted { continue }
        let url = draft.appendingPathComponent(rel)
        guard rbA24_isFile(url), let data = try? Data(contentsOf: url) else { continue }
        let masked = rbA24_maskedSource(String(decoding: data, as: UTF8.self))
        result.append(rbA24_Source(rel: rel, masked: masked))
        for h in rbA24_rxInput.hits(in: masked) {
            for part in h.groups[1].split(separator: ",") {
                let p = rbA24_normalizePath(String(part), draft: nil)
                if p.isEmpty || p.contains("\\") || p.contains("#") { continue }
                let hasExt = !(p as NSString).pathExtension.isEmpty
                let candidates = hasExt ? [p, p + ".tex"] : [p + ".tex", p]
                if let f = candidates.first(where: { rbA24_isFile(draft.appendingPathComponent($0)) }) { queue.append(f) }
            }
        }
    }
    return result
}

nonisolated fileprivate func rbA24_graphicExists(_ name: String, dirs: [String], draft: URL) -> Bool {
    let exts = ["", ".pdf", ".png", ".jpg", ".jpeg", ".eps", ".PDF", ".PNG", ".JPG", ".JPEG", ".EPS"]
    for d in [""] + dirs {
        for e in exts where rbA24_isFile(draft.appendingPathComponent(d + name + e)) { return true }
    }
    return false
}

nonisolated fileprivate func rbA24_structureDiagnostics(file rel: String, masked: String, isMain: Bool) -> [LatexCompiler.Diagnostic] {
    var out: [LatexCompiler.Diagnostic] = []
    let idx = rbA24_LineIndex(masked)

    // \begin / \end pairing, with both line numbers
    var stack: [(name: String, line: Int)] = []
    for h in rbA24_rxBeginEnd.hits(in: masked) {
        let kind = h.groups[1]
        let name = h.groups[2].trimmingCharacters(in: .whitespaces)
        let ln = idx.line(at: h.location)
        if kind == "begin" {
            stack.append((name, ln))
            continue
        }
        if let top = stack.last, top.name == name {
            stack.removeLast()
        } else if let pos = stack.lastIndex(where: { $0.name == name }) {
            var k = stack.count - 1
            while k > pos {
                out.append(LatexCompiler.Diagnostic(severity: .error, category: .structure, file: rel, line: stack[k].line,
                    message: "\\begin{\(stack[k].name)} on line \(stack[k].line) is not closed before \\end{\(name)} on line \(ln).",
                    help: "Add \\end{\(stack[k].name)} where that environment should finish.", code: "unclosed:\(rel):\(stack[k].line)"))
                k -= 1
            }
            stack.removeSubrange(pos..<stack.count)
        } else if let top = stack.last {
            out.append(LatexCompiler.Diagnostic(severity: .error, category: .structure, file: rel, line: ln,
                message: "\\end{\(name)} on line \(ln) does not match \\begin{\(top.name)} on line \(top.line).",
                help: "Make the two names the same.", code: "mismatch:\(rel):\(ln)"))
            stack.removeLast()
        } else {
            out.append(LatexCompiler.Diagnostic(severity: .error, category: .structure, file: rel, line: ln,
                message: "\\end{\(name)} on line \(ln) has no matching \\begin.",
                help: "Remove it, or add \\begin{\(name)} above.", code: "extra-end:\(rel):\(ln)"))
        }
    }
    for entry in stack {
        if entry.name == "document" && isMain {
            out.append(LatexCompiler.Diagnostic(severity: .error, category: .structure, file: rel, line: entry.line,
                message: "\\end{document} is missing: the file ends without it.",
                help: "Add \\end{document} as the last line.", code: "missing-end-document"))
        } else {
            out.append(LatexCompiler.Diagnostic(severity: .error, category: .structure, file: rel, line: entry.line,
                message: "\\begin{\(entry.name)} on line \(entry.line) is never closed.",
                help: "Add \\end{\(entry.name)} where that environment should finish.", code: "unclosed:\(rel):\(entry.line)"))
        }
    }

    // Braces
    let bytes = Array(masked.utf8)
    var opens: [Int] = []
    var line = 1
    var extras = 0
    var k = 0
    while k < bytes.count {
        let c = bytes[k]
        if c == 10 {
            line += 1
        } else if c == 92 {
            if k + 1 < bytes.count, bytes[k + 1] == 10 { line += 1 }
            k += 2
            continue
        } else if c == 123 {
            opens.append(line)
        } else if c == 125 {
            if opens.isEmpty {
                if extras < 3 {
                    out.append(LatexCompiler.Diagnostic(severity: .error, category: .syntax, file: rel, line: line,
                        message: "The } on line \(line) has no matching {.",
                        help: "Remove the extra } or add the missing {.", code: "extra-brace:\(rel):\(line)"))
                }
                extras += 1
            } else {
                opens.removeLast()
            }
        }
        k += 1
    }
    for l in opens.prefix(3) {
        out.append(LatexCompiler.Diagnostic(severity: .error, category: .syntax, file: rel, line: l,
            message: "The { on line \(l) is never closed.",
            help: "Add the missing } where the braces should end.", code: "open-brace:\(rel):\(l)"))
    }
    return out
}

// MARK: Name tables for missing-package help

nonisolated fileprivate func rbA24_table(_ pairs: [(String, String)]) -> [String: String] {
    Dictionary(pairs, uniquingKeysWith: { first, _ in first })
}

nonisolated fileprivate let rbA24_packageTable: [String: String] = rbA24_table([
    ("algorithm", "algorithms"), ("algorithmic", "algorithms"), ("algorithm2e", "algorithm2e"),
    ("algpseudocode", "algorithmicx"), ("algorithmicx", "algorithmicx"), ("amsmath", "amsmath"),
    ("amsthm", "amscls"), ("amssymb", "amsfonts"), ("amsfonts", "amsfonts"),
    ("array", "tools"), ("tabularx", "tools"), ("longtable", "tools"), ("bm", "tools"), ("multicol", "tools"),
    ("varioref", "tools"), ("xspace", "tools"), ("calc", "tools"), ("afterpage", "tools"), ("dcolumn", "tools"),
    ("hhline", "tools"), ("verbatim", "tools"), ("enumerate", "tools"),
    ("graphicx", "graphics"), ("graphics", "graphics"), ("color", "graphics"), ("epsfig", "graphics"), ("lscape", "graphics"),
    ("xcolor", "xcolor"), ("hyperref", "hyperref"), ("url", "url"), ("natbib", "natbib"), ("biblatex", "biblatex"),
    ("cleveref", "cleveref"), ("booktabs", "booktabs"), ("caption", "caption"), ("subcaption", "caption"),
    ("subfig", "subfig"), ("subfigure", "subfigure"), ("siunitx", "siunitx"), ("tikz", "pgf"), ("pgf", "pgf"),
    ("pgfplots", "pgfplots"), ("microtype", "microtype"), ("listings", "listings"), ("minted", "minted"),
    ("enumitem", "enumitem"), ("multirow", "multirow"), ("titlesec", "titlesec"), ("fancyhdr", "fancyhdr"),
    ("geometry", "geometry"), ("todonotes", "todonotes"), ("thmtools", "thmtools"), ("mathtools", "mathtools"),
    ("tcolorbox", "tcolorbox"), ("lmodern", "lm"), ("float", "float"), ("wrapfig", "wrapfig"), ("setspace", "setspace"),
    ("soul", "soul"), ("ulem", "ulem"), ("cite", "cite"), ("appendix", "appendix"), ("changepage", "changepage"),
    ("framed", "framed"), ("xparse", "l3packages"), ("fontspec", "fontspec"), ("unicode-math", "unicode-math"),
    ("babel", "babel"), ("polyglossia", "polyglossia"), ("csquotes", "csquotes"), ("etoolbox", "etoolbox"),
    ("lipsum", "lipsum"), ("pdfpages", "pdfpages"), ("balance", "preprint"), ("authblk", "preprint"),
    ("stfloats", "sttools"), ("bbm", "bbm-macros"), ("dsfont", "doublestroke"), ("units", "units"), ("nicefrac", "units"),
    ("placeins", "placeins"), ("physics", "physics"), ("mhchem", "mhchem"), ("cancel", "cancel"), ("comment", "comment"),
    ("pifont", "psnfss"), ("upquote", "upquote"), ("ragged2e", "ragged2e"), ("threeparttable", "threeparttable"),
    ("makecell", "makecell"), ("colortbl", "colortbl"), ("pdflscape", "pdflscape"), ("adjustbox", "adjustbox"),
    ("glossaries", "glossaries"), ("nomencl", "nomencl"), ("footmisc", "footmisc"), ("orcidlink", "orcidlink"),
])

nonisolated fileprivate let rbA24_classTable: [String: String] = rbA24_table([
    ("ieeetran", "IEEEtran"), ("acmart", "acmart"), ("elsarticle", "elsarticle"), ("llncs", "llncs"),
    ("revtex4-2", "revtex"), ("revtex4-1", "revtex"), ("beamer", "beamer"), ("memoir", "memoir"),
    ("amsart", "amscls"), ("amsbook", "amscls"), ("amsproc", "amscls"),
    ("scrartcl", "koma-script"), ("scrreprt", "koma-script"), ("scrbook", "koma-script"),
])

/// Classes that come from the publisher's own template, not from TeX Live.
nonisolated fileprivate let rbA24_manualClasses: Set<String> = ["svjour3", "svjour", "sn-jnl", "ieeeconf"]

nonisolated fileprivate let rbA24_bstTable: [String: String] = rbA24_table([
    ("ieeetran", "IEEEtran"), ("plainnat", "natbib"), ("abbrvnat", "natbib"), ("unsrtnat", "natbib"),
    ("acm", "acmart"), ("acmart", "acmart"), ("elsarticle-num", "elsarticle"), ("elsarticle-harv", "elsarticle"),
    ("splncs04", "llncs"), ("apalike", "base"),
])

// MARK: Running processes

nonisolated fileprivate final class rbA24_OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count < limit { data.append(d) }
    }

    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

nonisolated fileprivate func rbA24_terminateTree(_ p: Process) {
    let pid = p.processIdentifier
    // latexmk starts the engine as a child: stop the children first.
    let k = Process()
    k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
    k.arguments = ["-TERM", "-P", "\(pid)"]
    if (try? k.run()) != nil { k.waitUntilExit() }
    p.terminate()
    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        if p.isRunning { kill(pid, SIGKILL) }
    }
}

nonisolated fileprivate final class rbA24_ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func requestCancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p = p, p.isRunning { rbA24_terminateTree(p) }
    }

    private func markTimedOut() {
        lock.lock(); timedOut = true; lock.unlock()
    }

    private func flags() -> (cancelled: Bool, timedOut: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (cancelled, timedOut)
    }

    func run(executable: URL, arguments: [String], cwd: URL?, env: [String: String]?,
             timeout: TimeInterval) async -> LatexCompiler.CommandOutcome {
        let started = Date()
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments
        if let cwd = cwd { p.currentDirectoryURL = cwd }
        if let env = env { p.environment = env }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let buffer = rbA24_OutputBuffer(limit: 8_000_000)
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let d = handle.availableData
            if d.isEmpty { handle.readabilityHandler = nil } else { buffer.append(d) }
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<LatexCompiler.CommandOutcome, Never>) in
            p.terminationHandler = { [self] proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let rest = try? pipe.fileHandleForReading.readToEnd() { buffer.append(rest) }
                let f = self.flags()
                let code: Int32? = (f.cancelled || f.timedOut) ? nil : proc.terminationStatus
                cont.resume(returning: LatexCompiler.CommandOutcome(
                    exitCode: code,
                    output: buffer.text(), timedOut: f.timedOut, cancelled: f.cancelled,
                    launchError: nil, duration: Date().timeIntervalSince(started)))
            }
            do {
                try p.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                cont.resume(returning: LatexCompiler.CommandOutcome(
                    exitCode: nil, output: "", timedOut: false, cancelled: false,
                    launchError: error.localizedDescription, duration: Date().timeIntervalSince(started)))
                return
            }
            lock.lock()
            process = p
            let alreadyCancelled = cancelled
            lock.unlock()
            if alreadyCancelled { rbA24_terminateTree(p) }
            if timeout > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
                    if p.isRunning {
                        self.markTimedOut()
                        rbA24_terminateTree(p)
                    }
                }
            }
        }
    }
}
