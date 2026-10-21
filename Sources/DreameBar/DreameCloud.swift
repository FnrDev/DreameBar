import Foundation

/// Client for the Dreamehome cloud, ported from the DreameHome protocol in
/// Tasshack/dreame-vacuum (custom_components/dreame_vacuum/dreame/protocol.py).
enum Dreame {
    static let hostSuffix = ".iot.dreame.tech:13267"
    static let passwordSalt = "RAylYC%fmSKp7%Tq"
    static let basicAuth = "ZHJlYW1lX2FwcHYxOkFQXmR2QHpAU1FZVnhOODg="
    static let signingKey = "EETjszu*XI5znHsI"
    static let appVersion = "102060300"
    static let userAgent = "Dart/3.9 (dart:io)"
    static let fileUserAgent = "okhttp/4.12.0"
    static let defaultTenant = "000000"
    static let regions = ["eu", "sg", "us", "ru", "cn", "kr"]
}

struct DreameSession: Codable {
    var region: String
    var username: String
    var visitorHash: String
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var tenantId: String?
    var rlcRegion: String?
    var lang: String?
    var country: String?
    /// Account id from the token response; the live feed logs in with it.
    var uid: String?
}

struct DreameDevice: Identifiable, Hashable {
    let did: String
    let model: String
    let name: String
    let mac: String
    let bindDomain: String
    var masterUid: String = ""
    var id: String { did }
}

struct DreameError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

