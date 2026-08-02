import { common } from '@kit.AbilityKit';
import pasteboard from '@ohos.pasteboard';
import { fileIo, picker } from '@kit.CoreFileKit';
import { AppSession } from '../app/AppSession';
import { AppNotifier } from '../common/AppNotifier';
import { DeviceListItem, KdeStatus, ConnectionState, FileSendInfo, PairUiState } from '../service/KdeTypes';
import { BatteryHelper } from '../common/BatteryHelper';
import {
  DeviceDetailRouteParams,
  goBack,
  hostContext,
  pushPage,
  routeParams
} from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeIcon, KdeIconRes } from '../common/ui/KdeIcons';
import { KdeTopBar, KdePrimaryButton } from '../common/ui/KdeWidgets';
import { FileSendJob } from '../service/FileSendJob';
import {
  PLUGIN_CLIPBOARD,
  PLUGIN_FIND_MY_PHONE,
  PLUGIN_MPRIS,
  PLUGIN_PING,
  PLUGIN_REMOTE_INPUT,
  PLUGIN_RUNCOMMAND,
  PLUGIN_SHARE,
  PLUGIN_PERMISSION_DEFS,
  isUiButtonForPeer,
  peerSupportsRingMenu,
  pluginKeyForUiButton
} from '../service/PluginRegistry';
import { PluginSettingsStore } from '../store/PluginSettingsStore';
import { isPermissionGranted, requestPermission, PERMISSION_CAMERA } from '../common/AppPermission';

interface DeviceDetailParams {
  deviceId: string;
  /** Notification / deep-link actions: sendFile | sendClipboard */
  action?: string;
}

/** Plugin button definition — matches Android Plugin.PluginUiButton */
interface PluginButton {
  label: ResourceStr;
  symbol: Resource;
  disabled: boolean;
  onTap?: () => void;
  pluginKey?: string;
}

/** Enabled plugin missing a runtime permission (Android PluginsWithoutPermissions row). */
interface PermissionPluginRow {
  pluginKey: string;
  label: ResourceStr;
  explanation: ResourceStr;
}

/** Params for PluginSettings page */
interface PluginSettingsParams {
  deviceId: string;
  deviceName: string;
}

@Entry
@Component
struct DeviceDetail {

  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State deviceId: string = '';
  @State item: DeviceListItem | null = null;
  @State statusText: string = '';
  @State statusState: ConnectionState = 'idle';
  @State busy: boolean = false;
  @State toastHint: ResourceStr = '';
  @State toastVisible: boolean = false;
  // Overflow menu
  @State menuOpen: boolean = false;
  @State menuScale: number = 0.9;
  @State menuOpacity: number = 0;
  // Dialogs
  @State showEncryptionDialog: boolean = false;
  @State myFingerprint: string = '';
  @State remoteFingerprint: string = '';
  @State showPasteOverlay: boolean = false;
  // File send
  @State fileSending: boolean = false;
  @State fileProgress: number = 0;
  @State fileProgressLabel: string = '';
  /** Current send job so the inline card can cancel it (Android notification cancel). */
  private activeSendJob: FileSendJob | null = null;
  /** Bumps when plugin enable state changes so the grid refreshes. */
  @State pluginRev: number = 0;
  @State visiblePluginBtns: PluginButton[] = [];
  /** Enabled plugins missing a runtime permission (Android pluginsNeedPermissions). */
  @State needsPermissionPlugins: PermissionPluginRow[] = [];
  // Permission explanation dialog (Android PermissionsAlertDialogFragment)
  @State showPermissionDialog: boolean = false;
  @State permissionDialogTitle: ResourceStr = '';
  @State permissionDialogMessage: ResourceStr = '';
  private grantingPermission: boolean = false;
  /** Live pairing state (Android PairingHandler.PairState). */
  @State pairState: PairUiState = 'not_paired';
  private autoConnectTried: boolean = false;

  private deviceSubId: number = -1;
  private statusSubId: number = -1;
  private pluginSubId: number = -1;
  private session: AppSession = AppSession.getInstance();

  // ── Plugin button catalog (Android getUiButtons per loaded plugin) ──
  // Common (phone + desktop): send files / multimedia / clipboard
  // Desktop-oriented (hidden for phone peers): remote input / run command /
  // presentation / drawing — Android Presenter isCompatible + capability load
  // disabled=true → not implemented (coming soon); user-disabled plugins hidden
  private allPluginBtns: PluginButton[] = [
    { label: $r('app.string.plugin_send_files'), symbol: KdeIconRes.fileUpload(), disabled: false, onTap: () => { this.onSendFiles(); }, pluginKey: 'send_files' },
    { label: $r('app.string.plugin_multimedia_control'), symbol: KdeIconRes.music(), disabled: false, onTap: () => { this.openMpris(); }, pluginKey: 'multimedia' },
    { label: $r('app.string.plugin_remote_input'), symbol: KdeIconRes.touchpad(), disabled: false, onTap: () => { this.openRemoteInput(); }, pluginKey: 'remote_input' },
    { label: $r('app.string.plugin_run_command'), symbol: KdeIconRes.terminal(), disabled: false, onTap: () => { this.openRunCommand(); }, pluginKey: 'run_command' },
    { label: $r('app.string.plugin_presentation_remote'), symbol: KdeIconRes.slideshow(), disabled: false, onTap: () => { this.openPresentation(); }, pluginKey: 'presentation' },
    { label: $r('app.string.plugin_drawing_tablet'), symbol: KdeIconRes.draw(), disabled: false, onTap: () => { this.openDigitizer(); }, pluginKey: 'drawing' },
    { label: $r('app.string.plugin_send_clipboard'), symbol: KdeIconRes.contentPaste(), disabled: false, onTap: () => { this.trySendClipboard(); }, pluginKey: 'send_clipboard' },
  ];

