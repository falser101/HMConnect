import { common } from '@kit.AbilityKit';
import { AppSession } from '../app/AppSession';
import { goBack, hostContext, routeParams, pushPage } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeTopBar } from '../common/ui/KdeWidgets';
import { KdeIcon, KdeIconRes } from '../common/ui/KdeIcons';
import {
  IMPLEMENTED_PLUGINS,
  PLUGIN_BATTERY,
  PLUGIN_CLIPBOARD,
  PLUGIN_DIGITIZER,
  PLUGIN_FIND_MY_PHONE,
  PLUGIN_MPRIS,
  PLUGIN_PING,
  PLUGIN_RECEIVE_NOTIFICATIONS,
  PLUGIN_REMOTE_INPUT,
  PLUGIN_RUNCOMMAND,
  PLUGIN_SHARE,
  PLUGIN_SYSTEMVOLUME,
  PluginMeta,
  isPluginSupportedByPeer,
  pluginHasSettings
} from '../service/PluginRegistry';
import { PluginSettingsStore } from '../store/PluginSettingsStore';
import { PluginSubSettingsParams } from './PluginSubSettings';
import { DeviceListItem, PacketStatCount } from '../service/KdeTypes';

interface PluginSettingsParams {
  deviceId: string;
  deviceName?: string;
}

interface PluginRow {
  key: string;
  title: ResourceStr;
  titleText: string;
  description: ResourceStr;
  enabled: boolean;
}

/**
 * Per-device plugin enable list — Android PluginSettingsListFragment.
 * Rows toggle plugins; tapping an enabled plugin with a settings screen opens
 * its sub-settings (Android PluginPreference content click). Toolbar overflow
 * shows per-device packet stats (Android "Plugin stats").
 */
@Entry
@Component
struct PluginSettings {

  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State deviceId: string = '';
  @State deviceName: string = '';
  @State rows: PluginRow[] = [];
  @State statsText: string = '';
  @State showStats: boolean = false;
  private session: AppSession = AppSession.getInstance();
  private storeSubId: number = -1;
  private ctxRef: common.UIAbilityContext | undefined = undefined;

  aboutToAppear() {
    this.session.attachUiContext(this.getUIContext());
    const params = routeParams(this.getUIContext()) as PluginSettingsParams;
    if (params && params.deviceId) {
      this.deviceId = params.deviceId;
    }
    if (params && params.deviceName) {
      this.deviceName = params.deviceName;
    }
    const ctx: common.UIAbilityContext | undefined = hostContext(this.getUIContext());
    this.ctxRef = ctx;
    if (ctx) {
      this.session.ensureStarted(ctx).then(() => {
        return PluginSettingsStore.getInstance().ensureDeviceLoaded(this.deviceId);
      }).then(() => {
        this.reloadRows();
      });
    } else {
      PluginSettingsStore.getInstance().ensureDeviceLoaded(this.deviceId).then(() => {
        this.reloadRows();
      });
    }
    this.storeSubId = PluginSettingsStore.getInstance().subscribe(() => {
      this.reloadRows();
    });
  }

  aboutToDisappear() {
    if (this.storeSubId >= 0) {
      PluginSettingsStore.getInstance().unsubscribe(this.storeSubId);
      this.storeSubId = -1;
    }
  }

  onPageShow() {
    this.session.attachUiContext(this.getUIContext());
    this.reloadRows();
  }

  private titleForKey(key: string): ResourceStr {
    if (key === PLUGIN_CLIPBOARD) {
      return $r('app.string.pref_plugin_clipboard');
    }
    if (key === PLUGIN_SHARE) {
      return $r('app.string.pref_plugin_share');
    }
    if (key === PLUGIN_MPRIS) {
      return $r('app.string.pref_plugin_mpris');
    }
    if (key === PLUGIN_SYSTEMVOLUME) {
      return $r('app.string.pref_plugin_systemvolume');
    }
    if (key === PLUGIN_PING) {
      return $r('app.string.pref_plugin_ping');
    }
    if (key === PLUGIN_BATTERY) {
      return $r('app.string.pref_plugin_battery');
    }
    if (key === PLUGIN_FIND_MY_PHONE) {
      return $r('app.string.pref_plugin_findmyphone');
    }
    if (key === PLUGIN_RECEIVE_NOTIFICATIONS) {
      return $r('app.string.pref_plugin_receive_notifications');
    }
    if (key === PLUGIN_REMOTE_INPUT) {
      return $r('app.string.pref_plugin_remote_input');
    }
    if (key === PLUGIN_RUNCOMMAND) {
      return $r('app.string.pref_plugin_runcommand');
    }
    if (key === PLUGIN_DIGITIZER) {
      return $r('app.string.pref_plugin_digitizer');
    }
    return $r('app.string.menu_plugin_settings');
  }

