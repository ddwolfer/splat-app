# vision V5：用手勢調整場景位置

## 為什麼要做

使用者在實機試用時遇到兩個問題（2026-11-21）：

1. **坐在電腦桌前打開**：場景以頭部位置為原點往前展開，前半段落在桌上；前面是桌子，人也沒辦法走進去看。
2. **站在客廳按「重新置中」後太高**：照片的相機高度被放在站立時的眼睛高度，但照片通常是在比較低的位置拍的，加上 SHARP 的尺度本來就是估的，模型裡的地板浮在真實地板上方。

使用者要的是：用手把場景抓下來、推遠或拉近、轉個方向，讓模型的地板貼在自家地板上。
他選了「捏住拖曳」這一種方式就好，**不要**按鈕面板，也**不要**記住每個場景的位置。

## 範圍

- 要做：單手捏住拖曳平移；雙手捏住轉向與縮放；「重新置中」回到原始位置並清除調整；主視窗顯示操作提示與目前是否已調整。
- 不做（使用者決定或延後）：
  - 傾斜調整（pitch/roll）：拍照時手機若往下斜，模型地板本身是斜的。先不做，使用者實測覺得明顯再加。
  - 微調按鈕面板、每個場景記住位置、自動偵測地板。

## 設計

### 手勢

| 手勢 | 效果 |
|---|---|
| 單手捏住移動 | 場景跟著手平移。**上下 1:1**（對齊地板要準）；**前後左右放大 3 倍**（遠處的場景也推得動） |
| 雙手捏住 | 兩手中點的位移帶動場景平移（1:1）；兩手連線在水平面上轉的角度 = 場景繞垂直軸轉的角度（以兩手中點為軸）；兩手距離的比例 = 縮放（以兩手中點為中心） |
| 放開 | 停在當下的位置（世界座標固定） |
| 主視窗「重新置中」 | 以目前頭部位置重新放置，**清除所有手勢調整**（縮放回 1）。追蹤中斷時會等到追蹤恢復、新位置真正套用的那一幀才一起清除 |
| 換顯示另一個場景 | 調整清除，從原始位置開始 |

- 只接受捏合（`indirectPinch`：看著＋捏；`directPinch`：手直接捏），用 `inputDevicePose.pose3D.position`（捏合點的位置）。觸控板 pointer 忽略。
  **`.ended`／`.cancelled` 只靠 id 清除**，不需要 pose；只有 `.active` 更新要求有效 pose（沒有就略過這一筆，不影響其他手）（Codex #1）。
- 同時最多採用兩個捏合（依開始順序），第三個忽略。
- **「參與的手」改變時重新取基準**（一手加入、一手放開、取消）：當下的調整變成新的起點，手的位置也重新記錄，畫面不會跳。
- 兩手的水平距離 < 5 cm 時不計算轉角；兩手距離 < 5 cm 時不縮放（避免除以接近 0 的數）。
  **這兩個「有效／無效」狀態一改變就重新取基準**（凍結目前的調整、重記手的位置）：進入門檻內不會轉回去，離開時以當下的連線為新基準，
  兩手交叉或起始連線接近垂直都不會突然跳 180°（Codex #2）。
- 總縮放限制在 0.1×～4×。
- 增益（3 倍、1:1）是常數，實機試手感後再調。

### 數學（全部在世界座標、純值型別，可單元測試）

新增 `Rendering/SceneManipulator.swift`：

- 狀態：`adjustment`（4×4，世界座標）、手勢開始時的 `startAdjustment`、各捏合 id 的起始位置與目前位置、加入順序。
- 最終 model 矩陣：`modelMatrix = adjustment · placement · diag(1, −1, −1, 1)`
  （`placement` 仍由 `PlacementController` 依頭部算出，**不改**；調整套在它外面，所以重新置中與調整互不干擾）。
- 單手：`G = T(3·dx, dy, 3·dz)`，`d` = 目前位置 − 起始位置。
- 雙手：`G = T(m) · R_y(θ) · S(s) · T(−m₀)`；`m₀`、`m` 為起始與目前的兩手中點，`θ` 為兩手連線水平投影的有號夾角，`s` = 目前距離 ÷ 起始距離（夾在讓總縮放落在 0.1～4 的範圍）。
- `adjustment = G · startAdjustment`。
- `reset()`：回到單位矩陣並清空手的狀態。

