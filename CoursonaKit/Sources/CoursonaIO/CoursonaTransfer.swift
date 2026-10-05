//
//  CoursonaTransfer.swift
//  CoursonaIO
//
//  기기 간 전송 (TechPRD §6.9, T-603): Bonjour `_coursona._tcp` + TLS **PSK 6자리 코드**.
//  소반이 쓰던 MultipeerConnectivity 는 deprecated 라 처음부터 Network.framework(TN3213 패턴)로 간다.
//
//  프레이밍: `[4바이트 BE 헤더 길이][헤더 JSON][본문 바이트]` 한 건당 한 연결.
//  헤더는 파일 이름·크기·종류만 담는다(사람이 읽을 수 있고, 수신 쪽이 진행률을 계산할 수 있게).
//  프레이밍·헤더는 순수 코드(`TransferFraming`)라 테스트가 지킨다. 소켓 부분은 실기기 검증(T-608).
//

import Foundation
import CoursonaCore
#if canImport(Network)
import Network
import Security
import Observation
#endif

/// 보낼 것 한 건.
public struct TransferItem: Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case persona    // .coursona
        case capture    // .coursonacapture
        case other
        public var title: String {
            switch self {
            case .persona: "페르소나"
            case .capture: "캡처 번들"
            case .other: "파일"
            }
        }
        /// 파일 확장자에서 추정.
        public static func from(fileName: String) -> Kind {
            let ext = (fileName as NSString).pathExtension.lowercased()
            if ext == CoursonaPackageStore.fileExtension { return .persona }
            if ext == CaptureBundleStore.fileExtension { return .capture }
            return .other
        }
    }
    public var name: String
    public var kind: Kind
    public var data: Data
    public init(name: String, kind: Kind? = nil, data: Data) {
        self.name = name
        self.kind = kind ?? Kind.from(fileName: name)
        self.data = data
    }
    public var byteCount: Int { data.count }
}

/// 전송 헤더 (JSON).
public struct TransferHeader: Codable, Sendable, Equatable {
    public var schema: Int = 1
    public var name: String
    public var kind: TransferItem.Kind
    public var byteCount: Int
    /// 보낸 기기 이름 (수신 화면에 표시)
    public var sender: String
    public init(name: String, kind: TransferItem.Kind, byteCount: Int, sender: String) {
        self.name = name; self.kind = kind; self.byteCount = byteCount; self.sender = sender
    }
}

/// 길이 프리픽스 프레이밍 (순수 — 테스트 대상).
public enum TransferFraming {
    public static let serviceType = "_coursona._tcp"
    /// 헤더가 터무니없이 크면 끊는다 (악의적/깨진 스트림 방지)
    public static let maxHeaderBytes = 64 * 1024
    /// 한 번에 받을 수 있는 본문 상한 (256 MB)
    public static let maxBodyBytes = 256 * 1024 * 1024

    public enum FramingError: Error, LocalizedError {
        case headerTooLarge(Int), bodyTooLarge(Int), badHeader
        public var errorDescription: String? {
            switch self {
            case .headerTooLarge(let n): "전송 헤더가 너무 큽니다 (\(n) 바이트)"
            case .bodyTooLarge(let n): "전송 본문이 너무 큽니다 (\(n) 바이트)"
            case .badHeader: "전송 헤더를 읽지 못했습니다"
            }
        }
    }

    /// `[4바이트 BE 길이][헤더 JSON]` + 본문.
    public static func encode(_ item: TransferItem, sender: String) throws -> Data {
        let header = TransferHeader(name: item.name, kind: item.kind, byteCount: item.data.count, sender: sender)
        let json = try JSONEncoder().encode(header)
        guard json.count <= maxHeaderBytes else { throw FramingError.headerTooLarge(json.count) }
        var out = Data(capacity: 4 + json.count + item.data.count)
        var be = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
        out.append(json)
        out.append(item.data)
        return out
    }

    /// 누적 버퍼에서 헤더를 꺼낸다. 아직 모자라면 nil. 남은 바이트(본문 시작)는 `rest` 로.
    public static func decodeHeader(_ buffer: Data) throws -> (header: TransferHeader, rest: Data)? {
        guard buffer.count >= 4 else { return nil }
        let len = buffer.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard len <= UInt32(maxHeaderBytes) else { throw FramingError.headerTooLarge(Int(len)) }
        let need = 4 + Int(len)
        guard buffer.count >= need else { return nil }
        let json = buffer.subdata(in: 4..<need)
        guard let header = try? JSONDecoder().decode(TransferHeader.self, from: json) else { throw FramingError.badHeader }
        guard header.byteCount >= 0, header.byteCount <= maxBodyBytes else { throw FramingError.bodyTooLarge(header.byteCount) }
        return (header, buffer.subdata(in: need..<buffer.count))
    }

