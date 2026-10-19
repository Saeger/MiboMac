import CryptoKit
import Foundation

/// Intelbras Mibo Smart (Imou/Easy4ip) cloud API, reconstructed from the Android app
/// (br.com.intelbras.mibocam 3.1.1).
///
/// These are not user credentials: they identify the official Mibo Smart app and ship inside every copy of it.
/// The anonymous AK/SK pair signs the pre-login calls that email a verification code and authorize a new Mac;
/// the server rejects those calls when signed with account credentials.
enum MiboConfig {
    static let entryHost = "app-br.easy4ipcloud.com"
    static let appId = "Intelbrasphone25aa"
    static let project = "Intelbras9be0d3bb"
    static let defaultAK = "d55c39fb8ee54700ba65fdea2e9c3c28"
    static let defaultSK = "bf0858a346f94598ac9d53b99e23f3b7"
    static let clientVersion = "V3.1.1"
    static let protocolVersion = "V7.4.7"
}

struct MiboAPIError: LocalizedError {
    let code: Int
    let desc: String

    static let terminalUntrusted = 12112
    static let codeExpired = 15001
    static let codeInvalid = 15000

    var errorDescription: String? {
        switch code {
        case Self.terminalUntrusted: return "Este Mac ainda não está autorizado na sua conta."
        case Self.codeExpired: return "O código expirou. Solicite um novo."
        case Self.codeInvalid: return "Código inválido."
        case 22001: return "E-mail ou senha incorretos (tentativas: \(desc))."
        case 22005: return "Terminal bloqueado por excesso de tentativas. Tente mais tarde."
        default: return "Erro do servidor Mibo (\(code)): \(desc)"
        }
    }
}

struct Camera: Identifiable, Hashable {
    let id: String
    let name: String
    let model: String
    let online: Bool
    let channels: [String]
}

