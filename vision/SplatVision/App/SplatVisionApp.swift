import CompositorServices
import SwiftUI

@main
struct SplatVisionApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environment(appModel)
        }
        .defaultSize(width: 560, height: 520)

        ImmersiveSpace(id: AppModel.immersiveSpaceID, for: SplatRequest.self) { request in
            let model = appModel
            let splatRequest = request.wrappedValue
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                SplatSceneRenderer.start(layerRenderer, request: splatRequest, appModel: model)
            }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