  private descForKey(key: string): ResourceStr {
    if (key === PLUGIN_CLIPBOARD) {
      return $r('app.string.pref_plugin_clipboard_desc');
    }
    if (key === PLUGIN_SHARE) {
      return $r('app.string.pref_plugin_share_desc');
    }
    if (key === PLUGIN_MPRIS) {
      return $r('app.string.pref_plugin_mpris_desc');
    }
    if (key === PLUGIN_SYSTEMVOLUME) {
      return $r('app.string.pref_plugin_systemvolume_desc');
    }
    if (key === PLUGIN_PING) {
      return $r('app.string.pref_plugin_ping_desc');
    }
    if (key === PLUGIN_BATTERY) {
      return $r('app.string.pref_plugin_battery_desc');
    }
    if (key === PLUGIN_FIND_MY_PHONE) {
      return $r('app.string.pref_plugin_findmyphone_desc');
    }
    if (key === PLUGIN_RECEIVE_NOTIFICATIONS) {
      return $r('app.string.pref_plugin_receive_notifications_desc');
    }
    if (key === PLUGIN_REMOTE_INPUT) {
      return $r('app.string.pref_plugin_remote_input_desc');
    }
    if (key === PLUGIN_RUNCOMMAND) {
      return $r('app.string.pref_plugin_runcommand_desc');
    }
    if (key === PLUGIN_DIGITIZER) {
      return $r('app.string.pref_plugin_digitizer_desc');
    }
    return $r('app.string.pref_plugin_clipboard_desc');
  }

  private titleTextOf(title: ResourceStr): string {
    if (typeof title === 'string') {
      return title;
    }
    if (this.ctxRef) {
      try {
        return this.ctxRef.resourceManager.getStringSync(title.id);
      } catch (_e) {
        // fall through
      }
    }
    return '';
  }

  private reloadRows(): void {
    const store = PluginSettingsStore.getInstance();
    // Android PluginSettingsListFragment: only supportedPlugins for this device
    let peerIn: string[] | undefined = undefined;
    let peerOut: string[] | undefined = undefined;
    if (this.deviceId.length > 0) {
      const item: DeviceListItem | undefined =
        this.session.getService().getDeviceById(this.deviceId);
      if (item) {
        peerIn = item.incomingCapabilities;
        peerOut = item.outgoingCapabilities;
      }
    }
    const list: PluginRow[] = [];
    for (let i = 0; i < IMPLEMENTED_PLUGINS.length; i++) {
      const meta: PluginMeta = IMPLEMENTED_PLUGINS[i];
      if (!isPluginSupportedByPeer(meta.key, peerIn, peerOut)) {
        continue;
      }
      const title: ResourceStr = this.titleForKey(meta.key);
      list.push({
        key: meta.key,
        title: title,
        titleText: this.titleTextOf(title),
        description: this.descForKey(meta.key),
        enabled: store.isEnabled(this.deviceId, meta.key)
      });
    }
    // Android PluginFactory.sortPluginList — sort by display name
    list.sort((a: PluginRow, b: PluginRow) => a.titleText.localeCompare(b.titleText));
    this.rows = list;
  }

  private onToggle(key: string, value: boolean): void {
    PluginSettingsStore.getInstance().setEnabled(this.deviceId, key, value).then(() => {
      this.reloadRows();
      // Android: enabling ReceiveNotificationsPlugin recreates it → onCreate request
      if (value && key === PLUGIN_RECEIVE_NOTIFICATIONS && this.deviceId.length > 0) {
        const s = this.session.getService().getClientForDevice(this.deviceId);
        if (s) {
          s.requestPeerNotifications();
        }
      }
    });
  }

  /** Android PluginPreference content click — open the plugin's settings screen. */
  private openSubSettings(row: PluginRow): void {
    const params: PluginSubSettingsParams = {
      deviceId: this.deviceId,
      pluginKey: row.key,
      pluginName: row.titleText
    };
    pushPage(this.getUIContext(), 'pages/PluginSubSettings', params);
  }

  private canOpenSettings(row: PluginRow): boolean {
    return row.enabled && pluginHasSettings(row.key);
  }

