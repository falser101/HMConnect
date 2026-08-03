import { fileIo } from '@kit.CoreFileKit';
import { AppSession } from '../app/AppSession';
import { goBack, routeParams } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeTopBar } from '../common/ui/KdeWidgets';
import { KdeIcon, KdeIconRes } from '../common/ui/KdeIcons';
import { DeviceListItem, ShareSendData } from '../service/KdeTypes';

/**
 * System-share device picker (Android ShareActivity equivalent).
 * Receives the shared payload (copied to cache by EntryAbility) and sends it
 * to the chosen paired device: files via FileSendJob, text/URL via share.request.
 */
@Entry
@Component
struct ShareSend {
  @State data: ShareSendData | null = null;
  @State devices: DeviceListItem[] = [];
  @State sending: boolean = false;
  @State statusText: string = '';
  private subId: number = -1;
  private session: AppSession = AppSession.getInstance();

  aboutToAppear() {
    this.session.attachUiContext(this.getUIContext());
    const p = routeParams(this.getUIContext()) as ShareSendData;
    if (p && (p.fileName.length > 0 || p.filePaths.length > 0 || p.textContent.length > 0)) {
      this.data = p;
    }
    this.refreshDevices();
    this.subId = this.session.subscribeDevices((items: DeviceListItem[]) => {
      const list: DeviceListItem[] = [];
      for (let i = 0; i < items.length; i++) {
        if (items[i].trusted) {
          list.push(items[i]);
        }
      }
      this.devices = list;
    });
  }

  aboutToDisappear() {
    if (this.subId >= 0) {
      this.session.unsubscribeDevices(this.subId);
      this.subId = -1;
    }
  }

  private refreshDevices(): void {
    const items: DeviceListItem[] = this.session.getLastDevices();
    const list: DeviceListItem[] = [];
    for (let i = 0; i < items.length; i++) {
      if (items[i].trusted) {
        list.push(items[i]);
      }
    }
    this.devices = list;
  }

  private async sendTo(device: DeviceListItem): Promise<void> {
    if (!this.data || this.sending) {
      return;
    }
    this.sending = true;
    this.statusText = '发送中…';
    try {
      if (this.data.isText) {
        const text: string = this.data.textContent;
        const session = this.session.getService().getClientForDevice(device.deviceId);
        if (!session) {
          throw new Error('设备未连接');
        }
        if (text.startsWith('http://') || text.startsWith('https://')) {
          session.sendUrlToPeer(text);
        } else {
          session.sendTextToPeer(text);
        }
        this.statusText = '已发送';
      } else if (this.data.filePaths.length > 0) {
        const job = this.session.getService().createFileSendJobFor(device.deviceId);
        for (let i = 0; i < this.data.filePaths.length; i++) {
          const stat: fileIo.Stat = fileIo.statSync(this.data.filePaths[i]);
          job.addFile({
            uri: this.data.filePaths[i],
            displayName: i === 0 ? this.data.fileName : `shared_${i}`,
            size: stat.size,
            lastModified: Math.floor(stat.mtime)
          });
        }
        await job.run((percent: number, fileName: string) => {
          this.statusText = fileName.length > 0 ? `${fileName} ${percent}%` : `${percent}%`;
        });
        this.statusText = job.isCancelled ? '已取消发送' : '已发送';
      } else {
        throw new Error('没有可发送的内容');
      }
    } catch (e) {
      console.error('[ShareSend] send failed:', JSON.stringify(e));
      this.statusText = '发送失败';
    } finally {
      this.sending = false;
    }
  }

  @Builder
  DeviceRow(device: DeviceListItem) {
    Row() {
      KdeIcon({ symbol: KdeIconRes.forDeviceType(device.deviceType), iconSize: 26, color: UiTheme.iconTint })
      Column() {
        Text(device.deviceName)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(UiTheme.onSurface)
          .width('100%')
        Text(device.online ? '在线' : '离线')
          .fontSize(12)
          .fontColor(device.online ? UiTheme.success : UiTheme.textMuted)
          .margin({ top: 2 })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
      .margin({ left: 12 })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .backgroundColor(UiTheme.cardBg)
    .borderRadius(UiTheme.radiusCard)
    .margin({ bottom: 8 })
    .onClick(() => {
      this.sendTo(device);
    })
  }

  build() {
    Column() {
      KdeTopBar({
        title: '发送到设备',
        showBack: true,
        showOverflow: false,
        onBack: () => {
          goBack(this.getUIContext());
        }
      })

      Scroll() {
        Column() {
          // ── Shared item ──
          if (this.data) {
            Column() {
              KdeIcon({ symbol: KdeIconRes.fileUpload(), iconSize: 28, color: UiTheme.primary })
                .margin({ bottom: 8 })
              Text(this.data.isText && this.data.textContent.length > 0
                ? (this.data.textContent.length > 60
                  ? `${this.data.textContent.substring(0, 60)}…`
                  : this.data.textContent)
                : this.data.fileName)
                .fontSize(15)
                .fontColor(UiTheme.onSurface)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.Center)
                .width('100%')
              Text(this.data.isText ? '文本' : this.data.mime)
                .fontSize(12)
                .fontColor(UiTheme.textMuted)
                .margin({ top: 4 })
            }
            .width('100%')
            .padding(20)
            .backgroundColor(UiTheme.cardBg)
            .borderRadius(UiTheme.radiusCard)
            .margin({ bottom: 16 })
          }

          Text('选择要发送到的设备')
            .fontSize(13)
            .fontColor(UiTheme.textMuted)
            .width('100%')
            .margin({ bottom: 8 })

          if (this.devices.length === 0) {
            Text('暂无已配对设备')
              .fontSize(14)
              .fontColor(UiTheme.textMuted)
              .margin({ top: 32 })
              .width('100%')
              .textAlign(TextAlign.Center)
          } else {
            ForEach(this.devices, (device: DeviceListItem) => {
              this.DeviceRow(device)
            }, (device: DeviceListItem) => `share_${device.deviceId}`)
          }

          if (this.statusText.length > 0) {
            Text(this.statusText)
              .fontSize(14)
              .fontColor(this.statusText.includes('失败') || this.statusText.includes('取消')
                ? UiTheme.danger
                : UiTheme.primary)
              .width('100%')
              .margin({ top: 16 })
              .textAlign(TextAlign.Center)
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16, bottom: 24 })
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
