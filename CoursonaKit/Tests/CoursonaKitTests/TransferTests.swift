import Testing
import Foundation
@testable import CoursonaCore
@testable import CoursonaIO

/// T-603 전송 프레이밍·코드·보관 (소켓은 실기기 T-608).
@Suite("전송 (T-603)")
struct TransferTests {
    @Test("헤더 + 본문 왕복, 종류는 확장자에서")
    func roundTrip() throws {
        let body = Data((0..<5000).map { UInt8($0 % 251) })
        let item = TransferItem(name: "me.coursonacapture", data: body)
        #expect(item.kind == .capture)
        #expect(TransferItem(name: "me.coursona", data: Data()).kind == .persona)
        #expect(TransferItem(name: "memo.txt", data: Data()).kind == .other)

        let wire = try TransferFraming.encode(item, sender: "iPhone")
        let decoded = try #require(try TransferFraming.decodeHeader(wire))
        #expect(decoded.header.name == "me.coursonacapture")
        #expect(decoded.header.kind == .capture)
        #expect(decoded.header.byteCount == body.count)
        #expect(decoded.header.sender == "iPhone")
        #expect(decoded.rest == body)
    }

    @Test("조각난 스트림: 헤더가 다 오기 전에는 nil, 다 오면 남은 바이트가 본문 시작")
    func partialStream() throws {
        let body = Data(repeating: 7, count: 300)
        let wire = try TransferFraming.encode(TransferItem(name: "a.coursona", data: body), sender: "Mac")
        // 1바이트씩 넣어 보며 헤더가 완성되는 지점을 찾는다
        var buffer = Data()
        var completedAt: Int? = nil
        for i in 0..<wire.count {
            buffer.append(wire[i])
            if let r = try TransferFraming.decodeHeader(buffer) {
                completedAt = i + 1
                #expect(r.header.byteCount == 300)
                #expect(r.rest.isEmpty)       // 헤더가 막 끝난 순간이라 본문은 아직 0 바이트
                break
            }
        }
        let at = try #require(completedAt)
        #expect(at < wire.count)          // 본문이 오기 전에 헤더가 끝난다
        // 전체를 넣으면 rest 가 본문 전체
        let full = try #require(try TransferFraming.decodeHeader(wire))
        #expect(full.rest == body)
    }

    @Test("깨진 헤더·과대 길이는 던진다")
    func badFrames() {
        var huge = Data()
        var be = UInt32(TransferFraming.maxHeaderBytes + 1).bigEndian
        withUnsafeBytes(of: &be) { huge.append(contentsOf: $0) }
        #expect(throws: TransferFraming.FramingError.self) { _ = try TransferFraming.decodeHeader(huge) }

        var bad = Data()
        var len = UInt32(4).bigEndian
        withUnsafeBytes(of: &len) { bad.append(contentsOf: $0) }
        bad.append(contentsOf: [0x7b, 0x7b, 0x7b, 0x7b])   // "{{{{" — JSON 아님
        #expect(throws: TransferFraming.FramingError.self) { _ = try TransferFraming.decodeHeader(bad) }
    }

    @Test("6자리 코드")
    func codes() {
        for _ in 0..<50 {
            let c = TransferFraming.makeCode()
            #expect(c.count == 6)
            #expect(TransferFraming.isValidCode(c))
        }
        #expect(!TransferFraming.isValidCode("12345"))
        #expect(!TransferFraming.isValidCode("1234567"))
        #expect(!TransferFraming.isValidCode("12a456"))
        #expect(TransferFraming.isValidCode("000000"))
    }

    @Test("받은 파일 보관: 같은 이름은 -2, -3 으로 피한다")
    func receivedStoreNaming() throws {
        // 테스트는 Documents 를 건드리지 않도록 임시 폴더에서 같은 규칙을 검증
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("recv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func writeUnique(_ name: String) -> URL {
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            var url = dir.appendingPathComponent(name), n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = dir.appendingPathComponent(ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
                n += 1
            }
            try? Data("x".utf8).write(to: url)
            return url
        }
        #expect(writeUnique("a.coursona").lastPathComponent == "a.coursona")
        #expect(writeUnique("a.coursona").lastPathComponent == "a-2.coursona")
        #expect(writeUnique("a.coursona").lastPathComponent == "a-3.coursona")
    }
}

