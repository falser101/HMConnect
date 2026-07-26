import { FindMyPhoneHelper } from '../common/FindMyPhoneHelper';
import { AppSession } from '../app/AppSession';
import { goBack } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';

/**
 * Align with Android FindMyPhoneActivity:
 * full-screen primary action button labeled "已发现" / stop ringing.
 */
@Entry
@Component
struct FindMyPhone {
  @State peerName: string = '';
  @State ringing: boolean = true;
  @State pulse: boolean = false;
  @State buttonScale: number = 1;
  private subId: number = -1;
  private pulseTimer: number = -1;

  aboutToAppear() {
    AppSession.getInstance().markFindPhonePageOpen(true);
    let helper = FindMyPhoneHelper.getInstance();
    this.peerName = helper.getPeerName();
    this.ringing = helper.isActive();
    this.subId = helper.subscribe((active: boolean, name: string) => {
      this.ringing = active;
      if (name.length > 0) {
        this.peerName = name;
      }
      if (!active) {
        this.stopPulseAnim();
        setTimeout(() => {
          goBack(this.getUIContext());
        }, 200);
      }
    });
    this.startPulseAnim();
  }

  aboutToDisappear() {
    AppSession.getInstance().markFindPhonePageOpen(false);
    if (this.subId >= 0) {
      FindMyPhoneHelper.getInstance().unsubscribe(this.subId);
      this.subId = -1;
    }
    this.stopPulseAnim();
  }

  private startPulseAnim(): void {
    this.stopPulseAnim();
    this.pulseTimer = setInterval(() => {
      this.getUIContext().animateTo({
        duration: 450,
        curve: Curve.EaseInOut
      }, () => {
        this.pulse = !this.pulse;
        this.buttonScale = this.pulse ? 1.02 : 1.0;
      });
    }, 500) as number;
  }

  private stopPulseAnim(): void {
    if (this.pulseTimer >= 0) {
      clearInterval(this.pulseTimer);
      this.pulseTimer = -1;
    }
  }

  private onStopRing(): void {
    FindMyPhoneHelper.getInstance().stop();
    this.ringing = false;
    goBack(this.getUIContext());
  }

  build() {
    Column() {
      // Android: full-screen button with findmyphone_found text
      Button(this.ringing ? '已发现' : '已关闭')
        .width('100%')
        .layoutWeight(1)
        .fontSize(50)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.ringing ? Color.White : '#EEEEEE')
        .backgroundColor(this.ringing
          ? (this.pulse ? UiTheme.findPhone : UiTheme.findPhoneDark)
          : '#424242')
        .borderRadius(0)
        .scale({ x: this.buttonScale, y: this.buttonScale })
        .animation({ duration: 450, curve: Curve.EaseInOut })
        .onClick(() => {
          if (this.ringing) {
            this.onStopRing();
          } else {
            goBack(this.getUIContext());
          }
        })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.ringing
      ? (this.pulse ? UiTheme.findPhone : UiTheme.findPhoneDark)
      : '#424242')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }
}
