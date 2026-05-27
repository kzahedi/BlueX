// BlueX/ViewModels/SidebarViewModel.swift
import Foundation
import Observation

@Observable
final class SidebarViewModel {
    var expandedGroups: Set<String> = []
    var scrapePhase: CoordinatorPhase = .idle
    var scrapeProgress: Double = 0.0
    var activeScrapeHandle: String? = nil   // MUST be Optional
    var lastError: BlueskyError? = nil
    var accountStatuses: [String: AccountScrapeStatus] = [:]
}
