import SwiftUI

@main
struct BitChordApp: App {
    var body: some Scene {
        WindowGroup {
            WebHost()
                .ignoresSafeArea()
                .background(Color.black)
        }
    }
}
