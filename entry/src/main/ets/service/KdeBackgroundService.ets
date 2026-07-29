import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppNotifier } from '../common/AppNotifier';
import { AppSession } from '../app/AppSession';
import { DeviceListItem } from './KdeTypes';

/**
 * Keeps the process alive under home / lock screen so KDE LAN TLS/UDP survive.
 *
 * IMPORTANT: multiDeviceConnection is WRONG for KDE Connect.
 * HarmonyOS only treats SoftBus / 分布式 / 投播 as "multi-device".
 * Plain TCP/UDP gets cancelled with:
 *   SYSTEM_CANCEL (2) + detailed SYSTEM_CANCEL_NOT_USE_MULTI_DEVICE (10)
 *
 * We use dataTransfer instead: KDE sessions continuously exchange packets
 * (battery, mpris, clipboard, files). Progress must be refreshed on the
 * system continuous-task live-view notification or the task is cancelled.
 */
export class KdeBackgroundService {
  private static instance: KdeBackgroundService | null = null;
  private context: common.UIAbilityContext | null = null;
  /** Service shell started (listeners + notification). */
  private running: boolean = false;
  /** System continuous task currently held. */
  private taskActive: boolean = false;
  private deviceSubId: number = -1;
  private netConn: connection.NetConnection | null = null;
  private wantAgent: WantAgent | null = null;
  private debounceTimer: number = -1;
  private cancelListening: boolean = false;
  /** Continuous-task system notification id (for live-view progress). */
  private taskNotificationId: number = -1;
  private taskSlotType: notificationManager.SlotType =
    notificationManager.SlotType.SERVICE_INFORMATION;
  private progressTimer: number = -1;
  private progressValue: number = 0;
  private retryTimer: number = -1;
  private retryCount: number = 0;

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
    this.context = context;
    if (this.running) {
      await this.ensureContinuousTask();
      return;
    }
    this.running = true;
    console.info('[BgSvc] start');

    this.wireCancelListener();
    this.updateNotification();

    this.deviceSubId = AppSession.getInstance().subscribeDevices(() => {
      this.updateNotification();
      // Re-assert keep-alive when devices go online (task may have been cancelled while idle)
      if (!this.taskActive && this.countOnlineDevices() > 0) {
        this.ensureContinuousTask().catch(() => {
        });
      }
    });

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

