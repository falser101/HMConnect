import { MY_DEVICE_ID, KDE_PROTOCOL_VERSION } from '../service/KdeTypes';
import { goBack } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { KdeIcon, KdeIconRes } from '../common/ui/KdeIcons';
import { KdeTopBar } from '../common/ui/KdeWidgets';

@Entry
@Component
struct About {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State logoScale: number = 1;

  aboutToAppear() {
    this.logoScale = 0.85;
    this.getUIContext().animateTo({
      duration: UiTheme.durationLong,
      curve: Curve.EaseOut
    }, () => {
      this.logoScale = 1;
    });
  }

  build() {
    Column() {
      Column()
        .width('100%')
        .height(this.statusBarHeight)
        .backgroundColor(UiTheme.surface)

      KdeTopBar({
        title: '关于',
        showBack: true,
        onBack: () => {
          goBack(this.getUIContext());
        }
      })

      Scroll() {
        Column({ space: 16 }) {
          // App info elevated card — Android AboutScreen AppInfoCard
          Row() {
            Column() {
              KdeIcon({
                symbol: KdeIconRes.app(),
                iconSize: 28,
                color: '#FFFFFF'
              })
            }
            .width(52)
            .height(52)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(UiTheme.kdeBlue)
            .borderRadius(12)
            .scale({ x: this.logoScale, y: this.logoScale })

            Column() {
              Text('HMConnect')
                .fontSize(20)
                .fontWeight(FontWeight.Medium)
                .fontColor(UiTheme.onSurface)
              Text('鸿蒙端 KDE Connect')
                .fontSize(14)
                .fontColor(UiTheme.onSurfaceVariant)
                .margin({ top: 4 })
              Text('版本 1.0.0')
                .fontSize(13)
                .fontColor(UiTheme.textMuted)
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Start)
            .margin({ left: 16 })
            .layoutWeight(1)
          }
          .width('100%')
          .padding(16)
          .backgroundColor(UiTheme.cardBg)
          .borderRadius(UiTheme.radiusCard)
          .shadow({ radius: 4, color: '#1A000000', offsetX: 0, offsetY: 2 })
          .alignItems(VerticalAlign.Top)

          // Details card
          Column() {
            this.InfoRow('协议版本', `${KDE_PROTOCOL_VERSION}`)
            Divider().color(UiTheme.divider).margin({ left: 16, right: 16 })
            this.InfoRow('本机 ID', MY_DEVICE_ID)
            Divider().color(UiTheme.divider).margin({ left: 16, right: 16 })
            this.InfoRow('已实现功能', '发现 · 配对 · 剪贴板 · Ping · 电量 · 找手机')
            Divider().color(UiTheme.divider).margin({ left: 16, right: 16 })
            this.InfoRow('后续计划', '文件互传 · 通知同步 · 后台常驻')
          }
          .width('100%')
          .backgroundColor(UiTheme.cardBg)
          .borderRadius(UiTheme.radiusCard)
          .shadow({ radius: 2, color: '#14000000', offsetX: 0, offsetY: 1 })
          .alignItems(HorizontalAlign.Start)

          Text('兼容桌面端 KDE Connect（同一局域网）。')
            .fontSize(12)
            .fontColor(UiTheme.textMuted)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 8 })

          Column().width('100%').height(this.navBarHeight + 24)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16 })
      }
      .layoutWeight(1)
      .align(Alignment.Top)
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(UiTheme.pageBg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  InfoRow(label: string, value: string) {
    Column() {
      Text(label)
        .fontSize(12)
        .fontColor(UiTheme.textMuted)
        .width('100%')
      Text(value)
        .fontSize(14)
        .fontColor(UiTheme.onSurface)
        .margin({ top: 4 })
        .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
  }
}
