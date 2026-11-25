# Clash Harmony 跨平台开发与移植指南（macOS / Android / Linux / iOS）

> 本文档面向接手开发 **macOS、Android、Linux、iOS** 等其他平台客户端的 AI 编程助手与工程师。
> 仓库已完整验证 **HarmonyOS NEXT (`API 23`, `arm64-v8a`)** 与 **Windows (`amd64` 单二进制桌面版)** 双端闭环；新平台开发应**最大限度复用同一套 patched Mihomo + Tailscale Go 核心、数据契约、配置融合引擎与交互范式**，避免重复踩坑。

---

## 1. 整体架构与代码复用矩阵

Clash Harmony 的核心价值在于：**用同一个系统 VPN/TUN 通道同时承载 Mihomo（Clash Meta）多协议规则分流与原生 `type: tailscale` 异地组网（含 MagicDNS、SplitDNS、Subnet Router、真实 ICMP Ping）**，并提供面向真实高频场景的 **Fail-Closed AI 严格自建出口保护** 与 **桌面端 → 移动端局域网二维码同步**。

```text
┌────────────────────────────────────────────────────────────────────────────┐
│                           共享 Go 核心底座（本仓唯一真相源）                    │
│  third_party/mihomo            (Meta v1.19.34 + TUN/ICMP/RuleTest/Cleanup 补丁)│
│  third_party/metacubex-tailscale (v1.102.3 + netmon/magicsock/tsnet 自愈补丁) │
│  third_party/metacubex-wireguard-go (PR #116 收包恢复补丁)                     │
└───────────────────┬────────────────────────────────────┬───────────────────┘
                    │                                    │
        ┌───────────▼───────────┐            ┌───────────▼───────────┐
        │ 桌面端模式 (desktop/)  │            │ 移动端模式 (go_bridge/)│
        │ 单 Go 二进制 + 嵌入式   │            │ C-Shared .so / .aar / │
        │ Web UI (127.0.0.1:9091)│            │ .xcframework + 宿主   │
        │ + 系统托盘 + 自动 TUN   │            │ VpnService tunFd 移交  │
        └───────────┬───────────┘            └───────────┬───────────┘
         Windows (已完成)                      HarmonyOS (已完成)
         macOS   (复用 ~95% desktop/)          Android   (复用 ~90% go_bridge/)
         Linux   (复用 ~95% desktop/)          iOS       (NEPacketTunnelProvider)
```

### 各平台复用策略速查

| 目标平台 | 推荐参考基线 | 内核集成方式 | TUN 创建方式 | UI 方案 | 预计新增平台代码量 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **macOS** (`arm64`/`amd64`) | `desktop/` | 原生 Go 二进制 | `sing-tun` 自动创建 `utun` | 直接复用 `desktop/web/index.html` + 菜单栏托盘 | 极小（仅 3 个 `_darwin.go` 文件） |
| **Linux** (`amd64`/`arm64`) | `desktop/` | 原生 Go 二进制 | `sing-tun` 自动创建 `tun` | 直接复用 `desktop/web/index.html` + 可选托盘 | 极小（仅 2-3 个 `_linux.go` 文件） |
| **Android** (`arm64-v8a`) | `go_bridge/` + `app/` | `gomobile` 或 `c-shared` `.so` + JNI | `android.net.VpnService` 移交 `tunFd` | Kotlin + Jetpack Compose（对齐 6 项抽屉菜单） | 中等（原生壳 + UI） |
| **iOS** (`arm64`) | `go_bridge/` | `gomobile bind` 生成 `.xcframework` | `NEPacketTunnelProvider` (`packetFlow` 或 `utun` fd) | SwiftUI（对齐 6 项抽屉菜单） | 中大（受 50 MB 扩展内存限制） |

---

## 2. 必须保留的内核补丁清单（绝对不可回退）

无论移植到哪个平台，构建时必须保留 `third_party/` 下的以下全部定制补丁（已在 `go.mod` `replace` 中锁定）：

