//
//  ResetService.swift
//  ResearchBase
//
//  Owner: Agent 80 · Features: clean start ("Erase everything and start fresh")
//
//  Wipes every place ResearchBase keeps data, so the next launch looks like
//  a first launch. The wipe cannot run while the app is open (the SQLite
//  library and the SwiftData store are in use), so it works in two steps:
//
//      1. Settings calls `scheduleEraseAndRelaunch()`. That only sets a flag
//         in UserDefaults and relaunches the app. Nothing is deleted yet.
//      2. At the very start of the next launch, BEFORE the library or the
//         SwiftData container is opened, the app calls
//         `performPendingEraseIfNeeded()`. That does the deleting.
//
//  PUBLIC API
//    ResetService.scheduleEraseAndRelaunch(keepBackups: Bool = true) -> Bool
//        Main thread. Sets the flag, starts the relaunch, quits the app.
//        Returns false (and leaves everything as it was) if the relaunch
//        could not be started. The caller must have asked the user to type
//        a confirmation word first; this file does not ask.
//    ResetService.performPendingEraseIfNeeded() -> Bool
//        Call first thing at launch. Returns true if an erase ran.
//        Safe to call on every launch: it does nothing without the flag.
//    ResetService.eraseSummary: String
//        Plain-language result of the last erase ("" if there never was one).
//    ResetService.clearEraseSummary()
//        Call after the summary has been shown once.
//    ResetService.plannedItems(keepBackups:) -> [PlannedItem]
//        What an erase would delete right now, with sizes, for the
//        confirmation sheet. Deletes nothing.
//
//  What an erase removes
//    * ~/Documents/ResearchBase Library      (library.sqlite, -wal, -shm,
//                                             PDFs, drafts, inbox, exports)
//    * ~/Library/Application Support/default.store (+ -shm, -wal,
//                                             .default_SUPPORT)   SwiftData
//    * ~/Library/Application Support/ResearchBase (Papers, profile data)
//    * Backups, only when keepBackups is false:
//        ResearchBase Library/backups and Application Support/ResearchBase/Backups
//    * UserDefaults for this app (theme, sidebar, panel widths, last page,
//      welcome and profile state, and the erase flags themselves)
//    * Keychain items of this app (API keys, capture token)
//    * Pending reminder notifications
//    * App caches and saved window state
//  It never touches ~/Library/Logs/ResearchBase or anything outside the
//  paths above.
//
//  Safety rules
//    * The flag expires after 10 minutes. A stale flag is cleared and
//      ignored, so a leftover flag can never wipe data days later.
//    * The flag is cleared BEFORE deleting, so a crash halfway can never
//      cause a second erase of data created afterwards.
//    * Every delete is checked to be strictly inside its expected parent.
//      A path that is the parent itself, or outside it, is refused.
//    * Backups are kept by default.
//

import Foundation
import AppKit
import Security
import UserNotifications

