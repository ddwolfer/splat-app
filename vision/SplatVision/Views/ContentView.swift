import SwiftUI

struct ContentView: View {
    @Environment(ImmersiveController.self) private var immersive
    @Environment(GenerationController.self) private var generation
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    GenerateSection()
                } header: {
                    Text("用網路圖片生成")
                }

                Section {
                    ImmersiveSection()
                } header: {
                    Text("沉浸空間")
                }

                HistorySection()
            }
            .navigationTitle("Splat Vision")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("設定", systemImage: "gearshape") { showingSettings = true }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
        .onAppear {
            immersive.configure(open: openImmersiveSpace, dismiss: dismissImmersiveSpace)
            runLaunchHooks()
        }
    }

    /// Dev/automation hooks (launch arguments), so the simulator can be driven and screenshotted
    /// without clicking: `-autoOpenMock YES`, `-autoGenerateURL <url>`, `-showSettings YES`.
    private func runLaunchHooks() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "autoOpenMock") {
            immersive.show(.bundledMock)
        }
        if let url = defaults.string(forKey: "autoGenerateURL"), !url.isEmpty {
            generation.start(imageURLText: url)
        }
        if defaults.bool(forKey: "showSettings") {
            showingSettings = true
        }
    }
}

/// Shared number formatting for the UI.
enum Format {
    static func seconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " 秒"
    }

    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }
}