    /// 6자리 숫자 코드.
    public static func makeCode() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }
    public static func isValidCode(_ s: String) -> Bool {
        s.count == 6 && s.allSatisfy(\.isNumber)
    }
}

/// 받은 파일 보관 (T-602 의 1차).
public enum ReceivedStore {
    public static var folder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Received", isDirectory: true)
    }
    /// 같은 이름이 있으면 `-2`, `-3` … 을 붙인다. `in:` 은 테스트용(기본은 Documents/Received).
    @discardableResult
    public static func write(_ data: Data, name: String, in root: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let folder = root ?? Self.folder
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = folder.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            let candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            url = folder.appendingPathComponent(candidate)
            n += 1
        }
        try data.write(to: url)
        return url
    }
    public static func list(in root: URL? = nil) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: root ?? folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            }
    }
}

#if canImport(Network)

/// TLS PSK + TCP 파라미터. 양쪽이 **같은 6자리 코드**를 써야 핸드셰이크가 성립한다.
enum TransferParameters {
    static func make(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        let key = Data(code.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("coursona-v1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, key as __DispatchData, identity as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(sec, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = true   // AWDL (같은 Wi-Fi 가 아니어도 근거리 전송)
        return params
    }
}

/// 받기 (visionOS·Mac·iPhone 공용). 코드 6자리를 띄우고 기다린다.
@MainActor
@Observable
public final class CoursonaReceiver {
    public enum Phase: Equatable, Sendable {
        case idle
        case waiting              // 광고 중, 연결 대기
        case connected(String)    // 보낸 기기 이름
        case receiving(TransferHeader, received: Int)
        case done(URL, TransferHeader)
        case failed(String)

        public var isBusy: Bool {
            switch self { case .waiting, .connected, .receiving: true; default: false }
        }
    }

    public private(set) var phase: Phase = .idle
    public private(set) var code = ""
    /// 받은 파일 (최신순)
    public private(set) var received: [URL] = ReceivedStore.list()
    public var deviceName: String
    /// 저장 위치 (기본 Documents/Received). 테스트에서 임시 폴더로 바꾼다.
    public var destination: URL?

    private var listener: NWListener?
    private var connection: NWConnection?
    private var buffer = Data()
    private var header: TransferHeader?
    private var body = Data()
    private let queue = DispatchQueue(label: "coursona.receiver")

    public init(deviceName: String) {
        self.deviceName = deviceName
    }

    public var progress: Double {
        if case .receiving(let h, let got) = phase, h.byteCount > 0 { return min(1, Double(got) / Double(h.byteCount)) }
        if case .done = phase { return 1 }
        return 0
    }

    /// 광고 시작. 코드를 새로 뽑는다.
    public func start() {
        stop()
        let code = TransferFraming.makeCode()
        self.code = code
        buffer = Data(); body = Data(); header = nil
        do {
            let listener = try NWListener(using: TransferParameters.make(code: code))
            listener.service = NWListener.Service(name: deviceName, type: TransferFraming.serviceType)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: if case .idle = self.phase { self.phase = .waiting }
                    case .failed(let e): self.phase = .failed("수신 대기 실패: \(e.localizedDescription)")
                    case .waiting(let e): self.phase = .failed("네트워크 대기: \(e.localizedDescription) — 로컬 네트워크 권한을 확인하세요")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            listener.start(queue: queue)
            self.listener = listener
            phase = .waiting
        } catch {
            phase = .failed("수신 대기를 시작하지 못했습니다: \(error.localizedDescription)")
        }
    }

    public func stop() {
        listener?.cancel(); listener = nil
        connection?.cancel(); connection = nil
        if phase.isBusy { phase = .idle }
    }

    private func accept(_ conn: NWConnection) {
        guard connection == nil else { conn.cancel(); return }   // 한 번에 하나만
        connection = conn
        phase = .connected("연결됨")
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                if case .failed(let e) = state { self.phase = .failed("연결 실패: \(e.localizedDescription)"); self.connection = nil }
                if case .cancelled = state { self.connection = nil }
            }
        }
        conn.start(queue: queue)
        receiveMore(conn)
    }

