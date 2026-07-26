import { common } from '@kit.AbilityKit';
import { AppSession } from '../app/AppSession';
import { DeviceListItem, KdeStatus, ConnectionState } from '../service/KdeTypes';
import { BatteryHelper } from '../common/BatteryHelper';
import { goBack, hostContext, routeParams } from '../common/NavUtil';

interface DeviceDetailParams {
  deviceId: string;
}

@Entry
@Component
struct DeviceDetail {
  @State deviceId: string = '';
  @State item: DeviceListItem | null = null;
  @State statusText: string = '';
  @State statusState: ConnectionState = 'idle';
  @State clipInput: string = '';
  @State busy: boolean = false;

  private deviceSubId: number = -1;
  private statusSubId: number = -1;
  private session: AppSession = AppSession.getInstance();

  aboutToAppear() {
    let params = routeParams(this.getUIContext()) as DeviceDetailParams;
    if (params && params.deviceId) {
      this.deviceId = params.deviceId;
    }

    let ctx: common.UIAbilityContext | undefined = hostContext(this.getUIContext());
    if (ctx) {
      this.session.ensureStarted(ctx).then(() => {
        this.refreshItem();
        this.applyStatus(this.session.getLastStatus());
      });
    }

    this.ensureSubscriptions();
  }

  onPageShow() {
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

  /** Only show global status lines that belong to this device (or have no peer yet). */
  private applyStatus(s: KdeStatus): void {
    if (s.peerDeviceId && s.peerDeviceId.length > 0 && this.deviceId.length > 0 &&
      s.peerDeviceId !== this.deviceId) {
      return;
    }
    this.statusState = s.state;
    this.statusText = s.message;
  }

  private onConnect(): void {
    if (!this.item) {
      return;
    }
    this.session.getService().connectListItem(this.item);
  }

  private onDisconnect(): void {
    this.session.getService().disconnect();
  }

  private onUnpair(): void {
    if (!this.item) {
      return;
    }
    this.busy = true;
    this.session.getService().unpair(this.item.deviceId).then(() => {
      this.busy = false;
      goBack(this.getUIContext());
    }).catch(() => {
      this.busy = false;
    });
  }

  private onSendText(): void {
    if (this.clipInput.length === 0) {
      return;
    }
    this.session.getService().sendClipboardText(this.clipInput);
  }

  private onPing(): void {
    this.session.getService().sendPing();
  }

  private statusColor(): string {
    if (this.statusState === 'paired') {
      return '#1B8A4A';
    }
    if (this.statusState === 'error') {
      return '#C62828';
    }
    if (this.statusState === 'connected' || this.statusState === 'connecting' ||
      this.statusState === 'tls_handshake') {
      return '#1565C0';
    }
    return '#757575';
  }

  /** Same palette as list row dots / labels, driven by DeviceListItem.status. */
  private rowStatusColor(): string {
    if (!this.item) {
      return '#757575';
    }
    if (this.item.status === 'paired') {
      return '#1B8A4A';
    }
    if (this.item.status === 'connected' || this.item.status === 'connecting' ||
      this.item.status === 'available') {
      return '#1565C0';
    }
    return '#9E9E9E';
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(16)
          .fontColor('#1565C0')
          .onClick(() => {
            goBack(this.getUIContext());
          })
        Text(this.item?.deviceName ?? '设备')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 16 })
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      if (!this.item) {
        Text('设备不存在或已移除')
          .fontSize(15)
          .fontColor('#9E9E9E')
          .margin(24)
      } else {
        Scroll() {
          Column() {
            Column() {
              Text(this.item.deviceName)
                .fontSize(22)
                .fontWeight(FontWeight.Bold)
                .width('100%')
              Text(this.item.statusLabel)
                .fontSize(14)
                .fontColor(this.rowStatusColor())
                .margin({ top: 8 })
                .width('100%')
              Text(`类型: ${this.item.deviceType}`)
                .fontSize(13)
                .fontColor('#757575')
                .margin({ top: 12 })
                .width('100%')
              if (this.item.ip.length > 0) {
                Text(`${this.item.ip}:${this.item.tcpPort}`)
                  .fontSize(13)
                  .fontColor('#757575')
                  .margin({ top: 4 })
                  .width('100%')
              }
              if (this.item.peerBattery) {
                Text(BatteryHelper.formatLabel(
                  this.item.peerBattery.currentCharge,
                  this.item.peerBattery.isCharging
                ))
                  .fontSize(14)
                  .fontColor(this.item.peerBattery.currentCharge <= 15 &&
                    !this.item.peerBattery.isCharging ? '#C62828' : '#1565C0')
                  .margin({ top: 10 })
                  .width('100%')
              } else if (this.item.sessionActive) {
                Text('对端电量：等待上报…')
                  .fontSize(13)
                  .fontColor('#9E9E9E')
                  .margin({ top: 10 })
                  .width('100%')
              }
              Text(`ID: ${this.item.deviceId}`)
                .fontSize(11)
                .fontColor('#9E9E9E')
                .margin({ top: 8 })
                .width('100%')
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Color.White)
            .borderRadius(12)
            .margin({ left: 16, right: 16, top: 8 })

            Text(this.statusText)
              .fontSize(12)
              .fontColor(this.statusColor())
              .width('100%')
              .padding({ left: 20, right: 20, top: 12, bottom: 4 })

            Column({ space: 10 }) {
              if (!this.item.sessionActive) {
                Button(this.item.trusted ? '连接' : '连接并配对')
                  .width('100%')
                  .onClick(() => {
                    this.onConnect();
                  })
              } else {
                Button('断开连接')
                  .width('100%')
                  .backgroundColor('#757575')
                  .onClick(() => {
                    this.onDisconnect();
                  })
              }

              if (this.item.trusted || this.item.sessionActive) {
                Button('取消配对')
                  .width('100%')
                  .backgroundColor('#C62828')
                  .enabled(!this.busy)
                  .onClick(() => {
                    this.onUnpair();
                  })
              }
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12 })

            if (this.item.sessionActive) {
              Column() {
                Text('发送文本')
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .width('100%')
                  .margin({ bottom: 8 })

                TextInput({ text: this.clipInput, placeholder: '输入或粘贴文本到此，再点发送' })
                  .height(40)
                  .onChange((v: string) => {
                    this.clipInput = v;
                  })

                Row({ space: 8 }) {
                  Button('发送')
                    .layoutWeight(1)
                    .onClick(() => {
                      this.onSendText();
                    })
                  Button('Ping')
                    .layoutWeight(1)
                    .onClick(() => {
                      this.onPing();
                    })
                }
                .width('100%')
                .margin({ top: 10 })

                Text('提示：系统剪贴板请先粘贴到输入框（无需 READ_PASTEBOARD 权限）')
                  .fontSize(11)
                  .fontColor('#9E9E9E')
                  .margin({ top: 8 })
                  .width('100%')
              }
              .width('100%')
              .padding(16)
              .margin({ left: 16, right: 16, top: 16 })
              .backgroundColor(Color.White)
              .borderRadius(12)
            }
          }
          .width('100%')
          .padding({ bottom: 32 })
        }
        .layoutWeight(1)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
