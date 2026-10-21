import SwiftUI

/// Browsing past chats in the panel: ⌘K opens the list, type to filter, ↑↓ choose, ↩ open, esc close.
extension ChatStore {
    var historyResults: [SessionSummary] {
        let q = historyQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sessions }
        return sessions.filter { $0.displayTitle.localizedStandardContains(q) || $0.preview.localizedStandardContains(q) }
    }

    func toggleHistory() {
        showingHistory ? closeHistory() : openHistory()
    }

    func openHistory() {
        guard auth.isSignedIn else { return }
        dismissSlash()
        historyQuery = ""
        historySelection = sessions.firstIndex { $0.id == currentStoredId } ?? 0
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { showingHistory = true }
        Task { await refreshSessions() }
    }

    func closeHistory() {
        guard showingHistory else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) { showingHistory = false }
    }

    func moveHistory(_ delta: Int) {
        let count = historyResults.count
        guard count > 0 else { return }
        historySelection = min(max(historySelection + delta, 0), count - 1)
        historyScrollRequest += 1
    }

    func openSelectedHistory() {
        guard let s = historyResults[safe: historySelection] else { return }
        openSession(s)
    }
}
