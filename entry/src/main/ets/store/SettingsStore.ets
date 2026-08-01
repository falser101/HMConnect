import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME = 'hmconnect_settings';
const KEY_DEVICE_NAME = 'deviceName';
const KEY_THEME = 'theme';
const KEY_PERSISTENT_NOTIFICATION = 'persistentNotification';
const KEY_TRUSTED_NETWORKS = 'trustedNetworks';

/**
 * Global app settings — mirrors the Android SettingsFragment preferences:
 * device name, theme, persistent notification, trusted networks.
 * Persisted via @ohos.data.preferences.
 */
export class SettingsStore {
  private static instance: SettingsStore | null = null;
  private pref: preferences.Preferences | null = null;
  private ready: boolean = false;
  private deviceName: string = '';
  private theme: string = 'system';
  private persistentNotification: boolean = true;
  private trustedNetworks: string[] = [];
  private listeners: Map<number, () => void> = new Map();
  private nextListenerId: number = 1;

  public static getInstance(): SettingsStore {
    if (!SettingsStore.instance) {
      SettingsStore.instance = new SettingsStore();
    }
    return SettingsStore.instance;
  }

  public async init(context: common.Context): Promise<void> {
    if (this.ready) {
      return;
    }
    try {
      this.pref = await preferences.getPreferences(context, PREF_NAME);
      this.deviceName = await this.readString(KEY_DEVICE_NAME);
      this.theme = await this.readString(KEY_THEME);
      this.persistentNotification = await this.readBool(KEY_PERSISTENT_NOTIFICATION, true);
      this.trustedNetworks = await this.readStringArray(KEY_TRUSTED_NETWORKS);
      this.ready = true;
    } catch (e) {
      console.error('[SettingsStore] init failed:', JSON.stringify(e));
    }
  }

  private async readString(key: string): Promise<string> {
    if (!this.pref) {
      return '';
    }
    try {
      const raw = await this.pref.get(key, '');
      return typeof raw === 'string' ? raw : '';
    } catch (_e) {
      return '';
    }
  }

  private async readBool(key: string, def: boolean): Promise<boolean> {
    if (!this.pref) {
      return def;
    }
    try {
      const raw = await this.pref.get(key, def);
      return raw === true || raw === 'true';
    } catch (_e) {
      return def;
    }
  }

  private async readStringArray(key: string): Promise<string[]> {
    if (!this.pref) {
      return [];
    }
    try {
      const raw = await this.pref.get(key, '[]');
      const json: string = typeof raw === 'string' ? raw : '[]';
      const arr = JSON.parse(json) as string[];
      return Array.isArray(arr) ? arr : [];
    } catch (_e) {
      return [];
    }
  }

  private async writeString(key: string, value: string): Promise<void> {
    if (!this.pref) {
      return;
    }
    try {
      await this.pref.put(key, value);
      await this.pref.flush();
    } catch (e) {
      console.error('[SettingsStore] write failed:', JSON.stringify(e));
    }
  }

  public async setDeviceName(name: string): Promise<void> {
    this.deviceName = name;
    await this.writeString(KEY_DEVICE_NAME, name);
    this.notifyListeners();
  }

  public getDeviceName(): string {
    return this.deviceName;
  }

  public async setTheme(theme: string): Promise<void> {
    this.theme = theme;
    await this.writeString(KEY_THEME, theme);
    this.notifyListeners();
  }

  public getTheme(): string {
    return this.theme;
  }

  public async setPersistentNotification(enabled: boolean): Promise<void> {
    this.persistentNotification = enabled;
    if (this.pref) {
      try {
        await this.pref.put(KEY_PERSISTENT_NOTIFICATION, enabled);
        await this.pref.flush();
      } catch (e) {
        console.error('[SettingsStore] persist-notification write failed:', JSON.stringify(e));
      }
    }
    this.notifyListeners();
  }

  public isPersistentNotification(): boolean {
    return this.persistentNotification;
  }

  public getTrustedNetworks(): string[] {
    return this.trustedNetworks.slice();
  }

  public isTrustedNetwork(ssid: string): boolean {
    if (!ssid || ssid.length === 0) {
      return false;
    }
    for (let i = 0; i < this.trustedNetworks.length; i++) {
      if (this.trustedNetworks[i] === ssid) {
        return true;
      }
    }
    return false;
  }

  public async addTrustedNetwork(ssid: string): Promise<void> {
    const clean: string = ssid.trim();
    if (clean.length === 0 || this.isTrustedNetwork(clean)) {
      return;
    }
    this.trustedNetworks.push(clean);
    await this.writeString(KEY_TRUSTED_NETWORKS, JSON.stringify(this.trustedNetworks));
    this.notifyListeners();
  }

  public async removeTrustedNetwork(ssid: string): Promise<void> {
    const next: string[] = [];
    for (let i = 0; i < this.trustedNetworks.length; i++) {
      if (this.trustedNetworks[i] !== ssid) {
        next.push(this.trustedNetworks[i]);
      }
    }
    this.trustedNetworks = next;
    await this.writeString(KEY_TRUSTED_NETWORKS, JSON.stringify(this.trustedNetworks));
    this.notifyListeners();
  }

  public subscribe(cb: () => void): number {
    const id = this.nextListenerId++;
    this.listeners.set(id, cb);
    return id;
  }

  public unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  private notifyListeners(): void {
    this.listeners.forEach((cb: () => void) => {
      try {
        cb();
      } catch (e) {
        console.error('[SettingsStore] listener error:', JSON.stringify(e));
      }
    });
  }
}
