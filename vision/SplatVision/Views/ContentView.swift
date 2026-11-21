import SwiftUI

struct ContentView: View {
    @MainActor private static var launchHooksRan = false

    @Environment(ImmersiveController.self) private var immersive
    @Environment(GenerationController.self) private var generation
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
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
    /// without clicking: `-autoOpenMock YES`, `-autoOpenFile <ply path>`, `-autoGenerateURL <url>`,
    /// `-autoUploadPath <image path>`, `-showSettings YES`, `-hideWindow YES` (closes this window
    /// a few seconds after opening a splat, for unobstructed screenshots).
    private func runLaunchHooks() {
        // Once per process: reopening the main window must not re-run them (e.g. hide itself again).
        guard !Self.launchHooksRan else { return }
        Self.launchHooksRan = true
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "autoOpenMock") {
            immersive.show(.bundledMock)
        }
        if let path = defaults.string(forKey: "autoOpenFile"), !path.isEmpty {
            immersive.show(.localFile(URL(fileURLWithPath: path)))
        }
        if defaults.bool(forKey: "hideWindow") {
            Task {
                try? await Task.sleep(for: .seconds(4))
                if immersive.state == .open { dismissWindow(id: "main") }
            }
        }
        if let url = defaults.string(forKey: "autoGenerateURL"), !url.isEmpty {
            generation.start(imageURLText: url)
        }
        if defaults.bool(forKey: "showSettings") {
            showingSettings = true
        }
        // `-autoUploadPath <image file>`: runs the photo-upload path with that file (as if picked).
        if let path = defaults.string(forKey: "autoUploadPath"), !path.isEmpty {
            generation.startUpload {
                let source = URL(fileURLWithPath: path)
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("\(UUID().uuidString).\(source.pathExtension)")
                try FileManager.default.copyItem(at: source, to: copy)
                return PickedImageFile(url: copy, originalName: source.deletingPathExtension().lastPathComponent)
            }
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
