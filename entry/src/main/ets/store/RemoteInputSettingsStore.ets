import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';

const PREF_NAME = 'hmconnect_mousepad';

/**
 * Global mousepad preferences (Android MousePadActivity SharedPreferences —
 * NOT per-device). Keys/values mirror mousepadplugin_preferences.xml.
 */
export class RemoteInputSettingsStore {
  private static instance: RemoteInputSettingsStore | null = null;
  private pref: preferences.Preferences | null = null;
  private ready: boolean = false;
  private subscribers: Map<number, () => void> = new Map();
  private nextSubId: number = 0;

  public static getInstance(): RemoteInputSettingsStore {
    if (!RemoteInputSettingsStore.instance) {
      RemoteInputSettingsStore.instance = new RemoteInputSettingsStore();
    }
    return RemoteInputSettingsStore.instance;
  }

  public async ensureInit(context: common.Context): Promise<void> {
    if (this.ready) {
      return;
    }
    try {
      this.pref = await preferences.getPreferences(context, PREF_NAME);
      this.ready = true;
    } catch (e) {
      console.error('[Mousepad] settings init failed:', JSON.stringify(e));
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

  private async put(key: string, value: preferences.ValueType): Promise<void> {
    if (!this.pref) {
      return;
    }
    try {
      await this.pref.put(key, value);
      await this.pref.flush();
    } catch (e) {
      console.error(`[Mousepad] settings put ${key} failed:`, JSON.stringify(e));
    }
    this.notify();
  }

  private getString(key: string, fallback: string): string {
    if (!this.pref) {
      return fallback;
    }
    let v = this.pref.getSync(key, fallback);
    return typeof v === 'string' ? v : fallback;
  }

  private getBoolean(key: string, fallback: boolean): boolean {
    if (!this.pref) {
      return fallback;
    }
    let v = this.pref.getSync(key, fallback);
    return typeof v === 'boolean' ? v : fallback;
  }

  private getNumber(key: string, fallback: number): number {
    if (!this.pref) {
      return fallback;
    }
    let v = this.pref.getSync(key, fallback);
    return typeof v === 'number' ? v : fallback;
  }

  // ── Individual prefs (Android keys) ──

  public getSingleTapAction(): string {
    return this.getString('mousepad_single_tap_key', 'left');
  }

  public setSingleTapAction(value: string): void {
    this.put('mousepad_single_tap_key', value);
  }

  public getDoubleTapAction(): string {
    return this.getString('mousepad_double_tap_key', 'right');
  }

  public setDoubleTapAction(value: string): void {
    this.put('mousepad_double_tap_key', value);
  }

  public getTripleTapAction(): string {
    return this.getString('mousepad_triple_tap_key', 'middle');
  }

  public setTripleTapAction(value: string): void {
    this.put('mousepad_triple_tap_key', value);
  }

  public getSensitivity(): string {
    return this.getString('mousepad_sensitivity_key', 'default');
  }

  public setSensitivity(value: string): void {
    this.put('mousepad_sensitivity_key', value);
  }

  public getAccelerationProfile(): string {
    return this.getString('mousepad_acceleration_profile_key', 'medium');
  }

  public setAccelerationProfile(value: string): void {
    this.put('mousepad_acceleration_profile_key', value);
  }

  /** Reverse scrolling direction. */
  public getScrollDirectionReversed(): boolean {
    return this.getBoolean('mousepad_scroll_direction', false);
  }

  public setScrollDirectionReversed(value: boolean): void {
    this.put('mousepad_scroll_direction', value);
  }

  public getScrollSensitivity(): number {
    return this.getNumber('mousepad_scroll_sensitivity', 100);
  }

  public setScrollSensitivity(value: number): void {
    this.put('mousepad_scroll_sensitivity', value);
  }

  /** Show mouse buttons row (Android mousepad_mouse_buttons_enabled_pref). */
  public getMouseButtonsEnabled(): boolean {
    return this.getBoolean('mouse_buttons_enabled', true);
  }

  public setMouseButtonsEnabled(value: boolean): void {
    this.put('mouse_buttons_enabled', value);
  }

  /** Double-tap to drag (Android doubletap_drag_enabled_pref, default true). */
  public getDoubleTapDragEnabled(): boolean {
    return this.getBoolean('doubletap_drag_enabled', true);
  }

  public setDoubleTapDragEnabled(value: boolean): void {
    this.put('doubletap_drag_enabled', value);
  }

  /** Show the keyboard when the touchpad page opens (Android pref_mousepad_show_keyboard). */
  public getShowKeyboard(): boolean {
    return this.getBoolean('pref_mousepad_show_keyboard', false);
  }

  public setShowKeyboard(value: boolean): void {
    this.put('pref_mousepad_show_keyboard', value);
  }

  /** Compose input cache (Android compose_send_input_cache). */
  public getComposeCache(): string {
    return this.getString('compose_send_input_cache', '');
  }

  public setComposeCache(value: string): void {
    if (value && value.length > 0) {
      this.put('compose_send_input_cache', value);
    } else {
      this.put('compose_send_input_cache', '');
    }
  }
}
