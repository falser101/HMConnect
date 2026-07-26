import { AppSession } from '../app/AppSession';
import { DeviceStore } from '../store/DeviceStore';
import { goBack } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeTopBar } from '../common/ui/KdeWidgets';

/**
 * Settings page — aligned with Android KDE Connect SettingsFragment.
 *
 * Android preference order:
 *   1. Device name          (EditTextPreference)
 *   2. Choose theme         (ListPreference)
 *   3. Persistent notification (Preference / SwitchPreference)
 *   4. Trusted networks     (Preference → TrustedNetworksActivity)
 *   5. Add devices by IP    (Preference → CustomDevicesActivity)
 *   6. Enable bluetooth     (SwitchPreference)
 *   7. Export logs          (Preference → SAF logcat dump)
 *   8. More settings        (non-selectable spacer)
 *
 * Strings use $r('app.string.*') resources — follows system language
 * (zh-CN → Chinese from base/, en-US → English from en_US/).
 * All unimplemented rows are grayed out (opacity 0.4, muted text);
 * tapping a disabled row shows a "coming soon" toast.
 */

interface SettingEntry {
  title: ResourceStr;
  summary: ResourceStr;
  disabled: boolean;      // true → grayed out, tap shows toast
  danger?: boolean;        // red danger styling (for Clear pairs)
  selectable?: boolean;    // false → non-tappable (More settings spacer)
}

@Entry
@Component
struct Settings {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State myName: string = '';
  @State confirmClear: boolean = false;
  @State dialogOpacity: number = 0;
  @State dialogScale: number = 0.92;

  // ── Setting entries (matches Android preference list) ──
  // summary '' for device-name row is filled in aboutToAppear
  private settingRows: SettingEntry[] = [
    {
      title: $r('app.string.settings_device_name'),
      summary: '',
      disabled: false,
      selectable: false,
    },
    {
      title: $r('app.string.settings_choose_theme'),
      summary: $r('app.string.settings_theme_summary'),
      disabled: true,
    },
    {
      title: $r('app.string.settings_persistent_notification'),
      summary: $r('app.string.settings_persistent_notification_summary'),
      disabled: true,
    },
    {
      title: $r('app.string.settings_trusted_networks'),
      summary: $r('app.string.settings_trusted_networks_summary'),
      disabled: true,
    },
    {
      title: $r('app.string.settings_add_devices_by_ip'),
      summary: $r('app.string.settings_add_devices_by_ip_summary'),
      disabled: true,
    },
    {
      title: $r('app.string.settings_enable_bluetooth'),
      summary: '',
      disabled: true,
    },
    {
      title: $r('app.string.settings_export_logs'),
      summary: $r('app.string.settings_export_logs_summary'),
      disabled: true,
    },
    {
      title: $r('app.string.settings_more_settings'),
      summary: $r('app.string.settings_more_settings_summary'),
      disabled: true,
      selectable: false,
    },
  ];

  aboutToAppear() {
    this.myName = AppSession.getInstance().getService().getMyName();
    this.settingRows[0].summary = this.myName.length > 0 ? this.myName : '—';
  }

  // ── Clear pairs ──────────────────────────────────────────

  private clearPairs(): void {
    DeviceStore.getInstance().clear().then(() => {
      let svc = AppSession.getInstance().getService();
      svc.disconnect();
      svc.reloadTrustCache();
      this.hideConfirm();
      try {
        this.getUIContext().getPromptAction().showToast({
          message: $r('app.string.settings_cleared_toast'),
          duration: 1500
        });
      } catch (_e) {
      }
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

  // ── Helpers ───────────────────────────────────────────────

  private onDisabledTap(): void {
    try {
      this.getUIContext().getPromptAction().showToast({
        message: $r('app.string.settings_coming_soon'),
        duration: 1500
      });
    } catch (_e) {
    }
  }

  // ── Builders ──────────────────────────────────────────────

  @Builder
  SettingRow(entry: SettingEntry) {
    Column() {
      Text(entry.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(entry.danger ? UiTheme.danger : UiTheme.onSurface)
        .opacity(entry.disabled ? 0.4 : 1)
        .width('100%')

      if (typeof entry.summary === 'string' && entry.summary.length > 0 ||
          typeof entry.summary === 'object') {
        Text(entry.summary)
          .fontSize(13)
          .fontColor(entry.danger ? UiTheme.danger : UiTheme.onSurfaceVariant)
          .opacity(entry.disabled ? 0.4 : 1)
          .margin({ top: 4 })
          .width('100%')
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .margin({ left: 12, right: 12, top: 4, bottom: 4 })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      if (entry.danger) {
        this.showConfirm();
        return;
      }
      let selectable = entry.selectable ?? true;
      if (!selectable) {
        return;
      }
      if (entry.disabled) {
        this.onDisabledTap();
      }
    })
  }

  // ── Main build ────────────────────────────────────────────

  build() {
    Stack() {
      Column() {
        Column()
          .width('100%')
          .height(this.statusBarHeight)
          .backgroundColor(UiTheme.surface)

        KdeTopBar({
          title: 'Settings',
          showBack: true,
          onBack: () => {
            goBack(this.getUIContext());
          }
        })

        Scroll() {
          Column() {
            // Android-aligned setting rows
            ForEach(this.settingRows, (row: SettingEntry) => {
              this.SettingRow(row)
            }, (_item: SettingEntry, index: number) => index.toString())

            // ── Clear all paired records (HMConnect-specific, functional) ──
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
            .alignItems(HorizontalAlign.Start)
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

      // ── Clear pairs confirmation dialog ──
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
    }
    .width('100%')
    .height('100%')
  }
}
