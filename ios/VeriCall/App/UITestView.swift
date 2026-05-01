import SwiftUI

struct UITestView: View {
    @State private var confidence: Float = 0.95
    @State private var isHuman: Bool = true

    private var detectionResult: DeepfakeDetectionResult {
        DeepfakeDetectionResult(
            isHuman: isHuman,
            confidence: confidence,
            label: isHuman ? "real" : "fake",
            timestamp: Date(),
            processingTimeMs: 18.0
        )
    }

    var body: some View {
        VStack(spacing: 40) {
            Text("UI Isolation Test")
                .font(.largeTitle)
                .padding(.top, 60)

            Spacer()

            DeepfakeIndicatorView(
                result: detectionResult,
                isAnalyzing: false
            )
            .padding()
            .background(Color.gray.opacity(0.1))
            .cornerRadius(12)

            Spacer()

            VStack(spacing: 20) {
                Text("Confidence: \(Int(confidence * 100))%")
                    .font(.title2)
                    .fontWeight(.bold)

                Slider(value: $confidence, in: 0...1, step: 0.01)
                    .padding(.horizontal)

                Toggle("Is Human", isOn: $isHuman)
                    .padding(.horizontal)
            }
            .padding()

            Spacer()
        }
    }
}

struct UITestView_Previews: PreviewProvider {
    static var previews: some View {
        UITestView()
    }
}

enum AppStoreScreenshotKind: String, CaseIterable {
    case home
    case incoming
    case activeHuman = "active-human"
    case activeWarning = "active-warning"
    case contacts

    static func current() -> AppStoreScreenshotKind? {
        let env = ProcessInfo.processInfo.environment
        if let value = env["VICALL_SCREENSHOT_KIND"], let kind = AppStoreScreenshotKind(rawValue: value) {
            return kind
        }

        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-app-store-screenshot") else { return nil }
        let valueIndex = args.index(after: index)
        guard valueIndex < args.endIndex else { return .home }
        return AppStoreScreenshotKind(rawValue: args[valueIndex]) ?? .home
    }
}

struct AppStoreScreenshotView: View {
    let kind: AppStoreScreenshotKind

    var body: some View {
        Group {
            switch kind {
            case .home:
                screenshotHome
            case .incoming:
                screenshotIncoming
            case .activeHuman:
                screenshotActive(spoof: humanSpoof)
            case .activeWarning:
                screenshotActive(spoof: fakeSpoof)
            case .contacts:
                screenshotContacts
            }
        }
    }

