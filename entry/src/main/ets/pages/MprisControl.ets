import { common } from '@kit.AbilityKit';
import { AppSession } from '../app/AppSession';
import { MprisPlayerState } from '../service/KdeTypes';
import { DeviceSession } from '../service/DeviceSession';
import { goBack, hostContext, routeParams } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';

interface MprisRouteParams {
  deviceId: string;
}

@Entry
@Component
struct MprisControlPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State player: MprisPlayerState | null = null;
  @State seekValue: number = 0;
  private client: DeviceSession | null = null;
  private posTimer: number = -1;

  aboutToAppear(): void {
    let params = routeParams(this.getUIContext()) as MprisRouteParams;
    if (params && params.deviceId) {
      this.client = AppSession.getInstance().getService().getClientForDevice(params.deviceId);
      AppSession.getInstance().getService().getClient()
        .setMprisChangeListenerForDevice(params.deviceId, (p: MprisPlayerState | null) => {
          this.player = p;
          if (p) {
            this.seekValue = p.pos;
          }
        });
    } else {
      this.client = AppSession.getInstance().getService().getClient().getClient();
    }
    if (this.client) {
      this.client.setMprisChangeListener((p: MprisPlayerState | null) => {
        this.player = p;
        if (p) {
          this.seekValue = p.pos;
        }
      });
      const p = this.client.getMprisPlayer();
      if (p) {
        this.player = p;
        this.seekValue = p.pos;
      }
    }
    this.posTimer = setInterval(() => {
      if (this.player && this.player.isPlaying && this.player.length > 0) {
        const elapsed = Date.now() - this.player.lastPositionTime;
        this.seekValue = Math.min(this.player.pos + elapsed, this.player.length);
      }
    }, 500) as number;
  }

  aboutToDisappear(): void {
    if (this.posTimer >= 0) {
      clearInterval(this.posTimer);
      this.posTimer = -1;
    }
  }

  private getCl(): DeviceSession | null {
    return this.client;
  }

  build() {
    Column() {
      // Top bar
      Row() {
        Text('‹ 返回')
          .fontSize(17)
          .fontColor(UiTheme.primary)
          .padding(16)
          .onClick(() => { goBack(this.getUIContext()); })
        Text('多媒体控制')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(UiTheme.onSurface)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Row().width(70)
      }
      .width('100%')
      .height(52)
      .margin({ top: this.statusBarHeight })

      if (!this.player || this.player.title.length === 0) {
        // Empty state
        Column() {
          Column()
            .width(80).height(80)
            .borderRadius(40)
            .backgroundColor(UiTheme.surfaceVariant)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          Text('未在播放')
            .fontSize(20)
            .fontColor(UiTheme.textMuted)
            .margin({ top: 20 })
          Text('在电脑或手机上播放音乐后\n此处将显示播放控制')
            .fontSize(14)
            .fontColor(UiTheme.textMuted)
            .textAlign(TextAlign.Center)
            .margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else {
        Scroll() {
          Column() {
            // Album art placeholder
            Column()
              .width(220)
              .height(220)
              .borderRadius(16)
              .backgroundColor(UiTheme.surfaceVariant)
              .justifyContent(FlexAlign.Center)
              .alignItems(HorizontalAlign.Center)
              .margin({ top: 36, bottom: 28 })

            // Track info
            Text(this.player.title)
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor(UiTheme.onSurface)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.Center)
              .width('100%')
              .padding({ left: 32, right: 32 })

            Text(this.player.artist)
              .fontSize(15)
              .fontColor(UiTheme.textMuted)
              .maxLines(1)
              .textAlign(TextAlign.Center)
              .width('100%')
              .padding({ left: 32, right: 32 })
              .margin({ top: 8, bottom: 28 })

            // Progress
            if (this.player.canSeek && this.player.length > 0) {
              Column() {
                Slider({
                  value: this.seekValue,
                  min: 0,
                  max: this.player.length,
                  step: 1000
                })
                  .blockColor(UiTheme.primary)
                  .trackColor('#22000000')
                  .selectedColor(UiTheme.primary)
                  .trackThickness(3)
                  .blockSize({ width: 14, height: 14 })
                  .width('100%')

                Row() {
                  Text(this.fmtTime(this.seekValue))
                    .fontSize(12)
                    .fontColor(UiTheme.textMuted)
                  Blank()
                  Text(this.fmtTime(this.player.length))
                    .fontSize(12)
                    .fontColor(UiTheme.textMuted)
                }
                .width('100%')
              }
              .width('100%')
              .padding({ left: 24, right: 24 })
              .margin({ bottom: 28 })
            }

            // Main controls — large play/pause with prev/next on sides
            Row({ space: 32 }) {
              // Previous
              Column() {
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  SymbolGlyph($r('sys.symbol.chevron_left'))
                    .fontSize(22)
                    .fontColor([UiTheme.onSurface])
                }
                .width(48).height(48)
                .backgroundColor(UiTheme.surfaceVariant)
                .onClick(() => { this.getCl()?.mprisPrevious(); })
                Text('上一首')
                  .fontSize(11)
                  .fontColor(UiTheme.textMuted)
                  .margin({ top: 6 })
              }
              .alignItems(HorizontalAlign.Center)

              // Play/Pause - larger
              Column() {
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  SymbolGlyph(this.player.isPlaying ? $r('sys.symbol.pause') : $r('sys.symbol.play'))
                    .fontSize(30)
                    .fontColor([Color.White])
                }
                .width(64).height(64)
                .backgroundColor(UiTheme.primary)
                .onClick(() => { this.getCl()?.mprisPlayPause(); })
                Text(this.player.isPlaying ? '暂停' : '播放')
                  .fontSize(12)
                  .fontColor(UiTheme.textMuted)
                  .margin({ top: 6 })
              }
              .alignItems(HorizontalAlign.Center)

              // Next
              Column() {
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(22)
                    .fontColor([UiTheme.onSurface])
                }
                .width(48).height(48)
                .backgroundColor(UiTheme.surfaceVariant)
                .onClick(() => { this.getCl()?.mprisNext(); })
                Text('下一首')
                  .fontSize(11)
                  .fontColor(UiTheme.textMuted)
                  .margin({ top: 6 })
              }
              .alignItems(HorizontalAlign.Center)
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
            .margin({ bottom: 32 })

            // Secondary controls row
            Row({ space: 20 }) {
              // Shuffle
              Column() {
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  SymbolGlyph($r('sys.symbol.shuffle'))
                    .fontSize(18)
                    .fontColor([this.player.shuffle ? UiTheme.primary : UiTheme.textMuted])
                }
                .width(40).height(40)
                .backgroundColor('#00000000')
                .onClick(() => {
                  // toggle shuffle (placeholder)
                })
                Text('随机')
                  .fontSize(10)
                  .fontColor(UiTheme.textMuted)
              }
              .alignItems(HorizontalAlign.Center)

              // Loop
              Column() {
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  SymbolGlyph($r('sys.symbol.repeat'))
                    .fontSize(18)
                    .fontColor([this.player.loopStatus !== 'None' ? UiTheme.primary : UiTheme.textMuted])
                }
                .width(40).height(40)
                .backgroundColor('#00000000')
                .onClick(() => {
                  // toggle loop (placeholder)
                })
                Text('循环')
                  .fontSize(10)
                  .fontColor(UiTheme.textMuted)
              }
              .alignItems(HorizontalAlign.Center)
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
            .margin({ bottom: 28 })

            // Volume
            Text(`音量  ${this.player.volume}%`)
              .fontSize(13)
              .fontColor(UiTheme.textMuted)
              .margin({ bottom: 10 })

            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.speaker'))
                .fontSize(16)
                .fontColor([UiTheme.textMuted])

              Slider({
                value: this.player.volume >= 0 ? this.player.volume : 50,
                min: 0,
                max: 100,
                step: 1
              })
                .blockColor(UiTheme.primary)
                .trackColor('#22000000')
                .selectedColor(UiTheme.primary)
                .trackThickness(3)
                .blockSize({ width: 14, height: 14 })
                .layoutWeight(1)
                .onChange((value: number) => {
                  this.getCl()?.mprisSetVolume(Math.round(value));
                })

              SymbolGlyph($r('sys.symbol.speaker_wave_3'))
                .fontSize(18)
                .fontColor([UiTheme.textMuted])
            }
            .width('90%')
            .justifyContent(FlexAlign.Center)

            Column().height(this.navBarHeight + 24)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(UiTheme.pageBg)
  }

  private fmtTime(ms: number): string {
    const sec = Math.floor(ms / 1000);
    const min = Math.floor(sec / 60);
    const s = sec % 60;
    return `${min}:${s < 10 ? '0' : ''}${s}`;
  }
}
