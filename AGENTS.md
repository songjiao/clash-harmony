# AGENTS.md — Clash Harmony (Mihomo + Tailscale for HarmonyOS) AI 接手指南

本文档面向直接在笔记本本地接手开发与 **USB HDC (`hdc`，常口语称 hdb)** 真机调试的 AI 编程助手与开发者，包含项目架构、自定义改动清单、工具链搭建、调试命令、当前验证状态及历史踩坑红线。

---

## 1. 项目目标与整体架构

由于 HarmonyOS 同一时间只能激活一个系统级 VPN 实例，单独运行系统版 Tailscale 会导致无法同时开启 Mihomo（Clash Meta）分流代理。本仓库将 **patched Tailscale 作为 Mihomo 的原生 `type: tailscale` Outbound** 整合进同一个 HarmonyOS 7 (`API 23`, `arm64-v8a`) VPN 客户端，只需启动一个系统 VPN 即可同时完成：

- 公网分流 / 代理（VLESS / Trojan / 规则 / `fake-ip`）
- Tailscale 组网流量（`*.ts.net`、`100.64.0.0/10`、`fd7a:115c:a1e0::/48`、Subnet Router 子网路由与 `tailscale://Tailscale` MagicDNS）

### 运行标识

- **Bundle Name**: `com.sjfarmltd.tailscale`（定义于 [app/AppScope/app.json5](app/AppScope/app.json5)）
- **UI 显示版本**: `v2.1.1`（定义于 [app/entry/src/main/ets/pages/Index.ets](app/entry/src/main/ets/pages/Index.ets) `APP_VERSION_NAME`）
- **应用元信息**: `versionCode: 200000001`, `versionName: "2.1.0"`
- **目标平台**: HarmonyOS 7 / API 23 (`6.1.0(23)`), `arm64-v8a`
- **RESTful Controller**: `127.0.0.1:9090`

### 进程与数据流架构

```text
[UI 进程: EntryAbility / Index.ets]
  ├─ 本地配置导入 (LocalFileImportService.ets) & 生成 runtime/current.yaml + 解压 geoip.metadb (RuntimeConfigService.ets)
  ├─ 轮询 127.0.0.1:9090 (MihomoControllerService.ets) & 读取 runtime/tailscale-status.json
  └─ 启动 VPN Extension + 后台保活连续任务 (VpnService.ets, VpnKeepAliveService.ets)
          │
          ▼
[VPN Extension 进程: ClashVpnExtensionAbility.ets]
  ├─ vpnExtension.createVpnConnection -> 获取系统 tunFd (198.18.0.1/16, DNS 198.18.0.2, blockedApplications: com.sjfarmltd.tailscale)
  ├─ protectProcessNet()
  └─ N-API (mihomo_adapter.cpp) -> 8 MB 独立 pthread worker -> dlopen(libmihomo_ohos.so) -> MihomoStart(configPath, tunFd)
          │
          ▼
[Go C-Shared 核心: go_bridge -> libmihomo_ohos.so]
  ├─ netns.SetEnabled(false) & net.DefaultResolver.PreferGo = true
  ├─ 过滤并写入 runtime/mihomo-core.log
  ├─ executor.ParseWithPath -> hub.ApplyConfig
  ├─ unix.Dup(tunFd) -> third_party/mihomo/listener/sing_tun (OpenHarmony 纯 Go os.File + gVisor 栈，绕过 gvisor/fdbased)
  └─ eagerStartTailscaleProxies(): 解包 autoCloseProxyAdapter -> 启动 *outbound.Tailscale
          │
          ├──▶ 直连 / VLESS / Trojan 出站
          └──▶ outbound.Tailscale (tsnet.Server + metacubex-tailscale + wireguard-go)
                   └─ 持续监听 IPN Bus -> 自动触发 StartLoginInteractive -> 原子写入 runtime/tailscale-status.json
```

---

## 2. 仓库结构与相对上游的完整改动清单

本仓库合并了四个上游组件（已移除嵌套 `.git` 以便单仓版本控制）：

