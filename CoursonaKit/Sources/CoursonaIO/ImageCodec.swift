//
//  ImageCodec.swift
//  CoursonaIO
//
//  RGBAImage ↔ PNG/JPEG (ImageIO). 캡처 JPEG 는 EXIF 업라이트로 저장한다(픽셀이 이미 바른 방향, orientation = 1).
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CoursonaCore

public enum ImageCodec {
    public enum CodecError: Error { case encodeFailed, decodeFailed }

    public static func cgImage(_ img: RGBAImage) -> CGImage? {
        let data = Data(img.bytes)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: img.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    public static func rgbaImage(_ cg: CGImage) -> RGBAImage? {
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? RGBAImage(width: w, height: h, bytes: buf) : nil
    }

    public static func encode(_ img: RGBAImage, type: UTType, quality: Double = 0.92) throws -> Data {
        guard let cg = cgImage(img) else { throw CodecError.encodeFailed }
        return try encode(cg, type: type, quality: quality)
    }

    public static func encode(_ cg: CGImage, type: UTType, quality: Double = 0.92) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { throw CodecError.encodeFailed }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality, kCGImagePropertyOrientation: 1]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CodecError.encodeFailed }
        return out as Data
    }

    public static func png(_ img: RGBAImage) throws -> Data { try encode(img, type: .png) }
    public static func jpeg(_ img: RGBAImage, quality: Double = 0.92) throws -> Data { try encode(img, type: .jpeg, quality: quality) }

    public static func decode(_ data: Data) throws -> RGBAImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              let img = rgbaImage(cg) else { throw CodecError.decodeFailed }
        return img
    }

    public static func decodeCGImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 썸네일 (긴 변 `maxDimension`).
    public static func thumbnail(_ img: RGBAImage, maxDimension: Int) -> RGBAImage {
        let scale = min(1, Float(maxDimension) / Float(max(img.width, img.height)))
        let w = max(1, Int(Float(img.width) * scale)), h = max(1, Int(Float(img.height) * scale))
        var out = RGBAImage(width: w, height: h)
        for y in 0..<h { for x in 0..<w {
            let sx = min(img.width - 1, Int((Float(x) + 0.5) / scale)), sy = min(img.height - 1, Int((Float(y) + 0.5) / scale))
            out[x, y] = img[sx, sy]
        } }
        return out
    }
}