1. **Mihomo TUN 重启假活修复**（`third_party/mihomo/listener/listener.go`）
   - `Cleanup()` 必须加锁并重置 `LastTunConf = LC.Tun{}`；
   - `ReCreateTun()` 复用分支必须判断 `tunConf.Equal(LastTunConf) && (!tunConf.Enable || tunLister != nil)`。
   - **否则**：任何 `executor.Shutdown()` 后的二次启动都会跳过重建 TUN，导致 UI 显示已连接但虚拟网卡已死。
2. **禁止给 TUN 分配 `.0` 网络地址**（`third_party/mihomo/config/config.go` `parseTun()`）
   - 上游 Mihomo 忽略 YAML 中的 `tun.inet4-address`，直接从 `dns.fake-ip-range` 取 IP。某些订阅（如 BitzNet）下发 `198.18.0.0/15`，会导致 TUN 绑定非法 `.0` 地址 `198.18.0.0/30`，在 Windows/部分系统上引发 TCP 连接被内核异常中断（`wsarecv: An established connection was aborted`）。
   - 已在 `parseTun()` 中强制将末尾 `.0` 修正为 `.1`（`198.18.0.1/30`），且配置层同时清洗 `fake-ip-range`。
3. **Tailscale 真实 ICMP Echo 转发**（`third_party/mihomo/listener/sing_tun/prepare.go` & `adapter/outbound/tailscale.go`）
   - `PrepareConnection` 对 `NetworkICMP` 解析最终命中的 Proxy，若实现 `ConnectICMP`（即 `*outbound.Tailscale`），通过 `ping.ConnectGVisor(..., ns.IPStack(), bind4, bind6, ...)` 走 Tailscale gVisor 栈真实发包，使 `ping 100.x.x.x` 与 `ping 192.168.1.x` 返回真实 RTT。
4. **Tailscale `LookupHook` 过滤 Fake-IP**（`third_party/mihomo/adapter/outbound/tailscale.go`）
   - 解析 `controlplane.tailscale.com` / DERP 域名时若系统或残留本地 DNS 返回 `198.18.0.0/15` Fake-IP，必须直接过滤丢弃并回退真实 DNS，防止 Tailscale 控制面自环卡死。
5. **实时规则命中测试 API**（`third_party/mihomo/tunnel/tunnel.go` + `desktop/tailscale_api.go` / `go_bridge/tailscale_api.go`）
   - 暴露 `ResolveProxy` 供 `POST /config/rule-test`（或 `/api/rule-test`）直接查询运行中 Mihomo 引擎对任意域名/URL/IP 的真实命中规则、规则类型、策略组链路与最终出口节点。
6. **主动启动 Tailscale 出站 & 持续监听 IPN Bus**（`adapter/outbound/base.go` `UnwrapAdapter()` + `adapter/outbound/tailscale.go`）
   - `adapter/parser.go` 会用 `autoCloseProxyAdapter` 包装所有出站，启动核心后必须通过 `UnwrapAdapter()` 解包并调用 `*outbound.Tailscale.Start()`；
   - `watchBackendState()` 持续监听 IPN Bus，在 `NeedsLogin` 且无 `AuthURL` 时自动触发 `StartLoginInteractive()`，并原子写入 `tailscale-status.json`。
7. **移动沙箱纯 Go TUN 与 `netns`/`os.Executable()` 兼容**
   - `third_party/mihomo/listener/sing_tun/tun_rw_gvisor.go`（纯 Go `os.File` gVisor 栈）；
   - `third_party/metacubex-tailscale/tsnet/tsnet.go`（允许 `os.Executable()` 失败回退 `"tsnet"`）；
   - `third_party/metacubex-tailscale/wgengine/magicsock/magicsock.go` + `third_party/metacubex-wireguard-go/`（切网 UDP 断连自愈）。

---

## 3. 跨平台统一数据契约与核心融合管线

所有平台必须遵守相同的运行时文件布局、配置融合顺序与同步协议，才能保证任意两台设备（如 macOS ↔ Android、Windows ↔ HarmonyOS）之间配置 100% 无缝互通。

### 3.1 运行时目录 (`runtime/`) 标准文件

