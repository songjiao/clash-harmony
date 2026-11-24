import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { rpc } from '@kit.IPCKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import { CoreBridgeService, CoreBridgeState } from '../services/CoreBridgeService';
import { ControllerStatus, MihomoControllerService } from '../services/MihomoControllerService';
import nativeCore from 'libentry.so';

const DOMAIN: number = 0x0001;
const TAG: string = 'ClashVpnExtension';
const BUNDLE_NAME: string = 'com.sjfarmltd.tailscale';
const PARAM_CONFIG_PATH: string = 'configPath';

export default class ClashVpnExtensionAbility extends VpnExtensionAbility {
  private connection?: vpnExtension.VpnConnection;
  private tunFd: number = -1;
  private configPath: string = '';
  private starting: boolean = false;
  private bindStub?: rpc.RemoteObject;

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
      hilog.info(DOMAIN, TAG, 'VPN TUN created, fd=%{public}d, config=%{public}s', this.tunFd, this.configPath);
      this.appendExtLog(`connection.create ok tunFd=${this.tunFd}`);
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
      mtu: 1500,
      isIPv4Accepted: true,
      isIPv6Accepted: false,
      isInternal: false,
      isBlocking: false
    };
  }
}
