import AppKit
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case login, verify, main }

    @Published var phase: Phase = .login
    @Published var email: String = UserDefaults.standard.string(forKey: "email") ?? ""
    @Published var cameras: [Camera] = []
    @Published var busy = false
    @Published var error: String?
    @Published var info: String?

    let api = MiboAPI()
    private var password = ""

    init() {
        if !CommandLine.arguments.contains("--selftest"), !email.isEmpty, let pw = Keychain.password(email: email) {
            password = pw
            Task { await login(email: email, password: pw, remember: true) }
        }
    }

    func login(email: String, password: String, remember: Bool) async {
        let email = email.trimmingCharacters(in: .whitespaces).lowercased()
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await api.login(email: email, password: password)
            self.email = email
            self.password = password
            UserDefaults.standard.set(email, forKey: "email")
            if remember { Keychain.save(email: email, password: password) }
            cameras = try await api.cameras()
            phase = .main
        } catch let e as MiboAPIError where e.code == MiboAPIError.terminalUntrusted {
            self.email = email
            self.password = password
            await sendCode()
        } catch {
            self.error = error.localizedDescription
            phase = .login
        }
    }

    func sendCode() async {
        do {
            try await api.requestTerminalCode(email: email)
            info = "Enviamos um código de verificação para \(email). Ele expira em poucos minutos."
            phase = .verify
        } catch {
            self.error = error.localizedDescription
        }
    }

    func verify(code: String) async {
        busy = true
        error = nil
        do {
            try await api.trustTerminal(email: email, code: code.trimmingCharacters(in: .whitespaces))
            busy = false
            info = nil
            await login(email: email, password: password, remember: true)
        } catch {
            busy = false
            self.error = error.localizedDescription
        }
    }

    func refreshCameras() async {
        do { cameras = try await api.cameras() } catch { self.error = error.localizedDescription }
    }

    /// Fetch a fresh stream URL, re-logging in once if the session expired.
    func liveURL(for cam: Camera, hd: Bool) async throws -> String {
        do {
            return try await api.liveURL(deviceId: cam.id, channelId: cam.channels.first ?? "0", hd: hd)
        } catch {
            try await api.login(email: email, password: password)
            return try await api.liveURL(deviceId: cam.id, channelId: cam.channels.first ?? "0", hd: hd)
        }
    }

    func logout() {
        Keychain.delete(email: email)
        password = ""
        cameras = []
        phase = .login
    }
}

// MARK: - Stream tile

@MainActor
final class CameraStream: ObservableObject {
    @Published var status = "Conectando…"
    @Published var playing = false
    let player = StreamPlayer()
    private let camera: Camera
    private let hd: Bool
    private weak var model: AppModel?
    private var active = false
    private var retryTask: Task<Void, Never>?

    init(camera: Camera, hd: Bool, model: AppModel) {
        self.camera = camera
        self.hd = hd
        self.model = model
        player.onStateChange = { [weak self] s in self?.handle(s) }
    }

    func start() {
        guard !active else { return }
        active = true
        connect()
    }

    func stop() {
        active = false
        retryTask?.cancel()
        player.stop()
    }

    func setAudio(_ on: Bool) { player.audioEnabled = on }

    private func connect() {
        guard active, let model else { return }
        status = "Conectando…"
        Task {
            do {
                let url = try await model.liveURL(for: camera, hd: hd)
                guard self.active else { return }
                self.player.play(url: url)
            } catch {
                self.status = error.localizedDescription
                self.scheduleRetry()
            }
        }
    }

    private func handle(_ s: StreamPlayer.State) {
        switch s {
        case .playing: playing = true; status = "Ao vivo"
        case .connecting: status = "Conectando…"
        case .error(let m): playing = false; status = "Reconectando (\(m))"; scheduleRetry()
        case .idle: playing = false
        }
    }

    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !Task.isCancelled, self.active else { return }
            self.connect()
        }
    }
}

final class PlayerNSView: NSView {
    let player: StreamPlayer
    init(player: StreamPlayer) {
        self.player = player
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(player.layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    // Let clicks fall through to SwiftUI tap gestures on the tile.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        player.layer.frame = bounds
        CATransaction.commit()
    }
}

struct PlayerView: NSViewRepresentable {
    let player: StreamPlayer
    func makeNSView(context: Context) -> PlayerNSView { PlayerNSView(player: player) }
    func updateNSView(_ v: PlayerNSView, context: Context) {}
}

struct CameraTile: View {
    let camera: Camera
    let hd: Bool
    var audio = false
    @StateObject private var stream: CameraStream

