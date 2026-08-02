import { common } from '@kit.AbilityKit';
import { picker } from '@kit.CoreFileKit';
import { AppSession } from '../app/AppSession';
import { goBack, hostContext, routeParams } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeTopBar } from '../common/ui/KdeWidgets';
import { KdeIcon, KdeIconRes } from '../common/ui/KdeIcons';
import { PluginPrefsStore } from '../store/PluginPrefsStore';
import { RemoteInputSettingsStore } from '../store/RemoteInputSettingsStore';
import {
  PLUGIN_DIGITIZER,
  PLUGIN_FIND_MY_PHONE,
  PLUGIN_MPRIS,
  PLUGIN_REMOTE_INPUT,
  PLUGIN_RUNCOMMAND,
  PLUGIN_SHARE
} from '../service/PluginRegistry';

export interface PluginSubSettingsParams {
  deviceId: string;
  pluginKey: string;
  pluginName: string;
}

interface SubOption {
  value: string;
  label: string;
}

interface SubPrefRow {
  kind: 'switch' | 'list' | 'folder';
  rowKey: string;
  title: ResourceStr;
  summary: ResourceStr;
  switchOn: boolean;
  options: SubOption[];
}

const TAP_OPTIONS: SubOption[] = [
  { value: 'left', label: '左键点击' },
  { value: 'right', label: '右键点击' },
  { value: 'middle', label: '中键点击' },
  { value: 'none', label: '无操作' }
];

const SENSITIVITY_OPTIONS: SubOption[] = [
  { value: 'slowest', label: '最慢' },
  { value: 'aboveSlowest', label: '较慢' },
  { value: 'default', label: '默认' },
  { value: 'aboveDefault', label: '较快' },
  { value: 'fastest', label: '最快' }
];

const ACCEL_OPTIONS: SubOption[] = [
  { value: 'noacceleration', label: '无加速' },
  { value: 'weaker', label: '最弱' },
  { value: 'weak', label: '较弱' },
  { value: 'medium', label: '中等' },
  { value: 'strong', label: '较强' },
  { value: 'stronger', label: '最强' }
];

const SCROLL_SENS_OPTIONS: SubOption[] = [
  { value: '50', label: '低' },
  { value: '75', label: '中低' },
  { value: '100', label: '默认' },
  { value: '125', label: '中高' },
  { value: '150', label: '高' }
];

const MPRIS_TIME_OPTIONS: SubOption[] = [
  { value: '10', label: '10 秒' },
  { value: '20', label: '20 秒' },
  { value: '30', label: '30 秒' },
  { value: '60', label: '1 分钟' },
  { value: '120', label: '2 分钟' }
];

const DIGITIZER_SIDE_OPTIONS: SubOption[] = [
  { value: 'top_left', label: '左上' },
  { value: 'top_right', label: '右上' },
  { value: 'bottom_left', label: '左下' },
  { value: 'bottom_right', label: '右下' }
];

/**
 * Per-plugin sub-settings — port of Android PluginSettingsFragment for the
 * plugins we implement. The plugin list page opens this for a plugin that is
 * enabled and has settings (Android PluginPreference content click).
 */
@Entry
@Component
struct PluginSubSettings {
  @State rows: SubPrefRow[] = [];
  @State pickerOpen: boolean = false;
  @State pickerTitle: string = '';
  @State pickerOptions: SubOption[] = [];
  @State pickerSelected: string = '';
  private deviceId: string = '';
  private pluginKey: string = '';
  private pageTitle: string = '';
  private session: AppSession = AppSession.getInstance();
  private pendingPick: (value: string) => void = (value: string) => {
  };

  aboutToAppear(): void {
    this.session.attachUiContext(this.getUIContext());
    const params = routeParams(this.getUIContext()) as PluginSubSettingsParams;
    if (params && params.deviceId) {
      this.deviceId = params.deviceId;
    }
    if (params && params.pluginKey) {
      this.pluginKey = params.pluginKey;
    }
    if (params && params.pluginName) {
      this.pageTitle = params.pluginName;
    }
    const ctx: common.UIAbilityContext | undefined = hostContext(this.getUIContext());
    if (ctx) {
      PluginPrefsStore.getInstance().ensureInit(ctx).then(() => {
        this.buildRows();
      });
      RemoteInputSettingsStore.getInstance().ensureInit(ctx).catch(() => {
      });
    }
    this.buildRows();
  }

