import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { wifiManager } from '@kit.ConnectivityKit';
import { AppSession } from '../app/AppSession';
import { DeviceStore } from '../store/DeviceStore';
import { PluginSettingsStore } from '../store/PluginSettingsStore';
import { SettingsStore } from '../store/SettingsStore';
import { KdeBackgroundService } from '../service/KdeBackgroundService';
import { KdeDevice, KDE_PROTOCOL_VERSION, MY_DEVICE_ID, TrustedDevice } from '../service/KdeTypes';
import { goBack, pushPage, hostContext } from '../common/NavUtil';
import { UiTheme, cssColor } from '../common/ui/UiTheme';
import { ImmersiveUtil } from '../common/ImmersiveUtil';
import { KdeTopBar } from '../common/ui/KdeWidgets';

/**
 * Settings page — aligned with Android KDE Connect SettingsFragment.
 *
 * Android preference order:
 *   1. Device name          (edit dialog)
 *   2. Choose theme         (light / dark / system)
 *   3. Persistent notification (toggle → continuous-task keep-alive)
 *   4. Trusted networks     (TrustedNetworks page)
 *   5. Add devices by IP    (IP:port → connect)
 *   6. Enable bluetooth     (unsupported on HarmonyOS third-party apps)
 *   7. Export logs          (write diagnostics text via DocumentViewPicker)
 *   8. More settings        (non-selectable spacer)
 */

interface SettingEntry {
  title: ResourceStr;
  summary: ResourceStr;
  kind: string;
  disabled: boolean;
}

@Entry
@Component
struct Settings {

  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State myName: string = '';
  @State persistentNotif: boolean = true;
  @State themeLabel: ResourceStr = $r('app.string.settings_theme_follow');

  @State confirmClear: boolean = false;
  @State dialogOpacity: number = 0;
  @State dialogScale: number = 0.92;

  @State showNameDialog: boolean = false;
  @State nameInput: string = '';

  @State showThemeDialog: boolean = false;

  @State showAddIpDialog: boolean = false;
  @State ipInput: string = '';
  @State portInput: string = '1716';

  private store: SettingsStore = SettingsStore.getInstance();
  private session: AppSession = AppSession.getInstance();
  private settingRows: SettingEntry[] = [
    {
      title: $r('app.string.settings_device_name'),
      summary: '',
      kind: 'name',
      disabled: false,
    },
    {
      title: $r('app.string.settings_choose_theme'),
      summary: $r('app.string.settings_theme_summary'),
      kind: 'theme',
      disabled: false,
    },
    {
      title: $r('app.string.settings_persistent_notification'),
      summary: $r('app.string.settings_persistent_notification_summary'),
      kind: 'persistent',
      disabled: false,
    },
    {
      title: $r('app.string.settings_trusted_networks'),
      summary: $r('app.string.settings_trusted_networks_summary'),
      kind: 'trusted',
      disabled: false,
    },
    {
      title: $r('app.string.settings_add_devices_by_ip'),
      summary: $r('app.string.settings_add_devices_by_ip_summary'),
      kind: 'addip',
      disabled: false,
    },
    {
      title: $r('app.string.settings_enable_bluetooth'),
      summary: '',
      kind: 'bluetooth',
      disabled: true,
    },
    {
      title: $r('app.string.settings_export_logs'),
      summary: $r('app.string.settings_export_logs_summary'),
      kind: 'export',
      disabled: false,
    },
    {
      title: $r('app.string.settings_more_settings'),
      summary: $r('app.string.settings_more_settings_summary'),
      kind: 'spacer',
      disabled: true,
    },
  ];

  aboutToAppear(): void {
    this.myName = this.session.getService().getMyName();
    this.persistentNotif = this.store.isPersistentNotification();
    this.applyThemeLabel();
    this.applyColorMode();
  }

  // ── Theme ────────────────────────────────────────────────

  private applyThemeLabel(): void {
    const theme: string = this.store.getTheme();
    if (theme === 'light') {
      this.themeLabel = $r('app.string.settings_theme_light');
    } else if (theme === 'dark') {
      this.themeLabel = $r('app.string.settings_theme_dark');
    } else {
      this.themeLabel = $r('app.string.settings_theme_follow');
    }
  }

