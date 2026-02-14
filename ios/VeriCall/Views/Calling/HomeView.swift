import SwiftUI
import Contacts
import Combine

// MARK: - Premium Design System
struct GlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.black.opacity(0.1), radius: 10, x: 0, y: 5)
    }
}

extension View {
    func glassStyle() -> some View {
        self.modifier(GlassModifier())
    }
}

// MARK: - HomeViewModel
@MainActor
class HomeViewModel: ObservableObject {
    @Published var favorites: [Contact] = []
    @Published var callHistory: [CallHistoryEntry] = []
    @Published var connectionStatus: ConnectionStatus = .disconnected
    
    private var cancellables = Set<AnyCancellable>()
    private let webSocketService = WebSocketService.shared
    private let contactStore = CNContactStore()
    
    init() {
        // Subscribe to connection status changes
        webSocketService.$connectionStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.connectionStatus = status
            }
            .store(in: &cancellables)
            
        // Listen for call history updates
        NotificationCenter.default.publisher(for: Constants.Notifications.callHistoryUpdated)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.loadData()
            }
            .store(in: &cancellables)
    }
    
    func loadData() {
        Task {
            callHistory = await StorageService.shared.getCallHistory()
            await loadFavorites()
            
            if connectionStatus == .disconnected {
                webSocketService.connect()
            }
        }
    }
    
    private func loadFavorites() async {
        let favoriteIds = await StorageService.shared.getFavoriteIds()
        var loadedFavorites: [Contact] = []
        
        let keys = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor
        ]
        
        for id in favoriteIds {
            do {
                let cnContact = try contactStore.unifiedContact(withIdentifier: id, keysToFetch: keys)
                let name = [cnContact.givenName, cnContact.familyName]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                
                let contact = Contact(
                    id: cnContact.identifier,
                    name: name.isEmpty ? "Unknown" : name,
                    phoneNumber: cnContact.phoneNumbers.first?.value.stringValue,
                    email: nil,
                    isVerified: false,
                    isFavorite: true,
                    avatarUrl: nil,
                    lastContactedAt: nil
                )
                loadedFavorites.append(contact)
            } catch {
                print("Failed to load favorite contact \(id): \(error)")
            }
        }
        
        // Match verification status from recent calls if available
        for i in loadedFavorites.indices {
            if let lastCall = callHistory.first(where: { 
                $0.call.direction == .incoming ? $0.call.callerId == loadedFavorites[i].id : $0.call.recipientId == loadedFavorites[i].id 
            }) {
                loadedFavorites[i].isVerified = lastCall.call.isVerified
            }
        }
        
        self.favorites = loadedFavorites.sorted { $0.name < $1.name }
    }
    
    func callBack(_ entry: CallHistoryEntry) {
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
            let contactId = entry.call.direction == .incoming ? entry.call.callerId : entry.call.recipientId
            await StorageService.shared.toggleFavorite(contactId: contactId)
            await loadFavorites()
        }
    }
}

// MARK: - HomeView
struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var selectedFilter: CallFilter = .all
    @State private var selectedContact: Contact?
    @State private var showContactList = false
    
    enum CallFilter: String, CaseIterable {
        case all = "All"
        case missed = "Missed"
    }
    
    var filteredHistory: [CallHistoryEntry] {
        switch selectedFilter {
        case .all:
            return viewModel.callHistory
        case .missed:
            return viewModel.callHistory.filter { entry in
                let s = entry.call.state
                return (s == .missed || s == .declined || s == .failed) && entry.call.direction == .incoming
            }
        }
    }
    
    var body: some View {
        ZStack {
            // Premium background: Gradient over system background
            LinearGradient(colors: [Color.veriBlue.opacity(0.1), Color(UIColor.systemBackground)], 
                           startPoint: .top, 
                           endPoint: .bottom)
                .ignoresSafeArea()
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    
                    // TRUE FLUSH HEADER
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("VeriCall")
                                .font(.system(size: 34, weight: .black, design: .rounded))
                                .foregroundStyle(
                                    LinearGradient(colors: [.veriBlue, .veriLightBlue], startPoint: .leading, endPoint: .trailing)
                                )
                            
                            Spacer()
                            
                            ConnectionIndicator(status: viewModel.connectionStatus)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 60)
                    
                    // Favorites Carousel
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Favorites")
                                .font(.title3)
                                .fontWeight(.bold)
                            
                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 20) {
                                AddFavoriteButton(action: { showContactList = true })

                                ForEach(viewModel.favorites) { contact in
                                    PremiumFavoriteItem(contact: contact) {
                                        selectedContact = contact
                                    }
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 8)
                        }
                    }
                    
                    // Recents Section
                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text("Recents")
                                .font(.title3)
                                .fontWeight(.bold)
                            
                            Spacer()
                            
                            Picker("Filter", selection: $selectedFilter) {
                                ForEach(CallFilter.allCases, id: \.self) { filter in
                                    Text(filter.rawValue).tag(filter)
                                }
                            }
                            .pickerStyle(SegmentedPickerStyle())
                            .frame(width: 140)
                        }
                        .padding(.horizontal, 24)
                        
                        if filteredHistory.isEmpty {
                            HomeEmptyStateView(filter: selectedFilter)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                            LazyVStack(spacing: 12) {
                                ForEach(filteredHistory) { entry in
                                    PremiumRecentsRow(
                                        entry: entry,
                                        isFavorite: viewModel.favorites.contains(where: { 
                                            $0.id == (entry.call.direction == .incoming ? entry.call.callerId : entry.call.recipientId) 
                                        }),
                                        onCallBack: { viewModel.callBack(entry) },
                                        onToggleFavorite: { viewModel.toggleFavorite(entry: entry) }
                                    )
                                    .padding(.horizontal, 20)
                                }
                            }
                        }
                    }
                    
                    Color.clear.frame(height: 100)
                }
            }
            .refreshable {
                viewModel.loadData()
            }
            
            // Floating Call Button
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: { showContactList = true }) {
                        Image(systemName: "phone.fill.badge.plus")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 64, height: 64)
                            .background(
                                LinearGradient(colors: [.veriBlue, .veriBlue.opacity(0.8)], 
                                               startPoint: .topLeading, 
                                               endPoint: .bottomTrailing)
                            )
                            .clipShape(Circle())
                            .shadow(color: Color.veriBlue.opacity(0.3), radius: 15, x: 0, y: 8)
                    }
                    .padding(.trailing, 24)
                    .padding(.bottom, 24)
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .sheet(item: $selectedContact) { contact in
            ContactCallSheet(contact: contact, onCall: {
                selectedContact = nil
            }, onVoIPCall: {
                selectedContact = nil
                Task {
                    await VoIPCallService.shared.initiateCall(to: contact)
                }
            })
        }
        .sheet(isPresented: $showContactList) {
            NavigationView {
                ContactListView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Done") { showContactList = false }
                        }
                    }
            }
        }
        .onAppear {
            viewModel.loadData()
        }
    }
}

