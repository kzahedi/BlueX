// BlueX/ViewModels/SelectionHistory.swift
import Foundation
import Observation

/// Back-navigation for the content column.
///
/// Selecting a post replaces the whole `SidebarItem`, so without this the app forgets
/// which account you were browsing and there is nothing to go back to. This keeps a
/// bounded stack of previous selections.
@Observable
final class SelectionHistory {
    /// Bounded so a long browsing session cannot grow this without limit. 50 is far
    /// more than anyone steps back through, and each entry is a small enum.
    static let maxDepth = 50

    private(set) var stack: [SidebarItem] = []

    var canGoBack: Bool { !stack.isEmpty }

    /// Records `previous` before a new selection replaces it.
    /// Consecutive duplicates are not recorded — re-selecting the same item is not
    /// navigation, and recording it would make "back" appear to do nothing.
    func record(_ previous: SidebarItem?) {
        guard let previous else { return }
        if stack.last == previous { return }
        stack.append(previous)
        if stack.count > Self.maxDepth { stack.removeFirst(stack.count - Self.maxDepth) }
    }

    /// Pops and returns the previous selection, or nil when there is none.
    func goBack() -> SidebarItem? {
        stack.popLast()
    }

    func clear() { stack.removeAll() }
}
