import SwiftUI
import Contacts
import Combine

// MARK: - HomeViewModel
@MainActor
class HomeViewModel: ObservableObject {
    @Published var favorites: [Contact] = []
    @Published var callHistory: [CallHistoryEntry] = []
    @Published var connectionStatus: ConnectionStatus = .disconnected
    
    private var cancellables = Set<AnyCancellable>()
    private let webSocketService = WebSocketService.shared
    
    init() {
        // Subscribe to connection status changes
        webSocketService.$connectionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.connectionStatus = status
            }
            .store(in: &cancellables)
    }
    
    func loadData() {
        Task {
            // Load call history from storage
            callHistory = await StorageService.shared.getCallHistory()
            
            // Load favorites from storage
            let favoriteIds = await StorageService.shared.getFavoriteIds()
            
            // Update favorites list based on call history and favorite IDs
            await updateFavoritesFromHistory(favoriteIds: favoriteIds)
            
            // Ensure WebSocket is connected
            if connectionStatus == .disconnected {
                webSocketService.connect()
            }
        }
    }
    
    private func updateFavoritesFromHistory(favoriteIds: Set<String>) async {
        // Build favorites list from call history entries that match favorite IDs
        var newFavorites: [Contact] = []
        for entry in callHistory {
            let contactId = entry.call.direction == .incoming ? entry.call.callerId : entry.call.recipientId
            if favoriteIds.contains(contactId) && !newFavorites.contains(where: { $0.id == contactId }) {
                let contact = Contact(
                    id: contactId,
                    name: entry.call.direction == .incoming ? entry.call.callerName : entry.call.recipientName,
                    phoneNumber: nil,
                    email: nil,
                    isVerified: entry.call.isVerified,
                    isFavorite: true,
                    avatarUrl: nil,
                    lastContactedAt: entry.timestamp
                )
                newFavorites.append(contact)
            }
        }
        favorites = newFavorites
    }
    
    func callBack(_ entry: CallHistoryEntry) {
        // Place a call back to the contact
        Task {
            let contact = Contact(
                id: entry.call.direction == .incoming ? entry.call.callerId : entry.call.recipientId,
                name: entry.call.direction == .incoming ? entry.call.callerName : entry.call.recipientName,
                phoneNumber: nil,
                email: nil,
                isVerified: entry.call.isVerified,
                isFavorite: false,
                avatarUrl: nil,
                lastContactedAt: Date()
            )
            await VoIPCallService.shared.initiateCall(to: contact)
        }
    }
    
    func toggleFavorite(entry: CallHistoryEntry) {
        Task {
            // Toggle favorite status for the contact in this call entry
            let contactId = entry.call.direction == .incoming ? entry.call.callerId : entry.call.recipientId
            
            await StorageService.shared.toggleFavorite(contactId: contactId)
            
            // Reload favorites
            let favoriteIds = await StorageService.shared.getFavoriteIds()
            await updateFavoritesFromHistory(favoriteIds: favoriteIds)
        }
    }
}

// MARK: - HomeView
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var selectedFilter: CallFilter = .all
    @State private var selectedContact: Contact?
    @State private var showNewCallSheet = false
    
    enum CallFilter: String, CaseIterable {
        case all = "All"
        case missed = "Missed"
    }
    
    var filteredHistory: [CallHistoryEntry] {
        switch selectedFilter {
        case .all:
            return viewModel.callHistory
        case .missed:
            return viewModel.callHistory.filter { $0.call.state == .missed }
        }
    }
    
    var body: some View {
        ZStack {
            Color(UIColor.systemGroupedBackground)
                .ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ConnectionStatusBar(status: viewModel.connectionStatus)
                        .padding(.horizontal)
                        .padding(.top, 8)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "Favorites", icon: "star.fill", color: .yellow)
                        
                        if viewModel.favorites.isEmpty {
                            EmptyFavoritesView(onAddTap: { showNewCallSheet = true })
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 16) {
                                    AddFavoriteButton(action: { showNewCallSheet = true })
                                    
                                    ForEach(viewModel.favorites) { contact in
                                        FavoriteCard(contact: contact) {
                                            selectedContact = contact
                                        }
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                    
                    Divider()
                        .padding(.horizontal)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            SectionHeader(title: "Recents", icon: "clock.arrow.circlepath", color: .veriBlue)
                            
                            Spacer()
                            
                            HStack(spacing: 4) {
                                ForEach(CallFilter.allCases, id: \.rawValue) { filter in
                                    FilterPill(
                                        title: filter.rawValue,
                                        isSelected: selectedFilter == filter,
                                        action: { selectedFilter = filter }
                                    )
                                }
                            }
                        }
                        .padding(.horizontal)
                        
                        if filteredHistory.isEmpty {
                            EmptyHistoryView(filter: selectedFilter)
                                .padding(.top, 40)
                        } else {
                            VStack(spacing: 8) {
                                ForEach(filteredHistory) { entry in
                                    ModernCallHistoryRow(
                                        entry: entry,
                                        onCallBack: { viewModel.callBack(entry) },
                                        onToggleFavorite: { viewModel.toggleFavorite(entry: entry) }
                                    )
                                    .padding(.horizontal)
                                }
                            }
                            .padding(.top, 8)
                        }
                    }
                    .padding(.vertical, 16)
                    
                    Color.clear.frame(height: 100)
                }
            }
            .refreshable {
                viewModel.loadData()
            }
            
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    FloatingCallButton(action: { showNewCallSheet = true })
                        .padding(.trailing, 20)
                        .padding(.bottom, 20)
                }
            }
        }
        .navigationBarHidden(true)
        .sheet(item: $selectedContact) { contact in
            ContactCallSheet(
                contact: contact,
                onCall: { selectedContact = nil },
                onVoIPCall: {
                    selectedContact = nil
                    Task {
                        await VoIPCallService.shared.initiateCall(to: contact)
                    }
                }
            )
        }
        .sheet(isPresented: $showNewCallSheet) {
            ContactListView()
        }
        .onAppear {
            viewModel.loadData()
        }
    }
}

