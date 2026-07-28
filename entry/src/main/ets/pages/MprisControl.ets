import { common } from '@kit.AbilityKit';
import { AppSession } from '../app/AppSession';
import { MprisPlayerState } from '../service/KdeTypes';
import { KdeClient } from '../service/KdeClient';
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
  @State seekProgress: number = 0;
  private client: KdeClient | null = null;
  private posTimer: number = -1;

  aboutToAppear(): void {
    let params = routeParams(this.getUIContext()) as MprisRouteParams;
    if (params && params.deviceId) {
      this.client = AppSession.getInstance().getService().getClientForDevice(params.deviceId);
    } else {
      this.client = AppSession.getInstance().getService().getClient();
    }
    if (this.client) {
      this.client.setMprisChangeListener((p: MprisPlayerState | null) => {
        this.player = p;
      });
      const p = this.client.getMprisPlayer();
      if (p) {
        this.player = p;
      }
    }
    this.startPosTimer();
  }

  aboutToDisappear(): void {
    this.stopPosTimer();
  }

  private startPosTimer(): void {
    this.stopPosTimer();
    this.posTimer = setInterval(() => {
      if (this.player && this.player.isPlaying && this.player.length > 0) {
        const elapsed = Date.now() - this.player.lastPositionTime;
        const newPos = Math.min(this.player.pos + elapsed, this.player.length);
        this.seekProgress = newPos;
      }
    }, 500) as number;
  }

  private stopPosTimer(): void {
    if (this.posTimer >= 0) {
      clearInterval(this.posTimer);
      this.posTimer = -1;
    }
  }

  private client(): KdeClient | null {
    return this.client;
  }

  build() {
    Column() {
      // Top bar
      Row() {
        Text('←')
          .fontSize(24)
          .fontColor(UiTheme.onSurface)
          .padding(12)
          .onClick(() => { goBack(this.getUIContext()); })
        Text('多媒体控制')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(UiTheme.onSurface)
          .layoutWeight(1)
        // Spacer
        Row().width(44)
      }
      .width('100%')
      .height(48)
      .margin({ top: this.statusBarHeight })

      if (!this.player || this.player.title.length === 0) {
        // Empty state
        Column() {
          Text('未在播放')
            .fontSize(28)
            .fontColor(UiTheme.textMuted)
            .margin({ top: 80 })
          Text('请在电脑/手机端播放音乐')
            .fontSize(14)
            .fontColor(UiTheme.textMuted)
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
            Row() {
              Column()
                .width(200)
                .height(200)
                .borderRadius(12)
                .backgroundColor(UiTheme.surfaceVariant)
                .justifyContent(FlexAlign.Center)
                .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .margin({ top: 32, bottom: 24 })

            // Now playing info
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
              .fontSize(16)
              .fontColor(UiTheme.textMuted)
              .maxLines(1)
              .textAlign(TextAlign.Center)
              .width('100%')
              .padding({ left: 32, right: 32 })
              .margin({ top: 8, bottom: 24 })

            // Progress bar
            if (this.player.canSeek && this.player.length > 0) {
              Column() {
                Slider({
                  value: this.seekProgress,
                  min: 0,
                  max: this.player.length,
                  step: 1000
                })
                  .blockColor(UiTheme.primary)
                  .trackColor(UiTheme.surfaceVariant)
                  .selectedColor(UiTheme.primary)
                  .width('100%')

                Row() {
                  Text(this.formatTime(this.seekProgress))
                    .fontSize(12)
                    .fontColor(UiTheme.textMuted)
                  Blank()
                  Text(this.formatTime(this.player.length))
                    .fontSize(12)
                    .fontColor(UiTheme.textMuted)
                }
                .width('100%')
              }
              .width('100%')
              .padding({ left: 32, right: 32 })
              .margin({ bottom: 20 })
            }

            // Control buttons row 1
            Row({ space: 16 }) {
              this.CtrlBtn('⏮', '上一首', () => { this.client()?.mprisPrevious(); })
              this.CtrlBtn('▶️', this.player.isPlaying ? '暂停' : '播放', () => { this.client()?.mprisPlayPause(); })
              this.CtrlBtn('⏭', '下一首', () => { this.client()?.mprisNext(); })
            }
            .justifyContent(FlexAlign.Center)
            .width('100%')
            .margin({ bottom: 24 })

            // Volume
            if (this.player.volume >= 0) {
              Text(`音量: ${this.player.volume}%`)
                .fontSize(14)
                .fontColor(UiTheme.textMuted)
                .margin({ bottom: 8 })

              Slider({
                value: this.player.volume,
                min: 0,
                max: 100,
                step: 1
              })
                .blockColor(UiTheme.primary)
                .trackColor(UiTheme.surfaceVariant)
                .selectedColor(UiTheme.primary)
                .width('80%')
                .onChange((value: number) => {
                  this.client()?.mprisSetVolume(Math.round(value));
                })
            }

            Column().height(this.navBarHeight + 32)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Center)
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(UiTheme.pageBg)
  }

  @Builder
  CtrlBtn(icon: string, label: string, action: () => void) {
    Column() {
      Button(icon)
        .width(56)
        .height(56)
        .fontSize(28)
        .borderRadius(28)
        .backgroundColor(UiTheme.surfaceVariant)
        .fontColor(UiTheme.onSurface)
        .onClick(action)
      Text(label)
        .fontSize(11)
        .fontColor(UiTheme.textMuted)
        .margin({ top: 4 })
    }
    .alignItems(HorizontalAlign.Center)
  }

  private formatTime(ms: number): string {
    const sec = Math.floor(ms / 1000);
    const min = Math.floor(sec / 60);
    const s = sec % 60;
    return `${min}:${s < 10 ? '0' : ''}${s}`;
  }
}
