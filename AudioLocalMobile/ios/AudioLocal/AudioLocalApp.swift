import SwiftUI

@main
@MainActor
struct AudioLocalApp: App {
    @StateObject private var store = CommentStore()
    @StateObject private var fusion = FusionLeadStore()
    var body: some Scene {
        WindowGroup {
            TabView {
                HomeView().environmentObject(store)
                    .tabItem { Label("精细采集", systemImage: "magnifyingglass") }
                FusionRadarView().environmentObject(fusion)
                    .tabItem { Label("获客雷达", systemImage: "dot.radiowaves.left.and.right") }
                FusionWorkspaceView().environmentObject(store).environmentObject(fusion)
                    .tabItem { Label("线索工作台", systemImage: "tray.full") }
            }
            .preferredColorScheme(.dark)
            .tint(BackdoorTheme.accent)
        }
    }
}
