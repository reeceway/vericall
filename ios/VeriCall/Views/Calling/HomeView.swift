import SwiftUI
import Contacts

struct HomeView: View {
    @StateObject private var viewModel = HomeViewModel()
    @State private var selectedFilter: CallFilter = .all
    @State private var showContactSheet = false
    @State private var selectedContact: Contact?
    
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
        NavigationView {
            VStack(spacing: 0) {
                
                // Favorites Section
                if !viewModel.favorites.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Favorites")
                            .font(.headline)
                            .padding(.horizontal)
                            .padding(.top, 8)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(viewModel.favorites) { contact in
                                    FavoriteItemView(contact: contact) {
                                        selectedContact = contact
                                    }
                                }
                            }
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                        }
                        
                        Divider()
                    }
                    .background(Color(UIColor.systemBackground))
                }
                
                // Recents Section
                VStack(spacing: 0) {
                    // Filter pills
                    HStack {
                        Text("Recents")
                            .font(.headline)
                        
                        Spacer()
                        
                        Picker("Filter", selection: $selectedFilter) {
                            ForEach(CallFilter.allCases, id: \.self) { filter in
                                Text(filter.rawValue).tag(filter)
                            }
                        }
                        .pickerStyle(SegmentedPickerStyle())
                        .frame(width: 150)
                    }
                    .padding()
                    .background(Color(UIColor.secondarySystemBackground))
                    
                    if filteredHistory.isEmpty {
                        Spacer()
                        HomeEmptyView(filter: selectedFilter)
                        Spacer()
                    } else {
                        List {
                            ForEach(filteredHistory) { entry in
                                CallHistoryRow(entry: entry) {
                                    viewModel.callBack(entry)
                                }
                            }
                            .onDelete(perform: viewModel.deleteEntries)
                        }
                        .listStyle(PlainListStyle())
                    }
                }
            }
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $selectedContact) { contact in
                ContactCallSheet(contact: contact, onCall: {
                    // Standard call handling
                    selectedContact = nil
                    // TODO: Implement direct callback logic if needed, or rely on ContactCallSheet internal logic + VM integration
                }, onVoIPCall: {
                    selectedContact = nil
                    Task {
                        await VoIPCallService.shared.initiateCall(to: contact)
                    }
                })
            }
            .onAppear {
                viewModel.loadData()
            }
        }
    }
}

// MARK: - Favorite Item View
struct FavoriteItemView: View {
    let contact: Contact
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    if let avatarUrl = contact.avatarUrl, let url = URL(string: avatarUrl) {
                        AsyncImage(url: url) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Color.gray.opacity(0.3)
                        }
                        .frame(width: 60, height: 60)
                        .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(Color.veriBlue.opacity(0.1))
                            .frame(width: 60, height: 60)
                        
                        Text(contact.initials)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(.veriBlue)
                    }
                    
                    if contact.isVerified {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundColor(.green)
                                    .font(.system(size: 16))
                                    .background(Circle().fill(Color.white).padding(2))
                            }
                        }
                    }
                }
                .frame(width: 60, height: 60)
                
                Text(contact.name.components(separatedBy: " ").first ?? contact.name)
                    .font(.caption)
                    .lineLimit(1)
                    .frame(width: 70)
            }
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - ViewModel
@MainActor
class HomeViewModel: ObservableObject {
    @Published var callHistory: [CallHistoryEntry] = []
    @Published var favorites: [Contact] = []
    
    private let storageService = StorageService.shared
    private let callManager = CallManager.shared
    // Need access to full contact list to resolve IDs to Contact objects for Favorites
    // For now, we'll assume we can resolving them via ContactListViewModel or similar logic. 
    // Simplified: Favorites are stored as IDs, we need to fetch Contacts. 
    // We can reuse ContactListViewModel logic or duplicate it.
    // Better: Fetch contacts from CNContactStore matching IDs.
    
    func loadData() {
        Task {
            let history = await storageService.getCallHistory()
            let favIds = await storageService.getFavoriteIds()
            
            await MainActor.run {
                self.callHistory = history
            }
            
            await loadFavorites(ids: favIds)
        }
    }
    
    private func loadFavorites(ids: Set<String>) async {
        // Fetch contacts... logic
        // ...
        
        // Simplified fetching for now:
        let allContacts = try? await fetchContacts()
        if let contacts = allContacts {
            await MainActor.run {
                self.favorites = contacts.filter { ids.contains($0.id) }
            }
        }
    }
    
    private func fetchContacts() async throws -> [Contact] {
        // Reusing logic from ContactListViewModel roughly
        // Ideally this should be in a shared service.
        let store = Contacts.CNContactStore()
        let keys = [Contacts.CNContactGivenNameKey, Contacts.CNContactFamilyNameKey, Contacts.CNContactPhoneNumbersKey, Contacts.CNContactIdentifierKey] as [Contacts.CNKeyDescriptor]
        let request = Contacts.CNContactFetchRequest(keysToFetch: keys)
        var results: [Contact] = []
        try store.enumerateContacts(with: request) { contact, _ in
            let name = [contact.givenName, contact.familyName].joined(separator: " ").trimmingCharacters(in: .whitespaces)
             let phone = contact.phoneNumbers.first?.value.stringValue
             results.append(Contact(id: contact.identifier, name: name, phoneNumber: phone, email: nil, isVerified: false, isFavorite: false, avatarUrl: nil, lastContactedAt: nil))
        }
        return results
    }
    
    func deleteEntries(at offsets: IndexSet) {
        let entriesToDelete = offsets.map { callHistory[$0] }
        callHistory.remove(atOffsets: offsets)
        
        Task {
            for entry in entriesToDelete {
                 await storageService.deleteCall(id: entry.id)
            }
        }
    }
    
    func callBack(_ entry: CallHistoryEntry) {
        // ... (reuse logic)
        Task {
             let contact = Contact(
                 id: entry.call.direction == .incoming ? entry.call.callerId : entry.call.recipientId,
                 name: entry.call.direction == .incoming ? entry.call.callerName : entry.call.recipientName,
                 phoneNumber: nil, // We might not have phone number in history call object? Call object should probably store it.
                 email: nil,
                 isVerified: entry.call.isVerified,
                 isFavorite: false,
                 avatarUrl: nil,
                 lastContactedAt: nil
             )
             try? await callManager.initiateCall(to: contact)
        }
    }
}

// MARK: - Home Empty View
struct HomeEmptyView: View {
    let filter: HomeView.CallFilter
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "phone.arrow.up.right")
                .font(.system(size: 60))
                .foregroundColor(.gray.opacity(0.5))
            
            Text(emptyTitle)
                .font(.title3)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            
            Text(emptyMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
    
    private var emptyTitle: String {
        switch filter {
        case .all:
            return "No Calls Yet"
        case .missed:
            return "No Missed Calls"
        }
    }
    
    private var emptyMessage: String {
        switch filter {
        case .all:
            return "Your call history will appear here"
        case .missed:
            return "You haven't missed any calls"
        }
    }
}
