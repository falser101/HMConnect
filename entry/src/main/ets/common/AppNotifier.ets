import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  FileTransferNotifyInfo,
  FileTransferResultInfo
} from '../service/KdeTypes';

/**
 * Local system notifications (Ping, Find My Phone, file received).
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
  /**
   * Stable id range for file-transfer notifications (Android Upload/ReceiveNotification).
   * Each jobId maps to one id so progress updates replace the same banner and the
   * cancel action can remove it.
   */
  private static readonly TRANSFER_NOTIFY_BASE: number = 6000;
  private static readonly TRANSFER_NOTIFY_SPAN: number = 900;

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
   * Image files use NOTIFICATION_CONTENT_PICTURE so the tray can expand to a big preview.
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
    const label: string = this.getFileTypeLabel(filename);
    const isImage: boolean = this.isImageMime(mime);

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

    // Prefer picture-style notification for images (expand → big preview).
    // SDK: picture PixelMap total bytes ≤ 2MB (≈700×700 RGBA) — use ~600px so the
    // expanded preview is a real large image, not a thumbnail.
    let pictureMap: image.PixelMap | null = null;
    let largeIconMap: image.PixelMap | null = null;
    if (isImage) {
      pictureMap = await this.decodeImageForNotification(filePath, AppNotifier.NOTIFY_PICTURE_MAX_EDGE);
      if (pictureMap) {
        // Smaller square for collapsed-tray largeIcon (right-side thumbnail).
        // largeIcon limit is 192KB (recommended 128×128).
        largeIconMap = await this.decodeImageForNotification(filePath, AppNotifier.NOTIFY_LARGE_ICON_EDGE);
      } else {
        console.warn(`[Notify] image decode failed, falling back to text: ${filename}`);
      }
    }

    let content: notificationManager.NotificationContent;
    if (pictureMap !== null) {
      content = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_PICTURE,
        picture: {
          title: `${label}接收完成`,
          text: filename,
          additionalText: '下拉通知可展开查看大图',
          picture: pictureMap,
          briefText: filename,
          expandedTitle: `${label}接收完成 · 查看大图`
        }
      };
    } else {
      content = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: `${label}接收完成`,
          text: `点按打开 "${filename}"`
        }
      };
    }

    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: content,
      tapDismissed: true
    };

    if (largeIconMap !== null) {
      request.largeIcon = largeIconMap;
    }

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
      console.info(
        `[Notify] file-received published: ${filename} picture=${pictureMap !== null}`
      );
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] file-received publish failed: code=${err.code} ${err.message}`);
      // If picture style is rejected by the system, retry as plain text once.
      if (pictureMap) {
        try {
          const fallback: notificationManager.NotificationRequest = {
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
            fallback.wantAgent = viewAgent;
          }
          await notificationManager.publish(fallback);
          console.info(`[Notify] file-received text fallback published: ${filename}`);
        } catch (e2) {
          let err2 = e2 as BusinessError;
          console.error(`[Notify] file-received fallback failed: code=${err2.code} ${err2.message}`);
        }
      }
    }
  }

  /**
   * Expanded-preview image edge. SDK caps picture pixel bytes at 2MB —
   * 600×600 RGBA ≈ 1.37MB, well under limit and visibly larger than the thumbnail.
   */
  private static readonly NOTIFY_PICTURE_MAX_EDGE: number = 600;
  /** Collapsed-tray largeIcon recommendation (192KB limit, 128×128). */
  private static readonly NOTIFY_LARGE_ICON_EDGE: number = 128;

  private isImageMime(mime: string): boolean {
    return mime.startsWith('image/');
  }

  /**
   * Decode a local image file into a downscaled PixelMap for notification use.
   * Returns null on failure so caller can fall back to text notification.
   */
  private async decodeImageForNotification(
    filePath: string,
    maxEdge: number
  ): Promise<image.PixelMap | null> {
    let path: string = filePath;
    if (path.startsWith('file://')) {
      path = path.substring(7);
    }
    if (path.length === 0) {
      return null;
    }

    try {
      const src: image.ImageSource = image.createImageSource(path);
      try {
        return await this.createScaledPixelMap(src, maxEdge);
      } finally {
        try {
          src.release();
        } catch (_r) {
        }
      }
    } catch (_e) {
      // Fallback via fd (some sandbox paths need openSync)
      try {
        const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
        try {
          const src2: image.ImageSource = image.createImageSource(file.fd);
          try {
            return await this.createScaledPixelMap(src2, maxEdge);
          } finally {
            try {
              src2.release();
            } catch (_r2) {
            }
          }
        } finally {
          try {
            fileIo.closeSync(file);
          } catch (_c) {
          }
        }
      } catch (e2) {
        console.warn('[Notify] decodeImageForNotification failed:', JSON.stringify(e2));
        return null;
      }
    }
  }

  /**
   * Scale so the longer edge ≤ maxEdge (keeps aspect ratio).
   * picture limit is 2MB; 600px RGBA ≈ 1.37MB. largeIcon stays at 128px.
   */
  private async createScaledPixelMap(
    src: image.ImageSource,
    maxEdge: number
  ): Promise<image.PixelMap | null> {
    let targetW: number = maxEdge;
    let targetH: number = maxEdge;
    try {
      const info = await src.getImageInfo();
      const w: number = info.size.width;
      const h: number = info.size.height;
      if (w > 0 && h > 0) {
        if (w >= h) {
          targetW = Math.min(w, maxEdge);
          targetH = Math.max(1, Math.round(h * (targetW / w)));
        } else {
          targetH = Math.min(h, maxEdge);
          targetW = Math.max(1, Math.round(w * (targetH / h)));
        }
      }
    } catch (_infoErr) {
      // keep defaults
    }

    const opts: image.DecodingOptions = {
      desiredSize: {
        width: targetW,
        height: targetH
      },
      editable: false
    };
    try {
      return await src.createPixelMap(opts);
    } catch (e) {
      console.warn('[Notify] createPixelMap failed:', JSON.stringify(e));
      try {
        // Last resort: full decode (may fail publish if too large)
        return await src.createPixelMap();
      } catch (_e2) {
        return null;
      }
    }
  }

  /** Map file extension → MIME type. */
  private getMimeType(filename: string): string {
    const ext: string = filename.substring(filename.lastIndexOf('.') + 1).toLowerCase();
    const mimeMap: Record<string, string> = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
      'gif': 'image/gif', 'bmp': 'image/bmp', 'webp': 'image/webp',
      'heic': 'image/heic', 'heif': 'image/heif',
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
    if (['jpg', 'jpeg', 'png', 'gif', 'bmp', 'webp', 'heic', 'heif'].includes(ext)) {
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
   * Remote-input received from a desktop (desktop clicked our screen).
   * Protocol-level receiver: no touch injection on HarmonyOS, so we surface the
   * event as a throttled banner so the user knows the PC is controlling the phone.
   * At most one banner every 5 s; tap opens the app.
   */
  private static readonly REMOTE_INPUT_NOTIFY_ID: number = 1950;
  private lastRemoteInputNotifyAt: number = 0;

  public async notifyRemoteInput(peerName: string, button: string): Promise<void> {
    const now = Date.now();
    if (now - this.lastRemoteInputNotifyAt < 5000) {
      return;
    }
    this.lastRemoteInputNotifyAt = now;
    let ok = await this.ensureEnabled();
    if (!ok) {
      return;
    }
    let name = peerName.length > 0 ? peerName : '电脑';
    const label: string = button === 'right' ? '右键' :
      (button === 'middle' ? '中键' : (button === 'double' ? '双击' : '左键'));
    const id = AppNotifier.REMOTE_INPUT_NOTIFY_ID;
    let agent = await this.buildOpenAppAgent(id, 'remote_input');
    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: `${name} 正在控制这台设备`,
          text: `远程输入 · ${label}点击`
        }
      },
      tapDismissed: true
    };
    if (agent) {
      request.wantAgent = agent;
    }
    try {
      await notificationManager.publish(request);
      console.info(`[Notify] remote-input published from ${name} ${label}`);
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] remote-input publish failed: code=${err.code} ${err.message}`);
    }
  }

  public cancelRemoteInputNotification(): void {
    try {
      notificationManager.cancel(AppNotifier.REMOTE_INPUT_NOTIFY_ID);
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

  /**
   * Stable local notification id for a file-transfer jobId.
   * Reused across progress updates so the banner updates in place (Android: one
   * notification per job). Range: [6000, 6900).
   */
  public static transferNotifyId(jobId: string): number {
    let h = 0;
    for (let i = 0; i < jobId.length; i++) {
      h = ((h << 5) - h) + jobId.charCodeAt(i);
      h = h | 0;
    }
    const abs = h < 0 ? -h : h;
    return AppNotifier.TRANSFER_NOTIFY_BASE + (abs % AppNotifier.TRANSFER_NOTIFY_SPAN);
  }

  /** Remove the ongoing transfer notification for a jobId. */
  public cancelTransferNotification(jobId: string): void {
    try {
      notificationManager.cancel(AppNotifier.transferNotifyId(jobId));
    } catch (_e) {
      // ignore if already gone
    }
  }

  /**
   * Received-text banner (Android SharePlugin.receiveText → Toast).
   * Text was already saved to the clipboard; the banner confirms it.
   */
  public async notifyTextReceived(text: string, peerName: string): Promise<void> {
    let ok = await this.ensureEnabled();
    if (!ok) {
      console.warn('[Notify] notifications disabled; skip text-received banner');
      return;
    }
    let id = this.nextId++;
    if (this.nextId > 9000) {
      this.nextId = 2000;
    }
    let agent: WantAgent | undefined = await this.buildOpenAppAgent(id, 'received_text');
    let snippet: string = text.trim();
    if (snippet.length > 60) {
      snippet = snippet.substring(0, 60) + '…';
    }
    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SOCIAL_COMMUNICATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: `${peerName} 发来文本`,
          text: `已保存到剪贴板: ${snippet}`
        }
      },
      tapDismissed: true
    };
    if (agent) {
      request.wantAgent = agent;
    }
    try {
      await notificationManager.publish(request);
      console.info(`[Notify] text-received published from ${peerName}`);
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] text-received publish failed: code=${err.code} ${err.message}`);
    }
  }

  /**
   * Ongoing file-transfer banner (Android Upload/ReceiveNotification).
   * Uses the system downloadTemplate so the tray shows a real progress bar;
   * falls back to plain text when the template is unavailable.
   * Cancel action routes to EntryAbility → KdeService.cancelFileTransfer.
   */
  public async notifyTransferProgress(info: FileTransferNotifyInfo): Promise<void> {
    let ok = await this.ensureEnabled();
    if (!ok) {
      console.warn('[Notify] notifications disabled; skip transfer progress banner');
      return;
    }
    if (!this.context) {
      return;
    }
    const id: number = AppNotifier.transferNotifyId(info.jobId);
    const dirLabel: string = info.role === 'send' ? '发送' : '接收';
    const title: string = info.totalFiles > 1
      ? `${dirLabel} ${info.fileIndex} / ${info.totalFiles} 个文件到 ${info.deviceName}`
      : `${dirLabel}文件到 ${info.deviceName}`;
    const bodyText: string = `${info.fileName} · ${info.percent}%`;

    let openAgent: WantAgent | undefined = await this.buildOpenAppAgent(id, 'file_transfer');

    // Cancel action (Android ShareBroadcastReceiver ACTION_CANCEL_SHARE)
    let cancelAgent: WantAgent | undefined;
    try {
      cancelAgent = await wantAgent.getWantAgent({
        wants: [{
          deviceId: '',
          bundleName: this.context.abilityInfo.bundleName,
          moduleName: this.context.abilityInfo.moduleName,
          abilityName: this.context.abilityInfo.name,
          action: 'ohos.want.action.home',
          parameters: {
            'cancelTransfer': info.jobId,
            'cancelTransferRole': info.role,
            'cancelTransferDevice': info.deviceId
          }
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: id + 1,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
    } catch (e) {
      console.warn('[Notify] transfer-cancel agent failed:', JSON.stringify(e));
    }

    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: bodyText
        }
      },
      isOngoing: true,
      isAlertOnce: false,
      tapDismissed: false
    };

    // Progress bar via the system download template (progressValue 0–100).
    const clampPct: number = Math.max(0, Math.min(100, info.percent));
    try {
      request.template = {
        name: 'downloadTemplate',
        data: {
          'title': title,
          'fileName': info.fileName,
          'progressValue': clampPct
        }
      };
    } catch (_te) {
      // template ignored — plain text still shows progress text
    }

    if (openAgent) {
      request.wantAgent = openAgent;
    }
    if (cancelAgent) {
      request.actionButtons = [{
        title: '取消',
        wantAgent: cancelAgent
      } as notificationManager.NotificationActionButton];
    }

    try {
      await notificationManager.publish(request);
      console.info(`[Notify] transfer progress ${info.role} ${info.jobId} ${info.percent}%`);
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] transfer progress publish failed: code=${err.code} ${err.message}`);
    }
  }

  /**
   * Transfer finished banner (Android UploadNotification.setFinished /
   * ReceiveNotification.setFinished + setURI).
   * Single received file with a known path reuses the rich open/share banner
   * (image preview included); everything else gets a plain summary banner.
   */
  public async notifyTransferFinished(info: FileTransferResultInfo): Promise<void> {
    // Replace the ongoing banner first (Android: same notification id).
    this.cancelTransferNotification(info.jobId);
    if (info.role === 'receive' && info.fileName && info.filePath && info.filePath.length > 0 &&
      info.numFiles <= 1) {
      await this.notifyFileReceived(info.fileName, info.filePath);
      return;
    }
    let ok = await this.ensureEnabled();
    if (!ok) {
      console.warn('[Notify] notifications disabled; skip transfer finished banner');
      return;
    }
    let id: number = AppNotifier.transferNotifyId(info.jobId);
    const title: string = info.role === 'send'
      ? `已发送 ${info.numFiles} 个文件到 ${info.deviceName}`
      : `已从 ${info.deviceName} 接收 ${info.numFiles} 个文件`;
    let agent: WantAgent | undefined = await this.buildOpenAppAgent(id, 'file_transfer');
    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: info.role === 'send' ? '发送完成' : '接收完成'
        }
      },
      tapDismissed: true
    };
    if (agent) {
      request.wantAgent = agent;
    }
    try {
      await notificationManager.publish(request);
      console.info(`[Notify] transfer finished ${info.role} ${info.jobId} n=${info.numFiles}`);
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] transfer finished publish failed: code=${err.code} ${err.message}`);
    }
  }

  /** Transfer failed banner (Android UploadNotification.setFailed / ReceiveNotification.setFailed). */
  public async notifyTransferFailed(info: FileTransferResultInfo): Promise<void> {
    this.cancelTransferNotification(info.jobId);
    let ok = await this.ensureEnabled();
    if (!ok) {
      console.warn('[Notify] notifications disabled; skip transfer failed banner');
      return;
    }
    let id: number = AppNotifier.transferNotifyId(info.jobId);
    const failed: number = Math.max(1, info.totalFiles - info.numFiles);
    const title: string = info.role === 'send'
      ? `发送失败 · ${failed}/${info.totalFiles} 个文件未发送到 ${info.deviceName}`
      : `接收失败 · 未从 ${info.deviceName} 收到 ${failed}/${info.totalFiles} 个文件`;
    let agent: WantAgent | undefined = await this.buildOpenAppAgent(id, 'file_transfer');
    const request: notificationManager.NotificationRequest = {
      id: id,
      notificationSlotType: notificationManager.SlotType.OTHER_TYPES,
      content: {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal: {
          title: title,
          text: '传输失败'
        }
      },
      tapDismissed: true
    };
    if (agent) {
      request.wantAgent = agent;
    }
    try {
      await notificationManager.publish(request);
      console.info(`[Notify] transfer failed ${info.role} ${info.jobId}`);
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[Notify] transfer failed publish failed: code=${err.code} ${err.message}`);
    }
  }
}
