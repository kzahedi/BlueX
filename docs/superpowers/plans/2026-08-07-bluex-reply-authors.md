# Reply Authors and Moderation-Outcome Probing — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Model the 146,422 people who reply to tracked news accounts, and record what happens to them over time, so platform moderation outcomes — takedown rate, enforcement latency, enforcement coverage — become measurable.

**Architecture:** Two new SwiftData models (`ReplyAuthor` keyed on DID, `AuthorObservation` written only on change). A new unauthenticated `PublicProfileAPI` against `public.api.bsky.app`, kept separate from the just-hardened `BlueskyAPIClient`. Pure probe logic (`AuthorProbe`) split from store persistence (`AuthorProbeRunner`) so batching and classification are unit-testable without SwiftData. A new `blueX-authors` CLI and a weekly launchd agent.

**Tech Stack:** Swift 5.9, SwiftData, XCTest, XcodeGen 2.46.0, zsh job scripts, launchd, pytest for job-script guards.

**Spec:** `docs/superpowers/specs/2026-08-07-bluex-reply-authors-design.md`

## Global Constraints

- **Identity is the DID, never the handle.** The corpus has 146,422 distinct DIDs but 146,336 distinct handles — handles are reused and changed.
- **Write-on-change**: an `AuthorObservation` is written only when `status`, `handle`, `labels`, `displayName`, `profileDescription` or `accountCreatedAt` differs from the newest existing observation. **Counts never trigger a write** — follower drift would produce ~146k rows per sweep and defeat the design.
- **No relationship from `Post` to `ReplyAuthor`.** Queries join on the DID string. Adding a relationship means SwiftData rewriting 842,369 rows in a migration.
- **The probe is unauthenticated.** `app.bsky.actor.getProfiles` works without a token against `https://public.api.bsky.app/xrpc`. This subsystem must never read the Keychain.
- **A DID missing from a batch is not "deleted".** It is only recorded as gone when a single-actor lookup returns a specific reason. An unclassifiable absence is `unknown`.
- **Statuses are observations, never terminal.** `AccountDeactivated` can revert.
- Deployment target `14.0`, `SWIFT_VERSION: "5.9"` for all targets.
- Store path is `/Volumes/Eregion/bluex-data`; job scripts stay on the internal disk. Run `xcodegen generate` after adding any source file.
- Branch: work on `fix/nightly-scrape-and-sentiment` unless told otherwise. Never commit to `main`.

## File Structure

| File | Responsibility |
|---|---|
| `BlueX/Data/ReplyAuthor.swift` | **new** — DID-keyed identity + cached current state |
| `BlueX/Data/AuthorObservation.swift` | **new** — immutable point-in-time record |
| `BlueX/Data/BlueXSchema.swift` | **modify** — register both models |
| `BlueX/Services/API/BlueskyStructs.swift` | **modify** — `ATProtoProfile` gains `createdAt`, `description`, `labels` |
| `BlueX/Services/API/PublicProfileAPI.swift` | **new** — unauthenticated batch + single profile, parses the reason code |
| `BlueX/Services/Authors/AuthorProbe.swift` | **new** — pure: chunking, requested-vs-returned diff, classification |
| `BlueX/Services/Authors/AuthorBackfill.swift` | **new** — populate `ReplyAuthor` from `Post`, idempotent, paged |
| `BlueX/Services/Authors/AuthorProbeRunner.swift` | **new** — drives the probe over the store, applies write-on-change |
| `cli/authors/main.swift` | **new** — `blueX-authors --backfill \| --probe \| --stats` |
| `project.yml` | **modify** — new `BlueXAuthors` target |
| `tools/jobs/bluex-authors-job.sh` | **new** — weekly wrapper |
| `tools/install-jobs.sh` | **modify** — install the weekly agent |
| `tools/jobs/test_jobs.py` | **modify** — cover the new script |

---

### Task 1: The two models

**Files:**
- Create: `BlueX/Data/ReplyAuthor.swift`, `BlueX/Data/AuthorObservation.swift`
- Modify: `BlueX/Data/BlueXSchema.swift:7-18`
- Test: `BlueXTests/Data/ReplyAuthorTests.swift`

**Interfaces:**
- Produces: `ReplyAuthor(did:firstSeenAt:lastSeenAt:)` with `currentHandle: String?`, `currentStatus: String`, `lastProbedAt: Date?`, `observations: [AuthorObservation]`; and `AuthorObservation(observedAt:status:)` with the optional profile fields below. Tasks 4, 6 and 7 depend on these exact names.

- [ ] **Step 1: Write the failing test**

Create `BlueXTests/Data/ReplyAuthorTests.swift`:

```swift
// BlueXTests/Data/ReplyAuthorTests.swift
import XCTest
import SwiftData
@testable import BlueX

final class ReplyAuthorTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Post.self, Annotation.self, TrackedAccount.self, AccountGroup.self,
            ScrapeLog.self, CoordinatorState.self, AccountSnapshot.self, ModelConfig.self,
            ReplyAuthor.self, AuthorObservation.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    func testAuthorPersistsWithDefaults() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let a = ReplyAuthor(did: "did:plc:abc",
                            firstSeenAt: Date(timeIntervalSince1970: 100),
                            lastSeenAt: Date(timeIntervalSince1970: 200))
        ctx.insert(a)
        try ctx.save()

        let fresh = ModelContext(container)
        let loaded = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ReplyAuthor>()).first)
        XCTAssertEqual(loaded.did, "did:plc:abc")
        XCTAssertEqual(loaded.currentStatus, "unknown", "an unprobed author is unknown, not active")
        XCTAssertNil(loaded.lastProbedAt)
        XCTAssertNil(loaded.currentHandle)
        XCTAssertTrue(loaded.observations.isEmpty)
    }

    func testObservationAttachesAndCascades() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let a = ReplyAuthor(did: "did:plc:abc", firstSeenAt: Date(), lastSeenAt: Date())
        ctx.insert(a)
        let o = AuthorObservation(observedAt: Date(timeIntervalSince1970: 500), status: "takedown")
        o.statusReason = "AccountTakedown"
        o.author = a
        ctx.insert(o)
        try ctx.save()

        let fresh = ModelContext(container)
        let loaded = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ReplyAuthor>()).first)
        XCTAssertEqual(loaded.observations.count, 1)
        XCTAssertEqual(loaded.observations.first?.statusReason, "AccountTakedown")

        // deleting the author must remove its observations (cascade)
        let del = ModelContext(container)
        let target = try XCTUnwrap(try del.fetch(FetchDescriptor<ReplyAuthor>()).first)
        del.delete(target)
        try del.save()
        let after = ModelContext(container)
        XCTAssertEqual(try after.fetch(FetchDescriptor<AuthorObservation>()).count, 0)
    }

    // A gone account has no counts. Storing 0 would be a lie that silently
    // corrupts any average computed over the population.
    func testCountsAreNilNotZeroWhenAbsent() throws {
        let container = try makeContainer()
        let ctx = ModelContext(container)
        let o = AuthorObservation(observedAt: Date(), status: "deleted")
        ctx.insert(o)
        try ctx.save()
        let fresh = ModelContext(container)
        let loaded = try XCTUnwrap(try fresh.fetch(FetchDescriptor<AuthorObservation>()).first)
        XCTAssertNil(loaded.followersCount)
        XCTAssertNil(loaded.postsCount)
        XCTAssertNil(loaded.accountCreatedAt)
    }
}
```

- [ ] **Step 2: Regenerate and run to see it fail**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueX \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/ReplyAuthorTests 2>&1 | tail -20
```
Expected: FAIL — `cannot find 'ReplyAuthor' in scope`

- [ ] **Step 3: Create `ReplyAuthor`**

```swift
// BlueX/Data/ReplyAuthor.swift
import Foundation
import SwiftData

/// A person who replied to a tracked account. Distinct from `TrackedAccount`, which
/// models the six curated news outlets: these are ~146k members of the public with a
/// completely different lifecycle, so they get their own entity rather than a flag.
///
/// Keyed on DID, never handle. The corpus contains 146,422 distinct DIDs but only
/// 146,336 distinct handles — handles are changed and reused, so a handle-keyed identity
/// would silently merge different people.
///
/// There is deliberately NO relationship from `Post` to here. Adding one would mean
/// SwiftData rewriting all 842,369 reply rows in a migration to gain what a join on
/// `authorDID` already provides.
@Model
final class ReplyAuthor {
    var did: String
    /// Earliest and latest reply by this DID *in our corpus* — not the account's real
    /// lifespan, which comes from the profile's `accountCreatedAt`.
    var firstSeenAt: Date
    var lastSeenAt: Date

    /// Caches of the newest observation, so "which authors are still active?" needs no
    /// join. Derived, never authoritative — `observations` is the record.
    var currentHandle: String?
    var currentStatus: String
    var lastProbedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \AuthorObservation.author)
    var observations: [AuthorObservation]

    init(did: String, firstSeenAt: Date, lastSeenAt: Date) {
        self.did = did
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.currentHandle = nil
        self.currentStatus = AuthorStatus.unknown.rawValue
        self.lastProbedAt = nil
        self.observations = []
    }
}

/// The states an account can be observed in. Stored as `rawValue` strings because
/// SwiftData persists enums only via RawRepresentable, and strings keep the store
/// readable from `sqlite3` during analysis.
enum AuthorStatus: String {
    case active
    case takedown        // AccountTakedown — a moderator actioned this account
    case deactivated     // AccountDeactivated — the user did; reversible
    case deleted         // DID no longer resolves
    case unknown         // absent from a batch but unclassifiable; NOT evidence of removal
}
```

- [ ] **Step 4: Create `AuthorObservation`**

```swift
// BlueX/Data/AuthorObservation.swift
import Foundation
import SwiftData