| 目录 | 上游基线 | 说明 |
| :--- | :--- | :--- |
| `app/` | `andycaihello/clash-harmony@c0994b2` | ArkTS UI、VPN Extension、N-API C++ 适配层、Hvigor 工程 |
| `third_party/mihomo/` | `MetaCubeX/mihomo@0455d0d` (`Meta`, `v1.19.34`) | Mihomo 核心 + OpenHarmony TUN 适配与 Tailscale Outbound 增强 |
| `third_party/metacubex-tailscale/` | `metacubex/tailscale` (`v1.102.3` fork `ff0ecd8181`) | 移植 Tailscale OpenHarmony 补丁（`netmon`/`neterror`/`magicsock`/`tsnet`） |
| `third_party/metacubex-wireguard-go/` | `metacubex/tailscale-wireguard-go@e61ab99` | PR #116 收包循环恢复补丁 |
| `go_bridge/` | 自研 | 暴露给 `mihomo_adapter.cpp` 的 C-Shared Go 桥接库 |
| `patches/` | 提取自 Tailscale OpenHarmony 移植工程 | Go 1.27.3 `GOOS=openharmony` 工具链补丁 (`ohos-go-1.27.3.patch`) |
| `scripts/` | 自研 | 工具链构建、跨端编译 `libmihomo_ohos.so`、HAP 构建与签名脚本 |
| `config/` | 自研 | 脱敏示例 YAML 配置模板 |

### 所有关键文件改动明细

#### `go_bridge/`
- `go_bridge/main.go`: 导出 `MihomoStart`、`MihomoStartCore`、`MihomoStop`、`MihomoVersion`、`MihomoLastError`、`MihomoAdapterInfo`、`MihomoFreeCString`。
- `go_bridge/bridge.go`:
  - `init()`: `net.DefaultResolver.PreferGo = true` + `netns.SetEnabled(false)`（HarmonyOS 应用沙箱无权限使用 Linux `SO_MARK` / `SO_BINDTODEVICE`）。
  - `configureRuntimeConfig()`: `unix.Dup(tunFd)` 交给 `sing-tun`，强制开启 `gvisor` 栈 (`198.18.0.1/16`, `any:53` DNS 劫持)，关闭 `AutoRoute`/`AutoRedirect`/`AutoDetectInterface`。
  - `startLogSinkLocked()`: 每次连接截断重写 `<homeDir>/mihomo-core.log`，并严格按 `ev.LogLevel < log.Level()` 过滤 `[DEBUG]` 刷屏日志。
  - `eagerStartTailscaleProxies()`: 通过 `adapterUnwrapper` (`UnwrapAdapter() C.ProxyAdapter`) 解包 `autoCloseProxyAdapter` 后调用 `*outbound.Tailscale.Start()`。
- `go_bridge/bridge_test.go`: 含解析、配置、日志过滤、端口释放，以及实连 Tailscale 控制面的 `TestBridgeEagerStartTailscaleWritesStatusAndFiltersDebugLog`。

#### `third_party/mihomo/`
- `listener/sing_tun/server_notwindows.go`: 构建标签收窄为 `//go:build !windows && !openharmony`。
- `listener/sing_tun/server_openharmony.go` + `tun_rw_gvisor.go` + `tun_rw_gvisor_test.go`: 实现 `//go:build openharmony && with_gvisor` 下纯 Go `os.File` 驱动的 gVisor `GVisorTun`，绕过会触发 `Fstat`/`Getsockname`/`eventfd2`/`readv` 失败的 `gvisor/fdbased`。
- `adapter/outbound/base.go`: 为 `autoCloseProxyAdapter` 新增 `UnwrapAdapter() C.ProxyAdapter`。
- `adapter/outbound/tailscale.go`:
  - 新增导出 `Tailscale.Start() error` 与 `TailscaleStatus`（及 `StatusSnapshot()`）。
  - 每次 `start()`、`watchBackendState()`、`UserLogf`、关键诊断 `Logf`、`LookupHook`/`SystemDialer` 错误及 `Close()` 时，原子更新 `<HomeDir>/tailscale-status.json`。
  - 修复 `watchBackendState()` 原版会在首个非 `NoState` 状态立即退出的问题，改为随 `t.ctx` 持续监听 IPN Bus，并在 `NeedsLogin` 且无 `AuthURL` 时每 15 秒内保底触发 `lc.StartLoginInteractive`。

