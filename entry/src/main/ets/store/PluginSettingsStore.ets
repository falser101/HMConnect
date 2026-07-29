import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { getPluginMeta, IMPLEMENTED_PLUGINS } from '../service/PluginRegistry';

const PREF_NAME = 'hmconnect_plugin_settings';
const KEY_PREFIX = 'enabled_'; // enabled_{deviceId}_{pluginKey}

/**
 * Per-device plugin enable/disable preferences.
 * Aligns with Android TrustedDevices.getDeviceSettings(deviceId).getBoolean(pluginKey).
 */
export class PluginSettingsStore {
  private static instance: PluginSettingsStore | null = null;
  private pref: preferences.Preferences | null = null;
  private ready: boolean = false;
  /** Memory cache: `${deviceId}\0${pluginKey}` → boolean */
  private cache: Map<string, boolean> = new Map();
  private loadedDevices: Set<string> = new Set();
  private listeners: Map<number, () => void> = new Map();
  private nextListenerId: number = 1;

  public static getInstance(): PluginSettingsStore {
    if (!PluginSettingsStore.instance) {
      PluginSettingsStore.instance = new PluginSettingsStore();
    }
    return PluginSettingsStore.instance;
  }

  public async init(context: common.Context): Promise<void> {
    if (this.ready) {
      return;
    }
    try {
      this.pref = await preferences.getPreferences(context, PREF_NAME);
      this.ready = true;
    } catch (e) {
      console.error('[PluginSettings] init failed:', JSON.stringify(e));
    }
  }

  private cacheKey(deviceId: string, pluginKey: string): string {
    return `${deviceId}\0${pluginKey}`;
  }

  private prefKey(deviceId: string, pluginKey: string): string {
    return `${KEY_PREFIX}${deviceId}_${pluginKey}`;
  }

  private defaultEnabled(pluginKey: string): boolean {
    const meta = getPluginMeta(pluginKey);
    return meta ? meta.enabledByDefault : true;
  }

  /** Load all plugin flags for a device into memory (call when opening settings / session). */
  public async ensureDeviceLoaded(deviceId: string): Promise<void> {
    if (!deviceId || deviceId.length === 0 || !this.pref || this.loadedDevices.has(deviceId)) {
      return;
    }
    for (let i = 0; i < IMPLEMENTED_PLUGINS.length; i++) {
      const key = IMPLEMENTED_PLUGINS[i].key;
      const def = this.defaultEnabled(key);
      try {
        const raw = await this.pref.get(this.prefKey(deviceId, key), def);
        const enabled = raw === true || raw === 'true';
        this.cache.set(this.cacheKey(deviceId, key), enabled);
      } catch (_e) {
        this.cache.set(this.cacheKey(deviceId, key), def);
      }
    }
    this.loadedDevices.add(deviceId);
  }

  /** Whether the plugin is enabled for this device (default from registry). */
  public isEnabled(deviceId: string, pluginKey: string): boolean {
    if (!deviceId || deviceId.length === 0) {
      return this.defaultEnabled(pluginKey);
    }
    const ck = this.cacheKey(deviceId, pluginKey);
    if (this.cache.has(ck)) {
      return this.cache.get(ck) as boolean;
    }
    // Not loaded yet — return default; caller should ensureDeviceLoaded soon
    return this.defaultEnabled(pluginKey);
  }

  public async setEnabled(deviceId: string, pluginKey: string, enabled: boolean): Promise<void> {
    if (!deviceId || deviceId.length === 0) {
      return;
    }
    const ck = this.cacheKey(deviceId, pluginKey);
    this.cache.set(ck, enabled);
    this.loadedDevices.add(deviceId);
    if (this.pref) {
      try {
        await this.pref.put(this.prefKey(deviceId, pluginKey), enabled);
        await this.pref.flush();
      } catch (e) {
        console.error('[PluginSettings] setEnabled failed:', JSON.stringify(e));
      }
    }
    this.notifyListeners();
  }

  /** Clear all plugin prefs for one device (on unpair). */
  public async clearDevice(deviceId: string): Promise<void> {
    if (!deviceId || deviceId.length === 0) {
      return;
    }
    for (let i = 0; i < IMPLEMENTED_PLUGINS.length; i++) {
      const key = IMPLEMENTED_PLUGINS[i].key;
      this.cache.delete(this.cacheKey(deviceId, key));
      if (this.pref) {
        try {
          await this.pref.delete(this.prefKey(deviceId, key));
        } catch (_e) {
        }
      }
    }
    this.loadedDevices.delete(deviceId);
    if (this.pref) {
      try {
        await this.pref.flush();
      } catch (_e) {
      }
    }
    this.notifyListeners();
  }

  /** Clear every device (settings "clear all pairs"). */
  public async clearAll(): Promise<void> {
    this.cache.clear();
    this.loadedDevices.clear();
    if (this.pref) {
      try {
        await this.pref.clear();
        await this.pref.flush();
      } catch (e) {
        console.error('[PluginSettings] clearAll failed:', JSON.stringify(e));
      }
    }
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
        console.error('[PluginSettings] listener error:', JSON.stringify(e));
      }
    });
  }
}
