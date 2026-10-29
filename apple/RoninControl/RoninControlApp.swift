import SwiftUI

@main
struct RoninControlApp: App {
    @StateObject private var studio = Studio()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(studio)
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 800)
        #endif
    }
}

struct RootView: View {
    @EnvironmentObject private var studio: Studio

    var body: some View {
        Group {
            if FormFactor.phone {
                PhoneRunView()
            } else {
                StudioView()
            }
        }
        .task { await studio.refresh() }
    }
}