#### `third_party/metacubex-tailscale/`
- `net/netmon/hostroute_openharmony.go`, `hostroute_other.go`, `hostroute_test.go`, `interfaces_linux.go`, `state.go`: OpenHarmony 默认路由提示，过滤 `rmnet_ims*`、`ancormnet*`、`vpn-tun`。
- `net/neterror/neterror_bad_{unix,windows,other}.go`, `neterror_bad_unix_test.go`: `IsBadSocketError`。
- `health/health.go`, `health_receive_test.go`: `ReceiveFuncStats` 断连自愈指标。
- `wgengine/magicsock/magicsock.go`, `receive_recovery_test.go`: UDP 读错重试/重绑定自愈。
- `tsnet/tsnet.go`: 在 `s.Hostname != "" && s.Dir != ""` 时允许 `os.Executable()` 失败回退为 `"tsnet"`。

#### `third_party/metacubex-wireguard-go/`
- `device/receive.go`, `conn/conn.go`: 仅在 `errors.Is(err, net.ErrClosed)` 时退出收包循环。

#### `app/`
- `app/AppScope/app.json5`, `build-profile.json5`, `entry/build-profile.json5`, `hvigor/hvigor-config.json5`, `entry/src/main/module.json5`: 切换包名 `com.sjfarmltd.tailscale`、API 23、`arm64-v8a`、清空旧签名引用、声明 `dataTransfer` 后台连续任务与必要权限。
- `app/entry/src/main/resources/rawfile/geoip.metadb`: 内置 GeoIP 数据库（`1.7 MB`），避免真机冷启动下载超时。
- `app/entry/src/main/cpp/mihomo_adapter.cpp`: `MihomoStart` 与 `MihomoStartCore` 均通过 8 MB 栈 pthread worker 调用 Go 函数，并接管 Go runtime stderr 到 `go-runtime-stderr.log`；将 `dlopen` 后等待从 1000ms 降至 100ms。
- `app/entry/src/main/ets/services/LocalFileImportService.ets`: 修复 `DocumentViewPicker` 返回的 `file://` URI 无法直接 `fileIo.readText(uri)` 的问题，改为 `openSync(READ_ONLY)` + `copyFile` 到沙箱临时文件后读取。
- `app/entry/src/main/ets/services/RuntimeConfigService.ets`: 保留用户 `dns:`、`hosts:`、`ipv6`、`mode` 等字段（仅接管 controller 与 `tun:`），并在缺少时释放内置 `geoip.metadb`。
- `app/entry/src/main/ets/vpnextensionability/ClashVpnExtensionAbility.ets` & `VpnService.ets` & `VpnKeepAliveService.ets`: 注册 `onConnect` RPC stub 配合 `connectServiceExtensionAbility` + `backgroundTaskManager` `dataTransfer` 保活；VPN DNS `198.18.0.2`，`blockedApplications: ['com.sjfarmltd.tailscale']`，冲突时自动 `destroy` 后重试。
- `app/entry/src/main/ets/pages/Index.ets`: 延长启动等待阈值（`waitForVersion(30, 500)`、`waitForVpnTunReady(20, 500)`），新增 `TailscaleStatusCard` 展示 `tailscale-status.json` 状态、IP、错误、健康警告及一键复制认证 URL（位于首页状态卡下方与「诊断 -> 日志」顶部）。

---

## 3. 笔记本本地开发环境搭建（Linux / macOS）

### 3.1 必备依赖
1. **HarmonyOS Command Line Tools 6.1.0 (API 23)** 或 **DevEco Studio**
   - 默认路径约定为 `~/ohos-sdk-6.1.0.830/command-line-tools`，若放在其他路径（如 macOS DevEco Studio），请在 shell 或 `~/.harmony_env` 中设置：
     ```bash
     export OHOS_SDK_ROOT="/path/to/command-line-tools"
     export DEVECO_SDK_HOME="$OHOS_SDK_ROOT/sdk"
     export PATH="$OHOS_SDK_ROOT/bin:$DEVECO_SDK_HOME/default/openharmony/toolchains:$PATH"
     ```
2. **宿主 Go（建议 1.24+，推荐 1.27.x 源码引导）+ JDK（供 `hap-sign-tool.jar` 使用）+ `curl`/`git`**
3. **OpenHarmony 交叉编译 Go 1.27.3 工具链 (`ohos-go-1.27.3`)**
   - 直接运行本仓库自带的一键脚本：
     ```bash
     ./scripts/setup-ohos-go.sh
     ```
   - 脚本会自动下载 `go1.27.3.src.tar.gz`、校验 SHA-256、打上 `patches/ohos-go-1.27.3.patch` 并编译安装到 `$HOME/.ohos-go-build/ohos-go-1.27.3`（可通过 `OHOS_GO_ROOT` 自定义路径）。
   - 如果需要自定义 Go 缓存目录，也可导出 `GOCACHE` / `GOMODCACHE` / `GOPATH`。