// MARK: - Connection Status Bar
struct ConnectionStatusBar: View {
    let status: ConnectionStatus
    
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(statusText)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    
    private var statusColor: Color {
        switch status {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }
    
    private var statusText: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting..."
        case .reconnecting(let attempt): return "Reconnecting (\(attempt))"
        case .disconnected: return "Disconnected"
        case .error: return "Connection Error"
        }
    }
}

// MARK: - Section Header
struct SectionHeader: View {
    let title: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(color)
            
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.primary)
        }
    }
}

// MARK: - Filter Pill
struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(isSelected ? Color.veriBlue : Color(UIColor.secondarySystemGroupedBackground))
                .clipShape(Capsule())
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Add Favorite Button
struct AddFavoriteButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Circle()
                    .strokeBorder(Color.veriBlue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.veriBlue)
                    )
                
                Text("Add")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.veriBlue)
            }
            .frame(width: 72)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Favorite Card
struct FavoriteCard: View {
    let contact: Contact
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(contact.isVerified ? Color.green.opacity(0.15) : Color.veriBlue.opacity(0.15))
                        .frame(width: 64, height: 64)
                    
                    if let avatarUrl = contact.avatarUrl, let url = URL(string: avatarUrl) {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            Color.gray.opacity(0.2)
                        }
                        .frame(width: 64, height: 64)
                        .clipShape(Circle())
                    } else {
                        Text(contact.initials)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundColor(contact.isVerified ? .green : .veriBlue)
                    }
                    
                    if contact.isVerified {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 16))
                                    .background(
                                        Circle()
                                            .fill(Color.white)
                                            .frame(width: 18, height: 18)
                                    )
                            }
                        }
                    }
                }
                .frame(width: 64, height: 64)
                
                Text(contact.name.components(separatedBy: " ").first ?? contact.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .frame(width: 72)
            }
            .frame(width: 72)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Modern Call History Row
struct ModernCallHistoryRow: View {
    let entry: CallHistoryEntry
    let onCallBack: () -> Void
    let onToggleFavorite: () -> Void
    
    private var contactName: String {
        entry.call.direction == .incoming ? entry.call.callerName : entry.call.recipientName
    }
    
    private var isVerified: Bool {
        entry.call.isVerified
    }
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(isVerified ? Color.green.opacity(0.12) : Color(UIColor.tertiarySystemFill))
                    .frame(width: 48, height: 48)
                
                Text(String(contactName.prefix(1)))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isVerified ? .green : .secondary)
                
                if isVerified {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                                .background(
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 14, height: 14)
                                )
                        }
                    }
                }
            }
            .frame(width: 48, height: 48)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(contactName)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(entry.call.state == .missed ? .red : .primary)
                
                HStack(spacing: 6) {
                    Image(systemName: entry.call.direction == .incoming ? "arrow.down.left" : "arrow.up.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(entry.call.direction == .incoming ? .green : .blue)
                    
                    Text(entry.call.direction.displayText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("\u{2022}")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(formatTime(entry.timestamp))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button(action: onToggleFavorite) {
                    Image(systemName: entry.call.isVerified ? "heart.fill" : "heart")
                        .font(.system(size: 20))
                        .foregroundColor(entry.call.isVerified ? .pink : Color(UIColor.systemGray3))
                }
                .buttonStyle(ScaleButtonStyle())
                
                Button(action: onCallBack) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(isVerified ? Color.green : Color.veriBlue)
                        .clipShape(Circle())
                }
                .buttonStyle(ScaleButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(UIColor.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(UIColor.separator), lineWidth: 0.5)
        )
    }
    
    private func formatTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Floating Call Button
struct FloatingCallButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Image(systemName: "phone.badge.plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 60, height: 60)
                .background(
                    LinearGradient(
                        colors: [Color.veriBlue, Color.veriBlue.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
                .shadow(color: Color.veriBlue.opacity(0.4), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Empty States
struct EmptyFavoritesView: View {
    let onAddTap: () -> Void
    
    var body: some View {
        Button(action: onAddTap) {
            HStack(spacing: 12) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.yellow.opacity(0.8))
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("No Favorites Yet")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text("Tap to add contacts to favorites")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(UIColor.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.yellow.opacity(0.3), lineWidth: 1)
            )
            .padding(.horizontal)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct EmptyHistoryView: View {
    let filter: HomeView.CallFilter
    
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color(UIColor.tertiarySystemFill))
                    .frame(width: 80, height: 80)
                
                Image(systemName: filter == .missed ? "phone.arrow.down.left" : "clock.arrow.circlepath")
                    .font(.system(size: 32))
                    .foregroundColor(.secondary)
            }
            
            Text(emptyTitle)
                .font(.headline)
                .foregroundColor(.primary)
            
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }
    
    private var emptyTitle: String {
        switch filter {
        case .all: return "No Calls Yet"
        case .missed: return "No Missed Calls"
        }
    }
    
    private var emptyMessage: String {
        switch filter {
        case .all: return "Your call history will appear here once you make or receive calls"
        case .missed: return "Great! You have not missed any calls recently"
        }
    }
}
