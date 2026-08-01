import { common } from '@kit.AbilityKit';
import { vibrator } from '@kit.SensorServiceKit';
import { KeyCode } from '@kit.InputKit';
import { AppSession } from '../app/AppSession';
import { DeviceSession } from '../service/DeviceSession';
import {
  MousepadInputInfo,
  MousepadModifiers,
  KdeStatus,
  MOUSEPAD_SPECIAL_KEY_DEL,
  MOUSEPAD_SPECIAL_KEY_TAB,
  MOUSEPAD_SPECIAL_KEY_LEFT,
  MOUSEPAD_SPECIAL_KEY_UP,
  MOUSEPAD_SPECIAL_KEY_RIGHT,
  MOUSEPAD_SPECIAL_KEY_DOWN,
  MOUSEPAD_SPECIAL_KEY_PAGE_UP,
  MOUSEPAD_SPECIAL_KEY_PAGE_DOWN,
  MOUSEPAD_SPECIAL_KEY_HOME,
  MOUSEPAD_SPECIAL_KEY_END,
  MOUSEPAD_SPECIAL_KEY_ENTER,
  MOUSEPAD_SPECIAL_KEY_FORWARD_DEL,
  MOUSEPAD_SPECIAL_KEY_ESC,
  MOUSEPAD_SPECIAL_KEY_PRINTSCREEN,
  MOUSEPAD_SPECIAL_KEY_SCROLL_LOCK,
  MOUSEPAD_SPECIAL_KEY_F1,
  MOUSEPAD_SPECIAL_KEY_F12
} from '../service/KdeTypes';
import { AcceleratedMouseDelta, PointerAcceleration } from '../service/PointerAcceleration';
import { RemoteInputSettingsStore } from '../store/RemoteInputSettingsStore';
import { goBack, routeParams, hostContext, pushPage } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeTopBar } from '../common/ui/KdeWidgets';
import { KdeIcon, KdeIconRes } from '../common/ui/KdeIcons';

interface RemoteInputRouteParams {
  deviceId: string;
}

interface TapOptionItem {
  value: string;
  label: string;
}

interface PickOption {
  label: string;
}

/** Android ViewConfiguration.getTapTimeout() + 100 */
const TAP_TIMEOUT: number = 400;
/** Android long press timeout (GestureDetector default). */
const LONG_PRESS_MS: number = 500;
/** Move beyond this distance cancels a tap (Android touch slop ≈ 15vp). */
const TAP_SLOP: number = 15;
/** Android MousePadActivity.MinDistanceToSendScroll. */
const MIN_SCROLL_DIST: number = 2.5;
/** Android MousePadActivity.StandardDpi = 240 (hdpi). */
const STANDARD_DPI: number = 240;
/** Virtual pixels per physical inch (vp ≈ dp; 160 vp = 1 inch). */
const VP_PER_INCH: number = 160;
/** Modifier bitmasks in KeyEvent.metaKey (OpenHarmony MetaKey). */
const META_SHIFT: number = 1;
const META_CTRL: number = 2;
const META_ALT: number = 4;
const META_SUPER: number = 8;

/**
 * Remote input touchpad — port of Android MousePadActivity.
 * Phone acts as touchpad + keyboard for the paired desktop via
 * kdeconnect.mousepad.request packets.
 */
@Entry
@Component
struct RemoteInputPage {
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State deviceName: string = '';
  @State mouseButtonsVisible: boolean = true;
  @State keyboardVisible: boolean = false;
  @State keyboardSupported: boolean = true;
  @State keyboardText: string = '';
  @State dragging: boolean = false;
  @State menuOpen: boolean = false;
  @State menuScale: number = 0.9;
  @State menuOpacity: number = 0;
  @State settingsOpen: boolean = false;
  @State settingsRev: number = 0;
  @State incomingText: string = '';
  @State toastHint: string = '';
  @State toastVisible: boolean = false;
  @State pickerOpen: boolean = false;
  @State pickerTitle: string = '';
  @State pickerOptions: string[] = [];
  @State pickerSelected: string = '';
  private pendingPick: (value: string) => void = (value: string) => {
  };
  /** TLS live state for the peer (false → touchpad can't send). */
  @State connected: boolean = false;
  @State connecting: boolean = false;
  // Settings display mirrors (refreshed by applyPrefs so the panel re-renders)
  @State singleTapLabel: string = '左键点击';
  @State doubleTapLabel: string = '右键点击';
  @State tripleTapLabel: string = '中键点击';
  @State sensLabel: string = '默认';
  @State accelLabelStr: string = '中等';
  @State scrollReversed: boolean = false;
  @State scrollSens: number = 100;
  @State showMouseButtons: boolean = true;
  @State dragModeEnabled: boolean = true;
  @State showKeyboardOnOpen: boolean = false;

  private deviceId: string = '';
  private client: DeviceSession | null = null;
  private session: AppSession = AppSession.getInstance();
  private prefs: RemoteInputSettingsStore = RemoteInputSettingsStore.getInstance();
  private prefsSubId: number = -1;
  private statusSubId: number = -1;
  private connectTried: boolean = false;
  private dpiMultiplier: number = 1;
  private mCurrentSensitivity: number = 1;
  private scrollDirection: number = 1;
  private scrollCoefficient: number = 1;
  private singleTapAction: string = 'left';
  private doubleTapAction: string = 'right';
  private tripleTapAction: string = 'middle';
  private doubleTapDragEnabled: boolean = true;
  private pointerAcceleration: PointerAcceleration = PointerAcceleration.forProfile('medium');
  private accDelta: AcceleratedMouseDelta = { x: 0, y: 0 };
  private keyboardController: TextInputController = new TextInputController();
  private lastSentLen: number = 0;
  private readonly emptyMods: MousepadModifiers = {};

