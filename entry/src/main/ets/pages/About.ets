import { MY_DEVICE_ID, KDE_PROTOCOL_VERSION } from '../service/KdeTypes';
import { goBack } from '../common/NavUtil';

@Entry
@Component
struct About {
  build() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(16)
          .fontColor('#1565C0')
          .onClick(() => {
            goBack(this.getUIContext());
          })
        Text('关于')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 16 })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Column() {
        Text('HMConnect')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .margin({ top: 32 })

        Text('鸿蒙端 KDE Connect MVP')
          .fontSize(14)
          .fontColor('#757575')
          .margin({ top: 8 })

        Text('版本 1.0.0 · 迭代 1')
          .fontSize(13)
          .fontColor('#9E9E9E')
          .margin({ top: 4 })

        Divider().margin({ top: 24, bottom: 16 }).color('#E0E0E0')

        Text(`协议版本: ${KDE_PROTOCOL_VERSION}`)
          .fontSize(13)
          .fontColor('#616161')
          .width('100%')
          .padding({ left: 24 })

        Text(`本机 ID: ${MY_DEVICE_ID}`)
          .fontSize(12)
          .fontColor('#9E9E9E')
          .width('100%')
          .padding({ left: 24, top: 8, right: 24 })

        Text('功能：发现 / 配对 / 剪贴板 / Ping / 电量 / 找手机')
          .fontSize(13)
          .fontColor('#616161')
          .width('100%')
          .padding({ left: 24, top: 16, right: 24 })

        Text('后续：文件互传、通知同步、后台常驻')
          .fontSize(13)
          .fontColor('#9E9E9E')
          .width('100%')
          .padding({ left: 24, top: 8, right: 24 })
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FAFAFA')
  }
}