| 文件名 | 作用 | 跨设备是否同步 |
| :--- | :--- | :--- |
| `current.yaml` | 融合后的最终生效 Mihomo 配置（每次启动/热重载自动重新生成） | 否（自动生成） |
| `overlay.json` | 自建节点 + AI 严格分流预设 + Fail-Closed 开关 + 自定义最高优先级规则 | **是** |
| `tailscale-prefs.json` | Tailscale 原生托管配置（路由策略 + 本机身份） | **仅同步路由策略，严禁同步本机身份/凭证** |
| `tailscale-status.json` | 内核实时原子写入的 Tailscale 状态、IP、`authUrl`、健康告警、日志 | 否（运行态） |
| `tailscale/tailscaled.state` | 本机 Tailscale 节点密钥持久化状态 | **严禁同步** |
| `geoip.metadb` | 内置完整 MetaCubeX GeoIP 数据库（**必须为完整 8.4 MB 有效 MMDB**） | 随安装包内置 |
| `mihomo-core.log` | 过滤 `DEBUG` 后的核心滚动日志（上限 ~256 KB） | 否（诊断用） |

### 3.2 四层配置融合管线（严格顺序不可颠倒）

参考实现：`desktop/config_builder.go` + `desktop/overlay.go`（Go）与 `app/entry/src/main/ets/services/RuntimeConfigService.ets` + `OverlayService.ets` + `TailscalePrefsService.ets`（ArkTS）。

```text
[层 0] 用户原始订阅 / 本地 YAML（只读基线，永不直接改写用户覆写层）
   │
   ▼
[层 1] CustomOverlay 覆写融合（订阅更新永不覆盖！）
   ├─ 解析自建节点：同时支持直接粘贴 vless:// / trojan:// / ss:// / vmess:// / hy2:// URI 与标准 Clash YAML
   ├─ 自动为自建节点 server 域名注入最高优先级 DIRECT 规则（防止节点解析/连接自环）
   ├─ 创建独立 AI 策略组（默认名 `🛡️ AI严格自建`）
   ├─ Fail-Closed 强保护：AI 组仅包含自建节点（未填自建节点时仅含 REJECT），绝不混入商业订阅或 DIRECT
   ├─ 按勾选的 AI 厂商预设（claude / gemini+Antigravity / openai / cursor / xai / other_ai）注入域名/关键词规则至顶部
   └─ 注入用户自定义最高优先级规则
   │
   ▼
[层 2] Tailscale 原生托管融合
   ├─ 移除订阅中原有的同名/同类型 tailscale 出站，按 tailscale-prefs.json 注入标准 `type: tailscale` 出站
   ├─ 注入 `dns.nameserver-policy`（`+.ts.net`、Tailnet 后缀、所有 SplitDNS 域名 -> `tailscale://Tailscale`）
   ├─ 注入 `dns.fake-ip-filter`（放行 `*.ts.net` 与所有 SplitDNS 域名，避免被 Fake-IP 劫持）
   ├─ 顶部规则注入：
   │    1. `DOMAIN-SUFFIX,tailscale.com,DIRECT` / `tailscale.io,DIRECT`
   │    2. `DOMAIN-SUFFIX,ts.net,Tailscale`
   │    3. `IP-CIDR,100.64.0.0/10,Tailscale,no-resolve` & `IP-CIDR6,fd7a:115c:a1e0::/48,Tailscale,no-resolve`
   │    4. 所有 SplitDNS 域名 `DOMAIN-SUFFIX,<dom>,Tailscale`
   │    5. 所有在线 Tailscale Subnet Router 网段 `IP-CIDR,<cidr>,Tailscale,no-resolve`（必须排除本机物理网卡局域网网段防自环！）
   └─ 所有上述规则必须位于订阅自带的 `IP-CIDR,192.168.0.0/16,DIRECT` 和 `GEOIP,CN,DIRECT` 之上！
   │
   ▼
[层 3] 平台运行时规范化 (Normalize)
   ├─ 剔除 `dns.proxy-server-nameserver` 中的回环地址（如 `127.0.0.1:7874`，防止与其他代理客户端冲突）
   ├─ 修正 `dns.listen: 127.0.0.1:7874` -> `127.0.0.1:17874`
   ├─ 修正 `.0` 结尾的 `dns.fake-ip-range`（如 `198.18.0.0/15` -> `198.18.0.1/15`）
   ├─ 默认开启 `sniffer:`（HTTP / TLS / QUIC SNI 嗅探 + `override-destination: true`），解决直连 IP 流量不命中域名规则的问题
   ├─ 当顶层 `ipv6` 未显式开启时，设置 `dns.ipv6: false` 与 `tun.inet6-address: []` 防止 IPv6 泄漏
   ├─ 接管 `external-controller: 127.0.0.1:9090` 与平台专属 `tun:` 段
   └─ 校验 `geoip.metadb` 字节大小与内置资源完全一致，不一致时强制覆盖并清理残留的 `Country.mmdb`/`geoip.db`