  private onRowContentTap(row: PluginRow): void {
    if (this.canOpenSettings(row)) {
      this.openSubSettings(row);
      return;
    }
    this.onToggle(row.key, !row.enabled);
  }

  private resString(res: Resource): string {
    if (this.ctxRef) {
      try {
        return this.ctxRef.resourceManager.getStringSync(res.id);
      } catch (_e) {
        // fall through
      }
    }
    return '';
  }

  private buildStatsText(): string {
    const hub = this.session.getService().getClient();
    const stats: PacketStatCount[] = hub.getPacketStatsForDevice(this.deviceId);
    if (stats.length === 0) {
      return this.resString($r('app.string.plugin_stats_empty'));
    }
    const sinceMs: number = hub.getStatsSinceMsForDevice(this.deviceId);
    const elapsedMs: number = Math.max(0, Date.now() - sinceMs);
    const hours: number = Math.floor(elapsedMs / 3600000);
    const minutes: number = Math.floor((elapsedMs % 3600000) / 60000);
    const sinceText: string = this.resString($r('app.string.plugin_stats_since'));
    const receivedText: string = this.resString($r('app.string.plugin_stats_received'));
    const sentText: string = this.resString($r('app.string.plugin_stats_sent'));
    const failedText: string = this.resString($r('app.string.plugin_stats_failed'));
    let lines: string = `${sinceText} ${hours}h ${minutes}m\n\n`;
    for (let i = 0; i < stats.length; i++) {
      const c: PacketStatCount = stats[i];
      const name: string = c.packetType.startsWith('kdeconnect.') ?
        c.packetType.substring('kdeconnect.'.length) : c.packetType;
      lines += `${name}\n• ${c.received} ${receivedText}\n` +
        `• ${c.sentOk + c.sentFail} ${sentText} (${c.sentFail} ${failedText})\n`;
    }
    return lines;
  }

  private openStats(): void {
    this.statsText = this.buildStatsText();
    this.showStats = true;
  }

  @Builder
  PluginRowItem(row: PluginRow) {
    Row() {
      Column() {
        Row() {
          Text(row.title)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
            .fontColor(UiTheme.onSurface)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (this.canOpenSettings(row)) {
            KdeIcon({ symbol: KdeIconRes.chevronRight(), iconSize: 18, color: UiTheme.onSurfaceVariant })
          }
        }
        .width('100%')

        Text(row.description)
          .fontSize(13)
          .fontColor(UiTheme.onSurfaceVariant)
          .margin({ top: 4 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ right: 12 })
      .onClick(() => {
        this.onRowContentTap(row);
      })

      Toggle({ type: ToggleType.Switch, isOn: row.enabled })
        .selectedColor(UiTheme.primary)
        .onChange((isOn: boolean) => {
          this.onToggle(row.key, isOn);
        })
    }
    .width('100%')
    .padding(16)
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .margin({ left: 12, right: 12, top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Stack() {
      Column() {
        KdeTopBar({
          title: $r('app.string.menu_plugin_settings'),
          showBack: true,
          showOverflow: true,
          onBack: () => {
            goBack(this.getUIContext());
          },
          onOverflow: () => {
            this.openStats();
          }
        })

        Scroll() {
          Column() {
            ForEach(this.rows, (row: PluginRow) => {
              this.PluginRowItem(row)
            }, (row: PluginRow) => `${row.key}_${row.enabled ? '1' : '0'}`)

            Column().width('100%').height(this.navBarHeight + 16)
          }
          .width('100%')
          .padding({ top: 8, bottom: 16 })
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(UiTheme.pageBg)

      // ── Plugin stats dialog (Android DeviceStats) — full-screen overlay ──
      if (this.showStats) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(UiTheme.scrim)
            .onClick(() => {
              this.showStats = false;
            })
          Column({ space: 12 }) {
            Text($r('app.string.plugin_stats'))
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(UiTheme.onSurface)
              .width('100%')
            Scroll() {
              Text(this.statsText)
                .fontSize(13)
                .fontColor(UiTheme.onSurface)
                .width('100%')
            }
            .width('100%')
            .height(220)
            .scrollBar(BarState.Auto)
            .edgeEffect(EdgeEffect.Spring)
            Button($r('app.string.ok'))
              .width('100%')
              .height(44)
              .fontColor(UiTheme.onPrimary)
              .backgroundColor(UiTheme.primary)
              .borderRadius(UiTheme.radiusButton)
              .onClick(() => {
                this.showStats = false;
              })
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
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
