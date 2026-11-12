import Foundation
import os

/// Wispr Faux was called Dictate (bundle ID `com.example.dictate`). On the first launch
/// after the rename, moves that version's data over so nothing has to be downloaded or set
/// up again: the models and history in Application Support, and the settings in
/// UserDefaults. Runs before anything opens those files. A cloud cleanup API key saved in
/// the keychain isn't moved; enter it again in Settings.
enum LegacyMigration {
    private static let oldBundleID = "com.example.dictate"
    private static let oldFolderName = "Dictate"
    private static let newFolderName = "Wispr Faux"

    static func run() {
        let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? newFolderName, category: "Migration")
        moveApplicationSupport(log: log)
        copyDefaults(log: log)
    }

    private static func moveApplicationSupport(log: Logger) {
        let fileManager = FileManager.default
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = support.appending(path: oldFolderName, directoryHint: .isDirectory)
        let new = support.appending(path: newFolderName, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: old.path), !fileManager.fileExists(atPath: new.path) else { return }
        do {
            try fileManager.moveItem(at: old, to: new)
            log.notice("Moved Application Support/\(oldFolderName, privacy: .public) to \(newFolderName, privacy: .public)")
        } catch {
            log.error("Couldn't move the old Application Support folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func copyDefaults(log: Logger) {
        let defaults = UserDefaults.standard
        let doneKey = "migratedFromDictate"
        guard let newID = Bundle.main.bundleIdentifier, newID != oldBundleID,
              !defaults.bool(forKey: doneKey)
        else { return }
        defer { defaults.set(true, forKey: doneKey) }
        guard let old = defaults.persistentDomain(forName: oldBundleID), !old.isEmpty else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        log.notice("Copied \(old.count) settings from \(oldBundleID, privacy: .public)")
    }
}