```

> **YAML 缩进兼容红线**：部分机场订阅（如 BitzNet）使用 **4 空格缩进**，而标准 Clash 使用 2 空格。所有 YAML 块级插入/删除逻辑**必须动态探测目标 section 的实际缩进宽度**，禁止硬编码 2 空格！

### 3.3 跨设备扫码同步协议 (`MobileSyncBundle`)

参考实现：`desktop/sync_qr.go` 与 `app/entry/src/main/ets/services/OverlayService.ets` (`importFromQrSyncText`)。

1. **发送端（任意桌面端 Windows/macOS/Linux）**：
   - 在局域网开启临时一次性 HTTP 服务（随机端口，5 分钟自动过期，128-bit 随机 `token`）。
   - 提供本机所有有效局域网 IPv4 网卡下拉选择器（自动过滤 `127.x`、`169.254.x`、`198.18.x`、虚拟网卡）。
   - 生成二维码文本：`clashharmony://sync?url=http%3A%2F%2F<LAN_IP>%3A<PORT>%2Fsync%3Ftoken%3D<HEX32>`。
2. **同步载荷边界（安全与正确性红线）**：
   - **同步项**：`overlay`（自建节点 + AI 预设 + Fail-Closed + 自定义规则）、`tailscaleRouting`（仅路由策略：`managedByApp`, `enabled`, `proxyName`, `controlUrl`, `acceptRoutes`, `autoInjectMagicDns`, `tailnetSuffix`, `autoSyncSplitDns`, `splitDnsDomains`, `subnetRoutes`）、`profiles`（当前生效配置）。
   - **严禁同步项**：`hostname`（本机设备名）、`authKey`（认证密钥）、`tailscaled.state`（私钥）、`exitNode`（出口节点选择）。接收端导入时**必须无条件保留本机原有身份字段**，让新设备独立登录自己的 Tailscale 节点。
3. **接收端（HarmonyOS / Android / iOS）**：
   - 扫码解析 `clashharmony://sync?url=...` -> HTTP GET 拉取 JSON -> 写入 `overlay.json`、合并 `tailscale-prefs.json` 路由字段、导入配置（若本机尚无配置则自动激活；若已有配置则作为「待生效配置」卡片供用户核对后一键切换）。

### 3.4 本地控制面 API 契约

- **Mihomo Controller (`127.0.0.1:9090`)**：标准 RESTful API（`/version`, `/configs`, `/proxies`, `/proxies/:name/delay`, `/connections`, `/rules`, `/traffic`）。
- **扩展控制 API**（桌面端集成在 UI 端口 `127.0.0.1:9091`，移动端通过 `go_bridge` 独立本地端口暴露）：
  - `GET /tailscale/status`：返回本机节点状态、IP、`authUrl`、所有 `peers`（含在线/直连/中继/流量）、`advertisedRoutes`、`splitDns`。
  - `POST /tailscale/login` / `/tailscale/logout`：触发交互式登录（等待最多 3 秒返回 `authUrl`）或登出。
  - `POST /tailscale/prefs`：热更新 `acceptRoutes` / `exitNode` / `exitNodeAllowLan`。
  - `POST /tailscale/ping`：通过 Tailscale LocalAPI 对指定 Peer 执行真实 Ping（返回直连/DERP 与毫秒延迟）。
  - `POST /config/rule-test`：输入 `{ "query": "claude.ai" }` 或 `{ "query": "192.168.1.12" }`，返回实时内核命中规则与出口链路。

---

## 4. 跨平台 UI 与交互规范（6 项菜单 1:1 对齐）

为保证用户在桌面端与移动端零学习成本无缝切换，所有平台统一采用 **6 项一级导航**（桌面端常驻左侧深色侧边栏 `#0F172A` + 翠绿高亮 `#10B981`；移动端采用顶部栏 `☰` + 左侧滑出深色抽屉）：

