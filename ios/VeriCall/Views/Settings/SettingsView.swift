import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService

    var body: some View {
        NavigationView {
            List {
                // Profile section
                Section {
                    HStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(Color.veriBlue.opacity(0.2))
                                .frame(width: 60, height: 60)
                            Text(initials)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .foregroundColor(.veriBlue)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(authService.currentUser?.displayName ?? "VeriCall User")
                                .font(.headline)
                            Text(authService.currentUser?.phoneNumber ?? "")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                // AI Protection section
                Section(header: Text("AI Protection")) {
                    HStack {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.green.opacity(0.15))
                                .frame(width: 36, height: 36)
                            Image(systemName: "shield.checkered")
                                .foregroundColor(.green)
                                .font(.system(size: 18))
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI Deepfake Detection")
                                .foregroundColor(.primary)
                            Text("Automatically detects AI-generated voices during VoIP calls")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }

                // About section
                Section(header: Text("About")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                }

                // Logout
                Section {
                    Button(action: {
                        Task { await authService.logout() }
                    }) {
                        HStack {
                            Spacer()
                            Text("Sign Out")
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var initials: String {
        if let name = authService.currentUser?.displayName, !name.isEmpty {
            return String(name.prefix(2)).uppercased()
        }
        return "VC"
    }
}