  private tapLabel(value: string): string {
    for (let i = 0; i < TAP_OPTIONS.length; i++) {
      if (TAP_OPTIONS[i].value === value) {
        return TAP_OPTIONS[i].label;
      }
    }
    return TAP_OPTIONS[0].label;
  }

  private sensLabel(value: string): string {
    for (let i = 0; i < SENSITIVITY_OPTIONS.length; i++) {
      if (SENSITIVITY_OPTIONS[i].value === value) {
        return SENSITIVITY_OPTIONS[i].label;
      }
    }
    return '默认';
  }

  private accelLabel(value: string): string {
    for (let i = 0; i < ACCEL_OPTIONS.length; i++) {
      if (ACCEL_OPTIONS[i].value === value) {
        return ACCEL_OPTIONS[i].label;
      }
    }
    return '中等';
  }

  private optionLabel(options: SubOption[], value: string): string {
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === value) {
        return options[i].label;
      }
    }
    return '';
  }

  private buildRows(): void {
    const store = PluginPrefsStore.getInstance();
    const mousepad = RemoteInputSettingsStore.getInstance();
    const list: SubPrefRow[] = [];

    if (this.pluginKey === PLUGIN_RUNCOMMAND) {
      list.push({
        kind: 'switch',
        rowKey: 'name_as_title',
        title: $r('app.string.subsettings_runcommand_name_title'),
        summary: $r('app.string.subsettings_runcommand_name_summary'),
        switchOn: store.getRunCommandNameAsTitle(this.deviceId),
        options: []
      });
    } else if (this.pluginKey === PLUGIN_REMOTE_INPUT) {
      list.push({
        kind: 'list', rowKey: 'single_tap',
        title: $r('app.string.mousepad_single_tap_settings_title'),
        summary: this.tapLabel(mousepad.getSingleTapAction()),
        switchOn: false,
        options: TAP_OPTIONS
      });
      list.push({
        kind: 'list', rowKey: 'double_tap',
        title: $r('app.string.mousepad_double_tap_settings_title'),
        summary: this.tapLabel(mousepad.getDoubleTapAction()),
        switchOn: false,
        options: TAP_OPTIONS
      });
      list.push({
        kind: 'list', rowKey: 'triple_tap',
        title: $r('app.string.mousepad_triple_tap_settings_title'),
        summary: this.tapLabel(mousepad.getTripleTapAction()),
        switchOn: false,
        options: TAP_OPTIONS
      });
      list.push({
        kind: 'list', rowKey: 'sensitivity',
        title: $r('app.string.mousepad_sensitivity_settings_title'),
        summary: this.sensLabel(mousepad.getSensitivity()),
        switchOn: false,
        options: SENSITIVITY_OPTIONS
      });
      list.push({
        kind: 'list', rowKey: 'accel',
        title: $r('app.string.mousepad_acceleration_profile_settings_title'),
        summary: this.accelLabel(mousepad.getAccelerationProfile()),
        switchOn: false,
        options: ACCEL_OPTIONS
      });
      list.push({
        kind: 'switch', rowKey: 'scroll_dir',
        title: $r('app.string.mousepad_scroll_direction_title'),
        summary: '',
        switchOn: mousepad.getScrollDirectionReversed(),
        options: []
      });
      list.push({
        kind: 'list', rowKey: 'scroll_sens',
        title: $r('app.string.mousepad_scroll_sensitivity_title'),
        summary: this.optionLabel(SCROLL_SENS_OPTIONS, String(mousepad.getScrollSensitivity())),
        switchOn: false,
        options: SCROLL_SENS_OPTIONS
      });
      list.push({
        kind: 'switch', rowKey: 'mouse_buttons',
        title: $r('app.string.mousepad_mouse_buttons_title'),
        summary: '',
        switchOn: mousepad.getMouseButtonsEnabled(),
        options: []
      });
      list.push({
        kind: 'switch', rowKey: 'doubletap_drag',
        title: $r('app.string.mousepad_doubletap_drag_title'),
        summary: '',
        switchOn: mousepad.getDoubleTapDragEnabled(),
        options: []
      });
      list.push({
        kind: 'switch', rowKey: 'show_keyboard',
        title: $r('app.string.mousepad_show_keyboard'),
        summary: '',
        switchOn: mousepad.getShowKeyboard(),
        options: []
      });
    } else if (this.pluginKey === PLUGIN_DIGITIZER) {
      list.push({
        kind: 'switch', rowKey: 'hide_draw_button',
        title: $r('app.string.digitizer_pref_hide_draw_button_title'),
        summary: $r('app.string.digitizer_pref_hide_draw_button_summary'),
        switchOn: store.getDigitizerHideDrawButton(this.deviceId),
        options: []
      });
      list.push({
        kind: 'list', rowKey: 'draw_button_side',
        title: $r('app.string.digitizer_pref_draw_button_side_title'),
        summary: this.optionLabel(DIGITIZER_SIDE_OPTIONS, store.getDigitizerDrawButtonSide(this.deviceId)),
        switchOn: false,
        options: DIGITIZER_SIDE_OPTIONS
      });
    } else if (this.pluginKey === PLUGIN_SHARE) {
      list.push({
        kind: 'switch', rowKey: 'custom_destination',
        title: $r('app.string.share_destination_customize'),
        summary: $r('app.string.share_destination_customize_summary'),
        switchOn: store.getShareCustomDestination(this.deviceId),
        options: []
      });
      list.push({
        kind: 'folder', rowKey: 'destination_folder',
        title: $r('app.string.share_destination_folder'),
        summary: store.getShareDestinationDir(this.deviceId),
        switchOn: false,
        options: []
      });
      list.push({
        kind: 'switch', rowKey: 'share_notification',
        title: $r('app.string.share_notification_preference'),
        summary: $r('app.string.share_notification_preference_summary'),
        switchOn: store.getShareNotification(this.deviceId),
        options: []
      });
    } else if (this.pluginKey === PLUGIN_FIND_MY_PHONE) {
      list.push({
        kind: 'switch', rowKey: 'sound',
        title: $r('app.string.findmyphone_sound_title'),
        summary: '',
        switchOn: store.getFindMyPhoneSound(this.deviceId),
        options: []
      });
      list.push({
        kind: 'switch', rowKey: 'flashlight',
        title: $r('app.string.findmyphone_flashlight_title'),
        summary: $r('app.string.findmyphone_camera_explanation'),
        switchOn: store.getFindMyPhoneFlashlight(this.deviceId),
        options: []
      });
    } else if (this.pluginKey === PLUGIN_MPRIS) {
      list.push({
        kind: 'list', rowKey: 'mpris_time',
        title: $r('app.string.mpris_time_settings_title'),
        summary: this.optionLabel(MPRIS_TIME_OPTIONS, String(store.getMprisTimeSeconds(this.deviceId))),
        switchOn: false,
        options: MPRIS_TIME_OPTIONS
      });
      list.push({
        kind: 'switch', rowKey: 'mpris_notification',
        title: $r('app.string.mpris_notification_settings_title'),
        summary: $r('app.string.mpris_notification_settings_summary'),
        switchOn: store.getMprisNotification(this.deviceId),
        options: []
      });
      list.push({
        kind: 'switch', rowKey: 'mpris_keepwatching',
        title: $r('app.string.mpris_keepwatching_settings_title'),
        summary: $r('app.string.mpris_keepwatching_settings_summary'),
        switchOn: store.getMprisKeepWatching(this.deviceId),
        options: []
      });
    }

    this.rows = list;
  }

  private onToggle(row: SubPrefRow, value: boolean): void {
    const store = PluginPrefsStore.getInstance();
    const mousepad = RemoteInputSettingsStore.getInstance();
    if (this.pluginKey === PLUGIN_RUNCOMMAND && row.rowKey === 'name_as_title') {
      store.setRunCommandNameAsTitle(this.deviceId, value);
    } else if (this.pluginKey === PLUGIN_REMOTE_INPUT) {
      if (row.rowKey === 'scroll_dir') {
        mousepad.setScrollDirectionReversed(value);
      } else if (row.rowKey === 'mouse_buttons') {
        mousepad.setMouseButtonsEnabled(value);
      } else if (row.rowKey === 'doubletap_drag') {
        mousepad.setDoubleTapDragEnabled(value);
      } else if (row.rowKey === 'show_keyboard') {
        mousepad.setShowKeyboard(value);
      }
    } else if (this.pluginKey === PLUGIN_DIGITIZER && row.rowKey === 'hide_draw_button') {
      store.setDigitizerHideDrawButton(this.deviceId, value);
    } else if (this.pluginKey === PLUGIN_SHARE) {
      if (row.rowKey === 'custom_destination') {
        store.setShareCustomDestination(this.deviceId, value);
      } else if (row.rowKey === 'share_notification') {
        store.setShareNotification(this.deviceId, value);
      }
    } else if (this.pluginKey === PLUGIN_FIND_MY_PHONE) {
      if (row.rowKey === 'sound') {
        store.setFindMyPhoneSound(this.deviceId, value);
      } else if (row.rowKey === 'flashlight') {
        store.setFindMyPhoneFlashlight(this.deviceId, value);
      }
    } else if (this.pluginKey === PLUGIN_MPRIS) {
      if (row.rowKey === 'mpris_notification') {
        store.setMprisNotification(this.deviceId, value);
        // Apply immediately: hide/show the lock-screen / status-bar media card.
        AppSession.getInstance().getService().getClientForDevice(this.deviceId)
          ?.refreshRemoteMediaSession();
      } else if (row.rowKey === 'mpris_keepwatching') {
        store.setMprisKeepWatching(this.deviceId, value);
      }
    }
    this.buildRows();
  }

  private onPickList(row: SubPrefRow, value: string): void {
    const store = PluginPrefsStore.getInstance();
    const mousepad = RemoteInputSettingsStore.getInstance();
    if (this.pluginKey === PLUGIN_REMOTE_INPUT) {
      if (row.rowKey === 'single_tap') {
        mousepad.setSingleTapAction(value);
      } else if (row.rowKey === 'double_tap') {
        mousepad.setDoubleTapAction(value);
      } else if (row.rowKey === 'triple_tap') {
        mousepad.setTripleTapAction(value);
      } else if (row.rowKey === 'sensitivity') {
        mousepad.setSensitivity(value);
      } else if (row.rowKey === 'accel') {
        mousepad.setAccelerationProfile(value);
      } else if (row.rowKey === 'scroll_sens') {
        mousepad.setScrollSensitivity(parseInt(value, 10));
      }
    } else if (this.pluginKey === PLUGIN_DIGITIZER && row.rowKey === 'draw_button_side') {
      store.setDigitizerDrawButtonSide(this.deviceId, value);
    } else if (this.pluginKey === PLUGIN_MPRIS && row.rowKey === 'mpris_time') {
      store.setMprisTimeSeconds(this.deviceId, parseInt(value, 10));
    }
    this.buildRows();
  }

  private onPickFolder(row: SubPrefRow): void {
    const ctx: common.UIAbilityContext | undefined = hostContext(this.getUIContext());
    if (!ctx) {
      return;
    }
    try {
      // Android ListPreference-style folder picker. FOLDER selection needs the
      // FolderSelection system capability (Phone: API 26+). Fall back to a
      // DOWNLOAD save otherwise so the row still works.
      const selectOpts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      selectOpts.selectMode = picker.DocumentSelectMode.FOLDER;
      const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(ctx);
      docPicker.select(selectOpts).then((uris: string[]) => {
        if (uris && uris.length > 0) {
          const dirUri: string = uris[0];
          const store = PluginPrefsStore.getInstance();
          store.persistAndActivateDir(dirUri).then((ok: boolean) => {
            if (ok) {
              store.setShareDestinationDir(this.deviceId, dirUri);
              this.buildRows();
            } else {
              this.showToast($r('app.string.subsettings_folder_persist_failed'));
            }
          });
        }
      }).catch((e: Error) => {
        console.warn('[PluginPrefs] folder select failed:', e.message);
        this.showToast($r('app.string.subsettings_folder_unavailable'));
      });
    } catch (e) {
      console.warn('[PluginPrefs] folder pick exception:', JSON.stringify(e));
      this.showToast($r('app.string.subsettings_folder_unavailable'));
    }
  }

  private showToast(msg: ResourceStr): void {
    this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1500 });
  }

  private onRowTap(row: SubPrefRow): void {
    if (row.kind === 'list') {
      this.pickerTitle = typeof row.title === 'string' ? row.title : '';
      this.pickerOptions = row.options;
      this.pickerSelected = typeof row.summary === 'string' ? row.summary : '';
      this.pendingPick = (value: string) => {
        this.onPickList(row, value);
      };
      this.pickerOpen = true;
    } else if (row.kind === 'folder') {
      this.onPickFolder(row);
    }
  }

  private openFolderLabel(row: SubPrefRow): ResourceStr {
    if (typeof row.summary === 'string' && row.summary.length > 0) {
      return row.summary;
    }
    return $r('app.string.subsettings_not_set');
  }

  @Builder
  PrefRowView(row: SubPrefRow) {
    Row() {
      Column() {
        Text(row.title)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(UiTheme.onSurface)
          .width('100%')
        if (row.kind === 'list' || row.kind === 'folder') {
          Text(row.kind === 'folder' ? this.openFolderLabel(row) : row.summary)
            .fontSize(13)
            .fontColor(UiTheme.onSurfaceVariant)
            .margin({ top: 4 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        } else if (typeof row.summary === 'object' && row.summary !== null) {
          Text(row.summary)
            .fontSize(13)
            .fontColor(UiTheme.onSurfaceVariant)
            .margin({ top: 4 })
            .width('100%')
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .padding({ right: 12 })

      if (row.kind === 'switch') {
        Toggle({ type: ToggleType.Switch, isOn: row.switchOn })
          .selectedColor(UiTheme.primary)
          .onChange((isOn: boolean) => {
            this.onToggle(row, isOn);
          })
      } else if (row.kind === 'list' || row.kind === 'folder') {
        KdeIcon({ symbol: KdeIconRes.chevronRight(), iconSize: 20, color: UiTheme.onSurfaceVariant })
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .margin({ left: 12, right: 12, top: 4, bottom: 4 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.onRowTap(row);
    })
  }

  build() {
    Column() {
      KdeTopBar({
        title: this.pageTitle.length > 0 ? this.pageTitle : $r('app.string.menu_plugin_settings'),
        showBack: true,
        onBack: () => {
          goBack(this.getUIContext());
        }
      })

      Scroll() {
        Column() {
          ForEach(this.rows, (row: SubPrefRow, index: number) => {
            this.PrefRowView(row)
          }, (row: SubPrefRow, index: number) => `${this.pluginKey}_${row.rowKey}_${index}`)

          Column().width('100%').height(24)
        }
        .width('100%')
        .padding({ top: 8, bottom: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)

      // ── Option picker dialog (Android ListPreference) ──
      if (this.pickerOpen) {
        Stack({ alignContent: Alignment.Center }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(UiTheme.scrim)
            .onClick(() => {
              this.pickerOpen = false;
            })
          Column({ space: 4 }) {
            Text(this.pickerTitle.length > 0 ? this.pickerTitle : '')
              .fontSize(18)
              .fontWeight(FontWeight.Medium)
              .fontColor(UiTheme.onSurface)
              .width('100%')
              .margin({ bottom: 8 })
            ForEach(this.pickerOptions, (opt: SubOption) => {
              Row() {
                Text(opt.label)
                  .fontSize(15)
                  .fontColor(UiTheme.onSurface)
                  .layoutWeight(1)
                if (opt.label === this.pickerSelected) {
                  KdeIcon({ symbol: KdeIconRes.check(), iconSize: 20, color: UiTheme.primary })
                }
              }
              .width('100%')
              .height(44)
              .borderRadius(UiTheme.radiusCard)
              .onClick(() => {
                this.pickerSelected = opt.label;
                this.pickerOpen = false;
                this.pendingPick(opt.value);
              })
            }, (opt: SubOption) => `${opt.value}`)
            Row({ space: 12 }) {
              Button($r('app.string.settings_cancel'))
                .layoutWeight(1)
                .height(44)
                .fontColor(UiTheme.onSurface)
                .backgroundColor(UiTheme.surfaceVariant)
                .borderRadius(UiTheme.radiusButton)
                .onClick(() => {
                  this.pickerOpen = false;
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
    }
    .width('100%')
    .height('100%')
    .backgroundColor(UiTheme.pageBg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
