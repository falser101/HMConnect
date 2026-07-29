import { common } from '@kit.AbilityKit';
import { AppSession } from '../app/AppSession';
import { goBack, hostContext, routeParams } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeTopBar } from '../common/ui/KdeWidgets';
import {
  IMPLEMENTED_PLUGINS,
  PLUGIN_BATTERY,
  PLUGIN_CLIPBOARD,
  PLUGIN_FIND_MY_PHONE,
  PLUGIN_MPRIS,
  PLUGIN_PING,
  PLUGIN_SHARE,
  PluginMeta
} from '../service/PluginRegistry';
import { PluginSettingsStore } from '../store/PluginSettingsStore';

interface PluginSettingsParams {
  deviceId: string;
  deviceName?: string;
}

interface PluginRow {
  key: string;
  title: ResourceStr;
  description: ResourceStr;
  enabled: boolean;
}

/**
 * Per-device plugin enable list — Android PluginSettingsListFragment.
 */
@Entry
@Component
struct PluginSettings {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State deviceId: string = '';
  @State deviceName: string = '';
  @State rows: PluginRow[] = [];
  private session: AppSession = AppSession.getInstance();
  private storeSubId: number = -1;

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
    if (key === PLUGIN_PING) {
      return $r('app.string.pref_plugin_ping');
    }
    if (key === PLUGIN_BATTERY) {
      return $r('app.string.pref_plugin_battery');
    }
    if (key === PLUGIN_FIND_MY_PHONE) {
      return $r('app.string.pref_plugin_findmyphone');
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
    if (key === PLUGIN_PING) {
      return $r('app.string.pref_plugin_ping_desc');
    }
    if (key === PLUGIN_BATTERY) {
      return $r('app.string.pref_plugin_battery_desc');
    }
    if (key === PLUGIN_FIND_MY_PHONE) {
      return $r('app.string.pref_plugin_findmyphone_desc');
    }
    return $r('app.string.pref_plugin_clipboard_desc');
  }

  private reloadRows(): void {
    const store = PluginSettingsStore.getInstance();
    const list: PluginRow[] = [];
    for (let i = 0; i < IMPLEMENTED_PLUGINS.length; i++) {
      const meta: PluginMeta = IMPLEMENTED_PLUGINS[i];
      list.push({
        key: meta.key,
        title: this.titleForKey(meta.key),
        description: this.descForKey(meta.key),
        enabled: store.isEnabled(this.deviceId, meta.key)
      });
    }
    this.rows = list;
  }

  private onToggle(key: string, value: boolean): void {
    PluginSettingsStore.getInstance().setEnabled(this.deviceId, key, value).then(() => {
      this.reloadRows();
    });
  }

  @Builder
  PluginRowItem(row: PluginRow) {
    Row() {
      Column() {
        Text(row.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(UiTheme.onSurface)
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
    Column() {
      Column()
        .width('100%')
        .height(this.statusBarHeight)
        .backgroundColor(UiTheme.surface)

      KdeTopBar({
        title: $r('app.string.menu_plugin_settings'),
        showBack: true,
        onBack: () => {
          goBack(this.getUIContext());
        }
      })

      if (this.deviceName.length > 0) {
        Text(this.deviceName)
          .fontSize(13)
          .fontColor(UiTheme.onSurfaceVariant)
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 4 })
      }

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
  }
}
