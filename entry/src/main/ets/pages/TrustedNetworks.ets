import { common } from '@kit.AbilityKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { SettingsStore } from '../store/SettingsStore';
import { goBack, routeParams, hostContext } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeTopBar } from '../common/ui/KdeWidgets';

/**
 * Trusted networks manager — port of Android TrustedNetworksActivity.
 * When the device is connected to a trusted WiFi network, incoming pairing
 * requests are accepted automatically.
 */
@Entry
@Component
struct TrustedNetworksPage {
  @State networks: string[] = [];
  @State showManual: boolean = false;
  @State manualInput: string = '';
  @State currentSsid: string = '';

  aboutToAppear(): void {
    this.refresh();
    this.readCurrentSsid();
  }

  private refresh(): void {
    this.networks = SettingsStore.getInstance().getTrustedNetworks();
  }

  private readCurrentSsid(): void {
    try {
      wifiManager.getLinkedInfo().then((info: wifiManager.WifiLinkedInfo) => {
        this.currentSsid = info.ssid ?? '';
      }).catch((_e: Error) => {
        this.currentSsid = '';
      });
    } catch (_e) {
      this.currentSsid = '';
    }
  }

  private addCurrent(): void {
    if (this.currentSsid.length === 0) {
      this.showToast($r('app.string.trusted_no_wifi'));
      return;
    }
    if (SettingsStore.getInstance().isTrustedNetwork(this.currentSsid)) {
      this.showToast($r('app.string.trusted_already_added'));
      return;
    }
    SettingsStore.getInstance().addTrustedNetwork(this.currentSsid).then(() => {
      this.refresh();
      this.showToast($r('app.string.trusted_added'));
    });
  }

  private confirmManual(): void {
    const value: string = this.manualInput.trim();
    if (value.length === 0) {
      return;
    }
    if (SettingsStore.getInstance().isTrustedNetwork(value)) {
      this.showToast($r('app.string.trusted_already_added'));
      return;
    }
    SettingsStore.getInstance().addTrustedNetwork(value).then(() => {
      this.refresh();
      this.manualInput = '';
      this.showManual = false;
      this.showToast($r('app.string.trusted_added'));
    });
  }

  private remove(ssid: string): void {
    SettingsStore.getInstance().removeTrustedNetwork(ssid).then(() => {
      this.refresh();
    });
  }

  private showToast(msg: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1500 });
  }

  build() {
    Column() {
      KdeTopBar({
        title: $r('app.string.settings_trusted_networks'),
        showBack: true,
        onBack: () => {
          goBack(this.getUIContext());
        }
      })

      Column({ space: 8 }) {
        Text($r('app.string.trusted_explain'))
          .fontSize(UiTheme.bodySm)
          .fontColor(UiTheme.textMuted)
          .width('100%')

        Row({ space: 8 }) {
          Button($r('app.string.trusted_add_current'))
            .layoutWeight(1)
            .height(46)
            .fontSize(UiTheme.bodyMd)
            .fontWeight(FontWeight.Medium)
            .fontColor(UiTheme.onPrimary)
            .backgroundColor(UiTheme.primary)
            .borderRadius(UiTheme.radiusButton)
            .onClick(() => {
              this.addCurrent();
            })
          Button($r('app.string.trusted_add_manual'))
            .layoutWeight(1)
            .height(46)
            .fontSize(UiTheme.bodyMd)
            .fontWeight(FontWeight.Medium)
            .fontColor(UiTheme.onSurface)
            .backgroundColor(UiTheme.surfaceVariant)
            .borderRadius(UiTheme.radiusButton)
            .onClick(() => {
              this.showManual = true;
              this.manualInput = '';
            })
        }
        .width('100%')
      }
      .padding({ left: UiTheme.pageHPad, right: UiTheme.pageHPad, top: 12 })

      if (this.currentSsid.length > 0) {
        Text(`${$r('app.string.trusted_current_label')} ${this.currentSsid}`)
          .fontSize(UiTheme.bodySm)
          .fontColor(UiTheme.primary)
          .width('100%')
          .padding({ left: UiTheme.pageHPad, right: UiTheme.pageHPad, top: 4 })
      }

      if (this.networks.length === 0) {
        Column() {
          Text($r('app.string.trusted_empty'))
            .fontSize(UiTheme.bodyMd)
            .fontColor(UiTheme.textMuted)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        List({ space: 8 }) {
          ForEach(this.networks, (ssid: string, index: number) => {
            ListItem() {
              Row() {
                Text(ssid)
                  .fontSize(UiTheme.bodyMd)
                  .fontColor(UiTheme.onSurface)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                Button($r('app.string.trusted_remove'))
                  .height(32)
                  .fontSize(UiTheme.bodySm)
                  .fontColor(UiTheme.danger)
                  .backgroundColor(UiTheme.surfaceVariant)
                  .borderRadius(UiTheme.radiusChip)
                  .onClick(() => {
                    this.remove(ssid);
                  })
              }
              .width('100%')
              .padding(14)
              .backgroundColor(UiTheme.cardBg)
              .borderRadius(UiTheme.radiusCard)
            }
          }, (ssid: string, index: number) => `n_${ssid}_${index}`)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: UiTheme.pageHPad, right: UiTheme.pageHPad, top: 12 })
        .scrollBar(BarState.Auto)
      }

      if (this.showManual) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(UiTheme.scrim)
            .onClick(() => {
              this.showManual = false;
            })
          Column({ space: 12 }) {
            Text($r('app.string.trusted_manual_title'))
              .fontSize(17)
              .fontWeight(FontWeight.Medium)
              .fontColor(UiTheme.onSurface)
              .width('100%')
            TextInput({ text: this.manualInput, placeholder: $r('app.string.trusted_manual_hint') })
              .height(46)
              .backgroundColor(UiTheme.surfaceVariant)
              .borderRadius(UiTheme.radiusCard)
              .onChange((value: string) => {
                this.manualInput = value;
              })
            Row({ space: 12 }) {
              Button($r('app.string.settings_cancel'))
                .layoutWeight(1)
                .height(44)
                .fontColor(UiTheme.onSurface)
                .backgroundColor(UiTheme.surfaceVariant)
                .borderRadius(UiTheme.radiusButton)
                .onClick(() => {
                  this.showManual = false;
                })
              Button($r('app.string.trusted_confirm'))
                .layoutWeight(1)
                .height(44)
                .fontColor(UiTheme.onPrimary)
                .backgroundColor(UiTheme.primary)
                .borderRadius(UiTheme.radiusButton)
                .enabled(this.manualInput.trim().length > 0)
                .opacity(this.manualInput.trim().length > 0 ? 1 : 0.5)
                .onClick(() => {
                  this.confirmManual();
                })
            }
            .width('100%')
          }
          .width('86%')
          .padding(24)
          .backgroundColor(UiTheme.cardBg)
          .borderRadius(28)
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(UiTheme.pageBg)
  }
}
