import SwiftUI
import CoursonaRig

@main
struct CoursonaApp: App {
    @State private var model = AppModel()

    init() {
        FaceRigSystem.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                // Finder "다른 앱으로 열기"·AirDrop 수신 후 열기·파일 앱에서 `.coursona` 를 열면 여기로 온다
                // (Info.plist `CFBundleDocumentTypes`/`UTExportedTypeDeclarations` 로 OS 가 연결 — T-003).
                .onOpenURL { url in
                    Task { await model.importPersona(from: url) }
                }
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        #endif
    }
}