  // Touch state machine (Android onTouchEvent + GestureDetector)
  private prevX: number = 0;
  private prevY: number = 0;
  private downX: number = 0;
  private downY: number = 0;
  private downTime: number = 0;
  private firstDownTime: number = 0;
  private moved: boolean = false;
  private isScrolling: boolean = false;
  private accumulatedDistanceY: number = 0;
  /** Active finger count (self-maintained; ArkUI Up event may keep the lifted finger). */
  private fingerCount: number = 0;
  private longPressTimer: number = -1;
  private tapTimer: number = -1;
  private tapCount: number = 0;
  private lastTapTime: number = 0;
  private incomingTimer: number = -1;
  private toastTimer: number = -1;

  aboutToAppear(): void {
    this.session.attachUiContext(this.getUIContext());
    const params = routeParams(this.getUIContext()) as RemoteInputRouteParams;
    if (params && params.deviceId) {
      this.deviceId = params.deviceId;
    }
    const ctx: common.UIAbilityContext | undefined = hostContext(this.getUIContext());
    if (ctx) {
      this.prefs.ensureInit(ctx).catch(() => {
      });
    }
    this.prefsSubId = this.prefs.subscribe(() => {
      this.applyPrefs();
    });
    // Android MousePadActivity: deltaPx * (StandardDpi / xdpi), with touch in PX.
    // ArkUI onTouch coordinates are in VP, so convert: px = vp * densityDPI/160.
    // Net multiplier = vp→px * Android scale = (densityDPI/160) * (240/densityDPI)
    // = 240/160 = 1.5 — density-independent (1 inch finger ≈ 240 mouse units).
    this.dpiMultiplier = STANDARD_DPI / VP_PER_INCH;
    this.applyPrefs();
    // Android applyPrefs: pref_mousepad_show_keyboard → show keyboard initially
    if (this.showKeyboardOnOpen && this.keyboardSupported) {
      this.keyboardVisible = true;
    }
    this.wireSession();
    this.ensureStatusSubscription();
    this.refreshConnection();
  }

  onPageShow(): void {
    this.session.attachUiContext(this.getUIContext());
    // Session may have been re-created / TLS may have re-established while away
    this.wireSession();
    this.ensureStatusSubscription();
    this.refreshConnection();
  }

  aboutToDisappear(): void {
    this.clearTimers();
    if (this.prefsSubId >= 0) {
      this.prefs.unsubscribe(this.prefsSubId);
      this.prefsSubId = -1;
    }
    if (this.statusSubId >= 0) {
      this.session.unsubscribeStatus(this.statusSubId);
      this.statusSubId = -1;
    }
  }

  private ensureStatusSubscription(): void {
    if (this.statusSubId >= 0) {
      return;
    }
    this.statusSubId = this.session.subscribeStatus((s: KdeStatus) => {
      if (this.deviceId.length > 0 && s.peerDeviceId && s.peerDeviceId.length > 0 &&
        s.peerDeviceId !== this.deviceId) {
        return;
      }
      this.refreshConnection();
    });
  }

  /**
   * Fresh session lookup on every call — the hub always holds the CURRENT
   * session for this deviceId, so a page opened mid-handshake or a replaced
   * session still routes to the live link (Android getDevicePlugin each time).
   */
  private liveClient(): DeviceSession | null {
    if (this.deviceId.length > 0) {
      return AppSession.getInstance().getService().getClientForDevice(this.deviceId);
    }
    return this.client;
  }

  private refreshConnection(): void {
    const cl = this.liveClient();
    const live: boolean = cl !== null && cl.isSessionLive();
    this.connected = live;
    if (live) {
      this.connecting = false;
      this.connectTried = false;
    }
    const svc = AppSession.getInstance().getService();
    if (this.deviceId.length > 0) {
      const item = svc.getDeviceById(this.deviceId);
      if (item) {
        this.deviceName = item.deviceName;
      }
      if (!live && item && (item.online || item.sessionActive)) {
        this.connecting = true;
        // Android: plugin opens only on reachable/paired devices; auto-connect
        // here so the touchpad works as soon as the link is up.
        if (!this.connectTried) {
          this.connectTried = true;
          svc.connectListItem(item);
        }
      }
    }
  }

  private wireSession(): void {
    const svc = AppSession.getInstance().getService();
    const hub = svc.getClient();
    if (this.deviceId.length > 0) {
      this.client = svc.getClientForDevice(this.deviceId);
      const item = svc.getDeviceById(this.deviceId);
      if (item) {
        this.deviceName = item.deviceName;
      }
      hub.setMousepadKeyboardStateListenerForDevice(this.deviceId, (enabled: boolean) => {
        this.keyboardSupported = enabled;
        if (!enabled && this.keyboardVisible) {
          this.keyboardVisible = false;
        }
      });
      hub.setMousepadInputListenerForDevice(this.deviceId, (info: MousepadInputInfo) => {
        this.onIncomingInput(info);
      });
      this.keyboardSupported = hub.getMousepadKeyboardEnabledForDevice(this.deviceId);
    } else {
      this.client = hub.getClient();
    }
  }

  private clearTimers(): void {
    if (this.longPressTimer >= 0) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
    if (this.tapTimer >= 0) {
      clearTimeout(this.tapTimer);
      this.tapTimer = -1;
    }
    if (this.incomingTimer >= 0) {
      clearTimeout(this.incomingTimer);
      this.incomingTimer = -1;
    }
    if (this.toastTimer >= 0) {
      clearTimeout(this.toastTimer);
      this.toastTimer = -1;
    }
  }

  // ── Prefs (Android MousePadActivity.applyPrefs) ──────────