/// One point-in-time record of an account's public state. Immutable once written.
///
/// Written ONLY when something material changed (see `AuthorProbeRunner`). Snapshotting
/// every author every sweep would be ~146k × 52 ≈ 7.6M rows a year, ~99% identical to
/// the row before. Counts deliberately do not count as "material": follower numbers
/// drift continuously, so including them would write the whole population every week.
@Model
final class AuthorObservation {
    var observedAt: Date
    var status: String
    /// The raw API error code when not active — e.g. "AccountTakedown". Kept raw rather
    /// than normalised so an unfamiliar future code is preserved rather than discarded.
    var statusReason: String?

    var handle: String?
    var displayName: String?
    var profileDescription: String?
    /// When the ACCOUNT was created, from the profile. Enables "account age at time of
    /// reply" — the throwaway-account signature.
    var accountCreatedAt: Date?

    // Optional, not defaulted to 0: a gone account has no counts and 0 would be a lie.
    var followersCount: Int?
    var followsCount: Int?
    var postsCount: Int?

    /// Bluesky's own moderation labels, comma-joined. Empty string means "observed, none";
    /// nil means "not observed". That distinction matters when counting labelled accounts.
    var labels: String?
    var hasAvatar: Bool

    @Relationship(deleteRule: .nullify) var author: ReplyAuthor?

    init(observedAt: Date, status: String) {
        self.observedAt = observedAt
        self.status = status
        self.hasAvatar = false
    }
}
```

- [ ] **Step 5: Register both in the schema**

In `BlueX/Data/BlueXSchema.swift`, add to `BlueXSchema.all` after `CoordinatorState.self`:

```swift
        CoordinatorState.self,
        ReplyAuthor.self,
        AuthorObservation.self,
    ])
```

- [ ] **Step 6: Run the tests**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild test -project BlueX.xcodeproj -scheme BlueX \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/ReplyAuthorTests 2>&1 | tail -20
```
Expected: PASS — 3 tests

- [ ] **Step 7: Run the full suite**

The schema changed, so every store-opening test is affected. This must be green before committing.

```bash
xcodebuild test -project BlueX.xcodeproj -scheme BlueX -destination 'platform=macOS,arch=arm64' 2>&1 | tail -20
```
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add BlueX/Data/ReplyAuthor.swift BlueX/Data/AuthorObservation.swift BlueX/Data/BlueXSchema.swift BlueXTests/Data/ReplyAuthorTests.swift BlueX.xcodeproj
git commit -m "feat(authors): ReplyAuthor and AuthorObservation models

Keyed on DID, not handle: the corpus has 146,422 DIDs against 146,336 handles,
so handle-keyed identity would merge different people. Observations are
immutable and written on change only. Counts are optional because a removed
account has none and 0 would be a lie."
```

---

### Task 2: Decode the profile fields we actually need

`ATProtoProfile` currently decodes neither `createdAt` nor `labels`. Both are central: `createdAt` gives account age at time of reply, and `labels` is Bluesky's own moderation signal.

**Files:**
- Modify: `BlueX/Services/API/BlueskyStructs.swift:14-22`
- Test: `BlueXTests/Services/API/ATProtoProfileDecodingTests.swift`

**Interfaces:**
- Produces: `ATProtoProfile` gains `createdAt: String?`, `description: String?`, `labels: [ATProtoLabel]?`; and `ATProtoLabel` with `val: String`. Tasks 3 and 4 consume these.

- [ ] **Step 1: Write the failing test**

```swift
// BlueXTests/Services/API/ATProtoProfileDecodingTests.swift
import XCTest
@testable import BlueX

final class ATProtoProfileDecodingTests: XCTestCase {

