import CompositorServices
import SwiftUI

/// Root object graph, created once per app launch.
@MainActor
@Observable
final class AppModel {
    let settings: SettingsStore
    let history: HistoryStore
    let immersive: ImmersiveController
    let generation: GenerationController

    init() {
        settings = SettingsStore()
        history = HistoryStore(rootDirectory: HistoryStore.defaultRootDirectory())
        immersive = ImmersiveController()
        generation = GenerationController(settings: settings, history: history, immersive: immersive)
        immersive.maxSplatsProvider = { [settings] in settings.maxSplats }
        history.load()
    }
}

@main
struct SplatVisionApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(appModel)
                .environment(appModel.settings)
                .environment(appModel.history)
                .environment(appModel.immersive)
                .environment(appModel.generation)
        }
        .defaultSize(width: 980, height: 760)

        ImmersiveSpace(id: ImmersiveController.spaceID, for: SplatRequest.self) { request in
            let immersive = appModel.immersive
            let splatRequest = request.wrappedValue
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                SplatSceneRenderer.start(layerRenderer, request: splatRequest, immersive: immersive)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
