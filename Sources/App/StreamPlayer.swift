import AVFoundation
import AppKit
import Foundation

/// Bridges the C FFmpeg player (mibo_player.c) to a CALayer. Callbacks arrive on the decode thread.
final class StreamPlayer {
    enum State: Equatable { case idle, connecting, playing, error(String) }

    let layer = CALayer()
    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .idle

    private var player: OpaquePointer?
    private let audioEngine = AVAudioEngine()
    private let audioNode = AVAudioPlayerNode()
    private var audioFormat: AVAudioFormat?
    private var audioQueued = 0
    private let audioLock = NSLock()

    var audioEnabled = false {
        didSet {
            if let p = player { mp_set_audio_enabled(p, audioEnabled ? 1 : 0) }
            if !audioEnabled { audioNode.stop() }
        }
    }

    init() {
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        player = mp_create(ctx, videoCallback, audioCallback, stateCallback)
        audioEngine.attach(audioNode)
    }

    deinit {
        if let p = player { mp_destroy(p) }
        audioEngine.stop()
    }

    func play(url: String) {
        guard let p = player else { return }
        mp_set_audio_enabled(p, audioEnabled ? 1 : 0)
        mp_start(p, url)
    }

    func stop() {
        if let p = player { mp_stop(p) }
        audioNode.stop()
    }

    fileprivate func handleVideo(_ data: UnsafePointer<UInt8>, _ w: Int, _ h: Int, _ stride: Int) {
        let cfData = CFDataCreate(nil, data, stride * h)!
        guard let provider = CGDataProvider(data: cfData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue |
                                      CGBitmapInfo.byteOrder32Little.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return }
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.layer.contents = image
            CATransaction.commit()
        }
    }

    fileprivate func handleAudio(_ samples: UnsafePointer<Float>, _ n: Int, _ rate: Int) {
        guard audioEnabled else { return }
        audioLock.lock()
        defer { audioLock.unlock() }
        if audioFormat?.sampleRate != Double(rate) {
            audioEngine.stop()
            audioFormat = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1)
            audioEngine.connect(audioNode, to: audioEngine.mainMixerNode, format: audioFormat)
        }
        guard let fmt = audioFormat else { return }
        if !audioEngine.isRunning { try? audioEngine.start() }
        if !audioNode.isPlaying { audioNode.play() }
        // Drop audio if it backs up (> ~0.5 s) to stay close to live.
        if audioQueued > rate / 2 { return }
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { return }
        buf.frameLength = AVAudioFrameCount(n)
        buf.floatChannelData![0].update(from: samples, count: n)
        audioQueued += n
        audioNode.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.audioLock.lock()
            self.audioQueued -= n
            self.audioLock.unlock()
        }
    }

    fileprivate func handleState(_ s: Int32, _ msg: String) {
        let newState: State
        switch Int(s) {
        case Int(MP_STATE_CONNECTING): newState = .connecting
        case Int(MP_STATE_PLAYING): newState = .playing
        case Int(MP_STATE_ERROR): newState = .error(msg)
        default: newState = .idle
        }
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
            self?.onStateChange?(newState)
        }
    }
}

private func videoCallback(ctx: UnsafeMutableRawPointer?, data: UnsafePointer<UInt8>?, w: Int32, h: Int32, stride: Int32) {
    guard let ctx, let data else { return }
    Unmanaged<StreamPlayer>.fromOpaque(ctx).takeUnretainedValue().handleVideo(data, Int(w), Int(h), Int(stride))
}

private func audioCallback(ctx: UnsafeMutableRawPointer?, samples: UnsafePointer<Float>?, n: Int32, rate: Int32) {
    guard let ctx, let samples else { return }
    Unmanaged<StreamPlayer>.fromOpaque(ctx).takeUnretainedValue().handleAudio(samples, Int(n), Int(rate))
}

private func stateCallback(ctx: UnsafeMutableRawPointer?, state: Int32, msg: UnsafePointer<CChar>?) {
    guard let ctx else { return }
    let text = msg.map { String(cString: $0) } ?? ""
    Unmanaged<StreamPlayer>.fromOpaque(ctx).takeUnretainedValue().handleState(state, text)
}