private func md5hex(_ s: String) -> String {
    Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

final class MiboAPI {
    private(set) var host = MiboConfig.entryHost
    private var username = ""
    private var secret = ""
    private var sessionId: String?
    let terminalId: String

    init() {
        terminalId = Self.loadTerminalId()
    }

    /// Stable per-Mac terminal id; the account's "terminal management" trusts this id once verified.
    private static func loadTerminalId() -> String {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiboMac", isDirectory: true)
        let file = dir.appendingPathComponent("terminal_id")
        if let s = try? String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            return s
        }
        let id = UUID().uuidString.lowercased()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? id.write(to: file, atomically: true, encoding: .utf8)
        return id
    }

    // MARK: transport

    private func clientUA() -> String {
        let ua: [String: String] = [
            "clientType": "phone",
            "clientVersion": MiboConfig.clientVersion,
            "clientOV": "Android 14",
            "clientOS": "Android",
            "terminalModel": "MiboMac",
            "terminalId": terminalId,
            "appid": MiboConfig.appId,
            "project": MiboConfig.project,
            "language": "pt_BR",
            "clientProtocolVersion": MiboConfig.protocolVersion,
            "timezoneOffset": String(TimeZone.current.secondsFromGMT()),
            "terminalBrand": "Apple",
            "terminalName": Host.current().localizedName ?? "Mac",
            "darkMode": "light",
        ]
        let json = try! JSONSerialization.data(withJSONObject: ua, options: [.sortedKeys])
        return json.base64EncodedString()
    }

    private func setAuth(_ user: String, _ password: String) {
        var u = user
        if u.hasPrefix("token/") { u = "uuid\\" + u.dropFirst(6) }
        else if u.hasPrefix("default/") { u = "default\\" + u.dropFirst(8) }
        username = u
        secret = md5hex(password)
    }

    private func useAnonymous() {
        sessionId = nil
        setAuth("default/" + MiboConfig.defaultAK, MiboConfig.defaultSK)
    }

    @discardableResult
    func call(_ api: String, _ data: [String: Any],
              contentType: String = "application/json; charset=utf-8",
              apiver: String = "191204") async throws -> [String: Any] {
        let path = "/pcs/v1/" + api
        let body = try JSONSerialization.data(withJSONObject: ["data": data])
        let contentMD5 = Data(Insecure.MD5.hash(data: body)).base64EncodedString()
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "GMT")
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        let date = df.string(from: Date())
        let alnum = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let nonce = String(Int64(Date().timeIntervalSince1970 * 1000)) + String((0..<32).map { _ in alnum.randomElement()! })
        let ua = clientUA()

        var toSign = "POST\n\(path)\n\(contentMD5)\n\(contentType)\n" +
            "x-pcs-apiver:\(apiver)\nx-pcs-client-ua:\(ua)\nx-pcs-date:\(date)\nx-pcs-nonce:\(nonce)\n"
        if let sid = sessionId { toSign += "x-pcs-session-id:\(sid)\n" }
        toSign += "x-pcs-username:\(username)\n"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        let signature = Data(mac).base64EncodedString()

        var req = URLRequest(url: URL(string: "https://\(host)\(path)")!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = 20
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue(contentMD5, forHTTPHeaderField: "Content-MD5")
        req.setValue(username, forHTTPHeaderField: "x-pcs-username")
        req.setValue(apiver, forHTTPHeaderField: "x-pcs-apiver")
        req.setValue(nonce, forHTTPHeaderField: "x-pcs-nonce")
        req.setValue(date, forHTTPHeaderField: "x-pcs-date")
        req.setValue(signature, forHTTPHeaderField: "x-pcs-signature")
        req.setValue(ua, forHTTPHeaderField: "x-pcs-client-ua")
        if let sid = sessionId { req.setValue(sid, forHTTPHeaderField: "x-pcs-session-id") }

        let (respData, _) = try await URLSession.shared.data(for: req)
        if ProcessInfo.processInfo.environment["MIBO_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[\(api)] body=\(String(decoding: body, as: UTF8.self)) -> \(String(decoding: respData.prefix(300), as: UTF8.self))\n".utf8))
        }
        guard let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            throw MiboAPIError(code: -1, desc: String(decoding: respData.prefix(200), as: UTF8.self))
        }
        let code = (json["code"] as? Int) ?? Int("\(json["code"] ?? "")") ?? -1
        guard code == 10000 else {
            throw MiboAPIError(code: code, desc: "\(json["desc"] ?? "")")
        }
        return json["data"] as? [String: Any] ?? [:]
    }

    private func stripScheme(_ s: String) -> String {
        s.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
    }

    // MARK: account

    func login(email: String, password: String) async throws {
        host = MiboConfig.entryHost
        sessionId = nil
        setAuth("account\\" + email, md5hex(password))
        let tok = try await call("user.account.GetToken", ["gpsInfo": ["latitude": 0.0, "longitude": 0.0]])
        if let fail = tok["failNum"], !"\(fail)".isEmpty {
            throw MiboAPIError(code: 22001, desc: "\(fail)")
        }
        guard let user = tok["username"] as? String, let token = tok["token"] as? String else {
            throw MiboAPIError(code: -2, desc: "resposta de login inesperada")
        }
        if let e = tok["entryUrlV2"] as? String, !e.isEmpty { host = stripScheme(e) }
        setAuth("token/" + user, token)
        sessionId = tok["sessionId"] as? String
        let info = try await call("user.account.Login", ["timezoneOffset": TimeZone.current.secondsFromGMT() / 60])
        if let e = info["entryUrlV2"] as? String, !e.isEmpty { host = stripScheme(e) }
    }

    func requestTerminalCode(email: String) async throws {
        useAnonymous()
        try await call("common.validcode.GetValidCode",
                       ["type": "email", "account": email, "usage": "GrantingCredit"],
                       contentType: "application/json", apiver: "61452")
    }

    func trustTerminal(email: String, code: String) async throws {
        useAnonymous()
        try await call("user.account.GrantingCredit",
                       ["type": "email", "account": email, "grantCreditAccount": email, "validCode": code],
                       contentType: "application/json", apiver: "82197")
    }

    // MARK: devices

    func cameras() async throws -> [Camera] {
        var out: [Camera] = []
        var transfer = ""
        for _ in 0..<50 {
            let d = try await call("device.list.BasicList", [
                "familyId": "", "groupId": "", "limit": 20, "offset": 0, "transferStr": transfer,
            ])
            let list = d["deviceList"] as? [[String: Any]] ?? []
            for dev in list {
                guard let id = dev["deviceId"] as? String else { continue }
                let chans = (dev["channelList"] as? [[String: Any]] ?? []).compactMap { "\($0["channelId"] ?? "")" }
                out.append(Camera(
                    id: id,
                    name: (dev["deviceName"] as? String) ?? (dev["name"] as? String) ?? id,
                    model: (dev["deviceModelName"] as? String) ?? (dev["deviceModel"] as? String) ?? "",
                    online: ((dev["status"] as? String) ?? "online") == "online",
                    channels: chans.isEmpty ? ["0"] : chans))
            }
            transfer = d["transferStr"] as? String ?? ""
            if transfer.isEmpty || (d["hasNextPage"] as? Bool) == false || list.isEmpty { break }
        }
        return out
    }

    /// Cloud relay RTSP URL (plain H.264 + AAC). streamId 0 = HD/main, 1 = SD/sub. URLs expire ~5 min after issue.
    func liveURL(deviceId: String, channelId: String, hd: Bool) async throws -> String {
        let d = try await call("things.media.GetRealTransferStreamUrl", [
            "deviceId": deviceId, "channelId": channelId, "streamId": hd ? "0" : "1",
            "encrypt": "0", "design": "first", "skipAuth": "0", "assistStream": "false",
            "imageSize": 0, "productId": "", "audioType": 0,
        ])
        guard let url = d["resource"] as? String, !url.isEmpty else {
            throw MiboAPIError(code: -3, desc: "sem URL de transmissão")
        }
        return url
    }
}
