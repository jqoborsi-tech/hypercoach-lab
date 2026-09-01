import SwiftUI

@main
struct ArchScanApp: App {
    @StateObject private var store = CaseStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