  aboutToAppear() {
    this.session.attachUiContext(this.getUIContext());
    let params = routeParams(this.getUIContext()) as DeviceDetailParams;
    if (params && params.deviceId) {
      this.deviceId = params.deviceId;
    }
    let ctx: common.UIAbilityContext | undefined = hostContext(this.getUIContext());
    if (ctx) {
      this.session.ensureStarted(ctx).then(() => {
        return PluginSettingsStore.getInstance().ensureDeviceLoaded(this.deviceId);
      }).then(() => {
        this.refreshItem();
        this.refreshPluginButtons();
        this.applyStatus(this.session.getLastStatus());
        // Android: opening detail dismisses pairing notification
        AppNotifier.getInstance().cancelPairRequest();
        this.maybeAutoConnect();
        // Auto-trigger sendFile from notification action
        if (params && params.action) {
          setTimeout(() => { this.handleNotificationAction(params.action!); }, 500);
        }
      });
    } else {
      PluginSettingsStore.getInstance().ensureDeviceLoaded(this.deviceId).then(() => {
        this.refreshPluginButtons();
      });
    }
    this.ensureSubscriptions();
  }

  /** Handle notification / deep-link actions. */
  private handleNotificationAction(action: string): void {
    if (action === 'sendClipboard') {
      this.trySendClipboard();
      return;
    }
    if (action === 'sendFile') {
      this.onSendFiles();
    }
  }

  onPageShow() {
    this.session.attachUiContext(this.getUIContext());
    this.ensureSubscriptions();
    this.refreshItem();
    PluginSettingsStore.getInstance().ensureDeviceLoaded(this.deviceId).then(() => {
      this.refreshPluginButtons();
    });
    this.applyStatus(this.session.getLastStatus());
    AppNotifier.getInstance().cancelPairRequest();
    this.maybeAutoConnect();
  }

  aboutToDisappear() {
    this.clearSubscriptions();
  }

  private ensureSubscriptions(): void {
    if (this.deviceSubId < 0) {
      this.deviceSubId = this.session.subscribeDevices(() => {
        this.refreshItem();
        // If TLS just came up and we were waiting, stay on pairing UI until trusted
        this.refreshPairState();
      });
    }
    if (this.statusSubId < 0) {
      this.statusSubId = this.session.subscribeStatus((s: KdeStatus) => {
        this.applyStatus(s);
      });
    }
    if (this.pluginSubId < 0) {
      this.pluginSubId = PluginSettingsStore.getInstance().subscribe(() => {
        this.refreshPluginButtons();
      });
    }
  }

  private clearSubscriptions(): void {
    if (this.deviceSubId >= 0) {
      this.session.unsubscribeDevices(this.deviceSubId);
      this.deviceSubId = -1;
    }
    if (this.statusSubId >= 0) {
      this.session.unsubscribeStatus(this.statusSubId);
      this.statusSubId = -1;
    }
    if (this.pluginSubId >= 0) {
      PluginSettingsStore.getInstance().unsubscribe(this.pluginSubId);
      this.pluginSubId = -1;
    }
  }

  /**
   * Android: only loadedPlugins contribute getUiButtons().
   * Filter by (1) peer capabilities + deviceType (pluginsForCapabilities / isCompatible)
   * (2) user-disabled plugin prefs.
   */
  private refreshPluginButtons(): void {
    const store = PluginSettingsStore.getInstance();
    const peerType: string = this.item !== null ? this.item.deviceType : 'desktop';
    const peerIn: string[] | undefined = this.item?.incomingCapabilities;
    const peerOut: string[] | undefined = this.item?.outgoingCapabilities;
    const out: PluginButton[] = [];
    for (let i = 0; i < this.allPluginBtns.length; i++) {
      const btn = this.allPluginBtns[i];
      const uiKey = btn.pluginKey ?? '';
      // Capability + deviceType gate (Android loadedPlugins)
      if (!isUiButtonForPeer(uiKey, peerType, peerIn, peerOut)) {
        continue;
      }
      const pluginKey = pluginKeyForUiButton(uiKey);
      if (pluginKey !== null && !store.isEnabled(this.deviceId, pluginKey)) {
        continue;
      }
      out.push(btn);
    }
    this.visiblePluginBtns = out;
    this.pluginRev = this.pluginRev + 1;
  }

  private pluginDisplayNameForKey(key: string): ResourceStr {
    if (key === PLUGIN_FIND_MY_PHONE) {
      return $r('app.string.pref_plugin_findmyphone');
    }
    return $r('app.string.menu_plugin_settings');
  }

  private permissionExplanationForKey(key: string): ResourceStr {
    if (key === PLUGIN_FIND_MY_PHONE) {
      return $r('app.string.permission_camera_reason');
    }
    return $r('app.string.permission_camera_reason');
  }

