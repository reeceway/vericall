import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @State private var showVoiceEnrollment = false
    @State private var showEnrollmentComplete = false
    @State private var hasVoiceSignature = false

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

                // Voice enrollment section
                Section(header: Text("Voice Verification")) {
                    Button(action: { showVoiceEnrollment = true }) {
                        HStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(hasVoiceSignature ? Color.green.opacity(0.15) : Color.veriBlue.opacity(0.15))
                                    .frame(width: 36, height: 36)
                                Image(systemName: hasVoiceSignature ? "checkmark.seal.fill" : "waveform.circle.fill")
                                    .foregroundColor(hasVoiceSignature ? .green : .veriBlue)
                                    .font(.system(size: 18))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(hasVoiceSignature ? "Re-record Voice Thumbprint" : "Record Voice Thumbprint")
                                    .foregroundColor(.primary)
                                Text(hasVoiceSignature ? "Your voice signature is enrolled" : "Set up voice verification for calls")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            if hasVoiceSignature {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                            }

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
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
            .sheet(isPresented: $showVoiceEnrollment) {
                SelfVoiceEnrollmentView(onComplete: {
                    showVoiceEnrollment = false
                    hasVoiceSignature = true
                    // Update UserDefaults to reflect enrollment completion
                    UserDefaults.standard.set(true, forKey: Constants.UserDefaultsKeys.hasCompletedVoiceEnrollment)
                })
                .environmentObject(authService)
            }
            .sheet(isPresented: $showEnrollmentComplete) {
                NavigationView {
                    VoiceEnrollmentCompleteView(
                        contactName: "Your Voice",
                        onDone: {
                            showEnrollmentComplete = false
                        },
                        onAddAnother: {
                            showEnrollmentComplete = false
                        }
                    )
                }
            }
            .onAppear {
                checkVoiceSignature()
            }
        }
    }

    private var initials: String {
        if let name = authService.currentUser?.displayName, !name.isEmpty {
            return String(name.prefix(2)).uppercased()
        }
        return "VC"
    }

    private func checkVoiceSignature() {
        let keychainService = VoiceKeychainService()
        if let _ = try? keychainService.loadSignature(for: "self") {
            hasVoiceSignature = true
        }
    }
}