  private applyPrefs(): void {
    this.mCurrentSensitivity = this.sensitivityValue(this.prefs.getSensitivity());
    this.scrollDirection = this.prefs.getScrollDirectionReversed() ? -1 : 1;
    const s = this.prefs.getScrollSensitivity();
    const safe = s > 0 ? s : 1;
    this.scrollCoefficient = Math.pow(safe / 100, 1.5);
    this.singleTapAction = this.prefs.getSingleTapAction();
    this.doubleTapAction = this.prefs.getDoubleTapAction();
    this.tripleTapAction = this.prefs.getTripleTapAction();
    this.doubleTapDragEnabled = this.prefs.getDoubleTapDragEnabled();
    this.mouseButtonsVisible = this.prefs.getMouseButtonsEnabled();
    this.pointerAcceleration = PointerAcceleration.forProfile(this.prefs.getAccelerationProfile());
    // Settings panel display mirrors
    this.singleTapLabel = this.tapOptionLabel(this.singleTapAction);
    this.doubleTapLabel = this.tapOptionLabel(this.doubleTapAction);
    this.tripleTapLabel = this.tapOptionLabel(this.tripleTapAction);
    this.sensLabel = this.sensitivityLabel(this.prefs.getSensitivity());
    this.accelLabelStr = this.accelLabel(this.prefs.getAccelerationProfile());
    this.scrollReversed = this.prefs.getScrollDirectionReversed();
    this.scrollSens = this.prefs.getScrollSensitivity();
    this.showMouseButtons = this.prefs.getMouseButtonsEnabled();
    this.dragModeEnabled = this.prefs.getDoubleTapDragEnabled();
    this.showKeyboardOnOpen = this.prefs.getShowKeyboard();
    this.settingsRev = this.settingsRev + 1;
  }

  private sensitivityValue(name: string): number {
    if (name === 'slowest') {
      return 0.2;
    }
    if (name === 'aboveSlowest') {
      return 0.5;
    }
    if (name === 'aboveDefault') {
      return 1.5;
    }
    if (name === 'fastest') {
      return 2.0;
    }
    return 1.0;
  }

  private sensitivityName(v: number): string {
    if (v === 0.2) {
      return 'slowest';
    }
    if (v === 0.5) {
      return 'aboveSlowest';
    }
    if (v === 1.5) {
      return 'aboveDefault';
    }
    if (v === 2.0) {
      return 'fastest';
    }
    return 'default';
  }

  // ── Sending (Android MousePadPlugin wrappers) ─────────────

  private sendMouseDelta(dx: number, dy: number): void {
    this.liveClient()?.sendMousepadDelta(dx, dy);
  }

  private sendLeftClick(): void {
    this.liveClient()?.sendMousepadLeftClick();
  }

  private sendRightClick(): void {
    this.liveClient()?.sendMousepadRightClick();
  }

  private sendMiddleClick(): void {
    this.liveClient()?.sendMousepadMiddleClick();
  }

  private sendDoubleClick(): void {
    this.liveClient()?.sendMousepadDoubleClick();
  }

  private sendScroll(y: number): void {
    this.liveClient()?.sendMousepadScroll(0, y);
  }

  private sendKey(text: string): void {
    this.liveClient()?.sendMousepadKey(text);
  }

  private sendSpecialKey(code: number, modifiers: MousepadModifiers): void {
    this.liveClient()?.sendMousepadSpecialKey(code, modifiers);
  }

  private vibrate(): void {
    vibrator.startVibration(
      { type: 'time', duration: 30 },
      { usage: 'physicalFeedback' }
    ).catch(() => {
    });
  }

  // ── Touch state machine (Android onTouchEvent) ───────────

  private onTouchEvent(event: TouchEvent): void {
    if (!this.connected) {
      return;
    }
    const type: TouchType = event.type;
    const count: number = event.touches.length;
    const primary: TouchObject | undefined = event.touches[0];

    if (type === TouchType.Down) {
      // Note: ArkUI touches[] already includes the new finger on Down.
      this.fingerCount = count > 0 ? count : this.fingerCount;
      if (count === 1 && primary) {
        this.firstDownTime = Date.now();
        this.prevX = primary.x;
        this.prevY = primary.y;
        this.downX = primary.x;
        this.downY = primary.y;
        this.downTime = Date.now();
        this.moved = false;
        this.isScrolling = false;
        this.startLongPressTimer();
      }
      return;
    }

    if (type === TouchType.Move) {
      if (!primary) {
        return;
      }
      this.fingerCount = count;
      if (count >= 2) {
        // Two-finger scroll (Android GestureDetector.onScroll)
        if (!this.isScrolling) {
          this.isScrolling = true;
          this.accumulatedDistanceY = 0;
          this.cancelLongPressTimer();
        }
        const curY: number = primary.y;
        const dy: number = curY - this.prevY;
        this.accumulatedDistanceY += dy * this.scrollCoefficient;
        if (Math.abs(this.accumulatedDistanceY) >= MIN_SCROLL_DIST) {
          this.sendScroll(this.scrollDirection * this.accumulatedDistanceY);
          this.accumulatedDistanceY = 0;
        }
        this.prevY = curY;
        return;
      }
      if (count === 1) {
        const curX: number = primary.x;
        const curY: number = primary.y;
        if (!this.moved) {
          if (Math.abs(curX - this.downX) > TAP_SLOP || Math.abs(curY - this.downY) > TAP_SLOP) {
            this.moved = true;
            this.cancelLongPressTimer();
          }
        }
        if (this.moved) {
          // Android: delta = touch move * dpi multiplier * sensitivity,
          // then run through the acceleration profile.
          const dx: number = (curX - this.prevX) * this.dpiMultiplier * this.mCurrentSensitivity;
          const dy: number = (curY - this.prevY) * this.dpiMultiplier * this.mCurrentSensitivity;
          this.pointerAcceleration.touchMoved(dx, dy, Date.now());
          const md: AcceleratedMouseDelta =
            this.pointerAcceleration.commitAcceleratedMouseDelta(this.accDelta);
          if (md.x !== 0 || md.y !== 0) {
            this.sendMouseDelta(md.x, md.y);
          }
        }
        this.prevX = curX;
        this.prevY = curY;
      }
      return;
    }

    if (type === TouchType.Up) {
      this.cancelLongPressTimer();
      // On Up, ArkUI touches[] may still contain the lifting finger, so rely on
      // the finger count tracked during Down/Move (Android pointerCount semantics).
      const liftedCount: number = event.changedTouches.length > 0 ? event.changedTouches.length : 1;
      const totalBefore: number = this.fingerCount;
      if (this.isScrolling) {
        this.isScrolling = false;
        this.accumulatedDistanceY = 0;
        this.fingerCount = Math.max(0, this.fingerCount - liftedCount);
        if (this.fingerCount === 0) {
          this.resetTouchState();
        } else if (primary) {
          // one finger remains — sync baseline so the next move doesn't jump
          this.prevX = primary.x;
          this.prevY = primary.y;
        }
        return;
      }
      // Multi-finger tap (Android MousePadGestureDetector on ACTION_POINTER_UP)
      if (totalBefore >= 2) {
        if (Date.now() - this.firstDownTime <= TAP_TIMEOUT) {
          if (totalBefore === 2) {
            this.fireTapAction(this.doubleTapAction);
          } else if (totalBefore === 3) {
            this.fireTapAction(this.tripleTapAction);
          }
        }
        this.fingerCount = Math.max(0, this.fingerCount - liftedCount);
        if (this.fingerCount === 0) {
          this.resetTouchState();
        }
        return;
      }
      // Single finger up
      if (totalBefore === 1) {
        if (!this.moved && Date.now() - this.downTime <= TAP_TIMEOUT) {
          if (this.dragging) {
            // finish drag & drop (Android onSingleTapConfirmed → sendSingleRelease)
            this.dragging = false;
            this.liveClient()?.sendMousepadSingleRelease();
          } else {
            this.registerSingleTap();
          }
        }
        this.fingerCount = 0;
        this.resetTouchState();
      }
      return;
    }

    if (type === TouchType.Cancel) {
      this.cancelLongPressTimer();
      this.isScrolling = false;
      this.accumulatedDistanceY = 0;
      this.fingerCount = 0;
      this.resetTouchState();
    }
  }

