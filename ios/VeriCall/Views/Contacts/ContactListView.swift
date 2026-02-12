import SwiftUI
import Contacts

struct ContactListView: View {
    @StateObject private var viewModel = ContactListViewModel()
    @State private var searchText = ""
    @State private var selectedContact: Contact?

    var filteredContacts: [Contact] {
        if searchText.isEmpty {
            return viewModel.contacts
        }
        return viewModel.contacts.filter { contact in
            contact.name.localizedCaseInsensitiveContains(searchText) ||
            (contact.phoneNumber?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
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

                if !viewModel.contactsPermissionGranted {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("VeriCall needs access to your contacts to identify VeriCall users you can verify calls with.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                            Button("Grant Access") {
                                viewModel.requestContactsPermission()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                    }
                }

                if !filteredVerifiedContacts.isEmpty {
                    Section(header: Text("VeriCall Users")) {
                        ForEach(filteredVerifiedContacts) { contact in
                            ContactRowView(contact: contact, onCall: {
                                initiateCall(to: contact)
                            }, onToggleFavorite: {
                                viewModel.toggleFavorite(contact: contact)
                            })
                            .swipeActions(edge: .leading) {
                                Button {
                                    viewModel.toggleFavorite(contact: contact)
                                } label: {
                                    Label(contact.isFavorite ? "Unfavorite" : "Favorite", 
                                          systemImage: contact.isFavorite ? "heart.slash" : "heart")
                                }
                                .tint(contact.isFavorite ? .gray : .pink)
                            }
                        }
                    }
                }

                if !filteredUnverifiedContacts.isEmpty {
                    Section(header: Text("Other Contacts")) {
                        ForEach(filteredUnverifiedContacts) { contact in
                            ContactRowView(contact: contact, onCall: {
                                initiateCall(to: contact)
                            }, onToggleFavorite: {
                                viewModel.toggleFavorite(contact: contact)
                            })
                            .swipeActions(edge: .leading) {
                                Button {
                                    viewModel.toggleFavorite(contact: contact)
                                } label: {
                                    Label(contact.isFavorite ? "Unfavorite" : "Favorite", 
                                          systemImage: contact.isFavorite ? "heart.slash" : "heart")
                                }
                                .tint(contact.isFavorite ? .gray : .pink)
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
                ContactCallSheet(contact: contact, onCall: {
                    selectedContact = nil
                    makePhoneCall(to: contact)
                }, onVoIPCall: {
                    selectedContact = nil
                    makeVoIPCall(to: contact)
                })
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
        .onAppear {
            viewModel.loadContacts()
        }
    }

    private var filteredVerifiedContacts: [Contact] {
        filteredContacts.filter { $0.isVerified }.sorted { $0.name < $1.name }
    }

    private var filteredUnverifiedContacts: [Contact] {
        filteredContacts.filter { !$0.isVerified }.sorted { $0.name < $1.name }
    }

    private func initiateCall(to contact: Contact) {
        selectedContact = contact
    }

    private func makeVoIPCall(to contact: Contact) {
        Task {
            await VoIPCallService.shared.initiateCall(to: contact)
        }
    }

    private func makePhoneCall(to contact: Contact) {
        guard let phoneNumber = contact.phoneNumber else { return }

        let cleaned = phoneNumber.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")

        Task {
            // Send the handshake BEFORE opening the Phone app.
            // Once we open tel: URL, VeriCall goes to background and WebSocket drops.
            await NativeCallObserver.shared.sendHandshakeBeforeCall(to: cleaned)

            // Now open the Phone app
            if let url = URL(string: "tel://\(cleaned)") {
                await UIApplication.shared.open(url)
            }
        }
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
    @Published var contactsPermissionGranted = false

    private let contactStore = CNContactStore()
    private let apiService = APIService.shared
    private let webSocketService = WebSocketService.shared
    private let authKeychain = KeychainService.shared

    init() {
        webSocketService.$connectionStatus
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionStatus)

        checkContactsPermission()
    }

    // MARK: - Contacts Permission

    private func checkContactsPermission() {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        contactsPermissionGranted = (status == .authorized)
    }

    func requestContactsPermission() {
        contactStore.requestAccess(for: .contacts) { [weak self] granted, error in
            Task { @MainActor in
                self?.contactsPermissionGranted = granted
                if granted {
                    self?.loadContacts()
                }
            }
        }
    }

    // MARK: - Load Contacts

    func loadContacts() {
        guard contactsPermissionGranted else {
            checkContactsPermission()
            if contactsPermissionGranted {
                loadContacts()
            }
            return
        }

        isLoading = true

        Task {
            do {
                // 1. Fetch device contacts
                let deviceContacts = try fetchDeviceContacts()

                // 2. Extract phone numbers and sync with backend
                let phoneNumbers = deviceContacts.compactMap { $0.phoneNumber }
                async let verifiedNumbersTask = syncWithBackend(phoneNumbers: phoneNumbers)
                async let favoritesTask = StorageService.shared.getFavoriteIds()
                
                let (veriCallPhoneNumbers, favoriteIds) = await (verifiedNumbersTask, favoritesTask)

                var updatedContacts = deviceContacts
                for i in updatedContacts.indices {
                    if let phone = updatedContacts[i].phoneNumber {
                        updatedContacts[i].isVerified = veriCallPhoneNumbers.contains(normalizePhoneNumber(phone))
                    }
                    // Sync favorites status
                    updatedContacts[i].isFavorite = favoriteIds.contains(updatedContacts[i].id)
                }

                contacts = updatedContacts
                isLoading = false
            } catch {
                errorMessage = "Failed to load contacts: \(error.localizedDescription)"
                showError = true
                isLoading = false
            }
        }
    }

    private func fetchDeviceContacts() throws -> [Contact] {
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactImageDataAvailableKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keysToFetch)
        request.sortOrder = .givenName

        var result: [Contact] = []

        try contactStore.enumerateContacts(with: request) { cnContact, _ in
            // Only include contacts that have at least one phone number
            guard let primaryPhone = cnContact.phoneNumbers.first else { return }

            let name = [cnContact.givenName, cnContact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            guard !name.isEmpty else { return }

            let email = cnContact.emailAddresses.first?.value as String?

            let contact = Contact(
                id: cnContact.identifier,
                name: name,
                phoneNumber: primaryPhone.value.stringValue,
                email: email,
                isVerified: false,
                isFavorite: false,
                avatarUrl: nil,
                lastContactedAt: nil
            )

            result.append(contact)
        }

        return result
    }

    private func syncWithBackend(phoneNumbers: [String]) async -> Set<String> {
        guard let accessToken = try? await authKeychain.retrieveString(
            service: "VeriCall",
            account: Constants.KeychainKeys.accessToken
        ) else {
            return []
        }

        do {
            let matchedNumbers = try await apiService.syncContacts(
                phoneNumbers: phoneNumbers,
                accessToken: accessToken
            )
            return Set(matchedNumbers.map { normalizePhoneNumber($0) })
        } catch {
            print("[ContactList] Failed to sync contacts: \(error)")
            return []
        }
    }

    private func normalizePhoneNumber(_ number: String) -> String {
        let digits = number.filter { $0.isNumber || $0 == "+" }
        // Normalize Australian numbers: 04xx → +614xx
        if digits.hasPrefix("0") && digits.count == 10 {
            return "+61" + digits.dropFirst()
        }
        return digits
    }

    func refreshContacts() {
        loadContacts()
    }

    func refreshContactsAsync() async {
        await MainActor.run {
            loadContacts()
        }
    }
    
    func toggleFavorite(contact: Contact) {
        Task {
            await StorageService.shared.toggleFavorite(contactId: contact.id)
            await MainActor.run {
                if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
                    contacts[index].isFavorite.toggle()
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
    var onVoIPCall: () -> Void = {}
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
                            Text("VeriCall User")
                                .font(.subheadline)
                                .foregroundColor(.green)
                        }
                    }

                    if let phoneNumber = contact.phoneNumber {
                        Text(phoneNumber)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    if contact.isVerified {
                        Text("Voice verification will be active during this call")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                }

                Spacer()

                // VoIP call button (primary — works with voice verification)
                Button(action: {
                    dismiss()
                    onVoIPCall()
                }) {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.veriBlue)
                                .frame(width: 72, height: 72)
                            Image(systemName: "phone.connection.fill")
                                .font(.title)
                                .foregroundColor(.white)
                        }
                        Text("VeriCall")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                        if contact.isVerified {
                            Text("Voice Verified")
                                .font(.caption2)
                                .foregroundColor(.green)
                        }
                    }
                }
                
                // Regular phone call button (fallback)
                Button(action: {
                    dismiss()
                    onCall()
                }) {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 56, height: 56)
                            Image(systemName: "phone.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                        }
                        Text("Phone")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
