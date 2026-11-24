import { bundleManager, common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { rpc } from '@kit.IPCKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0001;
const TAG: string = 'VpnKeepAlive';
const BUNDLE_NAME: string = 'com.sjfarmltd.tailscale';
const ENTRY_ABILITY_NAME: string = 'EntryAbility';
const VPN_EXTENSION_ABILITY_NAME: string = 'ClashVpnExtensionAbility';

/**
 * Maintains a HarmonyOS 7 API 23 `dataTransfer` continuous task and an
 * active RPC binding to ClashVpnExtensionAbility (PR #22) so the VPN process
 * is promoted above the background Extension OOM kill tier.
 */
export class VpnKeepAliveService {
  private static task?: backgroundTaskManager.ContinuousTaskNotification;
  private static extensionConnectionId: number = -1;

  static async start(context: common.UIAbilityContext): Promise<void> {
    if (!VpnKeepAliveService.task) {
      try {
        const info: wantAgent.WantAgentInfo = {
          wants: [{ bundleName: BUNDLE_NAME, abilityName: ENTRY_ABILITY_NAME }],
          actionType: wantAgent.OperationType.START_ABILITY,
          requestCode: 1001,
          actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
        };
        const agent: WantAgent = await wantAgent.getWantAgent(info);
        VpnKeepAliveService.task = await VpnKeepAliveService.startDataTransferTask(context, agent);
        hilog.info(DOMAIN, TAG, 'Continuous dataTransfer background task started');
      } catch (err) {
        const bErr = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'Failed to start background task: code=%{public}d msg=%{public}s',
          bErr.code ?? -1, bErr.message ?? '');
      }
    }

    VpnKeepAliveService.bindExtension(context);
  }

  static async stop(context: common.UIAbilityContext): Promise<void> {
    VpnKeepAliveService.unbindExtension(context);

    try {
      const task = VpnKeepAliveService.task;
      let taskId: number | undefined = task?.continuousTaskId;
      if (taskId === undefined && typeof backgroundTaskManager.getAllContinuousTasks === 'function') {
        const tasks: backgroundTaskManager.ContinuousTaskInfo[] =
          await backgroundTaskManager.getAllContinuousTasks(context, true);
        const match = tasks.find((item: backgroundTaskManager.ContinuousTaskInfo) =>
          item.abilityName === ENTRY_ABILITY_NAME && item.backgroundModes.includes('dataTransfer'));
        taskId = match?.continuousTaskId;
      }
      if (taskId !== undefined) {
        await backgroundTaskManager.stopBackgroundRunning(context, taskId);
      } else if (task) {
        await backgroundTaskManager.stopBackgroundRunning(context);
      }
      VpnKeepAliveService.task = undefined;
      hilog.info(DOMAIN, TAG, 'Continuous dataTransfer background task stopped');
    } catch (err) {
      VpnKeepAliveService.task = undefined;
      const bErr = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'Failed to stop background task: code=%{public}d msg=%{public}s',
        bErr.code ?? -1, bErr.message ?? '');
    }
  }

  private static startDataTransferTask(context: common.UIAbilityContext,
    agent: WantAgent): Promise<backgroundTaskManager.ContinuousTaskNotification> {
    if (typeof backgroundTaskManager.ContinuousTaskRequest === 'function' &&
      backgroundTaskManager.BackgroundTaskMode !== undefined &&
      backgroundTaskManager.BackgroundTaskSubmode !== undefined) {
      const request: backgroundTaskManager.ContinuousTaskRequest = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
      request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION];
      request.wantAgent = agent;
      request.combinedTaskNotification = false;
      return backgroundTaskManager.startBackgroundRunning(context, request);
    }
    return backgroundTaskManager.startBackgroundRunning(context, ['dataTransfer'], agent);
  }

  private static bindExtension(context: common.UIAbilityContext): void {
    if (VpnKeepAliveService.extensionConnectionId >= 0 ||
      typeof context.connectServiceExtensionAbility !== 'function') {
      return;
    }
    const options: common.ConnectOptions = {
      onConnect: (_element: bundleManager.ElementName, _remote: rpc.IRemoteObject): void => {
        hilog.info(DOMAIN, TAG, 'Bound ClashVpnExtensionAbility via RPC');
      },
      onDisconnect: (_element: bundleManager.ElementName): void => {
        VpnKeepAliveService.extensionConnectionId = -1;
        hilog.info(DOMAIN, TAG, 'ClashVpnExtensionAbility RPC disconnected');
      },
      onFailed: (code: number): void => {
        VpnKeepAliveService.extensionConnectionId = -1;
        hilog.warn(DOMAIN, TAG, 'ClashVpnExtensionAbility RPC bind failed: %{public}d', code);
      }
    };
    try {
      VpnKeepAliveService.extensionConnectionId = context.connectServiceExtensionAbility(
        { bundleName: BUNDLE_NAME, abilityName: VPN_EXTENSION_ABILITY_NAME },
        options
      );
    } catch (err) {
      VpnKeepAliveService.extensionConnectionId = -1;
      const bErr = err as BusinessError;
      hilog.warn(DOMAIN, TAG, 'connectServiceExtensionAbility threw: code=%{public}d', bErr.code ?? -1);
    }
  }

  private static unbindExtension(context: common.UIAbilityContext): void {
    const id: number = VpnKeepAliveService.extensionConnectionId;
    if (id < 0) {
      return;
    }
    VpnKeepAliveService.extensionConnectionId = -1;
    try {
      context.disconnectServiceExtensionAbility(id).catch((): void => {});
    } catch (_err) {
    }
  }
}
