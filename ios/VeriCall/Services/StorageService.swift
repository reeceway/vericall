import Foundation

actor StorageService {
    static let shared = StorageService()
    
    private let callHistoryKey = "call_history_v1"
    private let favoritesKey = "favorite_contact_ids"
    
    private var callHistory: [CallHistoryEntry] = []
    private var favoriteIds: Set<String> = []
    
    private init() {
        loadCallHistory()
        loadFavorites()
    }
    
    // MARK: - Call History
    
    func getCallHistory() -> [CallHistoryEntry] {
        return callHistory.sorted { $0.timestamp > $1.timestamp }
    }
    
    func saveCall(_ call: Call) {
        let entry = CallHistoryEntry(
            id: UUID().uuidString,
            call: call,
            timestamp: call.endedAt ?? call.startedAt ?? Date(),
            isRead: true
        )
        callHistory.append(entry)
        persistCallHistory()
    }
    
    func deleteCall(id: String) {
        callHistory.removeAll { $0.id == id }
        persistCallHistory()
    }
    
    func clearCallHistory() {
        callHistory.removeAll()
        persistCallHistory()
    }
    
    private func loadCallHistory() {
        guard let data = try? Data(contentsOf: historyFileURL) else { return }
        if let decoded = try? JSONDecoder().decode([CallHistoryEntry].self, from: data) {
            callHistory = decoded
        }
    }
    
    private func persistCallHistory() {
        if let data = try? JSONEncoder().encode(callHistory) {
            try? data.write(to: historyFileURL)
        }
    }
    
    private var historyFileURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("call_history.json")
    }
    
    // MARK: - Favorites
    
    func getFavoriteIds() -> Set<String> {
        return favoriteIds
    }
    
    func isFavorite(contactId: String) -> Bool {
        return favoriteIds.contains(contactId)
    }
    
    func toggleFavorite(contactId: String) {
        if favoriteIds.contains(contactId) {
            favoriteIds.remove(contactId)
        } else {
            favoriteIds.insert(contactId)
        }
        persistFavorites()
    }
    
    private func loadFavorites() {
        if let array = UserDefaults.standard.stringArray(forKey: favoritesKey) {
            favoriteIds = Set(array)
        }
    }
    
    private func persistFavorites() {
        UserDefaults.standard.set(Array(favoriteIds), forKey: favoritesKey)
    }
}