    private func receiveMore(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.phase = .failed("수신 오류: \(error.localizedDescription)"); return }
                if let data, !data.isEmpty { self.ingest(data) }
                if isComplete { self.finish() } else if self.connection != nil { self.receiveMore(conn) }
            }
        }
    }

    private func ingest(_ data: Data) {
        if header == nil {
            buffer.append(data)
            do {
                guard let (h, rest) = try TransferFraming.decodeHeader(buffer) else { return }
                header = h
                body = rest
                buffer = Data()
                phase = .receiving(h, received: body.count)
            } catch {
                phase = .failed(error.localizedDescription)
                connection?.cancel(); connection = nil
            }
        } else {
            body.append(data)
            if let h = header { phase = .receiving(h, received: body.count) }
        }
        if let h = header, body.count >= h.byteCount { finish() }
    }

    private func finish() {
        guard let h = header else { return }
        let payload = body.count > h.byteCount ? body.prefix(h.byteCount) : body
        guard payload.count == h.byteCount else {
            phase = .failed("전송이 끊겼습니다 (\(payload.count)/\(h.byteCount) 바이트)")
            cleanupConnection()
            return
        }
        do {
            let url = try ReceivedStore.write(Data(payload), name: h.name, in: destination)
            received = ReceivedStore.list(in: destination)
            phase = .done(url, h)
        } catch {
            phase = .failed("저장 실패: \(error.localizedDescription)")
        }
        cleanupConnection()
    }

    private func cleanupConnection() {
        header = nil; body = Data(); buffer = Data()
        connection?.cancel(); connection = nil
        listener?.cancel(); listener = nil
    }

    public func refreshReceived() { received = ReceivedStore.list(in: destination) }
}

/// 보내기 (iPhone·Mac). 근처 기기를 찾아 코드로 연결한다.
@MainActor
@Observable
public final class CoursonaSender {
    public struct Peer: Identifiable, Hashable, Sendable {
        public var id: String { name }
        public var name: String
        let endpoint: NWEndpoint
    }
    public enum Phase: Equatable, Sendable {
        case idle
        case browsing
        case sending(sent: Int, total: Int)
        case done
        case failed(String)
    }

    public private(set) var peers: [Peer] = []
    public private(set) var phase: Phase = .idle
    public var deviceName: String

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "coursona.sender")

    public init(deviceName: String) { self.deviceName = deviceName }

    public var progress: Double {
        if case .sending(let sent, let total) = phase, total > 0 { return min(1, Double(sent) / Double(total)) }
        if case .done = phase { return 1 }
        return 0
    }

    /// 근처 기기 찾기 (코드는 연결할 때 쓴다 — 브라우징은 암호화 파라미터가 필요 없다).
    public func startBrowsing() {
        stopBrowsing()
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: TransferFraming.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.peers = results.compactMap { r in
                    guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                    return Peer(name: name, endpoint: r.endpoint)
                }
                .sorted { $0.name < $1.name }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed(let e) = state { self?.phase = .failed("검색 실패: \(e.localizedDescription)") }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
        phase = .browsing
    }

    public func stopBrowsing() {
        browser?.cancel(); browser = nil
        peers = []
        if case .browsing = phase { phase = .idle }
    }

    /// 한 건 보내기. 코드가 다르면 TLS 핸드셰이크에서 끊긴다.
    public func send(_ item: TransferItem, to peer: Peer, code: String) {
        guard TransferFraming.isValidCode(code) else { phase = .failed("코드는 숫자 6자리입니다"); return }
        connection?.cancel()
        let payload: Data
        do { payload = try TransferFraming.encode(item, sender: deviceName) }
        catch { phase = .failed(error.localizedDescription); return }

        let conn = NWConnection(to: peer.endpoint, using: TransferParameters.make(code: code))
        connection = conn
        phase = .sending(sent: 0, total: payload.count)
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.transmit(conn, payload: payload)
                case .failed(let e):
                    self.phase = .failed("연결 실패: \(e.localizedDescription) — 코드가 맞는지 확인하세요")
                    self.connection = nil
                case .waiting(let e):
                    self.phase = .failed("연결 대기: \(e.localizedDescription)")
                default: break
                }
            }
        }
        conn.start(queue: queue)
    }

    /// 64 KB 씩 끊어 보내며 진행률을 갱신한다.
    private func transmit(_ conn: NWConnection, payload: Data) {
        let chunk = 64 * 1024
        var offset = 0
        func next() {
            guard offset < payload.count else {
                conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                    Task { @MainActor in
                        self.phase = .done
                        conn.cancel()
                        self.connection = nil
                    }
                })
                return
            }
            let end = min(offset + chunk, payload.count)
            let slice = payload.subdata(in: offset..<end)
            offset = end
            conn.send(content: slice, contentContext: .defaultMessage, isComplete: false, completion: .contentProcessed { error in
                Task { @MainActor in
                    if let error { self.phase = .failed("보내기 오류: \(error.localizedDescription)"); conn.cancel(); self.connection = nil; return }
                    self.phase = .sending(sent: end, total: payload.count)
                    next()
                }
            })
        }
        next()
    }

    public func cancel() {
        connection?.cancel(); connection = nil
        if case .sending = phase { phase = .idle }
    }
}
#endif