    /// Shape captured from a real public.api.bsky.app getProfiles response, 2026-08-07.
    func testDecodesTheFieldsTheProbeNeeds() throws {
        let json = """
        {
          "did": "did:plc:abc", "handle": "someone.bsky.social",
          "displayName": "Someone", "description": "bio text here",
          "avatar": "https://cdn.example/a.jpg",
          "createdAt": "2024-11-13T01:24:48.408Z",
          "followersCount": 206, "followsCount": 300, "postsCount": 1234,
          "labels": [{"val": "!warn"}, {"val": "spam"}]
        }
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(ATProtoProfile.self, from: json)
        XCTAssertEqual(p.did, "did:plc:abc")
        XCTAssertEqual(p.description, "bio text here")
        XCTAssertEqual(p.createdAt, "2024-11-13T01:24:48.408Z")
        XCTAssertEqual(p.labels?.map(\.val), ["!warn", "spam"])
    }

    /// Every added field is optional — a profile without a bio, labels or createdAt
    /// must still decode, or the probe fails on ordinary accounts.
    func testDecodesMinimalProfile() throws {
        let json = """
        {"did":"did:plc:x","handle":"x.bsky.social"}
        """.data(using: .utf8)!
        let p = try JSONDecoder().decode(ATProtoProfile.self, from: json)
        XCTAssertNil(p.description)
        XCTAssertNil(p.labels)
        XCTAssertNil(p.createdAt)
    }
}
```

- [ ] **Step 2: Run to see it fail**

```bash
xcodebuild test -project BlueX.xcodeproj -scheme BlueX -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/ATProtoProfileDecodingTests 2>&1 | tail -20
```
Expected: FAIL — `value of type 'ATProtoProfile' has no member 'description'`

- [ ] **Step 3: Extend the struct**

In `BlueX/Services/API/BlueskyStructs.swift`, replace the `ATProtoProfile` declaration:

```swift
/// One label applied to an account by a Bluesky labeler. `val` is the label value,
/// e.g. "!warn" or "spam". Captured because it is a second externally-generated
/// moderation signal alongside takedown status.
struct ATProtoLabel: Codable {
    let val: String
}

struct ATProtoProfile: Codable {
    let did: String
    let handle: String
    let displayName: String?
    let avatar: String?
    let followersCount: Int?
    let followsCount: Int?
    let postsCount: Int?
    // Added for the author probe. All optional: an ordinary profile may have no bio
    // and no labels, and older responses may omit createdAt.
    let description: String?
    let createdAt: String?
    let labels: [ATProtoLabel]?
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodebuild test -project BlueX.xcodeproj -scheme BlueX -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/ATProtoProfileDecodingTests 2>&1 | tail -20
```
Expected: PASS — 2 tests

- [ ] **Step 5: Run the full suite**

`ATProtoProfile` is used by the existing snapshot path, so confirm nothing broke.

```bash
xcodebuild test -project BlueX.xcodeproj -scheme BlueX -destination 'platform=macOS,arch=arm64' 2>&1 | tail -20
```
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add BlueX/Services/API/BlueskyStructs.swift BlueXTests/Services/API/ATProtoProfileDecodingTests.swift
git commit -m "feat(api): decode createdAt, description and labels on profiles

createdAt gives account age at time of reply — the throwaway-account
signature. labels is Bluesky's own moderation signal on the account. All
fields optional so ordinary profiles without a bio still decode."
```

---

### Task 3: `PublicProfileAPI` — the unauthenticated client

Deliberately separate from `BlueskyAPIClient`, which was just hardened twice (token refresh, ephemeral session) and whose 400 handling collapses every reason into `.badRequest(message:)`. This subsystem needs the reason code intact, and needs no auth at all.

**Files:**
- Create: `BlueX/Services/API/PublicProfileAPI.swift`
- Test: `BlueXTests/Services/API/PublicProfileAPITests.swift`

**Interfaces:**
- Consumes: `URLSessionProtocol`, `EphemeralHTTPSession.shared`, `ATProtoProfile` (Task 2)
- Produces:
  - `PublicProfileAPI(baseURL:session:)`
  - `func getProfiles(dids: [String]) async -> Result<[ATProtoProfile], String>` — max 25 per call
  - `func getProfileStatus(did: String) async -> AuthorStatusResult` where `enum AuthorStatusResult { case active(ATProtoProfile); case gone(status: AuthorStatus, reason: String); case indeterminate(String) }`
  Tasks 4 and 6 depend on these.

- [ ] **Step 1: Write the failing tests**

```swift
// BlueXTests/Services/API/PublicProfileAPITests.swift
import XCTest
@testable import BlueX

private final class StubSession: URLSessionProtocol, @unchecked Sendable {
    var responses: [(Data, Int)] = []
    private(set) var requestedURLs: [String] = []
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requestedURLs.append(request.url?.absoluteString ?? "")
        let (body, code) = responses.isEmpty ? (Data("{}".utf8), 200) : responses.removeFirst()
        let resp = HTTPURLResponse(url: request.url!, statusCode: code,
                                   httpVersion: nil, headerFields: nil)!
        return (body, resp)
    }
}

final class PublicProfileAPITests: XCTestCase {

    private func api(_ s: StubSession) -> PublicProfileAPI {
        PublicProfileAPI(baseURL: URL(string: "https://public.api.bsky.app/xrpc")!, session: s)
    }

    func testBatchSendsNoAuthorizationHeader() async {
        let s = StubSession()
        s.responses = [(Data(#"{"profiles":[]}"#.utf8), 200)]
        _ = await api(s).getProfiles(dids: ["did:plc:a"])
        XCTAssertTrue(s.requestedURLs.first?.contains("actors=did:plc:a") == true)
    }

    func testBatchReturnsProfiles() async {
        let s = StubSession()
        s.responses = [(Data(#"{"profiles":[{"did":"did:plc:a","handle":"a.bsky.social"}]}"#.utf8), 200)]
        let r = await api(s).getProfiles(dids: ["did:plc:a"])
        guard case .success(let ps) = r else { return XCTFail("expected success, got \(r)") }
        XCTAssertEqual(ps.map(\.did), ["did:plc:a"])
    }

    func testBatchRejectsMoreThan25() async {
        let s = StubSession()
        let r = await api(s).getProfiles(dids: (0..<26).map { "did:plc:\($0)" })
        guard case .failure(let msg) = r else { return XCTFail("expected failure") }
        XCTAssertTrue(msg.contains("25"), "error should name the limit, got: \(msg)")
    }

    // Each reason code must survive to the caller. This is the whole point of not
    // reusing BlueskyAPIClient, which flattens all 400s into one message.
    func testTakedownIsClassified() async {
        let s = StubSession()
        s.responses = [(Data(#"{"error":"AccountTakedown","message":"Account has been taken down"}"#.utf8), 400)]
        let r = await api(s).getProfileStatus(did: "did:plc:a")
        guard case .gone(let status, let reason) = r else { return XCTFail("expected gone, got \(r)") }
        XCTAssertEqual(status, .takedown)
        XCTAssertEqual(reason, "AccountTakedown")
    }

    func testDeactivatedIsClassified() async {
        let s = StubSession()
        s.responses = [(Data(#"{"error":"AccountDeactivated"}"#.utf8), 400)]
        let r = await api(s).getProfileStatus(did: "did:plc:a")
        guard case .gone(let status, _) = r else { return XCTFail("expected gone") }
        XCTAssertEqual(status, .deactivated)
    }

    func testInvalidRequestMeansDeleted() async {
        let s = StubSession()
        s.responses = [(Data(#"{"error":"InvalidRequest","message":"Profile not found"}"#.utf8), 400)]
        let r = await api(s).getProfileStatus(did: "did:plc:a")
        guard case .gone(let status, _) = r else { return XCTFail("expected gone") }
        XCTAssertEqual(status, .deleted)
    }

    // A network blip must NOT be recorded as a deletion. This is the single most
    // important negative case: mistaking flakiness for moderation would corrupt
    // every downstream takedown statistic.
    func testServerErrorIsIndeterminateNotDeleted() async {
        let s = StubSession()
        s.responses = [(Data("upstream failure".utf8), 502)]
        let r = await api(s).getProfileStatus(did: "did:plc:a")
        guard case .indeterminate = r else { return XCTFail("502 must be indeterminate, got \(r)") }
    }

    func testUnrecognisedErrorCodeIsIndeterminate() async {
        let s = StubSession()
        s.responses = [(Data(#"{"error":"SomethingNewFromBluesky"}"#.utf8), 400)]
        let r = await api(s).getProfileStatus(did: "did:plc:a")
        guard case .indeterminate(let m) = r else { return XCTFail("expected indeterminate") }
        XCTAssertTrue(m.contains("SomethingNewFromBluesky"), "must preserve the unknown code")
    }
}
```

- [ ] **Step 2: Run to see them fail**

```bash
xcodegen generate && xcodebuild test -project BlueX.xcodeproj -scheme BlueX \
  -destination 'platform=macOS,arch=arm64' -only-testing:BlueXTests/PublicProfileAPITests 2>&1 | tail -20
```
Expected: FAIL — `cannot find 'PublicProfileAPI' in scope`

- [ ] **Step 3: Implement it**

```swift
// BlueX/Services/API/PublicProfileAPI.swift
import Foundation

/// Outcome of asking the public API about one account.
enum AuthorStatusResult: Equatable {
    case active(ATProtoProfile)
    /// The account is gone and the platform told us why.
    case gone(status: AuthorStatus, reason: String)
    /// We could not determine anything — a network error, a 5xx, or an error code we
    /// do not recognise. NEVER treat this as removal: mistaking flakiness for
    /// moderation would corrupt every takedown statistic downstream.
    case indeterminate(String)

    static func == (l: AuthorStatusResult, r: AuthorStatusResult) -> Bool {
        switch (l, r) {
        case let (.active(a), .active(b)): return a.did == b.did
        case let (.gone(s1, r1), .gone(s2, r2)): return s1 == s2 && r1 == r2
        case let (.indeterminate(a), .indeterminate(b)): return a == b
        default: return false
        }
    }
}

/// Unauthenticated client for `public.api.bsky.app`.
///
/// Separate from `BlueskyAPIClient` on purpose:
///   - it needs **no token**, so this whole subsystem never touches the Keychain
///   - it must preserve the specific 400 error code (`AccountTakedown` vs
///     `AccountDeactivated` vs `InvalidRequest`), which `BlueskyAPIClient.perform`
///     flattens into a single `.badRequest(message:)`
struct PublicProfileAPI {
    /// getProfiles accepts at most 25 actors per call.
    static let maxBatchSize = 25

    private let baseURL: URL
    private let session: URLSessionProtocol

    init(baseURL: URL = URL(string: "https://public.api.bsky.app/xrpc")!,
         session: URLSessionProtocol = EphemeralHTTPSession.shared) {
        self.baseURL = baseURL
        self.session = session
    }

    private struct ProfilesResponse: Decodable { let profiles: [ATProtoProfile] }
    private struct ErrorBody: Decodable { let error: String?; let message: String? }

    /// Fetch up to 25 profiles. Accounts that are gone are **silently omitted** from the
    /// response — there is no per-actor error — so the caller must diff requested
    /// against returned. See `AuthorProbe.missingDIDs`.
    func getProfiles(dids: [String]) async -> Result<[ATProtoProfile], String> {
        guard !dids.isEmpty else { return .success([]) }
        guard dids.count <= Self.maxBatchSize else {
            return .failure("getProfiles accepts at most \(Self.maxBatchSize) actors, got \(dids.count)")
        }
        guard var c = URLComponents(url: baseURL.appendingPathComponent("app.bsky.actor.getProfiles"),
                                    resolvingAgainstBaseURL: false) else {
            return .failure("could not build getProfiles URL")
        }
        c.queryItems = dids.map { URLQueryItem(name: "actors", value: $0) }
        guard let url = c.url else { return .failure("could not build getProfiles URL") }

        do {
            let (data, resp) = try await session.data(for: URLRequest(url: url))
            guard let http = resp as? HTTPURLResponse else { return .failure("non-HTTP response") }
            guard http.statusCode == 200 else { return .failure("HTTP \(http.statusCode)") }
            return .success(try JSONDecoder().decode(ProfilesResponse.self, from: data).profiles)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// Ask about one account, preserving the reason it is gone.
    func getProfileStatus(did: String) async -> AuthorStatusResult {
        guard var c = URLComponents(url: baseURL.appendingPathComponent("app.bsky.actor.getProfile"),
                                    resolvingAgainstBaseURL: false) else {
            return .indeterminate("could not build getProfile URL")
        }
        c.queryItems = [URLQueryItem(name: "actor", value: did)]
        guard let url = c.url else { return .indeterminate("could not build getProfile URL") }

        do {
            let (data, resp) = try await session.data(for: URLRequest(url: url))
            guard let http = resp as? HTTPURLResponse else { return .indeterminate("non-HTTP response") }
            if http.statusCode == 200 {
                return .active(try JSONDecoder().decode(ATProtoProfile.self, from: data))
            }
            // Only a 400 carries a meaningful reason. 5xx and anything else is a
            // transport problem, not a statement about the account.
            guard http.statusCode == 400 else { return .indeterminate("HTTP \(http.statusCode)") }
            let code = (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error ?? ""
            switch code {
            case "AccountTakedown":    return .gone(status: .takedown, reason: code)
            case "AccountDeactivated": return .gone(status: .deactivated, reason: code)
            case "InvalidRequest":     return .gone(status: .deleted, reason: code)
            default:
                // Preserve the unrecognised code verbatim rather than guessing. A new
                // Bluesky error should surface as unknown, not be mapped to deleted.
                return .indeterminate("unrecognised error code: \(code)")
            }
        } catch {
            return .indeterminate(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodebuild test -project BlueX.xcodeproj -scheme BlueX -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/PublicProfileAPITests 2>&1 | tail -20
```
Expected: PASS — 8 tests

- [ ] **Step 5: Commit**

```bash
git add BlueX/Services/API/PublicProfileAPI.swift BlueXTests/Services/API/PublicProfileAPITests.swift BlueX.xcodeproj
git commit -m "feat(api): unauthenticated PublicProfileAPI preserving removal reasons

Separate from BlueskyAPIClient because it needs no token — so this subsystem
never touches the Keychain — and because BlueskyAPIClient flattens every 400
into one message, losing the AccountTakedown / AccountDeactivated /
InvalidRequest distinction this work exists to capture.

A 5xx or an unrecognised code is indeterminate, never 'deleted': mistaking
flakiness for moderation would corrupt every takedown statistic."
```

---

### Task 4: `AuthorProbe` — pure batching and classification

**Files:**
- Create: `BlueX/Services/Authors/AuthorProbe.swift`
- Test: `BlueXTests/Services/Authors/AuthorProbeTests.swift`

**Interfaces:**
- Consumes: `PublicProfileAPI`, `ATProtoProfile`, `AuthorStatus`, `AuthorStatusResult` (Tasks 1–3)
- Produces:
  - `struct ProbedAuthor { let did: String; let status: AuthorStatus; let reason: String?; let profile: ATProtoProfile? }`
  - `static func chunk(_ dids: [String], size: Int) -> [[String]]`
  - `static func missingDIDs(requested: [String], returned: [ATProtoProfile]) -> [String]`
  - `func probe(dids: [String]) async -> [ProbedAuthor]`
  Task 6 consumes all of these.

- [ ] **Step 1: Write the failing tests**

```swift
// BlueXTests/Services/Authors/AuthorProbeTests.swift
import XCTest
@testable import BlueX

private final class ScriptedSession: URLSessionProtocol, @unchecked Sendable {
    var batch: [String: [String]] = [:]      // joined dids -> handles to return
    var single: [String: (Data, Int)] = [:]  // did -> (body, status)
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!.absoluteString
        func http(_ code: Int) -> URLResponse {
            HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
        }
        if url.contains("getProfiles") {
            let comps = URLComponents(string: url)!
            let dids = comps.queryItems?.filter { $0.name == "actors" }.compactMap(\.value) ?? []
            let present = dids.filter { batch.keys.contains($0) }
            let objs = present.map { #"{"did":"\#($0)","handle":"\#(batch[$0]!.first ?? "h")"}"# }
            return (Data(#"{"profiles":[\#(objs.joined(separator: ","))]}"#.utf8), http(200))
        }
        let comps = URLComponents(string: url)!
        let did = comps.queryItems?.first(where: { $0.name == "actor" })?.value ?? ""
        let (body, code) = single[did] ?? (Data(#"{"error":"InvalidRequest"}"#.utf8), 400)
        return (body, http(code))
    }
}

final class AuthorProbeTests: XCTestCase {

    func testChunkRespectsBatchLimit() {
        let dids = (0..<53).map { "did:plc:\($0)" }
        let chunks = AuthorProbe.chunk(dids, size: 25)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].count, 25)
        XCTAssertEqual(chunks[2].count, 3)
        XCTAssertEqual(chunks.flatMap { $0 }, dids, "chunking must not lose or reorder DIDs")
    }

    func testMissingDIDsIsTheDeletionSignal() {
        let requested = ["did:plc:a", "did:plc:b", "did:plc:c"]
        let returned = [ATProtoProfile(did: "did:plc:a", handle: "a", displayName: nil, avatar: nil,
                                       followersCount: nil, followsCount: nil, postsCount: nil,
                                       description: nil, createdAt: nil, labels: nil)]
        XCTAssertEqual(AuthorProbe.missingDIDs(requested: requested, returned: returned),
                       ["did:plc:b", "did:plc:c"])
    }

    func testPresentAccountsAreActiveWithoutASecondCall() async {
        let s = ScriptedSession()
        s.batch = ["did:plc:a": ["a.bsky.social"]]
        let probe = AuthorProbe(api: PublicProfileAPI(session: s))
        let out = await probe.probe(dids: ["did:plc:a"])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].status, .active)
        XCTAssertEqual(out[0].profile?.handle, "a.bsky.social")
        XCTAssertNil(out[0].reason)
    }

    func testAbsentAccountGetsReasonLookup() async {
        let s = ScriptedSession()
        s.batch = [:]  // nothing returned -> absent
        s.single = ["did:plc:a": (Data(#"{"error":"AccountTakedown"}"#.utf8), 400)]
        let probe = AuthorProbe(api: PublicProfileAPI(session: s))
        let out = await probe.probe(dids: ["did:plc:a"])
        XCTAssertEqual(out[0].status, .takedown)
        XCTAssertEqual(out[0].reason, "AccountTakedown")
    }

    // The critical negative: an absence we cannot explain must be `unknown`,
    // never `deleted`.
    func testUnexplainedAbsenceIsUnknown() async {
        let s = ScriptedSession()
        s.batch = [:]
        s.single = ["did:plc:a": (Data("gateway timeout".utf8), 504)]
        let probe = AuthorProbe(api: PublicProfileAPI(session: s))
        let out = await probe.probe(dids: ["did:plc:a"])
        XCTAssertEqual(out[0].status, .unknown, "a 504 is not evidence of removal")
    }

    func testMixedBatchClassifiesEachIndependently() async {
        let s = ScriptedSession()
        s.batch = ["did:plc:a": ["a.bsky.social"]]
        s.single = ["did:plc:b": (Data(#"{"error":"AccountDeactivated"}"#.utf8), 400)]
        let probe = AuthorProbe(api: PublicProfileAPI(session: s))
        let out = await probe.probe(dids: ["did:plc:a", "did:plc:b"])
        let byDID = Dictionary(uniqueKeysWithValues: out.map { ($0.did, $0.status) })
        XCTAssertEqual(byDID["did:plc:a"], .active)
        XCTAssertEqual(byDID["did:plc:b"], .deactivated)
    }
}
```

- [ ] **Step 2: Run to see them fail**

```bash
xcodegen generate && xcodebuild test -project BlueX.xcodeproj -scheme BlueX \
  -destination 'platform=macOS,arch=arm64' -only-testing:BlueXTests/AuthorProbeTests 2>&1 | tail -20
```
Expected: FAIL — `cannot find 'AuthorProbe' in scope`

- [ ] **Step 3: Implement it**

```swift
// BlueX/Services/Authors/AuthorProbe.swift
import Foundation

/// The result of probing one account. Pure data — no SwiftData involvement, so the
/// batching and classification logic is unit-testable without a store. This is the same
/// split that made `ScrapeSession` testable after the token-refresh bug proved
/// untestable inside `runCLI()`.
struct ProbedAuthor {
    let did: String
    let status: AuthorStatus
    /// Raw API error code when not active; nil when active.
    let reason: String?
    /// Present only when the account is active.
    let profile: ATProtoProfile?
}

/// Turns a list of DIDs into classified outcomes.
///
/// Two stages, because the API forces it: `getProfiles` returns up to 25 profiles and
/// **silently omits** accounts that are gone — there is no per-actor error. The omission
/// is the signal; the reason needs a second, single-actor call.
struct AuthorProbe {
    private let api: PublicProfileAPI
    /// Pause between calls. Politeness, not correctness — the public API is
    /// unauthenticated and shared.
    private let pauseNanoseconds: UInt64
    private let sleeper: @Sendable (UInt64) async -> Void

    init(api: PublicProfileAPI = PublicProfileAPI(),
         pauseNanoseconds: UInt64 = 1_000_000_000,
         sleeper: @escaping @Sendable (UInt64) async -> Void = { ns in
             try? await Task.sleep(nanoseconds: ns)
         }) {
        self.api = api
        self.pauseNanoseconds = pauseNanoseconds
        self.sleeper = sleeper
    }

    static func chunk(_ dids: [String], size: Int = PublicProfileAPI.maxBatchSize) -> [[String]] {
        guard size > 0 else { return [dids] }
        return stride(from: 0, to: dids.count, by: size).map {
            Array(dids[$0..<min($0 + size, dids.count)])
        }
    }

    /// DIDs asked for but not returned. This difference IS the deletion signal.
    static func missingDIDs(requested: [String], returned: [ATProtoProfile]) -> [String] {
        let got = Set(returned.map(\.did))
        return requested.filter { !got.contains($0) }
    }

    func probe(dids: [String]) async -> [ProbedAuthor] {
        var out: [ProbedAuthor] = []
        for batch in Self.chunk(dids) {
            switch await api.getProfiles(dids: batch) {
            case .success(let profiles):
                for p in profiles {
                    out.append(ProbedAuthor(did: p.did, status: .active, reason: nil, profile: p))
                }
                for did in Self.missingDIDs(requested: batch, returned: profiles) {
                    out.append(await classifyAbsent(did))
                }
            case .failure:
                // The whole batch failed — a transport problem, not a statement about
                // any account. Record every DID as unknown so nothing is misread as
                // removal, and let the runner leave their stored status untouched.
                for did in batch {
                    out.append(ProbedAuthor(did: did, status: .unknown,
                                            reason: nil, profile: nil))
                }
            }
            if pauseNanoseconds > 0 { await sleeper(pauseNanoseconds) }
        }
        return out
    }

    private func classifyAbsent(_ did: String) async -> ProbedAuthor {
        switch await api.getProfileStatus(did: did) {
        case .active(let p):
            // Raced with a re-activation, or the batch dropped it spuriously.
            return ProbedAuthor(did: did, status: .active, reason: nil, profile: p)
        case .gone(let status, let reason):
            return ProbedAuthor(did: did, status: status, reason: reason, profile: nil)
        case .indeterminate(let message):
            return ProbedAuthor(did: did, status: .unknown, reason: message, profile: nil)
        }
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodebuild test -project BlueX.xcodeproj -scheme BlueX -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/AuthorProbeTests 2>&1 | tail -20
```
Expected: PASS — 6 tests

- [ ] **Step 5: Commit**

```bash
git add BlueX/Services/Authors/AuthorProbe.swift BlueXTests/Services/Authors/AuthorProbeTests.swift BlueX.xcodeproj
git commit -m "feat(authors): AuthorProbe — batching, absence diff, classification

getProfiles silently omits accounts that are gone, so the requested-vs-returned
difference is the deletion signal; the reason needs a second single-actor call.
Pure logic with no store access so it is testable without SwiftData.

An unexplained absence is 'unknown', never 'deleted'."
```

---

### Task 5: `AuthorBackfill` — populate authors from existing replies

**Files:**
- Create: `BlueX/Services/Authors/AuthorBackfill.swift`
- Test: `BlueXTests/Services/Authors/AuthorBackfillTests.swift`

**Interfaces:**
- Consumes: `ReplyAuthor` (Task 1), `Post`
- Produces: `AuthorBackfill(container:)` with `@discardableResult func run(batchSize: Int = 500) throws -> (created: Int, updated: Int)`. Task 7 calls it.

- [ ] **Step 1: Write the failing tests**

```swift
// BlueXTests/Services/Authors/AuthorBackfillTests.swift
import XCTest
import SwiftData
@testable import BlueX

final class AuthorBackfillTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Post.self, Annotation.self, TrackedAccount.self, AccountGroup.self,
            ScrapeLog.self, CoordinatorState.self, AccountSnapshot.self, ModelConfig.self,
            ReplyAuthor.self, AuthorObservation.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func addReply(_ ctx: ModelContext, uri: String, did: String, at t: TimeInterval) {
        let p = Post(uri: uri, text: "hi", createdAt: Date(timeIntervalSince1970: t),
                     authorDID: did, authorHandle: "\(did).handle",
                     parentURI: "at://root", rootURI: "at://root",
                     isRootPost: false, depth: 1)
        ctx.insert(p)
    }

    func testCreatesOneAuthorPerDIDWithSeenRange() throws {
        let c = try makeContainer(); let ctx = ModelContext(c)
        addReply(ctx, uri: "at://1", did: "did:plc:a", at: 100)
        addReply(ctx, uri: "at://2", did: "did:plc:a", at: 300)
        addReply(ctx, uri: "at://3", did: "did:plc:b", at: 200)
        try ctx.save()

        let r = try AuthorBackfill(container: c).run(batchSize: 2)
        XCTAssertEqual(r.created, 2)

        let fresh = ModelContext(c)
        let authors = try fresh.fetch(FetchDescriptor<ReplyAuthor>()).sorted { $0.did < $1.did }
        XCTAssertEqual(authors.map(\.did), ["did:plc:a", "did:plc:b"])
        XCTAssertEqual(authors[0].firstSeenAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(authors[0].lastSeenAt, Date(timeIntervalSince1970: 300))
    }

    func testIgnoresRootPosts() throws {
        let c = try makeContainer(); let ctx = ModelContext(c)
        let root = Post(uri: "at://root", text: "news", createdAt: Date(),
                        authorDID: "did:plc:outlet", authorHandle: "nytimes.com",
                        parentURI: nil, rootURI: "at://root", isRootPost: true, depth: 0)
        ctx.insert(root)
        try ctx.save()
        let r = try AuthorBackfill(container: c).run()
        XCTAssertEqual(r.created, 0, "tracked outlets are not reply authors")
    }

    func testIsIdempotentAndExtendsRange() throws {
        let c = try makeContainer(); let ctx = ModelContext(c)
        addReply(ctx, uri: "at://1", did: "did:plc:a", at: 100)
        try ctx.save()
        _ = try AuthorBackfill(container: c).run()

        let ctx2 = ModelContext(c)
        addReply(ctx2, uri: "at://2", did: "did:plc:a", at: 400)
        try ctx2.save()
        let second = try AuthorBackfill(container: c).run()

        XCTAssertEqual(second.created, 0, "existing author must not be duplicated")
        XCTAssertEqual(second.updated, 1)
        let fresh = ModelContext(c)
        let authors = try fresh.fetch(FetchDescriptor<ReplyAuthor>())
        XCTAssertEqual(authors.count, 1)
        XCTAssertEqual(authors[0].lastSeenAt, Date(timeIntervalSince1970: 400))
    }
}
```

- [ ] **Step 2: Run to see them fail**

```bash
xcodegen generate && xcodebuild test -project BlueX.xcodeproj -scheme BlueX \
  -destination 'platform=macOS,arch=arm64' -only-testing:BlueXTests/AuthorBackfillTests 2>&1 | tail -20
```
Expected: FAIL — `cannot find 'AuthorBackfill' in scope`

- [ ] **Step 3: Implement it**

```swift
// BlueX/Services/Authors/AuthorBackfill.swift
import Foundation
import SwiftData

/// Creates one `ReplyAuthor` per distinct reply-author DID, and keeps `firstSeenAt` /
/// `lastSeenAt` current as the corpus grows.
///
/// Pages over `Post` with a fresh `ModelContext` per page. The store holds ~842k reply
/// rows; a single long-lived context would register all of them and exhaust memory —
/// the same failure that made the original NLTagger pass unable to finish a backfill.
struct AuthorBackfill {
    private let container: ModelContainer

    init(container: ModelContainer) { self.container = container }

    @discardableResult
    func run(batchSize: Int = 500) throws -> (created: Int, updated: Int) {
        // Existing authors, keyed by DID. Small relative to the post table (~146k), so
        // one fetch is far cheaper than a per-post lookup.
        let index = ModelContext(container)
        var known: [String: (first: Date, last: Date)] = [:]
        for a in try index.fetch(FetchDescriptor<ReplyAuthor>()) {
            known[a.did] = (a.firstSeenAt, a.lastSeenAt)
        }

        // Fold the corpus down to one row per DID before touching the store.
        var seen: [String: (first: Date, last: Date)] = [:]
        let total = try index.fetchCount(FetchDescriptor<Post>())
        var offset = 0
        while offset < total {
            let ctx = ModelContext(container)
            var page = FetchDescriptor<Post>(sortBy: [SortDescriptor(\Post.uri)])
            page.fetchOffset = offset
            page.fetchLimit = batchSize
            let posts = try ctx.fetch(page)
            if posts.isEmpty { break }
            offset += posts.count
            for p in posts where !p.isRootPost {
                let d = p.authorDID
                if let cur = seen[d] {
                    seen[d] = (min(cur.first, p.createdAt), max(cur.last, p.createdAt))
                } else {
                    seen[d] = (p.createdAt, p.createdAt)
                }
            }
        }

        var created = 0, updated = 0
        let write = ModelContext(container)
        let existing = try write.fetch(FetchDescriptor<ReplyAuthor>())
        var byDID = Dictionary(uniqueKeysWithValues: existing.map { ($0.did, $0) })

        for (did, range) in seen {
            if let a = byDID[did] {
                let newFirst = min(a.firstSeenAt, range.first)
                let newLast = max(a.lastSeenAt, range.last)
                if newFirst != a.firstSeenAt || newLast != a.lastSeenAt {
                    a.firstSeenAt = newFirst
                    a.lastSeenAt = newLast
                    updated += 1
                }
            } else {
                let a = ReplyAuthor(did: did, firstSeenAt: range.first, lastSeenAt: range.last)
                write.insert(a)
                byDID[did] = a
                created += 1
            }
        }
        try write.save()
        return (created, updated)
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodebuild test -project BlueX.xcodeproj -scheme BlueX -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/AuthorBackfillTests 2>&1 | tail -20
```
Expected: PASS — 3 tests

- [ ] **Step 5: Commit**

```bash
git add BlueX/Services/Authors/AuthorBackfill.swift BlueXTests/Services/Authors/AuthorBackfillTests.swift BlueX.xcodeproj
git commit -m "feat(authors): backfill ReplyAuthor from existing replies

Pages over Post with a fresh context per page — a single long-lived context
would register all ~842k reply rows, the same failure that stopped the original
NLTagger backfill from ever completing. Idempotent: re-running extends the
seen-range rather than duplicating authors."
```

---

### Task 6: `AuthorProbeRunner` — write-on-change persistence

**Files:**
- Create: `BlueX/Services/Authors/AuthorProbeRunner.swift`
- Test: `BlueXTests/Services/Authors/AuthorProbeRunnerTests.swift`

**Interfaces:**
- Consumes: `AuthorProbe`, `ProbedAuthor`, `ReplyAuthor`, `AuthorObservation`, `AuthorStatus`
- Produces: `AuthorProbeRunner(container:probe:now:)` with `func run(limit: Int?, staleAfter: TimeInterval) async throws -> RunSummary`, and `struct RunSummary { let probed: Int; let observationsWritten: Int; let unknown: Int }`. Task 7 calls it.

- [ ] **Step 1: Write the failing tests**

```swift
// BlueXTests/Services/Authors/AuthorProbeRunnerTests.swift
import XCTest
import SwiftData
@testable import BlueX

private final class FakeSession: URLSessionProtocol, @unchecked Sendable {
    var activeHandles: [String: String] = [:]   // did -> handle
    var labelsFor: [String: String] = [:]       // did -> label val
    var goneCode: [String: String] = [:]        // did -> error code
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url!.absoluteString
        let comps = URLComponents(string: url)!
        func http(_ c: Int) -> URLResponse {
            HTTPURLResponse(url: request.url!, statusCode: c, httpVersion: nil, headerFields: nil)!
        }
        if url.contains("getProfiles") {
            let dids = comps.queryItems?.filter { $0.name == "actors" }.compactMap(\.value) ?? []
            let objs = dids.compactMap { d -> String? in
                guard let h = activeHandles[d] else { return nil }
                let lab = labelsFor[d].map { #","labels":[{"val":"\#($0)"}]"# } ?? ""
                return #"{"did":"\#(d)","handle":"\#(h)","followersCount":5\#(lab)}"#
            }
            return (Data(#"{"profiles":[\#(objs.joined(separator: ","))]}"#.utf8), http(200))
        }
        let did = comps.queryItems?.first(where: { $0.name == "actor" })?.value ?? ""
        let code = goneCode[did] ?? "InvalidRequest"
        return (Data(#"{"error":"\#(code)"}"#.utf8), http(400))
    }
}

final class AuthorProbeRunnerTests: XCTestCase {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Post.self, Annotation.self, TrackedAccount.self, AccountGroup.self,
            ScrapeLog.self, CoordinatorState.self, AccountSnapshot.self, ModelConfig.self,
            ReplyAuthor.self, AuthorObservation.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    private func seed(_ c: ModelContainer, dids: [String]) throws {
        let ctx = ModelContext(c)
        for d in dids { ctx.insert(ReplyAuthor(did: d, firstSeenAt: Date(), lastSeenAt: Date())) }
        try ctx.save()
    }

    private func runner(_ c: ModelContainer, _ s: FakeSession, now: Date = Date()) -> AuthorProbeRunner {
        AuthorProbeRunner(
            container: c,
            probe: AuthorProbe(api: PublicProfileAPI(session: s), pauseNanoseconds: 0),
            now: { now }
        )
    }

    func testFirstProbeWritesBaselineObservation() async throws {
        let c = try makeContainer(); try seed(c, dids: ["did:plc:a"])
        let s = FakeSession(); s.activeHandles = ["did:plc:a": "a.bsky.social"]
        let sum = try await runner(c, s).run(limit: nil, staleAfter: 0)
        XCTAssertEqual(sum.probed, 1)
        XCTAssertEqual(sum.observationsWritten, 1)

        let fresh = ModelContext(c)
        let a = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ReplyAuthor>()).first)
        XCTAssertEqual(a.currentStatus, "active")
        XCTAssertEqual(a.currentHandle, "a.bsky.social")
        XCTAssertNotNil(a.lastProbedAt)
        XCTAssertEqual(a.observations.count, 1)
    }

    // The core of the design: an unchanged profile must not add a row.
    func testUnchangedProfileWritesNoSecondObservation() async throws {
        let c = try makeContainer(); try seed(c, dids: ["did:plc:a"])
        let s = FakeSession(); s.activeHandles = ["did:plc:a": "a.bsky.social"]
        _ = try await runner(c, s).run(limit: nil, staleAfter: 0)
        let sum = try await runner(c, s).run(limit: nil, staleAfter: 0)
        XCTAssertEqual(sum.observationsWritten, 0)
        let fresh = ModelContext(c)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<AuthorObservation>()).count, 1)
    }

    func testHandleChangeWritesObservation() async throws {
        let c = try makeContainer(); try seed(c, dids: ["did:plc:a"])
        let s = FakeSession(); s.activeHandles = ["did:plc:a": "old.bsky.social"]
        _ = try await runner(c, s).run(limit: nil, staleAfter: 0)
        s.activeHandles = ["did:plc:a": "new.bsky.social"]
        let sum = try await runner(c, s).run(limit: nil, staleAfter: 0)
        XCTAssertEqual(sum.observationsWritten, 1, "a handle change is an evasion signal — record it")
    }

    func testLabelChangeWritesObservation() async throws {
        let c = try makeContainer(); try seed(c, dids: ["did:plc:a"])
        let s = FakeSession(); s.activeHandles = ["did:plc:a": "a.bsky.social"]
        _ = try await runner(c, s).run(limit: nil, staleAfter: 0)
        s.labelsFor = ["did:plc:a": "!warn"]
        let sum = try await runner(c, s).run(limit: nil, staleAfter: 0)
        XCTAssertEqual(sum.observationsWritten, 1)
    }

    func testTakedownTransitionIsRecordedWithNilCounts() async throws {
        let c = try makeContainer(); try seed(c, dids: ["did:plc:a"])
        let s = FakeSession(); s.activeHandles = ["did:plc:a": "a.bsky.social"]
        _ = try await runner(c, s).run(limit: nil, staleAfter: 0)
        s.activeHandles = [:]                       // now absent from the batch
        s.goneCode = ["did:plc:a": "AccountTakedown"]
        _ = try await runner(c, s).run(limit: nil, staleAfter: 0)

        let fresh = ModelContext(c)
        let a = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ReplyAuthor>()).first)
        XCTAssertEqual(a.currentStatus, "takedown")
        let newest = a.observations.max { $0.observedAt < $1.observedAt }
        XCTAssertEqual(newest?.statusReason, "AccountTakedown")
        XCTAssertNil(newest?.followersCount, "a removed account has no counts; 0 would be a lie")
    }

    // An indeterminate result must not overwrite a known-good status.
    func testUnknownDoesNotClobberAKnownStatus() async throws {
        let c = try makeContainer(); try seed(c, dids: ["did:plc:a"])
        let s = FakeSession(); s.activeHandles = ["did:plc:a": "a.bsky.social"]
        _ = try await runner(c, s).run(limit: nil, staleAfter: 0)

        final class FailingSession: URLSessionProtocol, @unchecked Sendable {
            func data(for r: URLRequest) async throws -> (Data, URLResponse) {
                (Data("boom".utf8),
                 HTTPURLResponse(url: r.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
            }
        }
        let bad = AuthorProbeRunner(
            container: c,
            probe: AuthorProbe(api: PublicProfileAPI(session: FailingSession()), pauseNanoseconds: 0),
            now: { Date() }
        )
        let sum = try await bad.run(limit: nil, staleAfter: 0)
        XCTAssertEqual(sum.unknown, 1)
        XCTAssertEqual(sum.observationsWritten, 0)
        let fresh = ModelContext(c)
        let a = try XCTUnwrap(try fresh.fetch(FetchDescriptor<ReplyAuthor>()).first)
        XCTAssertEqual(a.currentStatus, "active", "a 503 must not downgrade a known status")
    }

    // The spec tiers gone accounts to a slower cadence: they rarely change, but
    // deactivation is reversible so they must still be re-checked eventually.
    func testGoneAccountsUseTheSlowerCadence() async throws {
        let c = try makeContainer(); try seed(c, dids: ["did:plc:a"])
        let s = FakeSession(); s.goneCode = ["did:plc:a": "AccountTakedown"]
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = try await runner(c, s, now: t0).run(limit: nil, staleAfter: 0)

        // 8 days later: due under the 6-day active window, NOT due under the 24-day
        // gone window.
        let later = t0.addingTimeInterval(8 * 86400)
        let skipped = try await runner(c, s, now: later)
            .run(limit: nil, staleAfter: 6 * 86400)
        XCTAssertEqual(skipped.probed, 0, "a known-takedown account is not due weekly")

        // 30 days later: past the gone window, so it is re-checked.
        let muchLater = t0.addingTimeInterval(30 * 86400)
        let rechecked = try await runner(c, s, now: muchLater)
            .run(limit: nil, staleAfter: 6 * 86400)
        XCTAssertEqual(rechecked.probed, 1, "gone accounts must still be re-checked eventually")
    }

    func testStaleAfterSkipsRecentlyProbedAuthors() async throws {
        let c = try makeContainer(); try seed(c, dids: ["did:plc:a"])
        let s = FakeSession(); s.activeHandles = ["did:plc:a": "a.bsky.social"]
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        _ = try await runner(c, s, now: t0).run(limit: nil, staleAfter: 0)
        // one hour later, with a 7-day staleness window -> nothing due
        let sum = try await runner(c, s, now: t0.addingTimeInterval(3600))
            .run(limit: nil, staleAfter: 7 * 86400)
        XCTAssertEqual(sum.probed, 0)
    }
}
```

- [ ] **Step 2: Run to see them fail**

```bash
xcodegen generate && xcodebuild test -project BlueX.xcodeproj -scheme BlueX \
  -destination 'platform=macOS,arch=arm64' -only-testing:BlueXTests/AuthorProbeRunnerTests 2>&1 | tail -20
```
Expected: FAIL — `cannot find 'AuthorProbeRunner' in scope`

- [ ] **Step 3: Implement it**

```swift
// BlueX/Services/Authors/AuthorProbeRunner.swift
import Foundation
import SwiftData

/// Drives `AuthorProbe` over the stored authors and persists the results.
///
/// Write-on-change is the whole point: snapshotting 146k authors weekly would be ~7.6M
/// rows a year, ~99% identical. Only these fields count as change — status, handle,
/// labels, displayName, bio, accountCreatedAt. Counts deliberately do NOT, because
/// follower numbers drift continuously and would rewrite the population every sweep.
struct AuthorProbeRunner {
    struct RunSummary {
        let probed: Int
        let observationsWritten: Int
        /// Authors whose status could not be determined this run. Their stored status
        /// is left untouched.
        let unknown: Int
    }

    private let container: ModelContainer
    private let probe: AuthorProbe
    private let now: () -> Date

    init(container: ModelContainer,
         probe: AuthorProbe = AuthorProbe(),
         now: @escaping () -> Date = { Date() }) {
        self.container = container
        self.probe = probe
        self.now = now
    }

    /// - Parameters:
    ///   - limit: stop after this many authors. nil means all due.
    ///   - staleAfter: an active or never-probed author is due when last probed longer
    ///     ago than this.
    ///   - staleAfterGone: authors already known takedown/deactivated/deleted are
    ///     re-checked on this slower cadence — they rarely change, but deactivation IS
    ///     reversible, so they must not be written off permanently. Defaults to 4x
    ///     `staleAfter`, matching the spec's "every 4th sweep".
    func run(limit: Int?,
             staleAfter: TimeInterval,
             staleAfterGone: TimeInterval? = nil) async throws -> RunSummary {
        let ctx = ModelContext(container)
        let goneWindow = staleAfterGone ?? (staleAfter * 4)
        let activeCutoff = now().addingTimeInterval(-staleAfter)
        let goneCutoff = now().addingTimeInterval(-goneWindow)
        let goneStatuses: Set<String> = [
            AuthorStatus.takedown.rawValue,
            AuthorStatus.deactivated.rawValue,
            AuthorStatus.deleted.rawValue,
        ]
        let due = try ctx.fetch(FetchDescriptor<ReplyAuthor>())
            .filter { a in
                guard let last = a.lastProbedAt else { return true }   // never probed
                return goneStatuses.contains(a.currentStatus) ? last <= goneCutoff
                                                              : last <= activeCutoff
            }
            .prefix(limit ?? Int.max)
        guard !due.isEmpty else { return RunSummary(probed: 0, observationsWritten: 0, unknown: 0) }

        let byDID = Dictionary(uniqueKeysWithValues: due.map { ($0.did, $0) })
        let results = await probe.probe(dids: Array(byDID.keys))

        var written = 0, unknown = 0
        let stamp = now()
        for r in results {
            guard let author = byDID[r.did] else { continue }
            author.lastProbedAt = stamp

            if r.status == .unknown {
                // Could not determine anything. Leave currentStatus and currentHandle
                // alone — a transport failure is not evidence about the account.
                unknown += 1
                continue
            }

            let candidate = observation(from: r, at: stamp)
            let newest = author.observations.max { $0.observedAt < $1.observedAt }
            if changed(newest, candidate) {
                ctx.insert(candidate)
                candidate.author = author
                written += 1
            }
            author.currentStatus = r.status.rawValue
            if let h = r.profile?.handle { author.currentHandle = h }
        }
        try ctx.save()
        return RunSummary(probed: results.count, observationsWritten: written, unknown: unknown)
    }

    private func observation(from r: ProbedAuthor, at stamp: Date) -> AuthorObservation {
        let o = AuthorObservation(observedAt: stamp, status: r.status.rawValue)
        o.statusReason = r.reason
        guard let p = r.profile else {
            // Gone: no counts, no profile text. Everything stays nil, which is the
            // honest representation — 0 followers would be indistinguishable from a
            // real account with no followers.
            return o
        }
        o.handle = p.handle
        o.displayName = p.displayName
        o.profileDescription = p.description
        o.followersCount = p.followersCount
        o.followsCount = p.followsCount
        o.postsCount = p.postsCount
        o.hasAvatar = (p.avatar != nil)
        // "" means observed-with-none; nil means not observed. The distinction matters
        // when counting labelled accounts.
        o.labels = (p.labels ?? []).map(\.val).sorted().joined(separator: ",")
        o.accountCreatedAt = p.createdAt.flatMap { ISO8601DateFormatter.parseBluesky($0) }
        return o
    }

    /// Material change only. Counts are excluded on purpose — see the type comment.
    private func changed(_ old: AuthorObservation?, _ new: AuthorObservation) -> Bool {
        guard let old else { return true }
        return old.status != new.status
            || old.handle != new.handle
            || old.labels != new.labels
            || old.displayName != new.displayName
            || old.profileDescription != new.profileDescription
            || old.accountCreatedAt != new.accountCreatedAt
    }
}

extension ISO8601DateFormatter {
    /// Bluesky timestamps usually carry fractional seconds ("2024-11-13T01:24:48.408Z"),
    /// which the default configuration rejects — but not universally, so both forms
    /// must parse. A dropped date silently removes account age from the analysis.
    static let blueskyFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let blueskyPlain = ISO8601DateFormatter()

    static func parseBluesky(_ s: String) -> Date? {
        blueskyFractional.date(from: s) ?? blueskyPlain.date(from: s)
    }
}
```

- [ ] **Step 4: Run the tests**

```bash
xcodebuild test -project BlueX.xcodeproj -scheme BlueX -destination 'platform=macOS,arch=arm64' \
  -only-testing:BlueXTests/AuthorProbeRunnerTests 2>&1 | tail -20
```
Expected: PASS — 8 tests

Note the date parsing handles both forms. Bluesky returns fractional seconds
(`2024-11-13T01:24:48.408Z`) but not universally, and a dropped `accountCreatedAt`
silently removes account age from the analysis — so `parseBlueskyDate` tries the
fractional formatter first and falls back to the plain one:

```swift
/// Bluesky timestamps usually carry fractional seconds but not always. Try both:
/// a dropped date silently removes account age from every downstream analysis.
static func parseBlueskyDate(_ s: String) -> Date? {
    ISO8601DateFormatter.blueskyFractional.date(from: s)
        ?? ISO8601DateFormatter.blueskyPlain.date(from: s)
}
```


- [ ] **Step 5: Commit**

```bash
git add BlueX/Services/Authors/AuthorProbeRunner.swift BlueXTests/Services/Authors/AuthorProbeRunnerTests.swift BlueX.xcodeproj
git commit -m "feat(authors): write-on-change persistence for probe results

Only status, handle, labels, displayName, bio and accountCreatedAt count as
change. Counts are recorded but never trigger a write — follower drift would
rewrite all 146k authors every sweep and defeat the design.

An indeterminate probe leaves the stored status untouched: a 503 is not
evidence that an account was removed."
```

---

### Task 7: `blueX-authors` CLI

**Files:**
- Create: `cli/authors/main.swift`
- Modify: `project.yml` — add a `BlueXAuthors` target
- Test: verified by running the binary; no unit tests (CLI sources are not in the test target, consistent with `blueX-scrape` and `blueX-annotate`)

**Interfaces:**
- Consumes: `AuthorBackfill`, `AuthorProbeRunner`, `BlueXStore`, `fail`, `formatDuration`, `writeProgress`, `writeFinalLine`, `installSIGINTHandler` from `cli/Shared/CLISupport.swift`
- Produces: `blueX-authors --backfill | --probe | --stats`, consumed by Task 8's job script

- [ ] **Step 1: Add the target to `project.yml`**

Insert after the `BlueXAnnotate` target block:

```yaml
  BlueXAuthors:
    type: tool
    platform: macOS
    deploymentTarget: "14.0"
    sources:
      - path: cli/authors
      - path: cli/Shared
      - path: BlueX/Data
      - path: BlueX/Services/API
      - path: BlueX/Services/Authors
    settings:
      base:
        PRODUCT_NAME: blueX-authors
        SWIFT_VERSION: "5.9"
        MACOSX_DEPLOYMENT_TARGET: "14.0"
        ENABLE_HARDENED_RUNTIME: NO
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGNING_REQUIRED: "NO"
        CODE_SIGNING_ALLOWED: "NO"
    dependencies:
      - sdk: SwiftData.framework
```

`BlueX/Services/Authors` is a new directory in no other target, so nothing else is affected. `BlueX/Services/API` is already shared by the scrape and annotate targets.

- [ ] **Step 2: Write the CLI**

```swift
// cli/authors/main.swift — blueX-authors
//
// Tracks what happens to the people who reply to tracked accounts, so platform
// moderation becomes measurable: takedown rate, enforcement latency, coverage.
//
//   blueX-authors --backfill    — create ReplyAuthor rows from existing replies
//   blueX-authors --probe       — probe due authors, write observations on change
//   blueX-authors --stats       — print current status counts
//
// Needs NO credentials: app.bsky.actor.getProfiles is unauthenticated.

import Foundation
import SwiftData

struct AuthorsArgs {
    var backfill = false
    var probe = false
    var stats = false
    var limit: Int?
    /// Re-probe an author only if last probed longer ago than this. Default 6 days so a
    /// weekly agent always finds the whole population due.
    var staleDays: Double = 6
    var help = false

    static func parse(_ argv: [String]) -> AuthorsArgs {
        var a = AuthorsArgs(); var i = 1
        while i < argv.count {
            switch argv[i] {
            case "--backfill": a.backfill = true
            case "--probe":    a.probe = true
            case "--stats":    a.stats = true
            case "-h", "--help": a.help = true
            case "--limit":
                i += 1
                if i < argv.count, let n = Int(argv[i]), n > 0 { a.limit = n }
                else { fail("blueX-authors", "invalid --limit value") }
            case "--stale-days":
                i += 1
                if i < argv.count, let d = Double(argv[i]), d >= 0 { a.staleDays = d }
                else { fail("blueX-authors", "invalid --stale-days value") }
            default: fail("blueX-authors", "unknown argument: \(argv[i]). Run --help.")
            }
            i += 1
        }
        return a
    }
}

let usage = """
usage: blueX-authors [--backfill] [--probe] [--stats]

  --backfill          Create a ReplyAuthor per distinct reply-author DID from the
                      posts already in the store. Idempotent; re-running extends
                      each author's first/last-seen range.
  --probe             Probe authors that are due and record an observation when
                      something material changed. Needs no credentials.
  --limit <n>         Probe at most n authors this run.
  --stale-days <d>    Consider an author due if last probed more than d days ago
                      (default 6, so a weekly agent finds everyone due).
  --stats             Print status counts and exit.
  --help, -h          This help.

Reads and writes the BlueX store at /Volumes/Eregion/bluex-data/default.store.
Ctrl-C stops at the next batch boundary; work already saved is kept.
"""

func runCLI() async {
    let args = AuthorsArgs.parse(CommandLine.arguments)
    if args.help || (!args.backfill && !args.probe && !args.stats) {
        print(usage); return
    }

    let container: ModelContainer
    do { container = try BlueXStore.openContainer() }
    catch { fail("blueX-authors", "failed to open store: \(error)") }

    if args.backfill {
        let start = Date()
        do {
            let r = try AuthorBackfill(container: container).run()
            writeFinalLine("backfill — \(r.created) created, \(r.updated) updated in \(formatDuration(Date().timeIntervalSince(start)))")
        } catch { fail("blueX-authors", "backfill failed: \(error)") }
    }

    if args.probe {
        let start = Date()
        let runner = AuthorProbeRunner(container: container)
        do {
            let s = try await runner.run(limit: args.limit, staleAfter: args.staleDays * 86400)
            writeFinalLine("probe — \(s.probed) probed, \(s.observationsWritten) observations written, \(s.unknown) indeterminate, in \(formatDuration(Date().timeIntervalSince(start)))")
            if s.unknown > 0 {
                // Indeterminate results are expected in small numbers; a large count
                // means the API or the network is unhealthy and the run should be
                // treated with suspicion rather than trusted.
                writeFinalLine("note: \(s.unknown) author(s) could not be classified; their stored status was left unchanged")
            }
        } catch { fail("blueX-authors", "probe failed: \(error)") }
    }

    if args.stats {
        let ctx = ModelContext(container)
        do {
            let authors = try ctx.fetch(FetchDescriptor<ReplyAuthor>())
            var counts: [String: Int] = [:]
            for a in authors { counts[a.currentStatus, default: 0] += 1 }
            print("authors: \(authors.count)")
            for k in counts.keys.sorted() { print("  \(k): \(counts[k]!)") }
            let probed = authors.filter { $0.lastProbedAt != nil }.count
            print("  (probed at least once: \(probed))")
        } catch { fail("blueX-authors", "stats failed: \(error)") }
    }
}

await runCLI()
```

- [ ] **Step 3: Build it**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && xcodegen generate
xcodebuild build -project BlueX.xcodeproj -scheme BlueXAuthors \
  -destination 'platform=macOS,arch=arm64' -quiet 2>&1 | tail -10
```
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Add it to the CLI installer**

In `tools/install-cli.sh`, extend the build loop and install both new binaries:

```bash
for scheme in BlueXAnnotate BlueXScrape BlueXAuthors; do
```

and after `install_one blueX-scrape`:

```bash
install_one blueX-authors
```

- [ ] **Step 5: Verify end to end against the real store**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && tools/install-cli.sh
~/.local/bin/blueX-authors --help | head -5
~/.local/bin/blueX-authors --stats
```
Expected: help prints; `--stats` reports `authors: 0` before any backfill.

- [ ] **Step 6: Commit**

```bash
git add cli/authors/main.swift project.yml tools/install-cli.sh BlueX.xcodeproj
git commit -m "feat(authors): blueX-authors CLI

--backfill, --probe, --stats. Needs no credentials: getProfiles is
unauthenticated, so this subsystem never touches the Keychain."
```

---

### Task 8: Weekly agent and guard tests

**Files:**
- Create: `tools/jobs/bluex-authors-job.sh`
- Modify: `tools/install-jobs.sh`, `tools/jobs/test_jobs.py`

**Interfaces:**
- Consumes: `lib-bluex-job.sh` (`bluex_wait_for_store`, `bluex_log_path`, `bluex_notify`, `BLUEX_BIN`, `BLUEX_LOCK`), `blueX-authors`
- Produces: installed agent `net.pulsschlag.bluex.authors`, weekly

- [ ] **Step 1: Write the job script**

```zsh
#!/bin/zsh
# tools/jobs/bluex-authors-job.sh — weekly author probe. User LaunchAgent.
#
# Probes the ~146k people who replied to tracked accounts and records what happened to
# them, so platform moderation is measurable: takedown rate, enforcement latency,
# enforcement coverage.
#
# Takes the SAME store lock as the nightly job, because it writes to the same SwiftData
# store and CoreData is not safe for concurrent multi-process writes. If the nightly run
# is still going, this skips and waits a week — the population changes slowly and a
# missed sweep costs only resolution.
#
# Needs no credentials: app.bsky.actor.getProfiles is unauthenticated.
set -u

JOBS_DIR="${0:A:h}"
source "$JOBS_DIR/lib-bluex-job.sh"

AUTHORS="$BLUEX_BIN/blueX-authors"
# Weekly cadence with a 6-day staleness window, so every author is due each run.
STALE_DAYS="${BLUEX_AUTHORS_STALE_DAYS:-6}"

LOG="$(bluex_log_path authors)"

if [ ! -x "$AUTHORS" ]; then
  echo "$(date): missing $AUTHORS — run tools/install-jobs.sh" >>"$LOG"
  bluex_notify "BlueX authors" "blueX-authors missing — see $LOG"
  exit 78
fi

if ! bluex_wait_for_store 180; then
  echo "$(date): store volume not mounted after 180s — skipped." >>"$LOG"
  bluex_notify "BlueX authors skipped" "Eregion not mounted — see $LOG"
  exit 75
fi

if ! mkdir "$BLUEX_LOCK" 2>/dev/null; then
  echo "$(date): store busy — author probe skipped, will retry next week." >>"$LOG"
  exit 0
fi
trap 'rmdir "$BLUEX_LOCK" 2>/dev/null' EXIT INT TERM HUP

rc=0
{
  echo "=== authors $(date) ==="
  "$AUTHORS" --backfill
  echo "--- probe (stale-days $STALE_DAYS) ---"
  "$AUTHORS" --probe --stale-days "$STALE_DAYS"
  rc=$?
  echo "=== done $(date) ==="
} >>"$LOG" 2>&1

if [ "$rc" -ne 0 ]; then
  bluex_notify "BlueX author probe failed" "exit $rc — see $LOG"
  exit 1
fi
exit 0
```

- [ ] **Step 2: Syntax-check**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && chmod +x tools/jobs/bluex-authors-job.sh
zsh -n tools/jobs/bluex-authors-job.sh && echo "syntax ok"
```
Expected: `syntax ok`

- [ ] **Step 3: Extend the guard tests**

In `tools/jobs/test_jobs.py`, add `"bluex-authors-job.sh"` to the `RUNTIME_SCRIPTS` list so the existing `/Volumes`, sourcing and `zsh -n` guards cover it, and add:

```python
AUTHORS_PLIST = AGENTS_DIR / "net.pulsschlag.bluex.authors.plist"


def test_authors_job_takes_the_store_lock():
    """The author probe writes to the same store as the nightly job.

    CoreData is not safe for concurrent multi-process writes, so this job must take
    BLUEX_LOCK. Losing that would put two writers on a 900k-row store.
    """
    text = (JOBS_SRC / "bluex-authors-job.sh").read_text()
    assert 'mkdir "$BLUEX_LOCK"' in text, "author job must acquire the store lock"
    assert "trap" in text and "rmdir" in text, "lock must be released on every exit path"


def test_authors_job_needs_no_credentials():
    """getProfiles is unauthenticated. A credential check appearing here means someone
    wired this subsystem to the Keychain, which it must never need."""
    text = (JOBS_SRC / "bluex-authors-job.sh").read_text()
    assert "--check-credentials" not in text
```

- [ ] **Step 4: Install the agent**

In `tools/install-jobs.sh`, after the two `write_agent` calls, add:

```bash
install -m 755 "$JOBS_SRC/bluex-authors-job.sh" "$JOBS_DEST/"
```

alongside the other `install` lines, and add a weekly agent. `StartCalendarInterval` with a `Weekday` key runs weekly — Sunday 09:00, well clear of the 03:31 nightly window:

```bash
write_weekly_agent() {   # label script weekday hour minute
  local label="$1" script="$2" weekday="$3" hour="$4" minute="$5"
  cat >"$AGENTS_DIR/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>$JOBS_DEST/$script</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key><integer>$weekday</integer>
        <key>Hour</key><integer>$hour</integer>
        <key>Minute</key><integer>$minute</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/BlueX/launchd.$label.out.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/BlueX/launchd.$label.err.log</string>
    <key>RunAtLoad</key>
    <false/>
</dict>
</plist>
PLIST
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$AGENTS_DIR/$label.plist"
  echo "  ✓ $label (weekly)"
}

write_weekly_agent net.pulsschlag.bluex.authors bluex-authors-job.sh 0 9 0
```

- [ ] **Step 5: Run the guard tests**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && bash -n tools/install-jobs.sh && echo "installer syntax ok"
cd tools/jobs && python -m pytest test_jobs.py -v 2>&1 | tail -15
```
Expected: PASS, with the install-state tests still skipping if the agents are not installed.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add tools/jobs/bluex-authors-job.sh tools/install-jobs.sh tools/jobs/test_jobs.py
git commit -m "feat(jobs): weekly author probe agent

Sunday 09:00, well clear of the 03:31 nightly window. Takes the same store
lock as the nightly job because it writes the same store, and skips rather
than contending if the nightly run overruns — the population changes slowly
and a missed sweep costs only resolution.

Guard tests assert it takes the lock and never needs credentials."
```

---

### Task 9: Attended first run

**Attended — do not run unsupervised.** This is the first contact with 146,422 real accounts and the numbers it produces replace estimates in the spec.

**Files:** none — operational

**Precondition:** no scrape is running. `pgrep -x blueX-scrape` must return nothing, or the lock will make the probe skip.

- [ ] **Step 1: Backfill**

```bash
time ~/.local/bin/blueX-authors --backfill
~/.local/bin/blueX-authors --stats
```
Expected: roughly 146,422 authors created (the count grows as scraping continues). `--stats` should report every author as `unknown`, since none has been probed.

- [ ] **Step 2: Measure a small probe before committing to a full sweep**

```bash
time ~/.local/bin/blueX-authors --probe --limit 500 --stale-days 0
```
Record the elapsed time. Extrapolate: 146,422 / 500 × elapsed. **Write the measured rate into the spec's Open Questions section**, replacing the "~100 minutes, estimated" note.

- [ ] **Step 3: Full sweep**

```bash
time ~/.local/bin/blueX-authors --probe --stale-days 0 2>&1 | tail -5
~/.local/bin/blueX-authors --stats
```
Expected: a status breakdown across `active`, `takedown`, `deactivated`, `deleted`, `unknown`.

- [ ] **Step 4: Sanity-check the result against what we know**

```bash
sqlite3 -column "file:/Volumes/Eregion/bluex-data/default.store?mode=ro" \
  "SELECT ZCURRENTSTATUS, COUNT(*) FROM ZREPLYAUTHOR GROUP BY ZCURRENTSTATUS;"
sqlite3 -column "file:/Volumes/Eregion/bluex-data/default.store?mode=ro" \
  "SELECT ZSTATUS, COUNT(*) FROM ZAUTHOROBSERVATION GROUP BY ZSTATUS;"
```

The population takedown rate **must be far below** the 31/40 seen in the ad-hoc probe — that sample was the 40 authors with the most deleted replies, selected for exactly the property being measured. A population rate anywhere near 78% means something is wrong with the classification, not that Bluesky removed three quarters of its users.

A large `unknown` count means the API or network was unhealthy; re-run before trusting the numbers.

- [ ] **Step 5: Install and enable the weekly agent**

```bash
cd /Volumes/Eregion/projects/bluex-v2 && tools/install-jobs.sh
launchctl print "gui/$(id -u)/net.pulsschlag.bluex.authors" | grep -E "state|program"
cd tools/jobs && python -m pytest test_jobs.py -q 2>&1 | tail -3
```
Expected: agent loaded; guard tests pass with fewer skips now that agents are installed.

- [ ] **Step 6: Record the real numbers**

```bash
cd /Volumes/Eregion/projects/bluex-v2
git add docs/superpowers/specs/2026-08-07-bluex-reply-authors-design.md
git commit -m "docs(spec): record measured sweep duration and population status rates"
```

---

## Verification checklist

- [ ] `xcodebuild test -project BlueX.xcodeproj -scheme BlueX -destination 'platform=macOS,arch=arm64'` passes
- [ ] `cd tools/jobs && python -m pytest test_jobs.py` passes
- [ ] `blueX-authors --stats` reports a plausible status breakdown
- [ ] No `AuthorObservation` row has `followersCount = 0` for a non-active status
- [ ] A second `--probe` immediately after the first writes ~0 new observations (write-on-change works)
- [ ] `blueX-authors` never reads the Keychain — `--probe` succeeds with no credentials configured
- [ ] The weekly agent is loaded and the nightly agents are unaffected
