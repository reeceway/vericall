import SwiftUI

// Superseded by HomeView
struct CallHistoryView: View {
    @StateObject private var viewModel = CallHistoryViewModel()
    @State private var selectedFilter: CallFilter = .all
    
    enum CallFilter: String, CaseIterable {
        case all = "All"
        case missed = "Missed"
        case incoming = "Incoming"
        case outgoing = "Outgoing"
        case verified = "Verified"
    }
    
    var filteredHistory: [CallHistoryEntry] {
        switch selectedFilter {
        case .all:
            return viewModel.callHistory
        case .missed:
            return viewModel.callHistory.filter { $0.call.state == .missed }
        case .incoming:
            return viewModel.callHistory.filter { $0.call.direction == .incoming }
        case .outgoing:
            return viewModel.callHistory.filter { $0.call.direction == .outgoing }
        case .verified:
            return viewModel.callHistory.filter { $0.call.isVerified }
        }
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Filter pills
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CallFilter.allCases, id: \.self) { filter in
                            FilterPill(
                                title: filter.rawValue,
                                isSelected: selectedFilter == filter,
                                count: countFor(filter: filter)
                            ) {
                                withAnimation(.spring()) {
                                    selectedFilter = filter
                                }
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                
                List {
                    ForEach(groupedHistory.keys.sorted(by: >), id: \.self) { date in
                        Section(header: Text(formatDate(date))) {
                            ForEach(groupedHistory[date] ?? []) { entry in
                                CallHistoryRow(entry: entry) {
                                    viewModel.callBack(entry)
                                }
                            }
                            .onDelete { indexSet in
                                viewModel.deleteEntries(at: indexSet, for: date)
                            }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .overlay {
                    if filteredHistory.isEmpty {
                        EmptyHistoryView(filter: selectedFilter)
                    }
                }
            }
            .navigationTitle("Recents")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { viewModel.clearAllHistory() }) {
                            Label("Clear All History", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .refreshable {
                await viewModel.refreshHistory()
            }
        }
        .onAppear {
            viewModel.loadHistory()
        }
    }
    
    private var groupedHistory: [Date: [CallHistoryEntry]] {
        Dictionary(grouping: filteredHistory) { entry in
            Calendar.current.startOfDay(for: entry.timestamp)
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE, MMM d"
            return formatter.string(from: date)
        }
    }
    
    private func countFor(filter: CallFilter) -> Int {
        switch filter {
        case .all:
            return viewModel.callHistory.count
        case .missed:
            return viewModel.callHistory.filter { $0.call.state == .missed }.count
        case .incoming:
            return viewModel.callHistory.filter { $0.call.direction == .incoming }.count
        case .outgoing:
            return viewModel.callHistory.filter { $0.call.direction == .outgoing }.count
        case .verified:
            return viewModel.callHistory.filter { $0.call.isVerified }.count
        }
    }
}

// MARK: - Call History Row
struct CallHistoryRow: View {
    let entry: CallHistoryEntry
    let onCallBack: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Call direction icon
            ZStack {
                Circle()
                    .fill(iconBackgroundColor)
                    .frame(width: 36, height: 36)
                
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundColor(iconColor)
            }
            
            // Call info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.call.direction == .incoming ? entry.call.callerName : entry.call.recipientName)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(entry.call.state == .missed ? .red : .primary)
                    
                    if entry.call.isVerified {
                        Image(systemName: "checkmark.shield")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
                
                HStack(spacing: 6) {
                    Text(entry.call.direction.displayText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if entry.call.duration > 0 {
                        Text("• \(entry.call.formattedDuration)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                }
            }
            
            Spacer()
            
            // Time and call button
            HStack(spacing: 12) {
                Text(formatTime(entry.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Button(action: onCallBack) {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 14))
                        .foregroundColor(entry.call.isVerified ? .green : .blue)
                        .frame(width: 32, height: 32)
                        .background(
                            Circle()
                                .fill(entry.call.isVerified ? Color.green.opacity(0.15) : Color.blue.opacity(0.15))
                        )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.vertical, 4)
    }
    
    private var iconName: String {
        switch entry.call.direction {
        case .incoming:
            if entry.call.state == .missed {
                return "phone.arrow.down.left.fill"
            }
            return "phone.arrow.down.left"
        case .outgoing:
            if entry.call.state == .failed || entry.call.state == .declined {
                return "phone.arrow.up.right.fill"
            }
            return "phone.arrow.up.right"
        }
    }
    
    private var iconColor: Color {
        switch entry.call.state {
        case .missed:
            return .red
        case .ended:
            return entry.call.isVerified ? .green : .blue
        case .failed, .declined:
            return .orange
        default:
            return .gray
        }
    }
    
    private var iconBackgroundColor: Color {
        switch entry.call.state {
        case .missed:
            return Color.red.opacity(0.15)
        case .ended:
            return entry.call.isVerified ? Color.green.opacity(0.15) : Color.blue.opacity(0.15)
        case .failed, .declined:
            return Color.orange.opacity(0.15)
        default:
            return Color.gray.opacity(0.15)
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }
}

// MARK: - Filter Pill
struct FilterPill: View {
    let title: String
    let isSelected: Bool
    let count: Int
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                
                if count > 0 {
                    Text("\(count)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.white.opacity(0.3) : Color.gray.opacity(0.2))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? Color.blue : Color.gray.opacity(0.2))
            )
            .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Empty History View
struct EmptyHistoryView: View {
    let filter: CallHistoryView.CallFilter
    
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
        case .incoming:
            return "No Incoming Calls"
        case .outgoing:
            return "No Outgoing Calls"
        case .verified:
            return "No Verified Calls"
        }
    }
    
    private var emptyMessage: String {
        switch filter {
        case .all:
            return "Your call history will appear here"
        case .missed:
            return "You haven't missed any calls"
        case .incoming:
            return "No incoming calls in your history"
        case .outgoing:
            return "No outgoing calls in your history"
        case .verified:
            return "Calls with verified devices will appear here"
        }
    }
}

// MARK: - ViewModel
@MainActor
class CallHistoryViewModel: ObservableObject {
    @Published var callHistory: [CallHistoryEntry] = []
    @Published var isLoading = false
    
    private let callManager = CallManager.shared
    
    func loadHistory() {
        // In a real app, fetch from API or CoreData
        // For now, using sample data
        let sampleCalls: [Call] = [
            Call(
                id: "1",
                callerId: "user1",
                callerName: "Alice Johnson",
                recipientId: "me",
                recipientName: "Me",
                direction: .incoming,
                state: .ended,
                startedAt: Date().addingTimeInterval(-3600),
                endedAt: Date().addingTimeInterval(-3300),
                isVerified: true
            ),
            Call(
                id: "2",
                callerId: "user2",
                callerName: "Unknown Caller",
                recipientId: "me",
                recipientName: "Me",
                direction: .incoming,
                state: .missed,
                startedAt: nil,
                endedAt: nil,
                isVerified: false
            ),
            Call(
                id: "3",
                callerId: "me",
                callerName: "Me",
                recipientId: "user3",
                recipientName: "Bob Smith",
                direction: .outgoing,
                state: .ended,
                startedAt: Date().addingTimeInterval(-86400),
                endedAt: Date().addingTimeInterval(-86100),
                isVerified: true
            ),
            Call(
                id: "4",
                callerId: "user4",
                callerName: "Carol White",
                recipientId: "me",
                recipientName: "Me",
                direction: .incoming,
                state: .declined,
                startedAt: nil,
                endedAt: nil,
                isVerified: false
            ),
            Call(
                id: "5",
                callerId: "me",
                callerName: "Me",
                recipientId: "user5",
                recipientName: "David Brown",
                direction: .outgoing,
                state: .ended,
                startedAt: Date().addingTimeInterval(-172800),
                endedAt: Date().addingTimeInterval(-171600),
                isVerified: true
            )
        ]
        
        callHistory = sampleCalls.map { call in
            CallHistoryEntry(
                id: call.id,
                call: call,
                timestamp: call.endedAt ?? call.startedAt ?? Date(),
                isRead: call.state != .missed
            )
        }.sorted { $0.timestamp > $1.timestamp }
    }
    
    func refreshHistory() async {
        await MainActor.run {
            loadHistory()
        }
    }
    
    func deleteEntries(at indexSet: IndexSet, for date: Date) {
        // In a real app, delete from persistent storage
        // For now, just remove from the array
        let calendar = Calendar.current
        let entriesForDate = callHistory.filter {
            calendar.isDate($0.timestamp, inSameDayAs: date)
        }
        
        let entriesToDelete = indexSet.map { entriesForDate[$0] }
        callHistory.removeAll { entry in
            entriesToDelete.contains { $0.id == entry.id }
        }
    }
    
    func clearAllHistory() {
        callHistory.removeAll()
    }
    
    func callBack(_ entry: CallHistoryEntry) {
        Task {
            do {
                let contactId = entry.call.direction == .incoming ? entry.call.callerId : entry.call.recipientId
                let contactName = entry.call.direction == .incoming ? entry.call.callerName : entry.call.recipientName
                
                let contact = Contact(
                    id: contactId,
                    name: contactName,
                    phoneNumber: nil,
                    email: nil,
                    isVerified: entry.call.isVerified,
                    isFavorite: false,
                    avatarUrl: nil,
                    lastContactedAt: nil
                )
                
                try await callManager.initiateCall(to: contact)
            } catch {
                print("Failed to call back: \(error)")
            }
        }
    }
}

// MARK: - Preview
struct CallHistoryView_Previews: PreviewProvider {
    static var previews: some View {
        CallHistoryView()
    }
}
