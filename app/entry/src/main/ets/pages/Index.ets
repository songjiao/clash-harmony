import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { scanBarcode, scanCore } from '@kit.ScanKit';
import { ClashConfigParserService, ParsedConfigSummary, ParsedProxyNode } from '../services/ClashConfigParserService';
import { ClipboardImportResult, ClipboardImportService, ClipboardReadResult } from '../services/ClipboardImportService';
import { CoreBridgeService, CoreBridgeState, ConfigValidationResult } from '../services/CoreBridgeService';
import { CoreService, CoreSummary } from '../services/CoreService';
import { ConvertedSubscription, GenericSubscriptionConverterService } from '../services/GenericSubscriptionConverterService';
import { ClashProfile, createEmptyProfileState, createRemoteProfile, formatProfileUpdatedAt, ProfileState } from '../models/Profile';
import {
  ConnectionInfo as ControllerConnectionInfo,
  ControllerStatus,
  ControllerTextResult,
  MihomoControllerService,
  ProxyGroupInfo
} from '../services/MihomoControllerService';
import { FileImportResult, LocalFileImportService } from '../services/LocalFileImportService';
import {
  AiProviderPreset,
  BackupImportResult,
  createDefaultOverlayConfig,
  CustomOverlayConfig,
  DEFAULT_AI_GROUP_NAME,
  getAllAiProviderPresets,
  OverlayService,
  ParsedCustomProxies
} from '../services/OverlayService';
import { ProfileStore } from '../services/ProfileStore';
import {
  ProfileVersionEntry,
  ProfileVersionManifest,
  ProfileVersionService,
  VersionCommitResult
} from '../services/ProfileVersionService';
import { RuntimeConfigResult, RuntimeConfigService } from '../services/RuntimeConfigService';
import { SubscriptionService, SubscriptionUpdateResult } from '../services/SubscriptionService';
import {
  createEmptyTailscaleControlStatus,
  LiveRuleTestResult,
  TailscaleActionResult,
  TailscaleAdvertisedRouteItem,
  TailscaleControlService,
  TailscaleControlStatus,
  TailscaleDnsQueryResult,
  TailscalePeerItem,
  TailscalePingResult,
  TailscaleSplitDnsItem
} from '../services/TailscaleControlService';
import {
  createDefaultTailscalePrefs,
  TailscaleNativePrefs,
  TailscalePrefsService
} from '../services/TailscalePrefsService';
import {
  FlowBucket,
  ParsedRuleItem,
  RouteSimulationResult,
  TrafficAnalysis,
  TrafficRuleAnalyzerService
} from '../services/TrafficRuleAnalyzerService';
import { DiffLine, DiffSummary, YamlDiffService } from '../services/YamlDiffService';
import {
  ConnectionInfo as PollerConnectionInfo,
  TrafficPollerService,
  TrafficSnapshot
} from '../services/TrafficPollerService';
import { VpnService } from '../services/VpnService';
import { VpnKeepAliveService } from '../services/VpnKeepAliveService';
import { TcpDelayTestService } from '../services/TcpDelayTestService';

interface NavItem {
  key: string;
  label: string;
  shortLabel: string;
}

interface ProxyNode {
  name: string;
  meta: string;
  delay: string;
  selected?: boolean;
  status?: string;
  server?: string;
  port?: number;
}

interface ProxyDelayState {
  delay: string;
  status: string;
}

interface ProxyDelayUpdate {
  name: string;
  delay: string;
  status: string;
}

interface SpeedTestBlockedState {
  nodeDelay: string;
  nodeStatus: string;
  statusMessage: string;
  progress: string;
  summary: string;
}

interface RuntimeConnectionRow {
  id: string;
  target: string;
  chain: string;
  rule: string;
  upload: string;
  download: string;
}

interface RuntimeTunStatus {
  ready: boolean;
  message: string;
  raw: string;
  enabled: boolean;
  fileDescriptor: number;
  stack: string;
}

interface AppLogEntry {
  time: string;
  level: string;
  message: string;
}

interface TailscaleRuntimeStatus {
  name: string;
  hostname: string;
  backendState: string;
  authUrl: string;
  tailscaleIPs: string[];
  health: string[];
  lastError: string;
  recentLogs: string[];
  updatedAt: string;
}

interface HomeActiveNodeItem {
  group: string;
  finalNode: string;
  delay: string;
  status: string;
  isAi: boolean;
  isTs: boolean;
}

interface HomeNodeTrafficItem {
  key: string;
  node: string;
  group: string;
  active: number;
  downloadBytes: number;
  uploadBytes: number;
  percent: number;
}

interface HomeNodeConnDetail {
  target: string;
  rule: string;
  chain: string;
  download: string;
  upload: string;
}

interface ConnBytesRecord {
  download: number;
  upload: number;
}

const NAV_ITEMS: NavItem[] = [
  { key: 'home', label: '总览 & 状态', shortLabel: '●' },
  { key: 'proxies', label: '代理策略组', shortLabel: '⇄' },
  { key: 'tailscale', label: 'Tailscale 组网', shortLabel: '✦' },
  { key: 'overlay', label: '自建与分流覆写', shortLabel: '🛡' },
  { key: 'profiles', label: '订阅与配置', shortLabel: '≡' },
  { key: 'diagnostics', label: '日志与诊断', shortLabel: '▤' }
];
const LOG_DOMAIN: number = 0x0001;
const LOG_TAG: string = 'ClashHarmonyIndex';
const APP_VERSION_NAME: string = 'v2.4.6';
const APP_BUILD_UPDATED_AT: string = '2026-11-28 17:12';
const DELAY_TEST_TIMEOUT_MS: number = 4500;
const DELAY_TEST_URLS: string[] = [
  'https://cp.cloudflare.com/generate_204',
  'https://www.gstatic.com/generate_204',
  'http://connectivitycheck.platform.hicloud.com/generate_204'
];

const EMPTY_CORE_BRIDGE_STATE: CoreBridgeState = {
  running: false,
  tunFd: -1,
  nativeFd: -1,
  startCount: 0,
  stopCount: 0,
  controllerReady: false,
  controllerOnly: false,
  tunAttached: false,
  supportsControllerOnly: false,
  supportsTunAttach: false,
  realConnectionReady: false,
  configPath: '',
  coreMode: 'idle',
  adapterMode: 'unloaded',
  adapterKind: 'unknown',
  adapterInfo: '',
  adapterLoadError: '',
  adapterVersion: '',
  controllerVersion: '',
  version: '',
  lastError: '',
  packetsRead: 0,
  packetsWritten: 0,
  bytesRead: 0,
  bytesWritten: 0,
  readErrors: 0,
  writeErrors: 0,
  forwarderActive: false
};

@Entry
@Component
struct Index {
  @State private currentTab: string = 'home';
  @State private showSettings: boolean = false;
  @State private showNavDrawer: boolean = false;
  @State private profileState: ProfileState = createEmptyProfileState();
  @State private summary: CoreSummary = CoreService.createSummary(createEmptyProfileState(), false);
  @State private vpnActionText: string = '连接';
  @State private showImportPanel: boolean = false;
  @State private importUrl: string = '';
  @State private importName: string = '';
  @State private importUserAgent: string = '';
  @State private editingSubMetaUid: string = '';
  @State private editingSubMetaName: string = '';
  @State private editingSubMetaUrl: string = '';
  @State private editingSubMetaUserAgent: string = '';
  @State private statusMessage: string = '请先导入或启用一个配置';
  @State private runtimeConfigPath: string = '';
  @State private runtimeConfigInfo: string = '尚未生成运行配置';
  @State private proxyStatus: string = '当前配置尚未下载';
  @State private proxyNodes: ProxyNode[] = [];
  @State private proxySearchText: string = '';
  @State private proxyGroups: ProxyGroupInfo[] = [];
  @State private proxyGroupsSynced: boolean = false;
  @State private selectedProxyGroup: string = '';
  @State private pendingProxyGroup: string = '';
  @State private pendingProxyName: string = '';
  @State private isSpeedTesting: boolean = false;
  @State private speedTestProgress: string = '';
  @State private speedTestSummary: string = '';
  @State private diagSegment: string = '连接';
  @State private controllerStatus: ControllerStatus = {
    available: false,
    version: '',
    message: '尚未检查 controller',
    raw: ''
  };
  @State private coreBridgeState: CoreBridgeState = EMPTY_CORE_BRIDGE_STATE;
  @State private proxyMode: string = 'rule';
  @State private runtimeConnections: RuntimeConnectionRow[] = [];
  @State private rulesStatus: string = '尚未读取规则';
  @State private ruleLines: string[] = [];
  @State private dnsStatus: string = '尚未读取 DNS 配置';
  @State private dnsLines: string[] = [];
  @State private appLogs: AppLogEntry[] = [];
  @State private coreLogLines: string[] = [];
  @State private tailscaleAuthUrl: string = '';
  @State private tailscaleState: string = '';
  @State private tailscaleHostname: string = '';
  @State private tailscaleIps: string = '';
  @State private tailscaleError: string = '';
  @State private tailscaleHealth: string[] = [];
  @State private tailscaleRecentLogs: string[] = [];
  // Phase 1: Config version management, editor, kernel validator, diff
  @State private profileSubTab: string = 'list';
  @State private editingProfileUid: string = '';
  @State private editingProfileName: string = '';
  @State private editorBaseText: string = '';
  @State private editorDraftText: string = '';
  @State private editorCommitNote: string = '';
  @State private editorValidationChecked: boolean = false;
  @State private editorValidationOk: boolean = false;
  @State private editorValidationLine: number = 0;
  @State private editorValidationMessage: string = '';
  @State private editorValidationWarnings: string[] = [];
  @State private editorValidationStats: string = '';
  @State private showDiffPanel: boolean = false;
  @State private diffContextOnly: boolean = true;
  @State private diffTitle: string = '';
  @State private diffSummaryText: string = '';
  @State private diffLines: DiffLine[] = [];
  @State private versionHistory: ProfileVersionEntry[] = [];
  @State private activeVersionNumber: number = 0;
  @State private showVersionHistory: boolean = false;
  @State private isSavingDraft: boolean = false;
  @State private editorSaveBanner: string = '';
  @State private editorSaveBannerOk: boolean = true;
  // Phase 4: Self-hosted Overlay, Fail-Closed AI, Rule Test, Batch Ping & Cross-Platform Backup
  @State private overlayConfig: CustomOverlayConfig = createDefaultOverlayConfig();
  @State private overlayGroupNameDraft: string = DEFAULT_AI_GROUP_NAME;
  @State private overlayProxiesDraft: string = '';
  @State private overlayCustomRulesDraft: string = '';
  @State private overlayAiDomainsDraft: string = '';
  @State private overlayAiKeywordsDraft: string = '';
  @State private overlayDirectDomainsDraft: string = '';
  @State private overlayBanner: string = '';
  @State private overlayBannerOk: boolean = true;
  @State private isSavingOverlay: boolean = false;
  @State private showOverlayAdvanced: boolean = false;
  @State private isBatchPingingPeers: boolean = false;
  @State private batchPingProgress: string = '';
  @State private proxyRuleTestInput: string = 'claude.ai';
  @State private proxyRuleTestResult: string = '';
  @State private proxyRuleTestDetail: string = '';
  @State private proxyRuleTestOk: boolean = true;
  @State private proxyRuleTestIsReject: boolean = false;
  // Phase 5: PC-aligned Home Telemetry, Max-2-Card Profile List, QR Scan Sync & Clean Tailscale Priority
  @State private homeActiveNodes: HomeActiveNodeItem[] = [];
  @State private homePrimaryDelayText: string = '待测';
  @State private homeNodeTraffic: HomeNodeTrafficItem[] = [];
  @State private expandedTrafficNodeKeys: string[] = [];
  @State private homeTrafficConnsTick: number = 0;
  @State private isTestingActiveNodes: boolean = false;
  @State private pendingProfileUid: string = '';
  @State private showOtherProfiles: boolean = false;
  @State private showTsAdvancedSettings: boolean = false;
  @State private isQrSyncing: boolean = false;
  @State private qrSyncBanner: string = '';
  @State private qrSyncBannerOk: boolean = true;
  @State private updatingProfileUid: string = '';
  @State private showClearAllConfirm: boolean = false;
  @State private showClipboardPanel: boolean = false;
  @State private clipboardDraftName: string = '';
  @State private clipboardDraftText: string = '';
  @State private clipboardValidationChecked: boolean = false;
  @State private clipboardValidationOk: boolean = false;
  @State private clipboardValidationMessage: string = '';
  @State private clipboardValidationStats: string = '';
  @State private clipboardIsUrl: boolean = false;
  @State private isSavingClipboard: boolean = false;
  private homeConnSeenBytes: Record<string, ConnBytesRecord> = {};
  private homeNodeAccumMap: Record<string, HomeNodeTrafficItem> = {};
  private homeNodeLiveConnsMap: Record<string, HomeNodeConnDetail[]> = {};
  private homeNodeRecentConnsMap: Record<string, HomeNodeConnDetail[]> = {};
  // Phase 2: Embedded native Tailscale management
  @State private tsPrefs: TailscaleNativePrefs = createDefaultTailscalePrefs();
  @State private tsControl: TailscaleControlStatus = createEmptyTailscaleControlStatus();
  @State private tsHostnameDraft: string = 'harmony-phone';
  @State private tsControlUrlDraft: string = '';
  @State private tsAuthKeyDraft: string = '';
  @State private tsBusyMessage: string = '';
  @State private tsDnsTestQuery: string = '';
  @State private tsDnsTestResult: string = '';
  @State private tsSplitDnsNeedReload: boolean = false;
  @State private tsPingRefreshTick: number = 0;
  private tsPeerPingResults: Record<string, string> = {};
  // Phase 3: Visual traffic routing & simulator
  @State private trafficAnalysis: TrafficAnalysis = TrafficRuleAnalyzerService.analyze('');
  @State private simQuery: string = '';
  @State private simResult: RouteSimulationResult = TrafficRuleAnalyzerService.simulateRoute(
    TrafficRuleAnalyzerService.analyze(''), '', 'rule'
  );
  @State private ruleSearchText: string = '';
  @State private showAddRulePanel: boolean = false;
  @State private newRuleType: string = 'DOMAIN-SUFFIX';
  @State private newRulePayload: string = '';
  @State private newRuleTarget: string = 'Tailscale';
  @State private newRulePrepend: boolean = true;
  @State private liveConnected: boolean = false;
  @State private liveUptime: string = '未连接';
  @State private liveDownloadSpeed: string = '0 KB/s';
  @State private liveUploadSpeed: string = '0 KB/s';
  @State private liveConnections: number = 0;
  @State private liveProfileName: string = '未选择配置';
  @State private liveProxyName: string = '未连接';
  @State private liveRuntimeConfigState: string = '未准备';
  @State private liveRefreshToken: number = 0;
  @State private vpnTunnelActive: boolean = false;
  @State private homeLastDownloadTotal: number = 0;
  @State private homeLastUploadTotal: number = 0;
  @State private homeLastActiveDownloadTotal: number = 0;
  @State private homeLastActiveUploadTotal: number = 0;
  @State private homeLastPollAt: number = 0;
  @State private homeTrafficBaselineReady: boolean = false;
  private connectedAt: number = 0;
  private lastToggleAt: number = 0;
  private toggling: boolean = false;
  private runtimePollTick: number = 0;
  private homeRefreshIntervalId: number | undefined = undefined;
  private homeRefreshInFlight: boolean = false;
  private homeRefreshFailures: number = 0;
  private proxyHealthCheckedAt: number = 0;
  private proxyHealthOk: boolean = false;
  private proxyHealthDelay: number = 0;
  private proxyHealthNode: string = '';
  private proxyDelayCache: Record<string, ProxyDelayState> = {};