    private var screenshotHome: some View {
        ZStack {
            LinearGradient(
                colors: [Color.veriBlue.opacity(0.1), Color(UIColor.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(Constants.appName.uppercased())
                                .font(.system(size: 34, weight: .black, design: .monospaced))
                                .tracking(1.8)
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.veriBlue, .veriLightBlue],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )

                            Spacer()

                            ConnectionIndicator(status: .connected)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 60)

                    VStack(alignment: .leading, spacing: 16) {
                        Text("Favorites")
                            .font(.title3)
                            .fontWeight(.bold)
                            .padding(.horizontal, 24)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 20) {
                                AddFavoriteButton(action: {})

                                ForEach(sampleContacts.prefix(3)) { contact in
                                    PremiumFavoriteItem(contact: contact) {}
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.bottom, 8)
                        }
                    }

                    VStack(alignment: .leading, spacing: 20) {
                        HStack {
                            Text("Recents")
                                .font(.title3)
                                .fontWeight(.bold)

                            Spacer()

                            Picker("Filter", selection: .constant(HomeView.CallFilter.all)) {
                                Text("All").tag(HomeView.CallFilter.all)
                                Text("Missed").tag(HomeView.CallFilter.missed)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 140)
                        }
                        .padding(.horizontal, 24)

                        LazyVStack(spacing: 12) {
                            ForEach(sampleHistory) { entry in
                                PremiumRecentsRow(
                                    entry: entry,
                                    isFavorite: sampleContacts.contains(where: {
                                        $0.id == (entry.call.direction == .incoming ? entry.call.callerId : entry.call.recipientId)
                                    }),
                                    onCallBack: {},
                                    onToggleFavorite: {}
                                )
                                .padding(.horizontal, 20)
                            }
                        }
                    }

                    Color.clear.frame(height: 120)
                }
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: {}) {
                        Image(systemName: "phone.fill.badge.plus")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 64, height: 64)
                            .background(
                                LinearGradient(
                                    colors: [.veriBlue, .veriBlue.opacity(0.8)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
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
    }

    private var screenshotIncoming: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.95),
                    Color(red: 0.02, green: 0.1, blue: 0.02)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 80)

                Text("\(Constants.appName) Incoming")
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundColor(.white.opacity(0.8))

                Spacer().frame(height: 16)

                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.title2)
                    Text("✓ Device Verified")
                        .font(.title3)
                        .fontWeight(.semibold)
                }
                .foregroundColor(.green)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(
                    Capsule()
                        .fill(Color.green.opacity(0.2))
                        .overlay(Capsule().stroke(Color.green.opacity(0.5), lineWidth: 1))
                )

                Spacer().frame(height: 32)

                ZStack {
                    Circle()
                        .stroke(Color.green.opacity(0.2), lineWidth: 2)
                        .frame(width: 160, height: 160)
                    Circle()
                        .fill(Color.green.opacity(0.3))
                        .frame(width: 120, height: 120)

                    Text("RW")
                        .font(.system(size: 48, weight: .medium))
                        .foregroundColor(.green)
                }
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .font(.title)
                        .background(Circle().fill(Color.black))
                }

                Spacer().frame(height: 24)

                Text("Reece Way")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundColor(.white)

                Spacer().frame(height: 8)

                Text("\(Constants.appName) Voice")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.6))

                Text("Voice check starts when you answer")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.top, 8)

                Spacer()

                HStack(spacing: 60) {
                    screenshotCallButton(icon: "phone.down.fill", label: "Decline", color: .red)
                    screenshotCallButton(icon: "phone.fill", label: "Accept", color: .green)
                }
                .padding(.bottom, 80)
            }
            .padding()
        }
    }

    private func screenshotActive(spoof: SpoofResult) -> some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.95),
                    Color(red: 0.05, green: 0.05, blue: 0.15)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 70)

                Text("Connected")
                    .font(.title3)
                    .fontWeight(.medium)
                    .foregroundColor(.white.opacity(0.8))

                Spacer().frame(height: 24)

                Circle()
                    .fill(chipColor(for: spoof).opacity(0.25))
                    .frame(width: 140, height: 140)
                    .overlay(
                        Text("RW")
                            .font(.system(size: 56, weight: .medium))
                            .foregroundColor(chipColor(for: spoof))
                    )

                Spacer().frame(height: 16)

                Text("Reece Way")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(.white)

                Spacer().frame(height: 8)

                Text("04:18")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .monospacedDigit()

                Spacer().frame(height: 24)

                ScreenshotVerificationChip(
                    icon: chipIcon(for: spoof),
                    label: chipLabel(for: spoof),
                    sublabel: chipSublabel(for: spoof),
                    color: chipColor(for: spoof)
                )
                .padding(.horizontal, 24)

                Spacer()

                VStack(spacing: 40) {
                    HStack(spacing: 60) {
                        screenshotControl(icon: "mic.fill", label: "Mute", color: .white, background: Color.white.opacity(0.2))
                        screenshotControl(icon: "speaker.wave.3.fill", label: "Speaker", color: .green, background: Color.green.opacity(0.3))
                    }

                    Button(action: {}) {
                        HStack(spacing: 12) {
                            Image(systemName: "phone.down.fill")
                                .font(.title2)
                            Text("End Call")
                                .font(.title3)
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 64)
                        .background(Capsule().fill(Color.red))
                    }
                    .padding(.horizontal, 40)
                }
                .padding(.bottom, 40)

                Spacer().frame(height: 40)
            }
            .padding()
        }
    }

    private var screenshotContacts: some View {
        NavigationStack {
            List {
                HStack {
                    ConnectionStatusView(status: .connected)
                    Spacer()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .padding(.horizontal)
                .padding(.vertical, 4)

                Section(header: Text("\(Constants.appName) Users")) {
                    ForEach(sampleContacts.filter(\.isVerified)) { contact in
                        ContactRowView(contact: contact, onCall: {})
                    }
                }

                Section(header: Text("Other Contacts")) {
                    ForEach(sampleContacts.filter { !$0.isVerified }) { contact in
                        ContactRowView(contact: contact, onCall: {})
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Contacts")
        }
    }

    private func screenshotCallButton(icon: String, label: String, color: Color) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: 80, height: 80)
                Image(systemName: icon)
                    .font(.title)
                    .foregroundColor(.white)
            }
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.white)
        }
    }

    private func screenshotControl(icon: String, label: String, color: Color, background: Color) -> some View {
        VStack(spacing: 12) {
            Circle()
                .fill(background)
                .frame(width: 72, height: 72)
                .overlay(
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundColor(color)
                )
            Text(label)
                .font(.subheadline)
                .foregroundColor(.white)
        }
    }

    private func chipLabel(for spoof: SpoofResult) -> String {
        switch spoof.verdict {
	        case .human:
	            return "Human Voice"
	        case .likelyFake:
	            return "Highly Likely Synthetic"
	        case .uncertain:
	            return "Likely Synthetic Voice"
        }
    }

    private func chipSublabel(for spoof: SpoofResult) -> String {
	        switch spoof.verdict {
	        case .human:
	            return "Live speech verified"
	        case .likelyFake:
	            return "Do not trust this voice"
	        case .uncertain:
	            return "Do not trust this voice yet"
	        }
    }

    private func chipIcon(for spoof: SpoofResult) -> String {
        switch spoof.verdict {
        case .human:
            return "checkmark.shield.fill"
        case .likelyFake:
            return "exclamationmark.triangle.fill"
        case .uncertain:
            return "waveform.badge.magnifyingglass"
        }
    }

    private func chipColor(for spoof: SpoofResult) -> Color {
        switch spoof.verdict {
        case .human:
            return .green
        case .likelyFake:
            return .red
        case .uncertain:
            return .orange
        }
    }

    private var sampleContacts: [Contact] {
        [
            Contact(
                id: "contact-reece",
                name: "Reece Way",
                phoneNumber: "+1 (412) 862-8887",
                email: nil,
                isVerified: true,
                isFavorite: true,
                avatarUrl: nil,
                lastContactedAt: Date().addingTimeInterval(-3600)
            ),
            Contact(
                id: "contact-jordan",
                name: "Jordan Mills",
                phoneNumber: "+1 (412) 555-0112",
                email: nil,
                isVerified: true,
                isFavorite: true,
                avatarUrl: nil,
                lastContactedAt: Date().addingTimeInterval(-18_000)
            ),
            Contact(
                id: "contact-avery",
                name: "Avery Chen",
                phoneNumber: "+1 (724) 555-0146",
                email: nil,
                isVerified: true,
                isFavorite: false,
                avatarUrl: nil,
                lastContactedAt: Date().addingTimeInterval(-86_400)
            ),
            Contact(
                id: "contact-taylor",
                name: "Taylor Brooks",
                phoneNumber: "+1 (330) 555-0182",
                email: nil,
                isVerified: false,
                isFavorite: false,
                avatarUrl: nil,
                lastContactedAt: Date().addingTimeInterval(-172_800)
            ),
            Contact(
                id: "contact-riley",
                name: "Riley Warren",
                phoneNumber: "+1 (216) 555-0177",
                email: nil,
                isVerified: false,
                isFavorite: true,
                avatarUrl: nil,
                lastContactedAt: Date().addingTimeInterval(-240_000)
            )
        ]
    }

    private var sampleHistory: [CallHistoryEntry] {
        [
            CallHistoryEntry(
                id: "history-1",
                call: Call(
                    id: "call-1",
                    callerId: "user_14128628887_prod1",
                    callerName: "Reece Way",
                    recipientId: "user_14125550199_prod1",
                    recipientName: "You",
                    direction: .incoming,
                    state: .connected,
                    startedAt: Date().addingTimeInterval(-3600),
                    endedAt: Date().addingTimeInterval(-3300),
                    isVerified: true
                ),
                timestamp: Date().addingTimeInterval(-3600),
                isRead: true
            ),
            CallHistoryEntry(
                id: "history-2",
                call: Call(
                    id: "call-2",
                    callerId: "user_13305550182_prod1",
                    callerName: "Taylor Brooks",
                    recipientId: "user_14125550199_prod1",
                    recipientName: "You",
                    direction: .incoming,
                    state: .missed,
                    startedAt: Date().addingTimeInterval(-15_000),
                    endedAt: Date().addingTimeInterval(-14_940),
                    isVerified: false
                ),
                timestamp: Date().addingTimeInterval(-15_000),
                isRead: false
            ),
            CallHistoryEntry(
                id: "history-3",
                call: Call(
                    id: "call-3",
                    callerId: "user_14125550199_prod1",
                    callerName: "You",
                    recipientId: "user_17245550146_prod1",
                    recipientName: "Avery Chen",
                    direction: .outgoing,
                    state: .connected,
                    startedAt: Date().addingTimeInterval(-86_400),
                    endedAt: Date().addingTimeInterval(-86_180),
                    isVerified: true
                ),
                timestamp: Date().addingTimeInterval(-86_400),
                isRead: true
            )
        ]
    }

    private var humanSpoof: SpoofResult {
        SpoofResult(
            cloneProbability: 0.06,
            threshold: AudioConfiguration.spoofHumanThresholdCall,
            supportingWindows: 5,
            processingTimeMs: 18,
            rms: 0.012
        )
    }

    private var fakeSpoof: SpoofResult {
        SpoofResult(
            cloneProbability: 0.995,
            threshold: AudioConfiguration.spoofHumanThresholdCall,
            supportingWindows: 5,
            processingTimeMs: 18,
            rms: 0.014
        )
    }
}

private struct ScreenshotVerificationChip: View {
    let icon: String
    let label: String
    let sublabel: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.subheadline)
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            .foregroundColor(color)

            Text(sublabel)
                .font(.caption2)
                .foregroundColor(color.opacity(0.75))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(color.opacity(0.15))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(color.opacity(0.4), lineWidth: 1)
                )
        )
    }
}