    init(camera: Camera, hd: Bool, audio: Bool = false, model: AppModel) {
        self.camera = camera
        self.hd = hd
        self.audio = audio
        _stream = StateObject(wrappedValue: CameraStream(camera: camera, hd: hd, model: model))
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            PlayerView(player: stream.player)
            if !stream.playing {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(stream.status).font(.caption).foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 6) {
                Circle().fill(stream.playing ? .red : .gray).frame(width: 8, height: 8)
                Text(camera.name).font(.caption.bold())
                if audio { Image(systemName: "speaker.wave.2.fill").font(.caption) }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
            .padding(8)
        }
        .background(Color.black)
        .onAppear { stream.setAudio(audio); stream.start() }
        .onDisappear { stream.stop() }
        .onChange(of: audio) { _, on in stream.setAudio(on) }
    }
}

// MARK: - Screens

// View-local state lives in ObservableObjects: the Command Line Tools SDK lacks the SwiftUI @State macro plugin.
final class LoginForm: ObservableObject {
    @Published var password = ""
    @Published var remember = true
}

final class VerifyForm: ObservableObject {
    @Published var code = ""
}

final class MainUIState: ObservableObject {
    @Published var selection: String? = "all"
    @Published var hd = true
    @Published var audio = false
    @Published var gridAudioId: String?
}

struct LoginView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var form = LoginForm()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.fill").font(.system(size: 44)).foregroundStyle(.green)
            Text("Mibo para Mac").font(.title.bold())
            Text("Entre com sua conta Intelbras Mibo Smart").foregroundStyle(.secondary)
            Form {
                TextField("E-mail", text: $model.email).textContentType(.username)
                SecureField("Senha", text: $form.password).textContentType(.password)
                    .onSubmit(submit)
                Toggle("Lembrar senha (Keychain)", isOn: $form.remember)
            }
            .frame(width: 340)
            if let e = model.error { Text(e).foregroundStyle(.red).font(.callout).frame(width: 340) }
            Button(action: submit) {
                if model.busy { ProgressView().controlSize(.small) } else { Text("Entrar").frame(width: 120) }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(model.busy || model.email.isEmpty || form.password.isEmpty)
            Text("Cliente não oficial, sem afiliação com a Intelbras.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(40)
    }

    private func submit() {
        Task { await model.login(email: model.email, password: form.password, remember: form.remember) }
    }
}

struct VerifyView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var form = VerifyForm()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield").font(.system(size: 44)).foregroundStyle(.orange)
            Text("Autorizar este Mac").font(.title2.bold())
            Text(model.info ?? "").multilineTextAlignment(.center).frame(width: 360)
            TextField("Código", text: $form.code).frame(width: 160).multilineTextAlignment(.center)
                .font(.title3.monospaced()).onSubmit(submit)
            if let e = model.error { Text(e).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Reenviar código") { Task { await model.sendCode() } }
                Button("Confirmar", action: submit).keyboardShortcut(.defaultAction)
                    .disabled(form.code.count < 4 || model.busy)
                Button("Cancelar") { model.phase = .login }
            }
        }
        .padding(40)
    }

    private func submit() { Task { await model.verify(code: form.code) } }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui = MainUIState()

    var body: some View {
        NavigationSplitView {
            List(selection: $ui.selection) {
                Label("Todas as câmeras", systemImage: "square.grid.2x2").tag("all")
                Section("Câmeras") {
                    ForEach(model.cameras) { cam in
                        HStack {
                            Label(cam.name, systemImage: "video")
                            Spacer()
                            Circle().fill(cam.online ? .green : .gray).frame(width: 7, height: 7)
                        }
                        .help("\(cam.model) · \(cam.id)")
                        .tag(cam.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            detail
                .toolbar {
                    ToolbarItemGroup {
                        if ui.selection != "all" {
                            Picker("Qualidade", selection: $ui.hd) {
                                Text("HD").tag(true)
                                Text("SD").tag(false)
                            }
                            .pickerStyle(.segmented)
                            Button { ui.audio.toggle() } label: {
                                Image(systemName: ui.audio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            }
                            .help(ui.audio ? "Silenciar" : "Ativar áudio")
                        }
                        Button { Task { await model.refreshCameras() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Atualizar lista")
                        Button("Sair") { model.logout() }
                    }
                }
        }
    }

    @ViewBuilder private var detail: some View {
        if ui.selection == "all" || ui.selection == nil {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 8)], spacing: 8) {
                    ForEach(model.cameras.filter(\.online)) { cam in
                        let listening = ui.gridAudioId == cam.id
                        CameraTile(camera: cam, hd: false, audio: listening, model: model)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(Color.green, lineWidth: listening ? 4 : 0)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { ui.selection = cam.id }
                            .onTapGesture { ui.gridAudioId = listening ? nil : cam.id }
                            .help(listening ? "Clique para silenciar · duplo clique para abrir"
                                            : "Clique para ouvir · duplo clique para abrir")
                    }
                }
                .padding(8)
            }
            .navigationTitle("Todas as câmeras")
        } else if let cam = model.cameras.first(where: { $0.id == ui.selection }) {
            CameraTile(camera: cam, hd: ui.hd, audio: ui.audio, model: model)
                .id("\(cam.id)-\(ui.hd)")
                .navigationTitle(cam.name)
                .navigationSubtitle(cam.model)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        switch model.phase {
        case .login: LoginView()
        case .verify: VerifyView()
        case .main: MainView()
        }
    }
}

@main
struct MiboMacApp: App {
    @StateObject private var model = AppModel()

    init() {
        SelfTest.runIfRequested()
    }

    var body: some Scene {
        WindowGroup("Mibo") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 800, minHeight: 520)
        }
        .windowStyle(.titleBar)
    }
}
