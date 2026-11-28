import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { rpc } from '@kit.IPCKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VpnExtensionAbility, connection, vpnExtension } from '@kit.NetworkKit';
import { CoreBridgeService, CoreBridgeState } from '../services/CoreBridgeService';
import { ControllerStatus, MihomoControllerService } from '../services/MihomoControllerService';
import nativeCore from 'libentry.so';

const DOMAIN: number = 0x0001;
const TAG: string = 'ClashVpnExtension';
const BUNDLE_NAME: string = 'com.sjfarmltd.tailscale';
const PARAM_CONFIG_PATH: string = 'configPath';
const MOBILE_TUN_MTU: number = 1360;
const FLAG_REBIND_TS: number = 1;
const FLAG_PRUNE_NON_TS: number = 2;

export default class ClashVpnExtensionAbility extends VpnExtensionAbility {
  private connection?: vpnExtension.VpnConnection;
  private tunFd: number = -1;
  private configPath: string = '';
  private starting: boolean = false;
  private bindStub?: rpc.RemoteObject;

  private netConn?: connection.NetConnection;
  private activeNetId: number = -1;
  private lastIfaceName: string = '';
  private lastBearer: string = '';
  private hasBaselineNet: boolean = false;
  private wasOffline: boolean = false;

  onConnect(_want: Want): rpc.RemoteObject {
    if (!this.bindStub) {
      this.bindStub = new rpc.RemoteObject('com.sjfarmltd.tailscale.vpn.bind');
    }
    hilog.info(DOMAIN, TAG, 'VPN extension bound by UI process');
    return this.bindStub;
  }

  onCreate(want: Want): void {
    hilog.info(DOMAIN, TAG, 'VPN extension created');
    this.connection = vpnExtension.createVpnConnection(this.context);
    try {
      nativeCore.protectSocket(-1);
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Socket protection setup check: %{public}s', JSON.stringify(err));
    }
    this.captureWant(want);
    this.appendExtLog(`onCreate config=${this.configPath}`, true);
    this.startTunnel();
  }