nonisolated enum ResetService {

    // MARK: - Constants

    /// UserDefaults keys. Fixed: Settings and the app entry point rely on
    /// the behaviour, not on these names, but tests and docs use them.
    static let pendingEraseKey = "rb.pendingErase"
    static let requestedAtKey = "rb.pendingErase.requestedAt"
    static let keepBackupsKey = "rb.pendingErase.keepBackups"
    static let summaryKey = "rb.lastEraseSummary"

    /// A request older than this is ignored.
    static let maxRequestAge: TimeInterval = 10 * 60

    /// Kept equal to `Library.folderName` (a test checks that). Written out
    /// here because the app's default isolation is MainActor and this file
    /// must be callable from a plain synchronous launch path.
    static let libraryFolderName = "ResearchBase Library"
    static let libraryBackupsFolderName = "backups"
    static let supportFolderName = "ResearchBase"
    static let supportBackupsFolderName = "Backups"

    /// Files SwiftData's default `.modelContainer(for:)` creates in
    /// Application Support (the app is not sandboxed).
    static let swiftDataNames = [
        "default.store", "default.store-shm", "default.store-wal", ".default_SUPPORT"
    ]

    private static let fallbackBundleID = "com.gaurav.ResearchBase"

    // MARK: - Types

    /// Where everything lives. `live` is the real thing; tests pass temp
    /// folders and a private UserDefaults suite.
    struct Locations {
        var applicationSupport: URL
        var documents: URL
        var caches: URL
        var savedState: URL
        var bundleID: String
        var defaults: UserDefaults
        /// Domain removed from UserDefaults (nil = just remove our own keys).
        var defaultsDomain: String?
        /// Deletes this app's Keychain items, returns how many were removed.
        var deleteSecrets: () -> Int
        /// Cancels reminder notifications.
        var clearNotifications: () -> Void

        static var live: Locations {
            let fm = FileManager.default
            let bundleID = Bundle.main.bundleIdentifier ?? ResetService.fallbackBundleID
            let home = fm.homeDirectoryForCurrentUser
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Library/Application Support", isDirectory: true)
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Documents", isDirectory: true)
            let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Library/Caches", isDirectory: true)
            let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
                ?? home.appendingPathComponent("Library", isDirectory: true)
            return Locations(
                applicationSupport: support,
                documents: docs,
                caches: caches.appendingPathComponent(bundleID, isDirectory: true),
                savedState: library
                    .appendingPathComponent("Saved Application State", isDirectory: true)
                    .appendingPathComponent("\(bundleID).savedState", isDirectory: true),
                bundleID: bundleID,
                defaults: .standard,
                defaultsDomain: bundleID,
                deleteSecrets: { ResetService.deleteAllKeychainItems() },
                clearNotifications: {
                    let center = UNUserNotificationCenter.current()
                    center.removeAllPendingNotificationRequests()
                    center.removeAllDeliveredNotifications()
                }
            )
        }
    }

    /// One thing an erase would delete (for the confirmation sheet).
    struct PlannedItem: Identifiable, Equatable {
        var id: String { url.path }
        let label: String
        let url: URL
        let bytes: Int64
        let exists: Bool
        /// Child names that stay (for example "backups").
        let keeping: [String]
    }

    /// What an erase did.
    struct Outcome: Equatable {
        var removedLabels: [String] = []
        var failures: [String] = []
        var bytesFreed: Int64 = 0
        var secretsRemoved: Int = 0
        var keptBackups: Bool = true

        var summary: String {
            var parts: [String] = []
            if removedLabels.isEmpty {
                parts.append("Nothing needed to be erased.")
            } else {
                let size = ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
                parts.append("Erased \(removedLabels.joined(separator: ", ")) (\(size)).")
            }
            if secretsRemoved > 0 {
                parts.append("Removed \(secretsRemoved) saved key\(secretsRemoved == 1 ? "" : "s") from the Keychain.")
            }
            parts.append("Settings and profile were reset.")
            parts.append(keptBackups ? "Your backups were kept." : "Backups were erased too.")
            if !failures.isEmpty {
                parts.append("Could not remove: \(failures.joined(separator: "; ")).")
            }
            return parts.joined(separator: " ")
        }
    }

    // MARK: - Step 1: ask for an erase (while the app is running)

    /// Sets the flag, starts a relaunch, and quits. Main thread only.
    /// Returns false, with the flag cleared again, if the relaunch could
    /// not be started.
    @MainActor
    @discardableResult
    static func scheduleEraseAndRelaunch(keepBackups: Bool = true) -> Bool {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: pendingEraseKey)
        defaults.set(Date(), forKey: requestedAtKey)
        defaults.set(keepBackups, forKey: keepBackupsKey)

        guard startRelaunchHelper() else {
            clearFlags(in: defaults)
            return false
        }
        NSApp.terminate(nil)
        return true
    }

    /// Starts a tiny background shell that waits for this app to quit and
    /// then opens it again. `$0` carries the app path, so no quoting issues.
    private static func startRelaunchHelper() -> Bool {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "(sleep 2; /usr/bin/open -n \"$0\") >/dev/null 2>&1 &",
            bundlePath
        ]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }

    // MARK: - Step 2: do the erase (first thing at the next launch)

    /// Runs the erase if one was requested in the last 10 minutes.
    @discardableResult
    static func performPendingEraseIfNeeded(
        locations: Locations = .live,
        now: Date = Date()
    ) -> Bool {
        let defaults = locations.defaults
        guard defaults.bool(forKey: pendingEraseKey) else { return false }

        let requestedAt = defaults.object(forKey: requestedAtKey) as? Date
        let keepBackups = (defaults.object(forKey: keepBackupsKey) as? Bool) ?? true

        // Clear the flags first, so nothing here can repeat.
        clearFlags(in: defaults)

        guard let requestedAt,
              now.timeIntervalSince(requestedAt) >= 0,
              now.timeIntervalSince(requestedAt) <= maxRequestAge else {
            defaults.set("An old erase request was ignored. Nothing was deleted.", forKey: summaryKey)
            return false
        }

        let outcome = erase(keepBackups: keepBackups, locations: locations)

        // Last, wipe the settings (this removes the flags and old summary
        // too), then store the result for one-time display.
        if let domain = locations.defaultsDomain {
            defaults.removePersistentDomain(forName: domain)
        } else {
            removeOurKeys(from: defaults)
        }
        defaults.set(outcome.summary, forKey: summaryKey)
        return true
    }

    /// The deleting itself. Needs no flag, so tests can call it directly
    /// with temp folders.
    static func erase(keepBackups: Bool, locations: Locations) -> Outcome {
        var outcome = Outcome()
        outcome.keptBackups = keepBackups

        for item in targets(keepBackups: keepBackups, locations: locations) {
            let bytes = size(of: item.url, excluding: Set(item.keeping))
            let existed = FileManager.default.fileExists(atPath: item.url.path)
            guard existed else { continue }
            if remove(item, failures: &outcome.failures) {
                outcome.removedLabels.append(item.label)
                outcome.bytesFreed += bytes
            }
        }

        outcome.secretsRemoved = locations.deleteSecrets()
        locations.clearNotifications()
        return outcome
    }

    // MARK: - Summary

    /// Result of the last erase, "" if there was none.
    static var eraseSummary: String {
        UserDefaults.standard.string(forKey: summaryKey) ?? ""
    }

    static func clearEraseSummary() {
        UserDefaults.standard.removeObject(forKey: summaryKey)
    }

    // MARK: - Preview for the confirmation sheet

    static func plannedItems(
        keepBackups: Bool = true,
        locations: Locations = .live
    ) -> [PlannedItem] {
        let fm = FileManager.default
        return targets(keepBackups: keepBackups, locations: locations).map { target in
            let exists = fm.fileExists(atPath: target.url.path)
            return PlannedItem(
                label: target.label,
                url: target.url,
                bytes: exists ? size(of: target.url, excluding: Set(target.keeping)) : 0,
                exists: exists,
                keeping: target.keeping
            )
        }
    }

    // MARK: - Targets

    private struct Target {
        let label: String
        let url: URL
        /// The folder the delete must stay strictly inside.
        let parent: URL
        /// Direct children to leave alone.
        let keeping: [String]
    }

    private static func targets(keepBackups: Bool, locations: Locations) -> [Target] {
        var list: [Target] = []

        list.append(Target(
            label: "the library (database, PDFs, drafts)",
            url: locations.documents.appendingPathComponent(libraryFolderName, isDirectory: true),
            parent: locations.documents,
            keeping: keepBackups ? [libraryBackupsFolderName] : []
        ))

        for name in swiftDataNames {
            list.append(Target(
                label: name == "default.store" ? "the old SwiftData store" : "SwiftData side file \(name)",
                url: locations.applicationSupport.appendingPathComponent(name),
                parent: locations.applicationSupport,
                keeping: []
            ))
        }

        list.append(Target(
            label: "saved app data (papers folder, profile)",
            url: locations.applicationSupport.appendingPathComponent(supportFolderName, isDirectory: true),
            parent: locations.applicationSupport,
            keeping: keepBackups ? [supportBackupsFolderName] : []
        ))

        list.append(Target(
            label: "caches",
            url: locations.caches,
            parent: locations.caches.deletingLastPathComponent(),
            keeping: []
        ))

        list.append(Target(
            label: "saved window state",
            url: locations.savedState,
            parent: locations.savedState.deletingLastPathComponent(),
            keeping: []
        ))

        return list
    }

    // MARK: - Deleting

    /// Removes `target`, or everything inside it except `keeping`.
    /// Refuses any path that is not strictly inside `target.parent`.
    private static func remove(_ target: Target, failures: inout [String]) -> Bool {
        let fm = FileManager.default

        guard isStrictlyInside(target.url, parent: target.parent) else {
            failures.append("\(target.label) (path check refused)")
            return false
        }

        do {
            if target.keeping.isEmpty {
                try fm.removeItem(at: target.url)
            } else {
                let children = try fm.contentsOfDirectory(
                    at: target.url,
                    includingPropertiesForKeys: nil,
                    options: []
                )
                let keep = Set(target.keeping)
                for child in children where !keep.contains(child.lastPathComponent) {
                    try fm.removeItem(at: child)
                }
            }
            return true
        } catch {
            failures.append("\(target.label) (\(error.localizedDescription))")
            return false
        }
    }

    static func isStrictlyInside(_ url: URL, parent: URL) -> Bool {
        let child = url.standardizedFileURL.resolvingSymlinksInPath().path
        let base = parent.standardizedFileURL.resolvingSymlinksInPath().path
        guard !child.isEmpty, !base.isEmpty, base != "/" else { return false }
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return child.hasPrefix(prefix) && child.count > prefix.count
    }

    // MARK: - Sizes

    private static func size(of url: URL, excluding names: Set<String>) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        func fileSize(_ u: URL) -> Int64 {
            let values = try? u.resourceValues(forKeys: Set(keys))
            return Int64(values?.fileSize ?? 0)
        }
        guard isDir.boolValue else { return fileSize(url) }

        var total: Int64 = 0
        let top = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for child in top where !names.contains(child.lastPathComponent) {
            var childIsDir: ObjCBool = false
            fm.fileExists(atPath: child.path, isDirectory: &childIsDir)
            if childIsDir.boolValue {
                if let walker = fm.enumerator(at: child, includingPropertiesForKeys: keys) {
                    for case let file as URL in walker {
                        let values = try? file.resourceValues(forKeys: Set(keys))
                        if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
                    }
                }
            } else {
                total += fileSize(child)
            }
        }
        return total
    }

    // MARK: - Flags and settings

    private static func clearFlags(in defaults: UserDefaults) {
        defaults.removeObject(forKey: pendingEraseKey)
        defaults.removeObject(forKey: requestedAtKey)
        defaults.removeObject(forKey: keepBackupsKey)
    }

    private static func removeOurKeys(from defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("rb.") || key.hasPrefix("sidebar.") {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - Keychain

    /// Deletes every generic-password item stored under this app's Keychain
    /// service (API keys and the capture token). Returns how many went.
    static func deleteAllKeychainItems(service: String = KeychainStore.defaultService) -> Int {
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { return 0 }

        var removed = 0
        for row in rows {
            guard let account = row[kSecAttrAccount as String] as? String else { continue }
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            if SecItemDelete(query as CFDictionary) == errSecSuccess { removed += 1 }
        }
        return removed
    }
}