  /**
   * Android DeviceFragment: pluginsNeedPermissions =
   * device.pluginsWithoutPermissions.filter { isPluginEnabled }.
   * Here: enabled plugins whose user-grant permission is not granted.
   */
  private refreshPermissionPlugins(): void {
    const store = PluginSettingsStore.getInstance();
    const ctx = hostContext(this.getUIContext());
    const rows: PermissionPluginRow[] = [];
    for (let i = 0; i < PLUGIN_PERMISSION_DEFS.length; i++) {
      const def = PLUGIN_PERMISSION_DEFS[i];
      if (!store.isEnabled(this.deviceId, def.pluginKey)) {
        continue;
      }
      if (isPermissionGranted(ctx, def.permission)) {
        continue;
      }
      rows.push({
        pluginKey: def.pluginKey,
        label: this.pluginDisplayNameForKey(def.pluginKey),
        explanation: this.permissionExplanationForKey(def.pluginKey)
      });
    }
    this.needsPermissionPlugins = rows;
  }

  /** Android PermissionsAlertDialogFragment positive button → request permission. */
  private onGrantPermission(): void {
    if (this.grantingPermission) {
      return;
    }
    const ctx = hostContext(this.getUIContext());
    if (!ctx) {
      this.showPermissionDialog = false;
      return;
    }
    this.grantingPermission = true;
    requestPermission(ctx, PERMISSION_CAMERA).then((granted: boolean) => {
      this.grantingPermission = false;
      this.showPermissionDialog = false;
      if (granted) {
        this.refreshPermissionPlugins();
      }
    });
  }

  /** Android pairVerification — 8-char code during pairing. */
  private verificationKeyText(): string {
    if (!this.item || !this.item.verificationKey) {
      return '';
    }
    if (this.pairState !== 'requested' && this.pairState !== 'requested_by_peer') {
      return '';
    }
    return this.item.verificationKey;
  }

  private isPluginOn(pluginKey: string): boolean {
    return PluginSettingsStore.getInstance().isEnabled(this.deviceId, pluginKey);
  }

  private openPluginSettings(): void {
    this.closeMenu();
    const params: PluginSettingsParams = {
      deviceId: this.deviceId,
      deviceName: this.item !== null ? this.item.deviceName : ''
    };
    pushPage(this.getUIContext(), 'pages/PluginSettings', params);
  }

  private refreshItem(): void {
    if (this.deviceId.length === 0) {
      return;
    }
    let found = this.session.getService().getDeviceById(this.deviceId);
    this.item = found ?? null;
    this.refreshPairState();
    // deviceType / trust may arrive after first paint — re-filter plugin grid
    this.refreshPluginButtons();
    this.refreshPermissionPlugins();
  }

  private refreshPairState(): void {
    if (this.deviceId.length === 0) {
      this.pairState = 'not_paired';
      return;
    }
    const fromSession = this.session.getService().getPairStateFor(this.deviceId);
    if (this.item !== null && this.item.trusted) {
      this.pairState = 'paired';
      return;
    }
    // Prefer live session state; fall back to list field
    if (fromSession !== 'not_paired' || this.item?.sessionActive) {
      this.pairState = fromSession;
    } else if (this.item?.pairState) {
      this.pairState = this.item.pairState;
    } else {
      this.pairState = 'not_paired';
    }
  }

  private applyStatus(s: KdeStatus): void {
    if (s.peerDeviceId && s.peerDeviceId.length > 0 && this.deviceId.length > 0 &&
      s.peerDeviceId !== this.deviceId) {
      return;
    }
    this.statusState = s.state;
    this.statusText = s.message;
    this.refreshPairState();
  }

  /**
   * Android: discovery already has TLS (isReachable). Here we auto-start TLS
   * when opening detail so user only needs "Request pairing" (one-step feel).
   */
  private maybeAutoConnect(): void {
    if (this.autoConnectTried || !this.item) {
      return;
    }
    if (this.item.sessionActive || this.isConnecting()) {
      return;
    }
    // Need a known address to connect
    if (!this.item.online || this.item.ip.length === 0) {
      return;
    }
    this.autoConnectTried = true;
    this.session.getService().connectListItem(this.item);
  }

  // ── Actions ──────────────────────────────────────────────

  private onConnectOrPair(): void {
    if (!this.item) {
      return;
    }
    const svc = this.session.getService();
    // TLS live → request pairing (Android: only "Request pairing")
    if (this.item.sessionActive) {
      svc.requestPairingFor(this.item.deviceId);
    } else {
      this.autoConnectTried = true;
      svc.connectListItem(this.item);
    }
  }

  private onCancelPairing(): void {
    this.closeMenu();
    if (this.deviceId.length > 0) {
      this.session.getService().cancelPairingFor(this.deviceId);
    }
    AppNotifier.getInstance().cancelPairRequest();
    this.refreshPairState();
  }

  private onAcceptPairing(): void {
    if (this.deviceId.length > 0) {
      this.session.getService().getClient().acceptPairingFor(this.deviceId);
    } else {
      this.session.getService().getClient().acceptPairing();
    }
    AppNotifier.getInstance().cancelPairRequest();
    this.refreshPairState();
  }

  private onRejectPairing(): void {
    if (this.deviceId.length > 0) {
      this.session.getService().getClient().rejectPairingFor(this.deviceId);
    } else {
      this.session.getService().getClient().rejectPairing();
    }
    AppNotifier.getInstance().cancelPairRequest();
    this.refreshPairState();
  }

  private onDisconnect(): void {
    this.closeMenu();
    if (this.deviceId.length > 0) {
      this.session.getService().disconnectDevice(this.deviceId);
    } else {
      this.session.getService().disconnect();
    }
  }

  private onUnpair(): void {
    if (!this.item) {
      return;
    }
    this.busy = true;
    this.closeMenu();
    this.session.getService().unpair(this.item.deviceId).then(() => {
      this.busy = false;
      goBack(this.getUIContext());
    }).catch(() => {
      this.busy = false;
    });
  }

