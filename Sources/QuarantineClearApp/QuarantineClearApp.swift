import SwiftUI

@main
struct QuarantineClearApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(AppModel())
                .environment(IconCache())
        }
        .defaultSize(width: 620, height: 460)
        .windowResizability(.contentMinSize)
    }
}
