import Foundation
import SwiftData

/// Single source of truth for the BlueX SwiftData schema. Used by the GUI's
/// `BlueXApp` and by both CLIs (`blueX-annotate`, `blueX-scrape`) so a new
/// `@Model` added in one place can't be silently missed by another.
enum BlueXSchema {
    static let all: Schema = Schema([
        TrackedAccount.self,
        AccountGroup.self,
        Post.self,
        Annotation.self,
        AccountSnapshot.self,
        ScrapeLog.self,
        ModelConfig.self,
        CoordinatorState.self,
        ReplyAuthor.self,
        AuthorObservation.self,
    ])
}

/// Store location + container builder for every process that opens the BlueX
/// database: the GUI, `blueX-scrape` and `blueX-annotate`.
///
/// The store lives on the external Eregion volume. The internal disk was at 96%
/// (18Gi free) holding a 456MB store about to gain ~795k annotation rows plus 61
/// days of recovered reply trees; Eregion has 627Gi.
///
/// Only the DATA lives there. The launchd job scripts stay on the internal disk,
/// because launchd execs them and can fire during DarkWake, when this volume is not
/// mounted — that is exactly what killed scraping for 61 days from 2026-06-04.
enum BlueXStore {
    enum StoreError: LocalizedError {
        case volumeNotMounted(URL)

        var errorDescription: String? {
            switch self {
            case .volumeNotMounted(let dir):
                return "The BlueX store directory is unavailable: \(dir.path). "
                     + "Attach the Eregion drive, or set BLUEX_STORE_DIR to another location."
            }
        }
    }

    /// Store directory. `BLUEX_STORE_DIR` overrides it, so the location can change
    /// without a rebuild and tests can point at a temporary directory.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["BLUEX_STORE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: "/Volumes/Eregion/bluex-data", isDirectory: true)
    }

    static var url: URL {
        directory.appendingPathComponent("default.store", isDirectory: false)
    }

    /// True when the store directory's PARENT exists — i.e. the volume is mounted.
    ///
    /// Checking the parent rather than the directory itself is deliberate: if the
    /// drive is detached, `createDirectory` would happily build the whole path under
    /// an empty /Volumes and SwiftData would create a second, empty store. That
    /// looks like success while orphaning 797k posts, so it must be impossible.
    static var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        let parent = directory.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory) else {
            return false
        }
        return isDirectory.boolValue
    }

    /// Creates the store directory if needed and returns a configured ModelContainer.
    ///
    /// **Index re-assertion.** Every process that reads or writes this store — the
    /// app and all three CLIs — calls this before doing anything else, which makes it
    /// the one place that can keep `StoreIndexPlan.all` present across a lightweight
    /// SwiftData migration (measured to drop them silently — see
    /// `docs/superpowers/specs/2026-08-07-bluex-authors-dashboard-design.md`,
    /// *Indexes*). `IndexReasserter.reassert` never throws: a scrape or the label
    /// harvester holding the store open must never prevent the app or a CLI from
    /// starting, so a failure to acquire the write connection is logged and
    /// swallowed here, not propagated.
    static func openContainer() throws -> ModelContainer {
        guard isAvailable else { throw StoreError.volumeNotMounted(directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let config = ModelConfiguration(
            schema: BlueXSchema.all,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: BlueXSchema.all, configurations: config)
        IndexReasserter.reassert(storeURL: url)
        return container
    }
}
