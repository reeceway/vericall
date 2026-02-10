import Foundation
import os.log

/// Comprehensive logging system for VeriCall
enum VeriCallLogger {
    // MARK: - Log Categories
    static let auth = Logger(subsystem: "com.vericall", category: "🔐 Auth")
    static let network = Logger(subsystem: "com.vericall", category: "🌐 Network")
    static let crypto = Logger(subsystem: "com.vericall", category: "🔑 Crypto")
    static let voice = Logger(subsystem: "com.vericall", category: "🎤 Voice")
    static let call = Logger(subsystem: "com.vericall", category: "📞 Call")
    static let websocket = Logger(subsystem: "com.vericall", category: "⚡ WebSocket")
    static let lifecycle = Logger(subsystem: "com.vericall", category: "🔄 Lifecycle")
    static let errors = Logger(subsystem: "com.vericall", category: "❌ Errors")
    static let debug = Logger(subsystem: "com.vericall", category: "🐛 Debug")
    
    // MARK: - Log Levels
    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
        case critical = "CRITICAL"
    }
    
    // MARK: - File Logging
    private static let logFileURL: URL = {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("vericall_logs.txt")
    }()
    
    /// Logs to both Console app and file
    static func log(
        _ message: String,
        level: Level = .info,
        category: Logger,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = (file as NSString).lastPathComponent
        let logEntry = "[\(timestamp)] [\(level.rawValue)] [\(fileName):\(line)] \(function): \(message)"
        
        // Log to Console app
        switch level {
        case .debug:
            category.debug("\(message)")
        case .info:
            category.info("\(message)")
        case .warning:
            category.warning("\(message)")
        case .error, .critical:
            category.error("\(message)")
        }
        
        // Log to file
        writeToFile(logEntry)
    }
    
    private static func writeToFile(_ entry: String) {
        do {
            let data = (entry + "\n").data(using: .utf8)!
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let handle = try FileHandle(forWritingTo: logFileURL)
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try data.write(to: logFileURL)
            }
        } catch {
            print("Failed to write log: \(error)")
        }
    }
    
    // MARK: - Convenience Methods
    static func logAuth(_ message: String, level: Level = .info) {
        log(message, level: level, category: auth)
    }
    
    static func logNetwork(_ message: String, level: Level = .info) {
        log(message, level: level, category: network)
    }
    
    static func logCrypto(_ message: String, level: Level = .info) {
        log(message, level: level, category: crypto)
    }
    
    static func logVoice(_ message: String, level: Level = .info) {
        log(message, level: level, category: voice)
    }
    
    static func logCall(_ message: String, level: Level = .info) {
        log(message, level: level, category: call)
    }
    
    static func logWebSocket(_ message: String, level: Level = .info) {
        log(message, level: level, category: websocket)
    }
    
    static func logError(_ error: Error, context: String) {
        let errorMessage = "❌ ERROR in \(context): \(error.localizedDescription)"
        log(errorMessage, level: .error, category: errors)
        
        // Log additional details if available
        if let nsError = error as NSError? {
            log("Domain: \(nsError.domain), Code: \(nsError.code)", level: .error, category: errors)
            log("UserInfo: \(nsError.userInfo)", level: .debug, category: errors)
        }
    }
    
    static func logRequest(_ request: URLRequest, level: Level = .debug) {
        var message = "📤 REQUEST: \(request.httpMethod ?? "UNKNOWN") \(request.url?.absoluteString ?? "nil")"
        if let headers = request.allHTTPHeaderFields {
            message += "\nHeaders: \(headers)"
        }
        if let body = request.httpBody, let bodyString = String(data: body, encoding: .utf8) {
            message += "\nBody: \(bodyString.prefix(1000))"
        }
        log(message, level: level, category: network)
    }
    
    static func logResponse(_ response: URLResponse?, data: Data?, error: Error?, level: Level = .debug) {
        if let error = error {
            log("📥 RESPONSE ERROR: \(error.localizedDescription)", level: .error, category: network)
            return
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            log("📥 RESPONSE: Invalid response type", level: .warning, category: network)
            return
        }
        
        var message = "📥 RESPONSE: \(httpResponse.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode))"
        
        if let data = data, let bodyString = String(data: data, encoding: .utf8) {
            message += "\nBody: \(bodyString.prefix(1000))"
        }
        
        let logLevel: Level = (200..<300).contains(httpResponse.statusCode) ? .debug : .warning
        log(message, level: logLevel, category: network)
    }
    
    static func logVoiceProcessing(
        stage: String,
        sampleCount: Int? = nil,
        duration: TimeInterval? = nil,
        features: [Float]? = nil,
        score: Float? = nil
    ) {
        var message = "🎤 VOICE [\(stage)]"
        if let count = sampleCount { message += " | Samples: \(count)" }
        if let dur = duration { message += String(format: " | Duration: %.2fs", dur) }
        if let feats = features { message += " | Features: \(feats.count)" }
        if let s = score { message += String(format: " | Score: %.2f", s) }
        log(message, level: .debug, category: voice)
    }
    
    static func logCryptoOperation(
        operation: String,
        success: Bool,
        details: String? = nil
    ) {
        let status = success ? "✅" : "❌"
        var message = "🔑 CRYPTO [\(operation)] \(status)"
        if let details = details { message += " | \(details)" }
        log(message, level: success ? .debug : .error, category: crypto)
    }
    
    static func logCallState(
        callId: String,
        from: String,
        to: String,
        state: String,
        details: String? = nil
    ) {
        var message = "📞 CALL [\(callId)] \(from) → \(to) | State: \(state)"
        if let details = details { message += " | \(details)" }
        log(message, level: .info, category: call)
    }
    
    // MARK: - Export Logs
    static func exportLogs() -> String? {
        do {
            let logs = try String(contentsOf: logFileURL)
            return logs
        } catch {
            logError(error, context: "Exporting logs")
            return nil
        }
    }
    
    static func clearLogs() {
        do {
            try FileManager.default.removeItem(at: logFileURL)
            log("Logs cleared", level: .info, category: lifecycle)
        } catch {
            logError(error, context: "Clearing logs")
        }
    }
}

