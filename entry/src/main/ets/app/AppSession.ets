import { common } from '@kit.AbilityKit';
import { KdeService } from '../service/KdeService';
import { DeviceListItem, KdeStatus } from '../service/KdeTypes';

/**
 * Process-wide session: protocol stack lives here, not in pages.
 */
export class AppSession {
  private static instance: AppSession | null = null;

  private service: KdeService = new KdeService();
  private started: boolean = false;
  private context: common.UIAbilityContext | null = null;

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
    this.service.stop();
    this.started = false;
    this.deviceListeners.clear();
    this.statusListeners.clear();
  }
}
