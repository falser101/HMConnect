import { common } from '@kit.AbilityKit';
import { AppSession } from '../app/AppSession';
import { DeviceListItem, KdeStatus, ConnectionState } from '../service/KdeTypes';
import { BatteryHelper } from '../common/BatteryHelper';
import { DeviceDetailRouteParams, hostContext, pushPage } from '../common/NavUtil';

@Entry
@Component
struct Index {
  @State pairedList: DeviceListItem[] = [];
  @State availableList: DeviceListItem[] = [];
  @State statusText: string = '初始化中…';
  @State statusState: ConnectionState = 'idle';
  @State myName: string = '';
  @State myIdShort: string = '';
  @State sidebarOpen: boolean = false;

  private deviceSubId: number = -1;
  private statusSubId: number = -1;
  private session: AppSession = AppSession.getInstance();

  aboutToAppear() {
    let ctx: common.UIAbilityContext | undefined = hostContext(this.getUIContext());
    if (ctx) {
      this.session.ensureStarted(ctx).then(() => {
        this.myName = this.session.getService().getMyName();
        let id = this.session.getService().getMyDeviceId();
        this.myIdShort = id.length > 12 ? id.substring(0, 12) + '…' : id;
        this.applyDevices(this.session.getLastDevices());
        this.applyStatus(this.session.getLastStatus());
      });
    }

    this.ensureSubscriptions();
  }

  onPageShow() {
    // Router may keep Index alive under the detail page; re-sync when visible again.
    this.ensureSubscriptions();
    this.applyDevices(this.session.getLastDevices());
    this.applyStatus(this.session.getLastStatus());
  }

  aboutToDisappear() {
    this.clearSubscriptions();
  }

