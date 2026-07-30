import { common } from '@kit.AbilityKit';
import { UIContext, router } from '@kit.ArkUI';
import { KdeService } from '../service/KdeService';
import { DeviceListItem, KdeStatus } from '../service/KdeTypes';
import { FindMyPhoneHelper } from '../common/FindMyPhoneHelper';
import { RemoteMprisMediaSession } from '../service/RemoteMprisMediaSession';

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
    // Early AVSession for lock-screen / 播控中心 (pure remote; no local audio)
    const media = RemoteMprisMediaSession.getInstance();
    media.setContext(context);
    media.initSession().catch((e: Error) => {
      console.warn('[AppSession] RemoteMpris initSession:', e.message);
    });
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
   * Open device detail and show PasteButton overlay (temporary clipboard access).
   * Ordinary apps cannot install with ohos.permission.READ_PASTEBOARD (code 9568289);
   * system PasteButton is the supported path.
   */
  public openClipboardSendFor(deviceId: string): void {
    if (!this.uiContext) {
      console.warn('[AppSession] openClipboardSendFor: no uiContext');
      return;
    }
    try {
      this.uiContext.getRouter().pushUrl({
        url: 'pages/DeviceDetail',
        params: { deviceId: deviceId, action: 'sendClipboard' }
      }).catch((e: Error) => {
        console.error('[AppSession] openClipboardSendFor pushUrl failed:', e.message);
      });
    } catch (e) {
      console.error('[AppSession] openClipboardSendFor exception:', JSON.stringify(e));
    }
  }

  /** Accept incoming pair request (from notification). Optional deviceId when known. */
  public acceptPairing(deviceId?: string): void {
    if (deviceId && deviceId.length > 0) {
      this.service.getClient().acceptPairingFor(deviceId);
    } else {
      this.service.getClient().acceptPairing();
    }
  }

  /** Reject incoming pair request (from notification). */
  public rejectPairing(deviceId?: string): void {
    if (deviceId && deviceId.length > 0) {
      this.service.getClient().rejectPairingFor(deviceId);
    } else {
      this.service.getClient().rejectPairing();
    }
  }

  /** Navigate to device detail and trigger file picker. */
  public openFileSendFor(deviceId: string): void {
    if (!this.uiContext) {
      return;
    }
    try {
      this.uiContext.getRouter().pushUrl({
        url: 'pages/DeviceDetail',
        params: { deviceId: deviceId, action: 'sendFile' }
      }).catch((e: Error) => {
        console.error('[AppSession] openFileSendFor pushUrl failed:', e.message);
      });
    } catch (e) {
      console.error('[AppSession] openFileSendFor exception:', JSON.stringify(e));
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
