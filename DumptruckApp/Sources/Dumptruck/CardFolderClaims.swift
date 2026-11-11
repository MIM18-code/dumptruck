import Foundation

/// Whether a card folder already holds another card's footage, judged the
/// way the engine judges it (`cli.cmd_offload`), so single-card Start can
/// give the card the next free name instead of launching a copy the engine
/// will refuse (Joshua, 2026-11-09: "it should simply dump the footage
/// safely and carefully, not overwriting things").
///
/// The engine's rule: a folder is taken when it holds at least one file and
/// a different card on record wrote it, or, when no card on record wrote
/// it, a different card on record carries its name. An empty folder is
/// free. So is a folder holding files no card on record claims: that is a
/// stopped first copy of this same card, or files picked earlier, and the
/// copy resumes into it file by file without overwriting anything.
///
/// The app reads the engine's card record itself because the answer has to
/// be in hand before the plan is frozen, and the record is only complete
/// once the destinations are known. The engine stays the authority: if this
/// reading is ever wrong, the engine still refuses and nothing is copied.
/// Public only because `BatchSourceFileSystem.cardRegistry()` hands out
/// its records.
public enum CardFolderClaims {
    public struct Record: Equatable {
        let id: String
        let label: String
        /// Card folders this card wrote, as the engine recorded them.
        let destinations: [String]
    }

    /// The engine's card record (`identity._db_path`).
    static var registryURL: URL {
        let home = ProcessInfo.processInfo.environment["DUMPTRUCK_HOME"]
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/Dumptruck").path
        return URL(fileURLWithPath: home).appendingPathComponent("datasets.json")
    }

    /// Every card on record. Missing or unreadable reads as none: nothing is
    /// then called taken here, and the engine decides.
    static func loadRegistry(from url: URL = registryURL) -> [Record] {
        guard let data = try? Data(contentsOf: url),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = body["datasets"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] as? String, let label = row["label"] as? String else {
                return nil
            }
            return Record(id: id, label: label,
                          destinations: row["destinations"] as? [String] ?? [])
        }
    }

    /// True when `folder` holds at least one file. Finder's own litter does
    /// not count; anything else does, manifests and reports included
    /// (`cli._occupied_card_folders`).
    static func holdsFiles(_ folder: String) -> Bool {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return false
        }
        for case let item as URL in walker {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                continue
            }
            let name = item.lastPathComponent
            if name == ".DS_Store" || name == ".localized" || name.hasPrefix("._") { continue }
            return true
        }
        return false
    }

    /// True when `lane` (a destination's folder for the card named `label`)
    /// holds another card's footage. `datasetID` is the staged card's own
    /// record, nil for a card not on record and for picked files.
    static func isTaken(
        lane: String,
        label: String,
        datasetID: String?,
        registry: [Record],
        holdsFiles: (String) -> Bool = CardFolderClaims.holdsFiles,
        resolve: (String) -> String = { ($0 as NSString).resolvingSymlinksInPath }
    ) -> Bool {
        guard holdsFiles(lane) else { return false }
        let laneKeys = BatchCardNaming.pathKeys(lane, resolve: resolve)
        let writer = registry.first { record in
            record.destinations.contains {
                !BatchCardNaming.pathKeys($0, resolve: resolve).isDisjoint(with: laneKeys)
            }
        }
        if let writer { return writer.id != datasetID }
        let key = BatchCardNaming.labelKey(label)
        return registry.contains { BatchCardNaming.labelKey($0.label) == key && $0.id != datasetID }
    }
}
