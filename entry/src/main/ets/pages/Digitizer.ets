import { display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { AppSession } from '../app/AppSession';
import { DeviceSession } from '../service/DeviceSession';
import { KdeStatus, KdeDigitizerEventBody } from '../service/KdeTypes';
import { goBack, routeParams, hostContext } from '../common/NavUtil';
import { UiTheme, cssColor } from '../common/ui/UiTheme';
import { KdeTopBar } from '../common/ui/KdeWidgets';
import { KdeIcon, KdeIconRes } from '../common/ui/KdeIcons';
import { PluginPrefsStore } from '../store/PluginPrefsStore';

interface DigitizerRouteParams {
  deviceId: string;
}

/** Tool names must match Android DigitizerPlugin ToolEvent.Tool. */
const TOOL_PEN: string = 'Pen';
const TOOL_RUBBER: string = 'Rubber';
/** mm per inch — Android sends resolution = dpi / 25.4. */
const MM_PER_INCH: number = 25.4;
/** Finger pressure — Android reports constant 1.0 (most screens can't measure). */
const FINGER_PRESSURE: number = 1.0;

/**
 * Drawing tablet — port of Android DigitizerActivity + DrawingPadView.
 * This device is the pen surface: touch → kdeconnect.digitizer events with
 * absolute px coordinates + pressure. Session announces surface size + dpi.
 */
@Entry
@Component
struct DigitizerPage {
  @State deviceName: string = '';
  @State connected: boolean = false;
  @State connecting: boolean = false;
  @State tool: string = TOOL_PEN;
  @State drawHeld: boolean = false;
  @State hideDrawButton: boolean = false;
  @State drawButtonSide: string = 'bottom_left';
  private deviceId: string = '';
  private session: AppSession = AppSession.getInstance();
  private client: DeviceSession | null = null;
  private statusSubId: number = -1;
  private connectTried: boolean = false;
  private ctx: CanvasRenderingContext2D =
    new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ctxRef: common.UIAbilityContext | undefined = undefined;
  private dpi: number = 320;
  private padW: number = 0;
  private padH: number = 0;
  private sessionStarted: boolean = false;

  aboutToAppear(): void {
    this.ctxRef = hostContext(this.getUIContext());
    try {
      this.dpi = display.getDefaultDisplaySync().densityDPI;
    } catch (_e) {
      this.dpi = 320;
    }
    const params = routeParams(this.getUIContext()) as DigitizerRouteParams;
    if (params && params.deviceId) {
      this.deviceId = params.deviceId;
      if (this.ctxRef) {
        PluginPrefsStore.getInstance().ensureInit(this.ctxRef).then(() => {
          const store = PluginPrefsStore.getInstance();
          this.hideDrawButton = store.getDigitizerHideDrawButton(this.deviceId);
          this.drawButtonSide = store.getDigitizerDrawButtonSide(this.deviceId);
        });
      }
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
    this.endSession();
  }

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
      this.tryStartSession();
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

  private tryStartSession(): void {
    if (this.sessionStarted || !this.connected || this.padW <= 0 || this.padH <= 0) {
      return;
    }
    const resX: number = Math.round(this.dpi / MM_PER_INCH);
    const resY: number = Math.round(this.dpi / MM_PER_INCH);
    this.liveClient()?.sendDigitizerSession(this.padW, this.padH, resX, resY);
    this.sessionStarted = true;
    console.info(`[KDE-MVP] digitizer session start ${this.padW}x${this.padH} res=${resX}`);
  }

  private endSession(): void {
    if (!this.sessionStarted) {
      return;
    }
    this.liveClient()?.sendDigitizerEndSession();
    this.sessionStarted = false;
  }

  private drawGrid(): void {
    const w: number = this.ctx.width;
    const h: number = this.ctx.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    const bg: string = this.ctxRef ? cssColor(this.ctxRef, UiTheme.surface) : '#FFFFFF';
    const line: string = this.ctxRef ? cssColor(this.ctxRef, UiTheme.outline) : '#E6E1E5';
    const spacing: number = 5 * this.dpi / MM_PER_INCH;
    this.ctx.fillStyle = bg;
    this.ctx.fillRect(0, 0, w, h);
    this.ctx.strokeStyle = line;
    this.ctx.lineWidth = 1;
    this.ctx.beginPath();
    for (let x: number = 0; x <= w; x += spacing) {
      this.ctx.moveTo(x, 0);
      this.ctx.lineTo(x, h);
    }
    for (let y: number = 0; y <= h; y += spacing) {
      this.ctx.moveTo(0, y);
      this.ctx.lineTo(w, y);
    }
    this.ctx.stroke();
    this.padW = w;
    this.padH = h;
    this.tryStartSession();
  }

  private handleTouch(event: TouchEvent): void {
    // Android DigitizerActivity: finger drawing requires holding the draw button
    if (!this.hideDrawButton && !this.drawHeld) {
      return;
    }
    if (event.touches.length === 0) {
      return;
    }
    const t: TouchObject = event.touches[0];
    if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      const up: KdeDigitizerEventBody = { active: false, touching: false };
      this.liveClient()?.sendDigitizerEvent(up);
      return;
    }
    const scale: number = this.dpi / 160;
    const ev: KdeDigitizerEventBody = {
      tool: this.tool,
      x: Math.round(t.x * scale),
      y: Math.round(t.y * scale),
      pressure: FINGER_PRESSURE
    };
    if (event.type === TouchType.Down) {
      ev.active = true;
      ev.touching = false;
    }
    this.liveClient()?.sendDigitizerEvent(ev);
  }

  private showToast(msg: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1500 });
  }

  private drawButtonAlignment(): Alignment {
    if (this.drawButtonSide === 'top_left') {
      return Alignment.TopStart;
    }
    if (this.drawButtonSide === 'top_right') {
      return Alignment.TopEnd;
    }
    if (this.drawButtonSide === 'bottom_right') {
      return Alignment.BottomEnd;
    }
    return Alignment.BottomStart;
  }

  @Builder
  ToolChip(label: ResourceStr, toolName: string) {
    Button(label)
      .layoutWeight(1)
      .height(42)
      .fontSize(UiTheme.bodyMd)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.tool === toolName ? UiTheme.onPrimary : UiTheme.onSurface)
      .backgroundColor(this.tool === toolName ? UiTheme.primary : UiTheme.surfaceVariant)
      .borderRadius(UiTheme.radiusButton)
      .onClick(() => {
        this.tool = toolName;
      })
  }

  build() {
    Column() {
      KdeTopBar({
        title: $r('app.string.plugin_drawing_tablet'),
        subtitle: this.deviceName,
        showBack: true,
        onBack: () => {
          goBack(this.getUIContext());
        }
      })

      if (!this.connected) {
        Text(this.connecting ? $r('app.string.run_command_loading') : $r('app.string.digitizer_not_connected'))
          .fontSize(UiTheme.bodySm)
          .fontColor(UiTheme.danger)
          .padding({ top: 4 })
      }

      Stack() {
        Canvas(this.ctx)
          .width('100%')
          .height('100%')
          .onReady(() => {
            this.drawGrid();
          })
          .onTouch((event: TouchEvent) => {
            this.handleTouch(event);
          })

        if (!this.hideDrawButton) {
          Column() {
            KdeIcon({ symbol: KdeIconRes.draw(), iconSize: 26, color: this.drawHeld ? UiTheme.onPrimary : UiTheme.onSurface })
          }
          .width(64)
          .height(64)
          .justifyContent(FlexAlign.Center)
          .borderRadius(32)
          .backgroundColor(this.drawHeld ? UiTheme.primary : UiTheme.cardElevated)
          .shadow({ radius: 8, color: UiTheme.scrim, offsetX: 0, offsetY: 4 })
          .align(this.drawButtonAlignment())
          .margin(16)
          .onTouch((event: TouchEvent) => {
            if (event.type === TouchType.Down) {
              this.drawHeld = true;
            } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
              this.drawHeld = false;
            }
          })
        }
      }
      .layoutWeight(1)
      .width('100%')
      .padding(12)

      Row({ space: 12 }) {
        this.ToolChip($r('app.string.digitizer_tool_pen'), TOOL_PEN)
        this.ToolChip($r('app.string.digitizer_tool_rubber'), TOOL_RUBBER)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8 })

      Text($r('app.string.digitizer_hint'))
        .fontSize(UiTheme.bodySm)
        .fontColor(UiTheme.textMuted)
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24, top: 8, bottom: 16 })
    }
    .width('100%')
    .height('100%')
  }
}
