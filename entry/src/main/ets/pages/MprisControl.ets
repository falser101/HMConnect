import { AppSession } from '../app/AppSession';
import {
  MprisPlayerState,
  MPRIS_DEFAULT_SEEK_US,
  SystemVolumeSink
} from '../service/KdeTypes';
import { DeviceSession } from '../service/DeviceSession';
import { goBack, routeParams } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';

interface MprisRouteParams {
  deviceId: string;
}

/** Android DEFAULT_VOLUME_STEP */
const VOLUME_STEP: number = 5;
/** Common volume key codes (Android 24/25; some OH builds 16/17). */
const KEY_VOL_UP_A: number = 24;
const KEY_VOL_UP_B: number = 16;
const KEY_VOL_DOWN_A: number = 25;
const KEY_VOL_DOWN_B: number = 17;

@Entry
@Component
struct MprisControlPage {
  @StorageProp('statusBarHeight') statusBarHeight: number = 0;
  @StorageProp('navBarHeight') navBarHeight: number = 0;
  @State player: MprisPlayerState | null = null;
  @State playerNames: string[] = [];
  @State playerSelectOptions: SelectOption[] = [];
  @State selectedPlayerIndex: number = 0;
  @State sinks: SystemVolumeSink[] = [];
  /**
   * Bumps when sink list/fields change so percent/mute icons re-bind
   * (ForEach key stays stable on sink.name to avoid remounting the Slider).
   */
  @State sinkUiVersion: number = 0;
  /** While dragging: live percent label for that sink (immediate UI feedback). */
  @State activeSinkName: string = '';
  @State activeSinkPercent: number = -1;
  @State seekValue: number = 0;
  @State scrubbing: boolean = false;
  /** 0 = playback (MPRIS), 1 = system volume — Android MprisActivity tabs */
  @State currentTabIndex: number = 0;
  /** While user is dragging a sink slider, ignore remote volume echoes for it. */
  private trackingSinkName: string = '';
  private deviceId: string = '';
  private client: DeviceSession | null = null;
  private posTimer: number = -1;

  aboutToAppear(): void {
    let params = routeParams(this.getUIContext()) as MprisRouteParams;
    if (params && params.deviceId) {
      this.deviceId = params.deviceId;
      this.client = AppSession.getInstance().getService().getClientForDevice(params.deviceId);
      const hub = AppSession.getInstance().getService().getClient();
      hub.setMprisChangeListenerForDevice(params.deviceId, (p: MprisPlayerState | null) => {
        this.onPlayerUpdate(p);
      });
      hub.setMprisPlayerListListenerForDevice(params.deviceId, (names: string[]) => {
        this.onPlayerListUpdate(names);
      });
      hub.setSystemVolumeChangeListenerForDevice(params.deviceId, (list: SystemVolumeSink[]) => {
        this.applyRemoteSinks(list);
      });
      this.applyRemoteSinks(hub.getSystemVolumeSinksForDevice(params.deviceId));
      this.onPlayerListUpdate(hub.getMprisPlayerListForDevice(params.deviceId));
      hub.requestMprisPlayerListForDevice(params.deviceId);
      hub.requestSystemVolumeSinksForDevice(params.deviceId);
    } else {
      this.client = AppSession.getInstance().getService().getClient().getClient();
    }
    if (this.client) {
      this.client.setMprisChangeListener((p: MprisPlayerState | null) => {
        this.onPlayerUpdate(p);
      });
      this.client.setMprisPlayerListListener((names: string[]) => {
        this.onPlayerListUpdate(names);
      });
      this.client.setSystemVolumeChangeListener((list: SystemVolumeSink[]) => {
        this.applyRemoteSinks(list);
      });
      this.onPlayerUpdate(this.client.getMprisPlayer());
      this.onPlayerListUpdate(this.client.getMprisPlayerList());
      this.applyRemoteSinks(this.client.getSystemVolumeSinks());
      this.client.requestMprisPlayerList();
      this.client.requestSystemVolumeSinks();
    }
    this.posTimer = setInterval(() => {
      if (this.scrubbing) {
        return;
      }
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

  private onPlayerUpdate(p: MprisPlayerState | null): void {
    this.player = p;
    if (p && !this.scrubbing) {
      if (p.isPlaying && p.length > 0) {
        const elapsed = Date.now() - p.lastPositionTime;
        this.seekValue = Math.min(p.pos + elapsed, p.length);
      } else {
        this.seekValue = p.pos;
      }
    }
    if (p) {
      const idx = this.playerNames.indexOf(p.player);
      if (idx >= 0) {
        this.selectedPlayerIndex = idx;
      }
    }
  }

  private onPlayerListUpdate(names: string[]): void {
    this.playerNames = names.slice();
    const opts: SelectOption[] = [];
    for (let i = 0; i < names.length; i++) {
      const o: SelectOption = { value: names[i] };
      opts.push(o);
    }
    this.playerSelectOptions = opts;
    if (this.player) {
      const idx = names.indexOf(this.player.player);
      this.selectedPlayerIndex = idx >= 0 ? idx : 0;
    } else {
      this.selectedPlayerIndex = 0;
    }
  }

  private getCl(): DeviceSession | null {
    return this.client;
  }

  private selectPlayer(index: number): void {
    if (index < 0 || index >= this.playerNames.length) {
      return;
    }
    const name = this.playerNames[index];
    this.selectedPlayerIndex = index;
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient()
        .selectMprisPlayerForDevice(this.deviceId, name);
    } else {
      this.getCl()?.selectMprisPlayer(name);
    }
  }

  private callPlayPause(): void {
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient().mprisPlayPauseForDevice(this.deviceId);
    } else {
      this.getCl()?.mprisPlayPause();
    }
  }

  private callStop(): void {
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient().mprisStopForDevice(this.deviceId);
    } else {
      this.getCl()?.mprisStop();
    }
  }

