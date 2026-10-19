import AppKit
import Foundation

/// `MiboMac --selftest` (env MIBO_EMAIL, MIBO_PASSWORD): login, list cameras, decode a frame from each
/// online camera and write PNGs to $TMPDIR. Exits with status 0 on success.
@MainActor
enum SelfTest {
    static func runIfRequested() {
        guard CommandLine.arguments.contains("--selftest") else { return }
        Task { await run() }
    }

    private static func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    private static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["MIBO_EMAIL"], let pw = env["MIBO_PASSWORD"] else { log("missing env"); exit(2) }
        let api = MiboAPI()
        do {
            try await api.login(email: email, password: pw)
            log("login ok host=\(api.host)")
            let cams = try await api.cameras()
            log("cameras: \(cams.map { "\($0.name) [\($0.model)] \($0.online ? "online" : "offline")" })")
            var ok = 0
            for cam in cams where cam.online {
                let url = try await api.liveURL(deviceId: cam.id, channelId: cam.channels[0], hd: false)
                let player = StreamPlayer()
                player.audioEnabled = true
                player.play(url: url)
                let deadline = Date().addingTimeInterval(20)
                while Date() < deadline, player.layer.contents == nil {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                player.stop()
                if let img = player.layer.contents as! CGImage? {
                    let out = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mibo_\(cam.id).png")
                    let rep = NSBitmapImageRep(cgImage: img)
                    try rep.representation(using: .png, properties: [:])!.write(to: out)
                    log("OK \(cam.name): \(img.width)x\(img.height) -> \(out.path)")
                    ok += 1
                } else {
                    log("FAIL \(cam.name): no frame (state=\(player.state))")
                }
            }
            exit(ok > 0 ? 0 : 1)
        } catch {
            log("ERROR \(error.localizedDescription)")
            exit(1)
        }
    }
}