actor DreameCloud {
    private(set) var session: DreameSession?
    private var requestId = Int.random(in: 1...100)
    private let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        return URLSession(configuration: config)
    }()

    init(session: DreameSession?) {
        self.session = session
    }

    // MARK: Auth

    func login(username: String, password: String, region: String) async throws -> DreameSession {
        let hashed = Crypto.md5Hex(password + Dreame.passwordSalt)
        // Python quote(username, safe="")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~")
        let user = username.addingPercentEncoding(withAllowedCharacters: unreserved) ?? username
        let body = "grant_type=password&scope=all&platform=ANDROID&type=account&username=\(user)&password=\(hashed)"
        let fresh = DreameSession(region: region, username: username,
                                  visitorHash: Crypto.md5Hex(UUID().uuidString),
                                  accessToken: "", refreshToken: "", expiresAt: .distantPast)
        let s = try await token(body: body, base: fresh)
        session = s
        return s
    }

    private func refresh() async throws {
        guard let s = session else { throw DreameError("Not signed in") }
        let body = "grant_type=refresh_token&scope=all&platform=ANDROID&type=account&refresh_token=\(s.refreshToken)"
        session = try await token(body: body, base: s)
    }

    private func token(body: String, base: DreameSession) async throws -> DreameSession {
        var req = URLRequest(url: URL(string: "https://\(base.region)\(Dreame.hostSuffix)/dreame-auth/oauth/token")!)
        req.httpMethod = "POST"
        for (k, v) in headers(for: base, contentType: "application/x-www-form-urlencoded", authorized: false) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = Data(body.utf8)
        let (data, resp) = try await http.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let json = JSON.parse(data), let access = json["access_token"]?.string else {
            let info = JSON.parse(data)
            let reason = info?["error_description"]?.string ?? info?["msg"]?.string ?? String(data: data, encoding: .utf8) ?? ""
            throw DreameError("Login failed (\(status)): \(reason)")
        }
        var s = base
        s.accessToken = access
        s.refreshToken = json["refresh_token"]?.string ?? s.refreshToken
        s.expiresAt = Date().addingTimeInterval(TimeInterval(json["expires_in"]?.int ?? 3600))
        s.tenantId = json["tenant_id"]?.string ?? s.tenantId
        s.rlcRegion = json["region"]?.string ?? s.rlcRegion
        s.lang = json["lang"]?.string ?? s.lang
        s.country = json["country"]?.string ?? s.country
        s.uid = json["uid"]?.string ?? json["uid"]?.int.map(String.init) ?? s.uid
        return s
    }

    private func headers(for s: DreameSession, contentType: String, authorized: Bool) -> [String: String] {
        let meta = "cv=a_\(Dreame.appVersion)"
            + ";canvasHash=\(Crypto.md5Hex(s.username + "c").prefix(8))"
            + ";webglHash=\(Crypto.md5Hex(s.username + "w").prefix(8))"
            + ";visitorIdHash=\(s.visitorHash)"
        var h = [
            "user-agent": Dreame.userAgent,
            "dreame-meta": meta,
            "tenant-id": s.tenantId ?? Dreame.defaultTenant,
            "authorization": "Basic \(Dreame.basicAuth)",
            "content-type": contentType,
        ]
        if let r = s.rlcRegion, let l = s.lang, let c = s.country,
           let enc = Crypto.aesECBEncrypt(Data("\(r)|\(l)|\(c)".utf8), key: Data(Dreame.signingKey.utf8)) {
            h["dreame-rlc"] = enc.base64EncodedString()
        }
        if authorized { h["dreame-auth"] = s.accessToken }
        return h
    }

    // MARK: Signed API calls

    /// Python `_spliced`: the canonical string the request signature is computed over.
    private static func spliced(_ obj: [String: JSON], top: Bool) -> String {
        var parts: [String] = []
        for k in obj.keys.sorted() {
            switch obj[k]! {
            case .object(let d):
                let inner = spliced(d, top: false)
                parts.append(inner.isEmpty ? "\(k)=]" : "\(k)=[\(inner)]")
            case .array(let a):
                if top { parts.append("\(k)=\(JSON.array(a).dumps(sortKeys: true))") }
            case .bool(let b): parts.append("\(k)=\(b ? "true" : "false")")
            case .null: parts.append("\(k)=null")
            case .string(let s) where top: parts.append("\(k)=\(s)")
            case let v where top: parts.append("\(k)=\(v.dumps())")
            case let v: parts.append("\(k)=\(v.dumps(compact: false))")
            }
        }
        return parts.joined(separator: "&")
    }

    private static func signed(_ params: [String: JSON]) -> [String: JSON] {
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        var out = params
        out["sign"] = .string(Crypto.md5Hex(spliced(params, top: true) + String(ms) + Dreame.signingKey))
        out["timestamp"] = .int(ms)
        return out
    }

    func call(_ path: String, _ params: [String: JSON]? = nil, retried: Bool = false) async throws -> JSON {
        guard var s = session else { throw DreameError("Not signed in") }
        if s.expiresAt.timeIntervalSinceNow < 600 {
            try await refresh()
            s = session!
        }
        var req = URLRequest(url: URL(string: "https://\(s.region)\(Dreame.hostSuffix)/\(path)")!)
        req.httpMethod = "POST"
        for (k, v) in headers(for: s, contentType: "application/json", authorized: true) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        if let params {
            req.httpBody = Data(JSON.object(Self.signed(params)).dumps().utf8)
        }
        let (data, resp) = try await http.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && !retried {
            try await refresh()
            return try await call(path, params, retried: true)
        }
        guard status == 200, let json = JSON.parse(data) else {
            throw DreameError("Dreame cloud error \(status): \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        return json
    }

    // MARK: Devices

    func devices() async throws -> [DreameDevice] {
        let json = try await call("dreame-user-iot/iotuserbind/device/listV2")
        guard json["code"]?.int == 0, let records = json["data"]?["page"]?["records"]?.array else {
            throw DreameError("Couldn't list devices: \(json.dumps().prefix(200))")
        }
        return records.compactMap { r in
            guard let did = r["did"]?.string ?? r["did"]?.int.map(String.init),
                  let model = r["model"]?.string else { return nil }
            let custom = r["customName"]?.string ?? ""
            return DreameDevice(
                did: did, model: model,
                name: custom.isEmpty ? (r["deviceInfo"]?["displayName"]?.string ?? model) : custom,
                mac: r["mac"]?.string ?? "",
                bindDomain: r["bindDomain"]?.string ?? "",
                masterUid: r["masterUid"]?.string ?? r["masterUid"]?.int.map(String.init) ?? ""
            )
        }
    }

    /// Sends a miIO-style command ("action", "get_properties", ...) to the robot through the cloud.
    func send(_ device: DreameDevice, method: String, params: JSON) async throws -> JSON {
        requestId += 1
        let host = device.bindDomain.isEmpty ? "" : "-" + (device.bindDomain.split(separator: ".").first.map(String.init) ?? "")
        let json = try await call("dreame-iot-com\(host)/device/sendCommand", [
            "did": .string(device.did),
            "id": .int(requestId),
            "data": ["did": .string(device.did), "id": .int(requestId), "method": .string(method), "params": params],
        ])
        guard let result = json["data"]?["result"] else {
            throw DreameError("The robot didn't answer (it may be offline): \(json.dumps().prefix(200))")
        }
        return result
    }

    func properties(_ device: DreameDevice, _ ids: [(Int, Int)]) async throws -> [String: JSON] {
        let params = JSON.array(ids.map { ["did": .string(device.did), "siid": .int($0.0), "piid": .int($0.1)] })
        let result = try await send(device, method: "get_properties", params: params)
        var out: [String: JSON] = [:]
        for item in result.array ?? [] where item["code"]?.int ?? 0 == 0 {
            if let s = item["siid"]?.int, let p = item["piid"]?.int, let v = item["value"] {
                out["\(s).\(p)"] = v
            }
        }
        return out
    }

    @discardableResult
    func action(_ device: DreameDevice, siid: Int, aiid: Int, in input: [JSON] = []) async throws -> JSON {
        let result = try await send(device, method: "action", params: [
            "did": .string(device.did), "siid": .int(siid), "aiid": .int(aiid), "in": .array(input),
        ])
        if let code = result["code"]?.int, code != 0 {
            throw DreameError("The robot rejected the command (code \(code))")
        }
        return result
    }

    /// Connection details for the live feed: the device's MQTT broker, logged in with the current access token.
    func liveConfig(_ device: DreameDevice) async throws -> DreameLive.Config {
        guard var s = session else { throw DreameError("Not signed in") }
        if s.uid == nil || s.expiresAt.timeIntervalSinceNow < 600 {
            try await refresh()
            s = session!
        }
        let parts = device.bindDomain.split(separator: ":")
        guard parts.count == 2, let port = UInt16(parts[1]), let uid = s.uid, !device.masterUid.isEmpty else {
            throw DreameError("Live updates aren't available for this robot")
        }
        return DreameLive.Config(
            host: String(parts[0]), port: port,
            clientID: "p_" + Crypto.md5Hex(device.did + "mqtt" + s.visitorHash),
            username: uid, password: s.accessToken,
            topic: "/status/\(device.did)/\(device.masterUid)/\(device.model)/\(s.region)/"
        )
    }

    // MARK: Map files

    /// The last value the robot reported for a property ("siid.piid"), as stored by the cloud.
    /// Values often arrive as JSON-encoded strings, so those are parsed.
    func storedProperty(_ device: DreameDevice, _ key: String) async throws -> JSON? {
        let json = try await call("dreame-user-iot/iotstatus/props", ["did": .string(device.did), "keys": .string(key)])
        guard let value = json["data"]?[0]?["value"] else { return nil }
        if let text = value.string, let parsed = JSON.parse(Data(text.utf8)), parsed.string == nil { return parsed }
        return value
    }

    /// Object name of the current map file (property 6.3), possibly with a ",key" suffix.
    func mapObjectName(_ device: DreameDevice) async throws -> String? {
        guard let value = try await storedProperty(device, "6.3") else { return nil }
        return value[0]?.string ?? value.string
    }

    /// Object name of the saved-map list file (property 6.8).
    func mapListObjectName(_ device: DreameDevice) async throws -> String? {
        guard let value = try await storedProperty(device, "6.8") else { return nil }
        return value["object_name"]?.string ?? value["obj_name"]?.string
    }

    func downloadFile(_ device: DreameDevice, objectName: String) async throws -> Data {
        guard let s = session else { throw DreameError("Not signed in") }
        let json = try await call("dreame-user-iot/iotfile/getDownloadUrl", [
            "did": .string(device.did), "model": .string(device.model),
            "filename": .string(objectName), "region": .string(s.region),
        ])
        guard let urlString = json["data"]?.string, let url = URL(string: urlString) else {
            throw DreameError("Couldn't get the map download link")
        }
        var req = URLRequest(url: url)
        req.setValue(Dreame.fileUserAgent, forHTTPHeaderField: "user-agent")
        let (data, resp) = try await http.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw DreameError("Map download failed") }
        return data
    }
}
