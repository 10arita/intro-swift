import SwiftUI
import AppIntents

@MainActor
final class PracticeShortcutRoute: ObservableObject {
    static let shared = PracticeShortcutRoute()
    @Published var practiceRequest: UUID?

    private init() {}
}

struct StartPracticeIntent: AppIntent {
    static let title: LocalizedStringResource = "ひとりで練習"
    static let description = IntentDescription("オリジナル音源でイントロクイズを始めます。")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            PracticeShortcutRoute.shared.practiceRequest = UUID()
        }
        return .result()
    }
}

struct IntoLShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartPracticeIntent(),
            phrases: ["\(.applicationName)でひとりで練習を始める"],
            shortTitle: "ひとりで練習",
            systemImageName: "waveform"
        )
    }
}

@main
struct IntoLApp: App {
    @StateObject private var model = AppModel()

    init() {
        IntoLShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
