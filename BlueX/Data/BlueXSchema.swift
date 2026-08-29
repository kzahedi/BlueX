import Foundation
import SwiftData

/// Single source of truth for the BlueX SwiftData schema. Used by the GUI's
/// `BlueXApp` and by both CLIs (`blueX-annotate`, `blueX-scrape`) so a new
/// `@Model` added in one place can't be silently missed by another.
enum BlueXSchema {
    /// Monotonic version of the persisted surface (entity + persisted-property
    /// shape) below in `all`. **MUST be incremented whenever any `@Model` type
    /// gains, loses, or renames a persisted property, or an entity is added or
    /// removed.** Enforced by `SchemaVersionGuardTests.testPersistedSurfaceFingerprintMatchesDeclaredVersion`
    /// — that test fails if the schema changes without this bump.
    ///
    /// `BlueXStore.openContainer()` refuses to open a store whose sidecar marker
    /// (`SchemaVersionGuard`) records a version higher than this one, so a binary
    /// built before a model change can never lightweight-migrate the store DOWN
    /// and silently destroy newer columns (measured happening repeatedly with
    /// `LabelBatch.skippedURIs` and the hand-built indexes on 2026-08-24/25).
    ///
    /// Starts at 1: everything before this guard existed is "unversioned" — there
    /// is no reconstructable version 0 schema to pin, so 1 is the first schema
    /// this mechanism protects.
    static let version: Int = 1

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
        LabelBatch.self,
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
        /// The sidecar schema-version marker names a version newer than this
        /// binary's `BlueXSchema.version` — this binary is stale relative to the
        /// store and must not be allowed to open (and therefore migrate) it.
        case storeWrittenByNewerSchema(binary: String, binaryVersion: Int, storeVersion: Int)
        /// The sidecar marker exists but could not be read/decoded. Treated as a
        /// refusal (fail CLOSED) rather than as "absent", because a corrupted
        /// marker is exactly the situation where a silent backward migration is
        /// least acceptable.
        case malformedSchemaVersionMarker(URL)

        var errorDescription: String? {
            switch self {
            case .volumeNotMounted(let dir):
                return "The BlueX store directory is unavailable: \(dir.path). "
                     + "Attach the Eregion drive, or set BLUEX_STORE_DIR to another location."
            case .storeWrittenByNewerSchema(let binary, let binaryVersion, let storeVersion):
                return "\(binary) is schema version \(binaryVersion), but this store was last "
                     + "written by schema version \(storeVersion). Refusing to open it — "
                     + "rebuild every binary that opens this store — run tools/install-cli.sh "
                     + "and rebuild the app."
            case .malformedSchemaVersionMarker(let url):
                return "The schema-version marker at \(url.path) exists but is unreadable or "
                     + "malformed. Refusing to open the store rather than risk a silent backward "
                     + "migration — rebuild every binary that opens this store — run "
                     + "tools/install-cli.sh and rebuild the app."
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

        // Schema-version guard — MUST run before the ModelContainer below is ever
        // constructed. Once SwiftData opens the file it has already lightweight-
        // migrated it to this binary's schema; by then it is too late to refuse.
        let binaryName = ProcessInfo.processInfo.processName
        try SchemaVersionGuard.checkBeforeOpening(
            storeURL: url,
            binaryVersion: BlueXSchema.version,
            binaryName: binaryName
        )

        let config = ModelConfiguration(
            schema: BlueXSchema.all,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: BlueXSchema.all, configurations: config)
        IndexReasserter.reassert(storeURL: url)
        try SchemaVersionGuard.recordAfterOpening(
            storeURL: url,
            binaryVersion: BlueXSchema.version,
            binaryName: binaryName
        )
        return container
    }
}
