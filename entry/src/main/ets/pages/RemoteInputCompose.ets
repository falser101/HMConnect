import { common } from '@kit.AbilityKit';
import { AppSession } from '../app/AppSession';
import { DeviceSession } from '../service/DeviceSession';
import { RemoteInputSettingsStore } from '../store/RemoteInputSettingsStore';
import { goBack, routeParams, hostContext } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeTopBar } from '../common/ui/KdeWidgets';

interface ComposeRouteParams {
  deviceId: string;
}

/**
 * Compose & send text to the desktop — port of Android ComposeSendActivity.
 * Text is typed on the phone and sent as kdeconnect.mousepad.request {key}
 * (Android MousePadPlugin.sendText). Input cached across visits.
 */
@Entry
@Component
struct RemoteInputComposePage {
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State text: string = '';
  private deviceId: string = '';
  private client: DeviceSession | null = null;
  private prefs: RemoteInputSettingsStore = RemoteInputSettingsStore.getInstance();

  aboutToAppear(): void {
    const ctx: common.UIAbilityContext | undefined = hostContext(this.getUIContext());
    if (ctx) {
      this.prefs.ensureInit(ctx).catch(() => {
      });
    }
    const params = routeParams(this.getUIContext()) as ComposeRouteParams;
    if (params && params.deviceId) {
      this.deviceId = params.deviceId;
    }
    this.text = this.prefs.getComposeCache();
    // Android: KdeConnect.getInstance().getDevicePlugin(deviceId, MousePadPlugin)
    if (this.deviceId.length > 0) {
      this.client = AppSession.getInstance().getService().getClientForDevice(this.deviceId);
    } else {
      this.client = AppSession.getInstance().getService().getClient().getClient();
    }
  }

  aboutToDisappear(): void {
    // Android ComposeSendActivity.onStop — cache non-blank input
    if (this.text.trim().length > 0) {
      this.prefs.setComposeCache(this.text);
    } else {
      this.prefs.setComposeCache('');
    }
  }

  private sendComposed(): void {
    const content: string = this.text.trim();
    if (content.length === 0) {
      return;
    }
    // Android: plugin.sendText(userInput.value)
    this.client?.sendMousepadKey(content);
    this.clearComposeInput();
  }

  private clearComposeInput(): void {
    this.text = '';
    this.prefs.setComposeCache('');
  }

  build() {
    Column() {
      KdeTopBar({
        title: $r('app.string.compose_send_title'),
        showBack: true,
        onBack: () => {
          goBack(this.getUIContext());
        }
      })

      Column() {
        TextArea({ text: this.text, placeholder: $r('app.string.compose_send_hint') })
          .height(160)
          .fontSize(16)
          .backgroundColor(UiTheme.cardBg)
          .borderRadius(UiTheme.radiusCard)
          .padding(14)
          .margin({ top: 8, bottom: 16 })
          .onChange((value: string) => {
            this.text = value;
          })

        Row() {
          Button($r('app.string.compose_clear'))
            .layoutWeight(1)
            .height(48)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(UiTheme.onSurface)
            .backgroundColor(UiTheme.surfaceVariant)
            .borderRadius(UiTheme.radiusButton)
            .onClick(() => {
              this.clearComposeInput();
            })

          Button($r('app.string.compose_send'))
            .layoutWeight(1)
            .height(48)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(UiTheme.onPrimary)
            .backgroundColor(UiTheme.primary)
            .borderRadius(UiTheme.radiusButton)
            .enabled(this.text.trim().length > 0)
            .opacity(this.text.trim().length > 0 ? 1 : 0.5)
            .onClick(() => {
              this.sendComposed();
            })
        }
        .width('100%')
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 16, right: 16, top: 8 })
      .alignItems(HorizontalAlign.Start)

      Column().width('100%').height(this.navBarHeight + 16)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(UiTheme.pageBg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
