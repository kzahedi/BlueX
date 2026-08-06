// BlueX/Services/API/EphemeralHTTPSession.swift
import Foundation

/// The one `URLSession` every BlueX HTTP client uses: **no on-disk HTTP footprint at all.**
///
/// Lives in `Services/API` rather than `Services/Annotation` deliberately: per
/// `project.yml`, `BlueX/Services/API` is compiled into all three targets
/// (`BlueXScrape`, `BlueXAnnotate` and the GUI), while `Services/Annotation` is not
/// part of `BlueXScrape`. A helper placed there would break the scrape build.
///
/// ### Why `.ephemeral` and not `.default` + `urlCache = nil`
///
/// `URLSession.shared` / `.default` write to **two** places on the INTERNAL disk,
/// while the store, its SQLite scratch and the logs all live on the external volume:
///
/// 1. `~/Library/Caches/<tool>` — the response body cache. It grew ~1 MB per minute
///    of scraping and filling the internal disk killed a run on 2026-08-04. Setting
///    `urlCache = nil` removed this one.
/// 2. `~/Library/HTTPStorages/<tool>/httpstorages.sqlite` (+ `-wal`, `-shm`) — the
///    cookie / credential / HSTS store. A *different* thing from the response cache,
///    and `urlCache = nil` does nothing about it. Measured at 232 KB and **not
///    growing** (zero delta over 30 s of heavy API traffic), so this was never a
///    space risk — removing it eliminates the last internal-disk write surface
///    rather than fixing a leak.
///
/// `.ephemeral` keeps cache, cookies and credentials in memory only, so it covers
/// both in one stroke — which is what `urlCache = nil` should have been.
///
/// ### Why losing persistent cookie / credential storage is safe
///
/// Every endpoint BlueX talks to authenticates with a bearer token or nothing at all:
/// Bluesky (`bsky.social/xrpc`) uses an access JWT the coordinator holds in memory and
/// refreshes itself; Ollama on localhost needs no auth; the OpenAI-compatible hosted
/// endpoints (Cerebras, Groq, …) take an API key from the Keychain as a Bearer header.
/// No code path reads or sets cookies, and none responds to an HTTP auth challenge —
/// so there is nothing for a persistent cookie jar or credential store to carry.
///
/// ### Why `requestCachePolicy` is still set explicitly
///
/// `.ephemeral` has no persistent cache, and we additionally clear `urlCache` so there
/// is no in-memory one either. `.reloadIgnoringLocalCacheData` closes the remaining
/// gap: it stops *reads* from any cache a later change might reintroduce. That matters
/// for correctness, not just disk. Feed pagination sends a fresh cursor every time so
/// it can never hit, but the `getPostThread` refreshes of reply trees inside the
/// rescrape window repeat by design — and they exist to discover **new** replies. A
/// cache hit there returns the reply set we already have and we silently under-collect.
///
/// Built once, statically: a `URLSession` per client instance would leak connection
/// pools, and all three clients share this single instance.
enum EphemeralHTTPSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Ephemeral still installs an in-memory URLCache; drop it entirely so no
        // layer can serve a stale getPostThread response.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
}