    await this.ensureContinuousTask();
  }

  /**
   * Call from onBackground / onForeground so sessions stay alive under lock.
   */
  public async ensureRunning(): Promise<void> {
    if (!this.context) {
      console.warn('[BgSvc] ensureRunning: no context');
      return;
    }
    if (!this.running) {
      await this.start(this.context);
      return;
    }
    await this.ensureContinuousTask();
  }

  /**
   * dataTransfer continuous task + periodic live-view progress.
   * Without this, HarmonyOS freezes the process after home/lock and TLS dies.
   */
  private async ensureContinuousTask(): Promise<void> {
    if (!this.context) {
      return;
    }
    if (this.taskActive) {
      console.info('[BgSvc] continuous task already active');
      this.ensureProgressTimer();
      return;
    }

    if (!this.wantAgent) {
      this.wantAgent = await this.buildWantAgent();
    }
    if (!this.wantAgent) {
      console.error('[BgSvc] cannot start continuous task: WantAgent missing');
      return;
    }

    // dataTransfer: real LAN packet exchange (battery/mpris/clipboard/files).
    // Do NOT use multiDeviceConnection — system requires SoftBus multi-device APIs.
    const modes: string[] = ['dataTransfer'];
    try {
      const res: backgroundTaskManager.ContinuousTaskNotification =
        await backgroundTaskManager.startBackgroundRunning(
          this.context,
          modes,
          this.wantAgent
        );
      this.onTaskStarted(res);
      return;
    } catch (e1) {
      const err1 = e1 as BusinessError;
      if (this.isAlreadyRunningError(err1)) {
        this.taskActive = true;
        this.ensureProgressTimer();
        console.info(`[BgSvc] continuous task already held: ${err1.message}`);
        return;
      }
      console.warn(
        `[BgSvc] string[] dataTransfer failed: code=${err1.code} ${err1.message}, try enum`
      );
    }

    try {
      await backgroundTaskManager.startBackgroundRunning(
        this.context,
        backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
        this.wantAgent
      );
      this.taskActive = true;
      this.retryCount = 0;
      this.ensureProgressTimer();
      // Immediately publish a progress tick (enum path has no ContinuousTaskNotification)
      this.publishProgress();
      console.info('[BgSvc] continuous task started (DATA_TRANSFER enum)');
    } catch (e2) {
      const err2 = e2 as BusinessError;
      if (this.isAlreadyRunningError(err2)) {
        this.taskActive = true;
        this.ensureProgressTimer();
        console.info(`[BgSvc] continuous task already held (enum): ${err2.message}`);
        return;
      }
      this.taskActive = false;
      console.error(
        `[BgSvc] startBackgroundRunning failed: code=${err2.code} ${err2.message}`
      );
    }
  }

  private onTaskStarted(res: backgroundTaskManager.ContinuousTaskNotification): void {
    this.taskActive = true;
    this.retryCount = 0;
    this.taskNotificationId = res.notificationId;
    this.taskSlotType = res.slotType;
    console.info(
      `[BgSvc] continuous task started (dataTransfer) notificationId=${res.notificationId}` +
        (res.continuousTaskId !== undefined ? ` taskId=${res.continuousTaskId}` : '')
    );
    this.ensureProgressTimer();
    // First progress update ASAP (docs: must update within 10 minutes; sooner is safer)
    this.publishProgress();
  }

  private ensureProgressTimer(): void {
    if (this.progressTimer !== -1) {
      return;
    }
    // Refresh every 45s so system does not cancel dataTransfer for stale progress
    this.progressTimer = setInterval(() => {
      this.publishProgress();
    }, 45 * 1000);
  }

  private stopProgressTimer(): void {
    if (this.progressTimer !== -1) {
      clearInterval(this.progressTimer);
      this.progressTimer = -1;
    }
  }

  /**
   * Update continuous-task live-view progress.
   * Required for dataTransfer; without updates the task is cancelled.
   */
  private publishProgress(): void {
    if (!this.context || !this.taskActive) {
      return;
    }
    const online = this.countOnlineDevices();
    // Indeterminate-style cycling progress (connection is ongoing, not a finite download)
    this.progressValue = (this.progressValue + 7) % 100;
    const text = online > 0
      ? `已连接 ${online} 台设备，保持数据通道…`
      : '等待设备连接，保持网络发现…';

    // Prefer system continuous-task notification id when available
    const id = this.taskNotificationId >= 0
      ? this.taskNotificationId
      : AppNotifier.PERSISTENT_NOTIFY_ID_FOR_PROGRESS;

    try {
      const request: notificationManager.NotificationRequest = {
        id: id,
        notificationSlotType: this.taskSlotType,
        content: {
          notificationContentType:
            notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
          systemLiveView: {
            title: 'HMConnect',
            text: text,
            typeCode: 0,
            progress: {
              maxValue: 100,
              currentValue: this.progressValue,
              isPercentage: true
            }
          }
        },
        isOngoing: true,
        tapDismissed: false
      };
      if (this.wantAgent) {
        request.wantAgent = this.wantAgent;
      }
      notificationManager.publish(request).then(() => {
        console.info(`[BgSvc] progress updated id=${id} value=${this.progressValue} online=${online}`);
      }).catch((e: BusinessError) => {
        // Fallback: plain text update if live-view type rejected
        console.warn(
          `[BgSvc] live-view progress failed code=${e.code} ${e.message}, try basic`
        );
        this.publishProgressBasic(id, text);
      });
    } catch (e) {
      const err = e as BusinessError;
      console.warn(`[BgSvc] publishProgress exception: code=${err.code} ${err.message}`);
    }
  }

  private publishProgressBasic(id: number, text: string): void {
    try {
      const request: notificationManager.NotificationRequest = {
        id: id,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        content: {
          notificationContentType:
            notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
          normal: {
            title: 'HMConnect',
            text: text
          }
        },
        isOngoing: true,
        tapDismissed: false
      };
      if (this.wantAgent) {
        request.wantAgent = this.wantAgent;
      }
      notificationManager.publish(request).catch((e: BusinessError) => {
        console.warn(`[BgSvc] basic progress failed: code=${e.code} ${e.message}`);
      });
    } catch (_e) {
      // ignore
    }
  }

  private countOnlineDevices(): number {
    const devices: DeviceListItem[] = AppSession.getInstance().getLastDevices();
    let n = 0;
    for (let i = 0; i < devices.length; i++) {
      if (devices[i].trusted && devices[i].online) {
        n++;
      }
    }
    return n;
  }

  private isAlreadyRunningError(err: BusinessError): boolean {
    const msg = (err.message ?? '').toLowerCase();
    if (msg.indexOf('already') >= 0 || msg.indexOf('exist') >= 0) {
      return true;
    }
    const code = err.code;
    return code === 9800006 || code === 9800005;
  }

  private cancelReasonName(reason: number): string {
    // backgroundTaskManager.ContinuousTaskCancelReason
    switch (reason) {
      case 1:
        return 'USER_CANCEL';
      case 2:
        return 'SYSTEM_CANCEL (often detailed=NOT_USE_MULTI_DEVICE if mode was multiDevice)';
      case 3:
        return 'USER_CANCEL_REMOVE_NOTIFICATION';
      case 4:
        return 'SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED';
      case 5:
        return 'SYSTEM_CANCEL_AUDIO_PLAYBACK_NOT_USE_AVSESSION';
      case 6:
        return 'SYSTEM_CANCEL_AUDIO_PLAYBACK_NOT_RUNNING';
      case 7:
        return 'SYSTEM_CANCEL_AUDIO_RECORDING_NOT_RUNNING';
      case 8:
        return 'SYSTEM_CANCEL_NOT_USE_LOCATION';
      case 9:
        return 'SYSTEM_CANCEL_NOT_USE_BLUETOOTH';
      case 10:
        return 'SYSTEM_CANCEL_NOT_USE_MULTI_DEVICE';
      case 11:
        return 'SYSTEM_CANCEL_USE_ILLEGALLY';
      default:
        return `UNKNOWN(${reason})`;
    }
  }

  private async buildWantAgent(): Promise<WantAgent | null> {
    if (!this.context) {
      return null;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          deviceId: '',
          bundleName: this.context.abilityInfo.bundleName,
          moduleName: this.context.abilityInfo.moduleName,
          abilityName: this.context.abilityInfo.name,
          action: 'ohos.want.action.home'
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 100,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      console.info('[BgSvc] WantAgent ready');
      return agent;
    } catch (e) {
      const err = e as BusinessError;
      console.error(`[BgSvc] build wantAgent failed: code=${err.code} ${err.message}`);
      return null;
    }
  }

  private wireCancelListener(): void {
    if (this.cancelListening) {
      return;
    }
    try {
      backgroundTaskManager.on('continuousTaskCancel',
        (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
          const name = this.cancelReasonName(info.reason as number);
          console.warn(
            `[BgSvc] continuousTaskCancel id=${info.id} reason=${info.reason} (${name})`
          );
          this.taskActive = false;
          this.stopProgressTimer();
          // User dismissed notification — do not fight the user
          if (info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL ||
            info.reason ===
              backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL_REMOVE_NOTIFICATION) {
            console.info('[BgSvc] user cancelled continuous task; skip auto-retry');
            return;
          }
          // System cancelled (wrong mode / low speed / consistency) — retry dataTransfer
          this.scheduleRetry();
        });
      this.cancelListening = true;
      console.info('[BgSvc] continuousTaskCancel listener registered');
    } catch (e) {
      const err = e as BusinessError;
      console.warn(
        `[BgSvc] on continuousTaskCancel failed: code=${err.code} ${err.message}`
      );
    }
  }

  private scheduleRetry(): void {
    if (!this.running || !this.context) {
      return;
    }
    if (this.retryTimer !== -1) {
      return;
    }
    // Backoff: 3s, 8s, 15s, then stop (avoid thrashing)
    const delays: number[] = [3000, 8000, 15000];
    if (this.retryCount >= delays.length) {
      console.warn('[BgSvc] continuous task retry exhausted');
      return;
    }
    const delay = delays[this.retryCount];
    this.retryCount++;
    console.info(`[BgSvc] schedule continuous task retry #${this.retryCount} in ${delay}ms`);
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      this.ensureContinuousTask().catch((e: Error) => {
        console.warn('[BgSvc] retry ensureContinuousTask failed:', e.message);
      });
    }, delay);
  }

  /** Stop continuous task, cancel notification, unsubscribe. */
  public stop(): void {
    if (!this.running) {
      return;
    }
    this.running = false;
    this.taskActive = false;
    console.info('[BgSvc] stop');

    this.stopProgressTimer();
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }

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
        this.netConn.unregister((_err: BusinessError) => {
        });
      } catch (_e) {
        // ignore
      }
      this.netConn = null;
    }

    if (this.context) {
      try {
        backgroundTaskManager.stopBackgroundRunning(this.context);
      } catch (_e) {
        // ignore
      }
    }

    AppNotifier.getInstance().cancelPersistent();
    this.wantAgent = null;
    this.taskNotificationId = -1;
    this.context = null;
  }

  /** Called when device list changes. Debounced to avoid flicker during state transitions. */
  public updateNotification(): void {
    if (!this.running || !this.context) {
      return;
    }
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

  private onNetworkChange(): void {
    console.info('[BgSvc] onNetworkChange');
    AppSession.getInstance().getService().onNetworkChange();
  }
}
