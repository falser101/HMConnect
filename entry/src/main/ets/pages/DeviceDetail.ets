import { common } from '@kit.AbilityKit';
import pasteboard from '@ohos.pasteboard';
import { fileIo, picker } from '@kit.CoreFileKit';
import { AppSession } from '../app/AppSession';
import { AppNotifier } from '../common/AppNotifier';
import { DeviceListItem, KdeStatus, ConnectionState, FileSendInfo } from '../service/KdeTypes';
import { BatteryHelper } from '../common/BatteryHelper';
import { goBack, hostContext, routeParams } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeIcon, KdeIconRes } from '../common/ui/KdeIcons';
import { KdeTopBar, KdePrimaryButton } from '../common/ui/KdeWidgets';
import { FileSendJob } from '../service/FileSendJob';

interface DeviceDetailParams {
  deviceId: string;
  action?: string; // 'sendFile' from notification action
}

/** Plugin button definition — matches Android Plugin.PluginUiButton */
interface PluginButton {
  label: ResourceStr;
  symbol: Resource;
  disabled: boolean;
  onTap?: () => void;
  pluginKey?: string;
}

@Entry
@Component
struct DeviceDetail {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
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
  @State showPasteOverlay: boolean = false;
  // File send
  @State fileSending: boolean = false;
  @State fileProgress: number = 0;
  @State fileProgressLabel: string = '';

  private deviceSubId: number = -1;
  private statusSubId: number = -1;
  private session: AppSession = AppSession.getInstance();

