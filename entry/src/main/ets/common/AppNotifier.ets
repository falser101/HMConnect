import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * Local system notifications (Ping etc.).
 * Requests notification enablement once; failures are logged, never thrown to callers.
 * Tap on a notification brings EntryAbility to the foreground via WantAgent.
 */
export class AppNotifier {
  private static instance: AppNotifier | null = null;
  private context: common.UIAbilityContext | null = null;
  private permissionAsked: boolean = false;
  private nextId: number = 2000;
  /** Fixed id so find-my-phone can replace / cancel the same banner. */
  private static readonly FIND_PHONE_NOTIFY_ID: number = 1901;

  public static getInstance(): AppNotifier {
    if (!AppNotifier.instance) {
      AppNotifier.instance = new AppNotifier();
    }
    return AppNotifier.instance;
  }

  public setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
  }

  /** Call once after Ability start so the first Ping can show a banner. */
  public prepare(): void {
    this.ensureEnabled().catch((e: Error) => {
      console.warn('[Notify] prepare failed:', e.message);
    });
  }

  private async ensureEnabled(): Promise<boolean> {
    try {
      let enabled = notificationManager.isNotificationEnabledSync();
      if (enabled) {
        return true;
      }
    } catch (_e) {
      // fall through to request
    }
    if (this.permissionAsked) {
      return false;
    }
    this.permissionAsked = true;
    if (!this.context) {
      console.warn('[Notify] no context, cannot request notification permission');
      return false;
    }
    try {
      await notificationManager.requestEnableNotification(this.context);
      try {
        await notificationManager.addSlot(notificationManager.SlotType.SOCIAL_COMMUNICATION);
      } catch (_slot) {
        // slot may already exist
      }
      return notificationManager.isNotificationEnabledSync();
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] requestEnableNotification failed: code=${err.code} ${err.message}`);
      return false;
    }
  }

  /** Build a WantAgent that starts EntryAbility when the notification is tapped. */
  private async buildOpenAppAgent(requestCode: number, from: string): Promise<WantAgent | undefined> {
    if (!this.context) {
      return undefined;
    }
    let bundleName = this.context.abilityInfo.bundleName;
    let abilityName = this.context.abilityInfo.name;
    let moduleName = this.context.abilityInfo.moduleName;
    try {
      let info: wantAgent.WantAgentInfo = {
        wants: [
          {
            deviceId: '',
            bundleName: bundleName,
            moduleName: moduleName,
            abilityName: abilityName,
            action: 'ohos.want.action.home',
            parameters: {
              'fromNotification': from
            }
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: requestCode,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      return await wantAgent.getWantAgent(info);
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] getWantAgent failed: code=${err.code} ${err.message}`);
      return undefined;
    }
  }

  /**
   * Show a system notification for an inbound KDE Connect Ping.
   * Each ping uses a new id so successive pings stack instead of replacing.
   * Tapping the notification opens the app (EntryAbility).
   */
  public async notifyPing(peerName: string, message: string): Promise<void> {
    let ok = await this.ensureEnabled();
    if (!ok) {
      console.warn('[Notify] notifications disabled; skip ping banner');
      return;
    }
    let name = peerName.length > 0 ? peerName : '设备';
    let body = message && message.trim().length > 0 ? message.trim() : '向你发送了 Ping';
    let id = this.nextId++;
    if (this.nextId > 9000) {
      this.nextId = 2000;
    }
    let agent = await this.buildOpenAppAgent(id, 'ping');
    let request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: `${name} 发来 Ping`,
          text: body
        }
      },
      // Dismiss after tap when wantAgent is present
      tapDismissed: true
    };
    if (agent) {
      request.wantAgent = agent;
    }
    try {
      await notificationManager.publish(request);
      console.info(`[Notify] ping published id=${id} from ${name} clickOpen=${agent !== undefined}`);
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] publish failed: code=${err.code} ${err.message}`);
    }
  }

  /**
   * High-visibility banner when desktop rings this phone (Find My Phone).
   * Tap opens the app so the user can confirm / stop the alert.
   */
  public async notifyFindMyPhone(peerName: string): Promise<void> {
    let ok = await this.ensureEnabled();
    if (!ok) {
      console.warn('[Notify] notifications disabled; skip find-phone banner');
      return;
    }
    let name = peerName.length > 0 ? peerName : '电脑';
    let id = AppNotifier.FIND_PHONE_NOTIFY_ID;
    let agent = await this.buildOpenAppAgent(id, 'findmyphone');
    let request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: '正在查找这台设备',
          text: `${name} 发起了「找手机」· 点按打开应用`
        }
      },
      tapDismissed: true
    };
    if (agent) {
      request.wantAgent = agent;
    }
    try {
      await notificationManager.publish(request);
      console.info(`[Notify] find-phone published from ${name}`);
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] find-phone publish failed: code=${err.code} ${err.message}`);
    }
  }

  public async cancelFindMyPhone(): Promise<void> {
    try {
      await notificationManager.cancel(AppNotifier.FIND_PHONE_NOTIFY_ID);
    } catch (_e) {
      // ignore if already gone
    }
  }
}
