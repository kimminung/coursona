//
//  ComingSoonView.swift
//  coursona
//
//  C8 1단계: 아직 연결 안 된 화면(캡처·빌드·검수·거울·전송 등, 2~5단계에서 채운다) 자리표시자.
//  탭 전환·네비게이션 자체는 지금 바로 되게 해서, 뼈대가 끝까지 눌러볼 수 있는 상태를 유지한다.
//

import SwiftUI

struct ComingSoonView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.bold())
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.coursonaBackground)
    }
}

#Preview {
    ComingSoonView(icon: "camera.viewfinder", title: "캡처", message: "다음 단계에서 연결됩니다.")
}
