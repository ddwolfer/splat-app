# vision V4：安裝到第一代 Vision Pro 實機

## 目標

1. 教使用者把 App 裝到自己的 Vision Pro（開發者模式、用免費 Apple ID 簽署、Xcode 無線部署），寫進 README「快速開始」。
2. 在實機上量 V2 A 段做好的數字（提交幀率、GPU 時間、記憶體、讀檔時間），決定「顯示品質」的預設值。

**這個里程碑需要使用者戴上頭戴裝置操作，到那一步就停下來等使用者。**

## 事前準備（splat-vision 先做，不需要頭戴裝置）

- **簽署設定不進 git**：`vision/Config/Signing.xcconfig`（commit）放預設的 `PRODUCT_BUNDLE_IDENTIFIER`、
  `CODE_SIGN_STYLE`、空的 `DEVELOPMENT_TEAM`，**最後一行**才 `#include? "Signing.local.xcconfig"`；
  `Signing.local.xcconfig`（`vision/.gitignore` 排除）放使用者自己的 Team（與需要時的 Bundle ID）。
  `project.yml` 把這個 xcconfig 掛到 App target 的 Debug／Release，**並從 target settings 移除這兩個設定**
  （target settings 的優先權高於 xcconfig，否則本機覆寫會無效，Codex #1）。重跑 xcodegen 不會把 Team 洗掉。
  README 提醒：不要在 Xcode 的 Signing 畫面選 Team（那會寫進 `.pbxproj` 被 commit），改寫 `Signing.local.xcconfig`。
- Bundle ID 預設 `io.github.ddwolfer.SplatVision`（免費帳號的 Bundle ID 要全球唯一；撞名就在本機檔覆寫）。
- README「快速開始 > Vision App」草稿。

## 實機步驟（使用者 + splat-vision）

| # | 誰 | 做什麼 |
|---|---|---|
| 1 | 使用者 | 確認 Vision Pro 是 visionOS 26.x（設定 > 一般 > 關於本機）。若已升到 27，Xcode 26.6 無法部署，要改用 Xcode 27（需 macOS 26.6+）。 |
| 2 | 使用者 | Mac 與 Vision Pro 連同一個 Wi-Fi。Mac 打開 Xcode-26.6 > Settings > Accounts > ＋ 加入 Apple ID（免費即可）。密碼與雙重認證由使用者輸入。接著在同一頁選 Personal Team → Manage Certificates → ＋ Apple Development，建立簽署憑證（Codex #2；全新帳號加入後不一定已有憑證）。 |
| 3 | 使用者 | Vision Pro：設定 > 一般 > 遠端裝置（Remote Devices），保持該畫面開著。 |
| 4 | 使用者 | Mac：Xcode > Window > Devices and Simulators，左側出現 Apple Vision Pro → Pair → 在 Mac 輸入頭戴裝置上顯示的配對碼。 |
| 5 | 使用者 | Vision Pro：設定 > 隱私權與安全性 > 開發者模式 → 開啟 → 重新開機 → 開機後確認開啟。 |
| 6 | splat-vision | 從 Apple Development 憑證的 OU 讀出 Team ID（有多個 Team 時請使用者確認），寫入 `Signing.local.xcconfig`；`xcrun devicectl list devices` 確認裝置；`xcodebuild -destination 'platform=visionOS,id=<裝置>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration` 建置 Release（第一次部署要讓 Xcode 註冊這台裝置，Codex #3），`devicectl` 安裝並啟動。若 CLI 簽署失敗，改請使用者在 Xcode 選這台裝置按 Run 一次，之後再用 CLI。 |
| 7 | 使用者 | 若第一次啟動被擋：Vision Pro 設定 > 一般 > 裝置管理（VPN 與裝置管理）→ 信任開發者 Apple ID。 |
| 8 | 使用者 | 開 App → 「顯示內建範例」→ 確認畫面在正前方、天空在上；按「重新置中」；左右移動頭看視差。 |
| 9 | 使用者 | （M3 好了的話）設定填 server Base URL → 第一次連線時允許「區域網路」權限 → 用網址與照片各生成一次。 |
| 10 | 兩邊 | **用 118 萬點的場景量測**（Codex #4；內建範例只有 1.9 萬點，量不到負載）：真實 server 好了就用 SHARP 結果；還沒好就用 Mac 上的 `mock_server.py --count 1179648`（Vision Pro 與 Mac 同網路即可連）頂替並註明。每個品質選項（全部／80／50／30 萬）各開一次，記錄靜止與左右移動頭時的提交幀率、GPU 時間、跳過幀、排序耗時、記憶體，持續 1 分鐘以上。沒有代表性樣本時只驗收部署、延後決定預設值。 |

## 已知限制（寫進 README）

- 免費 Apple ID（Personal Team）：App **7 天後失效**；每台裝置最多 3 個自簽 App；最多 10 個 App ID、3 台註冊裝置（Codex #5）。
  續期用**同一個 Bundle ID 覆蓋安裝**即可（不要先刪 App，刪了會失去本機歷史）；不要為了排查一直換 Bundle ID，會吃掉 App ID 配額。
- 第一次連 server 會跳「區域網路」權限，拒絕後要到 設定 > 隱私權與安全性 > 區域網路 打開。

## 驗收

- README「快速開始 > Vision App」照著做可以從零裝好（以這次實際操作修正文字）。
- 實機：範例在正前方且方向正確；（若有 server）真實 splat 可生成與顯示；記錄實機的提交幀率、GPU 時間、記憶體與讀檔時間，
  決定顯示品質預設值並寫進 STATUS.md 與 V2 計畫。

## Codex 審查

### Plan review（2026-11-21）

1. P2 本機 Bundle ID 覆寫會被 target settings 蓋掉 → **採納**：預設值移到共用 xcconfig，target settings 不再設定；提醒不要在 Xcode UI 選 Team。
2. P2 全新免費帳號未必已有憑證 → **採納**：步驟 2 加上 Manage Certificates 建立 Apple Development；多 Team 時請使用者確認。
3. P2 首次部署需註冊裝置 → **採納**：加 `-allowProvisioningDeviceRegistration` 並指定裝置；失敗改用 Xcode Run 一次。
4. P2 不能用小 mock 決定品質預設 → **採納**：改用 118 萬點（真實 SHARP 或大 mock 頂替並註明），各品質、靜止與移動、持續量測；沒樣本就延後決定。
5. P3 免費帳號配額 → **採納**：README 補上 10 個 App ID、3 台裝置與同 Bundle ID 覆蓋續期。

### Code review：事前準備（2026-11-21）

簽署 xcconfig（本機覆寫、git 忽略）、project.yml 改用 configFiles：沒有 P1／P2。
已驗證：覆寫檔的 Team 與 Bundle ID 會生效、git 忽略該檔、模擬器 89 個測試全過、visionOS 實機架構（未簽署）Release 建置成功。

**進度：事前準備完成，停在步驟 1，等使用者戴上頭戴裝置。**
