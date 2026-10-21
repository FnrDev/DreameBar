import Foundation
import Network
import CryptoKit

/// Receive-only MQTT 3.1.1 client for the Dreamehome live device feed, which pushes the robot's
/// property changes and map frames (see DreameVacuumDreameHomeCloudProtocol.connect in Tasshack/dreame-vacuum).
final class DreameLive {
    struct Config {
        let host: String
        let port: UInt16
        let clientID: String
        let username: String
        let password: String
        let topic: String
    }

    /// Dreame's brokers present their own self-signed certificate, which macOS rejects as malformed.
    /// Rather than turning verification off, accept only this exact certificate (SHA-256 of its DER).
    static let pinnedCertificateSHA256 = "0a55ff4bbf5acbb52bfb1b7a941ea097c75f5ca58d0d5eb16464c1d255988200"

    var onMessage: ((JSON) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    /// Called when a connection ends without `disconnect()` being asked for, so the owner can retry.
    var onClosed: (() -> Void)?

    private let queue = DispatchQueue(label: "local.dreamebar.mqtt")
    private var connection: NWConnection?
    private var buffer = Data()
    private var pingTimer: DispatchSourceTimer?
    private var config: Config?
    private var connected = false

    func connect(_ config: Config) {
        queue.async { [self] in
            self.config = nil
            stopLocked()
            self.config = config
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { metadata, _, complete in
                var leaf: Data?
                sec_protocol_metadata_access_peer_certificate_chain(metadata) { cert in
                    if leaf == nil { leaf = SecCertificateCopyData(sec_certificate_copy_ref(cert).takeRetainedValue()) as Data }
                }
                let hash = leaf.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
                if hash != Self.pinnedCertificateSHA256 { Log.write("live: unexpected broker certificate \(hash ?? "none")") }
                complete(hash == Self.pinnedCertificateSHA256)
            }, queue)
            let tcp = NWProtocolTCP.Options()
            tcp.enableKeepalive = true
            let conn = NWConnection(host: NWEndpoint.Host(config.host), port: NWEndpoint.Port(rawValue: config.port)!,
                                    using: NWParameters(tls: tls, tcp: tcp))
            connection = conn
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.send(Self.connectPacket(config))
                    self.receive()
                case .failed(let error), .waiting(let error):
                    Log.write("live: connection problem \(error)")
                    self.stopLocked()
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    func disconnect() {
        queue.async { [self] in
            if connection != nil { send(Data([0xE0, 0x00])) }  // DISCONNECT
            config = nil
            stopLocked()
        }
    }

    private func stopLocked() {
        let unexpected = connection != nil && config != nil
        pingTimer?.cancel()
        pingTimer = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        setConnected(false)
        if unexpected {
            config = nil
            let callback = onClosed
            DispatchQueue.main.async { callback?() }
        }
    }

    private func setConnected(_ value: Bool) {
        guard connected != value else { return }
        connected = value
        let callback = onConnectionChange
        DispatchQueue.main.async { callback?(value) }
    }

    private func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data); self.drainPackets() }
            if done || error != nil {
                Log.write("live: disconnected \(error.map { "\($0)" } ?? "by server")")
                self.stopLocked()
            } else {
                self.receive()
            }
        }
    }

    // MARK: Packets

    private func drainPackets() {
        while buffer.count >= 2 {
            let bytes = [UInt8](buffer.prefix(5))
            var length = 0, multiplier = 1, index = 1
            while true {
                guard index < bytes.count else { return }  // length not fully received yet
                let b = Int(bytes[index])
                length += (b & 0x7F) * multiplier
                multiplier *= 128
                index += 1
                if b & 0x80 == 0 { break }
                if index > 4 { stopLocked(); return }
            }
            guard buffer.count >= index + length else { return }
            let header = bytes[0]
            let body = Data(buffer[buffer.startIndex + index ..< buffer.startIndex + index + length])
            buffer.removeFirst(index + length)
            handle(type: header >> 4, flags: header & 0x0F, body: [UInt8](body))
        }
    }

    private func handle(type: UInt8, flags: UInt8, body: [UInt8]) {
        switch type {
        case 2:  // CONNACK
            guard body.count >= 2, body[1] == 0 else {
                Log.write("live: broker refused login (code \(body.count >= 2 ? Int(body[1]) : -1))")
                stopLocked()
                return
            }
            if let config { send(Self.subscribePacket(topic: config.topic)) }
        case 9:  // SUBACK
            Log.write("live: subscribed")
            setConnected(true)
            startPing()
        case 3:  // PUBLISH
            guard body.count >= 2 else { return }
            let topicLength = Int(body[0]) << 8 | Int(body[1])
            var offset = 2 + topicLength
            let qos = (flags >> 1) & 0x03
            if qos > 0, body.count >= offset + 2 {
                send(Data([0x40, 0x02, body[offset], body[offset + 1]]))  // PUBACK
                offset += 2
            }
            guard body.count >= offset, let json = JSON.parse(Data(body[offset...])), let data = json["data"] else { return }
            let callback = onMessage
            DispatchQueue.main.async { callback?(data) }
        default:
            break  // PINGRESP and others need no action
        }
    }

    private func startPing() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in self?.send(Data([0xC0, 0x00])) }
        timer.resume()
        pingTimer = timer
    }

    private static func string(_ s: String) -> Data {
        let utf8 = Data(s.utf8)
        return Data([UInt8(utf8.count >> 8), UInt8(utf8.count & 0xFF)]) + utf8
    }

    private static func packet(_ header: UInt8, _ body: Data) -> Data {
        var out = Data([header])
        var length = body.count
        repeat {
            var byte = UInt8(length % 128)
            length /= 128
            if length > 0 { byte |= 0x80 }
            out.append(byte)
        } while length > 0
        return out + body
    }

    private static func connectPacket(_ c: Config) -> Data {
        // Protocol "MQTT" level 4; flags: username, password, clean session; keep-alive 60 s.
        var body = string("MQTT") + Data([0x04, 0xC2, 0x00, 0x3C])
        body += string(c.clientID) + string(c.username) + string(c.password)
        return packet(0x10, body)
    }

    private static func subscribePacket(topic: String) -> Data {
        packet(0x82, Data([0x00, 0x01]) + string(topic) + Data([0x00]))
    }
}
