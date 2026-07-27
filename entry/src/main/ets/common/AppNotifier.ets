import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';

/**
 * Local system notifications (Ping, Find My Phone).
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
   * Sticky find-my-phone banner with explicit「关闭响铃」action.
   * Body tap opens the control page; button stops ringing.
   * Uses a loud slot + optional notification sound as background fallback.
   */
  public async notifyFindMyPhone(peerName: string): Promise<void> {
    let ok = await this.ensureEnabled();
    if (!ok) {
      console.warn('[Notify] notifications disabled; skip find-phone banner');
      return;
    }
    // Prefer service slot (ongoing) so system keeps the banner while continuous task runs
    try {
      await notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION);
    } catch (_s) {
      // already exists
    }
    let name = peerName.length > 0 ? peerName : '电脑';
    let id = AppNotifier.FIND_PHONE_NOTIFY_ID;
    let openAgent = await this.buildOpenAppAgent(id, 'findmyphone');
    let stopAgent = await this.buildOpenAppAgent(id + 1, 'stopfindmyphone');

    let request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: '正在响铃 · 查找设备',
          text: `${name} 在找你 · 后台持续响铃中，点「关闭响铃」停止`
        }
      },
      isOngoing: true,
      isAlertOnce: false,
      tapDismissed: false
    };
    if (openAgent) {
      request.wantAgent = openAgent;
    }
    if (stopAgent) {
      request.actionButtons = [
        {
          title: '关闭响铃',
          wantAgent: stopAgent
        }
      ];
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

  /**
   * Show a file-received notification with type-aware text, tap-to-open, and share button.
   * Matches Android ReceiveNotification.setURI + setFinished pattern.
   */
  public async notifyFileReceived(filename: string, filePath: string): Promise<void> {
    let ok = await this.ensureEnabled();
    if (!ok) {
      console.warn('[Notify] notifications disabled; skip file-received banner');
      return;
    }
    if (!this.context) {
      return;
    }
    let id = this.nextId++;
    if (this.nextId > 9000) {
      this.nextId = 2000;
    }

    // Detect MIME type from extension
    const mime: string = this.getMimeType(filename);
    const fileUri: string = filePath.startsWith('file://') ? filePath : `file://${filePath}`;
    const label: string = this.getFileTypeLabel(filename);

    // Build view WantAgent — same pattern as buildOpenAppAgent (known working)
    let viewAgent: WantAgent | undefined;
    try {
      const viewInfo: wantAgent.WantAgentInfo = {
        wants: [{
          deviceId: '',
          bundleName: this.context.abilityInfo.bundleName,
          moduleName: this.context.abilityInfo.moduleName,
          abilityName: this.context.abilityInfo.name,
          action: 'ohos.want.action.home',
          parameters: { 'openFile': filePath }
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: id,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      viewAgent = await wantAgent.getWantAgent(viewInfo);
    } catch (e) {
      console.warn('[Notify] view agent failed:', JSON.stringify(e));
    }

    let shareAgent: WantAgent | undefined;
    try {
      const shareInfo: wantAgent.WantAgentInfo = {
        wants: [{
          deviceId: '',
          bundleName: this.context.abilityInfo.bundleName,
          moduleName: this.context.abilityInfo.moduleName,
          abilityName: this.context.abilityInfo.name,
          action: 'ohos.want.action.home',
          parameters: { 'shareFile': filePath, 'shareMime': mime }
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: id + 1,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      shareAgent = await wantAgent.getWantAgent(shareInfo);
    } catch (e) {
      console.warn('[Notify] share agent failed:', JSON.stringify(e));
    }

    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: `${label}接收完成`,
          text: `点按打开 "${filename}"`
        }
      },
      tapDismissed: true
    };

    if (viewAgent) {
      request.wantAgent = viewAgent;
      // Action buttons: View + Share (matches Android)
      const buttons: notificationManager.NotificationActionButton[] = [];
      if (viewAgent) {
        buttons.push({
          title: '查看',
          wantAgent: viewAgent
        });
      }
      if (shareAgent) {
        buttons.push({
          title: '分享',
          wantAgent: shareAgent
        });
      }
      if (buttons.length > 0) {
        request.actionButtons = buttons;
      }
    }

    try {
      await notificationManager.publish(request);
      console.info(`[Notify] file-received published: ${filename}`);
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] file-received publish failed: code=${err.code} ${err.message}`);
    }
  }

  /** Map file extension → MIME type. */
  private getMimeType(filename: string): string {
    const ext: string = filename.substring(filename.lastIndexOf('.') + 1).toLowerCase();
    const mimeMap: Record<string, string> = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
      'gif': 'image/gif', 'bmp': 'image/bmp', 'webp': 'image/webp',
      'mp4': 'video/mp4', 'avi': 'video/x-msvideo', 'mov': 'video/quicktime',
      'mkv': 'video/x-matroska', 'mp3': 'audio/mpeg', 'wav': 'audio/wav',
      'aac': 'audio/aac', 'flac': 'audio/flac', 'ogg': 'audio/ogg',
      'pdf': 'application/pdf', 'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt': 'text/plain', 'zip': 'application/zip', 'apk': 'application/vnd.android.package-archive'
    };
    return mimeMap[ext] ?? 'application/octet-stream';
  }

  /** Human-readable file type label. */
  private getFileTypeLabel(filename: string): string {
    const ext: string = filename.substring(filename.lastIndexOf('.') + 1).toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp'].includes(ext)) {
      return '图片';
    }
    if (['mp4', 'avi', 'mov', 'mkv'].includes(ext)) {
      return '视频';
    }
    if (['mp3', 'wav', 'aac', 'flac', 'ogg'].includes(ext)) {
      return '音频';
    }
    if (['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt'].includes(ext)) {
      return '文档';
    }
    return '文件';
  }

  static readonly PERSISTENT_NOTIFY_ID: number = 1;

  /**
   * Persistent / ongoing notification showing connected device names.
   * Mirrors Android BackgroundService.createForegroundNotification().
   */
  public async notifyPersistent(connectedNames: string[]): Promise<void> {
    let ok = await this.ensureEnabled();
    if (!ok || !this.context) {
      return;
    }

    let tapAgent: WantAgent | undefined;
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          deviceId: '',
          bundleName: this.context.abilityInfo.bundleName,
          moduleName: this.context.abilityInfo.moduleName,
          abilityName: this.context.abilityInfo.name,
          action: 'ohos.want.action.home'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: AppNotifier.PERSISTENT_NOTIFY_ID,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      tapAgent = await wantAgent.getWantAgent(info);
    } catch (e) {
      console.warn('[Notify] persistent agent failed:', JSON.stringify(e));
    }

    const text: string = connectedNames.length > 0
      ? `已连接: ${connectedNames.join(', ')}`
      : '没有已连接的设备';

    const request: notificationManager.NotificationRequest = {
      id: AppNotifier.PERSISTENT_NOTIFY_ID,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: 'HMConnect',
          text: text
        }
      },
      tapDismissed: false
    };

    if (tapAgent) {
      request.wantAgent = tapAgent;
    }

    try {
      await notificationManager.publish(request);
      console.info('[Notify] persistent published:', text);
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] persistent publish failed: code=${err.code} ${err.message}`);
    }
  }

  /** Remove the persistent notification. */
  public cancelPersistent(): void {
    try {
      notificationManager.cancel(AppNotifier.PERSISTENT_NOTIFY_ID);
    } catch (_e) {
      // ignore
    }
  }
}