  aboutToAppear(): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Index aboutToAppear, loading profiles');
    this.loadProfiles();
    this.startHomeRefreshLoop();
  }

  aboutToDisappear(): void {
    TrafficPollerService.stop();
    this.stopHomeRefreshLoop();
  }

  private async loadProfiles(): Promise<void> {
    const context = getContext(this) as common.Context;
    const state: ProfileState = await ProfileStore.load(context);
    this.runtimeConfigPath = RuntimeConfigService.getRuntimeConfigPath(context);
    await this.loadTailscalePrefs();
    await this.loadOverlayConfig();
    this.applyProfileState(state);
    await this.refreshProxyNodes(state);
    if (state.currentUid.length > 0) {
      await this.loadProfileWorkspaceData(state.currentUid);
    }
    await this.resumeRuntimeIfControllerAvailable();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'Profiles loaded: %{public}d items, currentUid=%{public}s',
      state.items.length, state.currentUid);
  }

  private async toggleVpn(): Promise<void> {
    this.toggling = true;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn: start, state=%{public}s', this.summary.state);
    try {
      if (this.isRuntimeConnected()) {
        hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn: stopping');
        TrafficPollerService.stop();
        this.stopHomeRefreshLoop();
        this.runtimePollTick = 0;
        this.connectedAt = 0;
        this.vpnTunnelActive = false;
        this.resetHomeTrafficBaseline();
        this.clearProxyHealthState();
        this.clearTailscaleState();
        this.runtimeConnections = [];
        this.clearControllerProxyGroups();
        this.coreBridgeState = CoreBridgeService.markControllerReady(false, '');
        await VpnService.stop();
        await VpnKeepAliveService.stop(getContext(this) as common.UIAbilityContext);
        this.summary = CoreService.createSummary(this.profileState, false);
        this.vpnActionText = '连接';
        this.coreBridgeState = CoreBridgeService.getState();
        this.controllerStatus = { available: false, version: '', message: 'VPN 已停止', raw: '' };
        this.statusMessage = 'VPN 已停止';
        this.syncHomeRuntimeFields();
        this.recordLog('info', 'VPN 已停止，运行状态已清理');
        return;
      }

      if (this.profileState.currentUid.length === 0) {
        this.statusMessage = '请先在配置页导入并启用一个配置';
        this.currentTab = 'profiles';
        return;
      }

      const context = getContext(this) as common.Context;
      this.statusMessage = '正在准备运行配置...';
      const runtime: RuntimeConfigResult = await this.prepareRuntimeForConnection(context);
      if (!runtime.ok) {
        this.vpnTunnelActive = false;
        this.clearProxyHealthState();
        this.clearTailscaleState();
        this.summary = CoreService.createSummary(this.profileState, false);
        this.statusMessage = runtime.message;
        hilog.error(LOG_DOMAIN, LOG_TAG, 'toggleVpn: runtime failed: %{public}s', runtime.message);
        return;
      }

      this.runtimeConfigPath = runtime.configPath;
      this.runtimeConfigInfo = `${runtime.profileName} · ${runtime.size}`;
      const restoreGroup: string = this.pendingProxyGroup.length > 0 ? this.pendingProxyGroup : this.selectedProxyGroup;
      const selectedNode: string = this.pendingProxyName.length > 0 ? this.pendingProxyName : this.getSelectedProxyNodeName();
      const restoreNode: string = selectedNode.length > 0 ? selectedNode : this.pendingProxyName;
      this.statusMessage = '正在释放本地测速核心，准备启动 VPN...';
      this.coreBridgeState = CoreBridgeService.stopCore();
      this.controllerStatus = { available: false, version: '', message: '本地测速核心已停止', raw: '' };
      await this.waitForUiUpdate(500);
      this.statusMessage = '正在启动 VPN...';

      hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn: calling VpnService.start');
      const started: boolean = await VpnService.start(runtime.configPath);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn: VpnService.start returned %{public}s', started ? 'true' : 'false');

      if (!started) {
        this.vpnTunnelActive = false;
        this.clearProxyHealthState();
        this.clearTailscaleState();
        this.summary = CoreService.createSummary(this.profileState, false);
        this.statusMessage = 'VPN 启动失败：模拟器可能不支持 VPN Extension，请使用真机';
        this.recordLog('warn', this.statusMessage);
        return;
      }

      this.statusMessage = 'VPN 已启动，等待核心...';
      this.coreBridgeState = CoreBridgeService.getState();
      hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn: waiting for controller');
      const controllerReady: ControllerStatus = await MihomoControllerService.waitForVersion(30, 500);
      this.controllerStatus = controllerReady;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn: controller ready=%{public}s', controllerReady.available ? 'true' : 'false');

      if (!controllerReady.available) {
        await this.refreshCoreLogs();
        const extHint: string = await this.readLastDiagnosticLine();
        TrafficPollerService.stop();
        this.stopHomeRefreshLoop();
        this.connectedAt = 0;
        this.vpnTunnelActive = false;
        this.resetHomeTrafficBaseline();
        this.clearProxyHealthState();
        this.clearTailscaleState();
        this.clearControllerProxyGroups();
        this.coreBridgeState = CoreBridgeService.markControllerReady(false, '');
        await VpnService.stop();
        await VpnKeepAliveService.stop(getContext(this) as common.UIAbilityContext);
        this.summary = CoreService.createSummary(this.profileState, false);
        this.vpnActionText = '连接';
        this.coreBridgeState = CoreBridgeService.getState();
        this.statusMessage = extHint.length > 0 ? `核心未响应 (${extHint})` : `核心未响应：${controllerReady.message}`;
        this.recordLog('warn', this.statusMessage);
        return;
      }

      const tunReady: RuntimeTunStatus = await this.waitForVpnTunReady(20, 500);
      if (!tunReady.ready) {
        await this.refreshCoreLogs();
        const extHint: string = await this.readLastDiagnosticLine();
        TrafficPollerService.stop();
        this.stopHomeRefreshLoop();
        this.connectedAt = 0;
        this.vpnTunnelActive = false;
        this.resetHomeTrafficBaseline();
        this.clearProxyHealthState();
        this.clearTailscaleState();
        this.clearControllerProxyGroups();
        this.coreBridgeState = CoreBridgeService.markControllerReady(false, '');
        await VpnService.stop();
        await VpnKeepAliveService.stop(getContext(this) as common.UIAbilityContext);
        this.summary = CoreService.createSummary(this.profileState, false);
        this.vpnActionText = '连接';
        this.coreBridgeState = CoreBridgeService.getState();
        this.statusMessage = extHint.length > 0 ? `${tunReady.message} (${extHint})` : tunReady.message;
        this.recordLog('warn', this.statusMessage);
        return;
      }

      this.coreBridgeState = CoreBridgeService.markControllerReady(true, controllerReady.version);
      this.vpnTunnelActive = true;
      await VpnKeepAliveService.start(context as common.UIAbilityContext);
      await MihomoControllerService.setMode(this.normalizeProxyMode(this.proxyMode));
      this.summary = CoreService.createSummary(this.profileState, true);
      this.vpnActionText = '断开';
      this.statusMessage = `已连接 · ${controllerReady.version}`;
      this.connectedAt = Date.now();
      this.syncHomeRuntimeFields();
      this.startRuntimePolling();
      await this.refreshControllerProxies();
      await this.restoreProxySelection(restoreGroup, restoreNode);
      await this.refreshConnections();
      await this.verifySelectedProxyAfterConnection(controllerReady.version);
      await this.refreshCoreLogs();
      this.syncHomeRuntimeFields();
      this.recordLog('info', `VPN 已连接，controller=${controllerReady.version}`);
      hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn: connected');
      // Auto-trigger active exit nodes latency test right after connect so delays show immediately on Home
      this.testHomeActiveNodesDelay();
    } catch (err) {
      TrafficPollerService.stop();
      this.stopHomeRefreshLoop();
      hilog.error(LOG_DOMAIN, LOG_TAG, 'toggleVpn: exception=%{public}s', JSON.stringify(err));
      this.statusMessage = '连接异常，请查看诊断页';
      this.vpnTunnelActive = false;
      this.resetHomeTrafficBaseline();
      this.clearProxyHealthState();
      this.clearTailscaleState();
      this.summary = CoreService.createSummary(this.profileState, false);
      this.clearControllerProxyGroups();
      this.syncHomeRuntimeFields();
      this.recordLog('warn', this.statusMessage);
    } finally {
      this.toggling = false;
    }
  }

  private requestToggleVpn(): void {
    if (this.toggling) {
      hilog.info(LOG_DOMAIN, LOG_TAG, 'toggleVpn skipped: already toggling');
      return;
    }
    const now: number = Date.now();
    if (now - this.lastToggleAt < 1500) {
      return;
    }
    this.lastToggleAt = now;
    this.toggleVpn();
  }

  private async prepareRuntimeForConnection(context: common.Context): Promise<RuntimeConfigResult> {
    let targetState: ProfileState = this.profileState;
    const current: ClashProfile | undefined = CoreService.getCurrentProfile(targetState);
    if (!current) {
      this.currentTab = 'profiles';
      return this.createRuntimeFailure('请先在配置页导入并启用一个配置');
    }

    if (current.type === 'remote' && current.filePath.length === 0) {
      this.statusMessage = '首次连接正在下载订阅...';
      const updateResult: SubscriptionUpdateResult = await SubscriptionService.updateProfile(context, current.uid);
      this.applyProfileState(updateResult.state);
      await this.refreshProxyNodes(updateResult.state);
      if (!updateResult.ok) {
        return this.createRuntimeFailure(updateResult.message);
      }
      targetState = updateResult.state;
    }

    let runtime: RuntimeConfigResult = await RuntimeConfigService.prepareCurrentProfile(context, targetState);
    if (!runtime.ok) {
      const latestCurrent: ClashProfile | undefined = CoreService.getCurrentProfile(targetState);
      if (latestCurrent && latestCurrent.type === 'remote') {
        this.statusMessage = '本地配置不可用，正在重新更新订阅...';
        const updateResult: SubscriptionUpdateResult = await SubscriptionService.updateProfile(context, latestCurrent.uid);
        this.applyProfileState(updateResult.state);
        await this.refreshProxyNodes(updateResult.state);
        if (!updateResult.ok) {
          return this.createRuntimeFailure(updateResult.message);
        }
        runtime = await RuntimeConfigService.prepareCurrentProfile(context, updateResult.state);
      }
    }

    if (runtime.ok) {
      this.tsSplitDnsNeedReload = false;
    }
    return runtime;
  }

  private createRuntimeFailure(message: string): RuntimeConfigResult {
    return { ok: false, message: message, configPath: '', profileName: '', nodeCount: 0, size: '' };
  }

  private applyProfileState(state: ProfileState): void {
    const connected: boolean = this.isRuntimeConnected();
    const current: ClashProfile | undefined = CoreService.getCurrentProfile(state);
    this.profileState = state;
    const nextSummary: CoreSummary = CoreService.createSummary(state, connected);
    this.summary = connected ? {
      state: this.summary.state,
      mode: this.summary.mode,
      profileName: nextSummary.profileName,
      proxyName: this.summary.proxyName,
      uptime: this.summary.uptime,
      downloadSpeed: this.summary.downloadSpeed,
      uploadSpeed: this.summary.uploadSpeed,
      connections: this.summary.connections
    } : nextSummary;
    if (!connected) {
      this.statusMessage = current ? '配置已加载' : '请先导入或启用一个配置';
    }
    this.syncHomeRuntimeFields(state);
    this.liveProfileName = nextSummary.profileName;
    if (!connected) {
      this.liveProxyName = nextSummary.proxyName;
    }
    this.liveRefreshToken = this.liveRefreshToken + 1;
  }

  private async resumeRuntimeIfControllerAvailable(): Promise<void> {
    const status: ControllerStatus = await MihomoControllerService.checkVersion();
    if (!status.available) {
      if (this.isRuntimeConnected()) {
        this.handleRuntimeUnavailable(status.message);
      }
      return;
    }

    this.controllerStatus = status;
    this.coreBridgeState = CoreBridgeService.markControllerReady(true, status.version);
    const tunReady: RuntimeTunStatus = await this.waitForVpnTunReady(1, 0);
    if (!tunReady.ready) {
      this.vpnTunnelActive = false;
      this.connectedAt = 0;
      this.vpnActionText = '连接';
      this.summary = CoreService.createSummary(this.profileState, false);
      this.statusMessage = `controller 已连接：${status.version} · VPN 未连接`;
      await this.refreshControllerProxies();
      await this.refreshConnections();
      this.syncHomeRuntimeFields();
      return;
    }

    this.vpnTunnelActive = true;
    await VpnKeepAliveService.start(getContext(this) as common.UIAbilityContext);
    await this.refreshCoreLogs();
    if (this.connectedAt <= 0) {
      this.connectedAt = Date.now();
    }
    this.vpnActionText = '断开';
    await this.refreshControllerProxies();
    this.summary = this.createLiveSummary({
      downloadSpeed: this.summary.downloadSpeed,
      uploadSpeed: this.summary.uploadSpeed,
      totalDownload: 0,
      totalUpload: 0,
      activeConnections: this.summary.connections,
      memoryUsage: '',
      uptimeSeconds: 0,
      mode: this.proxyMode,
      controllerAvailable: true,
      message: 'controller 正常'
    });
    this.statusMessage = `已连接 · ${status.version}`;
    this.startRuntimePolling();
    await this.refreshConnections();
    this.syncHomeRuntimeFields();
  }

  private async addRemoteProfile(): Promise<void> {
    const url: string = this.importUrl.trim();
    if (url.length === 0) {
      this.statusMessage = '订阅 URL 不能为空';
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      this.statusMessage = '请输入 http 或 https 开头的订阅 URL';
      return;
    }
    const name: string = this.importName.trim().length > 0 ? this.importName.trim() : this.createProfileNameFromUrl(url);
    const userAgent: string = this.importUserAgent.replace(/[\r\n]/g, '').trim();
    const context = getContext(this) as common.Context;
    const prevCurrentUid: string = this.profileState.currentUid;
    const newProfile: ClashProfile = createRemoteProfile(name, url, userAgent);
    const next: ProfileState = await ProfileStore.addRemote(context, newProfile);
    this.importUrl = '';
    this.importName = '';
    this.importUserAgent = '';
    this.showImportPanel = false;
    this.applyProfileState(next);
    if (prevCurrentUid.length > 0 && newProfile.uid !== next.currentUid) {
      this.pendingProfileUid = newProfile.uid;
    }
    this.statusMessage = `已保存订阅：${name}，正在下载...`;
    this.recordLog('info', this.statusMessage);
    const updateResult: SubscriptionUpdateResult = await SubscriptionService.updateProfile(context, newProfile.uid);
    this.applyProfileState(updateResult.state);
    await this.refreshProxyNodes(updateResult.state);
    if (!updateResult.ok) {
      this.statusMessage = updateResult.message;
      this.recordLog('warn', updateResult.message);
      return;
    }
    if (next.currentUid === newProfile.uid) {
      const runtime: RuntimeConfigResult = await RuntimeConfigService.prepareCurrentProfile(context, updateResult.state);
      if (runtime.ok) {
        this.runtimeConfigPath = runtime.configPath;
        this.runtimeConfigInfo = `${runtime.profileName} · ${runtime.size}`;
        this.statusMessage = `${updateResult.message}，运行配置已准备`;
      } else {
        this.statusMessage = `${updateResult.message}，${runtime.message}`;
      }
    } else {
      this.statusMessage = `${updateResult.message}，已列为「待生效版本」`;
    }
    this.syncHomeRuntimeFields();
    this.recordLog('info', this.statusMessage);
  }

  private openSubMetaEditor(item: ClashProfile): void {
    this.editingSubMetaUid = item.uid;
    this.editingSubMetaName = item.name;
    this.editingSubMetaUrl = item.type === 'remote' ? item.source : '';
    this.editingSubMetaUserAgent = item.userAgent ? item.userAgent : '';
  }

  private closeSubMetaEditor(): void {
    this.editingSubMetaUid = '';
    this.editingSubMetaName = '';
    this.editingSubMetaUrl = '';
    this.editingSubMetaUserAgent = '';
  }

  private async saveSubMetaEditor(refreshNow: boolean): Promise<void> {
    const uid: string = this.editingSubMetaUid;
    if (uid.length === 0) {
      return;
    }
    let existing: ClashProfile | undefined = undefined;
    for (let i = 0; i < this.profileState.items.length; i++) {
      if (this.profileState.items[i].uid === uid) {
        existing = this.profileState.items[i];
        break;
      }
    }
    if (!existing) {
      this.closeSubMetaEditor();
      return;
    }
    const nextUrl: string = this.editingSubMetaUrl.trim();
    if (nextUrl.length > 0 && !nextUrl.startsWith('http://') && !nextUrl.startsWith('https://')) {
      this.statusMessage = '订阅 URL 必须以 http:// 或 https:// 开头';
      return;
    }
    if (refreshNow && nextUrl.length === 0) {
      this.statusMessage = '请先填写订阅 URL 再更新';
      return;
    }
    const nextName: string = this.editingSubMetaName.trim().length > 0 ? this.editingSubMetaName.trim() : existing.name;
    const nextUa: string = this.editingSubMetaUserAgent.replace(/[\r\n]/g, '').trim();
    const updated: ClashProfile = {
      uid: existing.uid,
      type: nextUrl.length > 0 ? 'remote' : existing.type,
      name: nextName,
      source: nextUrl.length > 0 ? nextUrl : existing.source,
      userAgent: nextUa,
      filePath: existing.filePath,
      updatedAt: existing.updatedAt,
      nodeCount: existing.nodeCount,
      traffic: existing.traffic
    };
    const context = getContext(this) as common.Context;
    const nextState: ProfileState = await ProfileStore.replace(context, updated);
    this.applyProfileState(nextState);
    this.closeSubMetaEditor();
    if (refreshNow) {
      await this.updateProfile(updated.uid);
    } else {
      this.statusMessage = nextUa.length > 0
        ? `已保存订阅设置（自定义 User-Agent: ${nextUa}）`
        : '已保存订阅设置（恢复默认 User-Agent）';
      this.recordLog('info', this.statusMessage);
    }
  }

  private async launchActiveProfileOnHome(): Promise<void> {
    this.navigateToTab('home');
    if (this.toggling) {
      return;
    }
    if (this.isRuntimeConnected()) {
      await this.toggleVpn();
      await this.waitForUiUpdate(350);
    }
    if (!this.isRuntimeConnected() && !this.toggling) {
      await this.toggleVpn();
    }
  }

  private async openClipboardImportPanel(readFromSystem: boolean): Promise<void> {
    this.showImportPanel = false;
    this.showClipboardPanel = true;
    this.clipboardValidationChecked = false;
    this.clipboardValidationOk = false;
    this.clipboardValidationMessage = '';
    this.clipboardValidationStats = '';
    this.clipboardIsUrl = false;

    if (!readFromSystem) {
      return;
    }

    const readRes: ClipboardReadResult = await ClipboardImportService.readClipboardText();
    if (!readRes.ok) {
      this.clipboardValidationChecked = true;
      this.clipboardValidationOk = false;
      this.clipboardValidationMessage = readRes.message;
      this.qrSyncBannerOk = false;
      this.qrSyncBanner = readRes.message;
      return;
    }

    this.clipboardDraftText = readRes.text;
    const trimmed: string = readRes.text.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      const firstLine: string = trimmed.split('\n')[0].trim();
      this.clipboardDraftName = this.createProfileNameFromUrl(firstLine);
    } else if (this.clipboardDraftName.trim().length === 0) {
      this.clipboardDraftName = '剪贴板配置';
    }
    await this.validateClipboardDraft();
  }

  private async validateClipboardDraft(): Promise<boolean> {
    const trimmed: string = this.clipboardDraftText.trim();
    this.clipboardValidationChecked = true;
    this.clipboardValidationStats = '';
    this.clipboardIsUrl = false;

    if (trimmed.length === 0) {
      this.clipboardValidationOk = false;
      this.clipboardValidationMessage = '文本框内容为空，请先粘贴 Clash YAML 或订阅链接';
      return false;
    }

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      this.clipboardIsUrl = true;
      this.clipboardValidationOk = true;
      this.clipboardValidationMessage = '检测到远程订阅链接，点击「拉取并保存」将下载并校验配置';
      return true;
    }

    let yamlToValidate: string = trimmed;
    const looksYaml: boolean = trimmed.indexOf('proxies:') >= 0 ||
      trimmed.indexOf('proxy-providers:') >= 0 ||
      trimmed.indexOf('proxy-groups:') >= 0 ||
      trimmed.indexOf('rules:') >= 0;

    if (!looksYaml) {
      const converted: ConvertedSubscription = GenericSubscriptionConverterService.normalizeToClashYaml(trimmed);
      if (!converted.ok) {
        this.clipboardValidationOk = false;
        this.clipboardValidationMessage = '内容不是有效的 Clash YAML、节点链接或订阅地址（已拦截，不会保存）';
        return false;
      }
      yamlToValidate = converted.text;
    }

    const context = getContext(this) as common.Context;
    const mergedText: string = await RuntimeConfigService.buildMergedRuntimeYaml(context, yamlToValidate);
    const res: ConfigValidationResult = CoreBridgeService.validateConfig(mergedText);
    this.clipboardValidationOk = res.ok;
    if (res.ok) {
      this.clipboardValidationMessage = 'Mihomo 内核语法校验通过，可以安全保存';
      this.clipboardValidationStats = `${res.proxyCount} 节点 · ${res.groupCount} 策略组 · ${res.ruleCount} 规则 · DNS ${res.dnsMode}`;
      return true;
    }
    this.clipboardValidationMessage = res.line > 0 ? `第 ${res.line} 行语法错误：${res.error}` : `语法校验未通过：${res.error}`;
    return false;
  }

  private async saveClipboardDraft(asCurrentVersion: boolean): Promise<void> {
    if (this.isSavingClipboard) {
      return;
    }
    this.isSavingClipboard = true;
    try {
      const valid: boolean = await this.validateClipboardDraft();
      if (!valid) {
        this.qrSyncBannerOk = false;
        this.qrSyncBanner = this.clipboardValidationMessage;
        return;
      }

      const context = getContext(this) as common.Context;
      const trimmed: string = this.clipboardDraftText.trim();

      if (this.clipboardIsUrl) {
        const firstLine: string = trimmed.split('\n')[0].trim();
        const name: string = this.clipboardDraftName.trim().length > 0
          ? this.clipboardDraftName.trim()
          : this.createProfileNameFromUrl(firstLine);
        const prevUids: string[] = this.collectProfileUids(this.profileState);
        const newProfile: ClashProfile = createRemoteProfile(name, firstLine);
        const next: ProfileState = await ProfileStore.addRemote(context, newProfile);
        this.applyProfileState(next);
        this.trackNewlyImportedPendingUid(prevUids, next);
        this.qrSyncBannerOk = true;
        this.qrSyncBanner = `正在拉取订阅「${name}」...`;
        const updateResult: SubscriptionUpdateResult = await SubscriptionService.updateProfile(context, newProfile.uid);
        this.applyProfileState(updateResult.state);
        await this.refreshProxyNodes(updateResult.state);
        this.qrSyncBannerOk = updateResult.ok;
        this.qrSyncBanner = updateResult.ok
          ? `${updateResult.message}${updateResult.state.currentUid === newProfile.uid ? '' : '（已加入待生效配置）'}`
          : `订阅保存成功，但拉取失败：${updateResult.message}`;
        this.statusMessage = this.qrSyncBanner;
        if (updateResult.ok) {
          this.showClipboardPanel = false;
          this.clipboardDraftText = '';
          this.clipboardDraftName = '';
        }
        this.syncHomeRuntimeFields();
        this.recordLog(updateResult.ok ? 'info' : 'warn', this.qrSyncBanner);
        return;
      }

      let yamlToSave: string = trimmed;
      const looksYaml: boolean = trimmed.indexOf('proxies:') >= 0 ||
        trimmed.indexOf('proxy-providers:') >= 0 ||
        trimmed.indexOf('proxy-groups:') >= 0 ||
        trimmed.indexOf('rules:') >= 0;
      if (!looksYaml) {
        const converted: ConvertedSubscription = GenericSubscriptionConverterService.normalizeToClashYaml(trimmed);
        if (converted.ok) {
          yamlToSave = converted.text;
        }
      }

      const activeProfile: ClashProfile | undefined = this.getCurrentActiveProfile();
      if (asCurrentVersion && activeProfile) {
        const currentText: string = await ProfileVersionService.readCurrentText(context, activeProfile);
        if (currentText.trim() === yamlToSave.trim()) {
          this.clipboardValidationOk = false;
          this.clipboardValidationMessage = `内容与当前配置 v${this.activeVersionNumber > 0 ? this.activeVersionNumber : 1} 完全一致，无需重复生成版本`;
          return;
        }
        const commit: VersionCommitResult = await ProfileVersionService.commitNewVersion(
          context,
          activeProfile,
          yamlToSave,
          'import',
          '剪贴板校验导入'
        );
        if (!commit.ok) {
          this.clipboardValidationOk = false;
          this.clipboardValidationMessage = commit.message;
          return;
        }
        this.applyProfileState(commit.state);
        await this.loadProfileWorkspaceData(activeProfile.uid);
        await this.refreshProxyNodes(commit.state);
        this.showClipboardPanel = false;
        this.clipboardDraftText = '';
        this.clipboardDraftName = '';
        this.qrSyncBannerOk = true;
        this.qrSyncBanner = `已校验并保存为「${activeProfile.name}」新版本 v${commit.version}`;
        this.statusMessage = this.qrSyncBanner;
        this.syncHomeRuntimeFields();
        this.recordLog('info', this.qrSyncBanner);
        return;
      }

      const prevUids: string[] = this.collectProfileUids(this.profileState);
      const saveRes: ClipboardImportResult = await ClipboardImportService.saveValidatedYamlProfile(
        context,
        this.clipboardDraftName,
        yamlToSave
      );
      this.applyProfileState(saveRes.state);
      this.trackNewlyImportedPendingUid(prevUids, saveRes.state);
      await this.refreshProxyNodes(saveRes.state);
      if (saveRes.state.currentUid.length > 0) {
        await this.loadProfileWorkspaceData(saveRes.state.currentUid);
      }
      this.qrSyncBannerOk = saveRes.ok;
      this.qrSyncBanner = saveRes.message;
      this.statusMessage = saveRes.message;
      if (saveRes.ok) {
        this.showClipboardPanel = false;
        this.clipboardDraftText = '';
        this.clipboardDraftName = '';
      }
      this.syncHomeRuntimeFields();
      this.recordLog(saveRes.ok ? 'info' : 'warn', saveRes.message);
    } finally {
      this.isSavingClipboard = false;
    }
  }

  private async clearAllProfiles(): Promise<void> {
    const context = getContext(this) as common.Context;
    const emptyState: ProfileState = await ProfileStore.clearAll(context);
    this.showClearAllConfirm = false;
    this.pendingProfileUid = '';
    this.editingProfileUid = '';
    this.editingProfileName = '';
    this.versionHistory = [];
    this.activeVersionNumber = 0;
    this.editorBaseText = '';
    this.editorDraftText = '';
    this.showVersionHistory = false;
    this.showOtherProfiles = false;
    this.showDiffPanel = false;
    this.applyProfileState(emptyState);
    this.proxyNodes = [];
    this.clearControllerProxyGroups();
    this.qrSyncBannerOk = true;
    this.qrSyncBanner = '已清空全部配置及历史版本';
    this.statusMessage = '已清空全部配置，请导入或扫码同步新配置';
    this.syncHomeRuntimeFields();
    this.recordLog('info', '已清空全部配置及历史版本');
  }

  private async importLocalFile(): Promise<void> {
    this.statusMessage = '请选择本地 YAML 或订阅文本文件...';
    const context = getContext(this) as common.Context;
    const prevUids: string[] = this.collectProfileUids(this.profileState);
    const result: FileImportResult = await LocalFileImportService.pickAndImport(context);
    this.applyProfileState(result.state);
    this.trackNewlyImportedPendingUid(prevUids, result.state);
    await this.refreshProxyNodes(result.state);
    this.qrSyncBannerOk = result.ok;
    this.qrSyncBanner = result.message;
    this.statusMessage = result.message;
    this.syncHomeRuntimeFields();
    this.recordLog(result.ok ? 'info' : 'warn', result.message);
  }

  private async activateProfile(uid: string): Promise<void> {
    const context = getContext(this) as common.Context;
    const next: ProfileState = await ProfileStore.activate(context, uid);
    if (this.pendingProfileUid === uid) {
      this.pendingProfileUid = '';
    }
    this.applyProfileState(next);
    await this.loadProfileWorkspaceData(uid);
    await this.refreshProxyNodes(next);
    this.statusMessage = '已切换当前生效配置（若已连接 VPN，请重连使其生效）';
    this.syncHomeRuntimeFields();
    this.recordLog('info', this.statusMessage);
  }

  private async removeProfile(uid: string): Promise<void> {
    const context = getContext(this) as common.Context;
    const next: ProfileState = await ProfileStore.remove(context, uid);
    if (this.pendingProfileUid === uid) {
      this.pendingProfileUid = '';
    }
    this.applyProfileState(next);
    await this.refreshProxyNodes(next);
    this.statusMessage = '配置已删除';
    this.syncHomeRuntimeFields();
    this.recordLog('info', this.statusMessage);
  }

  private async updateProfile(uid: string): Promise<void> {
    if (this.updatingProfileUid.length > 0) {
      return;
    }
    this.updatingProfileUid = uid;
    this.statusMessage = '正在更新订阅...';
    this.qrSyncBannerOk = true;
    this.qrSyncBanner = '正在从远程服务器拉取最新订阅...';
    try {
      const context = getContext(this) as common.Context;
      const result: SubscriptionUpdateResult = await SubscriptionService.updateProfile(context, uid);
      this.applyProfileState(result.state);
      await this.refreshProxyNodes(result.state);
      if (!result.ok) {
        this.qrSyncBannerOk = false;
        this.qrSyncBanner = `更新订阅失败：${result.message}`;
        this.statusMessage = this.qrSyncBanner;
        this.syncHomeRuntimeFields();
        this.recordLog('warn', this.qrSyncBanner);
        return;
      }

      const updatedProfile: ClashProfile | undefined = this.findProfileByUid(uid);
      if (updatedProfile && updatedProfile.filePath.length > 0) {
        try {
          const latestText: string = await fileIo.readText(updatedProfile.filePath);
          const commit: VersionCommitResult = await ProfileVersionService.commitNewVersion(
            context,
            updatedProfile,
            latestText,
            'import',
            '远程订阅更新'
          );
          if (commit.ok) {
            this.applyProfileState(commit.state);
            if (this.editingProfileUid === uid || commit.state.currentUid === uid) {
              await this.loadProfileWorkspaceData(uid);
            }
          }
        } catch (_vErr) {
        }
      }

      if (this.profileState.currentUid !== uid) {
        this.qrSyncBannerOk = true;
        this.qrSyncBanner = result.message;
        this.statusMessage = result.message;
        this.syncHomeRuntimeFields();
        this.recordLog('info', result.message);
        return;
      }

      const runtime: RuntimeConfigResult = await RuntimeConfigService.prepareCurrentProfile(context, this.profileState);
      if (runtime.ok) {
        this.runtimeConfigPath = runtime.configPath;
        this.runtimeConfigInfo = `${runtime.profileName} · ${runtime.size}`;
        this.qrSyncBannerOk = true;
        this.qrSyncBanner = `${result.message}（若已连接 VPN，点右上角「重启」即可生效）`;
        this.statusMessage = `${result.message}，运行配置已准备`;
      } else {
        this.qrSyncBannerOk = false;
        this.qrSyncBanner = `${result.message}，但准备运行配置失败：${runtime.message}`;
        this.statusMessage = this.qrSyncBanner;
      }
      this.syncHomeRuntimeFields();
      this.recordLog(runtime.ok ? 'info' : 'warn', this.qrSyncBanner);
    } finally {
      this.updatingProfileUid = '';
    }
  }

  private async updateAllProfiles(): Promise<void> {
    if (this.updatingProfileUid.length > 0) {
      return;
    }
    const remoteUids: string[] = [];
    for (let index = 0; index < this.profileState.items.length; index++) {
      if (this.profileState.items[index].type === 'remote') {
        remoteUids.push(this.profileState.items[index].uid);
      }
    }
    if (remoteUids.length === 0) {
      this.qrSyncBannerOk = false;
      this.qrSyncBanner = '当前没有可更新的远程订阅配置';
      this.statusMessage = this.qrSyncBanner;
      return;
    }
    this.updatingProfileUid = '__all__';
    this.qrSyncBannerOk = true;
    this.qrSyncBanner = `正在更新 ${remoteUids.length} 个远程订阅...`;
    this.statusMessage = this.qrSyncBanner;
    try {
      const context = getContext(this) as common.Context;
      let okCount: number = 0;
      let latestState: ProfileState = this.profileState;
      for (let index = 0; index < remoteUids.length; index++) {
        const result: SubscriptionUpdateResult = await SubscriptionService.updateProfile(context, remoteUids[index]);
        latestState = result.state;
        if (result.ok) { okCount++; }
      }
      this.applyProfileState(latestState);
      await this.refreshProxyNodes(latestState);
      const runtime: RuntimeConfigResult = await RuntimeConfigService.prepareCurrentProfile(context, latestState);
      if (runtime.ok) {
        this.runtimeConfigPath = runtime.configPath;
        this.runtimeConfigInfo = `${runtime.profileName} · ${runtime.size}`;
      }
      this.qrSyncBannerOk = okCount > 0;
      this.qrSyncBanner = `全量更新完成：${okCount}/${remoteUids.length} 个订阅成功`;
      this.statusMessage = this.qrSyncBanner;
      this.syncHomeRuntimeFields();
      this.recordLog(okCount === remoteUids.length ? 'info' : 'warn', this.statusMessage);
    } finally {
      this.updatingProfileUid = '';
    }
  }

  private async refreshControllerStatus(): Promise<void> {
    const status: ControllerStatus = await MihomoControllerService.checkVersion();
    this.controllerStatus = status;
    this.coreBridgeState = CoreBridgeService.markControllerReady(status.available, status.version);
    this.statusMessage = status.available ? `controller 已连接：${status.version}` : status.message;
    this.syncHomeRuntimeFields();
    this.recordLog(status.available ? 'info' : 'warn', this.statusMessage);
    if (status.available) {
      await this.refreshControllerProxies();
      const tunReady: RuntimeTunStatus = await this.waitForVpnTunReady(1, 0);
      if (tunReady.ready) {
        this.vpnTunnelActive = true;
        this.connectedAt = Date.now();
        this.vpnActionText = '断开';
        this.startRuntimePolling();
      } else {
        this.vpnTunnelActive = false;
        this.connectedAt = 0;
        this.vpnActionText = '连接';
        this.summary = CoreService.createSummary(this.profileState, false);
        this.statusMessage = `controller 已连接：${status.version} · VPN 未连接`;
      }
      await this.refreshConnections();
      this.syncHomeRuntimeFields();
    }
  }

  private async ensureControllerReadyForProxyActions(action: string): Promise<boolean> {
    let status: ControllerStatus = await MihomoControllerService.checkVersion();
    if (status.available) {
      this.controllerStatus = status;
      this.coreBridgeState = CoreBridgeService.markControllerReady(true, status.version);
      if (!this.proxyGroupsSynced) {
        await this.refreshControllerProxies();
      }
      return true;
    }

    if (this.isRuntimeConnected()) {
      this.statusMessage = `${action}：等待 VPN 核心响应...`;
      status = await MihomoControllerService.waitForVersion(6, 500);
      this.controllerStatus = status;
      this.coreBridgeState = CoreBridgeService.markControllerReady(status.available, status.version);
      if (status.available) {
        await this.refreshControllerProxies();
        return true;
      }
      this.statusMessage = `${action}失败：${status.message}`;
      this.recordLog('warn', this.statusMessage);
      return false;
    }

    const context = getContext(this) as common.Context;
    this.statusMessage = `${action}：正在准备运行配置...`;
    const runtime: RuntimeConfigResult = await this.prepareRuntimeForConnection(context);
    if (!runtime.ok) {
      this.statusMessage = runtime.message;
      this.recordLog('warn', runtime.message);
      return false;
    }

    this.runtimeConfigPath = runtime.configPath;
    this.runtimeConfigInfo = `${runtime.profileName} · ${runtime.size}`;
    this.statusMessage = `${action}：正在启动测速核心...`;
    this.syncHomeRuntimeFields();
    this.coreBridgeState = CoreBridgeService.startCore(runtime.configPath);
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'ensureControllerReady: action=%{public}s startCore running=%{public}s controllerOnly=%{public}s mode=%{public}s adapter=%{public}s kind=%{public}s supportsControllerOnly=%{public}s version=%{public}s error=%{public}s',
      action,
      this.coreBridgeState.running ? 'true' : 'false',
      this.coreBridgeState.controllerOnly ? 'true' : 'false',
      this.coreBridgeState.coreMode,
      this.coreBridgeState.adapterMode,
      this.coreBridgeState.adapterKind,
      this.coreBridgeState.supportsControllerOnly ? 'true' : 'false',
      this.coreBridgeState.adapterVersion,
      this.coreBridgeState.lastError);
    if (!this.coreBridgeState.running || !this.coreBridgeState.controllerOnly) {
      const reason: string = this.coreBridgeState.lastError.length > 0
        ? this.coreBridgeState.lastError
        : '当前 native 核心不支持 controller-only';
      this.statusMessage = `${action}失败：${reason}`;
      this.recordLog('warn', this.statusMessage);
      return false;
    }

    status = await MihomoControllerService.waitForVersion(10, 500);
    this.controllerStatus = status;
    this.coreBridgeState = CoreBridgeService.markControllerReady(status.available, status.version);
    this.syncHomeRuntimeFields();
    hilog.info(LOG_DOMAIN, LOG_TAG,
      'ensureControllerReady: action=%{public}s waitForVersion available=%{public}s version=%{public}s message=%{public}s nativeRunning=%{public}s controllerOnly=%{public}s error=%{public}s',
      action,
      status.available ? 'true' : 'false',
      status.version,
      status.message,
      this.coreBridgeState.running ? 'true' : 'false',
      this.coreBridgeState.controllerOnly ? 'true' : 'false',
      this.coreBridgeState.lastError);
    if (!status.available) {
      const nativeDetail: string = this.coreBridgeState.lastError.length > 0 ? `；native=${this.coreBridgeState.lastError}` : '';
      this.statusMessage = `${action}失败：${status.message}${nativeDetail}`;
      this.recordLog('warn', this.statusMessage);
      return false;
    }

    await MihomoControllerService.setMode(this.normalizeProxyMode(this.proxyMode));
    await this.refreshControllerProxies();
    this.statusMessage = `${action}：controller 已就绪`;
    this.recordLog('info', this.statusMessage);
    return true;
  }

  private async handleSectionAction(action: string): Promise<void> {
    if (action === '全量更新') {
      await this.updateAllProfiles();
    } else if (action === '查看') {
      this.currentTab = 'diagnostics';
    } else if (action === '关闭全部') {
      await this.closeAllControllerConnections();
    } else if (action === '导出') {
      this.statusMessage = '最近日志已在诊断页展示，文件导出将在分享能力接入后开放';
      this.recordLog('info', this.statusMessage);
    }
  }

  private async refreshProxyNodes(state?: ProfileState): Promise<void> {
    const context = getContext(this) as common.Context;
    const targetState: ProfileState = state ? state : this.profileState;
    const parsed: ParsedConfigSummary = await ClashConfigParserService.parseCurrentProfile(context, targetState);
    this.proxyStatus = parsed.message;
    const nodes: ProxyNode[] = [];
    for (let index = 0; index < parsed.nodes.length; index++) {
      nodes.push(this.mapParsedProxyNode(parsed.nodes[index], index));
    }
    this.proxyNodes = nodes;
    this.clearControllerProxyGroups();
  }

  private mapParsedProxyNode(node: ParsedProxyNode, index: number): ProxyNode {
    const delayState: ProxyDelayState = this.getCachedProxyDelayState(node.name);
    return {
      name: node.name,
      meta: `${node.type}${node.udp ? ' · UDP' : ''}`,
      delay: delayState.delay,
      selected: index === 0,
      status: delayState.status,
      server: node.server,
      port: node.port
    };
  }

  private async changeProxyMode(mode: 'rule' | 'global' | 'direct'): Promise<void> {
    if (this.proxyMode === mode) {
      this.statusMessage = `当前已是${this.modeLabel(mode)}模式`;
      return;
    }

    this.proxyMode = mode;
    const controllerCanApply: boolean = this.controllerStatus.available || this.coreBridgeState.controllerReady || this.proxyGroupsSynced;
    if (!controllerCanApply) {
      this.statusMessage = `已切换到${this.modeLabel(mode)}模式，连接或测速启动核心后生效`;
      this.syncHomeRuntimeFields();
      this.recordLog('info', this.statusMessage);
      return;
    }

    const ok: boolean = await MihomoControllerService.setMode(mode);
    this.statusMessage = ok ? `已切换到${this.modeLabel(mode)}模式` : '模式切换失败，controller 未响应';
    if (ok) {
      this.summary = {
        state: this.isRuntimeConnected() ? 'running' : 'stopped',
        mode: mode,
        profileName: this.currentProfileDisplayName(),
        proxyName: this.summary.proxyName,
        uptime: this.summary.uptime,
        downloadSpeed: this.summary.downloadSpeed,
        uploadSpeed: this.summary.uploadSpeed,
        connections: this.summary.connections
      };
      this.syncHomeRuntimeFields();
    }
    this.recordLog(ok ? 'info' : 'warn', this.statusMessage);
  }

  private async refreshControllerProxies(): Promise<void> {
    const previousSelectedGroup: string = this.selectedProxyGroup;
    const result: ControllerTextResult = await MihomoControllerService.getProxies();
    if (!result.ok) {
      this.proxyStatus = result.message;
      return;
    }

    const groups: ProxyGroupInfo[] = MihomoControllerService.parseProxyGroups(result.raw);
    this.proxyGroups = groups;
    if (groups.length === 0) {
      this.proxyStatus = 'controller 已连接，但未返回可选择策略组';
      return;
    }

    this.selectedProxyGroup = this.resolvePreferredProxyGroupName(groups, previousSelectedGroup);
    this.proxyGroupsSynced = true;
    this.applySelectedProxyGroup();
    this.rebuildHomeActiveNodes();
  }

  private clearControllerProxyGroups(): void {
    this.proxyGroups = [];
    this.proxyGroupsSynced = false;
    this.selectedProxyGroup = '';
    this.homeActiveNodes = [];
    this.homePrimaryDelayText = '待测';
  }

  private applySelectedProxyGroup(): void {
    const group: ProxyGroupInfo | undefined = this.findSelectedProxyGroup();
    if (!group) {
      return;
    }

    const nodes: ProxyNode[] = [];
    for (let index = 0; index < group.all.length; index++) {
      const name: string = group.all[index];
      const delayState: ProxyDelayState = this.getCachedProxyDelayState(name);
      nodes.push({
        name: name,
        meta: `${group.name} · ${group.type}`,
        delay: delayState.delay,
        selected: name === group.now,
        status: delayState.status
      });
    }
    this.proxyNodes = nodes;
    this.proxyStatus = `${group.name} · 当前 ${group.now.length > 0 ? group.now : '未选择'} · ${group.all.length} 个节点`;
    this.syncHomeRuntimeFields();
  }

  private findSelectedProxyGroup(): ProxyGroupInfo | undefined {
    for (let index = 0; index < this.proxyGroups.length; index++) {
      if (this.proxyGroups[index].name === this.selectedProxyGroup) {
        return this.proxyGroups[index];
      }
    }
    return this.proxyGroups.length > 0 ? this.proxyGroups[0] : undefined;
  }

  private resolvePreferredProxyGroupName(groups: ProxyGroupInfo[], previousSelectedGroup: string): string {
    if (groups.length === 0) {
      return '';
    }

    if (previousSelectedGroup.length > 0 && this.hasProxyGroup(groups, previousSelectedGroup)) {
      return previousSelectedGroup;
    }

    if (this.pendingProxyGroup.length > 0 && this.hasProxyGroup(groups, this.pendingProxyGroup)) {
      return this.pendingProxyGroup;
    }

    if (this.proxyMode === 'global' && this.hasProxyGroup(groups, 'GLOBAL')) {
      return 'GLOBAL';
    }

    const trafficGroup: string = this.findRuleTrafficProxyGroupName(groups);
    if (trafficGroup.length > 0) {
      return trafficGroup;
    }

    if (previousSelectedGroup.length > 0 && this.hasProxyGroup(groups, previousSelectedGroup)) {
      return previousSelectedGroup;
    }
    return groups[0].name;
  }

  private findRuleTrafficProxyGroupName(groups: ProxyGroupInfo[]): string {
    const preferredNames: string[] = ['Proxy', 'PROXY', '🚀 节点选择', '节点选择', '自动选择', 'Auto'];
    for (let preferredIndex = 0; preferredIndex < preferredNames.length; preferredIndex++) {
      if (this.hasProxyGroup(groups, preferredNames[preferredIndex])) {
        return preferredNames[preferredIndex];
      }
    }

    for (let index = 0; index < groups.length; index++) {
      if (groups[index].name !== 'GLOBAL') {
        return groups[index].name;
      }
    }
    return '';
  }

  private hasProxyGroup(groups: ProxyGroupInfo[], groupName: string): boolean {
    for (let index = 0; index < groups.length; index++) {
      if (groups[index].name === groupName) {
        return true;
      }
    }
    return false;
  }

  private findRuntimeProxyGroup(): ProxyGroupInfo | undefined {
    if (this.proxyMode === 'global') {
      const globalGroup: ProxyGroupInfo | undefined = this.findProxyGroupByName('GLOBAL');
      if (globalGroup) {
        return globalGroup;
      }
    }

    const trafficGroupName: string = this.findRuleTrafficProxyGroupName(this.proxyGroups);
    if (trafficGroupName.length > 0) {
      const trafficGroup: ProxyGroupInfo | undefined = this.findProxyGroupByName(trafficGroupName);
      if (trafficGroup) {
        return trafficGroup;
      }
    }
    return this.findSelectedProxyGroup();
  }

  private findProxyGroupByName(groupName: string): ProxyGroupInfo | undefined {
    for (let index = 0; index < this.proxyGroups.length; index++) {
      if (this.proxyGroups[index].name === groupName) {
        return this.proxyGroups[index];
      }
    }
    return undefined;
  }

  private selectProxyGroup(groupName: string): void {
    this.selectedProxyGroup = groupName;
    this.applySelectedProxyGroup();
  }

  private async selectProxyNode(node: ProxyNode): Promise<void> {
    const previousName: string = this.getSelectedProxyNodeName();
    this.statusMessage = `正在切换节点：${node.name}`;
    let group: ProxyGroupInfo | undefined = this.findSelectedProxyGroup();
    if (group) {
      this.pendingProxyGroup = group.name;
    }
    this.pendingProxyName = node.name;
    this.markSelectedProxyNode(node.name);
    this.syncHomeRuntimeFields();
    await this.waitForUiUpdate(0);

    if (!group) {
      const ready: boolean = await this.ensureControllerReadyForProxyActions('切换节点');
      if (!ready) {
        return;
      }
      group = this.findSelectedProxyGroup();
      if (!group) {
        this.statusMessage = '当前没有可选择的策略组';
        this.recordLog('warn', this.statusMessage);
        return;
      }
    }

    const ok: boolean = await MihomoControllerService.selectProxy(group.name, node.name);
    if (!ok) {
      if (previousName.length > 0 && previousName !== node.name) {
        this.markSelectedProxyNode(previousName);
      }
      this.pendingProxyName = previousName;
      this.pendingProxyGroup = group.name;
      this.statusMessage = `切换节点失败：${group.name} -> ${node.name}`;
      this.recordLog('warn', this.statusMessage);
      return;
    }

    this.statusMessage = `已切换 ${group.name} -> ${node.name}`;
    this.pendingProxyGroup = group.name;
    this.pendingProxyName = node.name;
    this.markSelectedProxyNode(node.name);
    this.recordLog('info', this.statusMessage);
    await this.refreshControllerProxies();
    this.summary = this.createLiveSummary({
      downloadSpeed: this.summary.downloadSpeed,
      uploadSpeed: this.summary.uploadSpeed,
      totalDownload: 0,
      totalUpload: 0,
      activeConnections: this.summary.connections,
      memoryUsage: '',
      uptimeSeconds: 0,
      mode: this.proxyMode,
      controllerAvailable: this.controllerStatus.available,
      message: this.controllerStatus.message
    });
    this.syncHomeRuntimeFields();
  }

  private markSelectedProxyNode(name: string): void {
    const nodes: ProxyNode[] = [];
    for (let index = 0; index < this.proxyNodes.length; index++) {
      const node: ProxyNode = this.proxyNodes[index];
      nodes.push({
        name: node.name,
        meta: node.meta,
        delay: node.delay,
        selected: node.name === name,
        status: node.status,
        server: node.server,
        port: node.port
      });
    }
    this.proxyNodes = nodes;
  }

  private getSelectedProxyNodeName(): string {
    for (let index = 0; index < this.proxyNodes.length; index++) {
      if (this.proxyNodes[index].selected) {
        return this.proxyNodes[index].name;
      }
    }
    return '';
  }

  private async restoreProxySelection(groupName: string, proxyName: string): Promise<void> {
    if (groupName.length === 0 || proxyName.length === 0) {
      return;
    }
    const ok: boolean = await MihomoControllerService.selectProxy(groupName, proxyName);
    if (!ok) {
      this.recordLog('warn', `连接后恢复节点失败：${groupName} -> ${proxyName}`);
      return;
    }
    this.pendingProxyGroup = groupName;
    this.pendingProxyName = proxyName;
    this.selectedProxyGroup = groupName;
    this.markSelectedProxyNode(proxyName);
    await this.refreshControllerProxies();
    this.recordLog('info', `连接后已恢复节点：${groupName} -> ${proxyName}`);
  }

  private getVisibleProxyNodes(): ProxyNode[] {
    const query: string = this.proxySearchText.trim().toLowerCase();
    if (query.length === 0) {
      return this.proxyNodes;
    }

    const result: ProxyNode[] = [];
    for (let index = 0; index < this.proxyNodes.length; index++) {
      const node: ProxyNode = this.proxyNodes[index];
      const haystack: string = `${node.name} ${node.meta}`.toLowerCase();
      if (haystack.indexOf(query) >= 0) {
        result.push(node);
      }
    }
    return result;
  }

  private getVisibleProxyNodeIndexes(): number[] {
    const query: string = this.proxySearchText.trim().toLowerCase();
    const indexes: number[] = [];
    for (let index = 0; index < this.proxyNodes.length; index++) {
      if (query.length === 0) {
        indexes.push(index);
        continue;
      }
      const node: ProxyNode = this.proxyNodes[index];
      const haystack: string = `${node.name} ${node.meta}`.toLowerCase();
      if (haystack.indexOf(query) >= 0) {
        indexes.push(index);
      }
    }
    return indexes;
  }

  private getAllProxyNodeIndexes(): number[] {
    const indexes: number[] = [];
    for (let index = 0; index < this.proxyNodes.length; index++) {
      indexes.push(index);
    }
    return indexes;
  }

  private startRuntimePolling(): void {
    this.runtimePollTick = 0;
    TrafficPollerService.stop();
    this.startHomeRefreshLoop();
    this.refreshLiveRuntimeSnapshot();
  }

  private startHomeRefreshLoop(): void {
    if (this.homeRefreshIntervalId !== undefined) {
      return;
    }
    this.resetHomeTrafficBaseline();
    this.refreshLiveRuntimeSnapshot();
    this.homeRefreshIntervalId = setInterval(() => {
      this.refreshLiveRuntimeSnapshot();
    }, 1000);
  }

  private stopHomeRefreshLoop(): void {
    if (this.homeRefreshIntervalId !== undefined) {
      clearInterval(this.homeRefreshIntervalId);
      this.homeRefreshIntervalId = undefined;
    }
    this.homeRefreshInFlight = false;
  }

  private async refreshLiveRuntimeSnapshot(): Promise<void> {
    if (this.homeRefreshInFlight) {
      return;
    }
    this.homeRefreshInFlight = true;
    try {
      const connectionsResult: ControllerTextResult = await MihomoControllerService.getConnections();
      const configResult: ControllerTextResult = await MihomoControllerService.getConfig();
      if (!connectionsResult.ok || !configResult.ok) {
        this.homeRefreshFailures++;
        if (this.homeRefreshFailures >= 3 && this.isRuntimeConnected()) {
          this.handleRuntimeUnavailable(connectionsResult.ok ? configResult.message : connectionsResult.message);
        }
        return;
      }

      this.homeRefreshFailures = 0;
      this.runtimePollTick++;

      if (!this.controllerStatus.available || this.runtimePollTick % 5 === 0) {
        const status: ControllerStatus = await MihomoControllerService.checkVersion();
        if (status.available) {
          this.controllerStatus = status;
          this.coreBridgeState = CoreBridgeService.markControllerReady(true, status.version);
        }
      }

      const connections: ControllerConnectionInfo[] = MihomoControllerService.parseConnections(connectionsResult.raw);
      const totalDownload: number = this.readJsonNumber(connectionsResult.raw, 'downloadTotal');
      const totalUpload: number = this.readJsonNumber(connectionsResult.raw, 'uploadTotal');
      const activeDownloadTotal: number = this.sumConnectionDownload(connections);
      const activeUploadTotal: number = this.sumConnectionUpload(connections);
      const now: number = Date.now();
      let downloadSpeed: number = 0;
      let uploadSpeed: number = 0;
      if (this.homeTrafficBaselineReady && this.homeLastPollAt > 0 && now > this.homeLastPollAt) {
        const elapsedSeconds: number = (now - this.homeLastPollAt) / 1000;
        const totalDownloadDelta: number = Math.max(0, totalDownload - this.homeLastDownloadTotal);
        const totalUploadDelta: number = Math.max(0, totalUpload - this.homeLastUploadTotal);
        const activeDownloadDelta: number = Math.max(0, activeDownloadTotal - this.homeLastActiveDownloadTotal);
        const activeUploadDelta: number = Math.max(0, activeUploadTotal - this.homeLastActiveUploadTotal);
        downloadSpeed = Math.max(totalDownloadDelta, activeDownloadDelta) / elapsedSeconds;
        uploadSpeed = Math.max(totalUploadDelta, activeUploadDelta) / elapsedSeconds;
      }
      this.homeLastDownloadTotal = totalDownload;
      this.homeLastUploadTotal = totalUpload;
      this.homeLastActiveDownloadTotal = activeDownloadTotal;
      this.homeLastActiveUploadTotal = activeUploadTotal;
      this.homeLastPollAt = now;
      this.homeTrafficBaselineReady = true;

      const controllerMode: 'rule' | 'global' | 'direct' = this.parseControllerMode(configResult.raw);
      this.proxyMode = controllerMode;
      this.runtimeConnections = this.mapControllerConnections(connections);
      this.updateHomeTrafficStats(connections);
      const tunReady: RuntimeTunStatus = this.parseRuntimeTunStatus(configResult.raw);
      if (!tunReady.ready) {
        this.vpnTunnelActive = false;
        this.connectedAt = 0;
        this.vpnActionText = '连接';
        this.summary = CoreService.createSummary(this.profileState, false);
        this.resetHomeTrafficBaseline();
        this.clearProxyHealthState();
        this.clearTailscaleState();
        this.syncHomeRuntimeFields();
        if (!this.isSpeedTesting && !this.toggling) {
          const version: string = this.controllerStatus.version.length > 0 ? this.controllerStatus.version : 'controller';
          this.statusMessage = `controller ${version} 已就绪 · VPN 未连接`;
        }
        if (!this.isSpeedTesting && this.runtimePollTick % 3 === 0) {
          this.refreshControllerProxies();
        }
        return;
      }

      this.vpnTunnelActive = true;
      this.summary = {
        state: 'running',
        mode: controllerMode,
        profileName: this.currentProfileDisplayName(),
        proxyName: this.currentProxyLabel(),
        uptime: this.formatRuntimeUptime(),
        downloadSpeed: this.formatSpeedValue(downloadSpeed),
        uploadSpeed: this.formatSpeedValue(uploadSpeed),
        connections: connections.length
      };
      this.vpnActionText = '断开';
      if (this.connectedAt <= 0) {
        this.connectedAt = Date.now();
      }
      this.syncHomeRuntimeFields();

      if (!this.isSpeedTesting && !this.toggling) {
        const version: string = this.controllerStatus.version.length > 0 ? this.controllerStatus.version : 'controller';
        this.statusMessage = `已连接 · ${version} · ${connections.length} 连接${this.formatProxyHealthSuffix()}`;
      }
      if (!this.isSpeedTesting && this.runtimePollTick % 3 === 0) {
        this.refreshControllerProxies();
      }
      if (this.runtimePollTick === 1 || this.runtimePollTick % 3 === 0) {
        await this.refreshTailscaleStatus();
      }
    } finally {
      this.homeRefreshInFlight = false;
    }
  }

  private handleRuntimeUnavailable(message: string): void {
    TrafficPollerService.stop();
    this.stopHomeRefreshLoop();
    this.runtimePollTick = 0;
    this.connectedAt = 0;
    this.vpnTunnelActive = false;
    this.resetHomeTrafficBaseline();
    this.clearProxyHealthState();
    this.clearTailscaleState();
    this.runtimeConnections = [];
    this.controllerStatus = { available: false, version: '', message: message, raw: '' };
    this.coreBridgeState = CoreBridgeService.markControllerReady(false, '');
    this.summary = CoreService.createSummary(this.profileState, false);
    this.vpnActionText = '连接';
    this.statusMessage = message.length > 0 ? message : 'controller 已断开';
    this.syncHomeRuntimeFields();
  }

  private createLiveSummary(snapshot: TrafficSnapshot): CoreSummary {
    const current: ClashProfile | undefined = CoreService.getCurrentProfile(this.profileState);
    return {
      state: 'running',
      mode: this.normalizeProxyMode(snapshot.mode),
      profileName: current ? current.name : this.currentProfileDisplayName(),
      proxyName: this.currentProxyLabel(),
      uptime: this.formatRuntimeUptime(),
      downloadSpeed: snapshot.downloadSpeed,
      uploadSpeed: snapshot.uploadSpeed,
      connections: snapshot.activeConnections
    };
  }

  private mapPollerConnections(connections: PollerConnectionInfo[]): RuntimeConnectionRow[] {
    const result: RuntimeConnectionRow[] = [];
    const limit: number = connections.length > 50 ? 50 : connections.length;
    for (let index = 0; index < limit; index++) {
      const item: PollerConnectionInfo = connections[index];
      const target: string = item.metadata.host.length > 0
        ? item.metadata.host
        : `${item.metadata.destIP}${item.metadata.type.length > 0 ? ` · ${item.metadata.type}` : ''}`;
      result.push({
        id: item.id,
        target: target.length > 0 ? target : 'unknown',
        chain: item.chains.join(' / '),
        rule: item.rule.length > 0 ? item.rule : 'MATCH',
        upload: this.formatBytes(item.upload),
        download: this.formatBytes(item.download)
      });
    }
    return result;
  }

  private mapControllerConnections(connections: ControllerConnectionInfo[]): RuntimeConnectionRow[] {
    const result: RuntimeConnectionRow[] = [];
    const limit: number = connections.length > 50 ? 50 : connections.length;
    for (let index = 0; index < limit; index++) {
      const item: ControllerConnectionInfo = connections[index];
      const target: string = item.metadata.host.length > 0
        ? item.metadata.host
        : `${item.metadata.destinationIP}:${item.metadata.destinationPort}`;
      result.push({
        id: item.id,
        target: target.length > 0 ? target : 'unknown',
        chain: item.chains.join(' / '),
        rule: item.rule.length > 0 ? item.rule : 'MATCH',
        upload: this.formatBytes(item.upload),
        download: this.formatBytes(item.download)
      });
    }
    return result;
  }

  private async refreshConnections(): Promise<void> {
    const result: ControllerTextResult = await MihomoControllerService.getConnections();
    if (!result.ok) {
      this.recordLog('warn', result.message);
      return;
    }
    const connections: ControllerConnectionInfo[] = MihomoControllerService.parseConnections(result.raw);
    this.runtimeConnections = this.mapControllerConnections(connections);
    this.summary = {
      state: this.isRuntimeConnected() ? 'running' : 'stopped',
      mode: this.summary.mode,
      profileName: this.currentProfileDisplayName(),
      proxyName: this.summary.proxyName,
      uptime: this.summary.uptime,
      downloadSpeed: this.summary.downloadSpeed,
      uploadSpeed: this.summary.uploadSpeed,
      connections: connections.length
    };
    this.syncHomeRuntimeFields();
  }

  private async closeAllControllerConnections(): Promise<void> {
    const ok: boolean = await MihomoControllerService.closeAllConnections();
    if (ok) {
      this.runtimeConnections = [];
      this.statusMessage = '已关闭全部 controller 连接';
    } else {
      this.statusMessage = '关闭连接失败，controller 未响应';
    }
    this.recordLog(ok ? 'info' : 'warn', this.statusMessage);
  }

  private async refreshRules(): Promise<void> {
    const result: ControllerTextResult = await MihomoControllerService.getRules();
    if (!result.ok) {
      this.rulesStatus = result.message;
      this.ruleLines = [];
      this.recordLog('warn', result.message);
      return;
    }
    this.ruleLines = this.pickJsonArrayPreview(result.raw, 'rules', 40);
    this.rulesStatus = `已同步 ${this.ruleLines.length} 条规则预览`;
    this.recordLog('info', this.rulesStatus);
  }

  private async refreshDnsConfig(): Promise<void> {
    const result: ControllerTextResult = await MihomoControllerService.getConfig();
    if (!result.ok) {
      this.dnsStatus = result.message;
      this.dnsLines = [];
      this.recordLog('warn', result.message);
      return;
    }
    this.dnsLines = this.pickJsonObjectPreview(result.raw, 'dns', 40);
    this.dnsStatus = this.dnsLines.length > 0 ? 'DNS 配置已同步' : '当前配置未返回 DNS 字段';
    this.recordLog('info', this.dnsStatus);
  }

  private pickJsonArrayPreview(raw: string, key: string, limit: number): string[] {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const array = parsed[key] as Object[];
      if (!Array.isArray(array)) {
        return [];
      }
      const result: string[] = [];
      const count: number = array.length > limit ? limit : array.length;
      for (let index = 0; index < count; index++) {
        result.push(String(array[index]));
      }
      return result;
    } catch (err) {
      return raw.split('\n').slice(0, limit);
    }
  }

  private pickJsonObjectPreview(raw: string, key: string, limit: number): string[] {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const value: Object | undefined = parsed[key];
      if (!value) {
        return [];
      }
      return JSON.stringify(value, null, 2).split('\n').slice(0, limit);
    } catch (err) {
      return raw.split('\n').slice(0, limit);
    }
  }

  private recordLog(level: string, message: string): void {
    const next: AppLogEntry[] = [{
      time: this.formatLogTime(new Date()),
      level: level,
      message: message
    }];
    for (let index = 0; index < this.appLogs.length && index < 49; index++) {
      next.push(this.appLogs[index]);
    }
    this.appLogs = next;
  }

  private async readTailLines(filePath: string, prefix: string, maxLines: number): Promise<string[]> {
    try {
      const exists: boolean = await fileIo.access(filePath);
      if (!exists) {
        return [];
      }
      const raw: string = await fileIo.readText(filePath);
      const rawLines: string[] = raw.split('\n');
      const lines: string[] = [];
      for (let index = 0; index < rawLines.length; index++) {
        const line: string = rawLines[index].trim();
        if (line.length > 0) {
          lines.push(prefix.length > 0 ? `${prefix} ${line}` : line);
        }
      }
      const startIndex: number = lines.length > maxLines ? lines.length - maxLines : 0;
      return lines.slice(startIndex);
    } catch (_err) {
      return [];
    }
  }

  private findLatestErrorLine(lines: string[]): string {
    for (let index = lines.length - 1; index >= 0; index--) {
      const line: string = lines[index];
      if (line.indexOf('[ERROR]') >= 0 || line.indexOf('level=error') >= 0 ||
        line.indexOf('FAILED') >= 0 || line.indexOf('exception') >= 0) {
        return line;
      }
    }
    return '';
  }

  private async readLastDiagnosticLine(): Promise<string> {
    const context = getContext(this) as common.Context;
    const runtimeDir: string = `${context.filesDir}/runtime`;
    const coreLines: string[] = await this.readTailLines(`${runtimeDir}/mihomo-core.log`, '', 40);
    const stderrLines: string[] = await this.readTailLines(`${runtimeDir}/go-runtime-stderr.log`, '', 40);
    const extLines: string[] = await this.readTailLines(`${runtimeDir}/vpn-extension.log`, '', 20);
    const coreErr: string = this.findLatestErrorLine(coreLines);
    if (coreErr.length > 0) {
      return coreErr;
    }
    const extErr: string = this.findLatestErrorLine(extLines);
    if (extErr.length > 0) {
      return extErr;
    }
    const stderrErr: string = this.findLatestErrorLine(stderrLines);
    if (stderrErr.length > 0) {
      return stderrErr;
    }
    if (stderrLines.length > 0) {
      return stderrLines[stderrLines.length - 1];
    }
    if (extLines.length > 0) {
      return extLines[extLines.length - 1];
    }
    if (coreLines.length > 0) {
      return coreLines[coreLines.length - 1];
    }
    return '';
  }

  private clearTailscaleState(): void {
    this.tailscaleState = '';
    this.tailscaleHostname = '';
    this.tailscaleAuthUrl = '';
    this.tailscaleIps = '';
    this.tailscaleError = '';
    this.tailscaleHealth = [];
    this.tailscaleRecentLogs = [];
  }

  private readJsonStringField(obj: Record<string, Object>, key: string): string {
    const val: Object | undefined = obj[key];
    return typeof val === 'string' ? (val as string).trim() : '';
  }

  private readJsonStringArrayField(obj: Record<string, Object>, key: string): string[] {
    const val: Object | undefined = obj[key];
    if (!Array.isArray(val)) {
      return [];
    }
    const items: Object[] = val as Object[];
    const result: string[] = [];
    for (let i = 0; i < items.length; i++) {
      if (typeof items[i] === 'string') {
        const entry: string = (items[i] as string).trim();
        if (entry.length > 0) {
          result.push(entry);
        }
      }
    }
    return result;
  }

  private async refreshTailscaleStatus(): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const statusPath: string = `${context.filesDir}/runtime/tailscale-status.json`;
      const exists: boolean = await fileIo.access(statusPath);
      if (!exists) {
        return;
      }
      const raw: string = await fileIo.readText(statusPath);
      if (raw.trim().length === 0) {
        return;
      }
      const parsed = JSON.parse(raw) as Record<string, Object>;
      if (!parsed) {
        return;
      }
      const status: TailscaleRuntimeStatus = {
        name: this.readJsonStringField(parsed, 'name'),
        hostname: this.readJsonStringField(parsed, 'hostname'),
        backendState: this.readJsonStringField(parsed, 'backendState'),
        authUrl: this.readJsonStringField(parsed, 'authUrl'),
        tailscaleIPs: this.readJsonStringArrayField(parsed, 'tailscaleIPs'),
        health: this.readJsonStringArrayField(parsed, 'health'),
        lastError: this.readJsonStringField(parsed, 'lastError'),
        recentLogs: this.readJsonStringArrayField(parsed, 'recentLogs'),
        updatedAt: this.readJsonStringField(parsed, 'updatedAt')
      };
      this.tailscaleState = status.backendState;
      this.tailscaleHostname = status.hostname;
      this.tailscaleIps = status.tailscaleIPs.join(', ');
      this.tailscaleError = status.lastError;
      this.tailscaleHealth = status.health;
      this.tailscaleRecentLogs = status.recentLogs;
      if (status.backendState === 'Running') {
        this.tailscaleAuthUrl = '';
      } else if (status.authUrl.length > 0) {
        this.tailscaleAuthUrl = status.authUrl;
      }
      await this.refreshTailscaleControl();
    } catch (_err) {
    }
  }

  private tailscaleStateLabel(): string {
    if (this.tailscaleState === 'Running') {
      return '已连接';
    }
    if (this.tailscaleState === 'NeedsLogin') {
      return '待登录';
    }
    if (this.tailscaleState === 'Starting' || this.tailscaleState === 'NoState') {
      return '启动中';
    }
    if (this.tailscaleState === 'Error' || this.tailscaleError.length > 0) {
      return '异常';
    }
    if (this.tailscaleState === 'Stopped') {
      return '已停止';
    }
    return '等待中';
  }

  private tailscaleStateColor(): string {
    if (this.tailscaleState === 'Running') {
      return '#0F766E';
    }
    if (this.tailscaleState === 'Error' || this.tailscaleError.length > 0) {
      return '#DC2626';
    }
    if (this.tailscaleState === 'NeedsLogin') {
      return '#D97706';
    }
    return '#2563EB';
  }

  private tailscaleStateBgColor(): string {
    if (this.tailscaleState === 'Running') {
      return '#E6FFFB';
    }
    if (this.tailscaleState === 'Error' || this.tailscaleError.length > 0) {
      return '#FEF2F2';
    }
    if (this.tailscaleState === 'NeedsLogin') {
      return '#FFF7ED';
    }
    return '#EFF6FF';
  }

  private tailscaleRecentLogTail(): string[] {
    const startIndex: number = this.tailscaleRecentLogs.length > 10 ? this.tailscaleRecentLogs.length - 10 : 0;
    return this.tailscaleRecentLogs.slice(startIndex);
  }

  private async refreshCoreLogs(): Promise<void> {
    try {
      await this.refreshTailscaleStatus();
      const context = getContext(this) as common.Context;
      const runtimeDir: string = `${context.filesDir}/runtime`;
      const extLines: string[] = await this.readTailLines(`${runtimeDir}/vpn-extension.log`, '[VPN]', 30);
      const stderrLines: string[] = await this.readTailLines(`${runtimeDir}/go-runtime-stderr.log`, '[GO]', 30);
      const coreLines: string[] = await this.readTailLines(`${runtimeDir}/mihomo-core.log`, '', 120);
      const merged: string[] = [];
      for (let i = 0; i < extLines.length; i++) {
        merged.push(extLines[i]);
      }
      for (let i = 0; i < stderrLines.length; i++) {
        merged.push(stderrLines[i]);
      }
      for (let i = 0; i < coreLines.length; i++) {
        merged.push(coreLines[i]);
      }
      const startIndex: number = merged.length > 100 ? merged.length - 100 : 0;
      this.coreLogLines = merged.slice(startIndex);
      if (this.tailscaleAuthUrl.length === 0 && this.tailscaleState !== 'Running') {
        const allCoreLines: string[] = await this.readTailLines(`${runtimeDir}/mihomo-core.log`, '', 2000);
        const fallbackUrl: string = this.extractTailscaleAuthUrl(allCoreLines);
        if (fallbackUrl.length > 0) {
          this.tailscaleAuthUrl = fallbackUrl;
        }
      }
    } catch (_err) {
      this.coreLogLines = [];
    }
  }

  private extractTailscaleAuthUrl(lines: string[]): string {
    for (let index = lines.length - 1; index >= 0; index--) {
      const line: string = lines[index];
      let urlIndex: number = line.indexOf('https://login.tailscale.com/');
      if (urlIndex < 0 && (line.indexOf('authenticate') >= 0 || line.indexOf('visit:') >= 0 || line.indexOf('[Tailscale]') >= 0)) {
        urlIndex = line.indexOf('https://');
        if (urlIndex < 0) {
          urlIndex = line.indexOf('http://');
        }
      }
      if (urlIndex >= 0) {
        const tail: string = line.substring(urlIndex);
        const spaceIdx: number = tail.search(/[\s"'<>()\]}]/);
        return spaceIdx > 0 ? tail.substring(0, spaceIdx) : tail;
      }
    }
    return '';
  }

  private async copyTailscaleAuthUrl(): Promise<void> {
    if (this.tailscaleAuthUrl.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.tailscaleAuthUrl);
      await pasteboard.getSystemPasteboard().setData(data);
      this.statusMessage = '已复制 Tailscale 登录链接';
      this.tsBusyMessage = '已复制 Tailscale 登录链接到剪贴板';
      this.recordLog('info', '已复制 Tailscale 登录链接到剪贴板');
    } catch (_err) {
      this.statusMessage = '复制 Tailscale 登录链接失败';
    }
  }

  private async openTailscaleAuthUrlInBrowser(): Promise<void> {
    if (this.tailscaleAuthUrl.length === 0) {
      return;
    }
    const targetUrl: string = this.tailscaleAuthUrl;
    try {
      const uiContext = getContext(this) as common.UIAbilityContext;
      await uiContext.openLink(targetUrl, { appLinkingOnly: false });
      this.statusMessage = '已调起系统浏览器进行 Tailscale 授权';
      this.tsBusyMessage = '已调起系统浏览器，请完成登录后返回本应用';
      this.recordLog('info', '已通过系统浏览器打开 Tailscale 登录链接');
      return;
    } catch (_openErr) {
    }
    try {
      const uiContext = getContext(this) as common.UIAbilityContext;
      await uiContext.startAbility({
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: targetUrl
      });
      this.statusMessage = '已调起系统浏览器进行 Tailscale 授权';
      this.tsBusyMessage = '已调起系统浏览器，请完成登录后返回本应用';
      this.recordLog('info', '已通过系统浏览器打开 Tailscale 登录链接');
    } catch (_wantErr) {
      await this.copyTailscaleAuthUrl();
      this.statusMessage = '无法直接拉起浏览器，已自动复制链接，请手动粘贴打开';
      this.tsBusyMessage = '无法直接拉起浏览器，已自动复制链接，请手动粘贴打开';
    }
  }

  private formatLogTime(date: Date): string {
    const hours: string = date.getHours() < 10 ? `0${date.getHours()}` : `${date.getHours()}`;
    const minutes: string = date.getMinutes() < 10 ? `0${date.getMinutes()}` : `${date.getMinutes()}`;
    const seconds: string = date.getSeconds() < 10 ? `0${date.getSeconds()}` : `${date.getSeconds()}`;
    return `${hours}:${minutes}:${seconds}`;
  }

  private normalizeProxyMode(mode: string): 'rule' | 'global' | 'direct' {
    if (mode === 'global' || mode === 'direct') {
      return mode;
    }
    return 'rule';
  }

  private modeLabel(mode: string): string {
    if (mode === 'global') {
      return '全局';
    }
    if (mode === 'direct') {
      return '直连';
    }
    return '规则';
  }

  private formatGroupDelay(group: ProxyGroupInfo, name: string): string {
    return this.getCachedProxyDelayState(name).delay;
  }

  private currentProxyLabel(): string {
    if (!this.isRuntimeConnected()) {
      return '未连接';
    }
    const group: ProxyGroupInfo | undefined = this.findRuntimeProxyGroup();
    if (group && group.now.length > 0) {
      return `${group.name} -> ${group.now}`;
    }
    if (this.pendingProxyGroup.length > 0 && this.pendingProxyName.length > 0) {
      return `${this.pendingProxyGroup} -> ${this.pendingProxyName}`;
    }
    return this.isRuntimeConnected() ? '等待策略组同步' : '未连接';
  }

  private isRuntimeConnected(): boolean {
    return this.vpnTunnelActive;
  }

  private currentProfileDisplayName(state?: ProfileState): string {
    const targetState: ProfileState = state ? state : this.profileState;
    const current: ClashProfile | undefined = CoreService.getCurrentProfile(targetState);
    if (current) {
      return current.name;
    }
    if (this.summary.profileName.length > 0 && this.summary.profileName !== '未选择配置') {
      return this.summary.profileName;
    }
    if (this.runtimeConfigInfo.length > 0 && this.runtimeConfigInfo !== '尚未生成运行配置') {
      const separator: number = this.runtimeConfigInfo.indexOf(' · ');
      return separator > 0 ? this.runtimeConfigInfo.substring(0, separator) : this.runtimeConfigInfo;
    }
    return this.isRuntimeConnected() ? '当前运行配置' : '未选择配置';
  }

  private runtimeConfigDisplayState(): string {
    if (this.runtimeConfigInfo !== '尚未生成运行配置') {
      return '已准备';
    }
    return this.isRuntimeConnected() ? '已加载' : '未准备';
  }

  private syncHomeRuntimeFields(state?: ProfileState): void {
    const connected: boolean = this.isRuntimeConnected();
    this.liveConnected = connected;
    this.liveUptime = connected ? this.summary.uptime : '未连接';
    this.liveDownloadSpeed = connected ? this.summary.downloadSpeed : '0 KB/s';
    this.liveUploadSpeed = connected ? this.summary.uploadSpeed : '0 KB/s';
    this.liveConnections = connected ? this.summary.connections : 0;
    this.liveProfileName = this.currentProfileDisplayName(state);
    this.liveProxyName = this.currentProxyLabel();
    this.liveRuntimeConfigState = this.runtimeConfigDisplayState();
    this.liveRefreshToken = this.liveRefreshToken + 1;
  }

  private parseControllerMode(raw: string): 'rule' | 'global' | 'direct' {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const mode = parsed['mode'];
      return typeof mode === 'string' ? this.normalizeProxyMode(mode as string) : 'rule';
    } catch (err) {
      return 'rule';
    }
  }

  private readJsonNumber(raw: string, key: string): number {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const value = parsed[key];
      if (typeof value === 'number') {
        return value as number;
      }
      if (typeof value === 'string') {
        const parsedValue: number = Number(value as string);
        return Number.isFinite(parsedValue) ? parsedValue : 0;
      }
      return 0;
    } catch (err) {
      return 0;
    }
  }

  private resetHomeTrafficBaseline(): void {
    this.homeLastDownloadTotal = 0;
    this.homeLastUploadTotal = 0;
    this.homeLastActiveDownloadTotal = 0;
    this.homeLastActiveUploadTotal = 0;
    this.homeLastPollAt = 0;
    this.homeTrafficBaselineReady = false;
  }

  private sumConnectionDownload(connections: ControllerConnectionInfo[]): number {
    let total: number = 0;
    for (let index = 0; index < connections.length; index++) {
      total += Math.max(0, connections[index].download);
    }
    return total;
  }

  private sumConnectionUpload(connections: ControllerConnectionInfo[]): number {
    let total: number = 0;
    for (let index = 0; index < connections.length; index++) {
      total += Math.max(0, connections[index].upload);
    }
    return total;
  }

  private formatRuntimeUptime(): string {
    if (this.connectedAt <= 0) {
      return '刚刚启动';
    }
    const seconds: number = Math.floor((Date.now() - this.connectedAt) / 1000);
    return CoreService.formatUptime(seconds);
  }

  private formatBytes(bytes: number): string {
    if (bytes < 1024) {
      return `${bytes} B`;
    }
    if (bytes < 1024 * 1024) {
      return `${(bytes / 1024).toFixed(1)} KB`;
    }
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }

  private formatSpeedValue(bytesPerSecond: number): string {
    if (bytesPerSecond < 1024) {
      return `${bytesPerSecond.toFixed(1)} B/s`;
    }
    if (bytesPerSecond < 1024 * 1024) {
      return `${(bytesPerSecond / 1024).toFixed(1)} KB/s`;
    }
    return `${(bytesPerSecond / 1024 / 1024).toFixed(1)} MB/s`;
  }

  // ============== Phase 1: Profile Version Management, Editor & Diff ==============
  private findProfileByUid(uid: string): ClashProfile | undefined {
    for (let i = 0; i < this.profileState.items.length; i++) {
      if (this.profileState.items[i].uid === uid) {
        return this.profileState.items[i];
      }
    }
    return undefined;
  }

  private async loadProfileWorkspaceData(uid: string): Promise<void> {
    const profile: ClashProfile | undefined = this.findProfileByUid(uid);
    if (!profile) {
      return;
    }
    const context = getContext(this) as common.Context;
    const manifest: ProfileVersionManifest = await ProfileVersionService.loadManifest(context, profile);
    const text: string = await ProfileVersionService.readCurrentText(context, profile);
    this.editingProfileUid = profile.uid;
    this.editingProfileName = profile.name;
    this.versionHistory = ProfileVersionService.reversedVersions(manifest);
    this.activeVersionNumber = manifest.activeVersion;
    this.editorBaseText = text;
    this.editorDraftText = text;
    this.editorCommitNote = '';
    this.editorValidationChecked = false;
    this.editorValidationOk = false;
    this.editorValidationLine = 0;
    this.editorValidationMessage = '';
    this.editorValidationWarnings = [];
    this.editorValidationStats = '';
    this.editorSaveBanner = '';
    this.editorSaveBannerOk = true;
    this.showDiffPanel = false;
    this.diffLines = [];
    this.trafficAnalysis = TrafficRuleAnalyzerService.analyze(text);
    if (this.simQuery.trim().length > 0) {
      this.simResult = TrafficRuleAnalyzerService.simulateRoute(this.trafficAnalysis, this.simQuery, this.proxyMode);
    }
  }

  private async openProfileWorkspace(uid: string, subTab: string, expandHistory: boolean = false): Promise<void> {
    await this.loadProfileWorkspaceData(uid);
    if (expandHistory) {
      this.showVersionHistory = true;
    }
    this.profileSubTab = subTab;
    this.currentTab = 'profiles';
  }

  private async runKernelValidateDraft(): Promise<ConfigValidationResult> {
    const context = getContext(this) as common.Context;
    const mergedText: string = await RuntimeConfigService.buildMergedRuntimeYaml(context, this.editorDraftText);
    const res: ConfigValidationResult = CoreBridgeService.validateConfig(mergedText);
    this.editorValidationChecked = true;
    this.editorValidationOk = res.ok;
    this.editorValidationLine = res.line;
    this.editorValidationWarnings = res.warnings;
    if (res.ok) {
      this.editorValidationMessage = 'Mihomo 融合内核语法校验通过';
      this.editorValidationStats = `${res.proxyCount} 节点 · ${res.groupCount} 策略组 · ${res.ruleCount} 规则 · DNS ${res.dnsMode}${res.hasTailscale ? ' · 含 Tailscale' : ''}`;
    } else {
      this.editorValidationMessage = res.line > 0 ? `第 ${res.line} 行错误：${res.error}` : res.error;
      this.editorValidationStats = '';
    }
    return res;
  }

  private previewDraftDiff(): void {
    const summary: DiffSummary = YamlDiffService.computeDiff(this.editorBaseText, this.editorDraftText);
    this.diffTitle = `当前草稿 vs 激活版本 v${this.activeVersionNumber}`;
    this.diffSummaryText = summary.changed
      ? `+${summary.added} 行新增 / -${summary.removed} 行删除`
      : '与当前激活版本完全一致（无变更）';
    this.diffLines = summary.lines;
    this.showDiffPanel = true;
  }

  private async compareHistoryVersion(version: number): Promise<void> {
    const profile: ClashProfile | undefined = this.findProfileByUid(this.editingProfileUid);
    if (!profile) {
      return;
    }
    const context = getContext(this) as common.Context;
    const manifest: ProfileVersionManifest = await ProfileVersionService.loadManifest(context, profile);
    const entry: ProfileVersionEntry | undefined = ProfileVersionService.findVersion(manifest, version);
    if (!entry) {
      return;
    }
    const oldText: string = await ProfileVersionService.readVersionText(entry.filePath);
    const summary: DiffSummary = YamlDiffService.computeDiff(oldText, this.editorBaseText);
    this.diffTitle = `历史版本 v${version} -> 当前版本 v${this.activeVersionNumber}`;
    this.diffSummaryText = summary.changed
      ? `+${summary.added} 行新增 / -${summary.removed} 行删除`
      : '两个版本内容完全一致';
    this.diffLines = summary.lines;
    this.showDiffPanel = true;
  }

  private visibleDiffLines(): DiffLine[] {
    if (!this.diffContextOnly) {
      return this.diffLines;
    }
    return YamlDiffService.filterChangedContext(this.diffLines, 3);
  }

  private async saveDraftAsNewVersion(): Promise<void> {
    if (this.isSavingDraft) {
      return;
    }
    const profile: ClashProfile | undefined = this.findProfileByUid(this.editingProfileUid);
    if (!profile) {
      this.editorSaveBannerOk = false;
      this.editorSaveBanner = '请先在配置列表中选择一个配置';
      this.statusMessage = this.editorSaveBanner;
      return;
    }
    if (this.editorDraftText === this.editorBaseText) {
      this.editorSaveBannerOk = false;
      this.editorSaveBanner = `内容与当前版本 v${this.activeVersionNumber} 完全一致，无需重复保存`;
      this.statusMessage = this.editorSaveBanner;
      return;
    }

    this.isSavingDraft = true;
    this.editorSaveBannerOk = true;
    this.editorSaveBanner = '正在执行融合校验并保存...';
    try {
      const validation: ConfigValidationResult = await this.runKernelValidateDraft();
      if (!validation.ok) {
        this.editorSaveBannerOk = false;
        this.editorSaveBanner = `校验未通过，已阻止保存：${this.editorValidationMessage}`;
        this.statusMessage = this.editorSaveBanner;
        this.recordLog('warn', this.statusMessage);
        return;
      }
      const context = getContext(this) as common.Context;
      const note: string = this.editorCommitNote.trim().length > 0 ? this.editorCommitNote.trim() : '在线编辑保存';
      const commit: VersionCommitResult = await ProfileVersionService.commitNewVersion(
        context,
        profile,
        this.editorDraftText,
        'edit',
        note
      );
      if (!commit.ok) {
        this.editorSaveBannerOk = false;
        this.editorSaveBanner = commit.message;
        this.statusMessage = commit.message;
        return;
      }
      this.applyProfileState(commit.state);
      this.versionHistory = ProfileVersionService.reversedVersions(commit.manifest);
      this.activeVersionNumber = commit.version;
      this.editorBaseText = this.editorDraftText;
      this.editorCommitNote = '';
      this.showDiffPanel = false;
      this.trafficAnalysis = TrafficRuleAnalyzerService.analyze(this.editorDraftText);
      await this.refreshProxyNodes(commit.state);
      this.editorSaveBannerOk = true;
      this.editorSaveBanner = `已保存为 v${commit.version}（融合校验通过，重连 VPN 生效）`;
      this.statusMessage = `${commit.message}（若已连接 VPN，重新连接后生效）`;
      this.recordLog('info', this.statusMessage);
    } finally {
      this.isSavingDraft = false;
    }
  }

  private async rollbackToHistoryVersion(version: number): Promise<void> {
    const profile: ClashProfile | undefined = this.findProfileByUid(this.editingProfileUid);
    if (!profile) {
      return;
    }
    const context = getContext(this) as common.Context;
    const result: VersionCommitResult = await ProfileVersionService.rollbackToVersion(context, profile, version);
    if (!result.ok) {
      this.statusMessage = result.message;
      return;
    }
    this.applyProfileState(result.state);
    await this.loadProfileWorkspaceData(profile.uid);
    await this.refreshProxyNodes(result.state);
    this.statusMessage = `已回滚至 v${version} 并生成新版本 v${result.version}`;
    this.recordLog('info', this.statusMessage);
  }

  private async loadVersionIntoEditor(version: number): Promise<void> {
    const profile: ClashProfile | undefined = this.findProfileByUid(this.editingProfileUid);
    if (!profile) {
      return;
    }
    const context = getContext(this) as common.Context;
    const manifest: ProfileVersionManifest = await ProfileVersionService.loadManifest(context, profile);
    const entry: ProfileVersionEntry | undefined = ProfileVersionService.findVersion(manifest, version);
    if (!entry) {
      return;
    }
    this.editorDraftText = await ProfileVersionService.readVersionText(entry.filePath);
    this.editorCommitNote = `基于 v${version} 修改`;
    this.profileSubTab = 'editor';
    this.statusMessage = `已载入历史版本 v${version} 到编辑器`;
  }

  // ============== Phase 2: Embedded Native Tailscale Management ==============
  private async loadTailscalePrefs(): Promise<void> {
    const context = getContext(this) as common.Context;
    const prefs: TailscaleNativePrefs = await TailscalePrefsService.load(context);
    this.tsPrefs = prefs;
    this.tsHostnameDraft = prefs.hostname;
    this.tsControlUrlDraft = prefs.controlUrl;
    this.tsAuthKeyDraft = prefs.authKey;
  }

  private async refreshTailscaleControl(): Promise<void> {
    const st: TailscaleControlStatus = await TailscaleControlService.getStatus();
    if (!st.reachable) {
      return;
    }
    this.tsControl = st;
    if (st.backendState.length > 0) {
      this.tailscaleState = st.backendState;
    }
    if (st.hostname.length > 0) {
      this.tailscaleHostname = st.hostname;
    }
    if (st.tailscaleIPs.length > 0) {
      this.tailscaleIps = st.tailscaleIPs.join(', ');
    }
    if (st.backendState === 'Running') {
      this.tailscaleAuthUrl = '';
    } else if (st.authUrl.length > 0) {
      this.tailscaleAuthUrl = st.authUrl;
    }
    if (st.lastError.length > 0) {
      this.tailscaleError = st.lastError;
    }
    const discoveredSplitDomains: string[] = [];
    for (let i = 0; i < st.splitDns.length; i++) {
      const d: string = st.splitDns[i].domain.trim().toLowerCase();
      if (d.length > 0 && discoveredSplitDomains.indexOf(d) < 0) {
        discoveredSplitDomains.push(d);
      }
    }
    const suffixChanged: boolean = st.magicDnsSuffix.length > 0 && st.magicDnsSuffix !== this.tsPrefs.tailnetSuffix;
    const splitChanged: boolean = discoveredSplitDomains.length > 0 &&
      !this.sameStringList(discoveredSplitDomains, this.tsPrefs.splitDnsDomains);
    if (suffixChanged || splitChanged) {
      const next: TailscaleNativePrefs = this.cloneTailscalePrefs(this.tsPrefs);
      if (suffixChanged) {
        next.tailnetSuffix = st.magicDnsSuffix;
      }
      if (splitChanged) {
        next.splitDnsDomains = discoveredSplitDomains;
        if (this.tsPrefs.autoSyncSplitDns && this.liveConnected) {
          this.tsSplitDnsNeedReload = true;
          this.tsBusyMessage = `已自动发现 SplitDNS 域名（${discoveredSplitDomains.join(', ')}），重连 VPN 后自动生效`;
        }
      }
      this.tsPrefs = next;
      const context = getContext(this) as common.Context;
      await TailscalePrefsService.save(context, next);
    }
  }

  private sameStringList(a: string[], b: string[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }

  private cloneTailscalePrefs(src: TailscaleNativePrefs): TailscaleNativePrefs {
    const splitCopy: string[] = [];
    for (let i = 0; i < src.splitDnsDomains.length; i++) {
      splitCopy.push(src.splitDnsDomains[i]);
    }
    return {
      managedByApp: src.managedByApp,
      enabled: src.enabled,
      proxyName: src.proxyName,
      hostname: src.hostname,
      controlUrl: src.controlUrl,
      acceptRoutes: src.acceptRoutes,
      exitNode: src.exitNode,
      exitNodeAllowLan: src.exitNodeAllowLan,
      authKey: src.authKey,
      autoInjectMagicDns: src.autoInjectMagicDns,
      tailnetSuffix: src.tailnetSuffix,
      autoSyncSplitDns: src.autoSyncSplitDns,
      splitDnsDomains: splitCopy
    };
  }

  private async saveTailscalePrefsAndApply(next: TailscaleNativePrefs, applyLive: boolean): Promise<void> {
    const context = getContext(this) as common.Context;
    this.tsPrefs = next;
    await TailscalePrefsService.save(context, next);
    if (applyLive && this.tsControl.reachable && this.tsControl.available) {
      this.tsBusyMessage = '正在向运行中的 Tailscale 内核热更新偏好...';
      const res: TailscaleActionResult = await TailscaleControlService.updatePrefs({
        hostname: next.hostname,
        acceptRoutes: next.acceptRoutes,
        exitNode: next.exitNode,
        exitNodeAllowLan: next.exitNodeAllowLan,
        controlUrl: next.controlUrl
      });
      if (res.ok && res.status) {
        this.tsControl = res.status;
        this.tsBusyMessage = '已热生效（无需重启 VPN）';
        this.recordLog('info', 'Tailscale 偏好已热更新');
      } else {
        this.tsBusyMessage = `已保存本地配置（热更新提示：${res.error}）`;
        this.recordLog('warn', this.tsBusyMessage);
      }
    } else {
      this.tsBusyMessage = 'Tailscale 原生配置已保存，下次连接自动注入';
      this.recordLog('info', this.tsBusyMessage);
    }
  }

  private async toggleTsManagedByApp(): Promise<void> {
    const next: TailscaleNativePrefs = this.cloneTailscalePrefs(this.tsPrefs);
    next.managedByApp = !next.managedByApp;
    await this.saveTailscalePrefsAndApply(next, false);
  }

  private async toggleTsEnabled(): Promise<void> {
    const next: TailscaleNativePrefs = this.cloneTailscalePrefs(this.tsPrefs);
    next.enabled = !next.enabled;
    await this.saveTailscalePrefsAndApply(next, false);
  }

  private async toggleTsAcceptRoutes(): Promise<void> {
    const next: TailscaleNativePrefs = this.cloneTailscalePrefs(this.tsPrefs);
    next.acceptRoutes = !next.acceptRoutes;
    await this.saveTailscalePrefsAndApply(next, true);
  }

  private async toggleTsExitNodeAllowLan(): Promise<void> {
    const next: TailscaleNativePrefs = this.cloneTailscalePrefs(this.tsPrefs);
    next.exitNodeAllowLan = !next.exitNodeAllowLan;
    await this.saveTailscalePrefsAndApply(next, true);
  }

  private async toggleTsAutoInjectDns(): Promise<void> {
    const next: TailscaleNativePrefs = this.cloneTailscalePrefs(this.tsPrefs);
    next.autoInjectMagicDns = !next.autoInjectMagicDns;
    await this.saveTailscalePrefsAndApply(next, false);
  }

  private async toggleTsAutoSyncSplitDns(): Promise<void> {
    const next: TailscaleNativePrefs = this.cloneTailscalePrefs(this.tsPrefs);
    next.autoSyncSplitDns = !next.autoSyncSplitDns;
    await this.saveTailscalePrefsAndApply(next, false);
  }

  private async saveTsTextSettings(): Promise<void> {
    const next: TailscaleNativePrefs = this.cloneTailscalePrefs(this.tsPrefs);
    next.hostname = this.tsHostnameDraft.trim().length > 0 ? this.tsHostnameDraft.trim() : 'harmony-phone';
    next.controlUrl = this.tsControlUrlDraft.trim();
    next.authKey = this.tsAuthKeyDraft.trim();
    await this.saveTailscalePrefsAndApply(next, true);
  }

  private async selectTsExitNode(ipOrEmpty: string): Promise<void> {
    const next: TailscaleNativePrefs = this.cloneTailscalePrefs(this.tsPrefs);
    next.exitNode = ipOrEmpty;
    await this.saveTailscalePrefsAndApply(next, true);
  }

  private async routeProxyViaTailscaleExitNode(): Promise<void> {
    if (!this.controllerStatus.available) {
      this.tsBusyMessage = '请先启动 VPN 后再切换代理出口';
      return;
    }
    const targetName: string = this.tsPrefs.proxyName.length > 0 ? this.tsPrefs.proxyName : 'Tailscale';
    await MihomoControllerService.setMode('global');
    const ok: boolean = await MihomoControllerService.selectProxy('GLOBAL', targetName);
    if (ok) {
      this.proxyMode = 'global';
      this.tsBusyMessage = `已将全局流量切换至 ${targetName}（Exit Node 生效）`;
      this.recordLog('info', this.tsBusyMessage);
    } else {
      this.tsBusyMessage = `切换 GLOBAL -> ${targetName} 失败，请检查配置中是否包含 ${targetName}`;
    }
  }

  private async triggerTailscaleLogin(): Promise<void> {
    if (!this.tsControl.reachable) {
      this.tsBusyMessage = '请先在首页连接 VPN 启动 Tailscale 核心';
      return;
    }
    this.tsBusyMessage = '正在请求交互式登录链接...';
    const res: TailscaleActionResult = await TailscaleControlService.startLogin();
    if (res.ok) {
      if (res.status) {
        this.tsControl = res.status;
      }
      await this.refreshTailscaleStatus();
      this.tsBusyMessage = '已触发登录，请复制上方登录链接在浏览器授权';
    } else {
      this.tsBusyMessage = `触发登录失败：${res.error}`;
    }
  }

  private async triggerTailscaleLogout(): Promise<void> {
    if (!this.tsControl.reachable) {
      this.tsBusyMessage = '请先连接 VPN 后再执行登出';
      return;
    }
    this.tsBusyMessage = '正在登出 Tailscale 节点...';
    const res: TailscaleActionResult = await TailscaleControlService.logout();
    if (res.ok) {
      if (res.status) {
        this.tsControl = res.status;
      }
      await this.refreshTailscaleStatus();
      this.tsBusyMessage = '已登出，可点击「重新登录」切换账号';
      this.recordLog('info', 'Tailscale 节点已登出');
    } else {
      this.tsBusyMessage = `登出失败：${res.error}`;
    }
  }

  private async pingTailscalePeer(peer: TailscalePeerItem): Promise<void> {
    if (peer.tailscaleIPs.length === 0) {
      return;
    }
    const ip: string = peer.tailscaleIPs[0];
    this.tsPeerPingResults[peer.id] = 'Ping 中...';
    this.tsPingRefreshTick = this.tsPingRefreshTick + 1;
    const res: TailscalePingResult = await TailscaleControlService.pingPeer(ip);
    if (res.ok) {
      const ms: string = `${Math.round(res.latencyMs)} ms`;
      this.tsPeerPingResults[peer.id] = res.direct
        ? `直连 ${ms}`
        : `DERP(${res.derpRegionCode.length > 0 ? res.derpRegionCode : 'relay'}) ${ms}`;
    } else {
      this.tsPeerPingResults[peer.id] = `失败: ${res.error}`;
    }
    this.tsPingRefreshTick = this.tsPingRefreshTick + 1;
  }

  private getPeerPingText(peerId: string): string {
    const val: string | undefined = this.tsPeerPingResults[peerId];
    return val ? val : '';
  }

  private async pingAllOnlineTailscalePeers(): Promise<void> {
    if (this.isBatchPingingPeers) {
      return;
    }
    const targets: TailscalePeerItem[] = [];
    for (let i = 0; i < this.tsControl.peers.length; i++) {
      const p: TailscalePeerItem = this.tsControl.peers[i];
      if (p.online && p.tailscaleIPs.length > 0) {
        targets.push(p);
      }
    }
    if (targets.length === 0) {
      this.batchPingProgress = '暂无在线 Tailscale 设备可测速';
      this.tsBusyMessage = this.batchPingProgress;
      return;
    }
    this.isBatchPingingPeers = true;
    this.batchPingProgress = `批量 Ping 中 0/${targets.length}...`;
    let done: number = 0;
    let reachable: number = 0;
    try {
      const tasks: Promise<void>[] = [];
      for (let i = 0; i < targets.length; i++) {
        const peer: TailscalePeerItem = targets[i];
        tasks.push((async (): Promise<void> => {
          const ip: string = peer.tailscaleIPs[0];
          this.tsPeerPingResults[peer.id] = 'Ping 中...';
          this.tsPingRefreshTick = this.tsPingRefreshTick + 1;
          const res: TailscalePingResult = await TailscaleControlService.pingPeer(ip);
          if (res.ok) {
            reachable = reachable + 1;
            const ms: string = `${Math.round(res.latencyMs)} ms`;
            this.tsPeerPingResults[peer.id] = res.direct
              ? `直连 ${ms}`
              : `DERP(${res.derpRegionCode.length > 0 ? res.derpRegionCode : 'relay'}) ${ms}`;
          } else {
            this.tsPeerPingResults[peer.id] = `超时: ${res.error}`;
          }
          done = done + 1;
          this.batchPingProgress = `批量 Ping 中 ${done}/${targets.length} (${reachable} 可达)`;
          this.tsPingRefreshTick = this.tsPingRefreshTick + 1;
        })());
      }
      await Promise.all(tasks);
      this.batchPingProgress = `批量 Ping 完成：${reachable}/${targets.length} 在线设备可达`;
      this.tsBusyMessage = this.batchPingProgress;
    } finally {
      this.isBatchPingingPeers = false;
    }
  }

  // ============== Phase 4: Self-hosted Overlay, Fail-Closed AI, Rule Test & Backup ==============
  private async loadOverlayConfig(): Promise<void> {
    const context = getContext(this) as common.Context;
    const cfg: CustomOverlayConfig = await OverlayService.load(context);
    this.overlayConfig = cfg;
    this.syncOverlayDraftsFromConfig(cfg);
  }

  private syncOverlayDraftsFromConfig(cfg: CustomOverlayConfig): void {
    this.overlayGroupNameDraft = cfg.selfHostedGroupName;
    this.overlayProxiesDraft = cfg.customProxiesYaml;
    this.overlayCustomRulesDraft = cfg.customRules.join('\n');
    this.overlayAiDomainsDraft = cfg.aiDomains.join('\n');
    this.overlayAiKeywordsDraft = cfg.aiKeywords.join(', ');
    this.overlayDirectDomainsDraft = cfg.directDomains.join(', ');
  }

  private getAiProviderPresets(): AiProviderPreset[] {
    return getAllAiProviderPresets();
  }

  private isAiProviderSelected(providerId: string): boolean {
    return this.overlayConfig.aiProviders.indexOf(providerId) >= 0;
  }

  private toggleAiProviderSelection(providerId: string): void {
    const next: CustomOverlayConfig = this.buildOverlayDraftConfig();
    const list: string[] = [];
    let removed: boolean = false;
    for (let i = 0; i < next.aiProviders.length; i++) {
      if (next.aiProviders[i] === providerId) {
        removed = true;
      } else {
        list.push(next.aiProviders[i]);
      }
    }
    if (!removed) {
      list.push(providerId);
    }
    next.aiProviders = list;
    this.overlayConfig = next;
  }

  private selectAllAiProviders(): void {
    const next: CustomOverlayConfig = this.buildOverlayDraftConfig();
    const presets: AiProviderPreset[] = getAllAiProviderPresets();
    const ids: string[] = [];
    for (let i = 0; i < presets.length; i++) {
      ids.push(presets[i].id);
    }
    next.aiProviders = ids;
    this.overlayConfig = next;
  }

  private selectCoreAiProviders(): void {
    const next: CustomOverlayConfig = this.buildOverlayDraftConfig();
    next.aiProviders = ['claude', 'gemini', 'openai'];
    this.overlayConfig = next;
  }

  private splitOverlayList(raw: string): string[] {
    const parts: string[] = raw.split(/[\r\n,;]+/);
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const s: string = parts[i].trim();
      if (s.length > 0) {
        out.push(s);
      }
    }
    return out;
  }

  private splitOverlayLines(raw: string): string[] {
    const parts: string[] = raw.split(/\r?\n/);
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const s: string = parts[i].trim();
      if (s.length > 0) {
        out.push(s);
      }
    }
    return out;
  }

  private buildOverlayDraftConfig(): CustomOverlayConfig {
    const providersCopy: string[] = [];
    for (let i = 0; i < this.overlayConfig.aiProviders.length; i++) {
      providersCopy.push(this.overlayConfig.aiProviders[i]);
    }
    return OverlayService.normalizeConfig({
      enabled: this.overlayConfig.enabled,
      selfHostedGroupName: this.overlayGroupNameDraft.trim().length > 0 ? this.overlayGroupNameDraft.trim() : DEFAULT_AI_GROUP_NAME,
      failClosed: this.overlayConfig.failClosed,
      aiStrictEnabled: this.overlayConfig.aiStrictEnabled,
      aiProviders: providersCopy,
      aiDomains: this.splitOverlayList(this.overlayAiDomainsDraft),
      aiKeywords: this.splitOverlayList(this.overlayAiKeywordsDraft),
      customProxiesYaml: this.overlayProxiesDraft,
      customRules: this.splitOverlayLines(this.overlayCustomRulesDraft),
      directDomains: this.splitOverlayList(this.overlayDirectDomainsDraft)
    });
  }

  private toggleOverlayEnabled(): void {
    const next: CustomOverlayConfig = this.buildOverlayDraftConfig();
    next.enabled = !next.enabled;
    this.overlayConfig = next;
  }

  private toggleOverlayAiStrict(): void {
    const next: CustomOverlayConfig = this.buildOverlayDraftConfig();
    next.aiStrictEnabled = !next.aiStrictEnabled;
    this.overlayConfig = next;
  }

  private toggleOverlayAiFailClosed(): void {
    const next: CustomOverlayConfig = this.buildOverlayDraftConfig();
    next.failClosed = !next.failClosed;
    this.overlayConfig = next;
  }

  private insertSelfHostedVlessTemplate(): void {
    const tpl: string = [
      '- name: 东京自建稳定出口',
      '  type: vless',
      '  server: your-node.example.com',
      '  port: 443',
      '  uuid: 00000000-0000-0000-0000-000000000000',
      '  network: ws',
      '  tls: true',
      '  udp: true',
      '  servername: your-node.example.com',
      '  client-fingerprint: chrome',
      '  ws-opts:',
      '    path: /ws',
      '    headers:',
      '      Host: your-node.example.com'
    ].join('\n');
    const cur: string = this.overlayProxiesDraft.trim();
    this.overlayProxiesDraft = cur.length > 0 ? `${cur}\n${tpl}` : tpl;
    this.overlayBannerOk = true;
    this.overlayBanner = '已填入 VLESS 模板，也可直接粘贴 vless:// / trojan:// / ss:// 分享链接';
  }

  private async saveOverlayConfig(): Promise<void> {
    if (this.isSavingOverlay) {
      return;
    }
    this.isSavingOverlay = true;
    this.overlayBannerOk = true;
    this.overlayBanner = '正在解析自建节点并执行融合校验...';
    try {
      const context = getContext(this) as common.Context;
      const next: CustomOverlayConfig = this.buildOverlayDraftConfig();
      // Auto-enable when user fills self-hosted nodes and clicks save
      if (!next.enabled && next.customProxiesYaml.trim().length > 0) {
        next.enabled = true;
      }
      const parsed: ParsedCustomProxies = OverlayService.parseCustomProxiesYaml(next.customProxiesYaml);

      // Pre-validate merged runtime YAML with current profile (if any)
      const current: ClashProfile | undefined = CoreService.getCurrentProfile(this.profileState);
      if (current && current.filePath.length > 0) {
        try {
          if (await fileIo.access(current.filePath)) {
            const rawYaml: string = await fileIo.readText(current.filePath);
            const mergedYaml: string = await RuntimeConfigService.buildMergedRuntimeYaml(context, rawYaml, next);
            const check: ConfigValidationResult = CoreBridgeService.validateConfig(mergedYaml);
            if (!check.ok) {
              this.overlayBannerOk = false;
              this.overlayBanner = `融合校验失败${check.line > 0 ? ` (第 ${check.line} 行)` : ''}：${check.error}`;
              this.statusMessage = this.overlayBanner;
              return;
            }
          }
        } catch (_err) {
        }
      }

      const saved: boolean = await OverlayService.save(context, next);
      if (!saved) {
        this.overlayBannerOk = false;
        this.overlayBanner = '保存覆写配置失败，请检查存储空间';
        return;
      }
      this.overlayConfig = next;
      this.syncOverlayDraftsFromConfig(next);
      const modeDesc: string = !next.enabled
        ? 'AI 自建覆写已关闭'
        : (next.aiStrictEnabled && next.failClosed
          ? (parsed.names.length > 0
            ? `已选 ${next.aiProviders.length} 家 AI 严格走 [${parsed.names.join(', ')}]，不可达直接断开`
            : `已选 ${next.aiProviders.length} 家 AI（未填自建节点，Fail-Closed 直接 REJECT）`)
          : '已应用自定义规则');
      this.overlayBannerOk = true;
      this.overlayBanner = `保存成功！自建节点 ${parsed.names.length} 个 · ${modeDesc}（重连 VPN 生效）`;
      this.statusMessage = this.overlayBanner;
      this.recordLog('info', this.overlayBanner);
    } finally {
      this.isSavingOverlay = false;
    }
  }

  private async exportCrossPlatformBackup(sanitize: boolean): Promise<void> {
    const context = getContext(this) as common.Context;
    const jsonText: string = await OverlayService.exportBackupBundleJson(context, sanitize);
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, jsonText);
      await pasteboard.getSystemPasteboard().setData(data);
      this.overlayBannerOk = true;
      this.overlayBanner = sanitize
        ? '已复制脱敏迁移包 JSON 到剪贴板（可导入 Windows 版或分享）'
        : '已复制完整迁移包 JSON 到剪贴板（含自建节点/AI规则/Tailscale/订阅，可导入 Windows 版）';
      this.statusMessage = this.overlayBanner;
    } catch (_err) {
      this.overlayBannerOk = false;
      this.overlayBanner = '复制到剪贴板失败';
    }
  }

  private async importCrossPlatformBackupFromClipboard(): Promise<void> {
    try {
      const data: pasteboard.PasteData = await pasteboard.getSystemPasteboard().getData();
      const rawText: string = data.getPrimaryText();
      if (!rawText || rawText.trim().length === 0) {
        this.overlayBannerOk = false;
        this.overlayBanner = '剪贴板为空，请先复制从 Windows 版或手机导出的 JSON 迁移包';
        return;
      }
      const context = getContext(this) as common.Context;
      const res: BackupImportResult = await OverlayService.importBackupBundleJson(context, rawText);
      this.overlayBannerOk = res.ok;
      this.overlayBanner = res.message;
      this.statusMessage = res.message;
      if (res.ok) {
        await this.loadOverlayConfig();
        await this.loadTailscalePrefs();
        const nextState: ProfileState = await ProfileStore.load(context);
        this.applyProfileState(nextState);
        await this.refreshProxyNodes(nextState);
        if (nextState.currentUid.length > 0) {
          await this.loadProfileWorkspaceData(nextState.currentUid);
        }
      }
    } catch (_err) {
      this.overlayBannerOk = false;
      this.overlayBanner = '读取剪贴板失败，请检查剪贴板权限';
    }
  }

  private async runProxyRuleTest(customTarget?: string): Promise<void> {
    const target: string = (customTarget !== undefined ? customTarget : this.proxyRuleTestInput).trim();
    if (customTarget !== undefined) {
      this.proxyRuleTestInput = target;
    }
    if (target.length === 0) {
      this.proxyRuleTestOk = false;
      this.proxyRuleTestIsReject = false;
      this.proxyRuleTestResult = '请输入待测域名、URL 或 IP';
      this.proxyRuleTestDetail = '';
      return;
    }
    this.proxyRuleTestResult = `正在测试 ${target} 规则命中...`;
    this.proxyRuleTestDetail = '';

    // 1. Prefer live Mihomo rule engine when core is running
    const live: LiveRuleTestResult = await TailscaleControlService.testRule(target, 443, 'tcp');
    if (live.ok) {
      const chainText: string = live.proxyChain.length > 0 ? live.proxyChain.join(' → ') : live.finalOutbound;
      const isRej: boolean = live.finalOutbound.toUpperCase() === 'REJECT' || live.finalType.toLowerCase() === 'reject';
      this.proxyRuleTestOk = true;
      this.proxyRuleTestIsReject = isRej;
      this.proxyRuleTestResult = `实时内核命中：${live.ruleRaw}`;
      this.proxyRuleTestDetail = `链路：${chainText} (${live.finalType}) · 模式：${live.mode}`;
      return;
    }

    // 2. Fallback to offline simulation on merged runtime YAML (including Overlay + Tailscale)
    const context = getContext(this) as common.Context;
    let sourceYaml: string = this.editorBaseText;
    if (sourceYaml.trim().length === 0) {
      const current: ClashProfile | undefined = CoreService.getCurrentProfile(this.profileState);
      if (current && current.filePath.length > 0) {
        try {
          if (await fileIo.access(current.filePath)) {
            sourceYaml = await fileIo.readText(current.filePath);
          }
        } catch (_err) {
        }
      }
    }
    if (sourceYaml.trim().length === 0) {
      this.proxyRuleTestOk = false;
      this.proxyRuleTestIsReject = false;
      this.proxyRuleTestResult = live.error.length > 0 ? live.error : '请先导入配置或启动 VPN';
      this.proxyRuleTestDetail = '';
      return;
    }
    const mergedYaml: string = await RuntimeConfigService.buildMergedRuntimeYaml(context, sourceYaml);
    const analysis: TrafficAnalysis = TrafficRuleAnalyzerService.analyze(mergedYaml);
    const sim: RouteSimulationResult = TrafficRuleAnalyzerService.simulateRoute(analysis, target, this.proxyMode);
    this.proxyRuleTestOk = true;
    this.proxyRuleTestIsReject = sim.category === 'reject';
    this.proxyRuleTestResult = `离线融合模拟：${sim.matchedRuleRaw}`;
    this.proxyRuleTestDetail = `链路：${sim.chain.join(' → ')} · DNS：${sim.dnsNote}`;
  }

  private async runAllGroupsSpeedTest(): Promise<void> {
    if (this.isSpeedTesting) {
      this.statusMessage = '测速正在进行，请稍候';
      return;
    }
    this.isSpeedTesting = true;
    this.speedTestSummary = '';
    this.speedTestProgress = '准备全量测速所有策略组...';
    this.statusMessage = this.speedTestProgress;
    await this.waitForUiUpdate(50);

    try {
      const ready: boolean = await this.ensureControllerReadyForProxyActions('全组测速');
      if (!ready) {
        this.speedTestProgress = '全组测速未开始：controller 未就绪';
        this.speedTestSummary = this.speedTestProgress;
        return;
      }

      const uniqueNames: string[] = [];
      const seen: Record<string, boolean> = {};
      for (let g = 0; g < this.proxyGroups.length; g++) {
        const grp: ProxyGroupInfo = this.proxyGroups[g];
        if (grp.name === 'GLOBAL') {
          continue;
        }
        for (let j = 0; j < grp.all.length; j++) {
          const name: string = grp.all[j];
          if (name === 'DIRECT' || name === 'REJECT' || seen[name]) {
            continue;
          }
          seen[name] = true;
          uniqueNames.push(name);
        }
      }
      if (uniqueNames.length === 0) {
        this.speedTestProgress = '没有可测速节点';
        this.statusMessage = this.speedTestProgress;
        return;
      }

      let tested: number = 0;
      let reachable: number = 0;
      let timeout: number = 0;
      const batchSize: number = 12;
      this.speedTestProgress = `全组测速中 0/${uniqueNames.length}...`;

      for (let offset = 0; offset < uniqueNames.length; offset += batchSize) {
        const end: number = offset + batchSize > uniqueNames.length ? uniqueNames.length : offset + batchSize;
        const batchNames: string[] = [];
        const tasks: Promise<number>[] = [];
        for (let i = offset; i < end; i++) {
          const n: string = uniqueNames[i];
          batchNames.push(n);
          tasks.push(this.measureProxyNodeDelay({ name: n, meta: '', delay: '测试中...' }));
        }
        const delays: number[] = await Promise.all(tasks);
        const updates: ProxyDelayUpdate[] = [];
        for (let i = 0; i < delays.length; i++) {
          const fmt = TcpDelayTestService.formatDelay(delays[i]);
          updates.push({ name: batchNames[i], delay: fmt.delay, status: fmt.status });
          tested = tested + 1;
          if (delays[i] > 0) {
            reachable = reachable + 1;
          } else {
            timeout = timeout + 1;
          }
        }
        this.updateProxyNodeDelayBatch(updates);
        this.speedTestProgress = `全组测速 ${tested}/${uniqueNames.length} · ${reachable} 可达 · ${timeout} 超时`;
        this.statusMessage = this.speedTestProgress;
        await this.waitForUiUpdate(0);
      }
      this.speedTestSummary = `全组测速完成 ${tested} 节点 · ${reachable} 可达 · ${timeout} 超时`;
      this.speedTestProgress = this.speedTestSummary;
      this.statusMessage = this.speedTestSummary;
      this.applySelectedProxyGroup();
      this.rebuildHomeActiveNodes();
    } finally {
      this.isSpeedTesting = false;
    }
  }

  // ============== Phase 5: PC-aligned Home Telemetry, Max-2-Card Profiles & QR Scan Sync ==============
  private collectProfileUids(state: ProfileState): string[] {
    const out: string[] = [];
    for (let i = 0; i < state.items.length; i++) {
      out.push(state.items[i].uid);
    }
    return out;
  }

  private trackNewlyImportedPendingUid(prevUids: string[], nextState: ProfileState): void {
    if (prevUids.length === 0) {
      return;
    }
    for (let i = nextState.items.length - 1; i >= 0; i--) {
      const uid: string = nextState.items[i].uid;
      if (prevUids.indexOf(uid) < 0 && uid !== nextState.currentUid) {
        this.pendingProfileUid = uid;
        return;
      }
    }
  }

  private getCurrentActiveProfile(): ClashProfile | undefined {
    return CoreService.getCurrentProfile(this.profileState);
  }

  private getPendingProfile(): ClashProfile | undefined {
    if (this.pendingProfileUid.length === 0 || this.pendingProfileUid === this.profileState.currentUid) {
      return undefined;
    }
    return this.findProfileByUid(this.pendingProfileUid);
  }

  private getOtherSavedProfiles(): ClashProfile[] {
    const out: ClashProfile[] = [];
    for (let i = 0; i < this.profileState.items.length; i++) {
      const p: ClashProfile = this.profileState.items[i];
      if (p.uid === this.profileState.currentUid) {
        continue;
      }
      if (this.pendingProfileUid.length > 0 && p.uid === this.pendingProfileUid) {
        continue;
      }
      out.push(p);
    }
    return out;
  }

  private async scanQrSyncFromPc(): Promise<void> {
    if (this.isQrSyncing) {
      return;
    }
    this.isQrSyncing = true;
    this.qrSyncBanner = '';
    try {
      const context = getContext(this) as common.Context;
      const scanRes: scanBarcode.ScanResult = await scanBarcode.startScanForResult(context, {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: true
      });
      const rawVal: string = scanRes && scanRes.originalValue ? scanRes.originalValue.trim() : '';
      if (rawVal.length === 0) {
        this.qrSyncBannerOk = false;
        this.qrSyncBanner = '未识别到二维码内容';
        return;
      }
      this.qrSyncBannerOk = true;
      this.qrSyncBanner = '已扫码，正在从电脑拉取配置...';
      const res: BackupImportResult = await OverlayService.importFromQrSyncText(context, rawVal);
      this.qrSyncBannerOk = res.ok;
      this.qrSyncBanner = res.message;
      this.statusMessage = res.message;
      this.recordLog(res.ok ? 'info' : 'warn', res.message);
      if (res.ok) {
        await this.loadOverlayConfig();
        await this.loadTailscalePrefs();
        const nextState: ProfileState = await ProfileStore.load(context);
        if (!res.activated && res.importedProfileUid.length > 0 && res.importedProfileUid !== nextState.currentUid) {
          this.pendingProfileUid = res.importedProfileUid;
        }
        this.applyProfileState(nextState);
        await this.refreshProxyNodes(nextState);
        if (nextState.currentUid.length > 0) {
          await this.loadProfileWorkspaceData(nextState.currentUid);
        }
      }
    } catch (_err) {
      this.qrSyncBannerOk = false;
      this.qrSyncBanner = '已取消扫码或扫码服务不可用';
    } finally {
      this.isQrSyncing = false;
    }
  }

  private async scanQrToFillUrl(target: string): Promise<void> {
    try {
      const context = getContext(this) as common.Context;
      const scanRes: scanBarcode.ScanResult = await scanBarcode.startScanForResult(context, {
        scanTypes: [scanCore.ScanType.QR_CODE],
        enableMultiMode: false,
        enableAlbum: true
      });
      const rawVal: string = scanRes && scanRes.originalValue ? scanRes.originalValue.trim() : '';
      if (rawVal.length === 0) {
        this.statusMessage = '未识别到二维码内容';
        return;
      }

      let extractedUrl: string = rawVal;
      let extractedName: string = '';
      const lower: string = rawVal.toLowerCase();
      if (lower.startsWith('clash://') || lower.startsWith('clashmeta://') || lower.startsWith('mihomo://')) {
        const qIdx: number = rawVal.indexOf('?');
        if (qIdx >= 0) {
          const pairs: string[] = rawVal.substring(qIdx + 1).split('&');
          for (let i = 0; i < pairs.length; i++) {
            const eq: number = pairs[i].indexOf('=');
            if (eq <= 0) {
              continue;
            }
            const key: string = pairs[i].substring(0, eq).trim().toLowerCase();
            const rawParam: string = pairs[i].substring(eq + 1).trim();
            let decoded: string = rawParam;
            try {
              decoded = decodeURIComponent(rawParam.replace(/\+/g, ' '));
            } catch (_e) {
              decoded = rawParam;
            }
            if (key === 'url' && decoded.length > 0) {
              extractedUrl = decoded.trim();
            } else if (key === 'name' && decoded.length > 0) {
              extractedName = decoded.trim();
            }
          }
        }
      }

      if (target === 'edit') {
        this.editingSubMetaUrl = extractedUrl;
        if (this.editingSubMetaName.trim().length === 0 && extractedName.length > 0) {
          this.editingSubMetaName = extractedName;
        }
      } else {
        this.importUrl = extractedUrl;
        if (this.importName.trim().length === 0 && extractedName.length > 0) {
          this.importName = extractedName;
        }
      }
      this.statusMessage = extractedUrl.startsWith('http://') || extractedUrl.startsWith('https://')
        ? '已扫码填入订阅 URL'
        : '已扫码填入内容，请确认是否为有效订阅 URL';
      this.recordLog('info', this.statusMessage);
    } catch (_err) {
      this.statusMessage = '已取消扫码或扫码服务不可用';
    }
  }

  private resolveFinalGroupNode(startName: string): string {
    let cur: string = startName;
    const visited: string[] = [];
    for (let depth = 0; depth < 6; depth++) {
      if (cur.length === 0 || visited.indexOf(cur) >= 0) {
        break;
      }
      visited.push(cur);
      const grp: ProxyGroupInfo | undefined = this.findProxyGroupByName(cur);
      if (grp && grp.now.length > 0 && grp.now !== cur) {
        cur = grp.now;
      } else {
        break;
      }
    }
    return cur;
  }

  private rebuildHomeActiveNodes(): void {
    const aiItems: HomeActiveNodeItem[] = [];
    const mainItems: HomeActiveNodeItem[] = [];
    const otherItems: HomeActiveNodeItem[] = [];
    let hasTsItem: boolean = false;

    for (let i = 0; i < this.proxyGroups.length; i++) {
      const g: ProxyGroupInfo = this.proxyGroups[i];
      if (g.name === 'GLOBAL') {
        continue;
      }
      const finalNode: string = this.resolveFinalGroupNode(g.now);
      const delayState: ProxyDelayState = this.getCachedProxyDelayState(finalNode);
      const isAi: boolean = g.name.indexOf('AI') >= 0;
      const isTs: boolean = finalNode.toLowerCase() === 'tailscale';
      if (isTs) {
        hasTsItem = true;
      }
      const item: HomeActiveNodeItem = {
        group: g.name,
        finalNode: finalNode.length > 0 ? finalNode : '未选择',
        delay: delayState.delay,
        status: delayState.status,
        isAi: isAi,
        isTs: isTs
      };
      if (isAi) {
        aiItems.push(item);
      } else if (g.type === 'Selector') {
        mainItems.push(item);
      } else {
        otherItems.push(item);
      }
    }

    const merged: HomeActiveNodeItem[] = [];
    for (let i = 0; i < aiItems.length; i++) {
      merged.push(aiItems[i]);
    }
    for (let i = 0; i < mainItems.length && merged.length < 4; i++) {
      merged.push(mainItems[i]);
    }
    for (let i = 0; i < otherItems.length && merged.length < 4; i++) {
      merged.push(otherItems[i]);
    }
    if (!hasTsItem && this.tsPrefs.enabled) {
      merged.push({
        group: 'Tailscale 组网',
        finalNode: this.tailscaleIps.length > 0 ? this.tailscaleIps : this.tailscaleStateLabel(),
        delay: this.tailscaleState === 'Running' ? `${this.tsControl.peers.length} 设备` : this.tailscaleStateLabel(),
        status: this.tailscaleState === 'Running' ? 'fast' : 'pending',
        isAi: false,
        isTs: true
      });
    }

    this.homeActiveNodes = merged;
    if (merged.length > 0 && !merged[0].isTs) {
      this.homePrimaryDelayText = merged[0].delay;
    } else if (merged.length > 1) {
      this.homePrimaryDelayText = merged[1].delay;
    } else {
      this.homePrimaryDelayText = '待测';
    }
  }

  private async testHomeActiveNodesDelay(): Promise<void> {
    if (this.isTestingActiveNodes || !this.isRuntimeConnected()) {
      return;
    }
    this.isTestingActiveNodes = true;
    try {
      this.rebuildHomeActiveNodes();
      const targets: string[] = [];
      for (let i = 0; i < this.homeActiveNodes.length; i++) {
        const item: HomeActiveNodeItem = this.homeActiveNodes[i];
        if (!item.isTs && item.finalNode.length > 0 && item.finalNode !== 'DIRECT' && item.finalNode !== 'REJECT' && targets.indexOf(item.finalNode) < 0) {
          targets.push(item.finalNode);
        }
      }
      if (targets.length === 0) {
        return;
      }
      const updates: ProxyDelayUpdate[] = [];
      const tasks: Promise<number>[] = [];
      for (let i = 0; i < targets.length; i++) {
        tasks.push(this.measureProxyNodeDelay({ name: targets[i], meta: '', delay: '测试中...' }));
      }
      const delays: number[] = await Promise.all(tasks);
      for (let i = 0; i < delays.length; i++) {
        const fmt = TcpDelayTestService.formatDelay(delays[i]);
        updates.push({ name: targets[i], delay: fmt.delay, status: fmt.status });
      }
      this.updateProxyNodeDelayBatch(updates);
      this.rebuildHomeActiveNodes();
    } finally {
      this.isTestingActiveNodes = false;
    }
  }

  private updateHomeTrafficStats(connections: ControllerConnectionInfo[]): void {
    const keys: string[] = Object.keys(this.homeNodeAccumMap);
    for (let i = 0; i < keys.length; i++) {
      this.homeNodeAccumMap[keys[i]].active = 0;
    }
    const nextLiveConns: Record<string, HomeNodeConnDetail[]> = {};
    const liveIds: Record<string, boolean> = {};

    for (let i = 0; i < connections.length; i++) {
      const c: ControllerConnectionInfo = connections[i];
      liveIds[c.id] = true;
      const finalNode: string = c.chains.length > 0 ? c.chains[0] : 'DIRECT';
      const topGroup: string = c.chains.length > 1 ? c.chains[c.chains.length - 1] : finalNode;
      const nodeKey: string = `${finalNode}||${topGroup}`;

      const prev: ConnBytesRecord | undefined = this.homeConnSeenBytes[c.id];
      const prevDown: number = prev ? prev.download : 0;
      const prevUp: number = prev ? prev.upload : 0;
      const dDown: number = c.download >= prevDown ? c.download - prevDown : c.download;
      const dUp: number = c.upload >= prevUp ? c.upload - prevUp : c.upload;
      this.homeConnSeenBytes[c.id] = { download: c.download, upload: c.upload };

      let acc: HomeNodeTrafficItem | undefined = this.homeNodeAccumMap[nodeKey];
      if (!acc) {
        acc = {
          key: nodeKey,
          node: finalNode,
          group: topGroup,
          active: 0,
          downloadBytes: 0,
          uploadBytes: 0,
          percent: 0
        };
        this.homeNodeAccumMap[nodeKey] = acc;
      }
      acc.downloadBytes = acc.downloadBytes + dDown;
      acc.uploadBytes = acc.uploadBytes + dUp;
      acc.active = acc.active + 1;

      const target: string = c.metadata.host.length > 0
        ? `${c.metadata.host}:${c.metadata.destinationPort}`
        : `${c.metadata.destinationIP}:${c.metadata.destinationPort}`;
      let detailList: HomeNodeConnDetail[] | undefined = nextLiveConns[nodeKey];
      if (!detailList) {
        detailList = [];
        nextLiveConns[nodeKey] = detailList;
      }
      if (detailList.length < 20) {
        detailList.push({
          target: target,
          rule: c.rule.length > 0 ? c.rule : 'MATCH',
          chain: c.chains.join(' <- '),
          download: this.formatBytes(c.download),
          upload: this.formatBytes(c.upload)
        });
      }
    }

    // Prune closed connection ids without using ArkTS-disallowed `delete` operator
    const nextSeen: Record<string, ConnBytesRecord> = {};
    const seenKeys: string[] = Object.keys(this.homeConnSeenBytes);
    for (let i = 0; i < seenKeys.length; i++) {
      const k: string = seenKeys[i];
      if (liveIds[k]) {
        nextSeen[k] = this.homeConnSeenBytes[k];
      }
    }
    this.homeConnSeenBytes = nextSeen;
    this.homeNodeLiveConnsMap = nextLiveConns;

    // Remember latest observed connections per node so tapping a node still shows recent targets even after short-lived bursts close
    const liveNodeKeys: string[] = Object.keys(nextLiveConns);
    for (let i = 0; i < liveNodeKeys.length; i++) {
      const nk: string = liveNodeKeys[i];
      const liveArr: HomeNodeConnDetail[] = nextLiveConns[nk];
      if (liveArr && liveArr.length > 0) {
        this.homeNodeRecentConnsMap[nk] = liveArr.slice(0, 15);
      }
    }

    const allRows: HomeNodeTrafficItem[] = [];
    const accumKeys: string[] = Object.keys(this.homeNodeAccumMap);
    for (let i = 0; i < accumKeys.length; i++) {
      const r: HomeNodeTrafficItem = this.homeNodeAccumMap[accumKeys[i]];
      allRows.push({
        key: r.key,
        node: r.node,
        group: r.group,
        active: r.active,
        downloadBytes: r.downloadBytes,
        uploadBytes: r.uploadBytes,
        percent: 0
      });
    }
    allRows.sort((a: HomeNodeTrafficItem, b: HomeNodeTrafficItem) => (b.downloadBytes + b.uploadBytes) - (a.downloadBytes + a.uploadBytes));
    const maxBytes: number = allRows.length > 0 ? Math.max(1, allRows[0].downloadBytes + allRows[0].uploadBytes) : 1;
    const topRows: HomeNodeTrafficItem[] = allRows.slice(0, 6);
    for (let i = 0; i < topRows.length; i++) {
      const total: number = topRows[i].downloadBytes + topRows[i].uploadBytes;
      topRows[i].percent = Math.max(4, Math.min(100, Math.round((total / maxBytes) * 100)));
    }
    this.homeNodeTraffic = topRows;
    this.homeTrafficConnsTick = this.homeTrafficConnsTick + 1;
  }

  private isTrafficNodeExpanded(nodeKey: string): boolean {
    return this.expandedTrafficNodeKeys.indexOf(nodeKey) >= 0;
  }

  private getTrafficNodeConns(nodeKey: string): HomeNodeConnDetail[] {
    const liveList: HomeNodeConnDetail[] | undefined = this.homeNodeLiveConnsMap[nodeKey];
    if (liveList && liveList.length > 0) {
      return liveList;
    }
    const recentList: HomeNodeConnDetail[] | undefined = this.homeNodeRecentConnsMap[nodeKey];
    return recentList ? recentList : [];
  }

  private toggleExpandTrafficNode(nodeKey: string): void {
    const next: string[] = [];
    let removed: boolean = false;
    for (let i = 0; i < this.expandedTrafficNodeKeys.length; i++) {
      if (this.expandedTrafficNodeKeys[i] === nodeKey) {
        removed = true;
      } else {
        next.push(this.expandedTrafficNodeKeys[i]);
      }
    }
    if (!removed) {
      next.push(nodeKey);
    }
    this.expandedTrafficNodeKeys = next;
  }

  private resetHomeTrafficAccumulators(): void {
    this.homeConnSeenBytes = {};
    this.homeNodeAccumMap = {};
    this.homeNodeLiveConnsMap = {};
    this.homeNodeRecentConnsMap = {};
    this.homeNodeTraffic = [];
    this.expandedTrafficNodeKeys = [];
    this.homeTrafficConnsTick = this.homeTrafficConnsTick + 1;
  }

  private delayAccentColor(status: string): string {
    if (status === 'dead') {
      return '#DC2626';
    }
    if (status === 'slow') {
      return '#D97706';
    }
    if (status === 'fast' || status === 'normal') {
      return '#0F766E';
    }
    if (status === 'testing') {
      return '#2563EB';
    }
    return '#64748B';
  }

  private getExitNodeCandidates(): TailscalePeerItem[] {
    const out: TailscalePeerItem[] = [];
    for (let i = 0; i < this.tsControl.peers.length; i++) {
      if (this.tsControl.peers[i].exitNodeOption) {
        out.push(this.tsControl.peers[i]);
      }
    }
    return out;
  }

  private async copyPlainText(label: string, text: string): Promise<void> {
    if (text.length === 0) {
      return;
    }
    try {
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      await pasteboard.getSystemPasteboard().setData(data);
      this.statusMessage = `已复制${label}：${text}`;
      this.tsBusyMessage = this.statusMessage;
    } catch (_err) {
      this.statusMessage = `复制${label}失败`;
    }
  }

  private async addDiscoveredRouteToMihomoRules(cidr: string): Promise<void> {
    const ruleLine: string = `IP-CIDR,${cidr},${this.tsPrefs.proxyName.length > 0 ? this.tsPrefs.proxyName : 'Tailscale'},no-resolve`;
    await this.quickAppendRuleToCurrentProfile(ruleLine, `添加 Tailscale 子网路由 ${cidr}`, true);
  }

  private async addTailnetSuffixToMihomoRules(suffix: string): Promise<void> {
    const ruleLine: string = `DOMAIN-SUFFIX,${suffix},${this.tsPrefs.proxyName.length > 0 ? this.tsPrefs.proxyName : 'Tailscale'}`;
    await this.quickAppendRuleToCurrentProfile(ruleLine, `添加 Tailnet 域名规则 ${suffix}`, true);
  }

  private async addSplitDnsToMihomoProfile(domain: string): Promise<void> {
    const targetUid: string = this.editingProfileUid.length > 0 ? this.editingProfileUid : this.profileState.currentUid;
    if (targetUid.length === 0) {
      this.tsBusyMessage = '请先在配置页启用一个 Mihomo 配置';
      this.statusMessage = this.tsBusyMessage;
      return;
    }
    if (this.editingProfileUid !== targetUid) {
      await this.loadProfileWorkspaceData(targetUid);
    }
    const proxyName: string = this.tsPrefs.proxyName.length > 0 ? this.tsPrefs.proxyName : 'Tailscale';
    const nextYaml: string = TailscalePrefsService.applySplitDnsDomainToProfileYaml(this.editorBaseText, domain, proxyName);
    if (nextYaml === this.editorBaseText) {
      this.tsBusyMessage = `SplitDNS 域名 ${domain} 的 DNS 与分流规则均已就绪`;
      this.statusMessage = this.tsBusyMessage;
      return;
    }
    await this.commitRuleMutation(nextYaml, `联动 Tailscale SplitDNS ${domain}`);
    this.tsSplitDnsNeedReload = this.liveConnected;
  }

  private async runTailscaleDnsTest(customHost?: string): Promise<void> {
    const target: string = (customHost !== undefined ? customHost : this.tsDnsTestQuery).trim();
    if (target.length === 0) {
      this.tsDnsTestResult = '请输入待测域名（例如 dsh-10.sjfarm.cc）';
      return;
    }
    if (customHost !== undefined) {
      this.tsDnsTestQuery = target;
    }
    if (!this.tsControl.reachable) {
      this.tsDnsTestResult = '请先连接 VPN 后再测试 SplitDNS 解析';
      return;
    }
    this.tsDnsTestResult = `正在通过 Tailscale 解析 ${target} ...`;
    const res: TailscaleDnsQueryResult = await TailscaleControlService.queryDns(target, 'A');
    if (res.ok && res.answers.length > 0) {
      const via: string = res.resolvers.length > 0 ? `（上游 ${res.resolvers.join(', ')}）` : '';
      this.tsDnsTestResult = `解析成功：${res.answers.join(', ')} · ${Math.round(res.latencyMs)} ms${via}`;
    } else {
      this.tsDnsTestResult = `解析失败：${res.error.length > 0 ? res.error : '无记录'}`;
    }
  }

  // ============== Phase 3: Visual Traffic Rules & Route Simulator ==============
  private runRouteSimulation(customQuery?: string): void {
    const q: string = customQuery !== undefined ? customQuery : this.simQuery;
    if (customQuery !== undefined) {
      this.simQuery = customQuery;
    }
    this.simResult = TrafficRuleAnalyzerService.simulateRoute(this.trafficAnalysis, q, this.proxyMode);
  }

  private getFilteredRules(): ParsedRuleItem[] {
    const q: string = this.ruleSearchText.trim().toLowerCase();
    if (q.length === 0) {
      return this.trafficAnalysis.rules.slice(0, 80);
    }
    const out: ParsedRuleItem[] = [];
    for (let i = 0; i < this.trafficAnalysis.rules.length; i++) {
      const r: ParsedRuleItem = this.trafficAnalysis.rules[i];
      if (r.raw.toLowerCase().indexOf(q) >= 0 || r.chainLabel.toLowerCase().indexOf(q) >= 0) {
        out.push(r);
      }
      if (out.length >= 80) {
        break;
      }
    }
    return out;
  }

  private async quickAppendRuleToCurrentProfile(ruleLine: string, note: string, prepend: boolean): Promise<void> {
    const targetUid: string = this.editingProfileUid.length > 0 ? this.editingProfileUid : this.profileState.currentUid;
    if (targetUid.length === 0) {
      this.tsBusyMessage = '请先在配置页启用一个 Mihomo 配置';
      this.statusMessage = this.tsBusyMessage;
      return;
    }
    if (this.editingProfileUid !== targetUid) {
      await this.loadProfileWorkspaceData(targetUid);
    }
    if (TrafficRuleAnalyzerService.hasRuleLine(this.editorBaseText, ruleLine)) {
      this.tsBusyMessage = `规则已存在：${ruleLine}`;
      this.statusMessage = this.tsBusyMessage;
      return;
    }
    const nextYaml: string = TrafficRuleAnalyzerService.addRuleToYaml(this.editorBaseText, ruleLine, prepend);
    await this.commitRuleMutation(nextYaml, note);
  }

  private async commitRuleMutation(nextYaml: string, note: string): Promise<void> {
    const profile: ClashProfile | undefined = this.findProfileByUid(this.editingProfileUid);
    if (!profile) {
      this.statusMessage = '未选中配置';
      return;
    }
    const check: ConfigValidationResult = CoreBridgeService.validateConfig(nextYaml);
    if (!check.ok) {
      this.statusMessage = `规则修改校验失败：${check.error}`;
      this.tsBusyMessage = this.statusMessage;
      return;
    }
    const context = getContext(this) as common.Context;
    const commit: VersionCommitResult = await ProfileVersionService.commitNewVersion(
      context,
      profile,
      nextYaml,
      'rule',
      note
    );
    if (!commit.ok) {
      this.statusMessage = commit.message;
      return;
    }
    this.applyProfileState(commit.state);
    this.versionHistory = ProfileVersionService.reversedVersions(commit.manifest);
    this.activeVersionNumber = commit.version;
    this.editorBaseText = nextYaml;
    this.editorDraftText = nextYaml;
    this.trafficAnalysis = TrafficRuleAnalyzerService.analyze(nextYaml);
    if (this.simQuery.trim().length > 0) {
      this.simResult = TrafficRuleAnalyzerService.simulateRoute(this.trafficAnalysis, this.simQuery, this.proxyMode);
    }
    this.statusMessage = `${note} · 已存为 v${commit.version}`;
    this.tsBusyMessage = this.statusMessage;
    this.recordLog('info', this.statusMessage);
  }

  private async submitNewRule(): Promise<void> {
    const payload: string = this.newRulePayload.trim();
    if (this.newRuleType !== 'MATCH' && payload.length === 0) {
      this.statusMessage = '请输入域名、关键词或 IP-CIDR';
      return;
    }
    const target: string = this.newRuleTarget.trim().length > 0 ? this.newRuleTarget.trim() : 'Tailscale';
    let line: string = '';
    if (this.newRuleType === 'MATCH') {
      line = `MATCH,${target}`;
    } else if (this.newRuleType === 'IP-CIDR' || this.newRuleType === 'IP-CIDR6') {
      line = `${this.newRuleType},${payload},${target},no-resolve`;
    } else {
      line = `${this.newRuleType},${payload},${target}`;
    }
    await this.quickAppendRuleToCurrentProfile(line, `新增规则 ${line}`, this.newRulePrepend);
    this.newRulePayload = '';
    this.showAddRulePanel = false;
  }

  private async deleteVisualRule(rule: ParsedRuleItem): Promise<void> {
    const nextYaml: string = TrafficRuleAnalyzerService.deleteRuleFromYaml(this.editorBaseText, rule.lineIndex);
    await this.commitRuleMutation(nextYaml, `删除规则 #${rule.index}`);
  }

  private async moveVisualRule(ruleIndex1Based: number, delta: number): Promise<void> {
    const pos: number = ruleIndex1Based - 1;
    const nextYaml: string = TrafficRuleAnalyzerService.moveRuleInYaml(this.editorBaseText, this.trafficAnalysis.rules, pos, delta);
    if (nextYaml === this.editorBaseText) {
      return;
    }
    await this.commitRuleMutation(nextYaml, delta < 0 ? `上移规则 #${ruleIndex1Based}` : `下移规则 #${ruleIndex1Based}`);
  }

  private categoryAccentColor(cat: string): string {
    if (cat === 'tailscale') {
      return '#0F766E';
    }
    if (cat === 'proxy') {
      return '#2563EB';
    }
    if (cat === 'reject') {
      return '#DC2626';
    }
    return '#475569';
  }

  private categoryBgColor(cat: string): string {
    if (cat === 'tailscale') {
      return '#E6FFFB';
    }
    if (cat === 'proxy') {
      return '#EFF6FF';
    }
    if (cat === 'reject') {
      return '#FEF2F2';
    }
    return '#F1F5F9';
  }

  private getCurrentPageTitle(): string {
    if (this.showSettings) {
      return '系统设置';
    }
    if (this.currentTab === 'proxies') {
      return '代理策略组';
    }
    if (this.currentTab === 'tailscale') {
      return 'Tailscale 组网';
    }
    if (this.currentTab === 'overlay') {
      return '自建与分流覆写';
    }
    if (this.currentTab === 'profiles') {
      return '订阅与配置';
    }
    if (this.currentTab === 'diagnostics') {
      return '日志与诊断';
    }
    return '总览 & 状态';
  }

  private navigateToTab(key: string): void {
    this.showSettings = false;
    this.showNavDrawer = false;
    this.currentTab = key;
    if (key === 'diagnostics') {
      this.refreshCoreLogs();
    } else if (key === 'tailscale') {
      this.refreshTailscaleStatus();
    } else if (key === 'overlay') {
      this.loadOverlayConfig();
    } else if (key === 'profiles' && this.editingProfileUid.length === 0 && this.profileState.currentUid.length > 0) {
      this.loadProfileWorkspaceData(this.profileState.currentUid);
    }
  }

  private isSwitchEnabled(key: string): boolean {
    if (key === 'overlay.enabled') {
      return this.overlayConfig.enabled;
    }
    if (key === 'overlay.aiStrictEnabled') {
      return this.overlayConfig.aiStrictEnabled;
    }
    if (key === 'overlay.failClosed') {
      return this.overlayConfig.failClosed;
    }
    if (key === 'ts.managedByApp') {
      return this.tsPrefs.managedByApp;
    }
    if (key === 'ts.enabled') {
      return this.tsPrefs.enabled;
    }
    if (key === 'ts.acceptRoutes') {
      return this.tsPrefs.acceptRoutes;
    }
    if (key === 'ts.autoInjectMagicDns') {
      return this.tsPrefs.autoInjectMagicDns;
    }
    if (key === 'ts.autoSyncSplitDns') {
      return this.tsPrefs.autoSyncSplitDns;
    }
    if (key === 'ts.exitNodeAllowLan') {
      return this.tsPrefs.exitNodeAllowLan;
    }
    return false;
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column() {
        this.AppBar()
        if (this.showSettings) {
          this.SettingsScreen()
        } else if (this.currentTab === 'home') {
          this.HomeScreen()
        } else if (this.currentTab === 'proxies') {
          this.ProxyScreen()
        } else if (this.currentTab === 'tailscale') {
          this.TailscaleScreen()
        } else if (this.currentTab === 'overlay') {
          this.OverlayScreen()
        } else if (this.currentTab === 'profiles') {
          this.ProfileScreen()
        } else {
          this.DiagnosticsScreen()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#F8FAFC')

      if (this.showNavDrawer) {
        this.NavDrawerOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }

  // ============== AppBar ==============
  @Builder
  private AppBar() {
    Row({ space: 10 }) {
      Button('☰')
        .width(38).height(36).fontSize(18).fontWeight(FontWeight.Bold)
        .fontColor('#0F172A').backgroundColor('#F1F5F9').borderRadius(8)
        .onClick(() => { this.showNavDrawer = !this.showNavDrawer })

      Column() {
        Text(this.getCurrentPageTitle())
          .fontSize(17).fontWeight(FontWeight.Bold).fontColor('#0F172A').maxLines(1)
        Text(this.getSubtitle())
          .fontSize(11).fontColor('#64748B').margin({ top: 1 }).maxLines(1)
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)

      if (this.showSettings) {
        Button('返回')
          .height(32).fontSize(12).fontColor('#0F172A').backgroundColor('#EEF2F7').borderRadius(8)
          .onClick(() => { this.showSettings = false })
      } else {
        Text(this.liveConnected ? '● 已连接' : '○ 未连接')
          .fontSize(12).fontWeight(FontWeight.Bold)
          .fontColor(this.liveConnected ? '#0F766E' : '#D97706')
          .padding({ left: 10, right: 10, top: 6, bottom: 6 })
          .backgroundColor(this.liveConnected ? '#E6FFFB' : '#FFF7ED')
          .borderRadius(14)
          .border({ width: 1, color: this.liveConnected ? '#99F6E4' : '#FDE68A' })
          .onClick(() => {
            if (this.currentTab !== 'home') {
              this.navigateToTab('home');
            }
          })
      }
    }
    .height(56).width('100%').padding({ left: 12, right: 12 })
    .backgroundColor('#FFFFFF').border({ width: { bottom: 1 }, color: '#E2E8F0' })
  }

  // ============== Left Slide-Over Drawer (PC-aligned 6-item Dark Navy Sidebar) ==============
  @Builder
  private NavDrawerOverlay() {
    Row() {
      Column() {
        // Brand Header
        Column({ space: 6 }) {
          Row() {
            Column({ space: 2 }) {
              Text('Clash Harmony').fontSize(18).fontWeight(FontWeight.Bold).fontColor('#F8FAFC')
              Text(`${APP_VERSION_NAME} · Mihomo + Tailscale`).fontSize(11).fontColor('#94A3B8')
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)

            Text('✕')
              .fontSize(15).fontWeight(FontWeight.Bold).fontColor('#94A3B8')
              .width(32).height(32).textAlign(TextAlign.Center)
              .backgroundColor('#1E293B').borderRadius(8)
              .onClick(() => { this.showNavDrawer = false })
          }
          .width('100%')

          Row({ space: 6 }) {
            Text(this.liveConnected ? '● VPN 运行中' : '○ VPN 未连接')
              .fontSize(11).fontWeight(FontWeight.Bold)
              .fontColor(this.liveConnected ? '#34D399' : '#FBBF24')
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .backgroundColor(this.liveConnected ? '#0D3B32' : '#3B2F12')
              .borderRadius(10)
            if (this.tailscaleState === 'Running') {
              Text('TS 在线')
                .fontSize(11).fontWeight(FontWeight.Bold).fontColor('#38BDF8')
                .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                .backgroundColor('#0C2D48').borderRadius(10)
            }
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: 16, right: 14, top: 18, bottom: 14 })
        .border({ width: { bottom: 1 }, color: '#1E293B' })

        // 6 PC-aligned Primary Navigation Items
        Column({ space: 6 }) {
          ForEach(NAV_ITEMS, (item: NavItem) => {
            Row({ space: 10 }) {
              Text(item.label)
                .fontSize(15)
                .fontWeight(!this.showSettings && this.currentTab === item.key ? FontWeight.Bold : FontWeight.Medium)
                .fontColor(!this.showSettings && this.currentTab === item.key ? '#34D399' : '#CBD5E1')
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 14, right: 14, top: 13, bottom: 13 })
            .borderRadius(10)
            .backgroundColor(!this.showSettings && this.currentTab === item.key ? '#0D3B32' : '#0F172A')
            .border({
              width: 1,
              color: !this.showSettings && this.currentTab === item.key ? '#10B981' : '#0F172A'
            })
            .onClick(() => { this.navigateToTab(item.key) })
          }, (item: NavItem) => item.key)
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 12, bottom: 12 })

        Blank().layoutWeight(1)

        // Drawer Footer Shortcuts
        Column({ space: 8 }) {
          Button('📷 扫码同步电脑')
            .width('100%').height(38).fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF').backgroundColor('#2563EB').borderRadius(8)
            .onClick(() => {
              this.navigateToTab('profiles');
              this.profileSubTab = 'list';
              this.scanQrSyncFromPc();
            })

          Row() {
            Text('⚙ 系统设置')
              .fontSize(14)
              .fontWeight(this.showSettings ? FontWeight.Bold : FontWeight.Medium)
              .fontColor(this.showSettings ? '#34D399' : '#94A3B8')
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 11, bottom: 11 })
          .borderRadius(10)
          .backgroundColor(this.showSettings ? '#0D3B32' : '#1E293B')
          .border({ width: 1, color: this.showSettings ? '#10B981' : '#1E293B' })
          .onClick(() => {
            this.showSettings = true;
            this.showNavDrawer = false;
          })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 12, bottom: 18 })
        .border({ width: { top: 1 }, color: '#1E293B' })
      }
      .width(268)
      .height('100%')
      .backgroundColor('#0F172A')

      // Tap outside backdrop to dismiss drawer
      Column()
        .layoutWeight(1)
        .height('100%')
        .backgroundColor('rgba(15, 23, 42, 0.52)')
        .onClick(() => { this.showNavDrawer = false })
    }
    .width('100%')
    .height('100%')
  }

  // ============== Top-Level OverlayScreen (aligned with PC 自建与分流覆写) ==============
  @Builder
  private OverlayScreen() {
    Scroll() {
      Column({ space: 12 }) {
        this.ProfileOverlaySubScreen()
      }
      .padding(16)
    }
    .align(Alignment.TopStart)
    .layoutWeight(1)
  }

  // ============== Reusable Components ==============
  @Builder
  private Pill(text: string, color: string, bg: string) {
    Text(text).fontSize(12).fontWeight(FontWeight.Medium).fontColor(color)
      .padding({ left: 10, right: 10, top: 4, bottom: 4 })
      .backgroundColor(bg).borderRadius(12)
  }

  @Builder
  private Metric(label: string, value: string) {
    Column() {
      Text(label).fontSize(12).fontColor('#64748B')
      Text(value).fontSize(16).fontWeight(FontWeight.Bold).fontColor('#0F172A').margin({ top: 4 })
    }
    .layoutWeight(1).padding(10).backgroundColor('#F8FAFC')
    .borderRadius(8).border({ width: 1, color: '#E2E8F0' })
  }

  @Builder
  private ProfileSubTabOption(text: string, subTab: 'list' | 'editor' | 'flow') {
    Text(text).width('100%').height(36).textAlign(TextAlign.Center).fontSize(13)
      .fontWeight(this.profileSubTab === subTab ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.profileSubTab === subTab ? '#FFFFFF' : '#475569')
      .backgroundColor(this.profileSubTab === subTab ? '#0F766E' : '#F8FAFC').borderRadius(6)
      .border({ width: 1, color: this.profileSubTab === subTab ? '#0F766E' : '#CBD5E1' })
      .layoutWeight(1)
      .onClick(() => {
        this.profileSubTab = subTab;
        if ((subTab === 'editor' || subTab === 'flow') && this.editingProfileUid.length === 0 && this.profileState.currentUid.length > 0) {
          this.loadProfileWorkspaceData(this.profileState.currentUid);
        }
      })
  }

  @Builder
  private DiagSegmentOption(text: string, segment: string) {
    Text(text).width('100%').height(36).textAlign(TextAlign.Center).fontSize(13)
      .fontWeight(this.diagSegment === segment ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.diagSegment === segment ? '#FFFFFF' : '#475569')
      .backgroundColor(this.diagSegment === segment ? '#0F766E' : '#F8FAFC').borderRadius(6)
      .border({ width: 1, color: this.diagSegment === segment ? '#0F766E' : '#CBD5E1' })
      .layoutWeight(1)
      .onClick(() => {
        this.diagSegment = segment;
        if (segment === '日志') {
          this.refreshCoreLogs();
        }
      })
  }

  @Builder
  private ProxyModeOption(text: string, mode: 'rule' | 'global' | 'direct') {
    Text(text).width('100%').height(36).textAlign(TextAlign.Center).fontSize(13)
      .fontWeight(this.proxyMode === mode ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.proxyMode === mode ? '#FFFFFF' : '#475569')
      .backgroundColor(this.proxyMode === mode ? '#0F766E' : '#F8FAFC')
      .borderRadius(6)
      .border({ width: 1, color: this.proxyMode === mode ? '#0F766E' : '#CBD5E1' })
      .layoutWeight(1)
      .onClick(() => { this.changeProxyMode(mode) })
  }

  @Builder
  private ProxyGroupOption(groupName: string) {
    Text(groupName).fontSize(13)
      .fontWeight(this.selectedProxyGroup === groupName ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(this.selectedProxyGroup === groupName ? '#FFFFFF' : '#475569')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor(this.selectedProxyGroup === groupName ? '#2563EB' : '#FFFFFF').borderRadius(8)
      .border({ width: 1, color: this.selectedProxyGroup === groupName ? '#2563EB' : '#DBE3EF' })
      .onClick(() => { this.selectProxyGroup(groupName) })
  }

  @Builder
  private GroupButton(text: string, active: boolean) {
    Text(text).fontSize(13).fontWeight(active ? FontWeight.Bold : FontWeight.Regular)
      .fontColor(active ? '#2563EB' : '#64748B')
      .padding({ left: 12, right: 12, top: 8, bottom: 8 })
      .backgroundColor(active ? '#EFF6FF' : '#FFFFFF').borderRadius(8)
      .border({ width: 1, color: active ? '#BFDBFE' : '#DBE3EF' })
  }

  @Builder
  private SectionTitle(title: string, action: string) {
    Row() {
      Text(title).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
      if (action.length > 0) {
        Text(action).fontSize(12).fontColor('#2563EB').onClick(() => { this.handleSectionAction(action) })
      }
    }
    .width('100%').justifyContent(FlexAlign.SpaceBetween)
  }

  @Builder
  private InfoRow(label: string, value: string) {
    Row() {
      Text(label).fontSize(13).fontColor('#64748B')
      Text(value).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#0F172A')
    }
    .width('100%').justifyContent(FlexAlign.SpaceBetween)
  }

  @Builder
  private StatusLine(title: string, subtitle: string, status: string) {
    Row() {
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#0F172A')
        Text(subtitle).fontSize(12).fontColor('#64748B').margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      this.Pill(status, status === '正常' ? '#0F766E' : '#2563EB', status === '正常' ? '#E6FFFB' : '#EFF6FF')
    }
    .padding(10).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
  }

  @Builder
  private ProxyNodeRow(node: ProxyNode) {
    Row() {
      Column() {
        Text(node.name).fontSize(14).fontWeight(FontWeight.Bold)
          .fontColor(node.selected ? '#064E3B' : '#0F172A')
        Text(node.meta).fontSize(12)
          .fontColor(node.selected ? '#0F766E' : '#64748B').margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(node.delay).fontSize(12).fontWeight(FontWeight.Bold)
        .fontColor(node.status === 'dead' ? '#DC2626' : node.status === 'testing' ? '#2563EB' : node.status === 'slow' ? '#D97706' : node.status === 'fast' || node.status === 'normal' ? '#0F766E' : '#64748B')
    }
    .padding(10).backgroundColor(node.selected ? '#CCFBF1' : '#FFFFFF')
    .borderRadius(8).border({ width: node.selected ? 2 : 1, color: node.selected ? '#0F766E' : '#E2E8F0' })
    .onClick(() => { this.selectProxyNode(node) })
  }

  @Builder
  private ProfileRow(item: ClashProfile) {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Column() {
          Text(item.name).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A')
          Text(`${item.type === 'remote' ? '远程订阅' : '本地配置'} · ${formatProfileUpdatedAt(item.updatedAt)} · ${item.traffic}`)
            .fontSize(12).fontColor('#64748B').margin({ top: 3 })
          Text(`${item.nodeCount} 个节点 · ${item.filePath.length > 0 ? '已就绪' : '未下载'}`)
            .fontSize(11).fontColor('#94A3B8').margin({ top: 2 })
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (item.uid === this.profileState.currentUid) {
          this.Pill('当前', '#0F766E', '#E6FFFB')
        } else {
          Button('启用').height(28).fontSize(12).fontColor('#2563EB')
            .backgroundColor('#EFF6FF').borderRadius(8)
            .onClick(() => { this.activateProfile(item.uid) })
        }
        Button('删').height(28).fontSize(12).fontColor('#DC2626')
          .backgroundColor('#FEF2F2').borderRadius(8)
          .onClick(() => { this.removeProfile(item.uid) })
      }
      .width('100%')

      Row({ space: 6 }) {
        Button('版本历史').layoutWeight(1).height(30).fontSize(12).fontColor('#334155')
          .backgroundColor('#F1F5F9').borderRadius(6)
          .onClick(() => { this.openProfileWorkspace(item.uid, 'list', true) })
        Button('编辑/校验').layoutWeight(1).height(30).fontSize(12).fontColor('#0F766E')
          .backgroundColor('#E6FFFB').borderRadius(6)
          .onClick(() => { this.openProfileWorkspace(item.uid, 'editor', false) })
        Button('流量规则').layoutWeight(1).height(30).fontSize(12).fontColor('#2563EB')
          .backgroundColor('#EFF6FF').borderRadius(6)
          .onClick(() => { this.openProfileWorkspace(item.uid, 'flow', false) })
        if (item.type === 'remote') {
          Button('更新').height(30).fontSize(12).fontColor('#2563EB')
            .backgroundColor('#EFF6FF').borderRadius(6)
            .onClick(() => { this.updateProfile(item.uid) })
        }
      }
      .width('100%')
    }
    .padding(10).backgroundColor(item.uid === this.profileState.currentUid ? '#F0FDFA' : '#FFFFFF')
    .borderRadius(8).border({ width: 1, color: item.uid === this.profileState.currentUid ? '#99F6E4' : '#E2E8F0' })
  }

  @Builder
  private SwitchRow(title: string, subtitle: string, enabled: boolean) {
    Row() {
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#0F172A')
        Text(subtitle).fontSize(12).fontColor('#64748B').margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(enabled ? '开' : '关').fontSize(12).fontWeight(FontWeight.Bold)
        .fontColor(enabled ? '#FFFFFF' : '#64748B')
        .width(44).height(26).textAlign(TextAlign.Center)
        .backgroundColor(enabled ? '#0F766E' : '#E2E8F0').borderRadius(13)
    }
    .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
  }

  @Builder
  private ReactiveSwitchRow(title: string, subtitle: string, switchKey: string) {
    Row() {
      Column() {
        Text(title).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#0F172A')
        Text(subtitle).fontSize(12).fontColor('#64748B').margin({ top: 3 })
      }
      .alignItems(HorizontalAlign.Start).layoutWeight(1)
      Text(this.isSwitchEnabled(switchKey) ? '开' : '关').fontSize(12).fontWeight(FontWeight.Bold)
        .fontColor(this.isSwitchEnabled(switchKey) ? '#FFFFFF' : '#64748B')
        .width(44).height(26).textAlign(TextAlign.Center)
        .backgroundColor(this.isSwitchEnabled(switchKey) ? '#0F766E' : '#E2E8F0').borderRadius(13)
    }
    .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
  }

  @Builder
  private LogLine(time: string, level: string, message: string) {
    Row({ space: 8 }) {
      Text(time).fontSize(11).fontColor('#64748B')
      Text(level).fontSize(11).fontColor(level === 'warn' ? '#D97706' : '#2563EB')
      Text(message).fontSize(11).fontColor('#0F172A').layoutWeight(1)
    }
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  private EmptyState(title: string, subtitle: string) {
    Column({ space: 6 }) {
      Text(title).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A')
      Text(subtitle).fontSize(12).fontColor('#64748B').textAlign(TextAlign.Center)
    }
    .width('100%').padding(18).backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
  }

  // ============== HomeScreen (PC-aligned Hero + Active Nodes + Per-Node Traffic) ==============
  @Builder
  private HomeScreen() {
    Scroll() {
      Column({ space: 12 }) {
        this.HomeStatusCard()
        if (this.liveConnected && (this.tailscaleAuthUrl.length > 0 || this.tailscaleError.length > 0 || (this.tailscaleState.length > 0 && this.tailscaleState !== 'Running'))) {
          this.TailscaleStatusCard(true)
        }
        if (this.liveConnected) {
          this.HomeActiveNodesCard()
          this.HomeNodeTrafficCard()
        } else if (this.profileState.items.length === 0) {
          Column({ space: 10 }) {
            Text('快速开始（2 步搞定）').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
            Text('如果电脑端已经配好 BitzNet 订阅、自建节点与 AI 分流，可直接扫码同步，无需重复填写。')
              .fontSize(12).fontColor('#475569').width('100%')
            Row({ space: 8 }) {
              Button('📷 扫码同步电脑').layoutWeight(1).height(38).fontSize(13).fontColor('#FFFFFF')
                .backgroundColor('#2563EB').borderRadius(8)
                .onClick(() => {
                  this.currentTab = 'profiles';
                  this.profileSubTab = 'list';
                  this.scanQrSyncFromPc();
                })
              Button('前往导入配置').layoutWeight(1).height(38).fontSize(13).fontColor('#0F766E')
                .backgroundColor('#E6FFFB').borderRadius(8)
                .onClick(() => {
                  this.currentTab = 'profiles';
                  this.profileSubTab = 'list';
                })
            }
            .width('100%')
          }
          .padding(14).backgroundColor('#FFFFFF').borderRadius(12).border({ width: 1, color: '#BFDBFE' })
        }
      }
      .padding(16)
    }
    .align(Alignment.TopStart)
    .layoutWeight(1)
  }

  @Builder
  private HomeStatusCard() {
    Column({ space: 12 }) {
      Row() {
        Row({ space: 6 }) {
          Text(this.liveConnected ? '已连接' : '未连接')
            .fontSize(13).fontWeight(FontWeight.Bold)
            .fontColor(this.liveConnected ? '#FFFFFF' : '#D97706')
            .padding({ left: 12, right: 12, top: 5, bottom: 5 })
            .backgroundColor(this.liveConnected ? '#0F766E' : '#FFF7ED')
            .borderRadius(14)
          Text(this.liveUptime)
            .fontSize(12).fontWeight(FontWeight.Medium).fontColor('#2563EB')
            .padding({ left: 10, right: 10, top: 5, bottom: 5 })
            .backgroundColor('#EFF6FF').borderRadius(14)
        }
        Text(`${APP_VERSION_NAME}`).fontSize(11).fontColor('#64748B')
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween)

      // Prominent Hero Power Button (Emerald = Connect, Crimson = Disconnect)
      Row({ space: 16 }) {
        Button() {
          Column({ space: 2 }) {
            Text(this.liveConnected ? '断开' : '连接')
              .fontSize(20).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
            Text(this.liveConnected ? '点击停止' : '一键启动')
              .fontSize(10).fontColor('#F8FAFC').opacity(0.9)
          }
        }
          .width(96).height(96)
          .backgroundColor(this.liveConnected ? '#DC2626' : '#0F766E')
          .borderRadius(48)
          .onClick(() => { this.requestToggleVpn() })

        Column({ space: 6 }) {
          Text(this.liveProfileName)
            .fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A').maxLines(1)
          Text(this.liveConnected ? this.liveProxyName : '点击左侧按钮启动统一 VPN（代理 + AI自建 + Tailscale）')
            .fontSize(12).fontColor(this.liveConnected ? '#0F766E' : '#64748B').maxLines(2)
          if (this.tailscaleState === 'Running' && this.tailscaleIps.length > 0) {
            Text(`Tailscale 已组网 · ${this.tailscaleIps}`)
              .fontSize(11).fontWeight(FontWeight.Medium).fontColor('#2563EB').maxLines(1)
          }
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
      }
      .width('100%').padding({ top: 4, bottom: 4 })

      Row({ space: 6 }) {
        this.ProxyModeOption('规则', 'rule')
        this.ProxyModeOption('全局', 'global')
        this.ProxyModeOption('直连', 'direct')
      }
      .width('100%').padding(4).backgroundColor('#EEF2F7').borderRadius(8)

      Row({ space: 6 }) {
        Column() {
          Text('下行').fontSize(11).fontColor('#64748B')
          Text(this.liveDownloadSpeed).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F766E').margin({ top: 2 }).maxLines(1)
        }
        .layoutWeight(1).padding(8).backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
        Column() {
          Text('上行').fontSize(11).fontColor('#64748B')
          Text(this.liveUploadSpeed).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#2563EB').margin({ top: 2 }).maxLines(1)
        }
        .layoutWeight(1).padding(8).backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
        Column() {
          Text('连接').fontSize(11).fontColor('#64748B')
          Text(`${this.liveConnections}`).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A').margin({ top: 2 })
        }
        .layoutWeight(1).padding(8).backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
        Column() {
          Text('延迟').fontSize(11).fontColor('#64748B')
          Text(this.homePrimaryDelayText).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A').margin({ top: 2 }).maxLines(1)
        }
        .layoutWeight(1).padding(8).backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
      }
      .width('100%')

      Text(this.statusMessage).width('100%').fontSize(11).fontColor('#64748B').textAlign(TextAlign.Center)
      Text(`${this.liveRefreshToken}`).height(1).fontSize(1).fontColor('#FFFFFF').opacity(0)
    }
    .padding(14)
    .backgroundColor(this.liveConnected ? '#F0FDFA' : '#FFFFFF')
    .borderRadius(12)
    .border({ width: this.liveConnected ? 1.5 : 1, color: this.liveConnected ? '#14B8A6' : '#DBE3EF' })
  }

  @Builder
  private HomeActiveNodesCard() {
    Column({ space: 8 }) {
      Row() {
        Text('🌐 当前出口节点与延迟').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A')
        Row({ space: 6 }) {
          Button(this.isTestingActiveNodes ? '测速中...' : '⚡ 测延迟').height(28).fontSize(11).fontColor('#FFFFFF')
            .backgroundColor(this.isTestingActiveNodes ? '#64748B' : '#0F766E').borderRadius(6)
            .enabled(!this.isTestingActiveNodes)
            .onClick(() => { this.testHomeActiveNodesDelay() })
          Button('切换').height(28).fontSize(11).fontColor('#2563EB')
            .backgroundColor('#EFF6FF').borderRadius(6)
            .onClick(() => { this.currentTab = 'proxies' })
        }
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween)

      if (this.homeActiveNodes.length === 0) {
        Text('正在同步策略组节点...').fontSize(12).fontColor('#64748B').width('100%')
      } else {
        ForEach(this.homeActiveNodes, (item: HomeActiveNodeItem) => {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(item.group).fontSize(11).fontColor('#64748B')
              Text(item.finalNode).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#0F172A').maxLines(1)
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            Text(item.delay)
              .fontSize(12).fontWeight(FontWeight.Bold)
              .fontColor(this.delayAccentColor(item.status))
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .backgroundColor(item.isAi ? '#CCFBF1' : item.isTs ? '#EFF6FF' : '#F1F5F9')
              .borderRadius(10)
          }
          .width('100%').padding(10)
          .backgroundColor(item.isAi ? '#F0FDFA' : '#F8FAFC')
          .borderRadius(8)
          .border({ width: 1, color: item.isAi ? '#99F6E4' : '#E2E8F0' })
          .onClick(() => {
            if (item.isTs) {
              this.currentTab = 'tailscale';
              this.refreshTailscaleStatus();
            } else {
              this.selectProxyGroup(item.group);
              this.currentTab = 'proxies';
            }
          })
        }, (item: HomeActiveNodeItem) => `han-${item.group}-${item.finalNode}-${item.delay}`)
      }
    }
    .padding(12).backgroundColor('#FFFFFF').borderRadius(12).border({ width: 1, color: '#DBE3EF' })
  }

  @Builder
  private HomeNodeTrafficCard() {
    Column({ space: 8 }) {
      Row() {
        Text('📊 各节点实时流量').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A')
        Row({ space: 6 }) {
          Button('清空').height(26).fontSize(11).fontColor('#64748B')
            .backgroundColor('#F1F5F9').borderRadius(6)
            .onClick(() => { this.resetHomeTrafficAccumulators() })
          Button('详情').height(26).fontSize(11).fontColor('#2563EB')
            .backgroundColor('#EFF6FF').borderRadius(6)
            .onClick(() => {
              this.currentTab = 'diagnostics';
              this.diagSegment = '连接';
            })
        }
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween)

      if (this.homeNodeTraffic.length === 0) {
        Text('产生网络流量后自动按出口节点统计，点击任意节点可展开连接详情。')
          .fontSize(11).fontColor('#64748B').width('100%')
      } else {
        Text('点击任意节点可展开/收起连接详情（支持同时展开多个节点）').fontSize(11).fontColor('#64748B').width('100%')
        ForEach(this.homeNodeTraffic, (row: HomeNodeTrafficItem) => {
          Column({ space: 6 }) {
            Row({ space: 6 }) {
              Text(this.isTrafficNodeExpanded(row.key) ? '▾' : '▸')
                .fontSize(12).fontWeight(FontWeight.Bold)
                .fontColor(this.isTrafficNodeExpanded(row.key) ? '#0F766E' : '#94A3B8')
              Column({ space: 1 }) {
                Text(row.node).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#0F172A').maxLines(1)
                if (row.group.length > 0 && row.group !== row.node) {
                  Text(row.group).fontSize(10).fontColor('#64748B').maxLines(1)
                }
              }
              .alignItems(HorizontalAlign.Start).layoutWeight(1)

              Text(row.active > 0 ? `${row.active} 活跃` : '最近')
                .fontSize(10).fontWeight(FontWeight.Bold)
                .fontColor(this.isTrafficNodeExpanded(row.key) ? '#FFFFFF' : row.active > 0 ? '#0F766E' : '#64748B')
                .padding({ left: 7, right: 7, top: 3, bottom: 3 })
                .backgroundColor(this.isTrafficNodeExpanded(row.key) ? '#0F766E' : row.active > 0 ? '#E6FFFB' : '#F1F5F9')
                .borderRadius(10)

              Text(`↓${this.formatBytes(row.downloadBytes)} / ↑${this.formatBytes(row.uploadBytes)}`)
                .fontSize(11).fontColor('#475569')
            }
            .width('100%')

            Row() {
              Row().width(`${row.percent}%`).height(5).backgroundColor('#0F766E').borderRadius(3)
            }
            .width('100%').height(5).backgroundColor('#E2E8F0').borderRadius(3)

            if (this.isTrafficNodeExpanded(row.key)) {
              Column({ space: 6 }) {
                Row() {
                  Text(row.active > 0
                    ? `当前活跃连接 (${this.getTrafficNodeConns(row.key).length})`
                    : `最近连接记录 (${this.getTrafficNodeConns(row.key).length})`)
                    .fontSize(11).fontWeight(FontWeight.Bold).fontColor('#0F766E').layoutWeight(1)
                  Text('收起').fontSize(11).fontColor('#64748B')
                }
                .width('100%')

                if (this.getTrafficNodeConns(row.key).length === 0) {
                  Text('暂无连接明细').fontSize(11).fontColor('#64748B').width('100%')
                } else {
                  ForEach(this.getTrafficNodeConns(row.key), (cd: HomeNodeConnDetail, idx: number) => {
                    Column({ space: 2 }) {
                      Row({ space: 6 }) {
                        Text(cd.target).fontSize(11).fontWeight(FontWeight.Medium).fontColor('#0F172A').maxLines(1).layoutWeight(1)
                        Text(`↓${cd.download} / ↑${cd.upload}`).fontSize(10).fontWeight(FontWeight.Medium).fontColor('#0F766E')
                      }
                      .width('100%')
                      Text(`${cd.rule}${cd.chain.length > 0 ? ` · ${cd.chain}` : ''}`)
                        .fontSize(10).fontColor('#64748B').maxLines(1).width('100%')
                    }
                    .width('100%').padding({ top: 4, bottom: 4 })
                    .border({ width: { bottom: idx < this.getTrafficNodeConns(row.key).length - 1 ? 1 : 0 }, color: '#E2E8F0' })
                  }, (cd: HomeNodeConnDetail, idx: number) => `ec-${row.key}-${idx}-${cd.target}-${cd.download}-${cd.upload}`)
                }
              }
              .width('100%').padding(8).backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#99F6E4' })
            }
          }
          .width('100%')
          .padding(8)
          .backgroundColor(this.isTrafficNodeExpanded(row.key) ? '#F0FDFA' : '#FFFFFF')
          .borderRadius(8)
          .border({ width: 1, color: this.isTrafficNodeExpanded(row.key) ? '#14B8A6' : '#F1F5F9' })
          .onClick(() => { this.toggleExpandTrafficNode(row.key) })
        }, (row: HomeNodeTrafficItem) => `hnt-${row.key}-${row.active}-${row.downloadBytes}-${row.uploadBytes}-${this.isTrafficNodeExpanded(row.key) ? `open-${this.homeTrafficConnsTick}` : 'closed'}`)
      }
    }
    .padding(12).backgroundColor('#FFFFFF').borderRadius(12).border({ width: 1, color: '#DBE3EF' })
  }

  @Builder
  private HomeModeCard() {
    Column({ space: 10 }) {
      this.SectionTitle('运行模式', '')
      Row({ space: 6 }) {
        this.ProxyModeOption('规则', 'rule')
        this.ProxyModeOption('全局', 'global')
        this.ProxyModeOption('直连', 'direct')
      }
      .width('100%').padding(4).backgroundColor('#EEF2F7').borderRadius(8)
    }
    .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })
  }

  @Builder
  private HomeCurrentRouteCard() {
    Column({ space: 10 }) {
      Row() {
        Text('当前链路').fontSize(15).fontWeight(FontWeight.Bold)
        Button('切换').height(30).fontSize(12).backgroundColor('#EEF2F7')
          .fontColor('#0F172A').borderRadius(8)
          .onClick(() => { this.currentTab = 'proxies' })
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween)
      Row() {
        Text('配置').fontSize(13).fontColor('#64748B')
        Text(this.liveProfileName).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#0F172A')
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween)
      Row() {
        Text('模式').fontSize(13).fontColor('#64748B')
        Text(this.modeLabel(this.proxyMode)).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#0F172A')
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween)
      Row() {
        Text('策略组').fontSize(13).fontColor('#64748B')
        Text(this.liveProxyName).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#0F172A')
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween)
      Row() {
        Text('运行配置').fontSize(13).fontColor('#64748B')
        Text(this.liveRuntimeConfigState).fontSize(14).fontWeight(FontWeight.Medium).fontColor('#0F172A')
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween)
    }
    .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })
  }

  @Builder
  private HomeRecentStatusCard() {
    Column({ space: 8 }) {
      this.SectionTitle('最近状态', '查看')
      this.StatusLine('配置状态',
        this.profileState.currentUid.length > 0 ? '已选择当前配置' : '等待导入订阅',
        this.profileState.currentUid.length > 0 ? '正常' : '待处理')
      this.StatusLine('运行配置', this.runtimeConfigInfo,
        this.runtimeConfigInfo === '尚未生成运行配置' && !this.isRuntimeConnected() ? '待处理' : '正常')
      this.StatusLine('核心状态',
        this.controllerStatus.available ? `mihomo ${this.controllerStatus.version} · ${this.liveConnections} 连接` : this.controllerStatus.message,
        this.controllerStatus.available ? '正常' : '待接入')
      this.StatusLine('实时流量',
        `下行 ${this.liveDownloadSpeed} / 上行 ${this.liveUploadSpeed}`,
        this.liveConnected ? '实时' : '等待')
    }
    .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })
  }

  // ============== ProxyScreen ==============
  @Builder
  private ProxyScreen() {
    Scroll() {
      Column({ space: 12 }) {
        TextInput({ placeholder: '搜索节点、地区或提供者', text: this.proxySearchText })
          .height(40).backgroundColor('#FFFFFF').borderRadius(8)
          .onChange((value: string) => { this.proxySearchText = value })

        if (this.proxyGroups.length > 0) {
          Scroll() {
            Row({ space: 8 }) {
              ForEach(this.proxyGroups, (group: ProxyGroupInfo) => {
                this.ProxyGroupOption(group.name)
              }, (group: ProxyGroupInfo) => group.name)
            }
          }
          .scrollable(ScrollDirection.Horizontal)
          .scrollBar(BarState.Off)
          .width('100%')
        } else {
          Row({ space: 8 }) {
            this.GroupButton('本地预览', true)
            this.GroupButton('等待核心', false)
          }
        }

        // Rule Match Test Card (live Mihomo engine + offline overlay fallback)
        Column({ space: 8 }) {
          Text('规则命中测试（查实时内核规则）').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
          Row({ space: 6 }) {
            TextInput({ text: this.proxyRuleTestInput, placeholder: '输入域名/URL/IP，如 claude.ai / 192.168.1.11' })
              .layoutWeight(1).height(36).fontSize(12).backgroundColor('#F8FAFC').borderRadius(8)
              .onChange((val: string) => { this.proxyRuleTestInput = val })
            Button('测试命中').height(36).fontSize(12).fontColor('#FFFFFF')
              .backgroundColor('#2563EB').borderRadius(8)
              .onClick(() => { this.runProxyRuleTest() })
          }
          .width('100%')

          Row({ space: 6 }) {
            Button('claude.ai').height(26).fontSize(11).fontColor('#2563EB').backgroundColor('#EFF6FF').borderRadius(12)
              .onClick(() => { this.runProxyRuleTest('claude.ai') })
            Button('dsh-10').height(26).fontSize(11).fontColor('#0F766E').backgroundColor('#E6FFFB').borderRadius(12)
              .onClick(() => { this.runProxyRuleTest('dsh-10.in.sjfarm.cc') })
            Button('192.168.1.11').height(26).fontSize(11).fontColor('#0F766E').backgroundColor('#E6FFFB').borderRadius(12)
              .onClick(() => { this.runProxyRuleTest('192.168.1.11') })
            Button('baidu.com').height(26).fontSize(11).fontColor('#475569').backgroundColor('#F1F5F9').borderRadius(12)
              .onClick(() => { this.runProxyRuleTest('www.baidu.com') })
          }
          .width('100%')

          if (this.proxyRuleTestResult.length > 0) {
            Column({ space: 4 }) {
              Text(this.proxyRuleTestResult)
                .fontSize(12).fontWeight(FontWeight.Bold).width('100%')
                .fontColor(!this.proxyRuleTestOk || this.proxyRuleTestIsReject ? '#DC2626' : '#0F766E')
              if (this.proxyRuleTestDetail.length > 0) {
                Text(this.proxyRuleTestDetail).fontSize(11).fontColor('#334155').width('100%')
              }
            }
            .width('100%').padding(8).borderRadius(8)
            .backgroundColor(!this.proxyRuleTestOk || this.proxyRuleTestIsReject ? '#FEF2F2' : '#F0FDFA')
            .border({ width: 1, color: !this.proxyRuleTestOk || this.proxyRuleTestIsReject ? '#FECACA' : '#99F6E4' })
          }
        }
        .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })

        Column({ space: 8 }) {
          Row() {
            Text(`节点 · ${this.getVisibleProxyNodes().length}/${this.proxyNodes.length}`).fontSize(14).fontWeight(FontWeight.Bold)
            Row({ space: 6 }) {
              Text('同步').height(30).width(48).fontSize(12).textAlign(TextAlign.Center)
                .fontColor('#2563EB').backgroundColor('#EFF6FF').borderRadius(8)
                .onClick(() => { this.refreshControllerProxies() })
              Text(this.isSpeedTesting ? '测速中' : '本组测速').height(30).width(66).fontSize(12).textAlign(TextAlign.Center)
                .fontColor('#FFFFFF').backgroundColor(this.isSpeedTesting ? '#64748B' : '#2563EB').borderRadius(8)
                .onClick(async () => { await this.runRealSpeedTest() })
              Text(this.isSpeedTesting ? '...' : '全组测速').height(30).width(66).fontSize(12).textAlign(TextAlign.Center)
                .fontColor('#FFFFFF').backgroundColor(this.isSpeedTesting ? '#64748B' : '#0F766E').borderRadius(8)
                .onClick(async () => { await this.runAllGroupsSpeedTest() })
            }
          }
          .width('100%').justifyContent(FlexAlign.SpaceBetween)
          if (this.speedTestProgress.length > 0) {
            Text(this.speedTestProgress).fontSize(12).fontColor(this.isSpeedTesting ? '#2563EB' : '#475569')
              .width('100%').padding({ top: 6, bottom: 6, left: 8, right: 8 })
              .backgroundColor(this.isSpeedTesting ? '#EFF6FF' : '#F8FAFC').borderRadius(8)
          }
          if (this.getVisibleProxyNodes().length === 0) {
            this.EmptyState('暂无节点', this.proxyStatus)
          } else {
            ForEach(this.getVisibleProxyNodes(), (node: ProxyNode) => {
              this.ProxyNodeRow(node)
            }, (node: ProxyNode) => `${node.name}-${node.delay}-${node.status ? node.status : ''}-${node.selected ? 'selected' : 'normal'}`)
          }
        }
        .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })

        this.SwitchRow('链式代理', '高级模式关闭，开启后可设置入口和出口节点', false)

        Text(this.statusMessage)
          .width('100%').fontSize(12).fontColor('#475569').textAlign(TextAlign.Center)
          .padding({ top: 4, bottom: 4 })
      }
      .padding(16)
    }
    .align(Alignment.TopStart)
    .layoutWeight(1)
  }

  // ============== ProfileScreen (Configs / Editor / Traffic Flow) ==============
  @Builder
  private ProfileScreen() {
    Scroll() {
      Column({ space: 12 }) {
        Row({ space: 6 }) {
          this.ProfileSubTabOption('配置列表', 'list')
          this.ProfileSubTabOption('编辑校验', 'editor')
          this.ProfileSubTabOption('流量规则', 'flow')
        }
        .padding(4).backgroundColor('#EEF2F7').borderRadius(8)

        if (this.profileSubTab === 'list') {
          this.ProfileListAndVersionsSubScreen()
        } else if (this.profileSubTab === 'editor') {
          this.ProfileEditorSubScreen()
        } else {
          this.ProfileFlowSubScreen()
        }
      }
      .padding(16)
    }
    .align(Alignment.TopStart)
    .layoutWeight(1)
  }

  @Builder
  private ProfileListAndVersionsSubScreen() {
    Column({ space: 12 }) {
      // Primary 1-tap QR Sync from Windows PC
      Button(this.isQrSyncing ? '正在同步电脑配置...' : '📷 扫码同步电脑配置（AI自建 + 分流 + 订阅）')
        .width('100%').height(42).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
        .backgroundColor(this.isQrSyncing ? '#64748B' : '#2563EB').borderRadius(10)
        .enabled(!this.isQrSyncing)
        .onClick(() => { this.scanQrSyncFromPc() })

      if (this.qrSyncBanner.length > 0) {
        Text(this.qrSyncBanner)
          .fontSize(12).fontWeight(FontWeight.Medium).width('100%')
          .fontColor(this.qrSyncBannerOk ? '#0F766E' : '#DC2626')
          .padding(10).borderRadius(8)
          .backgroundColor(this.qrSyncBannerOk ? '#F0FDFA' : '#FEF2F2')
          .border({ width: 1, color: this.qrSyncBannerOk ? '#99F6E4' : '#FECACA' })
      }

      Row({ space: 8 }) {
        Button('+ 订阅链接').layoutWeight(1).height(36).fontSize(12).fontColor('#FFFFFF')
          .backgroundColor('#0F766E').borderRadius(8)
          .onClick(() => {
            this.showClipboardPanel = false;
            this.showImportPanel = !this.showImportPanel;
          })
        Button('本地文件').layoutWeight(1).height(36).fontSize(12).fontColor('#0F172A')
          .backgroundColor('#EEF2F7').borderRadius(8)
          .onClick(() => { this.importLocalFile() })
        Column() {
          PasteButton({ text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
            .width('100%')
            .height(36)
            .fontSize(13)
            .fontColor('#FFFFFF')
            .backgroundColor('#475569')
            .borderRadius(8)
            .onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
              if (result === PasteButtonOnClickResult.SUCCESS) {
                this.openClipboardImportPanel(true);
              } else {
                this.openClipboardImportPanel(false);
                this.clipboardValidationChecked = true;
                this.clipboardValidationOk = false;
                this.clipboardValidationMessage = '系统未授予自动读取权限，请直接长按下方文本框手动粘贴后点「语法校验」';
              }
            })
        }
        .layoutWeight(1)
      }

      if (this.showImportPanel) { this.ImportPanel() }

      if (this.showClipboardPanel) {
        Column({ space: 10 }) {
          Row() {
            Text('📋 剪贴板导入与语法校验').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A').layoutWeight(1)
            Button('关闭').height(26).fontSize(11).fontColor('#475569').backgroundColor('#F1F5F9').borderRadius(6)
              .onClick(() => { this.showClipboardPanel = false })
          }
          .width('100%')

          TextInput({ placeholder: '配置名称（可选，留空自动命名）', text: this.clipboardDraftName })
            .height(38).fontSize(13).backgroundColor('#F8FAFC').borderRadius(8)
            .onChange((val: string) => { this.clipboardDraftName = val })

          TextArea({
            text: this.clipboardDraftText,
            placeholder: '已自动填入剪贴板内容（也可在此直接编辑或长按粘贴 Clash YAML / 订阅链接）'
          })
            .width('100%').height(180).fontSize(12).fontColor('#0F172A')
            .backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#CBD5E1' })
            .onChange((val: string) => {
              this.clipboardDraftText = val;
              this.clipboardValidationChecked = false;
            })

          if (this.clipboardValidationChecked) {
            Column({ space: 3 }) {
              Text(`${this.clipboardValidationOk ? '✓ ' : '✕ '}${this.clipboardValidationMessage}`)
                .fontSize(12).fontWeight(FontWeight.Bold).width('100%')
                .fontColor(this.clipboardValidationOk ? '#0F766E' : '#DC2626')
              if (this.clipboardValidationStats.length > 0) {
                Text(this.clipboardValidationStats).fontSize(11).fontColor('#334155').width('100%')
              }
            }
            .width('100%').padding(8).borderRadius(8)
            .backgroundColor(this.clipboardValidationOk ? '#F0FDFA' : '#FEF2F2')
            .border({ width: 1, color: this.clipboardValidationOk ? '#99F6E4' : '#FECACA' })
          }

          Row({ space: 8 }) {
            Button('语法校验').height(36).fontSize(12).fontColor('#2563EB')
              .backgroundColor('#EFF6FF').borderRadius(8)
              .onClick(() => { this.validateClipboardDraft() })

            if (this.clipboardIsUrl) {
              Button(this.isSavingClipboard ? '拉取中...' : '拉取并保存')
                .layoutWeight(1).height(36).fontSize(12).fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
                .backgroundColor(this.isSavingClipboard ? '#64748B' : '#0F766E').borderRadius(8)
                .enabled(!this.isSavingClipboard)
                .onClick(() => { this.saveClipboardDraft(false) })
            } else if (this.getCurrentActiveProfile()) {
              Button(this.isSavingClipboard ? '保存中...' : '存为当前新版本')
                .layoutWeight(1).height(36).fontSize(12).fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
                .backgroundColor(this.isSavingClipboard ? '#64748B' : '#0F766E').borderRadius(8)
                .enabled(!this.isSavingClipboard)
                .onClick(() => { this.saveClipboardDraft(true) })
              Button('另存新配置')
                .height(36).fontSize(12).fontColor('#0F172A')
                .backgroundColor('#EEF2F7').borderRadius(8)
                .enabled(!this.isSavingClipboard)
                .onClick(() => { this.saveClipboardDraft(false) })
            } else {
              Button(this.isSavingClipboard ? '保存中...' : '校验通过并保存')
                .layoutWeight(1).height(36).fontSize(12).fontWeight(FontWeight.Bold)
                .fontColor('#FFFFFF')
                .backgroundColor(this.isSavingClipboard ? '#64748B' : '#0F766E').borderRadius(8)
                .enabled(!this.isSavingClipboard)
                .onClick(() => { this.saveClipboardDraft(false) })
            }
          }
          .width('100%')
        }
        .padding(12).backgroundColor('#FFFFFF').borderRadius(10).border({ width: 1.5, color: '#99F6E4' })
      }

      // Strictly show at most 2 cards: [Current Active] + optional [Pending Newly Imported]
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          Text(this.getPendingProfile() ? '配置管理（当前 + 待生效）' : '当前生效配置')
            .fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A').layoutWeight(1)
          if (this.profileState.items.length > 0) {
            Text(this.updatingProfileUid === '__all__' ? '更新中...' : '全量更新')
              .fontSize(12).fontColor('#2563EB')
              .onClick(() => { this.updateAllProfiles() })
            Text('清空配置')
              .fontSize(12).fontColor('#DC2626')
              .onClick(() => { this.showClearAllConfirm = !this.showClearAllConfirm })
          }
        }
        .width('100%')

        if (this.showClearAllConfirm && this.profileState.items.length > 0) {
          Row({ space: 8 }) {
            Text(`清空全部 ${this.profileState.items.length} 个配置与历史版本？`)
              .fontSize(12).fontWeight(FontWeight.Medium).fontColor('#B91C1C').layoutWeight(1)
            Button('取消').height(28).fontSize(11).fontColor('#475569').backgroundColor('#FFFFFF').borderRadius(6)
              .onClick(() => { this.showClearAllConfirm = false })
            Button('确认清空').height(28).fontSize(11).fontWeight(FontWeight.Bold).fontColor('#FFFFFF')
              .backgroundColor('#DC2626').borderRadius(6)
              .onClick(() => { this.clearAllProfiles() })
          }
          .width('100%').padding(8).backgroundColor('#FEF2F2').borderRadius(8).border({ width: 1, color: '#FECACA' })
        }

        if (!this.getCurrentActiveProfile()) {
          this.EmptyState('还没有配置', '点击上方「📷 扫码同步电脑」或「+ 订阅链接」快速开始。')
        } else {
          this.CompactProfileCard(this.getCurrentActiveProfile()!, true)
        }
        if (this.editingSubMetaUid.length > 0) {
          this.SubMetaEditorCard()
        }
        if (this.getPendingProfile()) {
          this.CompactProfileCard(this.getPendingProfile()!, false)
        }
      }
      .padding(12).backgroundColor('#FFFFFF').borderRadius(10).border({ width: 1, color: '#DBE3EF' })

      // Collapsible drawer 1: Other older saved profiles (hidden by default!)
      if (this.getOtherSavedProfiles().length > 0) {
        Column({ space: 8 }) {
          Row() {
            Text(`📁 其他历史配置 (${this.getOtherSavedProfiles().length})`).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#334155').layoutWeight(1)
            Button(this.showOtherProfiles ? '收起' : '展开').height(28).fontSize(11)
              .fontColor('#475569').backgroundColor('#F1F5F9').borderRadius(6)
              .onClick(() => { this.showOtherProfiles = !this.showOtherProfiles })
          }
          .width('100%')

          if (this.showOtherProfiles) {
            ForEach(this.getOtherSavedProfiles(), (item: ClashProfile) => {
              this.ProfileRow(item)
            }, (item: ClashProfile) => `other-${item.uid}-${item.updatedAt}`)
          }
        }
        .padding(12).backgroundColor('#FFFFFF').borderRadius(10).border({ width: 1, color: '#E2E8F0' })
      }

      // Collapsible drawer 2: Current profile immutable version history (hidden by default!)
      if (this.editingProfileUid.length > 0) {
        Column({ space: 8 }) {
          Row() {
            Column({ space: 2 }) {
              Text(`🕘 历史版本快照 · ${this.editingProfileName}`).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#334155')
              Text(`当前 v${this.activeVersionNumber} · 共 ${this.versionHistory.length} 版（默认折叠）`).fontSize(11).fontColor('#64748B')
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button(this.showVersionHistory ? '收起' : `展开 (${this.versionHistory.length})`)
              .height(28).fontSize(11)
              .fontColor(this.showVersionHistory ? '#475569' : '#2563EB')
              .backgroundColor(this.showVersionHistory ? '#F1F5F9' : '#EFF6FF')
              .borderRadius(6)
              .onClick(() => { this.showVersionHistory = !this.showVersionHistory })
          }
          .width('100%')

          if (this.showVersionHistory) {
            if (this.versionHistory.length === 0) {
              this.EmptyState('暂无历史快照', '在线编辑并保存后会自动生成历史版本。')
            } else {
              ForEach(this.versionHistory, (ver: ProfileVersionEntry) => {
                this.VersionHistoryRow(ver)
              }, (ver: ProfileVersionEntry) => `ver-${ver.version}-${this.activeVersionNumber}`)
            }
          }
        }
        .padding(12).backgroundColor('#FFFFFF').borderRadius(10).border({ width: 1, color: '#E2E8F0' })
      }

      if (this.showDiffPanel) {
        this.ProfileDiffCard()
      }
    }
  }

  @Builder
  private CompactProfileCard(item: ClashProfile, isActive: boolean) {
    Column({ space: 8 }) {
      Row({ space: 6 }) {
        Column({ space: 2 }) {
          Row({ space: 6 }) {
            Text(item.name).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A').maxLines(1).layoutWeight(1)
          }
          .width('100%')
          Text(`${item.type === 'remote' ? '订阅' : '本地'} · ${item.nodeCount} 节点 · ${formatProfileUpdatedAt(item.updatedAt)}`)
            .fontSize(11).fontColor('#64748B')
          Row({ space: 6 }) {
            if (isActive) {
              Text(`当前生效 v${this.activeVersionNumber > 0 ? this.activeVersionNumber : 1}`)
                .fontSize(10).fontWeight(FontWeight.Medium).fontColor('#0F766E')
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor('#CCFBF1').borderRadius(8)
            }
            if (item.traffic.length > 0 && item.traffic !== '未知') {
              Text(item.traffic).fontSize(11).fontColor('#0F766E')
            }
          }
          if (item.type === 'remote' && item.userAgent && item.userAgent.length > 0) {
            Text(`UA: ${item.userAgent}`)
              .fontSize(10).fontColor('#334155')
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor('#E2E8F0').borderRadius(6)
              .maxLines(1)
          }
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
        if (isActive) {
          Button(this.liveConnected ? '重启' : '启动')
            .height(32).fontSize(12).fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor(this.liveConnected ? '#0F766E' : '#10B981')
            .borderRadius(8)
            .padding({ left: 14, right: 14 })
            .onClick(() => { this.launchActiveProfileOnHome() })
        } else {
          this.Pill('待生效 · 新导入', '#2563EB', '#DBEAFE')
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (isActive) {
        Row({ space: 6 }) {
          if (item.type === 'remote') {
            Button(this.updatingProfileUid === item.uid ? '更新中...' : '更新订阅')
              .layoutWeight(1).height(32).fontSize(11).fontColor('#FFFFFF')
              .backgroundColor(this.updatingProfileUid === item.uid ? '#64748B' : '#0F766E').borderRadius(6)
              .enabled(this.updatingProfileUid.length === 0)
              .onClick(() => { this.updateProfile(item.uid) })
          }
          Button('订阅设置').layoutWeight(1).height(32).fontSize(11).fontColor('#334155')
            .backgroundColor('#F1F5F9').borderRadius(6)
            .onClick(() => { this.openSubMetaEditor(item) })
          Button('编辑 YAML').layoutWeight(1).height(32).fontSize(11).fontColor('#0F766E')
            .backgroundColor('#E6FFFB').borderRadius(6)
            .onClick(() => { this.openProfileWorkspace(item.uid, 'editor', false) })
          Button('流量规则').layoutWeight(1).height(32).fontSize(11).fontColor('#2563EB')
            .backgroundColor('#EFF6FF').borderRadius(6)
            .onClick(() => { this.openProfileWorkspace(item.uid, 'flow', false) })
        }
        .width('100%')
      } else {
        Row({ space: 8 }) {
          Button('立即切换生效').layoutWeight(1).height(34).fontSize(12).fontColor('#FFFFFF')
            .backgroundColor('#2563EB').borderRadius(6)
            .onClick(() => { this.activateProfile(item.uid) })
          Button('编辑查看').height(34).fontSize(12).fontColor('#334155')
            .backgroundColor('#F1F5F9').borderRadius(6)
            .onClick(() => { this.openProfileWorkspace(item.uid, 'editor', false) })
          Button('删除').height(34).fontSize(12).fontColor('#DC2626')
            .backgroundColor('#FEF2F2').borderRadius(6)
            .onClick(() => { this.removeProfile(item.uid) })
        }
        .width('100%')
      }
    }
    .padding(12)
    .backgroundColor(isActive ? '#F0FDFA' : '#EFF6FF')
    .borderRadius(10)
    .border({ width: 1.5, color: isActive ? '#14B8A6' : '#60A5FA' })
  }

  @Builder
  private VersionHistoryRow(ver: ProfileVersionEntry) {
    Column({ space: 6 }) {
      Row({ space: 6 }) {
        Text(`v${ver.version}`).fontSize(13).fontWeight(FontWeight.Bold)
          .fontColor(ver.version === this.activeVersionNumber ? '#0F766E' : '#0F172A')
        this.Pill(ProfileVersionService.sourceLabel(ver.source), '#2563EB', '#EFF6FF')
        if (ver.version === this.activeVersionNumber) {
          this.Pill('激活中', '#0F766E', '#E6FFFB')
        }
        Blank()
        Text(formatProfileUpdatedAt(ver.createdAt)).fontSize(11).fontColor('#64748B')
      }
      .width('100%')

      Text(`${ver.note} · ${ver.nodeCount} 节点 / ${ver.ruleCount} 规则`).fontSize(12).fontColor('#475569').width('100%')

      Row({ space: 6 }) {
        Button('载入编辑').layoutWeight(1).height(28).fontSize(11).fontColor('#334155')
          .backgroundColor('#F1F5F9').borderRadius(6)
          .onClick(() => { this.loadVersionIntoEditor(ver.version) })
        if (ver.version !== this.activeVersionNumber) {
          Button('对比 Diff').layoutWeight(1).height(28).fontSize(11).fontColor('#2563EB')
            .backgroundColor('#EFF6FF').borderRadius(6)
            .onClick(() => { this.compareHistoryVersion(ver.version) })
          Button('回滚至此版').layoutWeight(1).height(28).fontSize(11).fontColor('#D97706')
            .backgroundColor('#FFF7ED').borderRadius(6)
            .onClick(() => { this.rollbackToHistoryVersion(ver.version) })
        }
      }
      .width('100%')
    }
    .padding(10)
    .backgroundColor(ver.version === this.activeVersionNumber ? '#F0FDFA' : '#F8FAFC')
    .borderRadius(8)
    .border({ width: 1, color: ver.version === this.activeVersionNumber ? '#99F6E4' : '#E2E8F0' })
  }

  @Builder
  private ProfileOverlaySubScreen() {
    Column({ space: 12 }) {
      Column({ space: 10 }) {
        Row() {
          Text('🛡️ AI 严格走自建节点').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A').layoutWeight(1)
          Text(this.overlayConfig.enabled ? `已启用 · ${this.overlayConfig.aiProviders.length} 家 AI` : '未启用')
            .fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor(this.overlayConfig.enabled ? '#0F766E' : '#64748B')
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(this.overlayConfig.enabled ? '#E6FFFB' : '#F1F5F9')
            .borderRadius(12)
        }
        .width('100%')

        Column() {
          this.ReactiveSwitchRow('启用 AI 严格自建保护', '默认 Fail-Closed：所选 AI 仅走自建出口，不可达直接断开（更新订阅永不覆盖）', 'overlay.enabled')
        }.onClick(() => { this.toggleOverlayEnabled() })

        Row() {
          Text('第 1 步：勾选哪些 AI 走自建（默认全选）').fontSize(12).fontWeight(FontWeight.Bold).fontColor('#0F172A').layoutWeight(1)
          Button('全选').height(26).fontSize(11).fontColor('#0F766E').backgroundColor('#E6FFFB').borderRadius(6)
            .onClick(() => { this.selectAllAiProviders() })
          Button('仅核心三家').height(26).fontSize(11).fontColor('#2563EB').backgroundColor('#EFF6FF').borderRadius(6).margin({ left: 6 })
            .onClick(() => { this.selectCoreAiProviders() })
        }
        .width('100%')

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.getAiProviderPresets(), (preset: AiProviderPreset) => {
            Column({ space: 2 }) {
              Text(`${this.isAiProviderSelected(preset.id) ? '✓ ' : ''}${preset.label}`)
                .fontSize(12).fontWeight(FontWeight.Bold)
                .fontColor(this.isAiProviderSelected(preset.id) ? '#FFFFFF' : '#334155')
              Text(preset.subtitle)
                .fontSize(10)
                .fontColor(this.isAiProviderSelected(preset.id) ? '#CCFBF1' : '#64748B')
                .maxLines(1)
            }
            .alignItems(HorizontalAlign.Start)
            .padding({ left: 10, right: 10, top: 8, bottom: 8 })
            .margin({ right: 8, bottom: 8 })
            .borderRadius(8)
            .backgroundColor(this.isAiProviderSelected(preset.id) ? '#0F766E' : '#F8FAFC')
            .border({ width: 1, color: this.isAiProviderSelected(preset.id) ? '#0F766E' : '#CBD5E1' })
            .onClick(() => { this.toggleAiProviderSelection(preset.id) })
          }, (preset: AiProviderPreset) => `ai-preset-${preset.id}-${this.isAiProviderSelected(preset.id) ? '1' : '0'}`)
        }
        .width('100%')

        Row() {
          Text('第 2 步：粘贴自建节点（vless:// 等链接或 YAML）').fontSize(12).fontWeight(FontWeight.Bold).fontColor('#0F172A').layoutWeight(1)
          Button('填入示例').height(26).fontSize(11).fontColor('#2563EB')
            .backgroundColor('#EFF6FF').borderRadius(6)
            .onClick(() => { this.insertSelfHostedVlessTemplate() })
        }
        .width('100%')

        TextArea({ text: this.overlayProxiesDraft, placeholder: '最简方式：直接粘贴 vless:// / trojan:// / ss:// / hy2:// 节点链接（一行一个）\n或粘贴标准 Clash YAML 节点片段' })
          .width('100%').height(130).fontSize(12).fontColor('#0F172A')
          .backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#CBD5E1' })
          .onChange((val: string) => { this.overlayProxiesDraft = val })

        Row() {
          Text('高级自定义（补充规则 / 额外域名 / Fail-Closed）').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#475569').layoutWeight(1)
          Button(this.showOverlayAdvanced ? '收起高级' : '展开高级').height(26).fontSize(11)
            .fontColor('#475569').backgroundColor('#F1F5F9').borderRadius(6)
            .onClick(() => { this.showOverlayAdvanced = !this.showOverlayAdvanced })
        }
        .width('100%')

        if (this.showOverlayAdvanced) {
          Column({ space: 8 }) {
            Column() {
              this.ReactiveSwitchRow('启用 AI 严格分流规则', '关闭后仅注入自建节点与自定义规则', 'overlay.aiStrictEnabled')
            }.onClick(() => { this.toggleOverlayAiStrict() })

            Column() {
              this.ReactiveSwitchRow('Fail-Closed 不可达直接断开', 'AI 组仅含自建节点（未填时 REJECT），绝不漏给国内或商业节点', 'overlay.failClosed')
            }.onClick(() => { this.toggleOverlayAiFailClosed() })

            Text('AI 策略组名称').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#334155').width('100%')
            TextInput({ text: this.overlayGroupNameDraft, placeholder: DEFAULT_AI_GROUP_NAME })
              .height(36).fontSize(12).backgroundColor('#F8FAFC').borderRadius(8)
              .onChange((val: string) => { this.overlayGroupNameDraft = val })

            Text('自定义最高优先级规则（每行一条）').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#334155').width('100%')
            TextArea({ text: this.overlayCustomRulesDraft, placeholder: 'IP-CIDR,192.168.1.0/24,Tailscale,no-resolve\nDOMAIN-SUFFIX,tuyacn.com,DIRECT' })
              .width('100%').height(90).fontSize(12).fontColor('#0F172A')
              .backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#CBD5E1' })
              .onChange((val: string) => { this.overlayCustomRulesDraft = val })

            Text('额外补充 AI 域名后缀（预设已内置主流 AI，可留空）').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#334155').width('100%')
            TextArea({ text: this.overlayAiDomainsDraft, placeholder: '留空即可使用上方一键勾选预设' })
              .width('100%').height(80).fontSize(12).fontColor('#0F172A')
              .backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#CBD5E1' })
              .onChange((val: string) => { this.overlayAiDomainsDraft = val })

            Text('额外补充 AI 关键词（逗号分隔，可留空）').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#334155').width('100%')
            TextInput({ text: this.overlayAiKeywordsDraft, placeholder: '留空即可' })
              .height(36).fontSize(12).backgroundColor('#F8FAFC').borderRadius(8)
              .onChange((val: string) => { this.overlayAiKeywordsDraft = val })

            Text('直连保护域名（自建节点的 server 已自动保护）').fontSize(12).fontWeight(FontWeight.Medium).fontColor('#334155').width('100%')
            TextInput({ text: this.overlayDirectDomainsDraft, placeholder: 'derp.sjfarm.cc' })
              .height(36).fontSize(12).backgroundColor('#F8FAFC').borderRadius(8)
              .onChange((val: string) => { this.overlayDirectDomainsDraft = val })
          }
          .width('100%').padding(10).backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
        }

        if (this.overlayBanner.length > 0) {
          Text(this.overlayBanner)
            .fontSize(12).fontWeight(FontWeight.Medium).width('100%')
            .fontColor(this.overlayBannerOk ? '#0F766E' : '#DC2626')
            .padding(10).borderRadius(8)
            .backgroundColor(this.overlayBannerOk ? '#F0FDFA' : '#FEF2F2')
            .border({ width: 1, color: this.overlayBannerOk ? '#99F6E4' : '#FECACA' })
        }

        Button(this.isSavingOverlay ? '融合校验保存中...' : '一键保存并启用 AI 自建分流')
          .width('100%').height(40).fontSize(13).fontColor('#FFFFFF')
          .backgroundColor(this.isSavingOverlay ? '#64748B' : '#0F766E').borderRadius(8)
          .enabled(!this.isSavingOverlay)
          .onClick(() => { this.saveOverlayConfig() })
      }
      .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })

      Column({ space: 8 }) {
        Text('🔄 双端迁移同步（Windows ↔ 鸿蒙 JSON 互通）').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
        Text('导出 JSON 可直接导入 Windows 版桌面端；也可把 Windows 导出的 JSON 复制到剪贴板后一键导入手机。')
          .fontSize(11).fontColor('#64748B').width('100%')
        Row({ space: 8 }) {
          Button('复制完整 JSON').layoutWeight(1).height(34).fontSize(12).fontColor('#2563EB')
            .backgroundColor('#EFF6FF').borderRadius(8)
            .onClick(() => { this.exportCrossPlatformBackup(false) })
          Button('复制脱敏 JSON').layoutWeight(1).height(34).fontSize(12).fontColor('#334155')
            .backgroundColor('#F1F5F9').borderRadius(8)
            .onClick(() => { this.exportCrossPlatformBackup(true) })
        }
        .width('100%')
        PasteButton({ text: PasteDescription.PASTE, buttonType: ButtonType.Normal })
          .width('100%')
          .height(38)
          .fontSize(13)
          .fontColor('#FFFFFF')
          .backgroundColor('#2563EB')
          .borderRadius(8)
          .onClick((_event: ClickEvent, result: PasteButtonOnClickResult) => {
            if (result === PasteButtonOnClickResult.SUCCESS) {
              this.importCrossPlatformBackupFromClipboard();
            } else {
              this.overlayBannerOk = false;
              this.overlayBanner = '系统未授予剪贴板读取授权，请重试或使用「扫码同步电脑」';
            }
          })
      }
      .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })
    }
  }

  @Builder
  private ProfileEditorSubScreen() {
    Column({ space: 10 }) {
      if (this.editingProfileUid.length === 0) {
        this.EmptyState('未选择配置', '请先在「配置列表」中导入或点击任意配置的「编辑/校验」。')
      } else {
        Column({ space: 8 }) {
          Row() {
            Text(`编辑：${this.editingProfileName} (当前 v${this.activeVersionNumber})`)
              .fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A').layoutWeight(1)
            Button('重置').height(28).fontSize(12).fontColor('#64748B')
              .backgroundColor('#F1F5F9').borderRadius(6)
              .onClick(() => {
                this.editorDraftText = this.editorBaseText;
                this.editorValidationChecked = false;
                this.editorSaveBanner = '';
                this.showDiffPanel = false;
              })
          }
          .width('100%')

          if (this.tsPrefs.managedByApp && this.tsPrefs.enabled) {
            Text('提示：自建节点与 AI 规则建议维护在「自建与AI」页，Tailscale 由「Tailscale」页托管，更新订阅互不覆盖。')
              .fontSize(11).fontColor('#0F766E').width('100%')
              .padding(8).backgroundColor('#F0FDFA').borderRadius(6)
          }

          TextArea({ text: this.editorDraftText, placeholder: 'YAML 配置内容...' })
            .width('100%')
            .height(340)
            .fontSize(12)
            .fontColor('#0F172A')
            .backgroundColor('#F8FAFC')
            .borderRadius(8)
            .border({ width: 1, color: '#CBD5E1' })
            .onChange((val: string) => {
              this.editorDraftText = val;
              this.editorValidationChecked = false;
              this.editorSaveBanner = '';
            })

          TextInput({ text: this.editorCommitNote, placeholder: '本次修改备注（可选，例如：新增内网规则）' })
            .height(38).fontSize(13).backgroundColor('#F8FAFC').borderRadius(8)
            .onChange((val: string) => { this.editorCommitNote = val })

          Row({ space: 8 }) {
            Button('融合校验').layoutWeight(1).height(36).fontSize(13).fontColor('#2563EB')
              .backgroundColor('#EFF6FF').borderRadius(8)
              .onClick(() => { this.runKernelValidateDraft() })
            Button('预览 Diff').layoutWeight(1).height(36).fontSize(13).fontColor('#334155')
              .backgroundColor('#EEF2F7').borderRadius(8)
              .onClick(() => { this.previewDraftDiff() })
            Button(this.isSavingDraft ? '保存中...' : '保存新版本').layoutWeight(1).height(36).fontSize(13).fontColor('#FFFFFF')
              .backgroundColor(this.isSavingDraft ? '#64748B' : '#0F766E').borderRadius(8)
              .enabled(!this.isSavingDraft)
              .onClick(() => { this.saveDraftAsNewVersion() })
          }
          .width('100%')

          if (this.editorSaveBanner.length > 0) {
            Text(this.editorSaveBannerOk ? `✅ ${this.editorSaveBanner}` : `⚠ ${this.editorSaveBanner}`)
              .fontSize(12).fontWeight(FontWeight.Bold).width('100%')
              .fontColor(this.editorSaveBannerOk ? '#0F766E' : '#D97706')
              .padding(10).borderRadius(8)
              .backgroundColor(this.editorSaveBannerOk ? '#ECFDF5' : '#FFFBEB')
              .border({ width: 1, color: this.editorSaveBannerOk ? '#A7F3D0' : '#FDE68A' })
          }

          if (this.editorValidationChecked) {
            Column({ space: 4 }) {
              Text(this.editorValidationOk ? `✅ ${this.editorValidationMessage}` : `❌ ${this.editorValidationMessage}`)
                .fontSize(12).fontWeight(FontWeight.Bold)
                .fontColor(this.editorValidationOk ? '#0F766E' : '#DC2626')
                .width('100%')
              if (this.editorValidationStats.length > 0) {
                Text(this.editorValidationStats).fontSize(11).fontColor('#334155').width('100%')
              }
              ForEach(this.editorValidationWarnings, (warn: string, idx: number) => {
                Text(`⚠ ${warn}`).fontSize(11).fontColor('#D97706').width('100%')
              }, (warn: string, idx: number) => `val-warn-${idx}-${warn}`)
            }
            .width('100%').padding(10).borderRadius(8)
            .backgroundColor(this.editorValidationOk ? '#F0FDFA' : '#FEF2F2')
            .border({ width: 1, color: this.editorValidationOk ? '#99F6E4' : '#FECACA' })
          }
        }
        .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })

        if (this.showDiffPanel) {
          this.ProfileDiffCard()
        }
      }
    }
  }

  @Builder
  private ProfileDiffCard() {
    Column({ space: 8 }) {
      Row() {
        Column({ space: 2 }) {
          Text(this.diffTitle).fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A')
          Text(this.diffSummaryText).fontSize(11).fontColor('#64748B')
        }
        .alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button(this.diffContextOnly ? '看全文' : '仅变更').height(28).fontSize(11).fontColor('#2563EB')
          .backgroundColor('#EFF6FF').borderRadius(6)
          .onClick(() => { this.diffContextOnly = !this.diffContextOnly })
        Button('收起').height(28).fontSize(11).fontColor('#64748B')
          .backgroundColor('#F1F5F9').borderRadius(6).margin({ left: 6 })
          .onClick(() => { this.showDiffPanel = false })
      }
      .width('100%')

      if (this.visibleDiffLines().length === 0) {
        Text('无差异行').fontSize(12).fontColor('#64748B').width('100%').padding(8)
      } else {
        ForEach(this.visibleDiffLines(), (dl: DiffLine, idx: number) => {
          Row({ space: 6 }) {
            Text(dl.kind === 'add' ? '+' : dl.kind === 'del' ? '-' : dl.kind === 'sep' ? '·' : ' ')
              .fontSize(11).fontWeight(FontWeight.Bold).width(12)
              .fontColor(dl.kind === 'add' ? '#047857' : dl.kind === 'del' ? '#B91C1C' : '#94A3B8')
            Text(dl.kind === 'sep' ? '' : `${dl.newLineNo > 0 ? dl.newLineNo : dl.oldLineNo}`)
              .fontSize(10).fontColor('#94A3B8').width(28)
            Text(dl.text)
              .fontSize(11).layoutWeight(1)
              .fontColor(dl.kind === 'add' ? '#065F46' : dl.kind === 'del' ? '#991B1B' : dl.kind === 'sep' ? '#64748B' : '#334155')
          }
          .width('100%').padding({ left: 6, right: 6, top: 3, bottom: 3 })
          .backgroundColor(dl.kind === 'add' ? '#ECFDF5' : dl.kind === 'del' ? '#FEF2F2' : dl.kind === 'sep' ? '#F1F5F9' : '#FFFFFF')
        }, (dl: DiffLine, idx: number) => `diff-${idx}-${dl.kind}-${dl.oldLineNo}-${dl.newLineNo}`)
      }
    }
    .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#BFDBFE' })
  }

  @Builder
  private ProfileFlowSubScreen() {
    Column({ space: 12 }) {
      if (this.editingProfileUid.length === 0) {
        this.EmptyState('未加载配置', '请先导入或在配置列表选择一份配置。')
      } else {
        // 1. Route Hit Simulator
        Column({ space: 8 }) {
          Text('实时流量路由模拟器').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
          Row({ space: 6 }) {
            TextInput({ text: this.simQuery, placeholder: '输入域名或 IP，如 claude.ai / 192.168.1.10' })
              .layoutWeight(1).height(38).fontSize(13).backgroundColor('#F8FAFC').borderRadius(8)
              .onChange((val: string) => { this.runRouteSimulation(val) })
            Button('模拟').height(38).fontSize(13).fontColor('#FFFFFF')
              .backgroundColor('#2563EB').borderRadius(8)
              .onClick(() => { this.runRouteSimulation() })
          }
          .width('100%')

          Row({ space: 6 }) {
            Button('claude.ai').height(26).fontSize(11).fontColor('#2563EB').backgroundColor('#EFF6FF').borderRadius(12)
              .onClick(() => { this.runRouteSimulation('claude.ai') })
            Button('192.168.1.10').height(26).fontSize(11).fontColor('#0F766E').backgroundColor('#E6FFFB').borderRadius(12)
              .onClick(() => { this.runRouteSimulation('192.168.1.10') })
            Button('nas.ts.net').height(26).fontSize(11).fontColor('#0F766E').backgroundColor('#E6FFFB').borderRadius(12)
              .onClick(() => { this.runRouteSimulation('nas.ts.net') })
            Button('baidu.com').height(26).fontSize(11).fontColor('#475569').backgroundColor('#F1F5F9').borderRadius(12)
              .onClick(() => { this.runRouteSimulation('www.baidu.com') })
          }
          .width('100%')

          if (this.simResult.query.length > 0) {
            Column({ space: 6 }) {
              Row() {
                Text(this.simResult.ruleIndex > 0 ? `命中规则 #${this.simResult.ruleIndex}` : '模式直判')
                  .fontSize(12).fontWeight(FontWeight.Bold).fontColor(this.categoryAccentColor(this.simResult.category))
                this.Pill(this.simResult.target, this.categoryAccentColor(this.simResult.category), this.categoryBgColor(this.simResult.category))
              }
              .width('100%').justifyContent(FlexAlign.SpaceBetween)
              Text(`链路：${this.simResult.query}  ==>  ${this.simResult.chain.join(' -> ')}`)
                .fontSize(12).fontWeight(FontWeight.Medium).fontColor('#0F172A').width('100%')
              Text(`规则：${this.simResult.matchedRuleRaw}`).fontSize(11).fontColor('#475569').width('100%')
              Text(`DNS：${this.simResult.dnsNote}`).fontSize(11).fontColor('#64748B').width('100%')
            }
            .width('100%').padding(10).borderRadius(8)
            .backgroundColor(this.categoryBgColor(this.simResult.category))
            .border({ width: 1, color: '#CBD5E1' })
          }
        }
        .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })

        // 2. Traffic Flow Buckets Overview
        Column({ space: 8 }) {
          Text('流量去向总览').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
          Row({ space: 6 }) {
            this.Metric('Tailscale', `${this.trafficAnalysis.tailscaleRuleCount}`)
            this.Metric('代理规则', `${this.trafficAnalysis.proxyRuleCount}`)
            this.Metric('直连', `${this.trafficAnalysis.directRuleCount}`)
            this.Metric('拦截', `${this.trafficAnalysis.rejectRuleCount}`)
          }
          .width('100%')

          ForEach(this.trafficAnalysis.buckets, (bucket: FlowBucket) => {
            Column({ space: 4 }) {
              Row() {
                Text(bucket.title).fontSize(13).fontWeight(FontWeight.Bold)
                  .fontColor(this.categoryAccentColor(bucket.category))
                this.Pill(`${bucket.ruleCount} 条规则`, this.categoryAccentColor(bucket.category), this.categoryBgColor(bucket.category))
              }
              .width('100%').justifyContent(FlexAlign.SpaceBetween)
              Text(`出口链：${bucket.chainPreview}`).fontSize(11).fontColor('#334155').width('100%')
              Text(bucket.sampleRules.join(' · ')).fontSize(11).fontColor('#64748B').width('100%')
            }
            .width('100%').padding(10).backgroundColor('#F8FAFC').borderRadius(8)
            .border({ width: 1, color: '#E2E8F0' })
          }, (bucket: FlowBucket) => `${bucket.id}-${bucket.ruleCount}`)
        }
        .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })

        // 3. Visual Rule List + Quick Add
        Column({ space: 8 }) {
          Row() {
            Text(`规则优先级链 · ${this.trafficAnalysis.rules.length}`).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
            Button(this.showAddRulePanel ? '收起' : '+ 新增规则').height(30).fontSize(12).fontColor('#FFFFFF')
              .backgroundColor('#0F766E').borderRadius(8)
              .onClick(() => { this.showAddRulePanel = !this.showAddRulePanel })
          }
          .width('100%').justifyContent(FlexAlign.SpaceBetween)

          if (this.showAddRulePanel) {
            Column({ space: 8 }) {
              Row({ space: 6 }) {
                Button('域名后缀').layoutWeight(1).height(28).fontSize(11)
                  .fontColor(this.newRuleType === 'DOMAIN-SUFFIX' ? '#FFFFFF' : '#334155')
                  .backgroundColor(this.newRuleType === 'DOMAIN-SUFFIX' ? '#0F766E' : '#F1F5F9').borderRadius(6)
                  .onClick(() => { this.newRuleType = 'DOMAIN-SUFFIX' })
                Button('精确域名').layoutWeight(1).height(28).fontSize(11)
                  .fontColor(this.newRuleType === 'DOMAIN' ? '#FFFFFF' : '#334155')
                  .backgroundColor(this.newRuleType === 'DOMAIN' ? '#0F766E' : '#F1F5F9').borderRadius(6)
                  .onClick(() => { this.newRuleType = 'DOMAIN' })
                Button('关键词').layoutWeight(1).height(28).fontSize(11)
                  .fontColor(this.newRuleType === 'DOMAIN-KEYWORD' ? '#FFFFFF' : '#334155')
                  .backgroundColor(this.newRuleType === 'DOMAIN-KEYWORD' ? '#0F766E' : '#F1F5F9').borderRadius(6)
                  .onClick(() => { this.newRuleType = 'DOMAIN-KEYWORD' })
                Button('IP-CIDR').layoutWeight(1).height(28).fontSize(11)
                  .fontColor(this.newRuleType === 'IP-CIDR' ? '#FFFFFF' : '#334155')
                  .backgroundColor(this.newRuleType === 'IP-CIDR' ? '#0F766E' : '#F1F5F9').borderRadius(6)
                  .onClick(() => { this.newRuleType = 'IP-CIDR' })
              }
              .width('100%')

              TextInput({ text: this.newRulePayload, placeholder: '匹配内容，如 example.com 或 192.168.10.0/24' })
                .height(38).fontSize(13).backgroundColor('#FFFFFF').borderRadius(8)
                .onChange((val: string) => { this.newRulePayload = val })

              Text('目标出口：').fontSize(12).fontColor('#475569').width('100%')
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.trafficAnalysis.availableTargets, (tgt: string) => {
                  Text(tgt).fontSize(11)
                    .fontColor(this.newRuleTarget === tgt ? '#FFFFFF' : '#334155')
                    .backgroundColor(this.newRuleTarget === tgt ? '#2563EB' : '#FFFFFF')
                    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
                    .margin({ right: 6, bottom: 6 })
                    .borderRadius(12)
                    .border({ width: 1, color: this.newRuleTarget === tgt ? '#2563EB' : '#CBD5E1' })
                    .onClick(() => { this.newRuleTarget = tgt })
                }, (tgt: string) => `tgt-${tgt}`)
              }

              Row({ space: 8 }) {
                Button(this.newRulePrepend ? '插入位置：最顶部优先' : '插入位置：MATCH 之前')
                  .layoutWeight(1).height(32).fontSize(11).fontColor('#334155')
                  .backgroundColor('#E2E8F0').borderRadius(6)
                  .onClick(() => { this.newRulePrepend = !this.newRulePrepend })
                Button('确认添加并存新版本').height(32).fontSize(12).fontColor('#FFFFFF')
                  .backgroundColor('#0F766E').borderRadius(6)
                  .onClick(() => { this.submitNewRule() })
              }
              .width('100%')
            }
            .padding(10).backgroundColor('#F0FDFA').borderRadius(8).border({ width: 1, color: '#99F6E4' })
          }

          TextInput({ text: this.ruleSearchText, placeholder: '搜索规则域名、网段或策略组...' })
            .height(36).fontSize(12).backgroundColor('#F8FAFC').borderRadius(8)
            .onChange((val: string) => { this.ruleSearchText = val })

          ForEach(this.getFilteredRules(), (rule: ParsedRuleItem) => {
            Row({ space: 6 }) {
              Text(`#${rule.index}`).fontSize(11).fontColor('#94A3B8').width(28)
              Column({ space: 2 }) {
                Text(`${rule.ruleType}${rule.payload.length > 0 ? ` · ${rule.payload}` : ''}`)
                  .fontSize(12).fontWeight(FontWeight.Medium).fontColor('#0F172A')
                Text(`-> ${rule.chainLabel}`).fontSize(11).fontColor(this.categoryAccentColor(rule.category))
              }
              .alignItems(HorizontalAlign.Start).layoutWeight(1)
              Button('↑').width(28).height(26).fontSize(11).fontColor('#334155').backgroundColor('#F1F5F9').borderRadius(6)
                .onClick(() => { this.moveVisualRule(rule.index, -1) })
              Button('↓').width(28).height(26).fontSize(11).fontColor('#334155').backgroundColor('#F1F5F9').borderRadius(6)
                .onClick(() => { this.moveVisualRule(rule.index, 1) })
              Button('删').width(32).height(26).fontSize(11).fontColor('#DC2626').backgroundColor('#FEF2F2').borderRadius(6)
                .onClick(() => { this.deleteVisualRule(rule) })
            }
            .width('100%').padding(8).backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
          }, (rule: ParsedRuleItem) => `rule-${rule.index}-${rule.raw}`)
        }
        .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })
      }
    }
  }

  // ============== TailscaleScreen (Embedded Native Management) ==============
  @Builder
  private TailscaleScreen() {
    Scroll() {
      Column({ space: 12 }) {
        // 1. Hero Status & Account Card
        Column({ space: 10 }) {
          Row() {
            Row({ space: 8 }) {
              Text('Tailscale 组网').fontSize(16).fontWeight(FontWeight.Bold).fontColor('#0F172A')
              this.Pill(this.tailscaleStateLabel(), this.tailscaleStateColor(), this.tailscaleStateBgColor())
            }
            Button('刷新').height(30).fontSize(12).fontColor('#2563EB')
              .backgroundColor('#EFF6FF').borderRadius(8)
              .onClick(() => { this.refreshTailscaleStatus() })
          }
          .width('100%').justifyContent(FlexAlign.SpaceBetween)

          if (this.tsControl.tailnetName.length > 0) {
            this.InfoRow('Tailnet', this.tsControl.tailnetName)
          }
          if (this.tsControl.loginName.length > 0) {
            this.InfoRow('登录账号', this.tsControl.loginName)
          }
          this.InfoRow('本机节点', this.tailscaleHostname.length > 0 ? this.tailscaleHostname : this.tsPrefs.hostname)
          if (this.tailscaleIps.length > 0) {
            Row() {
              Text('Tailscale IP').fontSize(13).fontColor('#64748B')
              Text(this.tailscaleIps).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#0F766E')
                .onClick(() => { this.copyPlainText('Tailscale IP', this.tailscaleIps) })
            }
            .width('100%').justifyContent(FlexAlign.SpaceBetween)
          }

          if (this.tailscaleAuthUrl.length > 0) {
            Column({ space: 8 }) {
              Text('需要浏览器授权登录').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#0F766E').width('100%')
              Row({ space: 8 }) {
                Button('🌐 浏览器打开').layoutWeight(1).height(34).fontSize(12).fontWeight(FontWeight.Bold)
                  .fontColor('#FFFFFF').backgroundColor('#0F766E').borderRadius(8)
                  .onClick(() => { this.openTailscaleAuthUrlInBrowser() })
                Button('复制链接').height(34).fontSize(12).fontWeight(FontWeight.Medium)
                  .fontColor('#0F766E').backgroundColor('#FFFFFF').borderRadius(8)
                  .border({ width: 1, color: '#14B8A6' })
                  .onClick(() => { this.copyTailscaleAuthUrl() })
              }
              .width('100%')
              Text(this.tailscaleAuthUrl).fontSize(11).fontColor('#115E59').width('100%')
                .copyOption(CopyOptions.LocalDevice)
            }
            .padding(10).backgroundColor('#F0FDFA').borderRadius(8).border({ width: 1, color: '#99F6E4' })
          }

          Row({ space: 8 }) {
            Button('获取登录链接').layoutWeight(1).height(34).fontSize(12).fontColor('#FFFFFF')
              .backgroundColor('#0F766E').borderRadius(8)
              .onClick(() => { this.triggerTailscaleLogin() })
            Button('登出切换账号').layoutWeight(1).height(34).fontSize(12).fontColor('#DC2626')
              .backgroundColor('#FEF2F2').borderRadius(8)
              .onClick(() => { this.triggerTailscaleLogout() })
          }
          .width('100%')

          if (this.tsBusyMessage.length > 0) {
            Text(this.tsBusyMessage).fontSize(12).fontColor('#2563EB').width('100%')
          }
          if (this.tailscaleError.length > 0) {
            Text(`错误：${this.tailscaleError}`).fontSize(12).fontColor('#DC2626').width('100%')
          }
        }
        .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })

        // 2. Native Peers List with Live Ping (HIGH PRIORITY — moved right under status!)
        Column({ space: 8 }) {
          Row() {
            Text(`设备列表 · ${this.tsControl.peers.length}`).fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
            Text(`${this.tsPingRefreshTick}`).width(1).height(1).opacity(0)
            Button(this.isBatchPingingPeers ? 'Ping 测速中...' : '⚡ 一键 Ping 全部')
              .height(30).fontSize(12).fontColor('#FFFFFF')
              .backgroundColor(this.isBatchPingingPeers ? '#64748B' : '#0F766E').borderRadius(8)
              .enabled(!this.isBatchPingingPeers)
              .onClick(() => { this.pingAllOnlineTailscalePeers() })
          }
          .width('100%').justifyContent(FlexAlign.SpaceBetween)

          if (this.batchPingProgress.length > 0) {
            Text(this.batchPingProgress).fontSize(12).fontColor('#0F766E').width('100%')
              .padding({ left: 8, right: 8, top: 6, bottom: 6 }).backgroundColor('#F0FDFA').borderRadius(6)
          }

          if (this.tsControl.peers.length === 0) {
            this.EmptyState(
              this.tsControl.reachable ? '暂无对端设备' : 'Tailscale 核心未运行',
              this.tsControl.reachable ? '完成授权登录后将显示 Tailnet 内所有在线与离线设备。' : '请在首页点击「连接」启动 VPN 后查看设备列表与测速。'
            )
          } else {
            ForEach(this.tsControl.peers, (peer: TailscalePeerItem) => {
              Column({ space: 6 }) {
                Row({ space: 8 }) {
                  Column().width(8).height(8).borderRadius(4).backgroundColor(peer.online ? '#10B981' : '#CBD5E1')
                  Column({ space: 2 }) {
                    Text(`${peer.hostName}${peer.os.length > 0 ? ` · ${peer.os}` : ''}`)
                      .fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A')
                    Text(peer.tailscaleIPs.length > 0 ? peer.tailscaleIPs[0] : peer.dnsName)
                      .fontSize(12).fontColor('#0F766E')
                      .onClick(() => {
                        if (peer.tailscaleIPs.length > 0) {
                          this.copyPlainText('设备 IP', peer.tailscaleIPs[0]);
                        }
                      })
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Button('Ping').height(28).fontSize(11).fontColor('#2563EB')
                    .backgroundColor('#EFF6FF').borderRadius(6)
                    .onClick(() => { this.pingTailscalePeer(peer) })
                }
                .width('100%')

                Row() {
                  Text(peer.curAddr.length > 0 ? `直连 ${peer.curAddr}` : peer.relay.length > 0 ? `DERP 中继 (${peer.relay})` : '待建连')
                    .fontSize(11).fontColor('#64748B').layoutWeight(1)
                  Text(`↓${this.formatBytes(peer.rxBytes)} / ↑${this.formatBytes(peer.txBytes)}`)
                    .fontSize(11).fontColor('#64748B')
                }
                .width('100%')

                if (peer.primaryRoutes.length > 0) {
                  Text(`子网路由：${peer.primaryRoutes.join(', ')}`).fontSize(11).fontColor('#0F766E').width('100%')
                }
                if (this.getPeerPingText(peer.id).length > 0) {
                  Text(`Ping 结果：${this.getPeerPingText(peer.id)}`).fontSize(11).fontWeight(FontWeight.Medium).fontColor('#2563EB').width('100%')
                }
              }
              .width('100%').padding(10).backgroundColor('#F8FAFC').borderRadius(8)
              .border({ width: 1, color: peer.online ? '#A7F3D0' : '#E2E8F0' })
            }, (peer: TailscalePeerItem) => `peer-${peer.id}-${peer.online ? 'on' : 'off'}-${this.tsPingRefreshTick}`)
          }
        }
        .padding(12).backgroundColor('#FFFFFF').borderRadius(10).border({ width: 1, color: '#DBE3EF' })

        // 3. Discovered Subnet Routes, MagicDNS & SplitDNS -> One-click Sync to Mihomo Rules
        if (this.tsControl.advertisedRoutes.length > 0 || this.tsControl.magicDnsSuffix.length > 0 ||
          this.tsControl.splitDns.length > 0 || this.tsPrefs.splitDnsDomains.length > 0) {
          Column({ space: 8 }) {
            Text('SplitDNS 与子网分流（已自动联动 Mihomo）').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A').width('100%')
            if (this.tsSplitDnsNeedReload) {
              Row({ space: 8 }) {
                Text('已同步最新 SplitDNS 域名到本地配置，请重连 VPN 使 DNS 策略生效。')
                  .fontSize(12).fontColor('#B45309').layoutWeight(1)
              }
              .width('100%').padding(8).backgroundColor('#FFFBEB').borderRadius(8).border({ width: 1, color: '#FDE68A' })
            }
            if (this.tsControl.splitDns.length > 0) {
              ForEach(this.tsControl.splitDns, (sd: TailscaleSplitDnsItem) => {
                Row() {
                  Column({ space: 2 }) {
                    Text(`*.${sd.domain}`).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#0F172A')
                    Text(`SplitDNS · 上游 ${sd.nameservers.length > 0 ? sd.nameservers.join(', ') : 'Tailscale 内置'}`)
                      .fontSize(11).fontColor('#0F766E')
                  }
                  .alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Button('+ 写入配置').height(28).fontSize(11).fontColor('#0F766E')
                    .backgroundColor('#E6FFFB').borderRadius(6)
                    .onClick(() => { this.addSplitDnsToMihomoProfile(sd.domain) })
                }
                .width('100%').padding(8).backgroundColor('#F0FDFA').borderRadius(8).border({ width: 1, color: '#99F6E4' })
              }, (sd: TailscaleSplitDnsItem) => `split-${sd.domain}`)
            } else if (this.tsPrefs.splitDnsDomains.length > 0) {
              Text(`已同步 SplitDNS 分流域：${this.tsPrefs.splitDnsDomains.join(', ')}（启动 VPN 自动生效）`)
                .fontSize(12).fontColor('#0F766E').width('100%')
            }
            if (this.tsControl.magicDnsSuffix.length > 0) {
              Row() {
                Column({ space: 2 }) {
                  Text(`*.${this.tsControl.magicDnsSuffix}`).fontSize(13).fontWeight(FontWeight.Medium).fontColor('#0F172A')
                  Text('Tailnet MagicDNS 后缀').fontSize(11).fontColor('#64748B')
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)
                Button('+ 加分流规则').height(28).fontSize(11).fontColor('#0F766E')
                  .backgroundColor('#E6FFFB').borderRadius(6)
                  .onClick(() => { this.addTailnetSuffixToMihomoRules(this.tsControl.magicDnsSuffix) })
              }
              .width('100%').padding(8).backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
            }
            ForEach(this.tsControl.advertisedRoutes, (rt: TailscaleAdvertisedRouteItem) => {
              Row() {
                Column({ space: 2 }) {
                  Text(rt.cidr).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#0F172A')
                  Text(`由 ${rt.peerName} (${rt.peerIp}) 广播 · ${rt.online ? '在线' : '离线'}`).fontSize(11).fontColor('#64748B')
                }
                .alignItems(HorizontalAlign.Start).layoutWeight(1)
                Button('+ 加分流规则').height(28).fontSize(11).fontColor('#0F766E')
                  .backgroundColor('#E6FFFB').borderRadius(6)
                  .onClick(() => { this.addDiscoveredRouteToMihomoRules(rt.cidr) })
              }
              .width('100%').padding(8).backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
            }, (rt: TailscaleAdvertisedRouteItem) => `adv-${rt.cidr}-${rt.peerName}`)

            Row({ space: 8 }) {
              TextInput({ text: this.tsDnsTestQuery, placeholder: 'SplitDNS 诊断域名（如 dsh-10.in.sjfarm.cc）' })
                .layoutWeight(1).height(34).fontSize(12).backgroundColor('#F8FAFC').borderRadius(6)
                .onChange((val: string) => { this.tsDnsTestQuery = val })
              Button('测试解析').height(34).fontSize(12).fontColor('#FFFFFF')
                .backgroundColor('#2563EB').borderRadius(6)
                .onClick(() => { this.runTailscaleDnsTest() })
            }
            .width('100%')
            if (this.tsDnsTestResult.length > 0) {
              Text(this.tsDnsTestResult).fontSize(12).fontColor('#0F766E').width('100%')
            }
          }
          .padding(12).backgroundColor('#FFFFFF').borderRadius(10).border({ width: 1, color: '#DBE3EF' })
        }

        // 4. Collapsible Low-Frequency Settings (Native Prefs + Exit Node)
        Column({ space: 8 }) {
          Row() {
            Column({ space: 2 }) {
              Text('⚙ 高级托管设置与 Exit Node').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#334155')
              Text(`设备名 ${this.tsPrefs.hostname} · 接管${this.tsPrefs.managedByApp ? '开' : '关'} · 子网${this.tsPrefs.acceptRoutes ? '开' : '关'}`)
                .fontSize(11).fontColor('#64748B')
            }
            .alignItems(HorizontalAlign.Start).layoutWeight(1)
            Button(this.showTsAdvancedSettings ? '收起' : '展开设置').height(28).fontSize(11)
              .fontColor('#475569').backgroundColor('#F1F5F9').borderRadius(6)
              .onClick(() => { this.showTsAdvancedSettings = !this.showTsAdvancedSettings })
          }
          .width('100%')

          if (this.showTsAdvancedSettings) {
            Column({ space: 8 }) {
              Column() {
                this.ReactiveSwitchRow('App 接管 Tailscale 配置', '自动注入 Tailscale 出站与分流规则', 'ts.managedByApp')
              }.onClick(() => { this.toggleTsManagedByApp() })

              Column() {
                this.ReactiveSwitchRow('启用 Tailscale 出站', '开启后与 Mihomo 代理共享同一系统 VPN', 'ts.enabled')
              }.onClick(() => { this.toggleTsEnabled() })

              Column() {
                this.ReactiveSwitchRow('接受子网路由 (Accept Routes)', '访问对端广播的内网段（支持运行中热生效）', 'ts.acceptRoutes')
              }.onClick(() => { this.toggleTsAcceptRoutes() })

              Column() {
                this.ReactiveSwitchRow('自动注入 MagicDNS 与放行', '自动合并 *.ts.net DNS 策略及 fake-ip-filter', 'ts.autoInjectMagicDns')
              }.onClick(() => { this.toggleTsAutoInjectDns() })

              Column() {
                this.ReactiveSwitchRow('自动同步 SplitDNS 域名', '自动将 SplitDNS 写入 DNS 策略、fake-ip 放行与分流规则', 'ts.autoSyncSplitDns')
              }.onClick(() => { this.toggleTsAutoSyncSplitDns() })

              Column() {
                this.ReactiveSwitchRow('Exit Node 允许局域网访问', '使用 Exit Node 时保留本地局域网直连（热生效）', 'ts.exitNodeAllowLan')
              }.onClick(() => { this.toggleTsExitNodeAllowLan() })

              TextInput({ text: this.tsHostnameDraft, placeholder: '本机设备名 Hostname（默认 harmony-phone）' })
                .height(38).fontSize(13).backgroundColor('#F8FAFC').borderRadius(8)
                .onChange((val: string) => { this.tsHostnameDraft = val })

              TextInput({ text: this.tsControlUrlDraft, placeholder: '自定义 Control URL（留空为官方，可填 Headscale）' })
                .height(38).fontSize(13).backgroundColor('#F8FAFC').borderRadius(8)
                .onChange((val: string) => { this.tsControlUrlDraft = val })

              TextInput({ text: this.tsAuthKeyDraft, placeholder: '可选 Auth Key（留空则走交互式浏览器登录）' })
                .height(38).fontSize(13).backgroundColor('#F8FAFC').borderRadius(8)
                .onChange((val: string) => { this.tsAuthKeyDraft = val })

              Button('保存并应用 Tailscale 设置').width('100%').height(38).fontSize(13).fontColor('#FFFFFF')
                .backgroundColor('#0F766E').borderRadius(8)
                .onClick(() => { this.saveTsTextSettings() })

              Row() {
                Text('出口节点 (Exit Node)').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#0F172A')
                Text(this.tsPrefs.exitNode.length > 0 ? this.tsPrefs.exitNode : '未启用')
                  .fontSize(12).fontWeight(FontWeight.Medium)
                  .fontColor(this.tsPrefs.exitNode.length > 0 ? '#0F766E' : '#64748B')
                  .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                  .backgroundColor(this.tsPrefs.exitNode.length > 0 ? '#E6FFFB' : '#F1F5F9')
                  .borderRadius(12)
              }
              .width('100%').justifyContent(FlexAlign.SpaceBetween).margin({ top: 6 })

              Row({ space: 8 }) {
                Button('关闭 Exit Node').layoutWeight(1).height(32).fontSize(12).fontColor('#475569')
                  .backgroundColor('#F1F5F9').borderRadius(6)
                  .onClick(() => { this.selectTsExitNode('') })
                Button('全部代理切至 Tailscale').layoutWeight(1).height(32).fontSize(12).fontColor('#2563EB')
                  .backgroundColor('#EFF6FF').borderRadius(6)
                  .onClick(() => { this.routeProxyViaTailscaleExitNode() })
              }
              .width('100%')

              if (this.getExitNodeCandidates().length > 0) {
                ForEach(this.getExitNodeCandidates(), (peer: TailscalePeerItem) => {
                  Row() {
                    Column({ space: 2 }) {
                      Text(peer.hostName).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#0F172A')
                      Text(`${peer.tailscaleIPs.length > 0 ? peer.tailscaleIPs[0] : ''} · ${peer.online ? '在线' : '离线'}`)
                        .fontSize(11).fontColor('#64748B')
                    }
                    .alignItems(HorizontalAlign.Start).layoutWeight(1)
                    Button(peer.exitNode ? '当前出口' : '选用').height(28).fontSize(12)
                      .fontColor(peer.exitNode ? '#FFFFFF' : '#0F766E')
                      .backgroundColor(peer.exitNode ? '#0F766E' : '#E6FFFB').borderRadius(6)
                      .onClick(() => {
                        if (peer.tailscaleIPs.length > 0) {
                          this.selectTsExitNode(peer.tailscaleIPs[0]);
                        }
                      })
                  }
                  .width('100%').padding(8).backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
                }, (peer: TailscalePeerItem) => `exit-${peer.id}-${peer.exitNode ? '1' : '0'}`)
              }
            }
            .width('100%').padding({ top: 4 })
          }
        }
        .padding(12).backgroundColor('#FFFFFF').borderRadius(10).border({ width: 1, color: '#E2E8F0' })
      }
      .padding(16)
    }
    .align(Alignment.TopStart)
    .layoutWeight(1)
  }

  @Builder
  private ImportPanel() {
    Column({ space: 10 }) {
      Text('导入远程订阅').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
      TextInput({ placeholder: '订阅名称，可留空', text: this.importName }).height(40)
        .backgroundColor('#F8FAFC').borderRadius(8)
        .onChange((value: string) => { this.importName = value })
      Row({ space: 6 }) {
        TextInput({ placeholder: 'https://example.com/sub.yaml', text: this.importUrl })
          .layoutWeight(1).height(40)
          .backgroundColor('#F8FAFC').borderRadius(8)
          .onChange((value: string) => { this.importUrl = value })
        Button('📷 扫码')
          .height(40).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor('#0F766E').backgroundColor('#CCFBF1').borderRadius(8)
          .padding({ left: 10, right: 10 })
          .onClick(() => { this.scanQrToFillUrl('import') })
      }
      .width('100%')
      TextInput({ placeholder: '自定义 User-Agent（可选，留空默认 clash-verge）', text: this.importUserAgent }).height(40)
        .backgroundColor('#F8FAFC').borderRadius(8)
        .onChange((value: string) => { this.importUserAgent = value })
      Row({ space: 8 }) {
        Button('取消').layoutWeight(1).height(36).fontColor('#0F172A')
          .backgroundColor('#EEF2F7').borderRadius(8)
          .onClick(() => { this.showImportPanel = false })
        Button('保存').layoutWeight(1).height(36).fontColor('#FFFFFF')
          .backgroundColor('#0F766E').borderRadius(8)
          .onClick(() => { this.addRemoteProfile() })
      }
    }
    .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#99F6E4' })
  }

  @Builder
  private SubMetaEditorCard() {
    Column({ space: 10 }) {
      Row() {
        Text('编辑订阅设置（URL / User-Agent）').fontSize(14).fontWeight(FontWeight.Bold).fontColor('#0F172A').layoutWeight(1)
        Button('关闭').height(26).fontSize(11).fontColor('#475569').backgroundColor('#F1F5F9').borderRadius(6)
          .onClick(() => { this.closeSubMetaEditor() })
      }
      .width('100%')
      TextInput({ placeholder: '配置名称', text: this.editingSubMetaName }).height(38)
        .fontSize(13).backgroundColor('#F8FAFC').borderRadius(8)
        .onChange((value: string) => { this.editingSubMetaName = value })
      Row({ space: 6 }) {
        TextInput({ placeholder: '订阅地址 https://...', text: this.editingSubMetaUrl })
          .layoutWeight(1).height(38)
          .fontSize(13).backgroundColor('#F8FAFC').borderRadius(8)
          .onChange((value: string) => { this.editingSubMetaUrl = value })
        Button('📷 扫码')
          .height(38).fontSize(12).fontWeight(FontWeight.Medium)
          .fontColor('#0F766E').backgroundColor('#CCFBF1').borderRadius(8)
          .padding({ left: 10, right: 10 })
          .onClick(() => { this.scanQrToFillUrl('edit') })
      }
      .width('100%')
      TextInput({ placeholder: '自定义 User-Agent（留空恢复默认 clash-verge）', text: this.editingSubMetaUserAgent }).height(38)
        .fontSize(13).backgroundColor('#F8FAFC').borderRadius(8)
        .onChange((value: string) => { this.editingSubMetaUserAgent = value })
      Row({ space: 8 }) {
        Button('仅保存').layoutWeight(1).height(36).fontSize(12).fontColor('#0F172A')
          .backgroundColor('#EEF2F7').borderRadius(8)
          .onClick(() => { this.saveSubMetaEditor(false) })
        Button('保存并更新订阅').layoutWeight(1).height(36).fontSize(12).fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF').backgroundColor('#0F766E').borderRadius(8)
          .onClick(() => { this.saveSubMetaEditor(true) })
      }
      .width('100%')
    }
    .padding(12).backgroundColor('#FFFFFF').borderRadius(10).border({ width: 1.5, color: '#38BDF8' })
  }

  // ============== DiagnosticsScreen ==============
  @Builder
  private DiagnosticsScreen() {
    Scroll() {
      Column({ space: 12 }) {
        Row({ space: 6 }) {
          this.DiagSegmentOption('连接', '连接')
          this.DiagSegmentOption('日志', '日志')
          this.DiagSegmentOption('规则', '规则')
          this.DiagSegmentOption('DNS', 'DNS')
        }
        .padding(4).backgroundColor('#EEF2F7').borderRadius(8)

        if (this.diagSegment === '连接') {
          this.DiagnosticsConnectionSegment()
        } else if (this.diagSegment === '日志') {
          this.DiagnosticsLogSegment()
        } else if (this.diagSegment === '规则') {
          this.DiagnosticsRulesSegment()
        } else {
          this.DiagnosticsDnsSegment()
        }
      }
      .padding(16)
    }
    .align(Alignment.TopStart)
    .layoutWeight(1)
  }

  @Builder
  private DiagnosticsConnectionSegment() {
    Column({ space: 12 }) {
      Column({ space: 10 }) {
        this.SectionTitle('连接概览', '关闭全部')
        Row({ space: 8 }) {
          this.Metric('活跃', `${this.liveConnections}`)
          this.Metric('下载', this.liveDownloadSpeed)
          this.Metric('上传', this.liveUploadSpeed)
        }
      }
      .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })

      Column({ space: 8 }) {
        Row() {
          Text('核心 Controller').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
          Button('刷新').height(30).fontSize(12).fontColor('#FFFFFF')
            .backgroundColor('#2563EB').borderRadius(8)
            .onClick(() => { this.refreshControllerStatus() })
        }
        .width('100%').justifyContent(FlexAlign.SpaceBetween)
        this.StatusLine(
          this.controllerStatus.available ? '已连接' : '未连接',
          this.controllerStatus.available ? `mihomo ${this.controllerStatus.version}` : this.controllerStatus.message,
          this.controllerStatus.available ? '正常' : '待接入'
        )
      }
      .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })

      Column({ space: 8 }) {
        this.SectionTitle('Native Bridge', '')
        this.StatusLine('桥接状态', this.coreBridgeState.coreMode,
          this.coreBridgeState.running ? '运行' : '待接入')
        this.StatusLine('Adapter', this.coreBridgeState.adapterVersion.length > 0
          ? `${this.coreBridgeState.adapterMode} ${this.coreBridgeState.adapterVersion}`
          : this.coreBridgeState.adapterMode,
          this.coreBridgeState.adapterMode === 'real' ? '真实核心' : 'Stub')
        if (this.coreBridgeState.adapterLoadError.length > 0) {
          this.StatusLine('加载信息', this.coreBridgeState.adapterLoadError,
            this.coreBridgeState.adapterMode === 'real' ? '正常' : '待接入')
        }
        this.StatusLine('TUN FD', `system ${this.coreBridgeState.tunFd} / native ${this.coreBridgeState.nativeFd}`,
          this.coreBridgeState.nativeFd >= 0 ? '正常' : '等待')
        this.StatusLine('Controller Ready',
          this.coreBridgeState.controllerReady ? `ready ${this.coreBridgeState.controllerVersion}` : 'not ready',
          this.coreBridgeState.controllerReady ? '正常' : '等待')
        this.StatusLine('转发统计',
          `读 ${this.coreBridgeState.packetsRead} 包 (${this.coreBridgeState.bytesRead} B) / 写 ${this.coreBridgeState.packetsWritten} 包 (${this.coreBridgeState.bytesWritten} B)`,
          this.coreBridgeState.forwarderActive ? '活跃' : '停用')
        this.StatusLine('生命周期',
          `start ${this.coreBridgeState.startCount} / stop ${this.coreBridgeState.stopCount}`,
          this.coreBridgeState.lastError.length > 0 ? '异常' : '正常')
        if (this.coreBridgeState.lastError.length > 0) {
          this.StatusLine('最近错误', this.coreBridgeState.lastError, '异常')
        }
      }
      .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })

      Column({ space: 8 }) {
        this.SectionTitle('运行配置', '')
        this.StatusLine(this.runtimeConfigInfo,
          this.runtimeConfigPath.length > 0 ? this.runtimeConfigPath : '等待生成',
          this.runtimeConfigInfo === '尚未生成运行配置' ? '待处理' : '正常')
        this.StatusLine('VPN 路由', '默认路由，接管 IPv4 流量', '正常')
      }
      .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })

      Column({ space: 8 }) {
        Row() {
          Text('活跃连接').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
          Button('刷新').height(30).fontSize(12).fontColor('#2563EB')
            .backgroundColor('#EFF6FF').borderRadius(8)
            .onClick(() => { this.refreshConnections() })
        }
        .width('100%').justifyContent(FlexAlign.SpaceBetween)
        if (this.runtimeConnections.length === 0) {
          this.EmptyState('暂无连接数据', this.controllerStatus.available ? 'controller 已连接，等待连接产生。' : '启动 mihomo controller 后可同步活跃连接。')
        } else {
          ForEach(this.runtimeConnections, (item: RuntimeConnectionRow) => {
            this.ConnectionRow(item)
          }, (item: RuntimeConnectionRow) => item.id)
        }
      }
      .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })
    }
  }

  @Builder
  private TailscaleStatusCard(compact: boolean) {
    Column({ space: 8 }) {
      Row() {
        Row({ space: 8 }) {
          Text('Tailscale 状态').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
          Text(this.tailscaleStateLabel())
            .fontSize(12).fontWeight(FontWeight.Medium)
            .fontColor(this.tailscaleStateColor())
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .backgroundColor(this.tailscaleStateBgColor())
            .borderRadius(12)
        }
        if (compact) {
          Button('管理').height(28).fontSize(12).fontColor('#0F766E')
            .backgroundColor('#E6FFFB').borderRadius(6)
            .onClick(() => {
              this.currentTab = 'tailscale';
              this.refreshTailscaleStatus();
            })
        } else {
          Button('刷新').height(28).fontSize(12).fontColor('#2563EB')
            .backgroundColor('#EFF6FF').borderRadius(6)
            .onClick(() => { this.refreshCoreLogs() })
        }
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween)

      if (this.tailscaleHostname.length > 0 || this.tailscaleIps.length > 0) {
        Text(
          this.tailscaleHostname.length > 0 && this.tailscaleIps.length > 0
            ? `节点: ${this.tailscaleHostname} · IP: ${this.tailscaleIps}`
            : this.tailscaleHostname.length > 0
              ? `节点: ${this.tailscaleHostname}`
              : `IP: ${this.tailscaleIps}`
        )
          .fontSize(12).fontColor('#334155').width('100%')
      }

      if (this.tailscaleAuthUrl.length > 0) {
        Column({ space: 8 }) {
          Text('Tailscale 交互式认证').fontSize(13).fontWeight(FontWeight.Bold).fontColor('#0F766E').width('100%')
          Row({ space: 8 }) {
            Button('🌐 浏览器打开').layoutWeight(1).height(34).fontSize(12).fontWeight(FontWeight.Bold)
              .fontColor('#FFFFFF').backgroundColor('#0F766E').borderRadius(8)
              .onClick(() => { this.openTailscaleAuthUrlInBrowser() })
            Button('复制链接').height(34).fontSize(12).fontWeight(FontWeight.Medium)
              .fontColor('#0F766E').backgroundColor('#FFFFFF').borderRadius(8)
              .border({ width: 1, color: '#14B8A6' })
              .onClick(() => { this.copyTailscaleAuthUrl() })
          }
          .width('100%')
          Text(this.tailscaleAuthUrl)
            .fontSize(11).fontColor('#115E59').width('100%')
            .copyOption(CopyOptions.LocalDevice)
        }
        .padding(10).backgroundColor('#F0FDFA').borderRadius(8).border({ width: 1, color: '#99F6E4' })
      } else if (this.tailscaleState !== 'Running' && this.tailscaleError.length === 0) {
        Text('正在获取 Tailscale 登录状态，请稍候或点击刷新...')
          .fontSize(12).fontColor('#64748B').width('100%')
      }

      if (this.tailscaleError.length > 0) {
        Text(`错误: ${this.tailscaleError}`).fontSize(12).fontColor('#DC2626').width('100%')
      }

      if (!compact && this.tailscaleHealth.length > 0) {
        ForEach(this.tailscaleHealth, (warning: string, index: number) => {
          Text(`健康提示: ${warning}`).fontSize(11).fontColor('#D97706').width('100%')
        }, (warning: string, index: number) => `ts-health-${index}-${warning}`)
      }

      if (!compact && this.tailscaleRecentLogs.length > 0) {
        ForEach(this.tailscaleRecentLogTail(), (line: string, index: number) => {
          this.MonospaceLine(line)
        }, (line: string, index: number) => `ts-log-${index}-${line}`)
      }
    }
    .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })
  }

  @Builder
  private DiagnosticsLogSegment() {
    Column({ space: 10 }) {
      if (this.liveConnected || this.tailscaleState.length > 0 || this.tailscaleAuthUrl.length > 0 || this.tailscaleError.length > 0) {
        this.TailscaleStatusCard(false)
      }

      Column({ space: 8 }) {
        Row() {
          Text('核心日志 (Mihomo / Tailscale)').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
          Button('刷新日志').height(30).fontSize(12).fontColor('#FFFFFF')
            .backgroundColor('#2563EB').borderRadius(8)
            .onClick(() => { this.refreshCoreLogs() })
        }
        .width('100%').justifyContent(FlexAlign.SpaceBetween)
        if (this.coreLogLines.length === 0) {
          this.EmptyState('暂无核心日志', '连接后核心会将 Tailscale 状态与登录链接写入运行时日志。')
        } else {
          ForEach(this.coreLogLines, (line: string, index: number) => {
            this.MonospaceLine(line)
          }, (line: string, index: number) => `${index}-${line}`)
        }
      }
      .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })

      Column({ space: 8 }) {
        this.SectionTitle('最近日志', '导出')
        if (this.appLogs.length === 0) {
          this.LogLine('--:--', 'info', this.statusMessage)
          this.LogLine('--:--', 'info', this.controllerStatus.message)
        } else {
          ForEach(this.appLogs, (item: AppLogEntry) => {
            this.LogLine(item.time, item.level, item.message)
          }, (item: AppLogEntry) => `${item.time}-${item.message}`)
        }
      }
      .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })
    }
  }

  @Builder
  private DiagnosticsRulesSegment() {
    Column({ space: 8 }) {
      Row() {
        Text('规则').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
        Button('刷新').height(30).fontSize(12).fontColor('#FFFFFF')
          .backgroundColor('#2563EB').borderRadius(8)
          .onClick(() => { this.refreshRules() })
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween)
      this.StatusLine('规则同步', this.rulesStatus, this.ruleLines.length > 0 ? '正常' : '待接入')
      if (this.ruleLines.length === 0) {
        this.EmptyState('暂无规则数据', '启动 mihomo controller 后可读取 /rules。')
      } else {
        ForEach(this.ruleLines, (line: string) => {
          this.MonospaceLine(line)
        }, (line: string) => line)
      }
    }
    .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })
  }

  @Builder
  private DiagnosticsDnsSegment() {
    Column({ space: 8 }) {
      Row() {
        Text('DNS').fontSize(15).fontWeight(FontWeight.Bold).fontColor('#0F172A')
        Button('刷新').height(30).fontSize(12).fontColor('#FFFFFF')
          .backgroundColor('#2563EB').borderRadius(8)
          .onClick(() => { this.refreshDnsConfig() })
      }
      .width('100%').justifyContent(FlexAlign.SpaceBetween)
      this.StatusLine('DNS 配置', this.dnsStatus, this.dnsLines.length > 0 ? '正常' : '待接入')
      if (this.dnsLines.length === 0) {
        this.EmptyState('暂无 DNS 数据', '启动 mihomo controller 后可查看 DNS 配置。')
      } else {
        ForEach(this.dnsLines, (line: string) => {
          this.MonospaceLine(line)
        }, (line: string) => line)
      }
    }
    .padding(12).backgroundColor('#FFFFFF').borderRadius(8).border({ width: 1, color: '#DBE3EF' })
  }

  @Builder
  private ConnectionRow(item: RuntimeConnectionRow) {
    Column({ space: 4 }) {
      Text(item.target).fontSize(13).fontWeight(FontWeight.Bold).fontColor('#0F172A')
      Text(`${item.rule} · ${item.chain.length > 0 ? item.chain : 'DIRECT'}`)
        .fontSize(11).fontColor('#64748B')
      Text(`上行 ${item.upload} / 下行 ${item.download}`).fontSize(11).fontColor('#0F766E')
    }
    .width('100%').alignItems(HorizontalAlign.Start).padding(10)
    .backgroundColor('#F8FAFC').borderRadius(8).border({ width: 1, color: '#E2E8F0' })
  }

  @Builder
  private MonospaceLine(text: string) {
    Text(text).fontSize(11).fontColor('#334155')
      .width('100%').padding({ top: 4, bottom: 4 })
      .backgroundColor('#F8FAFC')
  }

  // ============== SettingsScreen ==============
  @Builder
  private SettingsScreen() {
    Scroll() {
      Column({ space: 12 }) {
        this.SwitchRow('后台持续运行', '连接后显示系统可见状态', true)
        this.SwitchRow('IPv6', '跟随配置，异常时提示', false)
        this.StatusLine('DNS 模式', 'fake-ip · 增强模式', '配置')
        this.StatusLine('mihomo 核心', 'Alpha 通道关闭 · 日志 info', '正常')
        this.SwitchRow('外部控制器', '仅本机访问，默认关闭局域网', false)
        this.SwitchRow('诊断包脱敏', '隐藏订阅 token、节点密码、secret', true)
        this.StatusLine('本地备份', '最近备份：今天 10:21', '导出')
      }
      .padding(16)
    }
    .align(Alignment.TopStart)
    .layoutWeight(1)
  }

  // ============== Helpers ==============
  private async runRealSpeedTest(): Promise<void> {
    if (this.isSpeedTesting) {
      this.statusMessage = '测速正在进行，请稍候';
      return;
    }

    let targetIndexes: number[] = this.getAllProxyNodeIndexes();
    let targetNodes: ProxyNode[] = this.createProxyNodeSnapshot(targetIndexes);
    if (targetNodes.length === 0) {
      this.statusMessage = '没有节点可测';
      this.speedTestProgress = '没有节点可测';
      this.speedTestSummary = '没有节点可测';
      return;
    }

    this.isSpeedTesting = true;
    this.speedTestSummary = '';
    this.speedTestProgress = `准备测速核心 · ${targetNodes.length} 个节点`;
    this.statusMessage = `正在准备测速 ${targetNodes.length} 个节点...`;
    await this.waitForUiUpdate(80);

    let tested: number = 0;
    let reachable: number = 0;
    let timeout: number = 0;

    try {
      const ready: boolean = await this.ensureControllerReadyForProxyActions('测速');
      if (!ready) {
        this.speedTestProgress = '测速未开始：controller 未就绪';
        this.speedTestSummary = this.speedTestProgress;
        return;
      }

      targetIndexes = this.getAllProxyNodeIndexes();
      targetNodes = this.createProxyNodeSnapshot(targetIndexes);
      if (targetNodes.length === 0) {
        this.speedTestProgress = '没有节点可测';
        this.speedTestSummary = '没有节点可测';
        this.statusMessage = '没有节点可测';
        return;
      }

      const blocked: SpeedTestBlockedState | undefined = this.getSpeedTestBlockedState(targetNodes.length);
      if (blocked) {
        this.updateProxyNodeDelayBatch(this.createDelayUpdates(targetNodes, blocked.nodeDelay, blocked.nodeStatus));
        this.statusMessage = blocked.statusMessage;
        this.speedTestProgress = blocked.progress;
        this.speedTestSummary = blocked.summary;
        this.recordLog('warn', blocked.statusMessage);
        return;
      }

      this.speedTestProgress = `测速中 0/${targetNodes.length} · 0 可达`;
      this.statusMessage = `正在测速 0/${targetNodes.length}...`;
      this.updateProxyNodeDelayBatch(this.createDelayUpdates(targetNodes, '测试中...', 'testing'));

      await this.waitForUiUpdate(80);

      const batchSize: number = 12;
      for (let offset = 0; offset < targetNodes.length; offset += batchSize) {
        const batchNodes: ProxyNode[] = [];
        const tasks: Promise<number>[] = [];
        const end: number = offset + batchSize > targetNodes.length ? targetNodes.length : offset + batchSize;
        for (let cursor = offset; cursor < end; cursor++) {
          const node: ProxyNode = targetNodes[cursor];
          batchNodes.push(node);
          tasks.push(this.measureProxyNodeDelay(node));
        }

        const delays: number[] = await Promise.all(tasks);
        const updates: ProxyDelayUpdate[] = [];
        for (let index = 0; index < delays.length; index++) {
          const node: ProxyNode = batchNodes[index];
          const result = TcpDelayTestService.formatDelay(delays[index]);
          updates.push({ name: node.name, delay: result.delay, status: result.status });
          tested = tested + 1;
          if (delays[index] > 0) {
            reachable = reachable + 1;
          } else {
            timeout = timeout + 1;
          }
        }
        this.updateProxyNodeDelayBatch(updates);
        this.speedTestProgress = '测速中 ' + tested + '/' + targetNodes.length + ' · ' + reachable + ' 可达 · ' + timeout + ' timeout';
        this.statusMessage = '测速: ' + tested + '/' + targetNodes.length + ' (' + reachable + ' 可达)';
        await this.waitForUiUpdate(0);
      }
      this.speedTestSummary = '测速完成 ' + tested + '/' + targetNodes.length + ' · ' + reachable + ' 可达 · ' + timeout + ' timeout';
      this.speedTestProgress = this.speedTestSummary;
      this.statusMessage = '测速完成: ' + tested + ' 个节点, ' + reachable + ' 可达';
      await this.autoSelectReachableProxyAfterSpeedTest();
    } finally {
      this.isSpeedTesting = false;
    }
  }

  private waitForUiUpdate(durationMs: number): Promise<void> {
    return new Promise((resolve: () => void) => {
      setTimeout(resolve, durationMs);
    });
  }

  private async measureProxyNodeDelay(node: ProxyNode): Promise<number> {
    if (!this.controllerStatus.available && !this.coreBridgeState.controllerReady) {
      return -1;
    }

    for (let urlIndex = 0; urlIndex < DELAY_TEST_URLS.length; urlIndex++) {
      const result: ControllerTextResult = await MihomoControllerService.testDelay(
        node.name,
        DELAY_TEST_TIMEOUT_MS,
        DELAY_TEST_URLS[urlIndex]
      );
      const delay: number = this.parseControllerDelay(result);
      if (delay > 0) {
        return delay;
      }
    }
    return -1;
  }

  private async verifySelectedProxyAfterConnection(controllerVersion: string): Promise<void> {
    const group: ProxyGroupInfo | undefined = this.findRuntimeProxyGroup();
    const nodeName: string = group && group.now.length > 0 ? group.now : this.getSelectedProxyNodeName();
    if (nodeName.length === 0) {
      this.clearProxyHealthState();
      this.statusMessage = `已连接 · ${controllerVersion} · 未找到当前节点`;
      this.recordLog('warn', this.statusMessage);
      return;
    }

    this.statusMessage = `VPN 隧道已建立，正在检测当前节点：${nodeName}`;
    this.syncHomeRuntimeFields();
    const delay: number = await this.measureProxyNodeDelay({
      name: nodeName,
      meta: '',
      delay: '待测',
      selected: true
    });

    this.proxyHealthCheckedAt = Date.now();
    this.proxyHealthNode = nodeName;
    this.proxyHealthOk = delay > 0;
    this.proxyHealthDelay = delay > 0 ? delay : 0;
    if (delay > 0) {
      this.statusMessage = `已连接 · ${controllerVersion} · 当前节点可达 ${delay} ms`;
      this.recordLog('info', this.statusMessage);
      return;
    }

    this.statusMessage = `VPN 隧道已建立，但当前节点不可达：${nodeName} · 请在代理页重新测速并切换节点`;
    this.recordLog('warn', this.statusMessage);
  }

  private clearProxyHealthState(): void {
    this.proxyHealthCheckedAt = 0;
    this.proxyHealthOk = false;
    this.proxyHealthDelay = 0;
    this.proxyHealthNode = '';
  }

  private formatProxyHealthSuffix(): string {
    if (this.proxyHealthCheckedAt <= 0 || this.proxyHealthNode.length === 0) {
      return '';
    }
    if (Date.now() - this.proxyHealthCheckedAt > 120000) {
      return '';
    }
    if (this.proxyHealthOk) {
      return ` · ${this.proxyHealthNode} ${this.proxyHealthDelay} ms`;
    }
    return ` · ${this.proxyHealthNode} 不可达`;
  }

  private async autoSelectReachableProxyAfterSpeedTest(): Promise<void> {
    const selectedName: string = this.getSelectedProxyNodeName();
    let selectedReachable: boolean = false;
    let bestNode: ProxyNode | undefined = undefined;
    let bestDelay: number = 0;

    for (let index = 0; index < this.proxyNodes.length; index++) {
      const node: ProxyNode = this.proxyNodes[index];
      const delay: number = this.parseDelayText(node.delay);
      if (delay <= 0) {
        continue;
      }
      if (node.name === selectedName) {
        selectedReachable = true;
      }
      if (!bestNode || delay < bestDelay) {
        bestNode = node;
        bestDelay = delay;
      }
    }

    if (!bestNode) {
      return;
    }
    if (selectedReachable && selectedName.length > 0) {
      return;
    }

    const group: ProxyGroupInfo | undefined = this.findSelectedProxyGroup();
    if (!group) {
      this.markSelectedProxyNode(bestNode.name);
      this.pendingProxyName = bestNode.name;
      this.statusMessage = `当前节点不可达，已预选最快可达节点：${bestNode.name} · ${bestNode.delay}`;
      this.recordLog('info', this.statusMessage);
      this.syncHomeRuntimeFields();
      return;
    }

    const ok: boolean = await MihomoControllerService.selectProxy(group.name, bestNode.name);
    if (!ok) {
      this.statusMessage = `最快可达节点选择失败：${group.name} -> ${bestNode.name}`;
      this.recordLog('warn', this.statusMessage);
      return;
    }

    this.pendingProxyGroup = group.name;
    this.pendingProxyName = bestNode.name;
    this.markSelectedProxyNode(bestNode.name);
    await this.refreshControllerProxies();
    this.statusMessage = `当前节点不可达，已切换最快可达节点：${bestNode.name} · ${bestNode.delay}`;
    this.speedTestProgress = `${this.speedTestSummary} · 已切换 ${bestNode.delay}`;
    this.recordLog('info', this.statusMessage);
    this.syncHomeRuntimeFields();
  }

  private parseDelayText(delay: string): number {
    if (delay.endsWith(' ms')) {
      return parseInt(delay.substring(0, delay.length - 3));
    }
    return 0;
  }

  private getSpeedTestBlockedState(targetCount: number): SpeedTestBlockedState | undefined {
    if (!this.controllerStatus.available && !this.coreBridgeState.controllerReady) {
      return {
        nodeDelay: '核心未就绪',
        nodeStatus: 'pending',
        statusMessage: `controller 未就绪，未对 ${targetCount} 个节点发起测速`,
        progress: `未开始：controller 未就绪，未对 ${targetCount} 个节点发起测速`,
        summary: '测速未开始：controller 未就绪；节点未标记 timeout'
      };
    }

    return undefined;
  }

  private parseControllerDelay(result: ControllerTextResult): number {
    if (!result.ok) {
      return -1;
    }
    try {
      const parsed = JSON.parse(result.raw) as Record<string, number>;
      const delay: number = parsed['delay'];
      return delay > 0 ? delay : -1;
    } catch (err) {
      return -1;
    }
  }

  private async waitForVpnTunReady(maxAttempts: number, intervalMs: number): Promise<RuntimeTunStatus> {
    let latest: RuntimeTunStatus = {
      ready: false,
      message: 'VPN TUN 尚未就绪',
      raw: '',
      enabled: false,
      fileDescriptor: 0,
      stack: ''
    };

    for (let index = 0; index < maxAttempts; index++) {
      const result: ControllerTextResult = await MihomoControllerService.getConfig();
      if (result.ok) {
        latest = this.parseRuntimeTunStatus(result.raw);
      } else {
        latest = {
          ready: false,
          message: `读取 TUN 状态失败：${result.message}`,
          raw: result.raw,
          enabled: false,
          fileDescriptor: 0,
          stack: ''
        };
      }

      if (latest.ready) {
        return latest;
      }
      if (index < maxAttempts - 1) {
        await this.waitForUiUpdate(intervalMs);
      }
    }
    return latest;
  }

  private parseRuntimeTunStatus(raw: string): RuntimeTunStatus {
    try {
      const parsed = JSON.parse(raw) as Record<string, Object>;
      const tun = parsed['tun'] as Record<string, Object>;
      if (!tun) {
        return {
          ready: false,
          message: 'VPN TUN 未启用：controller 未返回 tun 配置',
          raw: raw,
          enabled: false,
          fileDescriptor: 0,
          stack: ''
        };
      }

      const enabled: boolean = tun['enable'] === true;
      const fdValue: Object = tun['file-descriptor'];
      const fileDescriptor: number = typeof fdValue === 'number' ? fdValue as number : 0;
      const stackValue: Object = tun['stack'];
      const stack: string = typeof stackValue === 'string' ? stackValue as string : '';
      const ready: boolean = enabled && fileDescriptor > 0;
      return {
        ready: ready,
        message: ready ? `VPN TUN 已启用：fd=${fileDescriptor} stack=${stack}` :
          `VPN TUN 未启用：enable=${enabled ? 'true' : 'false'} fd=${fileDescriptor} stack=${stack}`,
        raw: raw,
        enabled: enabled,
        fileDescriptor: fileDescriptor,
        stack: stack
      };
    } catch (err) {
      return {
        ready: false,
        message: 'VPN TUN 状态解析失败',
        raw: raw,
        enabled: false,
        fileDescriptor: 0,
        stack: ''
      };
    }
  }

  private updateProxyNodeDelay(targetIndex: number, targetName: string, delay: string, status: string): void {
    this.updateProxyNodeDelayBatch([{ name: targetName, delay: delay, status: status }]);
  }

  private updateVisibleProxyNodeDelay(targetIndexes: number[], delay: string, status: string): void {
    const updates: ProxyDelayUpdate[] = [];
    for (let index = 0; index < targetIndexes.length; index++) {
      const nodeIndex: number = targetIndexes[index];
      if (nodeIndex >= 0 && nodeIndex < this.proxyNodes.length) {
        updates.push({ name: this.proxyNodes[nodeIndex].name, delay: delay, status: status });
      }
    }
    this.updateProxyNodeDelayBatch(updates);
  }

  private updateProxyNodeDelayBatch(updates: ProxyDelayUpdate[]): void {
    if (updates.length === 0) {
      return;
    }

    const updateMap: Record<string, ProxyDelayState> = {};
    for (let index = 0; index < updates.length; index++) {
      const update: ProxyDelayUpdate = updates[index];
      if (update.name.length === 0) {
        continue;
      }
      updateMap[update.name] = {
        delay: update.delay,
        status: update.status
      };
      this.proxyDelayCache[update.name] = {
        delay: update.delay,
        status: update.status
      };
    }

    const nodes: ProxyNode[] = [];
    for (let index = 0; index < this.proxyNodes.length; index++) {
      const node: ProxyNode = this.proxyNodes[index];
      const updated: ProxyDelayState | undefined = updateMap[node.name];
      if (updated) {
        nodes.push(this.copyProxyNodeWithDelay(node, updated.delay, updated.status));
      } else {
        const cached: ProxyDelayState = this.getCachedProxyDelayState(node.name);
        nodes.push(this.copyProxyNodeWithDelay(node, cached.delay, cached.status));
      }
    }
    this.proxyNodes = nodes;
  }

  private createProxyNodeSnapshot(indexes: number[]): ProxyNode[] {
    const nodes: ProxyNode[] = [];
    for (let index = 0; index < indexes.length; index++) {
      const nodeIndex: number = indexes[index];
      if (nodeIndex < 0 || nodeIndex >= this.proxyNodes.length) {
        continue;
      }
      const node: ProxyNode = this.proxyNodes[nodeIndex];
      nodes.push({
        name: node.name,
        meta: node.meta,
        delay: node.delay,
        selected: node.selected,
        status: node.status,
        server: node.server,
        port: node.port
      });
    }
    return nodes;
  }

  private createDelayUpdates(nodes: ProxyNode[], delay: string, status: string): ProxyDelayUpdate[] {
    const updates: ProxyDelayUpdate[] = [];
    for (let index = 0; index < nodes.length; index++) {
      updates.push({ name: nodes[index].name, delay: delay, status: status });
    }
    return updates;
  }

  private getCachedProxyDelayState(name: string): ProxyDelayState {
    const cached: ProxyDelayState | undefined = this.proxyDelayCache[name];
    if (cached && cached.delay.length > 0) {
      return {
        delay: cached.delay,
        status: cached.status
      };
    }
    return {
      delay: '待测',
      status: 'pending'
    };
  }

  private copyProxyNodeWithDelay(node: ProxyNode, delay: string, status: string): ProxyNode {
    return {
      name: node.name,
      meta: node.meta,
      delay: delay,
      selected: node.selected,
      status: status,
      server: node.server ? node.server : '',
      port: node.port ? node.port : 0
    };
  }

  private getSubtitle(): string {
    if (this.showSettings) { return 'VPN · DNS · 核心' }
    if (this.currentTab === 'proxies') {
      return this.profileState.currentUid.length > 0 ? '节点列表 · 策略组切换与测速' : '请先导入配置'
    }
    if (this.currentTab === 'tailscale') {
      return this.tsControl.tailnetName.length > 0
        ? `${this.tsControl.tailnetName} · ${this.tsControl.peers.length} 设备`
        : '内嵌 Tailscale 原生管理'
    }
    if (this.currentTab === 'overlay') {
      return this.overlayConfig.enabled
        ? `AI 严格自建已启用 · ${this.overlayConfig.aiProviders.length} 家 AI`
        : '自建节点与 Fail-Closed 分流覆写'
    }
    if (this.currentTab === 'profiles') { return `${this.profileState.items.length} 个配置 · 版本管理与流量规则` }
    if (this.currentTab === 'diagnostics') {
      return this.controllerStatus.available ? `controller ${this.controllerStatus.version}` : '诊断与运行配置'
    }
    return this.liveConnected ? `已连接 · ${this.modeLabel(this.proxyMode)}模式` : '未连接'
  }

  private createProfileNameFromUrl(url: string): string {
    let value: string = url;
    value = value.replace('https://', '').replace('http://', '');
    const slashIndex: number = value.indexOf('/');
    if (slashIndex > 0) { value = value.substring(0, slashIndex) }
    return value.length > 0 ? value : '远程订阅';
  }
}
