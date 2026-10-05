//
//  PermissionsView.swift
//  coursona
//
//  화면 9(UXPRD) — 권한·시스템 상태. 카메라·마이크(필수)·로컬 네트워크·사진 보기(선택) 4장, 각각 한 줄
//  개인정보 설명 + 지금 상태. 로컬 네트워크·사진 보기는 iOS/macOS 에 "미리 물어보기" API 가 없어 실제
//  요청 시점(캡처·전송 화면)까지는 "필요할 때 확인"으로만 보여준다 — 추측해서 상태를 꾸며내지 않는다.
//

import SwiftUI
import AVFoundation
#if os(iOS)
import UIKit
#endif

private struct PermissionItem: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let required: Bool
    let note: String
    let status: String
    let statusKind: StatusPill.Kind
}

struct PermissionsView: View {
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

    private var items: [PermissionItem] {
        [
            PermissionItem(title: "카메라", systemImage: "camera.fill", required: true,
                           note: "얼굴 형태를 촬영할 때만 사용하고, 사진·영상은 기기 밖으로 나가지 않습니다.",
                           status: text(for: cameraStatus), statusKind: kind(for: cameraStatus)),
            PermissionItem(title: "마이크", systemImage: "mic.fill", required: false,
                           note: "거울(라이브 구동) 화면에서 입 모양을 더 정확히 맞출 때만 사용합니다.",
                           status: text(for: micStatus), statusKind: kind(for: micStatus)),
            PermissionItem(title: "로컬 네트워크", systemImage: "antenna.radiowaves.left.and.right", required: false,
                           note: "같은 기기 간에만 페르소나를 주고받습니다(인터넷 전송 아님).",
                           status: "기기 연동 사용 시 확인", statusKind: .warning),
            PermissionItem(title: "사진 보기", systemImage: "photo.on.rectangle", required: false,
                           note: "사진 1장으로 만들기를 고를 때만 사용합니다.",
                           status: "사진 선택 시 확인", statusKind: .warning),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ForEach(items) { item in PermissionCard(item: item) }
                openSettingsButton
            }
            .padding()
        }
        .background(Color.coursonaBackground)
        .navigationTitle("권한·시스템 상태")
        .onAppear {
            cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        }
    }

    private var openSettingsButton: some View {
        Button {
            #if os(iOS)
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            #elseif os(macOS)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") { NSWorkspace.shared.open(url) }
            #endif
        } label: {
            Label("시스템 설정 열기", systemImage: "gearshape")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .padding(.top, 8)
    }

    private func text(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "허용됨"
        case .denied, .restricted: "거부됨 — 설정에서 바꿀 수 있어요"
        case .notDetermined: "아직 확인 안 함"
        @unknown default: "알 수 없음"
        }
    }

    private func kind(for status: AVAuthorizationStatus) -> StatusPill.Kind {
        switch status {
        case .authorized: .success
        case .denied, .restricted: .error
        default: .warning
        }
    }
}

private struct PermissionCard: View {
    let item: PermissionItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: item.systemImage)
                .font(.title3)
                .frame(width: 36, height: 36)
                .background(.secondary.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(item.title).font(.headline)
                    Text(item.required ? "필수" : "선택")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.secondary.opacity(0.15), in: .capsule)
                        .foregroundStyle(.secondary)
                }
                Text(item.note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StatusPill(text: item.status, kind: item.statusKind)
            }
            Spacer()
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

#Preview {
    NavigationStack { PermissionsView() }
}
