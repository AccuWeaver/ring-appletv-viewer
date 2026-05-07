#if canImport(WebRTC)
import Foundation
import WebRTC

/// A no-op `RTCAudioDevice` implementation.
///
/// WebRTC's default iOS `AudioDeviceModule` fails to initialize on tvOS because
/// tvOS lacks the `AVAudioSession` / microphone APIs the iOS ADM depends on.
/// This causes `RTCPeerConnectionFactory` init to abort with
/// `Check failed: adm_` in `webrtc_voice_engine.cc`.
///
/// By providing our own `RTCAudioDevice` stub to the factory, we bypass the
/// default ADM creation entirely. This is safe for receive-only video streaming
/// (WHEP) since the Ring Partner API streams are video-only from the app's
/// perspective and we have no need to record audio.
///
/// All audio methods return benign success values and do nothing — no audio
/// hardware is touched, so there's nothing to fail.
final class NoOpAudioDevice: NSObject, RTCAudioDevice {

    // MARK: - Audio format properties (required by protocol)

    var deviceInputSampleRate: Double { 48000 }
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { 0 }

    var deviceOutputSampleRate: Double { 48000 }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var outputNumberOfChannels: Int { 2 }
    var outputLatency: TimeInterval { 0 }

    // MARK: - State flags

    private var _isInitialized = false
    private var _isPlayoutInitialized = false
    private var _isRecordingInitialized = false
    private var _isPlaying = false
    private var _isRecording = false

    var isInitialized: Bool { _isInitialized }
    var isPlayoutInitialized: Bool { _isPlayoutInitialized }
    var isRecordingInitialized: Bool { _isRecordingInitialized }
    var isPlaying: Bool { _isPlaying }
    var isRecording: Bool { _isRecording }

    // MARK: - Lifecycle

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        _isInitialized = true
        return true
    }

    func terminateDevice() -> Bool {
        _isInitialized = false
        _isPlayoutInitialized = false
        _isRecordingInitialized = false
        _isPlaying = false
        _isRecording = false
        return true
    }

    // MARK: - Playout

    func initializePlayout() -> Bool {
        _isPlayoutInitialized = true
        return true
    }

    func startPlayout() -> Bool {
        _isPlaying = true
        return true
    }

    func stopPlayout() -> Bool {
        _isPlaying = false
        return true
    }

    // MARK: - Recording

    func initializeRecording() -> Bool {
        _isRecordingInitialized = true
        return true
    }

    func startRecording() -> Bool {
        _isRecording = true
        return true
    }

    func stopRecording() -> Bool {
        _isRecording = false
        return true
    }
}
#endif