4. **调试签名证书（严禁提交到 Git！）**
   - 将真机调试证书放在 `./certs/debug/`（已在 `.gitignore` 中忽略），包含 4 个文件：
     - `tailscale-debug.cer`
     - `tailscale-debug-profileDebug.p7b`
     - `tailscale-debug.p12`
     - `password.txt`（证书密码，切勿打印或提交）
   - 也可通过环境变量 `CERT_DIR=/path/to/certs/debug` 指定；若两者均未设置，[scripts/sign-debug.sh](scripts/sign-debug.sh) 会自动回退查找 `../certs/debug/`。

---

## 4. 常用构建、测试与 USB HDC 调试命令

### 4.1 宿主端 Go 单元测试
```bash
# go_bridge 单元测试 + 实连 Tailscale controlplane 验证生成 authUrl 与 tailscale-status.json
cd go_bridge && GOTOOLCHAIN=local go test -tags with_gvisor -count=1 -v .

# metacubex-tailscale OpenHarmony 补丁测试
cd third_party/metacubex-tailscale && GOTOOLCHAIN=local go test -count=1 ./net/netmon ./net/neterror ./health ./wgengine/magicsock

# mihomo OpenHarmony gVisor TUN 单测
cd third_party/mihomo && GOTOOLCHAIN=local go test -tags with_gvisor -count=1 ./listener/sing_tun
```

### 4.2 编译 `libmihomo_ohos.so` + ArkTS HAP + 签名
```bash
# 1. 编译 Go C-Shared (.so) 并调用 hvigorw 生成 entry-default-unsigned.hap
./scripts/build-mihomo-hap.sh

# 2. 使用本地调试证书签名生成 app/entry/build/default/outputs/default/entry-default-signed.hap
./scripts/sign-debug.sh
```
> 注意：`app/entry/src/main/cpp/prebuilt/arm64-v8a/libmihomo_ohos.so` (~97 MB) 与 `*.hap` (~75 MB) 默认不入 Git，新克隆仓库后必须先执行 `./scripts/build-mihomo-hap.sh` 才会生成；若跳过直接编译 CMake，CMake 会回退到 `fake_mihomo.c`！

### 4.3 USB HDC (`hdc`) 真机安装与日志调试
```bash
# 1. 确认 USB 设备连接（笔记本本地开启 USB 调试即可）
hdc list targets

# 2. 覆盖安装调试 HAP（若签名证书变化需先 hdc uninstall com.sjfarmltd.tailscale）
hdc install -r app/entry/build/default/outputs/default/entry-default-signed.hap

# 3. 启动主界面
hdc shell aa start -b com.sjfarmltd.tailscale -a EntryAbility

# 4. 实时查看应用与 VPN Extension / Native C++ 桥接日志
hdc hilog | grep -E "ClashMihomoAdapter|ClashVpnExtension|ClashHarmonyIndex|VpnKeepAlive"
```

#### 运行时诊断文件（App 沙箱 `${filesDir}/runtime/`）
应用会在真机沙箱 `files/runtime/`（或诊断日志页）记录以下运行时文件，排障时可优先核对：
- `tailscale-status.json`: Tailscale 当前实时状态、节点名、IP、`authUrl`、`health`、最近事件
- `mihomo-core.log`: 过滤了 `DEBUG` 刷屏的 Mihomo / Tailscale 核心日志
- `vpn-extension.log`: `ClashVpnExtensionAbility` `create`/`protectProcessNet`/`startTun` 记录
- `go-runtime-stderr.log`: Go runtime / panic / C-shared stderr 输出
- `current.yaml`: `RuntimeConfigService` 归一化后的实际生效配置
- `tailscale/tailscaled.state`: Tailscale 节点持久化密钥状态

> 如果真机开启了开发者 shell/沙箱读取权限（或可通过 `aa`/`bm` 排查），在 `hdc shell` 中定位沙箱或 `adb/hdc file recv` 导出上述文件；若 ROM 禁止 shell 直接访问 `/data/app/el2/.../com.sjfarmltd.tailscale/files/runtime/`，直接通过 App 内 **诊断 -> 日志** 或 `hdc hilog` 即可观察核心状态。

---

## 5. 当前进展与真机待验证清单 (Handoff Checklist)