  onRequest(want: Want, startId: number): void {
    hilog.info(DOMAIN, TAG, 'VPN extension requested: %{public}d', startId);
    this.captureWant(want);
    this.appendExtLog(`onRequest startId=${startId} config=${this.configPath}`);
    this.startTunnel();
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'VPN extension destroyed');
    this.appendExtLog('onDestroy stopping tunnel');
    this.stopTunnel();
  }

  private appendExtLog(message: string, reset: boolean = false): void {
    let file: fileIo.File | undefined = undefined;
    try {
      const runtimeDir: string = `${this.context.filesDir}/runtime`;
      try {
        fileIo.mkdirSync(runtimeDir, true);
      } catch (_dirErr) {
      }
      const logPath: string = `${runtimeDir}/vpn-extension.log`;
      const now: Date = new Date();
      const hh: string = now.getHours() < 10 ? `0${now.getHours()}` : `${now.getHours()}`;
      const mm: string = now.getMinutes() < 10 ? `0${now.getMinutes()}` : `${now.getMinutes()}`;
      const ss: string = now.getSeconds() < 10 ? `0${now.getSeconds()}` : `${now.getSeconds()}`;
      const flags: number = fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY |
        (reset ? fileIo.OpenMode.TRUNC : fileIo.OpenMode.APPEND);
      file = fileIo.openSync(logPath, flags);
      fileIo.writeSync(file.fd, `[${hh}:${mm}:${ss}] ${message}\n`);
    } catch (_err) {
    } finally {
      if (file !== undefined) {
        try {
          fileIo.closeSync(file);
        } catch (_closeErr) {
        }
      }
    }
  }

  private captureWant(want: Want): void {
    if (!want.parameters) {
      return;
    }

    const value: Object | undefined = want.parameters[PARAM_CONFIG_PATH];
    if (typeof value === 'string') {
      this.configPath = value;
    }
  }

  private isIgnoredInterface(ifaceName: string): boolean {
    const lower: string = ifaceName.trim().toLowerCase();
    if (lower.length === 0) {
      return true;
    }
    return lower.startsWith('vpn') ||
      lower.startsWith('tun') ||
      lower.startsWith('rmnet_ims') ||
      lower.startsWith('ancormnet');
  }

  private describeBearer(caps: connection.NetCapabilities | undefined): string {
    if (!caps || !caps.bearerTypes) {
      return 'net';
    }
    for (let i = 0; i < caps.bearerTypes.length; i++) {
      const bt: connection.NetBearType = caps.bearerTypes[i];
      if (bt === connection.NetBearType.BEARER_VPN) {
        return 'vpn';
      }
    }
    for (let i = 0; i < caps.bearerTypes.length; i++) {
      const bt: connection.NetBearType = caps.bearerTypes[i];
      if (bt === connection.NetBearType.BEARER_WIFI) {
        return 'wifi';
      }
      if (bt === connection.NetBearType.BEARER_CELLULAR) {
        return 'cellular';
      }
      if (bt === connection.NetBearType.BEARER_ETHERNET) {
        return 'ethernet';
      }
    }
    return 'other';
  }

  private inspectNetHandle(handle: connection.NetHandle, propsArg: connection.ConnectionProperties | undefined,
    capsArg: connection.NetCapabilities | undefined, trigger: string): void {
    if (this.tunFd < 0 || handle.netId <= 0) {
      return;
    }
    let caps: connection.NetCapabilities | undefined = capsArg;
    if (!caps) {
      try {
        caps = connection.getNetCapabilitiesSync(handle);
      } catch (_capErr) {
      }
    }
    const bearer: string = this.describeBearer(caps);
    if (bearer === 'vpn') {
      return;
    }

    let props: connection.ConnectionProperties | undefined = propsArg;
    if (!props) {
      try {
        props = connection.getConnectionPropertiesSync(handle);
      } catch (_propErr) {
      }
    }
    const ifaceName: string = props && props.interfaceName ? props.interfaceName.trim() : '';
    if (this.isIgnoredInterface(ifaceName)) {
      return;
    }

    if (!this.hasBaselineNet) {
      this.hasBaselineNet = true;
      this.wasOffline = false;
      this.activeNetId = handle.netId;
      this.lastIfaceName = ifaceName;
      this.lastBearer = bearer;
      CoreBridgeService.notifyNetworkChange(ifaceName, `baseline-${bearer}`, 0);
      hilog.info(DOMAIN, TAG, 'Network monitor baseline: netId=%{public}d iface=%{public}s bearer=%{public}s',
        handle.netId, ifaceName, bearer);
      this.appendExtLog(`netMonitor baseline iface=${ifaceName} bearer=${bearer}`);
      return;
    }

    const changed: boolean = this.wasOffline ||
      ifaceName !== this.lastIfaceName ||
      (bearer !== this.lastBearer && bearer !== 'net');
    if (!changed) {
      this.activeNetId = handle.netId;
      return;
    }

    let reason: string = `route-${bearer}-${trigger}`;
    if (this.wasOffline) {
      reason = `recover-${bearer}`;
    } else if (bearer !== this.lastBearer && this.lastBearer.length > 0) {
      reason = `switch-${this.lastBearer}-to-${bearer}`;
    } else if (ifaceName !== this.lastIfaceName) {
      reason = `iface-${this.lastIfaceName}-to-${ifaceName}`;
    }

    this.activeNetId = handle.netId;
    this.lastIfaceName = ifaceName;
    this.lastBearer = bearer;
    this.wasOffline = false;

    const ok: boolean = CoreBridgeService.notifyNetworkChange(ifaceName, reason, FLAG_REBIND_TS | FLAG_PRUNE_NON_TS);
    hilog.info(DOMAIN, TAG, 'Network roaming detected: reason=%{public}s iface=%{public}s notified=%{public}s',
      reason, ifaceName, ok ? 'true' : 'false');
    this.appendExtLog(`netMonitor change reason=${reason} iface=${ifaceName} notified=${ok}`);
  }

  private startNetworkMonitor(): void {
    this.stopNetworkMonitor();
    this.activeNetId = -1;
    this.lastIfaceName = '';
    this.lastBearer = '';
    this.hasBaselineNet = false;
    this.wasOffline = false;

    try {
      const nc: connection.NetConnection = connection.createNetConnection();
      nc.on('netAvailable', (handle: connection.NetHandle): void => {
        this.inspectNetHandle(handle, undefined, undefined, 'available');
      });
      nc.on('netConnectionPropertiesChange', (info: connection.NetConnectionPropertyInfo): void => {
        this.inspectNetHandle(info.netHandle, info.connectionProperties, undefined, 'props');
      });
      nc.on('netCapabilitiesChange', (info: connection.NetCapabilityInfo): void => {
        this.inspectNetHandle(info.netHandle, undefined, info.netCap, 'caps');
      });
      nc.on('netLost', (handle: connection.NetHandle): void => {
        if (this.tunFd < 0) {
          return;
        }
        if (this.activeNetId > 0 && handle.netId !== this.activeNetId) {
          return;
        }
        this.wasOffline = true;
        this.activeNetId = -1;
        CoreBridgeService.notifyNetworkChange('', 'net-lost', 0);
        hilog.info(DOMAIN, TAG, 'Active network lost: netId=%{public}d', handle.netId);
        this.appendExtLog(`netMonitor lost netId=${handle.netId}`);
      });
      nc.register((err: BusinessError): void => {
        if (err) {
          hilog.warn(DOMAIN, TAG, 'NetConnection register failed: code=%{public}d msg=%{public}s',
            err.code ?? -1, err.message ?? '');
          return;
        }
        hilog.info(DOMAIN, TAG, 'HarmonyOS NetConnection roaming monitor registered');
        try {
          const defHandle: connection.NetHandle = connection.getDefaultNetSync();
          if (defHandle && defHandle.netId > 0) {
            this.inspectNetHandle(defHandle, undefined, undefined, 'initial');
          }
        } catch (_defErr) {
        }
      });
      this.netConn = nc;
    } catch (err) {
      const bErr: BusinessError = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'startNetworkMonitor failed: code=%{public}d msg=%{public}s',
        bErr.code ?? -1, bErr.message ?? '');
    }
  }

  private stopNetworkMonitor(): void {
    const nc: connection.NetConnection | undefined = this.netConn;
    this.netConn = undefined;
    this.activeNetId = -1;
    this.hasBaselineNet = false;
    this.wasOffline = false;
    if (nc) {
      try {
        nc.unregister((_err: BusinessError): void => {});
      } catch (_err) {
      }
    }
  }

  private async startTunnel(): Promise<void> {
    if (this.starting || this.tunFd >= 0) {
      return;
    }
    if (!this.connection) {
      hilog.error(DOMAIN, TAG, 'VPN connection is not ready');
      this.appendExtLog('error: VPN connection object is undefined');
      return;
    }
    if (this.configPath.length === 0) {
      this.configPath = `${this.context.filesDir}/runtime/current.yaml`;
    }

    this.starting = true;
    this.appendExtLog(`startTunnel begin config=${this.configPath}`);
    try {
      const config: vpnExtension.VpnConfig = this.createSafeTunConfig();
      try {
        this.tunFd = await this.connection.create(config);
      } catch (createErr) {
        const bErr: BusinessError = createErr as BusinessError;
        this.appendExtLog(`connection.create failed code=${bErr.code ?? -1} msg=${bErr.message ?? ''}, retrying after destroy`);
        try {
          await this.connection.destroy();
        } catch (_destroyErr) {
        }
        await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 300); });
        this.tunFd = await this.connection.create(config);
      }
      hilog.info(DOMAIN, TAG, 'VPN TUN created, fd=%{public}d, mtu=%{public}d, config=%{public}s',
        this.tunFd, MOBILE_TUN_MTU, this.configPath);
      this.appendExtLog(`connection.create ok tunFd=${this.tunFd} mtu=${MOBILE_TUN_MTU}`);
      try {
        await this.connection.protectProcessNet();
        hilog.info(DOMAIN, TAG, 'VPN process network protected for native core outbound sockets');
        this.appendExtLog('protectProcessNet ok');
      } catch (protectErr) {
        const bErr: BusinessError = protectErr as BusinessError;
        hilog.warn(DOMAIN, TAG, 'VPN process network protection failed: %{public}s', JSON.stringify(protectErr));
        this.appendExtLog(`protectProcessNet failed code=${bErr.code ?? -1} msg=${bErr.message ?? ''}`);
      }
      const coreState: CoreBridgeState = CoreBridgeService.startTun(this.configPath, this.tunFd);
      if (!coreState.running) {
        hilog.error(DOMAIN, TAG, 'Native core bridge failed: error=%{public}s adapter=%{public}s adapterKind=%{public}s loadError=%{public}s nativeFd=%{public}d',
          coreState.lastError, coreState.adapterMode, coreState.adapterKind, coreState.adapterLoadError, coreState.nativeFd);
        this.appendExtLog(`startTun FAILED adapter=${coreState.adapterMode} kind=${coreState.adapterKind} loadErr=${coreState.adapterLoadError} lastErr=${coreState.lastError}`);
      } else {
        hilog.info(DOMAIN, TAG, 'Native core bridge started: mode=%{public}s adapter=%{public}s adapterVersion=%{public}s nativeFd=%{public}d adapterKind=%{public}s realReady=%{public}s supportsControllerOnly=%{public}s',
          coreState.coreMode, coreState.adapterMode, coreState.adapterVersion, coreState.nativeFd,
          coreState.adapterKind, coreState.realConnectionReady ? 'true' : 'false',
          coreState.supportsControllerOnly ? 'true' : 'false');
        this.appendExtLog(`startTun OK mode=${coreState.coreMode} adapter=${coreState.adapterMode} kind=${coreState.adapterKind} ver=${coreState.adapterVersion} nativeFd=${coreState.nativeFd}`);
        this.startNetworkMonitor();
        await this.markControllerReadyInVpnProcess();
      }
    } catch (err) {
      const bErr: BusinessError = err as BusinessError;
      const msg: string = `startTunnel exception code=${bErr.code ?? -1} msg=${bErr.message ?? JSON.stringify(err)}`;
      hilog.error(DOMAIN, TAG, 'Failed to create VPN TUN: %{public}s', msg);
      this.appendExtLog(msg);
      this.tunFd = -1;
    } finally {
      this.starting = false;
    }
  }

  private async markControllerReadyInVpnProcess(): Promise<void> {
    const controllerReady: ControllerStatus = await MihomoControllerService.waitForVersion(10, 300);
    if (controllerReady.available) {
      const readyState: CoreBridgeState = CoreBridgeService.markControllerReady(true, controllerReady.version);
      hilog.info(DOMAIN, TAG, 'Controller ready: controllerVersion=%{public}s adapter=%{public}s adapterVersion=%{public}s nativeFd=%{public}d realReady=%{public}s forwarderActive=%{public}s',
        controllerReady.version, readyState.adapterMode, readyState.adapterVersion, readyState.nativeFd,
        readyState.realConnectionReady ? 'true' : 'false', readyState.forwarderActive ? 'true' : 'false');
      return;
    }

    const notReadyState: CoreBridgeState = CoreBridgeService.markControllerReady(false, '');
    hilog.warn(DOMAIN, TAG, 'Controller readiness failed: message=%{public}s adapter=%{public}s adapterVersion=%{public}s nativeFd=%{public}d',
      controllerReady.message, notReadyState.adapterMode, notReadyState.adapterVersion, notReadyState.nativeFd);
  }

  private async stopTunnel(): Promise<void> {
    this.stopNetworkMonitor();
    if (!this.connection) {
      this.tunFd = -1;
      return;
    }

    try {
      // Cleanup order: stop forwarder -> stop mihomo via native bridge, then destroy VPN
      const coreState: CoreBridgeState = CoreBridgeService.stopTun();
      hilog.info(DOMAIN, TAG, 'Native core bridge stopped: mode=%{public}s nativeFd=%{public}d controllerReady=%{public}s stopCount=%{public}d',
        coreState.coreMode, coreState.nativeFd, coreState.controllerReady ? 'true' : 'false', coreState.stopCount);
      await this.connection.destroy();
      hilog.info(DOMAIN, TAG, 'VPN connection destroyed');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'Destroy VPN connection failed: %{public}s', JSON.stringify(err));
    } finally {
      this.tunFd = -1;
    }
  }

  private createSafeTunConfig(): vpnExtension.VpnConfig {
    return {
      addresses: [
        {
          address: {
            address: '198.18.0.1',
            family: 1
          },
          prefixLength: 16
        }
      ],
      routes: [
        {
          interface: '',
          destination: {
            address: {
              address: '0.0.0.0',
              family: 1
            },
            prefixLength: 0
          },
          gateway: {
            address: '0.0.0.0',
            family: 1
          },
          hasGateway: false,
          isDefaultRoute: true
        }
      ],
      dnsAddresses: [
        '198.18.0.2'
      ],
      blockedApplications: [
        BUNDLE_NAME
      ],
      mtu: MOBILE_TUN_MTU,
      isIPv4Accepted: true,
      isIPv6Accepted: false,
      isInternal: false,
      isBlocking: false
    };
  }
}