  private applyColorMode(): void {
    const ctx: common.UIAbilityContext | undefined = hostContext(this.getUIContext());
    if (!ctx) {
      return;
    }
    const theme: string = this.store.getTheme();
    let mode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (theme === 'light') {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (theme === 'dark') {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    try {
      ctx.getApplicationContext().setColorMode(mode);
      // Refresh window/system-bar chrome so it follows the new theme too
      ImmersiveUtil.applyChrome(
        cssColor(ctx, UiTheme.surface),
        cssColor(ctx, UiTheme.onSurface)
      );
    } catch (e) {
      console.error('[Settings] setColorMode failed:', JSON.stringify(e));
    }
  }

  private chooseTheme(theme: string): void {
    this.store.setTheme(theme).then(() => {
      this.showThemeDialog = false;
      this.applyThemeLabel();
      this.applyColorMode();
    });
  }

  // ── Device name ──────────────────────────────────────────

  private openNameDialog(): void {
    this.nameInput = this.myName;
    this.showNameDialog = true;
  }

  private saveName(): void {
    const value: string = this.nameInput.trim();
    if (value.length === 0) {
      return;
    }
    this.session.getService().setMyName(value).then(() => {
      this.myName = this.session.getService().getMyName();
      this.showNameDialog = false;
      this.showToast($r('app.string.settings_name_saved'));
    });
  }

  // ── Persistent notification toggle ───────────────────────

  private togglePersistent(enabled: boolean): void {
    this.persistentNotif = enabled;
    this.store.setPersistentNotification(enabled).then(() => {
      KdeBackgroundService.getInstance().setKeepAliveEnabled(enabled).catch((e: Error) => {
        console.warn('[Settings] keep-alive toggle failed:', e.message);
      });
    });
  }

  // ── Add device by IP ─────────────────────────────────────

  private openAddIpDialog(): void {
    this.ipInput = '';
    this.portInput = '1716';
    this.showAddIpDialog = true;
  }

  private saveAddByIp(): void {
    const ip: string = this.ipInput.trim();
    const port: number = parseInt(this.portInput.trim(), 10);
    if (ip.length === 0) {
      return;
    }
    const validPort: number = (isNaN(port) || port <= 0 || port > 65535) ? 1716 : port;
    const device: KdeDevice = {
      deviceId: `manual_${ip}`,
      deviceName: ip,
      ip: ip,
      tcpPort: validPort,
      protocolVersion: KDE_PROTOCOL_VERSION,
      deviceType: 'desktop'
    };
    this.session.getService().connect(device);
    this.showAddIpDialog = false;
    this.showToast($r('app.string.settings_added_ip_toast'));
  }

  // ── Export logs ──────────────────────────────────────────

  private async exportLogs(): Promise<void> {
    try {
      const lines: string[] = [];
      lines.push('HMConnect 诊断信息');
      lines.push(`时间: ${new Date().toLocaleString()}`);
      lines.push(`设备名: ${this.myName}`);
      lines.push(`设备ID: ${MY_DEVICE_ID}`);
      lines.push(`协议版本: ${KDE_PROTOCOL_VERSION}`);
      lines.push(`后台保活: ${this.store.isPersistentNotification() ? '开' : '关'}`);
      let ssid: string = '';
      try {
        const info: wifiManager.WifiLinkedInfo = await wifiManager.getLinkedInfo();
        ssid = info.ssid ?? '';
      } catch (_e) {
        ssid = '';
      }
      lines.push(`当前WiFi: ${ssid.length > 0 ? ssid : '未知'}`);
      const trusted: TrustedDevice[] = DeviceStore.getInstance().getAll();
      lines.push(`已配对设备(${trusted.length}):`);
      for (let i = 0; i < trusted.length; i++) {
        const t = trusted[i];
        lines.push(`  - ${t.deviceName} lastIp=${t.lastIp ?? '-'} lastSeen=${t.lastSeenAt}`);
      }
      const trustedNets: string[] = this.store.getTrustedNetworks();
      lines.push(`可信网络(${trustedNets.length}):`);
      for (let i = 0; i < trustedNets.length; i++) {
        lines.push(`  - ${trustedNets[i]}`);
      }
      const content: string = lines.join('\n');

      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const saveOpt: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
      saveOpt.newFileNames = ['hmconnect_logs.txt'];
      const uris: string[] = await docPicker.save(saveOpt);
      if (!uris || uris.length === 0) {
        return;
      }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(file.fd, content);
      } finally {
        fileIo.closeSync(file);
      }
      this.showToast($r('app.string.settings_exported_toast'));
    } catch (e) {
      console.error('[Settings] exportLogs failed:', JSON.stringify(e));
      this.showToast($r('app.string.settings_export_failed'));
    }
  }

  // ── Clear pairs ──────────────────────────────────────────

  private clearPairs(): void {
    DeviceStore.getInstance().clear().then(() => {
      return PluginSettingsStore.getInstance().clearAll();
    }).then(() => {
      let svc = this.session.getService();
      svc.disconnect();
      svc.reloadTrustCache();
      this.hideConfirm();
      this.showToast($r('app.string.settings_cleared_toast'));
    });
  }

  private showConfirm(): void {
    this.confirmClear = true;
    this.dialogOpacity = 0;
    this.dialogScale = 0.92;
    this.getUIContext().animateTo({
      duration: UiTheme.durationMedium,
      curve: Curve.EaseOut
    }, () => {
      this.dialogOpacity = 1;
      this.dialogScale = 1;
    });
  }

  private hideConfirm(): void {
    this.getUIContext().animateTo({
      duration: UiTheme.durationShort,
      curve: Curve.EaseIn,
      onFinish: () => {
        this.confirmClear = false;
      }
    }, () => {
      this.dialogOpacity = 0;
      this.dialogScale = 0.92;
    });
  }

  // ── Row dispatch ─────────────────────────────────────────

  private handleRowTap(kind: string): void {
    if (kind === 'name') {
      this.openNameDialog();
    } else if (kind === 'theme') {
      this.showThemeDialog = true;
    } else if (kind === 'trusted') {
      pushPage(this.getUIContext(), 'pages/TrustedNetworks');
    } else if (kind === 'addip') {
      this.openAddIpDialog();
    } else if (kind === 'export') {
      this.exportLogs().catch((e: Error) => {
        console.error('[Settings] exportLogs error:', e.message);
      });
    } else if (kind === 'bluetooth') {
      this.onDisabledTap();
    }
  }

  private showToast(msg: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1500 });
  }

  private onDisabledTap(): void {
    this.showToast($r('app.string.settings_coming_soon'));
  }

  // ── Builders ─────────────────────────────────────────────

  @Builder
  SettingRow(entry: SettingEntry) {
    Column() {
      Row() {
        Column() {
          Text(entry.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(UiTheme.onSurface)
            .opacity(entry.disabled ? 0.4 : 1)
            .width('100%')

          if (entry.kind === 'name') {
            Text(this.myName.length > 0 ? this.myName : '—')
              .fontSize(13)
              .fontColor(UiTheme.onSurfaceVariant)
              .opacity(entry.disabled ? 0.4 : 1)
              .margin({ top: 4 })
              .width('100%')
          } else if (entry.kind === 'theme') {
            Text(this.themeLabel)
              .fontSize(13)
              .fontColor(UiTheme.onSurfaceVariant)
              .opacity(entry.disabled ? 0.4 : 1)
              .margin({ top: 4 })
              .width('100%')
          } else if (typeof entry.summary === 'string' && entry.summary.length > 0 ||
              typeof entry.summary === 'object') {
            Text(entry.summary)
              .fontSize(13)
              .fontColor(UiTheme.onSurfaceVariant)
              .opacity(entry.disabled ? 0.4 : 1)
              .margin({ top: 4 })
              .width('100%')
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (entry.kind === 'persistent') {
          Toggle({ type: ToggleType.Switch, isOn: this.persistentNotif })
            .onChange((isOn: boolean) => {
              this.togglePersistent(isOn);
            })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .margin({ left: 12, right: 12, top: 4, bottom: 4 })
    .onClick(() => {
      if (entry.kind === 'persistent') {
        return;
      }
      this.handleRowTap(entry.kind);
    })
  }

  // ── Main build ───────────────────────────────────────────

  build() {
    Stack() {
      Column() {
        KdeTopBar({
          title: $r('app.string.settings_title'),
          showBack: true,
          onBack: () => {
            goBack(this.getUIContext());
          }
        })

        Scroll() {
          Column() {
            ForEach(this.settingRows, (row: SettingEntry) => {
              this.SettingRow(row)
            }, (_item: SettingEntry, index: number) => index.toString())

            // ── Clear all paired records ──
            Column() {
              Text($r('app.string.settings_clear_pairs'))
                .fontSize(16)
                .fontWeight(FontWeight.Medium)
                .fontColor(UiTheme.danger)
                .width('100%')
              Text($r('app.string.settings_clear_pairs_summary'))
                .fontSize(13)
                .fontColor(UiTheme.danger)
                .opacity(0.75)
                .margin({ top: 4 })
                .width('100%')
            }
            .width('100%')
            .padding(16)
            .backgroundColor(UiTheme.cardBg)
            .borderRadius(UiTheme.radiusCard)
            .margin({ left: 12, right: 12, top: 20, bottom: 4 })
            .onClick(() => {
              this.showConfirm();
            })

            Column().width('100%').height(this.navBarHeight + 16)
          }
          .width('100%')
          .padding({ bottom: 16 })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(UiTheme.pageBg)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      // ── Clear pairs confirmation ──
      if (this.confirmClear) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(UiTheme.scrim)
            .opacity(this.dialogOpacity)
            .onClick(() => {
              this.hideConfirm();
            })

          Column() {
            Text($r('app.string.settings_clear_confirm_title'))
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(UiTheme.onSurface)
              .width('100%')
            Text($r('app.string.settings_clear_confirm_body'))
              .fontSize(14)
              .fontColor(UiTheme.onSurfaceVariant)
              .margin({ top: 8 })
              .width('100%')

            Row({ space: 12 }) {
              Button($r('app.string.settings_cancel'))
                .layoutWeight(1)
                .height(44)
                .backgroundColor(UiTheme.surfaceVariant)
                .fontColor(UiTheme.onSurface)
                .borderRadius(UiTheme.radiusButton)
                .onClick(() => {
                  this.hideConfirm();
                })
              Button($r('app.string.settings_clear'))
                .layoutWeight(1)
                .height(44)
                .backgroundColor(UiTheme.danger)
                .fontColor(Color.White)
                .borderRadius(UiTheme.radiusButton)
                .onClick(() => {
                  this.clearPairs();
                })
            }
            .width('100%')
            .margin({ top: 24 })
          }
          .width('86%')
          .padding(24)
          .backgroundColor(UiTheme.cardBg)
          .borderRadius(28)
          .scale({ x: this.dialogScale, y: this.dialogScale })
          .opacity(this.dialogOpacity)
        }
        .width('100%')
        .height('100%')
      }

      // ── Device name dialog ──
      if (this.showNameDialog) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(UiTheme.scrim)
            .onClick(() => {
              this.showNameDialog = false;
            })
          Column({ space: 16 }) {
            Text($r('app.string.settings_name_dialog_title'))
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(UiTheme.onSurface)
              .width('100%')
            TextInput({ text: this.nameInput, placeholder: $r('app.string.settings_name_dialog_hint') })
              .height(46)
              .backgroundColor(UiTheme.surfaceVariant)
              .borderRadius(UiTheme.radiusCard)
              .onChange((value: string) => {
                this.nameInput = value;
              })
            Row({ space: 12 }) {
              Button($r('app.string.settings_cancel'))
                .layoutWeight(1)
                .height(44)
                .fontColor(UiTheme.onSurface)
                .backgroundColor(UiTheme.surfaceVariant)
                .borderRadius(UiTheme.radiusButton)
                .onClick(() => {
                  this.showNameDialog = false;
                })
              Button($r('app.string.settings_save'))
                .layoutWeight(1)
                .height(44)
                .fontColor(UiTheme.onPrimary)
                .backgroundColor(UiTheme.primary)
                .borderRadius(UiTheme.radiusButton)
                .enabled(this.nameInput.trim().length > 0)
                .opacity(this.nameInput.trim().length > 0 ? 1 : 0.5)
                .onClick(() => {
                  this.saveName();
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

      // ── Theme dialog ──
      if (this.showThemeDialog) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(UiTheme.scrim)
            .onClick(() => {
              this.showThemeDialog = false;
            })
          Column({ space: 8 }) {
            Text($r('app.string.settings_choose_theme'))
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(UiTheme.onSurface)
              .width('100%')
              .margin({ bottom: 8 })
            this.ThemeOption($r('app.string.settings_theme_follow'), 'system')
            this.ThemeOption($r('app.string.settings_theme_light'), 'light')
            this.ThemeOption($r('app.string.settings_theme_dark'), 'dark')
            Row({ space: 12 }) {
              Button($r('app.string.settings_cancel'))
                .layoutWeight(1)
                .height(44)
                .fontColor(UiTheme.onSurface)
                .backgroundColor(UiTheme.surfaceVariant)
                .borderRadius(UiTheme.radiusButton)
                .onClick(() => {
                  this.showThemeDialog = false;
                })
            }
            .width('100%')
            .margin({ top: 8 })
          }
          .width('86%')
          .padding(24)
          .backgroundColor(UiTheme.cardBg)
          .borderRadius(28)
        }
        .width('100%')
        .height('100%')
      }

      // ── Add device by IP dialog ──
      if (this.showAddIpDialog) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(UiTheme.scrim)
            .onClick(() => {
              this.showAddIpDialog = false;
            })
          Column({ space: 16 }) {
            Text($r('app.string.settings_addip_dialog_title'))
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(UiTheme.onSurface)
              .width('100%')
            TextInput({ text: this.ipInput, placeholder: $r('app.string.settings_addip_ip_hint') })
              .height(46)
              .backgroundColor(UiTheme.surfaceVariant)
              .borderRadius(UiTheme.radiusCard)
              .onChange((value: string) => {
                this.ipInput = value;
              })
            TextInput({ text: this.portInput, placeholder: $r('app.string.settings_addip_port_hint') })
              .height(46)
              .type(InputType.Number)
              .backgroundColor(UiTheme.surfaceVariant)
              .borderRadius(UiTheme.radiusCard)
              .onChange((value: string) => {
                this.portInput = value;
              })
            Row({ space: 12 }) {
              Button($r('app.string.settings_cancel'))
                .layoutWeight(1)
                .height(44)
                .fontColor(UiTheme.onSurface)
                .backgroundColor(UiTheme.surfaceVariant)
                .borderRadius(UiTheme.radiusButton)
                .onClick(() => {
                  this.showAddIpDialog = false;
                })
              Button($r('app.string.settings_connect'))
                .layoutWeight(1)
                .height(44)
                .fontColor(UiTheme.onPrimary)
                .backgroundColor(UiTheme.primary)
                .borderRadius(UiTheme.radiusButton)
                .enabled(this.ipInput.trim().length > 0)
                .opacity(this.ipInput.trim().length > 0 ? 1 : 0.5)
                .onClick(() => {
                  this.saveAddByIp();
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
  }

  @Builder
  ThemeOption(label: ResourceStr, theme: string) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor(UiTheme.onSurface)
        .layoutWeight(1)
      if (this.store.getTheme() === theme) {
        Text('✓')
          .fontSize(16)
          .fontColor(UiTheme.primary)
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(UiTheme.surfaceVariant)
    .borderRadius(UiTheme.radiusCard)
    .onClick(() => {
      this.chooseTheme(theme);
    })
  }
}