  private ensureSubscriptions(): void {
    if (this.deviceSubId < 0) {
      this.deviceSubId = this.session.subscribeDevices((items: DeviceListItem[]) => {
        this.applyDevices(items);
      });
    }
    if (this.statusSubId < 0) {
      this.statusSubId = this.session.subscribeStatus((status: KdeStatus) => {
        this.applyStatus(status);
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

  private applyDevices(items: DeviceListItem[]): void {
    let paired: DeviceListItem[] = [];
    let available: DeviceListItem[] = [];
    for (let i = 0; i < items.length; i++) {
      if (items[i].trusted) {
        paired.push(items[i]);
      } else {
        available.push(items[i]);
      }
    }
    this.pairedList = paired;
    this.availableList = available;
  }

  private applyStatus(status: KdeStatus): void {
    this.statusState = status.state;
    this.statusText = status.message;
  }

  private statusColor(): string {
    if (this.statusState === 'paired') {
      return '#1B8A4A';
    }
    if (this.statusState === 'connected' || this.statusState === 'tls_handshake' ||
      this.statusState === 'connecting') {
      return '#1565C0';
    }
    if (this.statusState === 'error') {
      return '#C62828';
    }
    return '#666666';
  }

  private openDevice(item: DeviceListItem): void {
    let params: DeviceDetailRouteParams = { deviceId: item.deviceId };
    pushPage(this.getUIContext(), 'pages/DeviceDetail', params);
  }

  private statusDotColor(item: DeviceListItem): string {
    if (item.status === 'paired') {
      return '#1B8A4A';
    }
    if (item.status === 'connected' || item.status === 'connecting') {
      return '#1565C0';
    }
    if (item.online || item.status === 'available') {
      return '#1565C0';
    }
    return '#BDBDBD';
  }

  @Builder
  DeviceRow(item: DeviceListItem) {
    Row() {
      Column()
        .width(10)
        .height(10)
        .borderRadius(5)
        .backgroundColor(this.statusDotColor(item))
        .margin({ right: 12 })

      Column() {
        Text(item.deviceName)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor('#212121')
        Text(`${item.statusLabel}${item.ip.length > 0 ? ' · ' + item.ip : ''}`)
          .fontSize(12)
          .fontColor('#757575')
          .margin({ top: 4 })
        if (item.peerBattery) {
          Text(BatteryHelper.formatLabel(
            item.peerBattery.currentCharge,
            item.peerBattery.isCharging
          ))
            .fontSize(12)
            .fontColor(item.peerBattery.currentCharge <= 15 && !item.peerBattery.isCharging
              ? '#C62828' : '#1565C0')
            .margin({ top: 2 })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text('›')
        .fontSize(22)
        .fontColor('#BDBDBD')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor(Color.White)
    .onClick(() => {
      this.openDevice(item);
    })
  }

  @Builder
  SectionHeader(title: string, count: number) {
    Text(`${title} (${count})`)
      .fontSize(13)
      .fontColor('#757575')
      .fontWeight(FontWeight.Medium)
      .width('100%')
      .padding({ left: 16, right: 16, top: 16, bottom: 8 })
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('☰')
            .fontSize(22)
            .fontColor('#212121')
            .padding(8)
            .onClick(() => {
              this.sidebarOpen = true;
            })

          Text('设备')
            .fontSize(20)
            .fontWeight(FontWeight.Bold)
            .fontColor('#212121')
            .margin({ left: 8 })
            .layoutWeight(1)
        }
        .width('100%')
        .height(56)
        .padding({ left: 8, right: 16 })
        .alignItems(VerticalAlign.Center)

        Text(this.statusText)
          .fontSize(12)
          .fontColor(this.statusColor())
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (this.pairedList.length === 0 && this.availableList.length === 0) {
          Column() {
            Text('正在搜索设备…')
              .fontSize(16)
              .fontColor('#9E9E9E')
            Text('请确认电脑已打开 KDE Connect\n并与手机在同一 Wi‑Fi')
              .fontSize(13)
              .fontColor('#BDBDBD')
              .textAlign(TextAlign.Center)
              .margin({ top: 12 })
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          List() {
            if (this.pairedList.length > 0) {
              ListItem() {
                this.SectionHeader('已配对', this.pairedList.length)
              }
              ForEach(this.pairedList, (item: DeviceListItem) => {
                ListItem() {
                  this.DeviceRow(item)
                }
                .margin({ bottom: 1 })
              }, (item: DeviceListItem) =>
                `p_${item.deviceId}_${item.status}_${item.sessionActive ? '1' : '0'}_${item.ip}_${item.peerBattery?.currentCharge ?? -1}_${item.peerBattery?.isCharging ? 1 : 0}`)
            }

            if (this.availableList.length > 0) {
              ListItem() {
                this.SectionHeader('可用设备', this.availableList.length)
              }
              ForEach(this.availableList, (item: DeviceListItem) => {
                ListItem() {
                  this.DeviceRow(item)
                }
                .margin({ bottom: 1 })
              }, (item: DeviceListItem) =>
                `a_${item.deviceId}_${item.status}_${item.sessionActive ? '1' : '0'}_${item.ip}_${item.peerBattery?.currentCharge ?? -1}_${item.peerBattery?.isCharging ? 1 : 0}`)
            }
          }
          .width('100%')
          .layoutWeight(1)
          .backgroundColor('#F5F5F5')
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor('#FAFAFA')

      if (this.sidebarOpen) {
        Row() {
          Column() {
            Text('HMConnect')
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .margin({ top: 48, left: 20, bottom: 4 })
              .width('100%')
              .textAlign(TextAlign.Start)

            Text('本机设备')
              .fontSize(12)
              .fontColor('#9E9E9E')
              .margin({ left: 20, top: 16 })
              .width('100%')

            Text(this.myName.length > 0 ? this.myName : '…')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .margin({ left: 20, top: 4 })
              .width('100%')

            Text(`ID: ${this.myIdShort}`)
              .fontSize(12)
              .fontColor('#9E9E9E')
              .margin({ left: 20, top: 4, bottom: 20 })
              .width('100%')

            Divider().color('#E0E0E0')

            Text('设置')
              .fontSize(16)
              .width('100%')
              .padding({ left: 20, right: 20, top: 16, bottom: 16 })
              .onClick(() => {
                this.sidebarOpen = false;
                pushPage(this.getUIContext(), 'pages/Settings');
              })

            Text('关于')
              .fontSize(16)
              .width('100%')
              .padding({ left: 20, right: 20, top: 16, bottom: 16 })
              .onClick(() => {
                this.sidebarOpen = false;
                pushPage(this.getUIContext(), 'pages/About');
              })

            Blank()
          }
          .width('78%')
          .height('100%')
          .backgroundColor(Color.White)
          .alignItems(HorizontalAlign.Start)
          .shadow({ radius: 16, color: '#40000000', offsetX: 2, offsetY: 0 })

          Column()
            .width('22%')
            .height('100%')
            .backgroundColor('#66000000')
            .onClick(() => {
              this.sidebarOpen = false;
            })
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}