  private startLongPressTimer(): void {
    this.cancelLongPressTimer();
    this.longPressTimer = setTimeout(() => {
      this.longPressTimer = -1;
      // Android onLongPress: only when hold-to-drag (not double-tap-drag)
      if (!this.moved && !this.isScrolling && !this.doubleTapDragEnabled) {
        this.dragging = true;
        this.liveClient()?.sendMousepadSingleHold();
        this.vibrate();
      }
    }, LONG_PRESS_MS) as number;
  }

  private cancelLongPressTimer(): void {
    if (this.longPressTimer >= 0) {
      clearTimeout(this.longPressTimer);
      this.longPressTimer = -1;
    }
  }

  private resetTouchState(): void {
    this.tapCount = 0;
    this.moved = false;
    this.firstDownTime = 0;
  }

  /** Register a single-finger tap and resolve single/double tap after the timeout. */
  private registerSingleTap(): void {
    const now: number = Date.now();
    if (now - this.lastTapTime <= TAP_TIMEOUT) {
      this.tapCount += 1;
    } else {
      this.tapCount = 1;
    }
    this.lastTapTime = now;
    this.cancelTapTimer();
    this.tapTimer = setTimeout(() => {
      this.tapTimer = -1;
      this.firePendingTap();
    }, TAP_TIMEOUT) as number;
  }

  private cancelTapTimer(): void {
    if (this.tapTimer >= 0) {
      clearTimeout(this.tapTimer);
      this.tapTimer = -1;
    }
  }

  private firePendingTap(): void {
    if (this.tapCount >= 2) {
      this.fireDoubleAction();
    } else {
      this.fireSingleAction();
    }
    this.tapCount = 0;
  }

  private fireSingleAction(): void {
    this.fireTapAction(this.singleTapAction);
  }

  private fireDoubleAction(): void {
    if (this.doubleTapDragEnabled) {
      // Double-tap starts drag (Android onDoubleTap with doubleTapDragEnabled)
      this.dragging = true;
      this.liveClient()?.sendMousepadSingleHold();
      this.vibrate();
    } else {
      this.liveClient()?.sendMousepadDoubleClick();
    }
  }

  private fireTapAction(action: string): void {
    if (action === 'left') {
      this.sendLeftClick();
    } else if (action === 'right') {
      this.sendRightClick();
    } else if (action === 'middle') {
      this.sendMiddleClick();
    }
  }

  // ── Inbound desktop input feedback ───────────────────────

  private onIncomingInput(info: MousepadInputInfo): void {
    let label: string = '';
    if (info.kind === 'click') {
      const b: string = info.button ?? 'left';
      label = b === 'right' ? '电脑：右键点击' :
        (b === 'middle' ? '电脑：中键点击' : (b === 'double' ? '电脑：双击' : '电脑：左键点击'));
    } else if (info.kind === 'hold') {
      label = '电脑：长按拖动中';
    } else if (info.kind === 'release') {
      label = '电脑：拖放结束';
    } else if (info.kind === 'scroll') {
      label = '电脑：滚动';
    } else if (info.kind === 'key') {
      label = '电脑：键盘输入';
    }
    if (label.length === 0) {
      return;
    }
    this.incomingText = label;
    if (this.incomingTimer >= 0) {
      clearTimeout(this.incomingTimer);
    }
    this.incomingTimer = setTimeout(() => {
      this.incomingTimer = -1;
      this.incomingText = '';
    }, 1500) as number;
  }

  // ── Keyboard (Android KeyListenerView + KeyInputConnection) ──

  private toggleKeyboard(): void {
    if (!this.connected) {
      this.showToast($r('app.string.mousepad_not_connected'));
      return;
    }
    if (!this.keyboardSupported) {
      this.showToast($r('app.string.mousepad_keyboard_not_supported'));
      return;
    }
    this.keyboardVisible = !this.keyboardVisible;
    if (this.keyboardVisible) {
      this.keyboardText = '';
      this.lastSentLen = 0;
    }
  }

