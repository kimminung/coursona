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
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 700)
        #endif
    }
}