縮放安全性：MetalSplatter 的 shader 以 view 矩陣的 3×3（`W`）投影共變異數（`W Σ Wᵀ`），等比例縮放會正確縮放每個高斯；排序用 view 矩陣反推的相機位置與方向，不受等比縮放影響，且相機或場景一動就會重新排序（已讀 MetalSplatter 1.0.1 原始碼確認）。

### 接線

- `SplatSceneRenderer.start`：在主執行緒設定 `layerRenderer.onSpatialEvent`（visionOS 1.0 起就有，已在 26.5 SDK 確認），把事件轉成 `PinchSample` 交給 `ImmersiveController`（帶 requestID，舊場景的事件忽略）。
- **以「放置世代」同步（Codex #3）**：`PlacementController` 每次真的換了 placement（第一次放置、重新置中生效、模擬姿態換成真實姿態）就把
  `generation` 加 1。render thread 在**同一幀**把 adjustment 歸零並送出 `.placementChanged(generation)` 事件。
  - `SplatSceneRenderer.setAdjustment(_:generation:)`：世代不符（主執行緒還不知道 placement 已換）就忽略，舊手勢不會套到新基準上。
  - `ImmersiveController`（MainActor）持有 `SceneManipulator`；收到 `.placementChanged` 時 `reset()` 並記下新世代；每批捏合事件算完後
    `renderer.setAdjustment(adjustment, generation:)`，並更新可觀察的 `adjustmentSummary`（是否已調整、目前縮放）給 UI。
  - `recenter()` 只送出重新置中請求，**不**在主執行緒先清除調整；等待追蹤期間的手勢照常作用在舊 placement 上，生效那一幀一起清除。
  - 換場景：新的 renderer 從世代 0、調整為單位矩陣開始，`attach` 時 `reset()`。
- UI（`ImmersiveSection`）：顯示「在場景中捏住拖曳可移動；雙手捏住可旋轉、縮放」；已調整時顯示「已手動調整 · 縮放 0.8×」；「重新置中」下方註明會清除調整。
- 啟動參數 `-sceneAdjust "dx,dy,dz,yaw度,縮放"`：直接套一個調整，供模擬器截圖驗證矩陣與縮放的畫面（模擬器無法做雙手捏合）。

## 實作步驟

每一步先寫測試（看它失敗）→ 實作 → 測試通過；全部完成後 Codex code review → commit。

1. **SceneManipulator（純數學）**：`Rendering/SceneManipulator.swift`
   - `struct PinchSample: Equatable { id: AnyHashable; phase: Phase(.active/.ended/.cancelled); position: SIMD3<Float> }`
   - `struct SceneManipulator { private(set) var adjustment: simd_float4x4; var isAdjusted: Bool; var scale: Float; mutating func apply(_ samples: [PinchSample]); mutating func reset() }`
   - 常數：`horizontalGain = 3`、`verticalGain = 1`、`minimumHandSpan: Float = 0.05`、`scaleRange = 0.1...4`
   - `SceneTransforms` 新增 `uniformScale(_:)`。
   - 測試：`SceneManipulatorTests`（見下方「測試」）。
2. **renderer 套用調整**：`PlacementController.generation: Int`（換 placement 才加 1）；`SplatSceneRenderer` 的 `Shared.adjustment`／`adjustmentGeneration`、
   `setAdjustment(_ m: simd_float4x4, generation: Int)`、`RendererEvent.placementChanged(generation: Int)`；
   `SceneTransforms.modelMatrix(placement:adjustment:)`（預設 identity，維持既有呼叫與測試）。
   測試：`SceneTransformsTests` 驗證 `adjustment · placement · flip`；`PlacementControllerTests` 驗證只有真的換 placement 時世代才加 1（`.held` 期間的重新置中不加）。
3. **事件接線與 UI**：`ImmersiveController.handlePinches(_ samples: [PinchSample], requestID: UUID)`、`adjustmentSummary`、收到 `.placementChanged`／`attach` 時 `reset()`；
   `SplatSceneRenderer.start` 設 `onSpatialEvent`，把 `.indirectPinch`／`.directPinch` 且有 `inputDevicePose` 的事件轉成 `PinchSample`；
   `ImmersiveSection` 提示文字與狀態；`-sceneAdjust` 啟動參數。測試：`ImmersiveControllerTests`。
