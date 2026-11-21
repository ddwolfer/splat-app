# server M3：區網可連線

## 目標

server 綁 `0.0.0.0:8000`，開 Windows 防火牆讓同一個區網的 Vision Pro／Mac 能連線，把 IP 寫進 STATUS.md，通知 splat-vision。

## 現況

- 乙太網路「網路 5」：**192.168.0.32/24**，gateway 192.168.0.1，網路設定檔 **Private**。
- 另有 Radmin VPN 網卡（26.144.65.140/8），設定檔 **Public**。
- 目前沒有任何 splat 或 sharp python.exe 相關的防火牆規則。
- server 已在 M2 完成：`run_server.ps1 -Lan`／`run_server.sh --lan` 綁 0.0.0.0。

## 步驟

1. 使用者在**系統管理員 PowerShell** 執行（我沒有管理員權限，需要使用者操作）：
   ```powershell
   New-NetFirewallRule -DisplayName "splat-server 8000 (LAN)" `
     -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8000 `
     -Profile Private -RemoteAddress LocalSubnet `
     -Program "C:\Users\91006\anaconda3\envs\sharp\python.exe"
   ```
   - 只開 Private 設定檔 + 本地子網路 + 只限這個 python.exe → Radmin VPN（Public）和外網都連不到。
   - 移除：`Remove-NetFirewallRule -DisplayName "splat-server 8000 (LAN)"`
   - 如果 server 第一次 listen 時跳出 Windows Defender「允許存取」視窗：只勾「私人網路」再按允許。不要按取消（取消會建立封鎖規則，而 Windows 防火牆的封鎖規則優先於允許規則）。
2. 我以 `-Lan` 重新啟動 server，驗證：
   - `Get-NetTCPConnection -LocalPort 8000 -State Listen` 顯示 0.0.0.0
   - 本機用區網 IP 打 `http://192.168.0.32:8000/health`
   - 確認規則存在且已啟用：`Get-NetFirewallRule -DisplayName "splat-server 8000 (LAN)"`
   - 真正的跨機器驗證請 splat-vision 從 Mac 執行 `curl http://192.168.0.32:8000/health`（同一個區網）。
3. 寫進 STATUS.md：Base URL `http://192.168.0.32:8000`、啟動方式、IP 可能因 DHCP 改變（建議在路由器設 DHCP 保留）。
4. 傳訊息給 splat-vision：「server 已可連線」＋範例 .ply 下載網址。

## 風險

- DHCP 換 IP → STATUS.md 的 IP 失效。對策：建議使用者在路由器設保留位址；server 啟動時 log 印出目前的區網 IP。
- 綁 0.0.0.0 也會在 Radmin VPN 介面 listen，但防火牆規則只開 Private，所以 VPN 端連不進來。
- API 沒有驗證（M2 決定）：同一個區網的任何裝置都能呼叫，個人家用網路可接受。
- Vision Pro／Mac 若連的是訪客 Wi-Fi 或 AP 隔離的網段，會連不到；這要在 vision 端測試時排除。

## 依 Codex plan review 修訂（優先於上文）

- 防火牆規則改成明確限定：`-InterfaceAlias "乙太網路"`（實際網卡別名，Realtek 2.5GbE）＋ `-RemoteAddress 192.168.0.0/24` ＋ `-Profile Private` ＋ TCP 8000 ＋ 該 python.exe。
- 已確認（唯讀）：Domain／Private／Public 三個設定檔防火牆都啟用，DefaultInboundAction = NotConfigured（＝預設封鎖）；沒有任何規則放行 `envs\sharp\python.exe`。其他 python（`C:\python313`、uv、cursor 的 wake-conda）已有既存的放行規則，與本專案無關，不動它們。port 層級的規則查詢需要管理員權限，請使用者在建立規則時一起執行。
- 不再建議「彈窗時勾私人網路」：先建立精確規則再啟動 server；若仍跳出視窗就回報，我再排查。
- 綁定維持 `0.0.0.0`（DHCP 換 IP 時綁特定 IP 會直接啟動失敗）；入口由防火牆的 InterfaceAlias 限定。server 以 `-Lan` 啟動時在 log 印出目前的區網 IP。
- 驗收：本機用 192.168.0.32 打 /health＋規則檢查（我）；跨機完整流程（上傳 → 取得 ply_url → 完整下載並比對大小）由 splat-vision 從 Mac 執行並回報；沒有 Radmin VPN 的另一台機器可以測，VPN 入口被擋這點記為「未實測，依規則推論」。

## Codex 審查

### Plan review（2026-11-21）
1. 「VPN／外網連不到」結論過強，要確認設定檔啟用與預設封鎖、其他規則 → **採納**：已唯讀檢查（見上）；port 規則請使用者以管理員查。
2. LocalSubnet／Private 不夠明確 → **採納**：改用 InterfaceAlias＋192.168.0.0/24。
3. 刪除「彈窗勾私人網路」的建議 → **採納**。
4. `-Program` 只限執行檔，腳本參數可覆寫 port → **採納（記錄）**：規則寫死 8000 與 sharp env 的 python.exe，啟動腳本預設也是這兩個；改 port 就要另外加規則（寫在 server/CLAUDE.md）。
5. 直接綁 LAN IP 比較單純 → **不採納**：DHCP 換 IP 時 server 會啟動失敗；改以防火牆 InterfaceAlias 限定入口，並建議在路由器設 DHCP 保留。
6. 驗收要跨機成功＋受限入口失敗的證據 → **部分採納**：跨機成功由 vision 實測；VPN 被擋因沒有測試節點，記為未實測。
7. /health 不代表完整流程 → **採納**：請 vision 做上傳 → 下載 → 比對大小的完整測試；無驗證的風險（區網裝置可占用 GPU、列出、下載、觸發淘汰）寫進 STATUS／API 說明。
