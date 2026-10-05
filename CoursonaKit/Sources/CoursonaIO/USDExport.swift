//
//  USDExport.swift
//  CoursonaIO
//
//  T-005 스파이크 결과(2026-10-03, macOS 27.0.1, Xcode 27.0):
//    MDLAsset.canExportFileExtension — usdz: false, usdc: true, usda: true, usd: true, obj/stl/ply/abc: true
//    실제 export — usdc 2744 B OK, usda OK, usdz 실패(MDLErrorDomain "Unknown extension on URL").
//  → 확정 분기: **usdc 를 ModelIO 로 쓰고 ZipArchive(정렬 64) 로 usdz 를 직접 묶는다.** 텍스처 PNG 도 같은 zip 에 넣고
//    usdc 가 상대 경로로 참조하게 한다. 실제 내보내기 구현은 M6 T-606. 여기서는 능력 조회만 둔다.
//

import Foundation
#if canImport(ModelIO)
import ModelIO
#endif

public struct USDExportCapability: Sendable, Equatable {
    public var usdz: Bool
    public var usdc: Bool
    public var usda: Bool
    public var obj: Bool
    public var summary: String {
        "ModelIO 내보내기 — usdz: \(usdz ? "가능" : "불가") · usdc: \(usdc ? "가능" : "불가") · usda: \(usda ? "가능" : "불가") · obj: \(obj ? "가능" : "불가")"
            + (usdz ? "" : " → usdc + 자체 zip(64B 정렬)으로 usdz 생성 (T-005 분기)")
    }
}

public enum USDExport {
    public static func capability() -> USDExportCapability {
        #if canImport(ModelIO)
        return USDExportCapability(usdz: MDLAsset.canExportFileExtension("usdz"), usdc: MDLAsset.canExportFileExtension("usdc"),
                                   usda: MDLAsset.canExportFileExtension("usda"), obj: MDLAsset.canExportFileExtension("obj"))
        #else
        return USDExportCapability(usdz: false, usdc: false, usda: false, obj: false)
        #endif
    }
}
