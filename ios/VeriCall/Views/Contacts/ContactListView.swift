import SwiftUI

struct ContactListView: View {
    @StateObject private var viewModel = ContactListViewModel()
    @State private var searchText = ""
    @State private var selectedContact: Contact?
    @State private var showingCallSheet = false
    
    var filteredContacts: [Contact] {
        if searchText.isEmpty {
            return viewModel.contacts
        }
        return viewModel.contacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(searchText) ||
            (contact.phoneNumber?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            (contact.email?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                List {
                    // Connection status indicator
                    HStack {
                        ConnectionStatusView(status: viewModel.connectionStatus)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .padding(.horizontal)
                    .padding(.vertical, 4)
                    
                    if !viewModel.verifiedContacts.isEmpty {
                        Section(header: Text("Verified Contacts")) {
                            ForEach(viewModel.verifiedContacts) { contact in
                                ContactRowView(contact: contact) {
                                    initiateCall(to: contact)
                                }
                            }
                        }
                    }
                    
                    if !viewModel.unverifiedContacts.isEmpty {
                        Section(header: Text("Contacts")) {
                            ForEach(viewModel.unverifiedContacts) { contact in
                                ContactRowView(contact: contact) {
                                    initiateCall(to: contact)
                                }
                            }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
                .navigationTitle("Contacts")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: {
                            viewModel.refreshContacts()
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .disabled(viewModel.isLoading)
                    }
                }
                .refreshable {
                    await viewModel.refreshContactsAsync()
                }
                .sheet(item: $selectedContact) { contact in
                    ContactCallSheet(contact: contact) {
                        selectedContact = nil
                        viewModel.makeCall(to: contact)
                    }
                }
                
                if viewModel.isLoading {
                    ProgressView()
                        .scaleEffect(1.2)
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage)
            }
        }
        .onAppear {
            viewModel.loadContacts()
        }
    }
    
    private func initiateCall(to contact: Contact) {
        selectedContact = contact
    }
}

// MARK: - ViewModel
@MainActor
class ContactListViewModel: ObservableObject {
    @Published var contacts: [Contact] = []
    @Published var isLoading = false
    @Published var showError = false
    @Published var errorMessage = ""
    @Published var connectionStatus: ConnectionStatus = .disconnected
    
    private let callManager = CallManager.shared
    private let webSocketService = WebSocketService.shared
    
    var verifiedContacts: [Contact] {
        contacts.filter { $0.isVerified }.sorted { $0.name < $1.name }
    }
    
    var unverifiedContacts: [Contact] {
        contacts.filter { !$0.isVerified }.sorted { $0.name < $1.name }
    }
    
    init() {
        webSocketService.$connectionStatus
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionStatus)
    }
    
    func loadContacts() {
        isLoading = true
        
        // In a real app, fetch from API
        // For now, using sample data
        contacts = [
            Contact(id: "1", name: "Alice Johnson", phoneNumber: "+1-555-0101", email: "alice@example.com", isVerified: true, avatarUrl: nil, lastContactedAt: Date().addingTimeInterval(-86400)),
            Contact(id: "2", name: "Bob Smith", phoneNumber: "+1-555-0102", email: "bob@example.com", isVerified: true, avatarUrl: nil, lastContactedAt: Date().addingTimeInterval(-172800)),
            Contact(id: "3", name: "Carol White", phoneNumber: "+1-555-0103", email: "carol@example.com", isVerified: false, avatarUrl: nil, lastContactedAt: nil),
            Contact(id: "4", name: "David Brown", phoneNumber: "+1-555-0104", email: "david@example.com", isVerified: true, avatarUrl: nil, lastContactedAt: Date().addingTimeInterval(-259200)),
            Contact(id: "5", name: "Eve Martinez", phoneNumber: "+1-555-0105", email: "eve@example.com", isVerified: false, avatarUrl: nil, lastContactedAt: nil)
        ]
        
        isLoading = false
    }
    
    func refreshContacts() {
        loadContacts()
    }
    
    func refreshContactsAsync() async {
        await MainActor.run {
            loadContacts()
        }
    }
    
    func makeCall(to contact: Contact) {
        Task {
            do {
                try await callManager.initiateCall(to: contact)
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}

// MARK: - Connection Status View
struct ConnectionStatusView: View {
    let status: ConnectionStatus
    
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(status.displayText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    private var statusColor: Color {
        switch status {
        case .disconnected:
            return .gray
        case .connecting, .reconnecting:
            return .orange
        case .connected:
            return .green
        case .error:
            return .red
        }
    }
}

// MARK: - Contact Call Sheet
struct ContactCallSheet: View {
    let contact: Contact
    let onCall: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 32) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(contact.isVerified ? Color.green.opacity(0.2) : Color.gray.opacity(0.2))
                        .frame(width: 120, height: 120)
                    
                    Text(contact.initials)
                        .font(.system(size: 48, weight: .medium))
                        .foregroundColor(contact.isVerified ? .green : .gray)
                }
                .overlay(alignment: .bottomTrailing) {
                    if contact.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundColor(.green)
                            .font(.title2)
                            .background(Circle().fill(Color.white))
                    }
                }
                
                // Name and verification
                VStack(spacing: 8) {
                    Text(contact.displayName)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    if contact.isVerified {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundColor(.green)
                            Text("Device Verified")
                                .font(.subheadline)
                                .foregroundColor(.green)
                        }
                    }
                    
                    if let phoneNumber = contact.phoneNumber {
                        Text(phoneNumber)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    if let email = contact.email {
                        Text(email)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Call buttons
                HStack(spacing: 40) {
                    // Voice call
                    Button(action: {
                        dismiss()
                        onCall()
                    }) {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 72, height: 72)
                                Image(systemName: "phone.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                            }
                            Text("Voice Call")
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }
                    
                    // Video call (placeholder)
                    Button(action: {
                        // Video call not implemented yet
                    }) {
                        VStack(spacing: 8) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 72, height: 72)
                                Image(systemName: "video.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                            }
                            Text("Video Call")
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                    }
                    .disabled(true)
                    .opacity(0.6)
                }
                
                Spacer()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Preview
struct ContactListView_Previews: PreviewProvider {
    static var previews: some View {
        ContactListView()
    }
}