1. **`总览 & 状态` (`home`)**
   - 醒目连接状态 Hero 卡片（大号连接/断开按钮 + 运行时长 + 模式切换 + 下行/上行/连接数/主延迟 4 项指标）。
   - **连接成功后自动触发一次出口节点延迟测速**，立即展示各关键策略组（AI 组、主代理组、Tailscale）的当前落地节点与实时 `ms` 延迟。
   - **各节点实时流量统计**：按出口节点聚合上下行流量与活跃连接数；桌面端悬浮连接标签弹出连接列表，移动端支持**整行点击展开且同时展开多个节点**，展示目标域名:端口、命中规则、链路与流量（短连接关闭后保留最近连接记录）。
   - 未登录 Tailscale 时在首页顶部展示认证卡片，提供 **「🌐 浏览器打开」**（主按钮）与 **「复制链接」**（次按钮）。
2. **`代理策略组` (`proxies`)**
   - 不再重复放置模式切换条（模式切换统一归口总览页）。
   - 横向滚动策略组标签 + 节点搜索 + **实时规则命中测试卡** + 一键「本组测速 / 全组测速」。
3. **`Tailscale 组网` (`tailscale`)**
   - 顶部紧凑状态卡（含浏览器一键授权登录、登出切换账号）。
   - **高频区置顶**：设备列表（在线优先排序、直连/DERP 标签、单节点 Ping + **一键全部 Ping**）、已发现子网路由与 SplitDNS 列表。
   - **低频区折叠**：本机 Hostname / Control URL / AuthKey / Accept Routes / Exit Node 等高级托管设置默认折叠。
4. **`自建与分流覆写` (`overlay`)**
   - 极简 2 步完成 AI 严格自建保护：第 1 步一键勾选 AI 厂商预设（Claude / Gemini+Antigravity / OpenAI / Cursor / Grok / 其他 AI）；第 2 步粘贴 `vless://` 等节点链接或 YAML；默认开启 Fail-Closed 不可达直接断开。
   - 高级自定义项（补充规则、额外域名、直连保护）默认折叠；底部保留跨平台 JSON 备份与扫码同步入口。
5. **`订阅与配置` (`profiles`)**
   - 顶部突出 **「📷 扫码同步电脑配置」**（移动端）或 **「📱 扫码同步到手机」**（桌面端）。
   - **配置列表最多只展示 2 张卡**：`当前生效配置`（右上角提供一键 **「启动 / 重启」** 按钮，点击直达总览页并自动建连）+ 可选的 `待生效 · 新导入` 卡片；其余旧配置与不可变历史版本快照默认折叠；提供带二次确认的 **「清空配置」**。
   - **剪贴板导入规范**：点击粘贴必须先弹出可编辑预览框并自动运行 **Mihomo 内核语法校验**，校验通过才允许保存为新版本或新配置，严禁盲目落盘刷版本。
   - 子页包含：`配置列表`、`编辑校验`（含 Diff 对比与内核报错行号）、`流量规则`（可视化规则流向与增删排序）。
6. **`日志与诊断` (`diagnostics`)**
   - 分为 `连接`、`日志`、`规则`、`DNS` 四个视图，支持实时查看过滤后的 `mihomo-core.log` 与导出脱敏诊断信息。

---

## 5. 各目标平台开发指南

### 5.1 macOS 版本（`darwin/arm64` Apple Silicon & `darwin/amd64`）

macOS 版可直接复用 **`desktop/` 目录中 95% 以上的代码**（`config_builder.go`, `overlay.go`, `engine.go`, `server.go`, `store.go`, `tailscale_api.go`, `sync_qr.go`, `validate.go`, `web/index.html` 全部平台无关！）。

#### 需要新增/替换的 3 个文件（使用 `//go:build darwin`）
1. **`desktop/sysproxy_darwin.go`**：
   - 使用 `networksetup -listallnetworkservices` 找到活跃网卡（`Wi-Fi`、`USB 10/100/1000 LAN` 等），调用：
     - `networksetup -setwebproxy <service> 127.0.0.1 <port>`
     - `networksetup -setsecurewebproxy <service> 127.0.0.1 <port>`
     - `networksetup -setsocksfirewallproxy <service> 127.0.0.1 <port>`
     - `networksetup -setproxybypassdomains <service> ...`
   - 退出/停止时用 `-setwebproxystate <service> off` 等还原（并注册 `SIGTERM`/`SIGINT` 兜底清理）。
