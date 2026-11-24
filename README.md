# Clash Harmony (Mihomo + Tailscale for HarmonyOS)

在 HarmonyOS 7 (`API 23`, `arm64-v8a`) 单 VPN 限制下，将 **patched Tailscale**（含 OpenHarmony 自愈补丁）作为 **Mihomo (`Meta v1.19.34`)** 原生出站整合为同一个系统 VPN 客户端，实现公网规则分流、Fake-IP DNS 与 Tailscale 内网/子网路由同时在线。

> **AI 接手 / 本地笔记本开发必读**：架构细节、相对上游的全部修改清单、USB `hdc` 真机调试流程、已知踩坑与待验证清单均整理在 **[AGENTS.md](AGENTS.md)**。

## 主要特性

- **单 VPN 并存**：Mihomo 核心内置 `type: tailscale` 出站，规则路由可同时分流公网代理（VLESS/Trojan 等）与 Tailscale 流量（`*.ts.net`、`100.64.0.0/10`、Subnet Router 内网段）。
- **OpenHarmony 专属适配**：
  - 纯 Go `os.File` gVisor TUN（`third_party/mihomo/listener/sing_tun/tun_rw_gvisor.go`），兼容 HarmonyOS VPN FD。
  - 集成 `metacubex/tailscale` & `wireguard-go` OpenHarmony 断网重连、`netmon` 接口过滤与沙箱 `netns` 禁用补丁。
  - 应用内 `Tailscale 状态` 卡片与「诊断 -> 日志」直接展示 `tailscale-status.json` 状态、IP 与一键复制交互式登录链接。
- **开箱体验优化**：内置 `geoip.metadb` 避免冷启动拉取超时；修复本地 YAML 导入与后台 `dataTransfer` 连续保活。

## 快速开始（笔记本 Linux / macOS）

### 1. 环境准备

1. 安装 **HarmonyOS Command Line Tools 6.1.0 (API 23)**（或 DevEco Studio），并配置环境变量：
   ```bash
   export OHOS_SDK_ROOT="${OHOS_SDK_ROOT:-$HOME/ohos-sdk-6.1.0.830/command-line-tools}"
   export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$OHOS_SDK_ROOT/sdk}"
   export PATH="$OHOS_SDK_ROOT/bin:$DEVECO_SDK_HOME/default/openharmony/toolchains:$PATH"
   ```
2. 构建 OpenHarmony Go 1.27.3 交叉编译器（需宿主机已安装 Go >= 1.24）：
   ```bash
   ./scripts/setup-ohos-go.sh
   ```
3. 准备个人真机调试签名材料至 `./certs/debug/`（已在 `.gitignore` 中忽略，勿提交）：
   - `tailscale-debug.cer`
   - `tailscale-debug-profileDebug.p7b`
   - `tailscale-debug.p12`
   - `password.txt`

### 2. 编译、签名与 USB `hdc` 安装

```bash
# 运行 Go 单元测试
cd go_bridge && GOTOOLCHAIN=local go test -tags with_gvisor -count=1 -v .
cd ../

# 编译 libmihomo_ohos.so 并打包 Debug HAP
./scripts/build-mihomo-hap.sh

# 本地调试签名
./scripts/sign-debug.sh

# USB 连接手机安装并查看日志
hdc list targets
hdc install -r app/entry/build/default/outputs/default/entry-default-signed.hap
hdc hilog | grep -E "ClashMihomoAdapter|ClashVpnExtension|ClashHarmonyIndex|VpnKeepAlive"
```

### 3. 配置参考

请参考脱敏模板 [config/harmony-mihomo-tailscale.example.yaml](config/harmony-mihomo-tailscale.example.yaml) 生成你自己的配置后在 App 内通过 **配置 -> 本地导入** 导入使用。

## 开源协议与致谢

- 上游应用框架参考 [andycaihello/clash-harmony](https://github.com/andycaihello/clash-harmony)
- 代理内核基于 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo)
- Tailscale 移植参考 [metacubex/tailscale](https://github.com/metacubex/tailscale) 与 OpenHarmony 社区适配补丁