  /**
   * Committed text (Android InputConnection.commitText). During IME composition
   * onChange carries previewText → we ignore; only committed changes are sent.
   */
  private onKeyboardChange(value: string, previewText?: PreviewText): void {
    if (previewText && previewText.value && previewText.value.length > 0) {
      this.keyboardText = value;
      return;
    }
    this.keyboardText = value;
    if (value.length > this.lastSentLen) {
      const inserted: string = value.substring(this.lastSentLen);
      this.lastSentLen = value.length;
      this.sendKey(inserted);
      return;
    }
    if (value.length < this.lastSentLen) {
      const removed: number = this.lastSentLen - value.length;
      this.lastSentLen = value.length;
      for (let i = 0; i < removed; i++) {
        this.sendSpecialKey(MOUSEPAD_SPECIAL_KEY_DEL, this.emptyMods);
      }
    }
  }

  private onKeyboardSubmit(): void {
    this.sendSpecialKey(MOUSEPAD_SPECIAL_KEY_ENTER, this.emptyMods);
  }

  /** Hardware special keys (Android KeyListenerView.onKeyUp). */
  private onKeyboardKeyEvent(event: KeyEvent): boolean {
    if (event.type !== KeyType.Up) {
      return false;
    }
    const code: number = this.specialKeyFromCode(event.keyCode);
    if (code < 0) {
      return false;
    }
    const mods: MousepadModifiers = {
      shift: (event.metaKey & META_SHIFT) !== 0,
      ctrl: (event.metaKey & META_CTRL) !== 0,
      alt: (event.metaKey & META_ALT) !== 0,
      super: (event.metaKey & META_SUPER) !== 0
    };
    this.sendSpecialKey(code, mods);
    return true;
  }

  private specialKeyFromCode(code: number): number {
    switch (code) {
      case KeyCode.KEYCODE_DEL:
        return MOUSEPAD_SPECIAL_KEY_DEL;
      case KeyCode.KEYCODE_TAB:
        return MOUSEPAD_SPECIAL_KEY_TAB;
      case KeyCode.KEYCODE_DPAD_LEFT:
        return MOUSEPAD_SPECIAL_KEY_LEFT;
      case KeyCode.KEYCODE_DPAD_UP:
        return MOUSEPAD_SPECIAL_KEY_UP;
      case KeyCode.KEYCODE_DPAD_RIGHT:
        return MOUSEPAD_SPECIAL_KEY_RIGHT;
      case KeyCode.KEYCODE_DPAD_DOWN:
        return MOUSEPAD_SPECIAL_KEY_DOWN;
      case KeyCode.KEYCODE_PAGE_UP:
        return MOUSEPAD_SPECIAL_KEY_PAGE_UP;
      case KeyCode.KEYCODE_PAGE_DOWN:
        return MOUSEPAD_SPECIAL_KEY_PAGE_DOWN;
      case KeyCode.KEYCODE_MOVE_HOME:
        return MOUSEPAD_SPECIAL_KEY_HOME;
      case KeyCode.KEYCODE_MOVE_END:
        return MOUSEPAD_SPECIAL_KEY_END;
      case KeyCode.KEYCODE_ENTER:
        return MOUSEPAD_SPECIAL_KEY_ENTER;
      case KeyCode.KEYCODE_NUMPAD_ENTER:
        return MOUSEPAD_SPECIAL_KEY_ENTER;
      case KeyCode.KEYCODE_FORWARD_DEL:
        return MOUSEPAD_SPECIAL_KEY_FORWARD_DEL;
      case KeyCode.KEYCODE_ESCAPE:
        return MOUSEPAD_SPECIAL_KEY_ESC;
      case KeyCode.KEYCODE_SYSRQ:
        return MOUSEPAD_SPECIAL_KEY_PRINTSCREEN;
      case KeyCode.KEYCODE_SCROLL_LOCK:
        return MOUSEPAD_SPECIAL_KEY_SCROLL_LOCK;
      default:
        break;
    }
    // F1..F12 → 21..32
    if (code >= KeyCode.KEYCODE_F1 && code <= KeyCode.KEYCODE_F12) {
      return MOUSEPAD_SPECIAL_KEY_F1 + (code - KeyCode.KEYCODE_F1);
    }
    return -1;
  }

  // ── Menu / compose / settings ────────────────────────────

  private openMenu(): void {
    this.menuOpen = true;
    this.menuScale = 0.9;
    this.menuOpacity = 0;
    this.getUIContext().animateTo({
      duration: UiTheme.durationShort,
      curve: Curve.EaseOut
    }, () => {
      this.menuScale = 1;
      this.menuOpacity = 1;
    });
  }

  private closeMenu(): void {
    this.getUIContext().animateTo({
      duration: UiTheme.durationShort,
      curve: Curve.EaseIn,
      onFinish: () => {
        this.menuOpen = false;
      }
    }, () => {
      this.menuScale = 0.9;
      this.menuOpacity = 0;
    });
  }

  private openCompose(): void {
    this.closeMenu();
    if (!this.connected) {
      this.showToast($r('app.string.mousepad_not_connected'));
      return;
    }
    if (!this.keyboardSupported) {
      this.showToast($r('app.string.mousepad_keyboard_not_supported'));
      return;
    }
    const params: RemoteInputRouteParams = { deviceId: this.deviceId };
    pushPage(this.getUIContext(), 'pages/RemoteInputCompose', params);
  }

