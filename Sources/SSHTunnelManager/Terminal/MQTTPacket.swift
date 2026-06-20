import Foundation

/// MQTT 3.1.1 packet encoding / decoding. Kept separate from `MQTTClient` so the
/// wire format can be unit‑tested in isolation (see the protocol tests).
enum MQTTPacket {

    // MARK: - Outgoing (encoders)

    /// CONNECT (type 1): clean session, protocol level 4, optional credentials.
    static func connect(clientID: String, username: String, password: String,
                        keepAlive: UInt16) -> Data {
        var variable = Data()
        variable.append(string("MQTT"))
        variable.append(0x04)                       // protocol level 4 = 3.1.1
        var flags: UInt8 = 0x02                      // clean session
        if !username.isEmpty { flags |= 0x80 }
        if !password.isEmpty { flags |= 0x40 }
        variable.append(flags)
        variable.append(UInt8(keepAlive >> 8))
        variable.append(UInt8(keepAlive & 0xFF))

        var payload = string(clientID)
        if !username.isEmpty { payload.append(string(username)) }
        if !password.isEmpty { payload.append(string(password)) }

        return frame(type: 0x10, body: variable + payload)
    }

    /// SUBSCRIBE (type 8, reserved flags 0010) to several topics at QoS 0.
    static func subscribe(packetID: UInt16, topics: [String]) -> Data {
        var body = Data([UInt8(packetID >> 8), UInt8(packetID & 0xFF)])
        for topic in topics {
            body.append(string(topic))
            body.append(0x00)                        // requested QoS 0
        }
        return frame(type: 0x82, body: body)
    }

    /// PUBLISH (type 3) at QoS 0.
    static func publish(topic: String, payload: Data, retain: Bool) -> Data {
        var header: UInt8 = 0x30
        if retain { header |= 0x01 }
        var body = string(topic)                     // no packet id at QoS 0
        body.append(payload)
        return frame(type: header, body: body)
    }

    /// PUBACK (type 4) — acknowledges an incoming QoS 1 PUBLISH.
    static func puback(_ packetID: UInt16) -> Data {
        Data([0x40, 0x02, UInt8(packetID >> 8), UInt8(packetID & 0xFF)])
    }

    static func pingReq() -> Data { Data([0xC0, 0x00]) }
    static func disconnect() -> Data { Data([0xE0, 0x00]) }

    // MARK: - Incoming (decoded packets)

    enum Incoming {
        case connack(accepted: Bool, message: String)
        case publish(topic: String, payload: Data, retained: Bool, qos: UInt8, packetID: UInt16?)
        case suback
        case pingResp
        case other
    }

    /// Pull the next complete packet from `buffer`, removing its bytes. Returns
    /// `nil` (leaving the buffer intact) when more bytes are needed.
    static func next(from buffer: inout [UInt8]) -> Incoming? {
        guard buffer.count >= 2 else { return nil }
        guard let (remaining, headerLength) = decodeRemainingLength(buffer, from: 1) else {
            // Either incomplete length bytes, or malformed. If we already have 5
            // header bytes and still no terminator, it's malformed — drop a byte
            // to resync; otherwise wait for more.
            if buffer.count > 4 { buffer.removeFirst() }
            return nil
        }
        let total = headerLength + remaining
        guard buffer.count >= total else { return nil }

        let firstByte = buffer[0]
        let type = firstByte >> 4
        let flags = firstByte & 0x0F
        let payload = Array(buffer[headerLength..<total])
        buffer.removeFirst(total)

        switch type {
        case 2:                                       // CONNACK
            let code = payload.count >= 2 ? payload[1] : 0xFF
            return .connack(accepted: code == 0, message: connackMessage(code))
        case 3:                                       // PUBLISH
            return decodePublish(flags: flags, payload: payload)
        case 9:                                        // SUBACK
            return .suback
        case 13:                                       // PINGRESP
            return .pingResp
        default:
            return .other
        }
    }

    // MARK: - Helpers

    /// A UTF‑8 string field: 2‑byte big‑endian length + bytes.
    static func string(_ value: String) -> Data {
        let bytes = Array(value.utf8)
        var data = Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)])
        data.append(contentsOf: bytes)
        return data
    }

    /// Build a packet: fixed‑header type byte + remaining‑length + body.
    static func frame(type: UInt8, body: Data) -> Data {
        var packet = Data([type])
        packet.append(encodeRemainingLength(body.count))
        packet.append(body)
        return packet
    }

    /// MQTT "remaining length": base‑128 varint, 1–4 bytes, MSB = continuation.
    static func encodeRemainingLength(_ length: Int) -> Data {
        var value = length
        var out = Data()
        repeat {
            var byte = UInt8(value % 128)
            value /= 128
            if value > 0 { byte |= 0x80 }
            out.append(byte)
        } while value > 0
        return out
    }

    /// Decode a remaining‑length field starting at `start`. Returns the value and
    /// the total header length (type byte + length bytes), or nil if incomplete.
    static func decodeRemainingLength(_ bytes: [UInt8], from start: Int) -> (value: Int, headerLength: Int)? {
        var multiplier = 1
        var value = 0
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            value += Int(byte & 0x7F) * multiplier
            index += 1
            if byte & 0x80 == 0 {
                return (value, index)
            }
            multiplier *= 128
            if multiplier > 128 * 128 * 128 { return nil }   // malformed
        }
        return nil                                            // need more bytes
    }

    private static func decodePublish(flags: UInt8, payload: [UInt8]) -> Incoming {
        let retain = flags & 0x01 != 0
        let qos = (flags >> 1) & 0x03
        guard payload.count >= 2 else { return .other }
        let topicLen = Int(payload[0]) << 8 | Int(payload[1])
        var index = 2
        guard payload.count >= index + topicLen else { return .other }
        let topic = String(decoding: payload[index..<index + topicLen], as: UTF8.self)
        index += topicLen

        var packetID: UInt16?
        if qos > 0 {
            guard payload.count >= index + 2 else { return .other }
            packetID = UInt16(payload[index]) << 8 | UInt16(payload[index + 1])
            index += 2
        }
        let body = Data(payload[index...])
        return .publish(topic: topic, payload: body, retained: retain, qos: qos, packetID: packetID)
    }

    private static func connackMessage(_ code: UInt8) -> String {
        switch code {
        case 0: return "Connection accepted."
        case 1: return "Connection refused: unacceptable protocol version."
        case 2: return "Connection refused: client identifier rejected."
        case 3: return "Connection refused: server unavailable."
        case 4: return "Connection refused: bad username or password."
        case 5: return "Connection refused: not authorized."
        default: return "Connection refused (code \(code))."
        }
    }
}
