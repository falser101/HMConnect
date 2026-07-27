import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppNotifier } from '../common/AppNotifier';
import { AppSession } from '../app/AppSession';
import { DeviceListItem } from './KdeTypes';

/**
 * Mirrors Android BackgroundService.kt pattern:
 * - Keeps the process alive via a continuous task (MULTI_DEVICE_CONNECTION).
 * - Publishes a persistent / ongoing notification showing connected device names.
 * - Listens for device-list changes and refreshes the notification.
 * - Monitors network changes and triggers a link-provider refresh.
 */
export class KdeBackgroundService {
  private static instance: KdeBackgroundService | null = null;
  private context: common.UIAbilityContext | null = null;
  private running: boolean = false;
  private deviceSubId: number = -1;
  private netConn: connection.NetConnection | null = null;
  private wantAgent: WantAgent | null = null;
  private debounceTimer: number = -1;

  private constructor() {
  }

  public static getInstance(): KdeBackgroundService {
    if (!KdeBackgroundService.instance) {
      KdeBackgroundService.instance = new KdeBackgroundService();
    }
    return KdeBackgroundService.instance;
  }

  /**
   * Start continuous task + persistent notification.
   * Call from EntryAbility.onCreate after AppSession is ready.
   */
  public async start(context: common.UIAbilityContext): Promise<void> {
    if (this.running) {
      return;
    }
    this.context = context;
    this.running = true;
    console.info('[BgSvc] start');

    // Build WantAgent that opens our app (same pattern as buildOpenAppAgent)
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          deviceId: '',
          bundleName: context.abilityInfo.bundleName,
          moduleName: context.abilityInfo.moduleName,
          abilityName: context.abilityInfo.name,
          action: 'ohos.want.action.home'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 100,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      this.wantAgent = await wantAgent.getWantAgent(info);
    } catch (e) {
      console.error('[BgSvc] build wantAgent failed:', JSON.stringify(e));
    }

    // Request continuous task (long-running background)
    try {
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.MULTI_DEVICE_CONNECTION, this.wantAgent!);
      console.info('[BgSvc] continuous task started');
    } catch (e) {
      const err = e as BusinessError;
      console.error('[BgSvc] startBackgroundRunning failed: code=', err.code, err.message);
      // Don't bail — notification alone is better than nothing
    }

    // Publish initial persistent notification
    this.updateNotification();

    // Subscribe to device list changes (mirrors Android addDeviceListChangedCallback)
    this.deviceSubId = AppSession.getInstance().subscribeDevices(() => {
      this.updateNotification();
    });

    // Monitor network changes (mirrors Android ConnectivityManager.NetworkCallback)
    try {
      this.netConn = connection.createNetConnection();
      this.netConn.register((err: BusinessError) => {
        if (err) {
          console.warn('[BgSvc] net register failed:', err.message);
          return;
        }
        console.info('[BgSvc] network listener registered');
      });
      this.netConn.on('netAvailable', () => {
        console.info('[BgSvc] netAvailable');
        this.onNetworkChange();
      });
    } catch (e) {
      console.warn('[BgSvc] net monitor setup failed:', JSON.stringify(e));
    }
  }

  /** Stop continuous task, cancel notification, unsubscribe. */
  public stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    console.info('[BgSvc] stop');

    if (this.deviceSubId >= 0) {
      AppSession.getInstance().unsubscribeDevices(this.deviceSubId);
      this.deviceSubId = -1;
    }

    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
      this.debounceTimer = -1;
    }

    if (this.netConn) {
      try {
        this.netConn.unregister((_err: BusinessError) => {});
      } catch (_e) {
        // ignore
      }
      this.netConn = null;
    }

    try {
      backgroundTaskManager.stopBackgroundRunning(this.context!);
    } catch (_e) {
      // ignore
    }

    AppNotifier.getInstance().cancelPersistent();
    this.context = null;
  }

  /** Called when device list changes. Debounced to avoid flicker during state transitions. */
  public updateNotification(): void {
    if (!this.running || !this.context) {
      return;
    }
    // Debounce: only apply after 300ms of no further changes
    if (this.debounceTimer !== -1) {
      clearTimeout(this.debounceTimer);
    }
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = -1;
      this.doUpdateNotification();
    }, 300);
  }

  private doUpdateNotification(): void {
    if (!this.context) {
      return;
    }
    const devices: DeviceListItem[] = AppSession.getInstance().getLastDevices();
    const names: string[] = [];
    const ids: string[] = [];
    for (const d of devices) {
      if (d.trusted && d.online) {
        names.push(d.deviceName);
        ids.push(d.deviceId);
      }
    }
    AppNotifier.getInstance().notifyPersistent(names, ids);
  }

  /** Trigger a network re-scan (matches Android onNetworkChange). */
  private onNetworkChange(): void {
    console.info('[BgSvc] onNetworkChange');
    AppSession.getInstance().getService().onNetworkChange();
  }
}
