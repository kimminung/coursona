//
//  MicLevelMeter.swift
//  CoursonaCapture
//
//  소반 `Sensing/MouthSource.swift` 의 MicLevelMeter 이식. 마이크 음량만 재는 가벼운 미터(전 플랫폼). 음성 전송은 하지 않는다.
//  visionOS 에는 입 모양을 보는 내부 카메라 접근이 없으므로 거울·상황 플레이어의 "내 음성 레벨" 입력이 된다.
//

import Foundation
import AVFAudio
import Observation
import os

@MainActor
@Observable
public final class MicLevelMeter {
    private let engine = AVAudioEngine()
    public private(set) var isRunning = false
    public private(set) var level: Float = 0
    public private(set) var peak: Float = 0
    public private(set) var errorText: String?
    public private(set) var permission: String = "확인 전"
    private let sink = LevelSink()
    private var pollTask: Task<Void, Never>?

    public init() {}

    public var permissionGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }

    public func refreshPermissionText() {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: permission = "허용됨"
        case .denied: permission = "거부됨 — 설정 > 개인정보 보호 > 마이크에서 초상을 켜 주세요"
        case .undetermined: permission = "아직 묻지 않음"
        @unknown default: permission = "알 수 없음"
        }
    }

    public func start() async {
        guard !isRunning else { return }
        #if targetEnvironment(simulator)
        errorText = "시뮬레이터에서는 마이크를 쓸 수 없습니다. 실기기에서 확인하세요."
        refreshPermissionText()
        return
        #else
        let granted = await AVAudioApplication.requestRecordPermission()
        refreshPermissionText()
        guard granted else { errorText = "마이크 권한이 없습니다."; return }
        do {
            #if os(iOS) || os(visionOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
            try session.setActive(true)
            #endif
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { errorText = "사용 가능한 마이크 입력이 없습니다."; return }
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { [sink] buffer, _ in
                guard let ch = buffer.floatChannelData?[0] else { return }
                var sum: Float = 0
                let n = Int(buffer.frameLength)
                for i in 0..<n { sum += ch[i] * ch[i] }
                sink.push((sum / Float(max(1, n))).squareRoot())
            }
            engine.prepare()
            try engine.start()
            isRunning = true
            errorText = nil
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { break }
                    let rms = sink.take()
                    let lvl = min(1, max(0, rms * 9 - 0.02))
                    level = max(lvl, level * 0.6)
                    peak = max(lvl, peak * 0.985)
                    try? await Task.sleep(for: .milliseconds(33))
                }
            }
        } catch {
            errorText = "마이크 시작 실패: \(error.localizedDescription)"
        }
        #endif
    }

    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        level = 0
        peak = 0
    }
}

final class LevelSink: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var value: Float = 0
    func push(_ rms: Float) { lock.withLock { value = max(value, rms) } }
    func take() -> Float { lock.withLock { let v = value; value = 0; return v } }
}