2. **`desktop/elevate_darwin.go`**：
   - 检测 `os.Geteuid() == 0` 判断是否已获 root 权限（`utun` + `auto-route` 需要 root）。
   - 非 root 时可通过 `osascript -e 'do shell script "..." with administrator privileges'` 提权重启，或打包为 `.app` + `SMAppService` 后台 Helper Daemon 实现无密码持久提权。
3. **`desktop/tray_darwin.go`**：
   - 使用 `fyne.io/systray`（或轻量 CGO `NSStatusBar`）实现顶部菜单栏图标、连接/断开、模式切换、打开 Web 控制台 (`open http://127.0.0.1:9091`)、退出清理。
   - 注意 macOS AppKit 要求菜单栏事件循环运行在主 goroutine (`runtime.LockOSThread()`)。

#### macOS 专属注意事项
- **TUN 配置**：`desktop/config_builder.go` 中 `device` 在 macOS 上必须留空或使用 `utun`（macOS 内核仅接受 `utun[0-9]*` 名称，不可写死 `ClashHarmony`！）。
- **数据目录**：`os.UserConfigDir()` 自动指向 `~/Library/Application Support/ClashHarmony`（与 Windows `%APPDATA%\ClashHarmony` 对等）。
- **DNS 恢复**：开启 `tun.auto-route: true` 时 macOS 会修改系统 DNS，务必确保正常退出与崩溃重启时调用 `executor.Shutdown()` 还原网络服务 DNS。
- **构建命令**：
  ```bash
  cd desktop
  GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 go build -tags with_gvisor -trimpath -ldflags "-s -w" -o dist/clash-harmony-darwin-arm64 .
  ```

---

### 5.2 Android 版本（`android/arm64-v8a`，Kotlin + Jetpack Compose）

Android 的系统 VPN 模型（`android.net.VpnService` 颁发 `tunFd` + 排除自身包名）与 HarmonyOS `VpnExtensionAbility` **架构几乎 1:1 同构**，可直接复用整个 `go_bridge/`！

#### 1. 原生 Go 核心编译 (`go_bridge/` -> `libmihomo_android.so`)
- 使用 Android NDK (`aarch64-linux-android24-clang`) 交叉编译：
  ```bash
  GOOS=android GOARCH=arm64 CGO_ENABLED=1 \
    CC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android24-clang" \
    go build -buildmode=c-shared -tags with_gvisor -trimpath -ldflags "-s -w" \
    -o android/app/src/main/jniLibs/arm64-v8a/libmihomo_android.so ./go_bridge
  ```
- **核心适配点**：
  - Android 上 `third_party/mihomo/listener/sing_tun/server_notwindows.go` 支持标准 `tunFd`；如遇部分国产 ROM 上 `fdbased` 兼容异常，可同样启用 `tun_rw_gvisor.go`（放宽其 build tag 包含 `android`）。
  - `go_bridge/bridge.go` 的 `init()` 中 `net.DefaultResolver.PreferGo = true` 与 `netns.SetEnabled(false)` 在 Android 同样必需（Android 应用无权限设置 Linux `SO_MARK` / `/etc/resolv.conf` 缺失）。
  - JNI 包装层启动 `MihomoStart(configPath, tunFd)` 时同样建议放到独立工作线程（>= 8 MB 栈）防止 ART 主线程栈溢出或 ANR。

#### 2. Android `VpnService` 实现要点
- `Builder` 配置：
  ```kotlin
  val builder = Builder()
      .setSession("Clash Harmony")
      .setMtu(1500)
      .addAddress("198.18.0.1", 16)
      .addDnsServer("198.18.0.2")
      .addRoute("0.0.0.0", 0)
      .addDisallowedApplication(packageName) // 关键：本应用自身直连防回环！
  ```
