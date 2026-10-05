//
//  ZipArchive.swift
//  CoursonaIO
//
//  최소 ZIP 쓰기/읽기 (저장 방식 stored, 압축 없음). 용도: `.coursonacapture`(캡처 번들 zip), `.coursona` 전송용 zip,
//  USDZ(usdc + 텍스처를 64바이트 정렬 stored zip 으로 묶는 규격 — Pixar USDZ 스펙). 외부 라이브러리 없이 Foundation 만.
//  읽기는 stored 와 deflate 중 stored 만 지원한다(우리가 쓴 파일 + usdz 전용).
//

import Foundation

public struct ZipEntry: Sendable {
    public var name: String
    public var data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

public enum ZipArchive {
    /// stored zip 생성. `alignment` > 1 이면 각 파일 데이터 시작 오프셋을 그 배수에 맞춘다(usdz = 64).
    public static func make(entries: [ZipEntry], alignment: Int = 1) -> Data {
        var out = Data()
        var central = Data()
        var count: UInt16 = 0
        let dosTime: UInt16 = 0, dosDate: UInt16 = 0x21 // 1980-01-01
        for e in entries {
            let name = Array(e.name.utf8)
            let crc = crc32(e.data)
            let localHeaderOffset = out.count
            // extra 필드로 데이터 시작을 정렬
            var extra: [UInt8] = []
            if alignment > 1 {
                let dataStart = localHeaderOffset + 30 + name.count
                let pad = (alignment - (dataStart + 4) % alignment) % alignment   // extra 헤더 4바이트 포함
                let extraLen = 4 + pad
                let padded = (dataStart + extraLen) % alignment == 0 ? extraLen : extraLen + alignment
                extra = [0x86, 0x1a] + le16(UInt16(padded - 4)) + [UInt8](repeating: 0, count: padded - 4)
            }
            out.append(contentsOf: [0x50, 0x4b, 0x03, 0x04])
            out.append(contentsOf: le16(20)); out.append(contentsOf: le16(0x0800)) // UTF-8 플래그
            out.append(contentsOf: le16(0)) // stored
            out.append(contentsOf: le16(dosTime)); out.append(contentsOf: le16(dosDate))
            out.append(contentsOf: le32(crc)); out.append(contentsOf: le32(UInt32(e.data.count))); out.append(contentsOf: le32(UInt32(e.data.count)))
            out.append(contentsOf: le16(UInt16(name.count))); out.append(contentsOf: le16(UInt16(extra.count)))
            out.append(contentsOf: name); out.append(contentsOf: extra)
            out.append(e.data)

            central.append(contentsOf: [0x50, 0x4b, 0x01, 0x02])
            central.append(contentsOf: le16(20)); central.append(contentsOf: le16(20)); central.append(contentsOf: le16(0x0800)); central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(dosTime)); central.append(contentsOf: le16(dosDate))
            central.append(contentsOf: le32(crc)); central.append(contentsOf: le32(UInt32(e.data.count))); central.append(contentsOf: le32(UInt32(e.data.count)))
            central.append(contentsOf: le16(UInt16(name.count))); central.append(contentsOf: le16(0)); central.append(contentsOf: le16(0))
            central.append(contentsOf: le16(0)); central.append(contentsOf: le16(0)); central.append(contentsOf: le32(0))
            central.append(contentsOf: le32(UInt32(localHeaderOffset)))
            central.append(contentsOf: name)
            count += 1
        }
        let centralOffset = out.count
        out.append(central)
        out.append(contentsOf: [0x50, 0x4b, 0x05, 0x06])
        out.append(contentsOf: le16(0)); out.append(contentsOf: le16(0))
        out.append(contentsOf: le16(count)); out.append(contentsOf: le16(count))
        out.append(contentsOf: le32(UInt32(central.count))); out.append(contentsOf: le32(UInt32(centralOffset)))
        out.append(contentsOf: le16(0))
        return out
    }

    public enum ReadError: Error, LocalizedError {
        case notZip, unsupportedCompression(String), truncated
        public var errorDescription: String? {
            switch self {
            case .notZip: "ZIP 파일이 아닙니다"
            case .unsupportedCompression(let n): "압축된 항목은 지원하지 않습니다: \(n)"
            case .truncated: "ZIP 이 잘렸습니다"
            }
        }
    }

    /// stored 항목 읽기 (중앙 디렉터리 기준).
    public static func read(_ data: Data) throws -> [ZipEntry] {
        guard data.count >= 22 else { throw ReadError.notZip }
        // EOCD 탐색 (뒤에서부터)
        var eocd = -1
        var i = data.count - 22
        while i >= max(0, data.count - 22 - 65535) {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x05, data[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ReadError.notZip }
        let count = Int(rd16(data, eocd + 10))
        var off = Int(rd32(data, eocd + 16))
        var entries: [ZipEntry] = []
        for _ in 0..<count {
            guard off + 46 <= data.count, data[off] == 0x50, data[off + 1] == 0x4b, data[off + 2] == 0x01, data[off + 3] == 0x02 else { throw ReadError.truncated }
            let method = rd16(data, off + 10)
            let size = Int(rd32(data, off + 24))
            let nameLen = Int(rd16(data, off + 28)), extraLen = Int(rd16(data, off + 30)), commentLen = Int(rd16(data, off + 32))
            let local = Int(rd32(data, off + 42))
            let name = String(decoding: data[(off + 46)..<(off + 46 + nameLen)], as: UTF8.self)
            guard method == 0 else { throw ReadError.unsupportedCompression(name) }
            guard local + 30 <= data.count else { throw ReadError.truncated }
            let lnameLen = Int(rd16(data, local + 26)), lextraLen = Int(rd16(data, local + 28))
            let start = local + 30 + lnameLen + lextraLen
            guard start + size <= data.count else { throw ReadError.truncated }
            entries.append(ZipEntry(name: name, data: data.subdata(in: start..<(start + size))))
            off += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// 폴더 → zip (상대 경로 유지, 숨김 파일 제외).
    public static func zipFolder(_ folder: URL, alignment: Int = 1) throws -> Data {
        let fm = FileManager.default
        var entries: [ZipEntry] = []
        let base = folder.standardizedFileURL.path
        if let en = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                let isFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                guard isFile else { continue }
                var rel = url.standardizedFileURL.path
                if rel.hasPrefix(base) { rel = String(rel.dropFirst(base.count)) }
                if rel.hasPrefix("/") { rel.removeFirst() }
                entries.append(ZipEntry(name: rel, data: try Data(contentsOf: url)))
            }
        }
        entries.sort { $0.name < $1.name }
        return make(entries: entries, alignment: alignment)
    }

    /// zip → 폴더.
    public static func unzip(_ data: Data, to folder: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for e in try read(data) {
            guard !e.name.contains("..") else { continue }
            let url = folder.appendingPathComponent(e.name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try e.data.write(to: url)
        }
    }

    // MARK: helpers
    static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8)] }
    static func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
    static func rd16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[o]) | (UInt16(d[o + 1]) << 8) }
    static func rd32(_ d: Data, _ o: Int) -> UInt32 { UInt32(d[o]) | (UInt32(d[o + 1]) << 8) | (UInt32(d[o + 2]) << 16) | (UInt32(d[o + 3]) << 24) }

    static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }
    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { raw in
            for b in raw { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        }
        return c ^ 0xFFFFFFFF
    }
}
