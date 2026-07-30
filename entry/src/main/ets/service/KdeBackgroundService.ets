import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { connection } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppNotifier } from '../common/AppNotifier';
import { AppSession } from '../app/AppSession';
import { DeviceListItem } from './KdeTypes';
import {
  ContinuousTaskCancelInfo,
  ContinuousTaskNotification,
  onContinuousTaskCancel,
  startContinuousTaskDataTransfer,
  startContinuousTaskStringModes,
  stopContinuousTask
} from './ContinuousTaskApi';

/**
 * Keeps the process alive under home / lock screen so KDE LAN TLS/UDP survive.
 *
 * IMPORTANT: multiDeviceConnection is WRONG for KDE Connect.
 * HarmonyOS only treats SoftBus / 分布式 / 投播 as "multi-device".
 * Plain TCP/UDP gets cancelled with:
 *   SYSTEM_CANCEL (2) + detailed SYSTEM_CANCEL_NOT_USE_MULTI_DEVICE (10)
 *
 * Modes:
 * - dataTransfer: KDE LAN packets (battery/mpris/clipboard/files)
 * - +audioPlayback when remote media is playing (lock-screen 播控 official requirement)
 * Never multiDeviceConnection alone (SoftBus-only; gets cancelled).
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
  /**
   * When true, continuous task includes audioPlayback.
   * Official lock-screen 播控: AVSession active + AUDIO_PLAYBACK long task.
   * dataTransfer alone is not enough for lock-screen media card.
   */
  private wantAudioPlayback: boolean = false;

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
    // Do not show persistent / progress banners (user request); cancel any leftover.
    AppNotifier.getInstance().cancelPersistent();
    this.cancelProgressBanner();

    this.deviceSubId = AppSession.getInstance().subscribeDevices(() => {
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
   * Public re-request after external code may have disrupted the task
   * (e.g. legacy find-phone stopBackgroundRunning).
   */
  public async reassertKeepAlive(): Promise<void> {
    if (!this.context) {
      return;
    }
    if (!this.running) {
      await this.start(this.context);
      return;
    }
    await this.forceRestartContinuousTask();
  }

  /**
   * Toggle AUDIO_PLAYBACK mode for lock-screen media card.
   * Official: AVSession active + AUDIO_PLAYBACK continuous task → 锁屏自动出播控卡片.
   * Also keeps dataTransfer for KDE LAN packets.
   */
  public setMediaPlaybackLongTask(needAudio: boolean): void {
    if (this.wantAudioPlayback === needAudio) {
      if (needAudio && !this.taskActive) {
        console.info('[BgSvc] audioPlayback wanted but task inactive — ensure');
        this.ensureContinuousTask().catch(() => {
        });
      }
      return;
    }
    this.wantAudioPlayback = needAudio;
    console.info(
      `[BgSvc] setMediaPlaybackLongTask audioPlayback=${needAudio} → restart modes`
    );
    this.forceRestartContinuousTask().catch((e: Error) => {
      console.warn('[BgSvc] mode switch failed:', e.message);
    });
  }

  /**
   * Force re-request even if we think taskActive is still true.
   * Stops existing task first so mode changes (dataTransfer ↔ +audioPlayback) apply.
   */
  public async forceRestartContinuousTask(): Promise<void> {
    this.taskActive = false;
    this.retryCount = 0;
    this.stopProgressTimer();
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    if (this.context &&
      canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      try {
        stopContinuousTask(this.context);
      } catch (_e) {
        // ignore
      }
    }
    // Brief yield so system releases previous task slot
    await new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, 120);
    });
    await this.ensureContinuousTask();
  }

  private buildContinuousModes(): string[] {
    // dataTransfer: LAN (battery/mpris/clipboard/files)
    // audioPlayback: required for lock-screen media card with AVSession (official)
    if (this.wantAudioPlayback) {
      return ['dataTransfer', 'audioPlayback'];
    }
    return ['dataTransfer'];
  }

  /**
   * Continuous task + progress refresh.
   * Modes: dataTransfer always; +audioPlayback when remote media is active.
   */
  private async ensureContinuousTask(): Promise<void> {
    if (!this.context) {
      return;
    }
    if (!canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      console.warn('[BgSvc] ContinuousTask SysCap unavailable on this device');
      return;
    }
    if (this.taskActive) {
      console.info('[BgSvc] continuous task already active');
      this.ensureProgressTimer();
      this.publishProgress();
      return;
    }

    if (!this.wantAgent) {
      this.wantAgent = await this.buildWantAgent();
    }
    if (!this.wantAgent) {
      console.error('[BgSvc] cannot start continuous task: WantAgent missing');
      return;
    }

    const modes: string[] = this.buildContinuousModes();
    console.info(`[BgSvc] requesting continuous task modes=[${modes.join(',')}]…`);
    try {
      if (canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
        const res: ContinuousTaskNotification =
          await startContinuousTaskStringModes(this.context, modes, this.wantAgent);
        this.onTaskStarted(res);
        console.info(
          `[BgSvc] continuous task OK modes=[${modes.join(',')}] notifyId=${res.notificationId}`
        );
        return;
      }
    } catch (e1) {
      const err1 = e1 as BusinessError;
      if (this.isAlreadyRunningError(err1)) {
        this.taskActive = true;
        this.retryCount = 0;
        this.ensureProgressTimer();
        this.publishProgress();
        console.info(`[BgSvc] continuous task already held: ${err1.message}`);
        return;
      }
      // Dual-mode may fail — try audioPlayback+dataTransfer reversed, then dataTransfer only
      if (this.wantAudioPlayback && modes.length > 1) {
        console.warn(
          `[BgSvc] dual-mode failed code=${err1.code} ${err1.message}, try audioPlayback+dataTransfer order`
        );
        try {
          const resAlt: ContinuousTaskNotification =
            await startContinuousTaskStringModes(
              this.context,
              ['audioPlayback', 'dataTransfer'],
              this.wantAgent
            );
          this.onTaskStarted(resAlt);
          console.info('[BgSvc] continuous task OK (audioPlayback first)');
          return;
        } catch (eAlt) {
          console.warn('[BgSvc] alt dual-mode failed:', JSON.stringify(eAlt));
        }
        try {
          const res2: ContinuousTaskNotification =
            await startContinuousTaskStringModes(
              this.context,
              ['dataTransfer'],
              this.wantAgent
            );
          this.onTaskStarted(res2);
          console.warn(
            '[BgSvc] held dataTransfer only — lock-screen card may be missing without audioPlayback'
          );
          return;
        } catch (_e2) {
        }
      }
      console.warn(
        `[BgSvc] string[] modes failed: code=${err1.code} ${err1.message}, try DATA_TRANSFER enum`
      );
    }

    try {
      if (canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
        await startContinuousTaskDataTransfer(this.context, this.wantAgent);
        this.taskActive = true;
        this.retryCount = 0;
        this.ensureProgressTimer();
        this.publishProgress();
        console.info('[BgSvc] continuous task started (DATA_TRANSFER enum)');
      }
    } catch (e2) {
      const err2 = e2 as BusinessError;
      if (this.isAlreadyRunningError(err2)) {
        this.taskActive = true;
        this.retryCount = 0;
        this.ensureProgressTimer();
        this.publishProgress();
        console.info(`[BgSvc] continuous task already held (enum): ${err2.message}`);
        return;
      }
      this.taskActive = false;
      console.error(
        `[BgSvc] startBackgroundRunning failed: code=${err2.code} ${err2.message}`
      );
      this.scheduleRetry(false);
    }
  }

  private onTaskStarted(res: ContinuousTaskNotification): void {
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
   * Continuous-task keepalive tick (no user-facing banner).
   * We intentionally do not publish HMConnect progress notifications.
   * System may still attach a single long-running-task chip to startBackgroundRunning.
   */
  private publishProgress(): void {
    if (!this.context || !this.taskActive) {
      return;
    }
    this.progressValue = (this.progressValue + 7) % 100;
  }

  /** Drop our progress fallback banner if present. */
  private cancelProgressBanner(): void {
    try {
      notificationManager.cancel(AppNotifier.PERSISTENT_NOTIFY_ID_FOR_PROGRESS);
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
    if (!canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      console.warn('[BgSvc] skip cancel listener: ContinuousTask SysCap unavailable');
      return;
    }
    if (canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      try {
        onContinuousTaskCancel((info: ContinuousTaskCancelInfo) => {
          const reason = info.reason;
          const name = this.cancelReasonName(reason);
          console.warn(
            `[BgSvc] continuousTaskCancel id=${info.id} reason=${reason} (${name})`
          );
          this.taskActive = false;
          this.stopProgressTimer();

          // HMConnect must stay connected under lock / after shade interactions.
          // Official docs: deleting the continuous-task notification stops the task
          // with USER_CANCEL. Pulling the shade often mis-swipes that banner; skipping
          // retry left TLS unprotected. Always re-request dataTransfer with backoff.
          // ContinuousTaskCancelReason.USER_CANCEL = 1, USER_CANCEL_REMOVE_NOTIFICATION = 3
          const isUserCancel = reason === 1 || reason === 3;
          if (isUserCancel) {
            this.retryCount = 0;
            console.info('[BgSvc] user-facing cancel — fast re-request continuous task');
            this.scheduleRetry(true);
            return;
          }
          this.scheduleRetry(false);
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
  }

  /**
   * Re-apply dataTransfer after cancel.
   * @param preferFast true after USER_CANCEL (1s / 3s / 8s); false for system (3s / 8s / 15s)
   */
  private scheduleRetry(preferFast: boolean = false): void {
    if (!this.running || !this.context) {
      return;
    }
    if (this.retryTimer !== -1) {
      return;
    }
    const delays: number[] = preferFast ? [1000, 3000, 8000] : [3000, 8000, 15000];
    if (this.retryCount >= delays.length) {
      console.warn('[BgSvc] continuous task retry exhausted');
      return;
    }
    const delay = delays[this.retryCount];
    this.retryCount++;
    console.info(
      `[BgSvc] schedule continuous task retry #${this.retryCount} in ${delay}ms` +
        (preferFast ? ' (fast)' : '')
    );
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

    if (this.context &&
      canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) {
      try {
        stopContinuousTask(this.context);
      } catch (_e) {
        // ignore
      }
    }

    AppNotifier.getInstance().cancelPersistent();
    this.cancelProgressBanner();
    this.wantAgent = null;
    this.taskNotificationId = -1;
    this.context = null;
  }

  /** Kept for callers; persistent banner is disabled. */
  public updateNotification(): void {
    AppNotifier.getInstance().cancelPersistent();
  }

  private onNetworkChange(): void {
    console.info('[BgSvc] onNetworkChange');
    AppSession.getInstance().getService().onNetworkChange();
  }
}