4. **模擬器驗證**：`-sceneAdjust` 截圖（下移 0.5 m、轉 90°、縮放 0.3）。
5. **文件**：`vision/CLAUDE.md` 補手勢與 `-sceneAdjust`；STATUS.md 新增 V5；本檔補 Codex 紀錄與結果。

## 測試

- `SceneManipulatorTests`：
  - 單手：位移與增益（上下 1:1、水平 3 倍）。
  - 第二隻手加入、其中一手放開、取消：重新取基準，調整不跳。
  - 雙手：轉 90° 時兩手中點不動、其他點繞它轉；距離加倍時縮放 2 倍並以中點為中心；總縮放夾在 0.1～4。
  - 小於 5 cm 的防呆、第三隻手忽略、`reset()`。
  - 沒有 pose 的 `.ended`／`.cancelled` 也會移除那隻手（下一次捏合是單手，不是雙手）。
  - 水平距離「有效 → 小於門檻 → 恢復」與兩手交叉：轉角不歸零、不跳 180°。
- `ImmersiveControllerTests`：`.placementChanged` 與換場景會清除調整並更新世代；舊 requestID 的事件被忽略。
- 模擬器：`-sceneAdjust` 截圖（下移、轉 90°、縮小 0.3 倍）確認畫面符合預期；試滑鼠拖曳是否會產生捏合事件。
- 實機（使用者）：在客廳用手勢把模型地板貼到真實地板；確認方向（手往下 → 場景往下）、看著主視窗捏合不會拖到場景、移動時的排序延遲與幀率可接受。

## 風險

1. `inputDevicePose` 的座標系假設與沉浸空間的世界座標相同（與頭部追蹤同一原點）。若實機上方向不對，改成以頭部姿態換算。
2. 混合沉浸模式下，看著空白處捏合是否會送到 CompositorLayer：需實機確認。
3. 118 萬點在第一代 Vision Pro 上排序需要時間，拖曳時半透明順序可能短暫錯亂；放開後會恢復。實機量測時一併觀察。

## 驗收

- 使用者能在客廳用手勢把模型地板對到真實地板、轉向、縮放，放開後固定；重新置中可以回到原始位置。
- 單元測試全過；STATUS.md 新增 V5。

## Codex 審查

### Plan review（2026-11-21）

1. P2 沒有 pose 的 `.ended`／`.cancelled` 被過濾掉會留下失效的手，下次捏合被當成第二隻手 → **採納**：結束／取消只靠 id 清除，只有 `.active` 需要 pose；補測試。
2. P2 兩手水平距離跨越 5 cm 門檻時轉角會歸零或跳 180° → **採納**：轉角與縮放的有效狀態一改變就重新取基準；補「有效→退化→恢復」與交叉測試。
3. P2 追蹤中斷時按重新置中，同鎖清除調整會先把場景跳回、恢復後又跳一次，等待中的手勢套到錯的基準 → **採納**：改用「放置世代」，在 placement 真正換掉的那一幀才清除調整，舊世代的調整被忽略。

### Code review（2026-11-21）

1. P2 雙手操作中某隻手收到沒有 pose 的 `.active`，仍用它的舊位置參與計算（例如兩手一起右移時被誤判為拉開、放大 1.25 倍）→ **採納**：該批凍結不套用變換，該手退出，下一筆有 pose 時重新加入並取新基準；補測試 `aHandLosingItsPoseFreezesInsteadOfScaling`。
2. P3 `-sceneGesture` 接受 NaN／Inf、空欄位被 `compactMap` 靜默略過 → **採納**：每個欄位都必須是有限數字，否則整個 spec 無效；補測試。

修正後再審：沒有 P1／P2。

## 結果

- 模擬器：112 個測試全過（新增 23 個：手勢數學 15、模擬手勢 2、放置世代 1、model 矩陣 1、ImmersiveController 4）。
- `-sceneGesture` 截圖確認：下移 0.5 m（近處物體位移約為 4 m 外背景的 2 倍，透視正確）、轉 30°（從上方看逆時針）、縮放 0.5（splat 縮小後正常）。
- **待實機驗收**：手勢座標方向、看著空白處捏合是否送到場景、拖曳時的排序延遲與幀率。
