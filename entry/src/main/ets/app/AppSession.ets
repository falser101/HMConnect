import { common } from '@kit.AbilityKit';
import { UIContext, router } from '@kit.ArkUI';
import pasteboard from '@ohos.pasteboard';
import { KdeService } from '../service/KdeService';
import { DeviceListItem, KdeStatus } from '../service/KdeTypes';
import { FindMyPhoneHelper } from '../common/FindMyPhoneHelper';

/**
 * Process-wide session: protocol stack lives here, not in pages.
 */
export class AppSession {
  private static instance: AppSession | null = null;

  private service: KdeService = new KdeService();
  private started: boolean = false;
  private context: common.UIAbilityContext | null = null;
  /** Latest UIContext from a visible page — used to open FindMyPhone. */
  private uiContext: UIContext | null = null;
  private findPhonePageOpen: boolean = false;
  private findPhoneNavSubId: number = -1;

  private deviceListeners: Map<number, (items: DeviceListItem[]) => void> = new Map();
  private statusListeners: Map<number, (status: KdeStatus) => void> = new Map();
  private nextListenerId: number = 1;

  private lastDevices: DeviceListItem[] = [];
  private lastStatus: KdeStatus = { state: 'idle', message: '未启动' };

  private constructor() {
  }

  public static getInstance(): AppSession {
    if (!AppSession.instance) {
      AppSession.instance = new AppSession();
    }
    return AppSession.instance;
  }

  public getService(): KdeService {
    return this.service;
  }

  public async ensureStarted(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    FindMyPhoneHelper.getInstance().setContext(context);
    if (this.started) {
      return;
    }
    await this.service.start(context, (items: DeviceListItem[]) => {
      this.lastDevices = items;
      this.deviceListeners.forEach((cb) => {
        cb(items);
      });
    }, (status: KdeStatus) => {
      this.lastStatus = status;
      this.statusListeners.forEach((cb) => {
        cb(status);
      });
    });
    this.started = true;
    this.wireFindPhoneNavigation();
  }

  /** Call from page aboutToAppear / onPageShow so we can open full-screen find UI. */
  public attachUiContext(ui: UIContext): void {
    this.uiContext = ui;
    // If already ringing when page becomes visible, open the control screen
    if (FindMyPhoneHelper.getInstance().isActive()) {
      this.openFindPhonePage();
    }
  }

  public markFindPhonePageOpen(open: boolean): void {
    this.findPhonePageOpen = open;
  }

  private wireFindPhoneNavigation(): void {
    if (this.findPhoneNavSubId >= 0) {
      return;
    }
    this.findPhoneNavSubId = FindMyPhoneHelper.getInstance().subscribe((active: boolean, _name: string) => {
      if (active) {
        this.openFindPhonePage();
      } else {
        this.findPhonePageOpen = false;
      }
    });
  }

  public openFindPhonePage(): void {
    if (this.findPhonePageOpen) {
      return;
    }
    if (!this.uiContext) {
      console.warn('[AppSession] no UIContext yet; find-phone page deferred');
      return;
    }
    try {
      let options: router.RouterOptions = {
        url: 'pages/FindMyPhone',
        params: {}
      };
      this.findPhonePageOpen = true;
      this.uiContext.getRouter().pushUrl(options).catch((e: Error) => {
        this.findPhonePageOpen = false;
        console.error('[AppSession] open FindMyPhone failed:', e.message);
      });
    } catch (e) {
      this.findPhonePageOpen = false;
      console.error('[AppSession] open FindMyPhone exception:', JSON.stringify(e));
    }
  }

  /**
   * Directly read clipboard and send to target device.
   * Mirrors Android ClipboardFloatingActivity (invisible, no UI, send-and-done).
   */
  public openClipboardSendFor(deviceId: string): void {
    try {
      const sysPasteboard = pasteboard.getSystemPasteboard();
      sysPasteboard.getData((err: Error, data: pasteboard.PasteData) => {
        if (err) {
          console.error('[AppSession] clipboard read error:', err.message);
          return;
        }
        if (!data) {
          console.warn('[AppSession] clipboard empty');
          return;
        }
        const text = data.getPrimaryText();
        if (!text || text.trim().length === 0) {
          console.warn('[AppSession] clipboard has no text');
          return;
        }
        this.service.sendClipboardText(text.trim());
        console.info('[AppSession] clipboard sent to', deviceId);
      });
    } catch (e) {
      console.error('[AppSession] openClipboardSendFor failed:', JSON.stringify(e));
    }
  }

  /** Accept incoming pair request (from notification). */
  public acceptPairing(): void {
    this.service.getClient().acceptPairing();
  }

  /** Reject incoming pair request (from notification). */
  public rejectPairing(): void {
    this.service.getClient().rejectPairing();
  }

  /** Navigate to device detail and trigger file picker. */
  public openFileSendFor(deviceId: string): void {
    if (this.uiContext) {
      this.uiContext.getRouter().pushUrl({
        url: 'pages/DeviceDetail',
        params: { deviceId: deviceId, action: 'sendFile' }
      });
    }
  }

  public subscribeDevices(cb: (items: DeviceListItem[]) => void): number {
    let id = this.nextListenerId++;
    this.deviceListeners.set(id, cb);
    cb(this.lastDevices);
    return id;
  }

  public unsubscribeDevices(id: number): void {
    this.deviceListeners.delete(id);
  }

  public subscribeStatus(cb: (status: KdeStatus) => void): number {
    let id = this.nextListenerId++;
    this.statusListeners.set(id, cb);
    cb(this.lastStatus);
    return id;
  }

  public unsubscribeStatus(id: number): void {
    this.statusListeners.delete(id);
  }

  public getLastDevices(): DeviceListItem[] {
    return this.lastDevices;
  }

  public getLastStatus(): KdeStatus {
    return this.lastStatus;
  }

  /** Only call from Ability onDestroy. */
  public shutdown(): void {
    if (this.findPhoneNavSubId >= 0) {
      FindMyPhoneHelper.getInstance().unsubscribe(this.findPhoneNavSubId);
      this.findPhoneNavSubId = -1;
    }
    FindMyPhoneHelper.getInstance().stop();
    this.service.stop();
    this.started = false;
    this.deviceListeners.clear();
    this.statusListeners.clear();
  }
}
