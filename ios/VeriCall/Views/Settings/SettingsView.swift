import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @State private var showDeleteConfirmation = false
    @State private var deleteErrorMessage: String?
    @State private var isDeletingAccount = false

    var body: some View {
        NavigationView {
            List {
                profileSection
                protectionSection
                accountActionsSection
                aboutSection
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .confirmationDialog(
                "Delete Vicall account?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Account", role: .destructive) {
                    deleteAccount()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Your MSP manages billing and deployment. Deleting your Vicall account removes your access and device data immediately, but it does not cancel your company's MSP service. Your seat remains billable through the current month.")
            }
            .alert(
                "Unable to Delete Account",
                isPresented: Binding(
                    get: { deleteErrorMessage != nil },
                    set: { if !$0 { deleteErrorMessage = nil } }
                ),
                actions: {
                    Button("OK", role: .cancel) { }
                },
                message: {
                    Text(deleteErrorMessage ?? "Something went wrong.")
                }
            )
            .overlay {
                if isDeletingAccount {
                    ZStack {
                        Color.black.opacity(0.18)
                            .ignoresSafeArea()
                        ProgressView("Deleting account…")
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
        }
    }

    private var profileSection: some View {
        Section {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.veriBlue.opacity(0.18))
                        .frame(width: 60, height: 60)

                    Text(initials)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.veriBlue)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(authService.currentUser?.displayName ?? "\(Constants.appName) User")
                        .font(.headline)
                    Text(authService.currentUser?.phoneNumber ?? "")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var protectionSection: some View {
        Section {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.green.opacity(0.15))
                        .frame(width: 40, height: 40)

                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundColor(.green)
                        .font(.system(size: 18, weight: .semibold))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Live Voice Protection")
                        .foregroundColor(.primary)
                    Text("Flags likely synthetic voices during \(Constants.appName) calls.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
        } header: {
            Text("Protection")
        } footer: {
            Text("Voice checking runs during calls and only alerts when the model has enough signal to be useful.")
        }
    }

    private var accountActionsSection: some View {
        Section {
            Button {
                showDeleteConfirmation = true
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.red.opacity(0.12))
                            .frame(width: 42, height: 42)

                        Image(systemName: "trash.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.red)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Delete Vicall Account")
                            .font(.headline)
                            .foregroundColor(.red)
                        Text("Removes this device's access now. Your MSP can add you back later with an access code.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer()
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await authService.logout() }
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.gray.opacity(0.12))
                            .frame(width: 42, height: 42)

                        Image(systemName: "arrow.backward.circle.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.primary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sign Out")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("Keeps your account active and signs this device out.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }

                    Spacer()
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } header: {
            Text("Account")
        } footer: {
            Text("Your MSP manages company billing and rollout. Deleting your Vicall account removes your local device data and active access immediately. Your seat remains billable through the current month, and your MSP can reprovision you later if needed.")
        }
    }

    private var aboutSection: some View {
        Section(header: Text("About")) {
            HStack {
                Text("App")
                Spacer()
                Text(Constants.appName)
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Version")
                Spacer()
                Text("1.0.0")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var initials: String {
        if let name = authService.currentUser?.displayName, !name.isEmpty {
            return String(name.prefix(2)).uppercased()
        }
        return "VC"
    }

    private func deleteAccount() {
        isDeletingAccount = true
        deleteErrorMessage = nil
        Task {
            do {
                try await authService.deleteAccount()
            } catch {
                deleteErrorMessage = error.localizedDescription
            }
            isDeletingAccount = false
        }
    }
}