/// 같은 머신에서 실제로 광고 → 발견 → TLS PSK 핸드셰이크 → 전송까지 돈다(T-603).
/// Bonjour 와 소켓을 쓰므로 환경에 따라 느릴 수 있어 넉넉한 제한 시간을 둔다. 기기 간 확인은 T-608.
@Suite("전송 루프백", .timeLimit(.minutes(1)))
struct TransferLoopbackTests {
    @MainActor
    @Test("보낸 바이트가 그대로 도착하고 진행률이 1 이 된다")
    func loopback() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tag = String(UUID().uuidString.prefix(6))
        let receiver = CoursonaReceiver(deviceName: "초상테스트-\(tag)")
        receiver.destination = dir
        receiver.start()

        // 광고가 준비될 때까지
        try await waitUntil(8) { if case .waiting = receiver.phase { return true }; if case .failed = receiver.phase { return true }; return false }
        if case .failed(let m) = receiver.phase { Issue.record("수신 대기 실패: \(m)"); return }

        let sender = CoursonaSender(deviceName: "보내는쪽")
        sender.startBrowsing()
        try await waitUntil(15) { sender.peers.contains { $0.name == receiver.deviceName } }
        let peer = try #require(sender.peers.first { $0.name == receiver.deviceName }, "Bonjour 로 상대를 찾지 못했습니다")

        let body = Data((0..<300_000).map { UInt8($0 % 253) })
        sender.send(TransferItem(name: "loop.coursonacapture", data: body), to: peer, code: receiver.code)

        try await waitUntil(25) {
            if case .done = receiver.phase { return true }
            if case .failed = receiver.phase { return true }
            if case .failed = sender.phase { return true }
            return false
        }
        if case .failed(let m) = receiver.phase { Issue.record("수신 실패: \(m)"); return }
        if case .failed(let m) = sender.phase { Issue.record("송신 실패: \(m)"); return }

        guard case .done(let url, let header) = receiver.phase else { Issue.record("완료되지 않음: \(receiver.phase)"); return }
        #expect(header.name == "loop.coursonacapture")
        #expect(header.kind == .capture)
        #expect(header.sender == "보내는쪽")
        #expect(header.byteCount == body.count)
        #expect(try Data(contentsOf: url) == body)
        #expect(receiver.progress == 1)
        #expect(receiver.received.count == 1)
        sender.stopBrowsing()
        receiver.stop()
    }

    /// 코드가 다르면 TLS 핸드셰이크가 깨져 전송이 성립하지 않는다.
    @MainActor
    @Test("코드가 틀리면 전송되지 않는다")
    func wrongCode() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("loop-bad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let receiver = CoursonaReceiver(deviceName: "초상틀린코드-\(String(UUID().uuidString.prefix(6)))")
        receiver.destination = dir
        receiver.start()
        try await waitUntil(8) { if case .waiting = receiver.phase { return true }; return false }

        let sender = CoursonaSender(deviceName: "보내는쪽")
        sender.startBrowsing()
        try await waitUntil(15) { sender.peers.contains { $0.name == receiver.deviceName } }
        let peer = try #require(sender.peers.first { $0.name == receiver.deviceName })

        let wrong = receiver.code == "000000" ? "111111" : "000000"
        sender.send(TransferItem(name: "x.coursona", data: Data(repeating: 1, count: 1000)), to: peer, code: wrong)

        // 완료되면 안 된다 — 실패하거나 아무 일도 없어야 한다
        try? await waitUntil(12) { if case .failed = sender.phase { return true }; if case .done = receiver.phase { return true }; return false }
        if case .done = receiver.phase { Issue.record("틀린 코드로 전송이 완료됐습니다 — PSK 가 적용되지 않았습니다") }
        #expect(ReceivedStore.list(in: dir).isEmpty)
        sender.stopBrowsing()
        receiver.stop()
    }
}

/// 조건이 참이 될 때까지 0.1 초 간격으로 기다린다.
@MainActor
func waitUntil(_ seconds: Double, _ condition: @MainActor () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    if !condition() { throw TimeoutError(seconds: seconds) }
}

struct TimeoutError: Error, CustomStringConvertible {
    let seconds: Double
    var description: String { "\(seconds) 초 안에 조건이 만족되지 않았습니다" }
}
