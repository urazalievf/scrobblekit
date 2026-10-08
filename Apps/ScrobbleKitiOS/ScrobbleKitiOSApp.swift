import ScrobbleCore
import SwiftUI

@main
struct ScrobbleKitiOSApp: App {
    @State private var model = AppModel.shared
    @AppStorage("onboardingComplete") private var onboardingComplete = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Background task handlers must be registered before launch finishes.
        BackgroundTaskScheduler.register()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if onboardingComplete {
                    HomeView()
                } else {
                    OnboardingView { withAnimation(.smooth) { onboardingComplete = true } }
                }
            }
            .environment(model)
            .modelContainer(model.container)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background: model.enteredBackground()
            default: break
            }
        }
    }
}
