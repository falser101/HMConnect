import { common } from '@kit.AbilityKit';
import { AppSession } from '../app/AppSession';
import { DeviceListItem, KdeStatus, KDE_PROTOCOL_VERSION } from '../service/KdeTypes';
import { FindMyPhoneHelper } from '../common/FindMyPhoneHelper';
import { DeviceDetailRouteParams, hostContext, pushPage } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeIcon, KdeIconRes } from '../common/ui/KdeIcons';
import {
  KdeTopBar,
  KdeSectionHeader,
  KdeDeviceCard,
  KdeEmptyText,
  KdeNavRow
} from '../common/ui/KdeWidgets';

@Entry
@Component
struct Index {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State connectedList: DeviceListItem[] = [];
  @State availableList: DeviceListItem[] = [];
  @State rememberedList: DeviceListItem[] = [];
  @State statusText: string = '';
  @State myName: string = '';
  @State sidebarOpen: boolean = false;
  /** Drawer panel X offset in vp; 0 = open, negative = off-screen left. */
  @State drawerPx: number = -320;
  @State scrimOpacity: number = 0;
  @State findPhoneRinging: boolean = false;
  @State findPhonePeer: string = '';
  @State refreshing: boolean = false;
  @State isRefreshingPull: boolean = false;

  private deviceSubId: number = -1;
  private statusSubId: number = -1;
  private findPhoneSubId: number = -1;
  private session: AppSession = AppSession.getInstance();
  private refreshTimer: number = -1;

  aboutToAppear() {
    this.session.attachUiContext(this.getUIContext());
    let ctx: common.UIAbilityContext | undefined = hostContext(this.getUIContext());
    if (ctx) {
      this.session.ensureStarted(ctx).then(() => {
        this.myName = this.session.getService().getMyName();
        this.applyDevices(this.session.getLastDevices());
        this.applyStatus(this.session.getLastStatus());
      });
    }
    this.ensureSubscriptions();
  }

  onPageShow() {
    this.session.attachUiContext(this.getUIContext());
    this.ensureSubscriptions();
    this.applyDevices(this.session.getLastDevices());
    this.applyStatus(this.session.getLastStatus());
  }

