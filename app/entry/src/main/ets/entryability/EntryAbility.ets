import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { http } from '@kit.NetworkKit';
import { window } from '@kit.ArkUI';
import { VpnKeepAliveService } from '../services/VpnKeepAliveService';

const DOMAIN: number = 0x0001;
const TAG: string = 'ClashHarmony';
const REBIND_ENDPOINT: string = 'http://127.0.0.1:9091/network/rebind';

export default class EntryAbility extends UIAbility {
  private backgroundAtMs: number = 0;

  onCreate(_want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility created');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility destroyed');
    VpnKeepAliveService.stop(this.context).catch((): void => {});
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Main page loaded');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Window stage destroyed');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility foreground');
    if (this.backgroundAtMs > 0) {
      const awayMs: number = Date.now() - this.backgroundAtMs;
      this.backgroundAtMs = 0;
      if (awayMs >= 30000) {
        this.triggerWakeRebind(awayMs >= 45000, `foreground-resume-${Math.floor(awayMs / 1000)}s`);
      }
    }
  }

  onBackground(): void {
    this.backgroundAtMs = Date.now();
    hilog.info(DOMAIN, TAG, 'EntryAbility background');
  }

  private triggerWakeRebind(rebindTailscale: boolean, reason: string): void {
    const client: http.HttpRequest = http.createHttp();
    const body: string = JSON.stringify({
      reason: reason,
      rebindTailscale: rebindTailscale,
      pruneNonTailscale: false
    });
    client.request(REBIND_ENDPOINT, {
      method: http.RequestMethod.POST,
      header: { 'Content-Type': 'application/json' },
      extraData: body,
      connectTimeout: 1500,
      readTimeout: 2000
    }).then((): void => {
      hilog.info(DOMAIN, TAG, 'Triggered wake rebind: reason=%{public}s rebindTS=%{public}s',
        reason, rebindTailscale ? 'true' : 'false');
    }).catch((): void => {
      // VPN core may not be running while UI comes to foreground; ignore silently.
    }).finally((): void => {
      client.destroy();
    });
  }
}
