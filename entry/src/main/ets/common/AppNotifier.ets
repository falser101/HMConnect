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
  /**
   * Fallback notification id for continuous-task progress when system did not
   * return a ContinuousTaskNotification id (enum startBackgroundRunning path).
   */
  public static readonly PERSISTENT_NOTIFY_ID_FOR_PROGRESS: number = 1800;

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
  static readonly PAIR_REQUEST_NOTIFY_ID: number = 100;

  /**
   * Pairing request notification with accept/reject buttons (matches Android).
   */
  public async notifyPairRequest(deviceName: string, deviceId: string): Promise<void> {
    let ok = await this.ensureEnabled();
    if (!ok || !this.context) {
      return;
    }

    // Accept agent
    let acceptAgent: WantAgent | undefined;
    try {
      acceptAgent = await wantAgent.getWantAgent({
        wants: [{
          deviceId: '',
          bundleName: this.context.abilityInfo.bundleName,
          moduleName: this.context.abilityInfo.moduleName,
          abilityName: this.context.abilityInfo.name,
          action: 'ohos.want.action.home',
          parameters: { 'pairAccept': deviceId }
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: AppNotifier.PAIR_REQUEST_NOTIFY_ID,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
    } catch (e) {
      console.warn('[Notify] pair-accept agent failed:', JSON.stringify(e));
    }

    // Reject agent
    let rejectAgent: WantAgent | undefined;
    try {
      rejectAgent = await wantAgent.getWantAgent({
        wants: [{
          deviceId: '',
          bundleName: this.context.abilityInfo.bundleName,
          moduleName: this.context.abilityInfo.moduleName,
          abilityName: this.context.abilityInfo.name,
          action: 'ohos.want.action.home',
          parameters: { 'pairReject': deviceId }
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: AppNotifier.PAIR_REQUEST_NOTIFY_ID + 1,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
    } catch (e) {
      console.warn('[Notify] pair-reject agent failed:', JSON.stringify(e));
    }

    const request: notificationManager.NotificationRequest = {
      id: AppNotifier.PAIR_REQUEST_NOTIFY_ID,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: '配对请求',
          text: `${deviceName} 请求配对`
        }
      },
      tapDismissed: true
    };

    const buttons: notificationManager.NotificationActionButton[] = [];
    if (acceptAgent) {
      buttons.push({
        title: '接受',
        wantAgent: acceptAgent
      } as notificationManager.NotificationActionButton);
    }
    if (rejectAgent) {
      buttons.push({
        title: '拒绝',
        wantAgent: rejectAgent
      } as notificationManager.NotificationActionButton);
    }
    if (buttons.length > 0) {
      request.actionButtons = buttons;
    }

    try {
      await notificationManager.publish(request);
      console.info('[Notify] pair-request published:', deviceName);
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] pair-request publish failed: code=${err.code} ${err.message}`);
    }
  }

  /** Remove pairing notification. */
  public cancelPairRequest(): void {
    try {
      notificationManager.cancel(AppNotifier.PAIR_REQUEST_NOTIFY_ID);
    } catch (_e) {
      // ignore
    }
  }

  /**
   * Persistent connection banner disabled (user request).
   * Kept as no-op so callers do not need to branch.
   */
  public async notifyPersistent(_connectedNames: string[], _connectedIds: string[]): Promise<void> {
    this.cancelPersistent();
  }

  /** Remove the persistent notification. */
  public cancelPersistent(): void {
    try {
      notificationManager.cancel(AppNotifier.PERSISTENT_NOTIFY_ID);
    } catch (_e) {
      // ignore
    }
  }

  /**
   * Mirrored peer notification id range (10000–19999).
   * Android uses tag "kdeconnectId:{id}" + int id; Harmony only has numeric id.
   */
  private static readonly MIRROR_NOTIFY_BASE: number = 10000;
  private static readonly MIRROR_NOTIFY_SPAN: number = 10000;
  /** remote notification id → local notify id (for cancel). */
  private mirroredIds: Map<string, number> = new Map();

  /**
   * Stable local id for a remote kdeconnect.notification id string.
   * Marks as mirrored so a future send-plugin can skip re-export (local-only).
   */
  public static remoteNotificationIdToLocal(remoteId: string): number {
    let h = 0;
    for (let i = 0; i < remoteId.length; i++) {
      h = ((h << 5) - h) + remoteId.charCodeAt(i);
      h = h | 0;
    }
    const abs = h < 0 ? -h : h;
    return AppNotifier.MIRROR_NOTIFY_BASE + (abs % AppNotifier.MIRROR_NOTIFY_SPAN);
  }

  /**
   * Show a notification mirrored from a peer device
   * (Android ReceiveNotificationsPlugin.onPacketReceived).
   * Same remote id replaces the previous banner.
   */
  public async notifyMirroredNotification(
    remoteId: string,
    appName: string,
    ticker: string,
    peerDeviceName?: string
  ): Promise<void> {
    if (!remoteId || remoteId.length === 0) {
      return;
    }
    let ok = await this.ensureEnabled();
    if (!ok) {
      console.warn('[Notify] notifications disabled; skip mirrored notification');
      return;
    }
    const title = appName && appName.length > 0 ? appName : '通知';
    let text = ticker && ticker.length > 0 ? ticker : '';
    if (peerDeviceName && peerDeviceName.length > 0 && text.length > 0) {
      // Keep ticker primary; peer name only if empty body
    } else if (peerDeviceName && peerDeviceName.length > 0 && text.length === 0) {
      text = `来自 ${peerDeviceName}`;
    }
    const id = AppNotifier.remoteNotificationIdToLocal(remoteId);
    this.mirroredIds.set(remoteId, id);
    const agent = await this.buildOpenAppAgent(id, 'mirrored_notification');
    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: text
        }
      },
      tapDismissed: true
    };
    if (agent) {
      request.wantAgent = agent;
    }
    try {
      await notificationManager.publish(request);
      console.info(
        `[Notify] mirrored notification published id=${id} remoteId=${remoteId} app=${title}`
      );
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] mirrored publish failed: code=${err.code} ${err.message}`);
    }
  }

  /** Cancel a mirrored notification by peer remote id (isCancel / dismiss). */
  public async cancelMirroredNotification(remoteId: string): Promise<void> {
    if (!remoteId || remoteId.length === 0) {
      return;
    }
    let id = this.mirroredIds.get(remoteId);
    if (id === undefined) {
      id = AppNotifier.remoteNotificationIdToLocal(remoteId);
    }
    this.mirroredIds.delete(remoteId);
    try {
      await notificationManager.cancel(id);
      console.info(`[Notify] mirrored notification cancelled remoteId=${remoteId} id=${id}`);
    } catch (_e) {
      // already gone
    }
  }

  /** Whether this local notify id is in the mirrored range (for future send-plugin). */
  public static isMirroredLocalNotifyId(localId: number): boolean {
    return localId >= AppNotifier.MIRROR_NOTIFY_BASE &&
      localId < AppNotifier.MIRROR_NOTIFY_BASE + AppNotifier.MIRROR_NOTIFY_SPAN;
  }
}