  aboutToDisappear() {
    this.clearSubscriptions();
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  private ensureSubscriptions(): void {
    if (this.deviceSubId < 0) {
      this.deviceSubId = this.session.subscribeDevices((items: DeviceListItem[]) => {
        setTimeout(() => {
          this.applyDevices(items);
        }, 0);
      });
    }
    if (this.statusSubId < 0) {
      this.statusSubId = this.session.subscribeStatus((status: KdeStatus) => {
        this.applyStatus(status);
      });
    }
    if (this.findPhoneSubId < 0) {
      this.findPhoneSubId = FindMyPhoneHelper.getInstance().subscribe((active: boolean, name: string) => {
        this.findPhoneRinging = active;
        this.findPhonePeer = name;
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
    if (this.findPhoneSubId >= 0) {
      FindMyPhoneHelper.getInstance().unsubscribe(this.findPhoneSubId);
      this.findPhoneSubId = -1;
    }
  }

  /**
   * Android PairingViewModel buckets (relaxed so session/paired devices always surface):
   * - connected: trusted + (online | sessionActive | connected/paired status)
   * - available: !trusted + online
   * - remembered: trusted + offline
   */
  private applyDevices(items: DeviceListItem[]): void {
    let connected: DeviceListItem[] = [];
    let available: DeviceListItem[] = [];
    let remembered: DeviceListItem[] = [];
    for (let i = 0; i < items.length; i++) {
      let item = items[i];
      let reachable = item.online || item.sessionActive ||
        item.status === 'connected' || item.status === 'paired' || item.status === 'connecting';
      if (item.trusted && reachable) {
        connected.push(item);
      } else if (!item.trusted && (item.online || item.sessionActive || item.status === 'connecting')) {
        available.push(item);
      } else if (item.trusted) {
        remembered.push(item);
      } else if (item.online) {
        available.push(item);
      }
    }
    this.connectedList = connected;
    this.availableList = available;
    this.rememberedList = remembered;
  }

  private applyStatus(status: KdeStatus): void {
    if (status.state === 'error') {
      this.statusText = status.message;
    } else {
      this.statusText = '';
    }
  }

  private openDevice(item: DeviceListItem): void {
    this.closeDrawer();
    let params: DeviceDetailRouteParams = { deviceId: item.deviceId };
    pushPage(this.getUIContext(), 'pages/DeviceDetail', params);
  }

  private openDeviceById(deviceId: string): void {
    let params: DeviceDetailRouteParams = { deviceId: deviceId };
    this.closeDrawer();
    pushPage(this.getUIContext(), 'pages/DeviceDetail', params);
  }

  /**
   * Card subtitle — Android PairingScreen only shows device name;
   * optional red summary is solely protocol_version_newer (never 已连接/已配对).
   * Returns ResourceStr so protocol warning can use string resources.
   */
  private deviceSummary(item: DeviceListItem): ResourceStr {
    // Android DeviceExtensions: summaryRes = protocol_version_newer if peer is newer
    if (item.protocolVersion > 0 && item.protocolVersion > KDE_PROTOCOL_VERSION) {
      return $r('app.string.protocol_version_newer');
    }
    return '';
  }

  private doRefresh(): void {
    this.refreshing = true;
    this.isRefreshingPull = true;
    this.session.getService().forceRefresh();
    // Re-pull list immediately after force refresh
    this.applyDevices(this.session.getService().buildDeviceList());
    if (this.refreshTimer >= 0) {
      clearTimeout(this.refreshTimer);
    }
    this.refreshTimer = setTimeout(() => {
      this.refreshing = false;
      this.isRefreshingPull = false;
      this.refreshTimer = -1;
      this.applyDevices(this.session.getService().buildDeviceList());
    }, UiTheme.durationRefresh) as number;
  }

  private openDrawer(): void {
    this.sidebarOpen = true;
    this.drawerPx = -320;
    this.scrimOpacity = 0;
    this.getUIContext().animateTo({
      duration: UiTheme.durationDrawer,
      curve: Curve.EaseOut
    }, () => {
      this.drawerPx = 0;
      this.scrimOpacity = 1;
    });
  }

  private closeDrawer(): void {
    this.getUIContext().animateTo({
      duration: UiTheme.durationDrawer,
      curve: Curve.EaseIn,
      onFinish: () => {
        this.sidebarOpen = false;
      }
    }, () => {
      this.drawerPx = -320;
      this.scrimOpacity = 0;
    });
  }

  @Builder
  DrawerContent() {
    Column() {
      // nav_header
      Row() {
        Column() {
          KdeIcon({
            symbol: KdeIconRes.phone(),
            iconSize: 28,
            color: UiTheme.iconTint
          })
        }
        .width(48)
        .height(48)
        .justifyContent(FlexAlign.Center)
        .backgroundColor(UiTheme.surfaceVariant)
        .borderRadius(24)

        Column() {
          Text('HMConnect')
            .fontSize(18)
            .fontWeight(FontWeight.Medium)
            .fontColor(UiTheme.onSurface)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.myName.length > 0 ? this.myName : '本机设备')
            .fontSize(13)
            .fontColor(UiTheme.onSurfaceVariant)
            .margin({ top: 4 })
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 12 })
        .layoutWeight(1)
        .constraintSize({ minWidth: 0 })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: this.statusBarHeight + 16, bottom: 16 })
      .alignItems(VerticalAlign.Center)

      Divider().color(UiTheme.divider)

      // Menu area with horizontal padding so selected pill stays inside
      Column() {
        Text('设备')
          .fontSize(12)
          .fontColor(UiTheme.textMuted)
          .width('100%')
          .padding({ left: 16, right: 8, top: 12, bottom: 4 })

        ForEach(this.connectedList, (item: DeviceListItem) => {
          KdeNavRow({
            label: item.deviceName,
            symbol: KdeIconRes.forDeviceType(item.deviceType),
            selected: false,
            onTap: () => {
              this.openDeviceById(item.deviceId);
            }
          })
        }, (item: DeviceListItem) => `nav_${item.deviceId}`)

        KdeNavRow({
          label: '配对新设备',
          symbol: KdeIconRes.addCircle(),
          selected: true,
          onTap: () => {
            this.closeDrawer();
          }
        })

        Divider().color(UiTheme.divider).margin({ top: 8, bottom: 8 })

        KdeNavRow({
          label: '设置',
          symbol: KdeIconRes.settings(),
          selected: false,
          onTap: () => {
            this.closeDrawer();
            pushPage(this.getUIContext(), 'pages/Settings');
          }
        })

        KdeNavRow({
          label: '关于',
          symbol: KdeIconRes.info(),
          selected: false,
          onTap: () => {
            this.closeDrawer();
            pushPage(this.getUIContext(), 'pages/About');
          }
        })
      }
      .width('100%')
      .padding({ left: 8, right: 8 })
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      .clip(true)

      Blank()
    }
    .width('100%')
    .height('100%')
    .backgroundColor(UiTheme.sidebarBg)
    .alignItems(HorizontalAlign.Start)
    .clip(true)
  }

  build() {
    Stack() {
      Column() {
        // TopBar paints under transparent status bar (continuous chrome)
        KdeTopBar({
          title: '设备',
          showMenu: true,
          showRefresh: true,
          refreshing: this.refreshing,
          onMenu: () => {
            this.openDrawer();
          },
          onRefresh: () => {
            this.doRefresh();
          }
        })

        if (this.findPhoneRinging) {
          Row() {
            Column() {
              Text('正在响铃 · 查找设备')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor(Color.White)
              Text(this.findPhonePeer.length > 0 ? this.findPhonePeer : '电脑端')
                .fontSize(12)
                .fontColor('#FFCDD2')
                .margin({ top: 2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .onClick(() => {
              this.session.openFindPhonePage();
            })

            Button('关闭响铃')
              .height(36)
              .fontSize(14)
              .fontColor(UiTheme.findPhoneDark)
              .backgroundColor(Color.White)
              .borderRadius(18)
              .onClick(() => {
                FindMyPhoneHelper.getInstance().stop();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 10, bottom: 10 })
          .backgroundColor(UiTheme.findPhone)
        }

        if (this.statusText.length > 0) {
          Text(this.statusText)
            .fontSize(13)
            .fontColor(UiTheme.danger)
            .width('100%')
            .padding({ left: 16, right: 16, top: 6, bottom: 2 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }

        // Inline List sections (avoid @Builder+ForEach ListItem refresh bugs)
        Refresh({ refreshing: this.isRefreshingPull }) {
          List() {
            ListItem({ style: ListItemStyle.NONE }) {
              Row() {
                KdeIcon({
                  symbol: KdeIconRes.wifi(),
                  iconSize: 18,
                  color: UiTheme.onSurfaceVariant
                })
                Text('其他在同一网络运行 KDE Connect 的设备会在此处显示。')
                  .fontSize(UiTheme.bodyMd)
                  .fontColor(UiTheme.onSurfaceVariant)
                  .margin({ left: 8 })
                  .layoutWeight(1)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 6 })
              .alignItems(VerticalAlign.Top)
            }

            // —— 已连接的设备 ——
            ListItem({ style: ListItemStyle.NONE }) {
              KdeSectionHeader({ title: '已连接的设备' })
            }

            if (this.connectedList.length === 0) {
              ListItem({ style: ListItemStyle.NONE }) {
                KdeEmptyText({ text: '无设备' })
              }
            }
            ForEach(this.connectedList, (item: DeviceListItem) => {
              ListItem({ style: ListItemStyle.NONE }) {
                KdeDeviceCard({
                  name: item.deviceName,
                  deviceType: item.deviceType,
                  summary: this.deviceSummary(item),
                  deviceId: item.deviceId,
                  onOpen: () => {
                    this.openDeviceById(item.deviceId);
                  }
                })
              }
            }, (item: DeviceListItem) =>
              `c_${item.deviceId}_${item.status}_${item.online ? 1 : 0}_${item.sessionActive ? 1 : 0}`)

            // —— 可用的设备 ——
            if (this.availableList.length > 0) {
              ListItem({ style: ListItemStyle.NONE }) {
                KdeSectionHeader({ title: '可用的设备' })
              }

              ForEach(this.availableList, (item: DeviceListItem) => {
                ListItem({ style: ListItemStyle.NONE }) {
                  KdeDeviceCard({
                    name: item.deviceName,
                    deviceType: item.deviceType,
                    summary: this.deviceSummary(item),
                    deviceId: item.deviceId,
                    onOpen: () => {
                      this.openDeviceById(item.deviceId);
                    }
                  })
                }
              }, (item: DeviceListItem) =>
                `a_${item.deviceId}_${item.status}_${item.online ? 1 : 0}_${item.sessionActive ? 1 : 0}`)
            }

            // —— 记住的设备 ——
            if (this.rememberedList.length > 0) {
              ListItem({ style: ListItemStyle.NONE }) {
                KdeSectionHeader({ title: '记住的设备' })
              }

              ForEach(this.rememberedList, (item: DeviceListItem) => {
                ListItem({ style: ListItemStyle.NONE }) {
                  KdeDeviceCard({
                    name: item.deviceName,
                    deviceType: item.deviceType,
                    summary: this.deviceSummary(item),
                    deviceId: item.deviceId,
                    onOpen: () => {
                      this.openDeviceById(item.deviceId);
                    }
                  })
                }
              }, (item: DeviceListItem) =>
                `r_${item.deviceId}_${item.status}_${item.online ? 1 : 0}`)
            }

            ListItem({ style: ListItemStyle.NONE }) {
              Column().width('100%').height(this.navBarHeight + 24)
            }
          }
          .width('100%')
          .height('100%')
          .padding({ left: UiTheme.pageHPad, right: UiTheme.pageHPad })
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring)
        }
        .onRefreshing(() => {
          this.doRefresh();
        })
        .layoutWeight(1)
        .backgroundColor(UiTheme.pageBg)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(UiTheme.pageBg)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])

      if (this.sidebarOpen) {
        Stack() {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor(UiTheme.scrim)
            .opacity(this.scrimOpacity)
            .hitTestBehavior(HitTestMode.Default)
            .onClick(() => {
              this.closeDrawer();
            })

          Column() {
            this.DrawerContent()
          }
          .width('78%')
          .constraintSize({ maxWidth: 320 })
          .height('100%')
          .shadow({ radius: 16, color: '#40000000', offsetX: 4, offsetY: 0 })
          .offset({ x: this.drawerPx })
          .clip(true)
          .align(Alignment.Start)
        }
        .width('100%')
        .height('100%')
        .alignContent(Alignment.Start)
        .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
      }
    }
    .width('100%')
    .height('100%')
  }
}
