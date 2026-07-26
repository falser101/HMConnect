import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { TrustedDevice } from '../service/KdeTypes';

const PREF_NAME = 'hmconnect_devices';
const KEY_TRUSTED = 'trusted_devices';

/**
 * Persist trusted (paired) devices across app restarts.
 */
export class DeviceStore {
  private static instance: DeviceStore | null = null;
  private pref: preferences.Preferences | null = null;
  private cache: Map<string, TrustedDevice> = new Map();
  private ready: boolean = false;

  public static getInstance(): DeviceStore {
    if (!DeviceStore.instance) {
      DeviceStore.instance = new DeviceStore();
    }
    return DeviceStore.instance;
  }

  public async init(context: common.Context): Promise<void> {
    if (this.ready) {
      return;
    }
    try {
      this.pref = await preferences.getPreferences(context, PREF_NAME);
      await this.reload();
      this.ready = true;
    } catch (e) {
      console.error('[KDE-MVP] DeviceStore init failed:', JSON.stringify(e));
    }
  }

  private async reload(): Promise<void> {
    this.cache.clear();
    if (!this.pref) {
      return;
    }
    try {
      let raw = await this.pref.get(KEY_TRUSTED, '[]');
      let json: string = typeof raw === 'string' ? raw : '[]';
      let arr = JSON.parse(json) as TrustedDevice[];
      if (Array.isArray(arr)) {
        for (let i = 0; i < arr.length; i++) {
          let d = arr[i];
          if (d && d.deviceId) {
            this.cache.set(d.deviceId, d);
          }
        }
      }
    } catch (e) {
      console.error('[KDE-MVP] DeviceStore reload failed:', JSON.stringify(e));
    }
  }

  private async persist(): Promise<void> {
    if (!this.pref) {
      return;
    }
    try {
      let list: TrustedDevice[] = this.getAll();
      await this.pref.put(KEY_TRUSTED, JSON.stringify(list));
      await this.pref.flush();
    } catch (e) {
      console.error('[KDE-MVP] DeviceStore persist failed:', JSON.stringify(e));
    }
  }

  public getAll(): TrustedDevice[] {
    let list: TrustedDevice[] = [];
    this.cache.forEach((v: TrustedDevice) => {
      list.push(v);
    });
    return list;
  }

  public get(deviceId: string): TrustedDevice | undefined {
    return this.cache.get(deviceId);
  }

  public isTrusted(deviceId: string): boolean {
    return this.cache.has(deviceId);
  }

  public getTrustedIds(): string[] {
    let ids: string[] = [];
    this.cache.forEach((_v: TrustedDevice, k: string) => {
      ids.push(k);
    });
    return ids;
  }

  public async upsert(device: TrustedDevice): Promise<void> {
    this.cache.set(device.deviceId, device);
    await this.persist();
  }

  public async touchSeen(deviceId: string, ip?: string, tcpPort?: number, name?: string): Promise<void> {
    let existing = this.cache.get(deviceId);
    if (!existing) {
      return;
    }
    existing.lastSeenAt = Date.now();
    if (ip) {
      existing.lastIp = ip;
    }
    if (tcpPort !== undefined) {
      existing.lastTcpPort = tcpPort;
    }
    if (name && name.length > 0) {
      existing.deviceName = name;
    }
    this.cache.set(deviceId, existing);
    await this.persist();
  }

  public async remove(deviceId: string): Promise<void> {
    this.cache.delete(deviceId);
    await this.persist();
  }

  public async clear(): Promise<void> {
    this.cache.clear();
    await this.persist();
  }
}