// MARK: - Premium UI Components

struct ConnectionIndicator: View {
    let status: ConnectionStatus
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.5), radius: 4)
            
            Text(statusText.uppercased())
                .font(.system(size: 10, weight: .black))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
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
        case .connected: return "Live"
        case .connecting, .reconnecting: return "Linking"
        default: return "Offline"
        }
    }
}

struct AddFavoriteButton: View {
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Circle()
                    .strokeBorder(Color.veriBlue.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [5, 5]))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "plus")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.veriBlue)
                    )
                    .background(Circle().fill(Color.veriBlue.opacity(0.05)))
                
                Text("Add")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.veriBlue)
            }
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

struct PremiumFavoriteItem: View {
    let contact: Contact
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                ZStack {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color.veriBlue.opacity(0.2), Color.veriBlue.opacity(0.05)], 
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 64, height: 64)
                        
                        if let avatarUrl = contact.avatarUrl, let url = URL(string: avatarUrl) {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                ProgressView()
                            }
                            .frame(width: 64, height: 64)
                            .clipShape(Circle())
                        } else {
                            Text(contact.initials)
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .foregroundColor(.veriBlue)
                        }
                    }
                    
                    if contact.isVerified {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(3)
                                    .background(Color.green)
                                    .clipShape(Circle())
                                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                    .shadow(radius: 2)
                            }
                        }
                        .frame(width: 68, height: 68)
                    }
                }
                
                Text(contact.name.components(separatedBy: " ").first ?? contact.name)
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

struct PremiumRecentsRow: View {
    let entry: CallHistoryEntry
    let isFavorite: Bool
    let onCallBack: () -> Void
    let onToggleFavorite: () -> Void
    
    var displayName: String {
        entry.call.direction == .incoming ? entry.call.callerName : entry.call.recipientName
    }
    
    var isMissed: Bool {
        (entry.call.state == .missed || entry.call.state == .declined || entry.call.state == .failed) && entry.call.direction == .incoming
    }
    
    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 52, height: 52)
                
                Text(String(displayName.prefix(1)))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(entry.call.isVerified ? .green : .veriBlue)
                
                if entry.call.isVerified {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.green)
                        .padding(2)
                        .background(Color.white)
                        .clipShape(Circle())
                        .offset(x: 18, y: 18)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundColor(isMissed ? .red : .primary)
                
                HStack(spacing: 6) {
                    Image(systemName: entry.call.direction == .incoming ? "phone.arrow.down.left" : "phone.arrow.up.right")
                        .font(.caption2)
                        .foregroundColor(entry.call.direction == .incoming ? .green : .blue)
                    
                    Text(entry.call.direction.displayText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary.opacity(0.3))
                    
                    Text(formatDate(entry.timestamp))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                Button(action: onToggleFavorite) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 18))
                        .foregroundColor(isFavorite ? .pink : .gray.opacity(0.3))
                }
                
                Button(action: onCallBack) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(entry.call.isVerified ? Color.green : Color.veriBlue)
                        .clipShape(Circle())
                        .shadow(color: (entry.call.isVerified ? Color.green : Color.veriBlue).opacity(0.3), radius: 5, x: 0, y: 3)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassStyle()
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "h:mm a"
        } else {
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }
}

struct HomeEmptyStateView: View {
    let filter: HomeView.CallFilter
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: filter == .missed ? "phone.arrow.down.left" : "phone.fill")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.2))
            
            Text(filter == .missed ? "All caught up" : "No stories yet")
                .font(.headline)
            
            Text(filter == .missed ? "You have no missed calls." : "Ready to verify your first call.")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
}