  // ── Plugin button definitions (matches Android getUiButtons) ──
  // disabled=true → grayed out, tap shows "coming soon" toast
  private pluginBtns: PluginButton[] = [
    { label: $r('app.string.plugin_send_files'), symbol: KdeIconRes.fileUpload(), disabled: false, onTap: () => { this.onSendFiles(); }, pluginKey: 'send_files' },
    { label: $r('app.string.plugin_multimedia_control'), symbol: KdeIconRes.music(), disabled: true, pluginKey: 'multimedia' },
    { label: $r('app.string.plugin_remote_input'), symbol: KdeIconRes.touchpad(), disabled: true, pluginKey: 'remote_input' },
    { label: $r('app.string.plugin_run_command'), symbol: KdeIconRes.terminal(), disabled: true, pluginKey: 'run_command' },
    { label: $r('app.string.plugin_presentation_remote'), symbol: KdeIconRes.slideshow(), disabled: true, pluginKey: 'presentation' },
    { label: $r('app.string.plugin_drawing_tablet'), symbol: KdeIconRes.draw(), disabled: true, pluginKey: 'drawing' },
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
        this.refreshItem();
        this.applyStatus(this.session.getLastStatus());
        // Auto-trigger sendFile from notification action
        if (params && params.action) {
          setTimeout(() => { this.handleNotificationAction(params.action!); }, 500);
        }
      });
    }
    this.ensureSubscriptions();
  }

  /** Handle notification action: send-file. */
  private handleNotificationAction(action: string): void {
    if (action === 'sendFile') {
      this.onSendFiles();
    }
  }

  onPageShow() {
    this.session.attachUiContext(this.getUIContext());
    this.ensureSubscriptions();
    this.refreshItem();
    this.applyStatus(this.session.getLastStatus());
  }

  aboutToDisappear() {
    this.clearSubscriptions();
  }

  private ensureSubscriptions(): void {
    if (this.deviceSubId < 0) {
      this.deviceSubId = this.session.subscribeDevices(() => {
        this.refreshItem();
      });
    }
    if (this.statusSubId < 0) {
      this.statusSubId = this.session.subscribeStatus((s: KdeStatus) => {
        this.applyStatus(s);
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
  }

  private refreshItem(): void {
    if (this.deviceId.length === 0) {
      return;
    }
    let found = this.session.getService().getDeviceById(this.deviceId);
    this.item = found ?? null;
  }

  private applyStatus(s: KdeStatus): void {
    if (s.peerDeviceId && s.peerDeviceId.length > 0 && this.deviceId.length > 0 &&
      s.peerDeviceId !== this.deviceId) {
      return;
    }
    this.statusState = s.state;
    this.statusText = s.message;
  }

  // ── Actions ──────────────────────────────────────────────

  private onConnectOrPair(): void {
    if (!this.item) {
      return;
    }
    const svc = this.session.getService();
    // If already connected (TLS live), request pairing instead of reconnecting
    if (this.item.sessionActive) {
      svc.requestPairing();
    } else {
      svc.connectListItem(this.item);
    }
  }

  private onDisconnect(): void {
    this.closeMenu();
    this.session.getService().disconnect();
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
    this.session.getService().sendPing();
    this.showToast($r('app.string.toast_ping_sent'));
  }

  private onRing(): void {
    this.closeMenu();
    this.session.getService().sendRing();
  }

  private async onSendFiles(): Promise<void> {
    try {
      // ── Open DocumentViewPicker ──
      const documentPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker();
      const uris: string[] = await documentPicker.select();
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

      // ── Build job ──
      const job: FileSendJob = this.session.getService().createFileSendJob();
      for (const info of fileInfos) {
        job.addFile(info);
      }

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

      // ── Done ──
      this.showToast($r('app.string.file_send_done'));
    } catch (e) {
      console.error('[DeviceDetail] onSendFiles error:', JSON.stringify(e));
      this.showToast($r('app.string.file_send_failed'));
    } finally {
      this.fileSending = false;
    }
  }

  private onDisabledTap(): void {
    this.showToast($r('app.string.settings_coming_soon'));
  }

  private onEncryptionInfo(): void {
    this.closeMenu();
    this.showEncryptionDialog = true;
  }

  private trySendClipboard(): void {
    this.closeMenu();
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

  private toolbarSubtitle(): ResourceStr {
    if (!this.item) {
      return '';
    }
    if (this.item.peerBattery) {
      return BatteryHelper.formatLabel(
        this.item.peerBattery.currentCharge,
        this.item.peerBattery.isCharging
      );
    }
    if (this.item.sessionActive) {
      return $r('app.string.battery_unknown');
    }
    return '';
  }

  private isPairingUi(): boolean {
    return this.item !== null && !this.item.trusted;
  }

  private isUnreachableUi(): boolean {
    return this.item !== null && this.item.trusted && !this.item.online && !this.item.sessionActive;
  }

  private isPluginsUi(): boolean {
    return this.item !== null && this.item.trusted && (this.item.online || this.item.sessionActive);
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
        // ── Plugin menu entries (Android: getUiMenuEntries) ──
        this.MenuItem($r('app.string.plugin_send_clipboard'), () => {
          this.trySendClipboard();
        }, false, false)

        this.MenuItem($r('app.string.menu_send_ping'), () => {
          this.onPing();
        }, false, false)

        this.MenuItem($r('app.string.menu_ring'), () => {
          this.onRing();
        }, false, false)

        Divider().color(UiTheme.divider).width('100%')

        // ── Plugin settings ──
        this.MenuItem($r('app.string.menu_plugin_settings'), () => {
          this.onDisabledTap();
        }, false, true)

        // ── Encryption Info ──
        this.MenuItem($r('app.string.menu_encryption_info'), () => {
          this.onEncryptionInfo();
        }, false, false)

        Divider().color(UiTheme.divider).width('100%')

        // ── Unpair ──
        this.MenuItem($r('app.string.menu_unpair'), () => {
          this.onUnpair();
        }, true, false)
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

  // ── Pairing panel (Android view_pair_request.xml) ────────

  @Builder
  PairingPanel() {
    Column() {
      Text($r('app.string.pairing_not_paired_title'))
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

      // ── Connecting / TLS ──
      if (this.isConnecting()) {
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

      // ── Error ──
      if (this.hasError()) {
        Text(this.statusText)
          .fontSize(13)
          .fontColor(UiTheme.danger)
          .width('100%')
          .margin({ bottom: 12 })
      }

      // ── Connect / Request pairing button ──
      KdePrimaryButton({
        label: this.item?.sessionActive ? $r('app.string.pairing_request_button') : $r('app.string.plugins_connect_button'),
        isEnabled: !this.isConnecting() || this.hasError(),
        onTap: () => {
          this.onConnectOrPair();
        }
      })

      // ── Accept / Reject ──
      // Enabled when peer has requested pairing (Android: RequestedByPeer)
      Row({ space: 8 }) {
        Button($r('app.string.pairing_accept'))
          .layoutWeight(1)
          .height(48)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .backgroundColor(UiTheme.primary)
          .borderRadius(UiTheme.radiusButton)
          .enabled(this.item !== null && this.item.sessionActive)
          .opacity(this.item !== null && this.item.sessionActive ? 1 : 0.4)
          .onClick(() => {
            this.session.getService().getClient().acceptPairing();
            AppNotifier.getInstance().cancelPairRequest();
          })
        Button($r('app.string.pairing_reject'))
          .layoutWeight(1)
          .height(48)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(UiTheme.onSurface)
          .backgroundColor(UiTheme.surfaceVariant)
          .borderRadius(UiTheme.radiusButton)
          .enabled(this.item !== null && this.item.sessionActive)
          .opacity(this.item !== null && this.item.sessionActive ? 1 : 0.4)
          .onClick(() => {
            this.session.getService().getClient().rejectPairing();
            AppNotifier.getInstance().cancelPairRequest();
          })
      }
      .width('100%')
      .margin({ top: 12 })
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
        .margin({ bottom: 12 })
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
    // Show progress card when file sending is active for the send_files plugin
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
      ForEach(this.pluginBtns, (btn: PluginButton, index: number) => {
        if (index % 2 === 0) {
          Row({ space: 8 }) {
            Column() {
              this.PluginCard(btn)
            }
            .layoutWeight(1)

            if (index + 1 < this.pluginBtns.length) {
              Column() {
                this.PluginCard(this.pluginBtns[index + 1])
              }
              .layoutWeight(1)
            } else {
              Column().layoutWeight(1)
            }
          }
          .width('100%')
          .padding({ bottom: 8 })
        }
      }, (btn: PluginButton, index: number) => `pb_${index}`)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8 })
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
      }

      if (this.item !== null && this.item.sessionActive) {
        // ── Plugin buttons grid ──
        this.PluginGrid()

        // ── Plugins needing permissions (Android section) ──
        Text($r('app.string.plugins_permission_needed'))
          .fontSize(12)
          .fontColor(UiTheme.textMuted)
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 4 })
          .opacity(0.4)

        Column()
          .width('100%')
          .height(8)

        Text($r('app.string.plugins_permission_disabled'))
          .fontSize(12)
          .fontColor(UiTheme.textMuted)
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 4 })
          .opacity(0.4)

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
      Text($r('app.string.encryption_cert_unavailable'))
        .fontSize(12)
        .fontColor(UiTheme.outline)
        .width('100%')
        .margin({ bottom: 12 })

      Divider().color(UiTheme.divider).width('100%').margin({ bottom: 12 })

      // Remote device fingerprint
      Text($r('app.string.encryption_remote_fingerprint_label'))
        .fontSize(13)
        .fontColor(UiTheme.textMuted)
        .width('100%')
        .margin({ bottom: 4 })
      Text($r('app.string.encryption_not_connected'))
        .fontSize(12)
        .fontColor(UiTheme.outline)
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
          if (result === 0) { // PasteButtonOnClickResult.SUCCESS = 0
            pasteboard.getSystemPasteboard().getData((err: Error, pasteData: pasteboard.PasteData) => {
              if (err) {
                console.error('[DeviceDetail] paste error:', err.message);
                this.showPasteOverlay = false;
                return;
              }
              const text = pasteData.getPrimaryText();
              if (text && text.trim().length > 0) {
                this.session.getService().sendClipboardText(text.trim());
                this.showToast($r('app.string.clipboard_send_toast'));
              }
              this.showPasteOverlay = false;
            });
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
        Column()
          .width('100%')
          .height(this.statusBarHeight)
          .backgroundColor(UiTheme.surface)

        KdeTopBar({
          title: this.item !== null ? this.item.deviceName : $r('app.string.device_detail_title'),
          subtitle: this.toolbarSubtitle(),
          showBack: true,
          showOverflow: this.item !== null && this.item.trusted,
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