### 已在真机实测确认的功能
- [x] 本地 YAML 文件导入（修复 `DocumentViewPicker` URI 读取问题）
- [x] 冷启动无网预置 `geoip.metadb`（避免首启下载失败导致的 controller 超时）
- [x] `127.0.0.1:9090` Controller 连接与策略组同步
- [x] HarmonyOS TUN 启动与 `enable=true fd>0 stack=gVisor` 成功建连（纯 Go `os.File` `GVisorTun` 已生效）

### 本次 (`v2.1.1`) 刚修复、已在主机单测通过、待通过 USB HDC 真机闭环验证的项目
- [ ] **Tailscale 交互式认证链路实测**：安装 `v2.1.1` 后导入用户配置（参考 [config/harmony-mihomo-tailscale.example.yaml](config/harmony-mihomo-tailscale.example.yaml)）并点击连接，确认首页与「诊断 -> 日志」出现 `Tailscale 状态` 卡片并显示 `待登录` + 可复制的 `https://login.tailscale.com/...` URL。
- [ ] **浏览器授权与节点上线**：复制 URL 在浏览器完成授权，确认状态自动转为 `已连接 (Running)` 并分配 `100.x.x.x` Tailscale IP，同时不需手动重启 VPN。
- [ ] **双链路并发连通性实测**：
  - Tailscale 节点域名 (`*.ts.net`, MagicDNS via `tailscale://Tailscale`)
  - Tailscale Subnet Router (`accept-routes: true` 访问 `192.168.1.0/24` 内网设备)
  - 代理分流规则同时访问 Google/Claude 等境外站点与国内直连站点。
- [ ] **Wi-Fi ↔ 5G 网络切换与后台保活**：通过 `hdc hilog` 观察切网后 `magicsock` 收包自愈、`VpnKeepAliveService` 后台连续任务稳定性与息屏断流情况。

---

## 6. 踩坑记录与开发红线 (Pitfalls & Guardrails)

1. **禁止在 HarmonyOS 使用 `gvisor/fdbased` 封装 TUN FD**：HarmonyOS VPN FD 在 `sing-tun` 的 Linux `fdbased` 中触发 `Fstat`/`Getsockname`/`eventfd2`/`readv` 报错导致 `enable=false`。必须保留 `listener/sing_tun/server_openharmony.go` + `tun_rw_gvisor.go`。
2. **`autoCloseProxyAdapter` 不可隐式透传 `Start()`**：`adapter/parser.go` 会包裹所有出站为 `*outbound.autoCloseProxyAdapter`，务必保留 `UnwrapAdapter()` 与 `bridge.go` 解包逻辑。
3. **Go C-Shared 栈与 `netns`**：
   - Go 核心启动必须在 >= 8 MB 栈的 `pthread_create` worker 中执行（见 `mihomo_adapter.cpp` `CallRealStartOnWorker`），否则 ArkTS 主线程小栈会直接崩溃。
   - OpenHarmony 沙箱下必须保持 `netns.SetEnabled(false)` 与 `net.DefaultResolver.PreferGo = true`。
4. **HarmonyOS Picker URI 与 `tsnet` `os.Executable()`**：
   - `DocumentViewPicker` 返回的 URI 必须通过 `fileIo.openSync(uri, READ_ONLY)` + `fileIo.copyFile()` 读取。
   - `tsnet.Server.start()` 已放行 `s.Hostname != "" && s.Dir != ""` 时的 `os.Executable()` 失败，不可回退该改动。
5. **ArkTS 严格模式规范**：禁止使用 `any`/`unknown`、对象展开运算符或无类型索引访问；`@Builder` 方法内避免局部变量声明，状态辅助逻辑应抽取到组件私有方法中，每次修改必须以 `hvigorw` 0 错误通过为准。
6. **安全与仓库红线**：
   - **严禁提交或打印** `certs/`、`password.txt`、`*.p12`/`*.p7b`/`*.cer`、个人真实配置（含订阅 token、UUID、节点域名、tailnet 后缀）。
   - **严禁提交** `libmihomo_ohos.so`（~97 MB）、`*.hap`（~75 MB）或 `.hvigor`/IDE 缓存。
   - 修改涉及原生层后，记得**重新跑一遍 `./scripts/build-mihomo-hap.sh && ./scripts/sign-debug.sh`** 再安装调试，避免安装旧 `.so` 缓存。
