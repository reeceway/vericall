import Foundation
import Network

/// Listens for RTP packets on a UDP port and extracts the payload.
class RTPReceiver {
    private var listener: NWListener?
    private let port: NWEndpoint.Port = 5004
    
    /// Callback triggered when a new Opus packet is extracted from RTP.
    var onOpusPacketReceived: ((Data) -> Void)?
    
    func start() {
        print("[RTPReceiver] Starting listener on port \(port)...")
        do {
            listener = try NWListener(using: .udp, on: port)
            
            listener?.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[RTPReceiver] Listener ready on port \(self.port)")
                case .failed(let error):
                    print("[RTPReceiver] Listener failed: \(error)")
                case .cancelled:
                    print("[RTPReceiver] Listener cancelled")
                default:
                    break
                }
            }
            
            listener?.newConnectionHandler = { connection in
                print("[RTPReceiver] New connection from \(connection.endpoint)")
                self.setupConnection(connection)
            }
            
            listener?.start(queue: .global(qos: .userInteractive))
        } catch {
            print("[RTPReceiver] Failed to start NWListener: \(error)")
        }
    }
    
    func stop() {
        print("[RTPReceiver] Stopping listener...")
        listener?.cancel()
        listener = nil
    }
    
    private func setupConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receive(on: connection)
            case .failed(let error):
                print("[RTPReceiver] Connection failed: \(error)")
            case .cancelled:
                print("[RTPReceiver] Connection cancelled")
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInteractive))
    }
    
    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self = self else { return }
            
            if let data = data, !data.isEmpty {
                self.handlePacket(data)
            }
            
            if error == nil {
                self.receive(on: connection)
            } else {
                print("[RTPReceiver] Receive error: \(error!)")
            }
        }
    }
    
    /// Parses RFC 3550 RTP header and extracts payload.
    /// Standard RTP header is 12 bytes.
    private func handlePacket(_ data: Data) {
        guard data.count > 12 else { return }
        
        let cc = Int(data[0] & 0x0F) // CSRC count
        var headerLength = 12 + (cc * 4)
        
        guard data.count > headerLength else { return }
        
        // Extension bit
        let xBit = (data[0] & 0x10) != 0
        if xBit {
            // Extension header follows CSRC list
            // First 2 bytes: profile-specific
            // Next 2 bytes: length of extension in 32-bit words
            let extLenOffset = headerLength + 2
            guard data.count > extLenOffset + 2 else { return }
            let extLen = Int(data[extLenOffset]) << 8 | Int(data[extLenOffset + 1])
            headerLength += 4 + (extLen * 4)
        }
        
        guard data.count > headerLength else { return }
        
        // Payload type is byte 1 (bits 1-7)
        let payloadType = data[1] & 0x7F
        
        // We expect Opus (Dynamic PT, usually 111 as requested)
        if payloadType == 111 {
            let payload = data.subdata(in: headerLength..<data.count)
            onOpusPacketReceived?(payload)
        }
    }
}
