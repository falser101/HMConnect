import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME = 'hmconnect_plugin_prefs';

/**
 * Per-device plugin sub-settings (Android PluginSettingsFragment preference
 * screens). Keys mirror the android preference keys; values are namespaced by
 * deviceId so each paired device keeps its own plugin settings.
 */
export class PluginPrefsStore {
  private static instance: PluginPrefsStore | null = null;
  private pref: preferences.Preferences | null = null;
  private ready: boolean = false;
  private subscribers: Map<number, () => void> = new Map();
  private nextSubId: number = 0;

  public static getInstance(): PluginPrefsStore {
    if (!PluginPrefsStore.instance) {
      PluginPrefsStore.instance = new PluginPrefsStore();
    }
    return PluginPrefsStore.instance;
  }

  public async ensureInit(context: common.Context): Promise<void> {
    if (this.ready) {
      return;
    }
    try {
      this.pref = await preferences.getPreferences(context, PREF_NAME);
      this.ready = true;
    } catch (e) {
      console.error('[PluginPrefs] init failed:', JSON.stringify(e));
    }
  }

  public subscribe(cb: () => void): number {
    this.nextSubId += 1;
    this.subscribers.set(this.nextSubId, cb);
    return this.nextSubId;
  }

  public unsubscribe(id: number): void {
    this.subscribers.delete(id);
  }

  private notify(): void {
    this.subscribers.forEach((cb: () => void) => {
      try {
        cb();
      } catch (_e) {
        // ignore subscriber errors
      }
    });
  }

  private key(deviceId: string, pluginKey: string, name: string): string {
    return `${deviceId}_${pluginKey}_${name}`;
  }

  public async put(deviceId: string, pluginKey: string, name: string,
    value: preferences.ValueType): Promise<void> {
    if (!this.pref) {
      return;
    }
    try {
      await this.pref.put(this.key(deviceId, pluginKey, name), value);
      await this.pref.flush();
    } catch (e) {
      console.error(`[PluginPrefs] put ${name} failed:`, JSON.stringify(e));
    }
    this.notify();
  }

  private getBoolean(deviceId: string, pluginKey: string, name: string,
    fallback: boolean): boolean {
    if (!this.pref) {
      return fallback;
    }
    const v = this.pref.getSync(this.key(deviceId, pluginKey, name), fallback);
    return typeof v === 'boolean' ? v : fallback;
  }

  private getString(deviceId: string, pluginKey: string, name: string,
    fallback: string): string {
    if (!this.pref) {
      return fallback;
    }
    const v = this.pref.getSync(this.key(deviceId, pluginKey, name), fallback);
    return typeof v === 'string' ? v : fallback;
  }

  private getNumber(deviceId: string, pluginKey: string, name: string,
    fallback: number): number {
    if (!this.pref) {
      return fallback;
    }
    const v = this.pref.getSync(this.key(deviceId, pluginKey, name), fallback);
    return typeof v === 'number' ? v : fallback;
  }

  // ── runcommand (runcommand_preferences.xml) ──────────────

  public getRunCommandNameAsTitle(deviceId: string): boolean {
    return this.getBoolean(deviceId, 'runcommand', 'runcommand_name_as_title', true);
  }

  public setRunCommandNameAsTitle(deviceId: string, value: boolean): void {
    this.put(deviceId, 'runcommand', 'runcommand_name_as_title', value);
  }

  // ── share (shareplugin_preferences.xml) ──────────────────

  public getShareNotification(deviceId: string): boolean {
    return this.getBoolean(deviceId, 'share', 'share_notification_preference', true);
  }

  public setShareNotification(deviceId: string, value: boolean): void {
    this.put(deviceId, 'share', 'share_notification_preference', value);
  }

  public getShareCustomDestination(deviceId: string): boolean {
    return this.getBoolean(deviceId, 'share', 'share_destination_custom', false);
  }

  public setShareCustomDestination(deviceId: string, value: boolean): void {
    this.put(deviceId, 'share', 'share_destination_custom', value);
  }

  public getShareDestinationDir(deviceId: string): string {
    return this.getString(deviceId, 'share', 'share_destination_folder', '');
  }

  public setShareDestinationDir(deviceId: string, value: string): void {
    this.put(deviceId, 'share', 'share_destination_folder', value);
  }

  // ── findmyphone (findmyphoneplugin_preferences.xml) ──────

  public getFindMyPhoneSound(deviceId: string): boolean {
    return this.getBoolean(deviceId, 'findmyphone', 'findmyphone_sound', true);
  }

  public setFindMyPhoneSound(deviceId: string, value: boolean): void {
    this.put(deviceId, 'findmyphone', 'findmyphone_sound', value);
  }

  public getFindMyPhoneFlashlight(deviceId: string): boolean {
    return this.getBoolean(deviceId, 'findmyphone', 'findmyphone_flashlight', false);
  }

  public setFindMyPhoneFlashlight(deviceId: string, value: boolean): void {
    this.put(deviceId, 'findmyphone', 'findmyphone_flashlight', value);
  }

  // ── mpris (mprisplugin_preferences.xml) ──────────────────

  public getMprisTimeSeconds(deviceId: string): number {
    return this.getNumber(deviceId, 'mpris', 'mpris_time', 10);
  }

  public setMprisTimeSeconds(deviceId: string, value: number): void {
    this.put(deviceId, 'mpris', 'mpris_time', value);
  }

  public getMprisNotification(deviceId: string): boolean {
    return this.getBoolean(deviceId, 'mpris', 'mpris_notification', true);
  }

  public setMprisNotification(deviceId: string, value: boolean): void {
    this.put(deviceId, 'mpris', 'mpris_notification', value);
  }

  public getMprisKeepWatching(deviceId: string): boolean {
    return this.getBoolean(deviceId, 'mpris', 'mpris_keepwatching', true);
  }

  public setMprisKeepWatching(deviceId: string, value: boolean): void {
    this.put(deviceId, 'mpris', 'mpris_keepwatching', value);
  }

  // ── digitizer (digitizer_preferences.xml) ────────────────

  public getDigitizerHideDrawButton(deviceId: string): boolean {
    return this.getBoolean(deviceId, 'digitizer', 'digitizer_hide_draw_button', false);
  }

  public setDigitizerHideDrawButton(deviceId: string, value: boolean): void {
    this.put(deviceId, 'digitizer', 'digitizer_hide_draw_button', value);
  }

  /** top_left | top_right | bottom_left | bottom_right (default bottom_left). */
  public getDigitizerDrawButtonSide(deviceId: string): string {
    return this.getString(deviceId, 'digitizer', 'digitizer_draw_button_side', 'bottom_left');
  }

  public setDigitizerDrawButtonSide(deviceId: string, value: string): void {
    this.put(deviceId, 'digitizer', 'digitizer_draw_button_side', value);
  }
}