  private onPing(): void {
    this.closeMenu();
    if (!this.isPluginOn(PLUGIN_PING)) {
      this.showToast($r('app.string.plugin_disabled_toast'));
      return;
    }
    if (this.deviceId.length > 0) {
      this.session.getService().sendPingTo(this.deviceId);
    } else {
      this.session.getService().sendPing();
    }
    this.showToast($r('app.string.toast_ping_sent'));
  }

  private onRing(): void {
    this.closeMenu();
    if (!this.isPluginOn(PLUGIN_FIND_MY_PHONE)) {
      this.showToast($r('app.string.plugin_disabled_toast'));
      return;
    }
    if (this.deviceId.length > 0) {
      this.session.getService().sendRingTo(this.deviceId);
    } else {
      this.session.getService().sendRing();
    }
  }

  private openMpris(): void {
    if (!this.isPluginOn(PLUGIN_MPRIS)) {
      this.showToast($r('app.string.plugin_disabled_toast'));
      return;
    }
    if (this.item) {
      const params: DeviceDetailRouteParams = { deviceId: this.item.deviceId };
      pushPage(this.getUIContext(), 'pages/MprisControl', params);
    }
  }

  /** Open the touchpad/keyboard page (Android MousePadActivity). */
  private openRemoteInput(): void {
    if (!this.isPluginOn(PLUGIN_REMOTE_INPUT)) {
      this.showToast($r('app.string.plugin_disabled_toast'));
      return;
    }
    if (this.item) {
      const params: DeviceDetailRouteParams = { deviceId: this.item.deviceId };
      pushPage(this.getUIContext(), 'pages/RemoteInput', params);
    }
  }

  /** Open the run-command page (Android RunCommandActivity). */
  private openRunCommand(): void {
    if (!this.isPluginOn(PLUGIN_RUNCOMMAND)) {
      this.showToast($r('app.string.plugin_disabled_toast'));
      return;
    }
    if (this.item) {
      const params: DeviceDetailRouteParams = { deviceId: this.item.deviceId };
      pushPage(this.getUIContext(), 'pages/RunCommand', params);
    }
  }

  /** Open the presentation-remote page (Android PresenterActivity). */
  private openPresentation(): void {
    if (this.item) {
      const params: DeviceDetailRouteParams = { deviceId: this.item.deviceId };
      pushPage(this.getUIContext(), 'pages/Presentation', params);
    }
  }

  /** Open the drawing-tablet page (Android DigitizerActivity). */
  private openDigitizer(): void {
    if (this.item) {
      const params: DeviceDetailRouteParams = { deviceId: this.item.deviceId };
      pushPage(this.getUIContext(), 'pages/Digitizer', params);
    }
  }

  private async onSendFiles(): Promise<void> {
    if (!this.isPluginOn(PLUGIN_SHARE)) {
      this.showToast($r('app.string.plugin_disabled_toast'));
      return;
    }
    try {
      // ── Open DocumentViewPicker (multi-select, Android SendFileActivity ALLOW_MULTIPLE) ──
      const selectOpts: picker.DocumentSelectOptions = new picker.DocumentSelectOptions();
      selectOpts.maxSelectNumber = 500;
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const uris: string[] = await documentPicker.select(selectOpts);
      if (!uris || uris.length === 0) {
        return;
      }

      // ── Read file metadata ──
      const fileInfos: FileSendInfo[] = [];
      for (const uri of uris) {
        try {
          const stat = fileIo.statSync(uri);
          const segments = uri.split('/');
          const displayName = segments[segments.length - 1] || 'unknown';
          fileInfos.push({
            uri: uri,
            displayName: displayName,
            size: stat.size,
            lastModified: Math.floor(stat.mtime)
          });
        } catch (e) {
          console.error('[DeviceDetail] stat file failed:', JSON.stringify(e));
          this.showToast('无法读取文件信息');
          return;
        }
      }

      if (fileInfos.length === 0) {
        return;
      }

      // ── Build job (bound to this device session) ──
      const job: FileSendJob = this.deviceId.length > 0
        ? this.session.getService().createFileSendJobFor(this.deviceId)
        : this.session.getService().createFileSendJob();
      for (const info of fileInfos) {
        job.addFile(info);
      }
      this.activeSendJob = job;

      // ── Start sending with progress ──
      this.fileSending = true;
      this.fileProgress = 0;
      this.fileProgressLabel = fileInfos.length > 1
        ? `0 / ${fileInfos.length}`
        : fileInfos[0].displayName;

      await job.run((percent, fileName) => {
        this.fileProgress = percent;
        if (fileName.length > 0) {
          this.fileProgressLabel = fileName;
        }
      });

      // ── Done (cancel is a graceful stop, not an error) ──
      if (job.isCancelled) {
        this.showToast('已取消发送');
      } else {
        this.showToast($r('app.string.file_send_done'));
      }
    } catch (e) {
      console.error('[DeviceDetail] onSendFiles error:', JSON.stringify(e));
      this.showToast($r('app.string.file_send_failed'));
    } finally {
      this.activeSendJob = null;
      this.fileSending = false;
    }
  }

  /** Cancel the in-flight send (Android ShareBroadcastReceiver ACTION_CANCEL_SHARE). */
  private cancelSendFile(): void {
    if (this.activeSendJob) {
      this.activeSendJob.cancel();
      this.showToast('正在取消…');
    }
  }

  private onDisabledTap(): void {
    this.showToast($r('app.string.settings_coming_soon'));
  }