// MARK: - View Lifecycle Logging
extension View {
    func logLifecycle(_ name: String) -> some View {
        self.onAppear {
            VeriCallLogger.log("👁️ \(name) appeared", level: .debug, category: VeriCallLogger.lifecycle)
        }
        .onDisappear {
            VeriCallLogger.log("🙈 \(name) disappeared", level: .debug, category: VeriCallLogger.lifecycle)
        }
    }
}

// MARK: - SwiftUI Debug Overlay
struct DebugLogView: View {
    @State private var logs: String = ""
    @State private var showCopied = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                Text(logs)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
            }
            .navigationTitle("Debug Logs")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Copy") {
                        UIPasteboard.general.string = logs
                        showCopied = true
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") {
                        VeriCallLogger.clearLogs()
                        loadLogs()
                    }
                }
            }
        }
        .onAppear {
            loadLogs()
        }
        .overlay(
            Group {
                if showCopied {
                    Text("Copied!")
                        .padding()
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                showCopied = false
                            }
                        }
                }
            }
        )
    }
    
    private func loadLogs() {
        logs = VeriCallLogger.exportLogs() ?? "No logs available"
    }
}

// MARK: - Debug Gesture
extension View {
    func enableDebugMenu() -> some View {
        self.onShakeGesture {
            NotificationCenter.default.post(name: .showDebugMenu, object: nil)
        }
    }
}

extension Notification.Name {
    static let showDebugMenu = Notification.Name("showDebugMenu")
}

// MARK: - Shake Gesture Detector
struct ShakeDetector: UIViewControllerRepresentable {
    let onShake: () -> Void
    
    func makeUIViewController(context: Context) -> ShakeViewController {
        let vc = ShakeViewController()
        vc.onShake = onShake
        return vc
    }
    
    func updateUIViewController(_ uiViewController: ShakeViewController, context: Context) {}
}

class ShakeViewController: UIViewController {
    var onShake: (() -> Void)?
    
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            onShake?()
        }
    }
}

extension View {
    func onShakeGesture(perform action: @escaping () -> Void) -> some View {
        self.overlay(
            ShakeDetector(onShake: action)
                .frame(width: 0, height: 0)
        )
    }
}