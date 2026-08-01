import { AppSession } from '../app/AppSession';
import { DeviceSession } from '../service/DeviceSession';
import {
  KdeStatus,
  MousepadModifiers,
  MOUSEPAD_SPECIAL_KEY_PAGE_UP,
  MOUSEPAD_SPECIAL_KEY_PAGE_DOWN,
  MOUSEPAD_SPECIAL_KEY_ESC
} from '../service/KdeTypes';
import { goBack, routeParams } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeTopBar } from '../common/ui/KdeWidgets';
import { KdeIcon, KdeIconRes } from '../common/ui/KdeIcons';

interface PresentationRouteParams {
  deviceId: string;
}

/** Android PresenterPlugin sends PageUp/PageDown/F5/ESC as mousepad specialKey. */
const MOUSEPAD_SPECIAL_KEY_F5: number = 25;
/** SwipeGesture angle: 0° = right, 180° = left. */
const SWIPE_LEFT_ANGLE_THRESHOLD: number = 90;

/**
 * Presentation remote — port of Android PresenterActivity + PresenterPlugin.
 * The phone controls slides on the desktop (LibreOffice Impress / PowerPoint)
 * by sending kdeconnect.mousepad.request special keys: PageUp/PageDown to flip
 * slides, F5 to start the slideshow and ESC to exit it.
 */
@Entry
@Component
struct PresentationPage {
  @State deviceName: string = '';
  @State connected: boolean = false;
  @State connecting: boolean = false;
  private deviceId: string = '';
  private session: AppSession = AppSession.getInstance();
  private client: DeviceSession | null = null;
  private statusSubId: number = -1;
  private connectTried: boolean = false;
  private readonly emptyMods: MousepadModifiers = {};

  aboutToAppear(): void {
    const params = routeParams(this.getUIContext()) as PresentationRouteParams;
    if (params && params.deviceId) {
      this.deviceId = params.deviceId;
    }
    this.wireSession();
    this.ensureStatusSubscription();
    this.refreshConnection();
  }

  onPageShow(): void {
    this.wireSession();
    this.ensureStatusSubscription();
    this.refreshConnection();
  }

  aboutToDisappear(): void {
    if (this.statusSubId >= 0) {
      this.session.unsubscribeStatus(this.statusSubId);
      this.statusSubId = -1;
    }
  }

  /**
   * Fresh session lookup on every call — the hub always holds the CURRENT
   * session for this deviceId (same pattern as RemoteInput).
   */
  private liveClient(): DeviceSession | null {
    if (this.deviceId.length > 0) {
      return AppSession.getInstance().getService().getClientForDevice(this.deviceId);
    }
    return this.client;
  }

  private wireSession(): void {
    const svc = AppSession.getInstance().getService();
    if (this.deviceId.length > 0) {
      this.client = svc.getClientForDevice(this.deviceId);
      const item = svc.getDeviceById(this.deviceId);
      if (item) {
        this.deviceName = item.deviceName;
      }
    } else {
      this.client = svc.getClient().getClient();
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
        if (!this.connectTried) {
          this.connectTried = true;
          svc.connectListItem(item);
        }
      }
    }
  }

  private sendSpecialKey(code: number): void {
    if (!this.connected) {
      this.showToast($r('app.string.presentation_not_connected'));
      return;
    }
    const cl = this.liveClient();
    if (cl) {
      cl.sendMousepadSpecialKey(code, this.emptyMods);
    }
  }

  private onSwipe(angle: number): void {
    // 180° = swipe left → next slide; ~0° = swipe right → previous slide
    if (angle >= SWIPE_LEFT_ANGLE_THRESHOLD) {
      this.sendSpecialKey(MOUSEPAD_SPECIAL_KEY_PAGE_DOWN);
    } else {
      this.sendSpecialKey(MOUSEPAD_SPECIAL_KEY_PAGE_UP);
    }
  }

  private showToast(msg: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1500 });
  }

  @Builder
  NavButton(label: ResourceStr, symbol: Resource, onTap: () => void) {
    Column() {
      KdeIcon({ symbol: symbol, iconSize: 44, color: UiTheme.onSurface })
      Text(label)
        .fontSize(UiTheme.bodyMd)
        .fontColor(UiTheme.onSurface)
        .margin({ top: 12 })
    }
    .justifyContent(FlexAlign.Center)
    .layoutWeight(1)
    .height(180)
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  ActionButton(label: ResourceStr, onTap: () => void) {
    Button(label)
      .layoutWeight(1)
      .height(46)
      .fontSize(UiTheme.bodyMd)
      .fontWeight(FontWeight.Medium)
      .fontColor(UiTheme.onSurface)
      .backgroundColor(UiTheme.surfaceVariant)
      .borderRadius(UiTheme.radiusButton)
      .onClick(() => {
        onTap();
      })
  }

  build() {
    Column() {
      KdeTopBar({
        title: $r('app.string.plugin_presentation_remote'),
        subtitle: this.deviceName,
        showBack: true,
        onBack: () => {
          goBack(this.getUIContext());
        }
      })

      if (!this.connected) {
        Text(this.connecting ? $r('app.string.run_command_loading') : $r('app.string.presentation_not_connected'))
          .fontSize(UiTheme.bodySm)
          .fontColor(UiTheme.danger)
          .padding({ top: 4 })
      }

      // Swipe area + nav buttons
      Column({ space: 16 }) {
        Row({ space: 16 }) {
          this.NavButton($r('app.string.presentation_prev'), KdeIconRes.arrowBack(), () => {
            this.sendSpecialKey(MOUSEPAD_SPECIAL_KEY_PAGE_UP);
          })
          this.NavButton($r('app.string.presentation_next'), KdeIconRes.chevronRight(), () => {
            this.sendSpecialKey(MOUSEPAD_SPECIAL_KEY_PAGE_DOWN);
          })
        }
        .width('100%')

        Text($r('app.string.presentation_hint'))
          .fontSize(UiTheme.bodySm)
          .fontColor(UiTheme.textMuted)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
      }
      .layoutWeight(1)
      .width('100%')
      .padding(24)
      .gesture(
        SwipeGesture({ direction: SwipeDirection.Horizontal, speed: 80 })
          .onAction((event: GestureEvent) => {
            this.onSwipe(event.angle);
          })
      )

      // Bottom actions: start / exit slideshow
      Row({ space: 12 }) {
        this.ActionButton($r('app.string.presentation_start'), () => {
          this.sendSpecialKey(MOUSEPAD_SPECIAL_KEY_F5);
        })
        this.ActionButton($r('app.string.presentation_exit'), () => {
          this.sendSpecialKey(MOUSEPAD_SPECIAL_KEY_ESC);
        })
      }
      .width('100%')
      .padding({ left: 24, right: 24, bottom: 24 })
    }
    .width('100%')
    .height('100%')
  }
}