  private onEncryptionInfo(): void {
    this.closeMenu();
    this.myFingerprint = '';
    this.remoteFingerprint = '';
    this.showEncryptionDialog = true;
    // Android: SslHelper.getCertificateHash for both certs.
    const session = this.session.getService().getClientForDevice(this.deviceId);
    if (session) {
      session.myCertificateFingerprint().then((fp: string) => {
        this.myFingerprint = fp;
      });
      session.remoteCertificateFingerprint().then((fp: string) => {
        this.remoteFingerprint = fp;
      });
    }
  }

  private trySendClipboard(): void {
    this.closeMenu();
    if (!this.isPluginOn(PLUGIN_CLIPBOARD)) {
      this.showToast($r('app.string.plugin_disabled_toast'));
      return;
    }
    this.showPasteOverlay = true;
  }

  private showToast(msg: ResourceStr): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: msg, duration: 1500 });
    } catch (_e) {
      this.toastHint = msg;
      this.toastVisible = true;
      setTimeout(() => {
        this.toastVisible = false;
      }, 1500);
    }
  }

  // ── UI helpers ───────────────────────────────────────────

  /**
   * Android DeviceFragment.displayBatteryInfoIfPossible:
   * subtitle only when peer actually sent kdeconnect.battery (remoteBatteryInfo != null).
   * PC rarely reports battery → no subtitle (not "电量：-").
   */
  private toolbarSubtitle(): ResourceStr {
    if (!this.item || !this.item.peerBattery) {
      return '';
    }
    return BatteryHelper.formatLabel(
      this.item.peerBattery.currentCharge,
      this.item.peerBattery.isCharging
    );
  }

  private isPairingUi(): boolean {
    // Hide pairing once session reports paired (trust persist may lag one frame)
    return this.item !== null && !this.item.trusted && this.pairState !== 'paired';
  }

  private isUnreachableUi(): boolean {
    return this.item !== null &&
      (this.item.trusted || this.pairState === 'paired') &&
      !this.item.online && !this.item.sessionActive;
  }

  private isPluginsUi(): boolean {
    return this.item !== null &&
      (this.item.trusted || this.pairState === 'paired') &&
      (this.item.online || this.item.sessionActive);
  }

  private isConnecting(): boolean {
    return this.statusState === 'connecting' || this.statusState === 'tls_handshake';
  }

  private hasError(): boolean {
    return this.statusState === 'error' && this.statusText.length > 0;
  }

  // ── Overflow menu ────────────────────────────────────────

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

  @Builder
  MenuItem(label: ResourceStr, onClick: () => void, danger: boolean = false, disabled: boolean = false) {
    Text(label)
      .fontSize(16)
      .fontColor(danger ? UiTheme.danger : (disabled ? UiTheme.textMuted : UiTheme.onSurface))
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
        // Trusted + online: plugin menu entries (Android getUiMenuEntries)
        if (this.item !== null && this.item.trusted && this.item.sessionActive) {
          if (this.isPluginOn(PLUGIN_CLIPBOARD)) {
            this.MenuItem($r('app.string.plugin_send_clipboard'), () => {
              this.trySendClipboard();
            }, false, false)
          }
          if (this.isPluginOn(PLUGIN_PING)) {
            this.MenuItem($r('app.string.menu_send_ping'), () => {
              this.onPing();
            }, false, false)
          }
          // Ring = FindRemoteDevice (capability or phone/tablet/TV fallback)
          if (this.isPluginOn(PLUGIN_FIND_MY_PHONE) &&
            peerSupportsRingMenu(this.item.deviceType, this.item.incomingCapabilities)) {
            this.MenuItem($r('app.string.menu_ring'), () => {
              this.onRing();
            }, false, false)
          }
          Divider().color(UiTheme.divider).width('100%')
          this.MenuItem($r('app.string.menu_plugin_settings'), () => {
            this.openPluginSettings();
          }, false, false)
        }

        // Encryption when TLS is live (Android: reachable)
        if (this.item !== null && this.item.sessionActive) {
          this.MenuItem($r('app.string.menu_encryption_info'), () => {
            this.onEncryptionInfo();
          }, false, false)
        }

        // Cancel in-flight pairing (Android: cancel_pairing)
        if (this.pairState === 'requested' || this.pairState === 'requested_by_peer') {
          this.MenuItem($r('app.string.cancel_pairing'), () => {
            this.onCancelPairing();
          }, false, false)
        }

        // Unpair only when trusted (Android)
        if (this.item !== null && this.item.trusted) {
          Divider().color(UiTheme.divider).width('100%')
          this.MenuItem($r('app.string.menu_unpair'), () => {
            this.onUnpair();
          }, true, false)
        }
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

  // ── Pairing panel (Android DevicePairingScreen / view_pair_request) ──

  private pairingTitle(): ResourceStr {
    if (this.pairState === 'requested') {
      return $r('app.string.pairing_requested_title');
    }
    if (this.pairState === 'requested_by_peer') {
      return $r('app.string.pairing_requested_by_peer_title');
    }
    return $r('app.string.pairing_not_paired_title');
  }

  @Builder
  PairingPanel() {
    Column() {
      // Title reflects pair state (Android: pair_message)
      Text(this.pairingTitle())
        .fontSize(UiTheme.titleMd)
        .fontWeight(FontWeight.Medium)
        .fontColor(UiTheme.onSurface)
        .width('100%')
        .margin({ bottom: 8 })

      Text($r('app.string.pairing_explanation'))
        .fontSize(UiTheme.bodyMd)
        .fontColor(UiTheme.onSurfaceVariant)
        .width('100%')
        .margin({ bottom: 16 })

      // ── Pairing verification key (Android pairVerification) ──
      if (this.verificationKeyText().length > 0) {
        Text($r('app.string.pairing_verification_label'))
          .fontSize(13)
          .fontColor(UiTheme.onSurfaceVariant)
          .width('100%')
          .margin({ bottom: 6 })
        Text(this.verificationKeyText())
          .fontSize(28)
          .fontWeight(FontWeight.Bold)
          .fontColor(UiTheme.primary)
          .letterSpacing(4)
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ bottom: 16 })
      }

      // ── TLS connecting (before link is up) ──
      if (this.isConnecting() && this.pairState === 'not_paired') {
        Row() {
          KdeIcon({ symbol: KdeIconRes.key(), iconSize: 20, color: UiTheme.iconTint })
          Text(this.statusText.length > 0 ? this.statusText : $r('app.string.pairing_connecting'))
            .fontSize(14)
            .fontColor(UiTheme.primary)
            .margin({ left: 8 })
            .layoutWeight(1)
        }
        .width('100%')
        .margin({ bottom: 12 })

        LoadingProgress()
          .width(36)
          .height(36)
          .color(UiTheme.primary)
          .margin({ bottom: 16 })
      }

      // ── Requested: waiting for peer (Android PairState.Requested) ──
      if (this.pairState === 'requested') {
        Text($r('app.string.pairing_waiting_peer'))
          .fontSize(14)
          .fontColor(UiTheme.onSurfaceVariant)
          .width('100%')
          .margin({ bottom: 12 })

        LoadingProgress()
          .width(36)
          .height(36)
          .color(UiTheme.primary)
          .margin({ bottom: 16 })

        KdePrimaryButton({
          label: $r('app.string.cancel_pairing'),
          onTap: () => {
            this.onCancelPairing();
          }
        })
      }

      // ── RequestedByPeer: accept / reject only ──
      if (this.pairState === 'requested_by_peer') {
        Row({ space: 8 }) {
          Button($r('app.string.pairing_accept'))
            .layoutWeight(1)
            .height(48)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .backgroundColor(UiTheme.primary)
            .borderRadius(UiTheme.radiusButton)
            .onClick(() => {
              this.onAcceptPairing();
            })
          Button($r('app.string.pairing_reject'))
            .layoutWeight(1)
            .height(48)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(UiTheme.onSurface)
            .backgroundColor(UiTheme.surfaceVariant)
            .borderRadius(UiTheme.radiusButton)
            .onClick(() => {
              this.onRejectPairing();
            })
        }
        .width('100%')
        .margin({ top: 4 })
      }

      // ── NotPaired: single primary action (auto-connect + request pair) ──
      if (this.pairState === 'not_paired' && !this.isConnecting()) {
        if (this.hasError()) {
          Text(this.statusText)
            .fontSize(13)
            .fontColor(UiTheme.danger)
            .width('100%')
            .margin({ bottom: 12 })
        }
        KdePrimaryButton({
          // Android has only "Request pairing"; show Connect only if TLS not up yet
          label: this.item?.sessionActive
            ? $r('app.string.pairing_request_button')
            : $r('app.string.plugins_connect_button'),
          isEnabled: true,
          onTap: () => {
            this.onConnectOrPair();
          }
        })
      }
    }
    .width('100%')
    .padding(16)
    .alignItems(HorizontalAlign.Start)
  }

  // ── Unreachable panel (Android view_pair_error.xml) ──────

  @Builder
  UnreachablePanel() {
    Column() {
      Row() {
        KdeIcon({
          symbol: KdeIconRes.errorOutline(),
          iconSize: 48,
          color: UiTheme.iconTint
        })
          .margin({ right: 12 })
        Text($r('app.string.unreachable_message'))
          .fontSize(15)
          .fontColor(UiTheme.onSurface)
          .layoutWeight(1)
      }
      .width('100%')
      .padding(24)
      .alignItems(VerticalAlign.Center)
      .layoutWeight(1)

      Column() {
        KdePrimaryButton({
          label: $r('app.string.unreachable_refresh'),
          onTap: () => {
            this.session.getService().forceRefresh();
          }
        })
      }
      .width('80%')
      .margin({ bottom: 40 })
    }
    .width('100%')
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  // ── Plugins screen (Android PluginsScreen Compose) ───────

  @Builder
  FileSendProgress() {
    Column() {
      KdeIcon({
        symbol: KdeIconRes.fileUpload(),
        iconSize: 28,
        color: UiTheme.primary
      })
        .margin({ top: 12 })

      Text(this.fileProgressLabel)
        .fontSize(13)
        .fontColor(UiTheme.onSurface)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: 8, bottom: 6 })

      Progress({ value: this.fileProgress, total: 100, type: ProgressType.Linear })
        .width('100%')
        .height(4)
        .color(UiTheme.primary)
        .backgroundColor(UiTheme.surfaceVariant)
        .margin({ bottom: 10 })

      Row() {
        Text(`${this.fileProgress}%`)
          .fontSize(12)
          .fontColor(UiTheme.textMuted)
          .layoutWeight(1)
        Button('取消')
          .height(28)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor(UiTheme.danger)
          .backgroundColor(UiTheme.surfaceVariant)
          .borderRadius(14)
          .padding({ left: 14, right: 14 })
          .onClick(() => {
            this.cancelSendFile();
          })
      }
      .width('100%')
      .margin({ bottom: 10 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .shadow({
      radius: 2,
      color: '#1A000000',
      offsetX: 0,
      offsetY: 1
    })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      // No-op during sending — prevent accidental cancel
    })
  }

  @Builder
  PluginCard(btn: PluginButton) {
    // Show progress card when file sending is active for the share plugin
    if (this.fileSending && btn.pluginKey === 'send_files') {
      this.FileSendProgress()
    } else {
    Column() {
      KdeIcon({
        symbol: btn.symbol,
        iconSize: 28,
        color: btn.disabled ? UiTheme.textMuted : UiTheme.iconTint
      })
        .margin({ top: 12 })
        .opacity(btn.disabled ? 0.4 : 1)

      Text(btn.label)
        .fontSize(18)
        .fontColor(btn.disabled ? UiTheme.textMuted : UiTheme.onSurface)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .height(44)
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: 10 })
        .opacity(btn.disabled ? 0.4 : 1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .shadow({
      radius: 2,
      color: '#1A000000',
      offsetX: 0,
      offsetY: 1
    })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      if (btn.disabled) {
        this.onDisabledTap();
      } else if (btn.onTap) {
        btn.onTap();
      }
    })
    }
  }

  @Builder
  PluginGrid() {
    Column() {
      ForEach(this.visiblePluginBtns, (btn: PluginButton, index: number) => {
        if (index % 2 === 0) {
          Row({ space: 8 }) {
            Column() {
              this.PluginCard(btn)
            }
            .layoutWeight(1)

            if (index + 1 < this.visiblePluginBtns.length) {
              Column() {
                this.PluginCard(this.visiblePluginBtns[index + 1])
              }
              .layoutWeight(1)
            } else {
              Column().layoutWeight(1)
            }
          }
          .width('100%')
          .padding({ bottom: 8 })
        }
      }, (btn: PluginButton, index: number) => `pb_${this.pluginRev}_${btn.pluginKey ?? index}`)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8 })
  }

  /** Android PluginsWithoutPermissions: tappable plugin row (indent 28.dp). */
  @Builder
  PermissionPluginRowItem(row: PermissionPluginRow) {
    Row() {
      Text(row.label)
        .fontSize(14)
        .fontColor(UiTheme.onSurface)
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 28, right: 16, top: 12, bottom: 12 })
    .onClick(() => {
      this.permissionDialogTitle = row.label;
      this.permissionDialogMessage = row.explanation;
      this.showPermissionDialog = true;
    })
  }

  @Builder
  PluginsPanel() {
    Column() {
      // ── Status banner ──
      if (this.hasError() || (this.isConnecting() && this.statusText.length > 0)) {
        Text(this.statusText)
          .fontSize(13)
          .fontColor(this.hasError() ? UiTheme.danger : UiTheme.primary)
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 4 })
      }      if (this.item !== null && this.item.sessionActive) {
        // ── Plugin buttons grid ──
        this.PluginGrid()

        // ── Plugins needing permissions (Android PluginsWithoutPermissions) ──
        if (this.needsPermissionPlugins.length > 0) {
          Text($r('app.string.plugins_permission_needed'))
            .fontSize(12)
            .fontColor(UiTheme.textMuted)
            .width('100%')
            .padding({ left: 16, right: 16, top: 16, bottom: 4 })

          ForEach(this.needsPermissionPlugins, (row: PermissionPluginRow) => {
            this.PermissionPluginRowItem(row)
          }, (row: PermissionPluginRow) => `pp_${row.pluginKey}`)
        }
      } else if (this.item !== null && this.item.online) {
        // ── Online but not session-active ──
        Row({ space: 8 }) {
          Column() {
            KdePrimaryButton({
              label: $r('app.string.plugins_connect_button'),
              isEnabled: true,
              onTap: () => {
                this.onConnectOrPair();
              }
            })
          }
          .layoutWeight(1)
          Column().layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8 })
      }
    }
    .width('100%')
    .padding({ top: 8, bottom: 24 })
    .alignItems(HorizontalAlign.Start)
  }

  // ── Encryption info dialog (Android MaterialAlertDialogBuilder) ──

  @Builder
  EncryptionDialog() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#33000000')
      .onClick(() => {
        this.showEncryptionDialog = false;
      })

    Column() {
      Text($r('app.string.menu_encryption_info'))
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(UiTheme.onSurface)
        .width('100%')
        .margin({ bottom: 16 })

      // My device fingerprint
      Text($r('app.string.encryption_my_fingerprint_label'))
        .fontSize(13)
        .fontColor(UiTheme.textMuted)
        .width('100%')
        .margin({ bottom: 4 })
      Text(this.myFingerprint.length > 0 ? this.myFingerprint : $r('app.string.encryption_cert_unavailable'))
        .fontSize(12)
        .fontColor(this.myFingerprint.length > 0 ? UiTheme.onSurface : UiTheme.outline)
        .width('100%')
        .margin({ bottom: 12 })

      Divider().color(UiTheme.divider).width('100%').margin({ bottom: 12 })

      // Remote device fingerprint
      Text($r('app.string.encryption_remote_fingerprint_label'))
        .fontSize(13)
        .fontColor(UiTheme.textMuted)
        .width('100%')
        .margin({ bottom: 4 })
      Text(this.remoteFingerprint.length > 0 ? this.remoteFingerprint : $r('app.string.encryption_not_connected'))
        .fontSize(12)
        .fontColor(this.remoteFingerprint.length > 0 ? UiTheme.onSurface : UiTheme.outline)
        .width('100%')
        .margin({ bottom: 12 })

      Divider().color(UiTheme.divider).width('100%').margin({ bottom: 12 })

      // Protocol version
      Row() {
        Text($r('app.string.encryption_protocol_version_label'))
          .fontSize(13)
          .fontColor(UiTheme.textMuted)
          .width(120)
        Text(this.item !== null ? String(this.item.protocolVersion) : '—')
          .fontSize(13)
          .fontColor(UiTheme.onSurface)
      }
      .width('100%')
      .margin({ bottom: 20 })

      KdePrimaryButton({
        label: $r('app.string.encryption_ok'),
        isEnabled: true,
        onTap: () => {
          this.showEncryptionDialog = false;
        }
      })
    }
    .width('90%')
    .constraintSize({ maxWidth: 360 })
    .padding(24)
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 8 })
    .alignItems(HorizontalAlign.Start)
  }

  // ── Permission explanation dialog (Android PermissionsAlertDialogFragment) ──

  @Builder
  PermissionDialog() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#33000000')
      .onClick(() => {
        this.showPermissionDialog = false;
      })

    Column({ space: 12 }) {
      Text(this.permissionDialogTitle)
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(UiTheme.onSurface)
        .width('100%')

      Text(this.permissionDialogMessage)
        .fontSize(14)
        .fontColor(UiTheme.textMuted)
        .width('100%')

      Row({ space: 12 }) {
        Button($r('app.string.settings_cancel'))
          .layoutWeight(1)
          .height(44)
          .fontColor(UiTheme.onSurface)
          .backgroundColor(UiTheme.surfaceVariant)
          .borderRadius(UiTheme.radiusButton)
          .onClick(() => {
            this.showPermissionDialog = false;
          })
        Button($r('app.string.ok'))
          .layoutWeight(1)
          .height(44)
          .fontColor(UiTheme.onPrimary)
          .backgroundColor(UiTheme.primary)
          .borderRadius(UiTheme.radiusButton)
          .onClick(() => {
            this.onGrantPermission();
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

  // ── Paste overlay (system PasteButton for clipboard access) ──

  @Builder
  PasteOverlay() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor('#33000000')
      .onClick(() => {
        this.showPasteOverlay = false;
      })

    Column() {
      Text('发送剪贴板')
        .fontSize(18)
        .fontWeight(FontWeight.Medium)
        .fontColor(UiTheme.onSurface)
        .width('100%')
        .margin({ bottom: 16 })

      Text('请点击下方按钮读取剪贴板并发送')
        .fontSize(14)
        .fontColor(UiTheme.textMuted)
        .margin({ bottom: 20 })

      PasteButton()
        .padding({ top: 12, bottom: 12, left: 24, right: 24 })
        .onClick((event: ClickEvent, result: number) => {
          // PasteButton grants temporary pasteboard access on SUCCESS (result === 0).
          // Do not declare ohos.permission.READ_PASTEBOARD — restricted, install fails (9568289).
          if (result === 0) {
            try {
              pasteboard.getSystemPasteboard().getData((err: Error, pasteData: pasteboard.PasteData) => {
                if (err) {
                  console.error('[DeviceDetail] paste error:', err.message);
                  this.showPasteOverlay = false;
                  return;
                }
                try {
                  const text = pasteData.getPrimaryText();
                  if (text && text.trim().length > 0) {
                    if (this.deviceId.length > 0) {
                      this.session.getService().sendClipboardTextTo(this.deviceId, text.trim());
                    } else {
                      this.session.getService().sendClipboardText(text.trim());
                    }
                    this.showToast($r('app.string.clipboard_send_toast'));
                  }
                } catch (textErr) {
                  console.error('[DeviceDetail] getPrimaryText failed:', JSON.stringify(textErr));
                }
                this.showPasteOverlay = false;
              });
            } catch (e) {
              console.error('[DeviceDetail] pasteboard getData failed:', JSON.stringify(e));
              this.showPasteOverlay = false;
            }
          }
        })
    }
    .width('90%')
    .constraintSize({ maxWidth: 360 })
    .padding(24)
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .shadow({ radius: 16, color: '#40000000', offsetX: 0, offsetY: 8 })
    .alignItems(HorizontalAlign.Center)
  }

  // ── Root ─────────────────────────────────────────────────

  build() {
    Stack() {
      Column() {
        KdeTopBar({
          title: this.item !== null ? this.item.deviceName : $r('app.string.device_detail_title'),
          subtitle: this.toolbarSubtitle(),
          showBack: true,
          // Overflow when trusted, mid-pairing, or TLS live (encryption info)
          showOverflow: this.item !== null && (
            this.item.trusted ||
            this.item.sessionActive ||
            this.pairState === 'requested' ||
            this.pairState === 'requested_by_peer'
          ),
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

        if (this.item === null) {
          Text($r('app.string.device_not_found'))
            .fontSize(15)
            .fontColor(UiTheme.textMuted)
            .margin(24)
        } else if (this.isPairingUi()) {
          this.PairingPanel()
        } else if (this.isUnreachableUi()) {
          this.UnreachablePanel()
        } else if (this.isPluginsUi()) {
          Scroll() {
            Column() {
              this.PluginsPanel()
              Column().width('100%').height(this.navBarHeight + 16)
            }
          }
          .layoutWeight(1)
          .align(Alignment.Top)
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        } else {
          this.PairingPanel()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(UiTheme.pageBg)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.menuOpen) {
        this.OverflowMenu()
      }

      if (this.showEncryptionDialog) {
        this.EncryptionDialog()
      }

      if (this.showPermissionDialog) {
        this.PermissionDialog()
      }

      if (this.showPasteOverlay) {
        this.PasteOverlay()
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