  private showToast(msg: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1500 });
    } catch (_e) {
      this.toastHint = msg as string;
      this.toastVisible = true;
      if (this.toastTimer >= 0) {
        clearTimeout(this.toastTimer);
      }
      this.toastTimer = setTimeout(() => {
        this.toastTimer = -1;
        this.toastVisible = false;
      }, 1500) as number;
    }
  }

  /** Guard manual actions against a dead link (Android would just fail to send). */
  private guardConnected(cb: () => void): void {
    if (!this.connected) {
      this.showToast($r('app.string.mousepad_not_connected'));
      return;
    }
    cb();
  }

  private tapOptionLabel(value: string): string {
    if (value === 'right') {
      return '右键点击';
    }
    if (value === 'middle') {
      return '中键点击';
    }
    if (value === 'none') {
      return '无操作';
    }
    return '左键点击';
  }

  private sensitivityLabel(name: string): string {
    if (name === 'slowest') {
      return '最慢';
    }
    if (name === 'aboveSlowest') {
      return '较慢';
    }
    if (name === 'aboveDefault') {
      return '较快';
    }
    if (name === 'fastest') {
      return '最快';
    }
    return '默认';
  }

  private accelLabel(name: string): string {
    if (name === 'noacceleration') {
      return '无加速';
    }
    if (name === 'weaker') {
      return '最弱';
    }
    if (name === 'weak') {
      return '较弱';
    }
    if (name === 'strong') {
      return '较强';
    }
    if (name === 'stronger') {
      return '最强';
    }
    return '中等';
  }

  /** Option picker (Android ListPreference dialog) — in-page selection overlay. */
  private pickOption(title: string, labels: PickOption[], current: string, onPick: (value: string) => void): void {
    const options: string[] = [];
    for (let i = 0; i < labels.length; i++) {
      options.push(labels[i].label);
    }
    this.pickerTitle = title;
    this.pickerOptions = options;
    this.pickerSelected = current;
    this.pendingPick = onPick;
    this.pickerOpen = true;
  }

  private closePicker(): void {
    this.pickerOpen = false;
  }

  private onPickOption(label: string): void {
    const cb: (value: string) => void = this.pendingPick;
    this.closePicker();
    cb(label);
  }

  private pickTapAction(kind: string, title: string): void {
    const items: PickOption[] = [
      { label: '左键点击' },
      { label: '右键点击' },
      { label: '中键点击' },
      { label: '无操作' }
    ];
    const values: string[] = ['left', 'right', 'middle', 'none'];
    const currentVal: string = kind === 'single' ? this.singleTapAction :
      (kind === 'double' ? this.doubleTapAction : this.tripleTapAction);
    const currentLabel: string = this.tapOptionLabel(currentVal);
    this.pickOption(title, items, currentLabel, (label: string) => {
      let idx: number = -1;
      for (let i = 0; i < items.length; i++) {
        if (items[i].label === label) {
          idx = i;
          break;
        }
      }
      if (idx < 0) {
        return;
      }
      const value: string = values[idx];
      if (kind === 'single') {
        this.prefs.setSingleTapAction(value);
      } else if (kind === 'double') {
        this.prefs.setDoubleTapAction(value);
      } else {
        this.prefs.setTripleTapAction(value);
      }
    });
  }

  private pickSensitivity(): void {
    const names: string[] = ['slowest', 'aboveSlowest', 'default', 'aboveDefault', 'fastest'];
    const items: PickOption[] = [];
    for (let i = 0; i < names.length; i++) {
      const opt: PickOption = { label: this.sensitivityLabel(names[i]) };
      items.push(opt);
    }
    const current: string = this.prefs.getSensitivity();
    this.pickOption('触控板灵敏度', items, this.sensitivityLabel(current), (label: string) => {
      let idx: number = -1;
      for (let i = 0; i < items.length; i++) {
        if (items[i].label === label) {
          idx = i;
          break;
        }
      }
      if (idx >= 0) {
        this.prefs.setSensitivity(names[idx]);
      }
    });
  }

  private pickAcceleration(): void {
    const names: string[] = ['noacceleration', 'weaker', 'weak', 'medium', 'strong', 'stronger'];
    const items: PickOption[] = [];
    for (let i = 0; i < names.length; i++) {
      const opt: PickOption = { label: this.accelLabel(names[i]) };
      items.push(opt);
    }
    const current: string = this.prefs.getAccelerationProfile();
    this.pickOption('指针加速', items, this.accelLabel(current), (label: string) => {
      let idx: number = -1;
      for (let i = 0; i < items.length; i++) {
        if (items[i].label === label) {
          idx = i;
          break;
        }
      }
      if (idx >= 0) {
        this.prefs.setAccelerationProfile(names[idx]);
      }
    });
  }

  // ── UI builders ──────────────────────────────────────────

  @Builder
  MenuItem(label: ResourceStr, onClick: () => void) {
    Text(label)
      .fontSize(16)
      .fontColor(UiTheme.onSurface)
      .width('100%')
      .padding({ left: 16, right: 16, top: 14, bottom: 14 })
      .onClick(() => {
        onClick();
      })
  }

  @Builder
  OverflowMenu() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#33000000')
        .opacity(this.menuOpacity)
        .onClick(() => {
          this.closeMenu();
        })

      Column() {
        this.MenuItem($r('app.string.mousepad_compose_send'), () => {
          this.openCompose();
        })
        this.MenuItem($r('app.string.mousepad_menu_right_click'), () => {
          this.closeMenu();
          this.guardConnected(() => {
            this.sendRightClick();
          });
        })
        this.MenuItem($r('app.string.mousepad_menu_middle_click'), () => {
          this.closeMenu();
          this.guardConnected(() => {
            this.sendMiddleClick();
          });
        })
        Divider().color(UiTheme.divider).width('100%')
        this.MenuItem(this.keyboardVisible
          ? $r('app.string.mousepad_menu_hide_keyboard')
          : $r('app.string.mousepad_menu_show_keyboard'), () => {
            this.closeMenu();
            this.toggleKeyboard();
          })
        this.MenuItem($r('app.string.mousepad_menu_settings'), () => {
          this.closeMenu();
          this.settingsOpen = true;
        })
      }
      .width(220)
      .backgroundColor(UiTheme.cardBg)
      .borderRadius(12)
      .shadow({ radius: 12, color: '#40000000', offsetX: 0, offsetY: 4 })
      .margin({ top: 52, right: 12 })
      .scale({ x: this.menuScale, y: this.menuScale })
      .opacity(this.menuOpacity)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  MouseButtonRow() {
    Row({ space: 16 }) {
      this.MouseButton($r('sys.symbol.mouse_fill'), $r('app.string.mousepad_left_click'), () => {
        this.sendLeftClick();
      })
      this.MouseButton($r('sys.symbol.circle'), $r('app.string.mousepad_middle_click'), () => {
        this.sendMiddleClick();
      })
      this.MouseButton($r('sys.symbol.mouse'), $r('app.string.mousepad_right_click'), () => {
        this.sendRightClick();
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .padding({ top: 10, bottom: 12 })
  }

  @Builder
  MouseButton(symbol: Resource, label: ResourceStr, onTap: () => void) {
    Column() {
      KdeIcon({ symbol: symbol, iconSize: 24, color: UiTheme.iconTint })
      Text(label)
        .fontSize(12)
        .fontColor(UiTheme.onSurfaceVariant)
        .margin({ top: 4 })
    }
    .width(72)
    .padding({ top: 12, bottom: 12 })
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .shadow({ radius: 2, color: '#1A000000', offsetX: 0, offsetY: 1 })
    .onClick(() => {
      this.guardConnected(() => {
        this.vibrate();
        onTap();
      });
    })
  }

  @Builder
  KeyboardArea() {
    Column() {
      Row() {
        Text($r('app.string.mousepad_keyboard_hint'))
          .fontSize(13)
          .fontColor(UiTheme.onSurfaceVariant)
          .layoutWeight(1)
        Button($r('app.string.mousepad_keyboard_enter'))
          .height(30)
          .fontSize(13)
          .fontColor(UiTheme.onPrimary)
          .backgroundColor(UiTheme.primary)
          .borderRadius(15)
          .padding({ left: 14, right: 14 })
          .onClick(() => {
            this.onKeyboardSubmit();
          })
      }
      .width('100%')
      .padding({ left: 16, right: 16, bottom: 6 })

      TextInput({ text: this.keyboardText, placeholder: $r('app.string.mousepad_keyboard_placeholder') })
        .id('remote_keyboard_input')
        .height(46)
        .fontSize(16)
        .backgroundColor(UiTheme.cardBg)
        .borderRadius(UiTheme.radiusCard)
        .padding({ left: 14, right: 14 })
        .margin({ left: 16, right: 16 })
        .enterKeyType(EnterKeyType.Send)
        .onChange((value: string, previewText?: PreviewText) => {
          this.onKeyboardChange(value, previewText);
        })
        .onSubmit(() => {
          this.onKeyboardSubmit();
        })
        .onKeyEvent((event: KeyEvent) => {
          return this.onKeyboardKeyEvent(event);
        })
    }
    .width('100%')
    .padding({ top: 8, bottom: 12 })
  }

  @Builder
  SettingRow(title: string, value: string, onTap: () => void) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor(UiTheme.onSurface)
        .layoutWeight(1)
      Text(value)
        .fontSize(14)
        .fontColor(UiTheme.onSurfaceVariant)
        .margin({ right: 8 })
      KdeIcon({ symbol: KdeIconRes.moreVert(), iconSize: 16, color: UiTheme.textMuted })
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 14, bottom: 14 })
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  SettingSwitchRow(title: string, isOn: boolean, onChange: (v: boolean) => void) {
    Row() {
      Text(title)
        .fontSize(16)
        .fontColor(UiTheme.onSurface)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(UiTheme.primary)
        .onChange((v: boolean) => {
          onChange(v);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 10, bottom: 10 })
  }

  @Builder
  SettingsPanel() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#33000000')
      .onClick(() => {
        this.settingsOpen = false;
      })

    Column() {
      Text($r('app.string.mousepad_settings_title'))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(UiTheme.onSurface)
        .width('100%')
        .padding({ left: 16, right: 16, top: 14, bottom: 8 })

      Scroll() {
        Column() {
          Text($r('app.string.mousepad_settings_section_tap'))
            .fontSize(13)
            .fontColor(UiTheme.onSurfaceVariant)
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 2 })
          this.SettingRow('单指点击', this.singleTapLabel, () => {
            this.pickTapAction('single', '单指点击动作');
          })
          this.SettingRow('双指点击', this.doubleTapLabel, () => {
            this.pickTapAction('double', '双指点击动作');
          })
          this.SettingRow('三指点击', this.tripleTapLabel, () => {
            this.pickTapAction('triple', '三指点击动作');
          })

          Text($r('app.string.mousepad_settings_section_pointer'))
            .fontSize(13)
            .fontColor(UiTheme.onSurfaceVariant)
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 2 })
          this.SettingRow('触控板灵敏度', this.sensLabel, () => {
            this.pickSensitivity();
          })
          this.SettingRow('指针加速', this.accelLabelStr, () => {
            this.pickAcceleration();
          })

          Text($r('app.string.mousepad_settings_section_scroll'))
            .fontSize(13)
            .fontColor(UiTheme.onSurfaceVariant)
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 2 })
          this.SettingSwitchRow('反向滚动方向', this.scrollReversed, (v: boolean) => {
            this.prefs.setScrollDirectionReversed(v);
          })
          Column() {
            Text('滚动灵敏度')
              .fontSize(16)
              .fontColor(UiTheme.onSurface)
              .width('100%')
            Slider({ value: this.scrollSens, min: 1, max: 200, step: 1, style: SliderStyle.OutSet })
              .width('100%')
              .selectedColor(UiTheme.primary)
              .blockColor(UiTheme.primary)
              .trackColor(UiTheme.surfaceVariant)
              .onChange((value: number) => {
                this.prefs.setScrollSensitivity(value);
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })

          Text($r('app.string.mousepad_settings_section_other'))
            .fontSize(13)
            .fontColor(UiTheme.onSurfaceVariant)
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 2 })
          this.SettingSwitchRow('显示鼠标按钮', this.showMouseButtons, (v: boolean) => {
            this.prefs.setMouseButtonsEnabled(v);
          })
          this.SettingSwitchRow(this.dragModeEnabled ? '双击拖拽' : '长按拖拽', this.dragModeEnabled, (v: boolean) => {
            this.prefs.setDoubleTapDragEnabled(v);
          })
          this.SettingSwitchRow('打开时显示键盘', this.showKeyboardOnOpen, (v: boolean) => {
            this.prefs.setShowKeyboard(v);
          })

          Column().width('100%').height(20)
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .constraintSize({ maxHeight: '80%' })
    .backgroundColor(UiTheme.cardBg)
    .borderRadius({ topLeft: UiTheme.radiusCard, topRight: UiTheme.radiusCard })
    .alignItems(HorizontalAlign.Start)
    .align(Alignment.Bottom)
  }

  @Builder
  PickerOverlay() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#33000000')
      .onClick(() => {
        this.closePicker();
      })

    Column() {
      Text(this.pickerTitle)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(UiTheme.onSurface)
        .width('100%')
        .padding({ left: 20, right: 20, top: 18, bottom: 8 })

      ForEach(this.pickerOptions, (option: string) => {
        Row() {
          Text(option)
            .fontSize(16)
            .fontColor(option === this.pickerSelected ? UiTheme.primary : UiTheme.onSurface)
            .fontWeight(option === this.pickerSelected ? FontWeight.Medium : FontWeight.Normal)
            .layoutWeight(1)
          if (option === this.pickerSelected) {
            KdeIcon({ symbol: $r('sys.symbol.checkmark'), iconSize: 20, color: UiTheme.primary })
          }
        }
        .width('100%')
        .padding({ left: 20, right: 20, top: 14, bottom: 14 })
        .onClick(() => {
          this.onPickOption(option);
        })
      }, (option: string) => `pick_${option}`)

      Divider().color(UiTheme.divider).width('100%')
      Text($r('app.string.settings_cancel'))
        .fontSize(16)
        .fontColor(UiTheme.onSurfaceVariant)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ top: 14, bottom: 16 })
        .onClick(() => {
          this.closePicker();
        })
    }
    .width('80%')
    .constraintSize({ maxWidth: 320 })
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  // ── Root ─────────────────────────────────────────────────

  build() {
    Stack() {
      Column() {
        KdeTopBar({
          title: this.deviceName.length > 0 ? this.deviceName : $r('app.string.plugin_remote_input'),
          showBack: true,
          showOverflow: true,
          onBack: () => {
            goBack(this.getUIContext());
          },
          onOverflow: () => {
            if (this.menuOpen) {
              this.closeMenu();
            } else {
              this.openMenu();
            }
          }
        })

        // ── Touchpad ──
        Stack({ alignContent: Alignment.Center }) {
          Column() {
            KdeIcon({ symbol: KdeIconRes.touchpad(), iconSize: 56, color: UiTheme.outline })
            Text($r('app.string.mousepad_info'))
              .fontSize(14)
              .fontColor(UiTheme.onSurfaceVariant)
              .textAlign(TextAlign.Center)
              .lineHeight(20)
              .margin({ top: 12 })
              .padding({ left: 24, right: 24 })
            if (this.dragging) {
              Text($r('app.string.mousepad_dragging'))
                .fontSize(14)
                .fontColor(UiTheme.primary)
                .fontWeight(FontWeight.Medium)
                .margin({ top: 10 })
            }
          }
          .width('100%')

          if (this.incomingText.length > 0) {
            Text(this.incomingText)
              .fontSize(13)
              .fontColor(UiTheme.onPrimaryContainer)
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .backgroundColor(UiTheme.primaryContainer)
              .borderRadius(UiTheme.radiusChip)
              .align(Alignment.Top)
              .margin({ top: 16 })
          }

          // ── Connection state (TLS not live → touchpad can't send) ──
          if (!this.connected) {
            Column() {
              if (this.connecting) {
                LoadingProgress()
                  .width(40)
                  .height(40)
                  .color(UiTheme.primary)
                Text($r('app.string.mousepad_connecting'))
                  .fontSize(14)
                  .fontColor(UiTheme.onSurfaceVariant)
                  .margin({ top: 10 })
              } else {
                KdeIcon({ symbol: KdeIconRes.errorOutline(), iconSize: 40, color: UiTheme.outline })
                Text($r('app.string.mousepad_not_connected'))
                  .fontSize(14)
                  .fontColor(UiTheme.onSurfaceVariant)
                  .textAlign(TextAlign.Center)
                  .lineHeight(20)
                  .margin({ top: 10, left: 24, right: 24 })
                Button($r('app.string.unreachable_refresh'))
                  .height(36)
                  .fontSize(14)
                  .fontColor(UiTheme.onPrimary)
                  .backgroundColor(UiTheme.primary)
                  .borderRadius(18)
                  .padding({ left: 20, right: 20 })
                  .margin({ top: 14 })
                  .onClick(() => {
                    this.refreshConnection();
                  })
              }
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          }
        }
        .width('100%')
        .layoutWeight(1)
        .backgroundColor(UiTheme.surfaceVariant)
        .margin({ left: 12, right: 12, top: 8, bottom: 8 })
        .borderRadius(UiTheme.radiusCard)
        .border({ width: 1, color: UiTheme.divider })
        .onTouch((event: TouchEvent) => {
          this.onTouchEvent(event);
        })

        if (this.mouseButtonsVisible) {
          this.MouseButtonRow()
        }

        if (this.keyboardVisible) {
          this.KeyboardArea()
        }

        Column().width('100%').height(this.navBarHeight + 8)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(UiTheme.pageBg)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.menuOpen) {
        this.OverflowMenu()
      }

      if (this.settingsOpen) {
        this.SettingsPanel()
      }

      if (this.pickerOpen) {
        this.PickerOverlay()
      }

      if (this.toastVisible) {
        Text(this.toastHint)
          .fontSize(14)
          .fontColor(Color.White)
          .padding({ left: 20, right: 20, top: 10, bottom: 10 })
          .backgroundColor('#CC000000')
          .borderRadius(20)
          .margin({ bottom: 48 + this.navBarHeight })
          .align(Alignment.Bottom)
      }
    }
    .width('100%')
    .height('100%')
  }
}