  private callPrevious(): void {
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient().mprisPreviousForDevice(this.deviceId);
    } else {
      this.getCl()?.mprisPrevious();
    }
  }

  private callNext(): void {
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient().mprisNextForDevice(this.deviceId);
    } else {
      this.getCl()?.mprisNext();
    }
  }

  private callSeek(offsetUs: number): void {
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient().mprisSeekForDevice(this.deviceId, offsetUs);
    } else {
      this.getCl()?.mprisSeek(offsetUs);
    }
  }

  private callSetPosition(ms: number): void {
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient().mprisSetPositionForDevice(this.deviceId, ms);
    } else {
      this.getCl()?.mprisSetPosition(ms);
    }
  }

  private callSetVolume(vol: number): void {
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient().mprisSetVolumeForDevice(this.deviceId, vol);
    } else {
      this.getCl()?.mprisSetVolume(vol);
    }
  }

  private callVolumeStep(step: number): void {
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient().mprisVolumeStepForDevice(this.deviceId, step);
    } else {
      this.getCl()?.mprisVolumeStep(step);
    }
  }

  private callToggleLoop(): void {
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient().mprisToggleLoopForDevice(this.deviceId);
    } else {
      this.getCl()?.mprisToggleLoop();
    }
  }

  private callToggleShuffle(): void {
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient().mprisToggleShuffleForDevice(this.deviceId);
    } else {
      this.getCl()?.mprisToggleShuffle();
    }
  }

  private isSeekAllowed(): boolean {
    const p = this.player;
    if (!p) {
      return false;
    }
    return p.canSeek && p.length >= 0 && p.pos >= 0;
  }

  private isSetVolumeAllowed(): boolean {
    return this.player !== null && this.player.volume > -1;
  }

  private albumArtSrc(): string {
    const p = this.player;
    if (!p) {
      return '';
    }
    if (p.albumArtLocalPath.length > 0) {
      if (p.albumArtLocalPath.startsWith('file://')) {
        return p.albumArtLocalPath;
      }
      return `file://${p.albumArtLocalPath}`;
    }
    if (p.albumArtUrl.startsWith('http://') || p.albumArtUrl.startsWith('https://')) {
      return p.albumArtUrl;
    }
    return '';
  }

  /** Deep-copy sink rows so @State always sees new object identities. */
  private cloneSinks(list: SystemVolumeSink[]): SystemVolumeSink[] {
    const next: SystemVolumeSink[] = [];
    for (let i = 0; i < list.length; i++) {
      const s = list[i];
      next.push({
        name: s.name,
        description: s.description,
        volume: s.volume,
        maxVolume: s.maxVolume,
        muted: s.muted,
        enabled: s.enabled
      });
    }
    return next;
  }

  /**
   * Apply peer/session sink list. While the user is dragging one sink, keep that
   * sink's local volume (avoid percentage jumping back from delayed echoes).
   */
  private applyRemoteSinks(list: SystemVolumeSink[]): void {
    const next = this.cloneSinks(list);
    if (this.trackingSinkName.length > 0) {
      let localVol: number = -1;
      for (let i = 0; i < this.sinks.length; i++) {
        if (this.sinks[i].name === this.trackingSinkName) {
          localVol = this.sinks[i].volume;
          break;
        }
      }
      if (localVol >= 0) {
        for (let j = 0; j < next.length; j++) {
          if (next[j].name === this.trackingSinkName) {
            next[j].volume = localVol;
            next[j].muted = false;
            break;
          }
        }
      }
    }
    this.sinks = next;
    this.sinkUiVersion = this.sinkUiVersion + 1;
  }

  private patchLocalSinkVolume(name: string, volume: number): void {
    const next: SystemVolumeSink[] = [];
    const vol = Math.round(volume);
    for (let i = 0; i < this.sinks.length; i++) {
      const s = this.sinks[i];
      if (s.name === name) {
        next.push({
          name: s.name,
          description: s.description,
          volume: vol,
          maxVolume: s.maxVolume,
          muted: false,
          enabled: s.enabled
        });
      } else {
        next.push({
          name: s.name,
          description: s.description,
          volume: s.volume,
          maxVolume: s.maxVolume,
          muted: s.muted,
          enabled: s.enabled
        });
      }
    }
    this.sinks = next;
    this.sinkUiVersion = this.sinkUiVersion + 1;
  }

  private patchLocalSinkMute(name: string, muted: boolean): void {
    const next: SystemVolumeSink[] = [];
    for (let i = 0; i < this.sinks.length; i++) {
      const s = this.sinks[i];
      if (s.name === name) {
        next.push({
          name: s.name,
          description: s.description,
          volume: s.volume,
          maxVolume: s.maxVolume,
          muted: muted,
          enabled: s.enabled
        });
      } else {
        next.push({
          name: s.name,
          description: s.description,
          volume: s.volume,
          maxVolume: s.maxVolume,
          muted: s.muted,
          enabled: s.enabled
        });
      }
    }
    this.sinks = next;
    this.sinkUiVersion = this.sinkUiVersion + 1;
  }

  private patchLocalSinkDefault(name: string): void {
    const next: SystemVolumeSink[] = [];
    for (let i = 0; i < this.sinks.length; i++) {
      const s = this.sinks[i];
      next.push({
        name: s.name,
        description: s.description,
        volume: s.volume,
        maxVolume: s.maxVolume,
        muted: s.muted,
        enabled: s.name === name
      });
    }
    this.sinks = next;
    this.sinkUiVersion = this.sinkUiVersion + 1;
  }

  private hubSetVolume(name: string, vol: number): void {
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient()
        .setSystemVolumeForDevice(this.deviceId, name, vol);
    } else {
      this.getCl()?.setSystemVolume(name, vol);
    }
  }

  private hubSetMute(name: string, muted: boolean): void {
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient()
        .setSystemVolumeMuteForDevice(this.deviceId, name, muted);
    } else {
      this.getCl()?.setSystemVolumeMute(name, muted);
    }
  }

  private hubSetDefault(name: string): void {
    if (this.deviceId.length > 0) {
      AppSession.getInstance().getService().getClient()
        .setSystemVolumeDefaultForDevice(this.deviceId, name);
    } else {
      this.getCl()?.setSystemVolumeDefault(name);
    }
  }

  private volumePercentOf(name: string, volume: number, maxVolume: number): number {
    if (maxVolume <= 0) {
      return 0;
    }
    return Math.round((volume / maxVolume) * 100);
  }

  /**
   * Percent label: prefer live drag state so Text updates every onChange
   * without remounting ForEach items.
   */
  private displaySinkPercent(sink: SystemVolumeSink): number {
    if (this.activeSinkName === sink.name && this.activeSinkPercent >= 0) {
      return this.activeSinkPercent;
    }
    // Depend on sinkUiVersion so remote/local patches refresh the label
    const _v = this.sinkUiVersion;
    if (_v < 0) {
      return 0;
    }
    for (let i = 0; i < this.sinks.length; i++) {
      if (this.sinks[i].name === sink.name) {
        const s = this.sinks[i];
        return this.volumePercentOf(s.name, s.volume, s.maxVolume);
      }
    }
    return this.volumePercentOf(sink.name, sink.volume, sink.maxVolume);
  }

  private sinkVolumeValue(name: string, fallback: number): number {
    const _v = this.sinkUiVersion;
    if (_v < 0) {
      return fallback;
    }
    for (let i = 0; i < this.sinks.length; i++) {
      if (this.sinks[i].name === name) {
        return this.sinks[i].volume;
      }
    }
    return fallback;
  }

  private sinkMutedValue(name: string, fallback: boolean): boolean {
    const _v = this.sinkUiVersion;
    if (_v < 0) {
      return fallback;
    }
    for (let i = 0; i < this.sinks.length; i++) {
      if (this.sinks[i].name === name) {
        return this.sinks[i].muted;
      }
    }
    return fallback;
  }

  private isVolUp(code: number): boolean {
    return code === KEY_VOL_UP_A || code === KEY_VOL_UP_B;
  }

  private isVolDown(code: number): boolean {
    return code === KEY_VOL_DOWN_A || code === KEY_VOL_DOWN_B;
  }

  private handleVolumeKey(keyCode: number): boolean {
    if (this.currentTabIndex === 1) {
      if (this.isVolUp(keyCode)) {
        this.stepDefaultSink(VOLUME_STEP);
        return true;
      }
      if (this.isVolDown(keyCode)) {
        this.stepDefaultSink(-VOLUME_STEP);
        return true;
      }
      return false;
    }
    if (!this.isSetVolumeAllowed()) {
      return false;
    }
    if (this.isVolUp(keyCode)) {
      this.callVolumeStep(VOLUME_STEP);
      return true;
    }
    if (this.isVolDown(keyCode)) {
      this.callVolumeStep(-VOLUME_STEP);
      return true;
    }
    return false;
  }

  private stepDefaultSink(percent: number): void {
    let sink: SystemVolumeSink | null = null;
    for (let i = 0; i < this.sinks.length; i++) {
      if (this.sinks[i].enabled) {
        sink = this.sinks[i];
        break;
      }
    }
    if (!sink && this.sinks.length > 0) {
      sink = this.sinks[0];
    }
    if (!sink || sink.maxVolume <= 0) {
      return;
    }
    const step = Math.round(sink.maxVolume * percent / 100);
    const next = Math.max(0, Math.min(sink.maxVolume, sink.volume + step));
    if (next !== sink.volume) {
      this.patchLocalSinkVolume(sink.name, next);
      this.hubSetVolume(sink.name, next);
    }
  }

  private loopLabel(): string {
    if (!this.player) {
      return '循环';
    }
    if (this.player.loopStatus === 'Track') {
      return '单曲';
    }
    if (this.player.loopStatus === 'Playlist') {
      return '列表';
    }
    return '循环';
  }

  private fmtTime(ms: number): string {
    const sec = Math.floor(ms / 1000);
    const min = Math.floor(sec / 60);
    const s = sec % 60;
    return `${min}:${s < 10 ? '0' : ''}${s}`;
  }

  @Builder
  TabHeader() {
    Row() {
      Text('播放')
        .fontSize(15)
        .fontWeight(this.currentTabIndex === 0 ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentTabIndex === 0 ? UiTheme.primary : UiTheme.textMuted)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 12 })
        .onClick(() => { this.currentTabIndex = 0; })
      Text('系统音量')
        .fontSize(15)
        .fontWeight(this.currentTabIndex === 1 ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentTabIndex === 1 ? UiTheme.primary : UiTheme.textMuted)
        .layoutWeight(1)
        .textAlign(TextAlign.Center)
        .padding({ top: 12, bottom: 12 })
        .onClick(() => { this.currentTabIndex = 1; })
    }
    .width('100%')
    .backgroundColor(UiTheme.surfaceVariant)

    Row() {
      Column()
        .width('50%')
        .height(2)
        .backgroundColor(this.currentTabIndex === 0 ? UiTheme.primary : Color.Transparent)
      Column()
        .width('50%')
        .height(2)
        .backgroundColor(this.currentTabIndex === 1 ? UiTheme.primary : Color.Transparent)
    }
    .width('100%')
  }

  @Builder
  PlayerPicker() {
    if (this.playerNames.length === 0) {
      Text('无可用播放器')
        .fontSize(13)
        .fontColor(UiTheme.textMuted)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ left: 24, right: 24, top: 12, bottom: 4 })
    } else {
      Row() {
        Text('播放器')
          .fontSize(13)
          .fontColor(UiTheme.textMuted)
          .margin({ right: 12 })
        Select(this.playerSelectOptions)
          .selected(this.selectedPlayerIndex)
          .value(this.playerNames[this.selectedPlayerIndex] ?? '')
          .font({ size: 14 })
          .selectedOptionFont({ size: 14 })
          .optionFont({ size: 14 })
          .layoutWeight(1)
          .onSelect((index: number) => {
            this.selectPlayer(index);
          })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 12, bottom: 4 })
    }
  }

  @Builder
  AlbumArt() {
    if (this.albumArtSrc().length > 0) {
      Image(this.albumArtSrc())
        .width(220)
        .height(220)
        .borderRadius(16)
        .objectFit(ImageFit.Cover)
        .backgroundColor(UiTheme.surfaceVariant)
        .margin({ top: 20, bottom: 20 })
    } else {
      Column()
        .width(220)
        .height(220)
        .borderRadius(16)
        .backgroundColor(UiTheme.surfaceVariant)
        .margin({ top: 20, bottom: 20 })
    }
  }

  @Builder
  PlayerTab() {
    if (!this.player) {
      Column() {
        this.PlayerPicker()
        Column()
          .width(80).height(80)
          .borderRadius(40)
          .backgroundColor(UiTheme.surfaceVariant)
          .margin({ top: 40 })
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
      .alignItems(HorizontalAlign.Center)
    } else {
      Scroll() {
        Column() {
          this.PlayerPicker()
          this.AlbumArt()

          Text(this.player.title.length > 0 ? this.player.title : this.player.player)
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
            .margin({ top: 8, bottom: 20 })

          if (this.isSeekAllowed() && this.player.length > 0) {
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
                .onChange((value: number, mode: SliderChangeMode) => {
                  if (mode === SliderChangeMode.Begin) {
                    this.scrubbing = true;
                  }
                  this.seekValue = value;
                  if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                    this.scrubbing = false;
                    this.callSetPosition(Math.round(value));
                  }
                })

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
            .margin({ bottom: 20 })
          }

          // rew / prev / play / next / ff
          Row({ space: 10 }) {
            if (this.isSeekAllowed()) {
              Column() {
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  Text('«')
                    .fontSize(18)
                    .fontColor(UiTheme.onSurface)
                }
                .width(40).height(40)
                .backgroundColor(UiTheme.surfaceVariant)
                .onClick(() => { this.callSeek(-MPRIS_DEFAULT_SEEK_US); })
                Text('快退')
                  .fontSize(10)
                  .fontColor(UiTheme.textMuted)
                  .margin({ top: 4 })
              }
              .alignItems(HorizontalAlign.Center)
            }

            if (this.player.canGoPrevious || this.player.canGoNext) {
              Column() {
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  SymbolGlyph($r('sys.symbol.chevron_left'))
                    .fontSize(20)
                    .fontColor([UiTheme.onSurface])
                }
                .width(44).height(44)
                .backgroundColor(UiTheme.surfaceVariant)
                .enabled(this.player.canGoPrevious)
                .opacity(this.player.canGoPrevious ? 1 : 0.4)
                .onClick(() => { this.callPrevious(); })
                Text('上一首')
                  .fontSize(10)
                  .fontColor(UiTheme.textMuted)
                  .margin({ top: 4 })
              }
              .alignItems(HorizontalAlign.Center)
            }

            Column() {
              Button({ type: ButtonType.Circle, stateEffect: true }) {
                SymbolGlyph(this.player.isPlaying ? $r('sys.symbol.pause') : $r('sys.symbol.play'))
                  .fontSize(28)
                  .fontColor([Color.White])
              }
              .width(64).height(64)
              .backgroundColor(UiTheme.primary)
              .enabled(this.player.isPlaying ? this.player.canPause : this.player.canPlay)
              .onClick(() => { this.callPlayPause(); })
              Text(this.player.isPlaying ? '暂停' : '播放')
                .fontSize(11)
                .fontColor(UiTheme.textMuted)
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Center)

            if (this.player.canGoPrevious || this.player.canGoNext) {
              Column() {
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(20)
                    .fontColor([UiTheme.onSurface])
                }
                .width(44).height(44)
                .backgroundColor(UiTheme.surfaceVariant)
                .enabled(this.player.canGoNext)
                .opacity(this.player.canGoNext ? 1 : 0.4)
                .onClick(() => { this.callNext(); })
                Text('下一首')
                  .fontSize(10)
                  .fontColor(UiTheme.textMuted)
                  .margin({ top: 4 })
              }
              .alignItems(HorizontalAlign.Center)
            }

            if (this.isSeekAllowed()) {
              Column() {
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  Text('»')
                    .fontSize(18)
                    .fontColor(UiTheme.onSurface)
                }
                .width(40).height(40)
                .backgroundColor(UiTheme.surfaceVariant)
                .onClick(() => { this.callSeek(MPRIS_DEFAULT_SEEK_US); })
                Text('快进')
                  .fontSize(10)
                  .fontColor(UiTheme.textMuted)
                  .margin({ top: 4 })
              }
              .alignItems(HorizontalAlign.Center)
            }
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .margin({ bottom: 16 })

          // Stop + loop + shuffle
          Row({ space: 20 }) {
            Column() {
              Button({ type: ButtonType.Circle, stateEffect: true }) {
                Text('■')
                  .fontSize(14)
                  .fontColor(UiTheme.onSurface)
              }
              .width(40).height(40)
              .backgroundColor(UiTheme.surfaceVariant)
              .onClick(() => { this.callStop(); })
              Text('停止')
                .fontSize(10)
                .fontColor(UiTheme.textMuted)
                .margin({ top: 4 })
            }
            .alignItems(HorizontalAlign.Center)

            if (this.player.shuffleAllowed) {
              Column() {
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  SymbolGlyph($r('sys.symbol.shuffle'))
                    .fontSize(18)
                    .fontColor([this.player.shuffle ? UiTheme.primary : UiTheme.textMuted])
                }
                .width(40).height(40)
                .backgroundColor(UiTheme.surfaceVariant)
                .onClick(() => { this.callToggleShuffle(); })
                Text('随机')
                  .fontSize(10)
                  .fontColor(UiTheme.textMuted)
                  .margin({ top: 4 })
              }
              .alignItems(HorizontalAlign.Center)
            }

            if (this.player.loopStatusAllowed) {
              Column() {
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  SymbolGlyph($r('sys.symbol.repeat'))
                    .fontSize(18)
                    .fontColor([
                      this.player.loopStatus !== 'None' && this.player.loopStatus.length > 0
                        ? UiTheme.primary : UiTheme.textMuted
                    ])
                }
                .width(40).height(40)
                .backgroundColor(UiTheme.surfaceVariant)
                .onClick(() => { this.callToggleLoop(); })
                Text(this.loopLabel())
                  .fontSize(10)
                  .fontColor(UiTheme.textMuted)
                  .margin({ top: 4 })
              }
              .alignItems(HorizontalAlign.Center)
            }
          }
          .justifyContent(FlexAlign.Center)
          .width('100%')
          .margin({ bottom: 24 })

          if (this.isSetVolumeAllowed()) {
            Text(`播放器音量  ${this.player.volume}%`)
              .fontSize(13)
              .fontColor(UiTheme.textMuted)
              .margin({ bottom: 10 })

            Row({ space: 8 }) {
              SymbolGlyph($r('sys.symbol.speaker'))
                .fontSize(16)
                .fontColor([UiTheme.textMuted])

              Slider({
                value: this.player.volume,
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
                  this.callSetVolume(Math.round(value));
                })

              SymbolGlyph($r('sys.symbol.speaker_wave_3'))
                .fontSize(18)
                .fontColor([UiTheme.textMuted])
            }
            .width('90%')
            .justifyContent(FlexAlign.Center)
          }

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

  @Builder
  SystemVolumeTab() {
    if (this.sinks.length === 0) {
      Column() {
        Text('暂无音频输出设备')
          .fontSize(18)
          .fontColor(UiTheme.textMuted)
          .margin({ top: 40 })
        Text('对端需开启「系统音量」插件\n并重新连接后即可调节')
          .fontSize(14)
          .fontColor(UiTheme.textMuted)
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
        Button('刷新')
          .margin({ top: 20 })
          .onClick(() => {
            if (this.deviceId.length > 0) {
              AppSession.getInstance().getService().getClient()
                .requestSystemVolumeSinksForDevice(this.deviceId);
            } else {
              this.getCl()?.requestSystemVolumeSinks();
            }
          })
      }
      .width('100%')
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Center)
    } else {
      Scroll() {
        Column({ space: 12 }) {
          ForEach(this.sinks, (sink: SystemVolumeSink) => {
            Column() {
              Row() {
                Radio({ value: sink.name, group: 'sysvol_default' })
                  .checked(sink.enabled)
                  .onChange((isChecked: boolean) => {
                    if (isChecked) {
                      this.patchLocalSinkDefault(sink.name);
                      this.hubSetDefault(sink.name);
                    }
                  })
                Text(sink.description.length > 0 ? sink.description : sink.name)
                  .fontSize(15)
                  .fontColor(UiTheme.onSurface)
                  .fontWeight(sink.enabled ? FontWeight.Medium : FontWeight.Normal)
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .margin({ left: 8 })
                  .onClick(() => {
                    this.patchLocalSinkDefault(sink.name);
                    this.hubSetDefault(sink.name);
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)

              Row({ space: 10 }) {
                Button({ type: ButtonType.Circle, stateEffect: true }) {
                  SymbolGlyph(this.sinkMutedValue(sink.name, sink.muted)
                    ? $r('sys.symbol.speaker')
                    : $r('sys.symbol.speaker_wave_2'))
                    .fontSize(18)
                    .fontColor([
                      this.sinkMutedValue(sink.name, sink.muted)
                        ? UiTheme.textMuted : UiTheme.onSurface
                    ])
                }
                .width(40).height(40)
                .backgroundColor(UiTheme.surfaceVariant)
                .onClick(() => {
                  const nextMuted = !this.sinkMutedValue(sink.name, sink.muted);
                  this.patchLocalSinkMute(sink.name, nextMuted);
                  this.hubSetMute(sink.name, nextMuted);
                })

                Slider({
                  value: this.sinkVolumeValue(sink.name, sink.volume),
                  min: 0,
                  max: sink.maxVolume > 0 ? sink.maxVolume : 100,
                  step: Math.max(1, Math.floor((sink.maxVolume > 0 ? sink.maxVolume : 100) / 100))
                })
                  .blockColor(UiTheme.primary)
                  .trackColor('#22000000')
                  .selectedColor(UiTheme.primary)
                  .trackThickness(3)
                  .blockSize({ width: 14, height: 14 })
                  .layoutWeight(1)
                  .onChange((value: number, mode: SliderChangeMode) => {
                    if (mode === SliderChangeMode.Begin) {
                      this.trackingSinkName = sink.name;
                    }
                    const maxV = sink.maxVolume > 0 ? sink.maxVolume : 100;
                    // Live percent @State — updates Text every drag step
                    this.activeSinkName = sink.name;
                    this.activeSinkPercent = this.volumePercentOf(sink.name, value, maxV);
                    this.patchLocalSinkVolume(sink.name, value);
                    this.hubSetVolume(sink.name, value);
                    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                      this.trackingSinkName = '';
                      // Keep percent from sinks[]; clear live overlay
                      this.activeSinkName = '';
                      this.activeSinkPercent = -1;
                    }
                  })

                Text(`${this.displaySinkPercent(sink)}%`)
                  .fontSize(12)
                  .fontColor(UiTheme.textMuted)
                  .width(40)
                  .textAlign(TextAlign.End)
              }
              .width('100%')
              .margin({ top: 8 })
            }
            .width('100%')
            .padding(16)
            .borderRadius(12)
            .backgroundColor(UiTheme.surfaceVariant)
          }, (sink: SystemVolumeSink) => sink.name)

          Column().height(this.navBarHeight + 24)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 16 })
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
  }

  build() {
    Column() {
      // Continuous chrome under transparent status bar
      Column() {
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
      }
      .width('100%')
      .padding({ top: this.statusBarHeight })
      .backgroundColor(UiTheme.surface)
      .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])

      this.TabHeader()

      if (this.currentTabIndex === 0) {
        this.PlayerTab()
      } else {
        this.SystemVolumeTab()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(UiTheme.pageBg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => {
      // KeyType.Down === 0 on most builds; also accept without filter for reliability
      if (this.handleVolumeKey(event.keyCode)) {
        event.stopPropagation();
      }
    })
  }
}