- `val pfd = builder.establish()` 获取 `tunFd = pfd.detachFd()`（或由 Go `unix.Dup(pfd.fd)` 复制后保持 `pfd` 生命周期），切记在停止时先 `MihomoStop()` 再关闭 `ParcelFileDescriptor`。
- 必须以 **Foreground Service**（`foregroundServiceType="specialUse"` 或 `"dataSync"`，Android 14+ 需在 `AndroidManifest.xml` 声明权限）运行防系统杀后台，并监听 `ConnectivityManager.NetworkCallback` 在 Wi-Fi ↔ 5G 切换时通知核心。

#### 3. Android UI 与系统能力对接
- **导航**：Jetpack Compose `ModalNavigationDrawer`，完全对齐 6 项深色抽屉菜单。
- **扫码同步**：使用 `CameraX` + `ML Kit Barcode Scanning`（或 `ZXing`）扫描电脑端 `clashharmony://sync?url=...`。
- **Tailscale 认证**：使用 `CustomTabsIntent` 或 `Intent(Intent.ACTION_VIEW, Uri.parse(authUrl))` 拉起系统浏览器完成 OAuth/Passkey 登录（**禁止用 WebView**）。
- **剪贴板导入**：Android 10+ 仅允许前台获得焦点的 Activity 读取 `ClipboardManager`，点击粘贴后弹出预览+校验弹窗即可稳定读取。
- **内置 `geoip.metadb`**：放入 `app/src/main/assets/geoip.metadb`，启动前按精确字节长度核验并释放至 `${filesDir}/runtime/geoip.metadb`。

---

### 5.3 Linux 桌面版（`linux/amd64` & `linux/arm64`）

直接复用 `desktop/`，仅需补充 2 个文件：
1. **`desktop/sysproxy_linux.go`**：检测桌面环境（GNOME 调用 `gsettings set org.gnome.system.proxy ...`；KDE 调用 `kwriteconfig5/6`），无桌面环境时仅依赖 TUN + `127.0.0.1:7890`。
2. **`desktop/elevate_linux.go`**：推荐文档指导用户一次性赋权 `sudo setcap cap_net_admin,cap_net_bind_service+eip ./clash-harmony`，无需每次以 root 运行；也可通过 `pkexec` 提权。
3. **构建命令**：
   ```bash
   cd desktop
   GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -tags with_gvisor -trimpath -ldflags "-s -w" -o dist/clash-harmony-linux-amd64 .
   ```

---

### 5.4 iOS 版本（`ios/arm64`，SwiftUI + `NEPacketTunnelProvider`）

iOS 架构与 Android/HarmonyOS 类似，但存在 **1 条核心生死红线**：
- **Network Extension 内存硬限制 = 50 MB**（超出即被系统 `jetsam` 秒杀）！
  - 必须为 Go 核心设置 `debug.SetMemoryLimit(30 << 20)` 与 `debug.SetGCPercent(20)`；
  - `geodata-loader: memconservative`，尽量精简规则集并避免加载超大 GeoSite；
  - 主 App 与 `PacketTunnelExtension` 通过 **App Groups** 共享目录交换 `runtime/` 文件与 `tailscale-status.json`；
  - Go 代码通过 `gomobile bind -target=ios` 编译为 `MihomoBridge.xcframework`；
  - Tailscale 认证通过 `ASWebAuthenticationSession` 或 `UIApplication.shared.open(url)` 拉起 Safari。

---

## 6. 全平台必避的 12 条血泪踩坑红线

以下每一条都来自 HarmonyOS 与 Windows 真机实战排障，开发新平台时请逐条对照自检：

