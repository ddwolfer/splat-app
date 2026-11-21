import SwiftUI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var baseURLText = ""
    @State private var saveMessage: Message?
    @State private var healthMessage: Message?
    @State private var checkingHealth = false

    private struct Message: Equatable {
        var text: String
        var isError: Bool
    }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.20:8000", text: $baseURLText)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(save)
                    HStack {
                        Button("儲存", action: save)
                        Button("測試連線", action: testConnection)
                            .disabled(checkingHealth)
                        if checkingHealth { ProgressView() }
                    }
                    // Two buttons in one Form row: separate hit areas.
                    .buttonStyle(.bordered)
                    if let saveMessage { messageLabel(saveMessage) }
                    if let healthMessage { messageLabel(healthMessage) }
                } header: {
                    Text("Server Base URL")
                } footer: {
                    Text("splat-server 的位址（實際 IP 見 repo 的 STATUS.md）。區網用 http 即可；儲存後會自動關閉 Mock 模式。")
                }

                Section {
                    Picker("最多顯示", selection: $settings.splatBudget) {
                        ForEach(SettingsStore.splatBudgetOptions, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                } header: {
                    Text("顯示品質")
                } footer: {
                    Text("超過上限時先略過幾乎透明的點，再均勻抽樣。第一代 Vision Pro 若不順，可調低。下次開啟 splat 時生效。")
                }

                Section {
                    Toggle("Mock 模式（不連網路）", isOn: $settings.useMock)
                } footer: {
                    Text("開啟時「生成」不會連 server，等一下後回傳 App 內建的範例 splat，用來測試操作流程。")
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { baseURLText = settings.baseURLString }
    }

    private func messageLabel(_ message: Message) -> some View {
        Label(message.text, systemImage: message.isError ? "exclamationmark.triangle" : "checkmark.circle")
            .foregroundStyle(message.isError ? .red : .green)
            .font(.callout)
    }

    private func save() {
        switch settings.saveBaseURL(baseURLText) {
        case let .success(url):
            baseURLText = url.absoluteString
            saveMessage = Message(text: "已儲存", isError: false)
        case let .failure(error):
            saveMessage = Message(text: error.localizedDescription, isError: true)
        }
    }

    /// Checks the typed URL (saved or not) with GET /health.
    private func testConnection() {
        let url: URL
        switch BaseURL.validate(baseURLText) {
        case let .success(valid): url = valid
        case let .failure(error):
            healthMessage = Message(text: error.localizedDescription, isError: true)
            return
        }
        checkingHealth = true
        healthMessage = nil
        Task {
            defer { checkingHealth = false }
            do {
                let health = try await HTTPSplatService(baseURL: url).health()
                healthMessage = health.ok
                    ? Message(text: "連線成功，GPU：\(health.gpu ?? "未知")", isError: false)
                    : Message(text: "server 回報尚未就緒", isError: true)
            } catch {
                healthMessage = Message(text: error.localizedDescription, isError: true)
            }
        }
    }
}
