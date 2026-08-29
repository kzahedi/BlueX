// BlueX/Data/SchemaVersionGuard.swift
import Foundation
import CryptoKit
import SwiftData

/// Enforces `BlueXSchema.version` against a sidecar marker written next to the
/// store file, so a binary compiled before a model change can never lightweight-
/// migrate the store DOWN to its own older schema.
///
/// **Why this exists.** Five binaries open the same SwiftData store: the app and
/// three CLIs (`blueX-scrape`, `blueX-authors`, `blueX-annotate`), plus the test
/// host. SwiftData's lightweight migration silently rewrites the store to match
/// *whichever binary opens it* — not the newest schema ever seen. On 2026-08-24/25
/// a stale `blueX-scrape` binary stripped `LabelBatch.skippedURIs` from the store
/// every ~80 minutes, discarding the annotator's skips with no error, no log line,
/// no crash. This guard makes that impossible: it runs BEFORE the `ModelContainer`
/// is constructed, because once SwiftData has opened the file the migration has
/// already happened.
///
/// The marker lives entirely outside the Core Data store (a plain JSON file next
/// to it) so it never touches `Z_METADATA` or any Core Data machinery.
enum SchemaVersionGuard {
    /// The sidecar's on-disk shape: `{"version": N, "writtenBy": "<binary>", "writtenAt": "<ISO8601>"}`.
    struct Marker: Codable, Equatable {
        var version: Int
        var writtenBy: String
        var writtenAt: String
    }

    enum ReadResult {
        case absent
        case malformed
        case marker(Marker)
    }

    static func sidecarURL(for storeURL: URL) -> URL {
        URL(fileURLWithPath: storeURL.path + ".schema-version")
    }

    static func readMarker(storeURL: URL) -> ReadResult {
        let url = sidecarURL(for: storeURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url) else { return .malformed }
        guard let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return .malformed }
        return .marker(marker)
    }

    private static func writeMarker(storeURL: URL, version: Int, binaryName: String) throws {
        let marker = Marker(
            version: version,
            writtenBy: binaryName,
            writtenAt: ISO8601DateFormatter().string(from: Date())
        )
        let data = try JSONEncoder().encode(marker)
        try data.write(to: sidecarURL(for: storeURL), options: .atomic)
    }

    /// Called BEFORE `ModelContainer` is constructed. Throws — refusing to open the
    /// store at all — when the sidecar is malformed (fail CLOSED: a corrupted
    /// marker is exactly when a silent backward migration is least wanted) or when
    /// it names a schema version newer than this binary's.
    static func checkBeforeOpening(storeURL: URL, binaryVersion: Int, binaryName: String) throws {
        switch readMarker(storeURL: storeURL) {
        case .absent:
            return
        case .malformed:
            throw BlueXStore.StoreError.malformedSchemaVersionMarker(sidecarURL(for: storeURL))
        case .marker(let marker):
            if marker.version > binaryVersion {
                throw BlueXStore.StoreError.storeWrittenByNewerSchema(
                    binary: binaryName,
                    binaryVersion: binaryVersion,
                    storeVersion: marker.version
                )
            }
        }
    }

    /// Called AFTER a successful open. Writes the sidecar when it was absent or
    /// behind this binary's version (a legitimate forward migration); leaves it
    /// untouched when already equal. `checkBeforeOpening` has already refused any
    /// case where the sidecar is ahead or malformed, so those cases can't reach
    /// here in the normal flow — if a marker somehow appears newer or malformed at
    /// this point (a race with another process), it is safely re-written rather
    /// than propagating a failure after the container is already open.
    static func recordAfterOpening(storeURL: URL, binaryVersion: Int, binaryName: String) throws {
        switch readMarker(storeURL: storeURL) {
        case .absent:
            try writeMarker(storeURL: storeURL, version: binaryVersion, binaryName: binaryName)
        case .marker(let marker):
            if marker.version < binaryVersion {
                try writeMarker(storeURL: storeURL, version: binaryVersion, binaryName: binaryName)
            }
        case .malformed:
            try writeMarker(storeURL: storeURL, version: binaryVersion, binaryName: binaryName)
        }
    }
}

extension BlueXSchema {
    /// A fingerprint of the persisted surface: every entity name in `BlueXSchema.all`
    /// paired with its persisted property names, derived directly from the schema's
    /// own entity metadata (no hand-maintained list to drift from the real models).
    ///
    /// This is the developer-facing drift check: `SchemaVersionGuardTests` commits
    /// the fingerprint that corresponds to the current `BlueXSchema.version`. If a
    /// model gains, loses, or renames a persisted property (or an entity is
    /// added/removed) without a matching version bump, this fingerprint changes and
    /// that test fails — telling the developer to bump `version` and update the
    /// committed fingerprint together.
    static func persistedSurfaceFingerprint() -> String {
        let parts = all.entities.map { entity -> String in
            let propertyNames = entity.properties.map(\.name).sorted()
            return "\(entity.name):\(propertyNames.joined(separator: ","))"
        }.sorted()
        let joined = parts.joined(separator: "|")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