1. **禁止给 TUN 绑定 `.0` 网络地址**：任何来自订阅的 `fake-ip-range: 198.18.0.0/15` 都必须清洗为 `198.18.0.1/15`，且内核 `parseTun()` 必须兜底修正 `.0` → `.1`。
2. **核心重启时 TUN 必须同步重置或原地热重载**：保留 `listener.go` 的 `Cleanup()`/`ReCreateTun()` 修复；后台自动发现新 SplitDNS 或 Subnet Routes 时，优先走 **`HotReloadRules()` 原地 `hub.ApplyConfig`**，不要拆建 TUN 网卡，避免打断正在运行的 CLI/SSH/AI 长连接。
3. **自动注入 Tailscale 子网路由必须排除本机物理局域网**：必须枚举本机活跃物理网卡网段（跳过虚拟/TUN/Loopback/Link-Local），过滤掉与本地 LAN 重叠的 Tailscale 广播网段（如本机 Wi-Fi 为 `10.10.1.0/24` 时必须跳过 `10.10.1.0/24`，并始终跳过 `0.0.0.0/0` 与 `::/0`）。
4. **Tailscale 规则必须置于订阅 `DIRECT` 规则之前**：`100.64.0.0/10`、`fd7a:115c:a1e0::/48`、SplitDNS 域名以及所有非本地子网路由（如 `192.168.1.0/24`）必须插在 `rules:` 最顶部，高于机场订阅自带的 `IP-CIDR,192.168.0.0/16,DIRECT` 与 `GEOIP,CN,DIRECT`。
5. **清洗订阅中的回环 DNS 冲突**：剥离 `dns.proxy-server-nameserver` 中的 `127.0.0.1` / `localhost` 条目，避免与其他代理软件残留的本地 DNS 端口冲突导致 Tailscale 解析出 Fake-IP。
6. **自动开启 `sniffer:`（HTTP / TLS / QUIC）**：防止只按 IP 建立连接的客户端绕过域名分流规则（尤其是 AI 严格自建规则）。
7. **内置完整版 `geoip.metadb` 并按字节长度严格校验**：切勿只检查 `size > 10KB`；损坏/截断的 `geoip.metadb` 会导致 Mihomo 冷启动删除文件并尝试无代理下载 GitHub 引发超时。
8. **Tailscale 交互认证一律拉起系统浏览器**：不要在内置 WebView 中打开 Tailscale 登录页（Google/Apple/Passkey 会直接拦截 WebView）。
9. **跨设备同步严禁复制设备身份与凭据**：扫码/JSON 同步只能平移覆写规则、订阅和 Tailscale 路由策略，绝对不可覆盖接收设备的 `hostname`、`authKey`、`tailscaled.state` 与 `exitNode`。
10. **剪贴板导入必须先预览 + 内核语法校验再落盘**：防止误触按钮把无关剪贴板文本写成坏配置或刷出一堆重复版本。
11. **Fail-Closed AI 规则不可妥协**：启用 AI 严格保护后，`🛡️ AI严格自建` 策略组内只能出现自建节点（无自建节点时只能为 `REJECT`），绝不允许自动回退到商业机场或直连。
12. **安全与仓库红线**：严禁将证书（`*.p12`/`*.p7b`/`*.cer`/`*.jks`/`*.keystore`）、密码文件、个人订阅链接/UUID、以及编译产物（`*.so`/`*.hap`/`*.app`/`*.exe`/`*.dmg`/`*.apk`）提交至 Git。

---

## 7. 新平台交付验收清单（Definition of Done）

AI 在交付任何新平台版本前，须逐项通过以下测试：

- [ ] **单元测试**：配置融合（含 4 空格 YAML、Fail-Closed AI、子网路由置顶、本地 LAN 过滤、`.0` `fake-ip-range` 清洗、二维码同步不含设备凭证）全部通过。
- [ ] **双链路并发验证**：单 VPN 开启后，同时验证：
  1. AI 域名（如 `claude.ai`、`antigravity.google.com`）严格命中 `🛡️ AI严格自建`；断开自建节点后直接失败不漏流；
  2. 普通境外域名命中商业订阅代理，国内域名直连；
  3. Tailscale 交互式登录通过系统浏览器完成并自动上线获得 `100.x.x.x`；
  4. `*.ts.net`、SplitDNS 内网域名与子网路由 IP（如 `ping` + TCP 访问远程内网主机）全部畅通。
- [ ] **二维码双向同步**：桌面端生成二维码，移动端扫码 10 秒内同步完成，且移动端保留自身 `hostname` 与 Tailscale 登录态。
- [ ] **热重载与稳定性**：自动发现新 SplitDNS / 子网路由原地热重载时，已有 TCP 长连接（如 AI CLI / SSH）不断流；Wi-Fi ↔ 移动网络切换后自动恢复。
- [ ] **安全扫描**：提交前 `git diff` 零密钥/零证书/零个人节点/零大二进制产物。
