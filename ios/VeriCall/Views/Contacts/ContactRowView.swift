import SwiftUI

struct ContactRowView: View {
    let contact: Contact
    let onCall: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // Avatar with verification badge
            ZStack(alignment: .bottomTrailing) {
                // Avatar circle
                ZStack {
                    Circle()
                        .fill(contact.isVerified ? Color.green.opacity(0.15) : Color.gray.opacity(0.15))
                        .frame(width: 50, height: 50)
                    
                    if let avatarUrl = contact.avatarUrl, let url = URL(string: avatarUrl) {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            Text(contact.initials)
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(contact.isVerified ? .green : .gray)
                        }
                        .frame(width: 50, height: 50)
                        .clipShape(Circle())
                    } else {
                        Text(contact.initials)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(contact.isVerified ? .green : .gray)
                    }
                }
                
                // Verification badge
                if contact.isVerified {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 16))
                        .background(
                            Circle()
                                .fill(Color.white)
                                .frame(width: 18, height: 18)
                        )
                        .offset(x: 2, y: 2)
                }
            }
            
            // Contact info
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(contact.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                    
                    if contact.isVerified {
                        Image(systemName: "checkmark.shield")
                            .foregroundColor(.green)
                            .font(.caption)
                    }
                }
                
                if let phoneNumber = contact.phoneNumber {
                    Text(phoneNumber)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if let email = contact.email {
                    Text(email)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                if let lastContacted = contact.lastContactedAt {
                    Text("Last called \(timeAgo(from: lastContacted))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Call button
            Button(action: onCall) {
                Image(systemName: "phone.fill")
                    .font(.system(size: 16))
                    .foregroundColor(contact.isVerified ? .green : .blue)
                    .frame(width: 36, height: 36)
                    .background(
                        Circle()
                            .fill(contact.isVerified ? Color.green.opacity(0.15) : Color.blue.opacity(0.15))
                    )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 4)
    }
    
    private func timeAgo(from date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Preview
struct ContactRowView_Previews: PreviewProvider {
    static var previews: some View {
        List {
            ContactRowView(
                contact: Contact(
                    id: "1",
                    name: "Alice Johnson",
                    phoneNumber: "+1 (555) 123-4567",
                    email: "alice@example.com",
                    isVerified: true,
                    isFavorite: false,
                    avatarUrl: nil,
                    lastContactedAt: Date()
                )
            ) {}
            
            ContactRowView(
                contact: Contact(
                    id: "2",
                    name: "Bob Smith",
                    phoneNumber: "+1 (555) 987-6543",
                    email: "bob@example.com",
                    isVerified: false,
                    isFavorite: true,
                    avatarUrl: nil,
                    lastContactedAt: Date()
                )
            ) {}
        }
    }
}
