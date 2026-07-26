import { AppSession } from '../app/AppSession';
import { DeviceStore } from '../store/DeviceStore';
import { goBack } from '../common/NavUtil';

@Entry
@Component
struct Settings {
  @State tip: string = '';

  build() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(16)
          .fontColor('#1565C0')
          .onClick(() => {
            goBack(this.getUIContext());
          })
        Text('设置')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .margin({ left: 16 })
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .alignItems(VerticalAlign.Center)

      Column() {
        Text('已配对设备')
          .fontSize(13)
          .fontColor('#757575')
          .width('100%')
          .padding({ left: 16, right: 16, top: 16, bottom: 8 })

        Text('清除全部已配对记录')
          .fontSize(16)
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)
          .onClick(() => {
            DeviceStore.getInstance().clear().then(() => {
              let svc = AppSession.getInstance().getService();
              svc.disconnect();
              svc.reloadTrustCache();
              this.tip = '已清除本地配对记录';
            });
          })

        Text('后台同步 / 通知')
          .fontSize(13)
          .fontColor('#757575')
          .width('100%')
          .padding({ left: 16, right: 16, top: 24, bottom: 8 })

        Text('将在迭代 2 提供前台长时任务与系统通知')
          .fontSize(14)
          .fontColor('#9E9E9E')
          .width('100%')
          .padding(16)
          .backgroundColor(Color.White)

        if (this.tip.length > 0) {
          Text(this.tip)
            .fontSize(12)
            .fontColor('#1B8A4A')
            .padding(16)
            .width('100%')
        }
      }
      .width('100%')
      .layoutWeight(1)
      .backgroundColor('#F5F5F5')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FAFAFA')
  }
}
