import { AppSession } from '../app/AppSession';
import {
  MprisPlayerState,
  MPRIS_DEFAULT_SEEK_US,
  SystemVolumeSink
} from '../service/KdeTypes';
import { DeviceSession } from '../service/DeviceSession';
import { goBack, routeParams, hostContext } from '../common/NavUtil';
import { UiTheme } from '../common/ui/UiTheme';
import { PluginPrefsStore } from '../store/PluginPrefsStore';

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
  /** Seek step in µs (Android mpris_time preference, default 10s). */
  private seekStepUs: number = MPRIS_DEFAULT_SEEK_US;

  aboutToAppear(): void {
    let params = routeParams(this.getUIContext()) as MprisRouteParams;
    if (params && params.deviceId) {
      this.deviceId = params.deviceId;
      const ctx = hostContext(this.getUIContext());
      if (ctx) {
        PluginPrefsStore.getInstance().ensureInit(ctx).then(() => {
          const secs: number = PluginPrefsStore.getInstance().getMprisTimeSeconds(this.deviceId);
          if (secs > 0) {
            this.seekStepUs = secs * 1000000;
          }
        });
      }
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
    // Android positionSeekUpdateRunnable: 1s tick while playing
    this.posTimer = setInterval(() => {
      if (this.scrubbing) {
        return;
      }
      const p = this.player;
      if (p && p.isPlaying && this.isSeekAllowedFor(p)) {
        const elapsed = Date.now() - p.lastPositionTime;
        let next = p.pos + elapsed;
        if (p.length >= 0) {
          next = Math.min(next, p.length);
        }
        this.seekValue = Math.max(0, next);
      }
    }, 1000) as number;
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
      // Android: position = lastPosition + elapsed when playing
      if (p.isPlaying && this.isSeekAllowedFor(p)) {
        const elapsed = Date.now() - p.lastPositionTime;
        let next = p.pos + elapsed;
        if (p.length >= 0) {
          next = Math.min(next, p.length);
        }
        this.seekValue = Math.max(0, next);
      } else {
        this.seekValue = Math.max(0, p.pos);
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

  /**
   * Android MprisPlayer.isSeekAllowed:
   * seekAllowed && length >= 0 && position >= 0
   * → progress bar + rew/ff visible only when true (music yes, many podcasts no).
   */
  private isSeekAllowedFor(p: MprisPlayerState | null): boolean {
    if (!p) {
      return false;
    }
    return p.canSeek && p.length >= 0 && p.pos >= 0;
  }

  private isSeekAllowed(): boolean {
    return this.isSeekAllowedFor(this.player);
  }

  /** Android isSetVolumeAllowed: volume > -1 */
  private isSetVolumeAllowed(): boolean {
    return this.player !== null && this.player.volume > -1;
  }

  /** Android: show prev+next together if either is allowed. */
  private showPrevNext(): boolean {
    const p = this.player;
    if (!p) {
      return false;
    }
    return p.canGoPrevious || p.canGoNext;
  }

  private playButtonEnabled(): boolean {
    const p = this.player;
    if (!p) {
      return false;
    }
    // Android: playing → isPauseAllowed; paused → isPlayAllowed
    return p.isPlaying ? p.canPause : p.canPlay;
  }

  /** Android nowPlayingTextview: "title - artist" or title */
  private nowPlayingLine(): string {
    const p = this.player;
    if (!p) {
      return '';
    }
    let song = p.title;
    if (p.artist.length > 0) {
      if (song.length > 0) {
        song = `${song} - ${p.artist}`;
      } else {
        song = p.artist;
      }
    }
    if (song.length === 0) {
      return p.player;
    }
    return song;
  }

  private loopIconTint(): ResourceColor {
    const p = this.player;
    if (!p || p.loopStatus === 'None' || p.loopStatus.length === 0) {
      return UiTheme.textMuted;
    }
    return UiTheme.primary;
  }

  private shuffleIconTint(): ResourceColor {
    const p = this.player;
    if (p && p.shuffle) {
      return UiTheme.primary;
    }
    return UiTheme.textMuted;
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

  /**
   * Android MprisNowPlayingFragment.durationToProgress — supports hours.
   */
  private fmtTime(ms: number): string {
    if (ms < 0 || !Number.isFinite(ms)) {
      return '0:00';
    }
    const length = Math.floor(ms / 1000);
    let minutes = Math.floor(length / 60);
    const seconds = length % 60;
    let out = '';
    if (minutes > 60) {
      const hours = Math.floor(minutes / 60);
      minutes = minutes % 60;
      out += `${hours}:`;
      if (minutes < 10) {
        out += '0';
      }
    }
    out += `${minutes}:`;
    if (seconds < 10) {
      out += '0';
    }
    out += `${seconds}`;
    return out;
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

  /**
   * Android mpris_control: no_players TextView + player_spinner.
   */
  @Builder
  PlayerPicker() {
    if (this.playerNames.length === 0) {
      Text('没有已连接的播放器')
        .fontSize(15)
        .fontColor(UiTheme.onSurfaceVariant)
        .width('100%')
        .textAlign(TextAlign.Center)
        .padding({ left: 16, right: 16, top: 16, bottom: 8 })
    } else {
      Select(this.playerSelectOptions)
        .selected(this.selectedPlayerIndex)
        .value(this.playerNames[this.selectedPlayerIndex] ?? '')
        .font({ size: 15 })
        .selectedOptionFont({ size: 15 })
        .optionFont({ size: 15 })
        .width('100%')
        .padding({ left: 8, right: 8, top: 8, bottom: 4 })
        .onSelect((index: number) => {
          this.selectPlayer(index);
        })
    }
  }

  /** Android album_art ImageView (placeholder surface when empty). */
  @Builder
  AlbumArt() {
    if (this.albumArtSrc().length > 0) {
      Image(this.albumArtSrc())
        .width(240)
        .height(240)
        .objectFit(ImageFit.Contain)
        .margin({ top: 16, bottom: 12, left: 24, right: 24 })
    } else {
      // Android ic_album_art_placeholder equivalent
      Column() {
        SymbolGlyph($r('sys.symbol.waveform'))
          .fontSize(72)
          .fontColor([UiTheme.outline])
      }
      .width(240)
      .height(240)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(UiTheme.surfaceVariant)
      .borderRadius(8)
      .margin({ top: 16, bottom: 12, left: 24, right: 24 })
    }
  }

  /**
   * Android MprisNowPlayingFragment + mpris_control.xml — layout order & visibility:
   * spinner → nowPlaying → [loop | play | shuffle] → [prev|rew|stop|ff|next]
   * → progress (if isSeekAllowed) → volume (if isSetVolumeAllowed)
   */
  @Builder
  PlayerTab() {
    Scroll() {
      Column() {
        this.PlayerPicker()
        this.AlbumArt()

        // now_playing_textview — single line marquee style
        Text(this.nowPlayingLine().length > 0 ? this.nowPlayingLine() : ' ')
          .fontSize(16)
          .fontColor(UiTheme.onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.MARQUEE })
          .textAlign(TextAlign.Center)
          .width('100%')
          .padding({ left: 16, right: 16, top: 4, bottom: 12 })

        // Primary: loop | play | shuffle — 3 equal columns, play always center
        Row() {
          Column() {
            if (this.player !== null && this.player.loopStatusAllowed) {
              Button({ type: ButtonType.Circle, stateEffect: true }) {
                SymbolGlyph($r('sys.symbol.repeat'))
                  .fontSize(22)
                  .fontColor([this.loopIconTint()])
              }
              .width(56)
              .height(56)
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.callToggleLoop();
              })
            }
          }
          .layoutWeight(1)
          .height(80)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)

          Column() {
            Button({ type: ButtonType.Circle, stateEffect: true }) {
              SymbolGlyph(
                this.player !== null && this.player.isPlaying
                  ? $r('sys.symbol.pause')
                  : $r('sys.symbol.play')
              )
                .fontSize(36)
                .fontColor([
                  this.playButtonEnabled() ? UiTheme.onSurface : UiTheme.outline
                ])
            }
            .width(72)
            .height(72)
            .backgroundColor(Color.Transparent)
            .enabled(this.playButtonEnabled())
            .opacity(this.playButtonEnabled() ? 1 : 0.35)
            .onClick(() => {
              this.callPlayPause();
            })
          }
          .layoutWeight(1)
          .height(80)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)

          Column() {
            if (this.player !== null && this.player.shuffleAllowed) {
              Button({ type: ButtonType.Circle, stateEffect: true }) {
                SymbolGlyph($r('sys.symbol.shuffle'))
                  .fontSize(22)
                  .fontColor([this.shuffleIconTint()])
              }
              .width(56)
              .height(56)
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.callToggleShuffle();
              })
            }
          }
          .layoutWeight(1)
          .height(80)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height(80)
        .padding({ left: 8, right: 8 })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)

        // Secondary: prev | rew | stop | ff | next — always 5 equal slots so
        // hidden pairs leave mirrored blanks and the row stays centered.
        Row() {
          // prev (mirror of next)
          if (this.showPrevNext()) {
            Column() {
              Button({ type: ButtonType.Circle, stateEffect: true }) {
                SymbolGlyph($r('sys.symbol.chevron_left'))
                  .fontSize(24)
                  .fontColor([
                    this.player !== null && this.player.canGoPrevious
                      ? UiTheme.onSurface : UiTheme.outline
                  ])
              }
              .width(48)
              .height(48)
              .backgroundColor(Color.Transparent)
              .enabled(this.player !== null && this.player.canGoPrevious)
              .opacity(this.player !== null && this.player.canGoPrevious ? 1 : 0.35)
              .onClick(() => {
                this.callPrevious();
              })
            }
            .layoutWeight(1)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else {
            Column().layoutWeight(1).height(56)
          }

          // rew (mirror of ff)
          if (this.isSeekAllowed()) {
            Column() {
              Button({ type: ButtonType.Circle, stateEffect: true }) {
                Text('«')
                  .fontSize(22)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(UiTheme.onSurface)
              }
              .width(48)
              .height(48)
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.callSeek(-this.seekStepUs);
              })
            }
            .layoutWeight(1)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else {
            Column().layoutWeight(1).height(56)
          }

          // stop — always center slot
          Column() {
            Button({ type: ButtonType.Circle, stateEffect: true }) {
              Text('■')
                .fontSize(16)
                .fontColor(this.player !== null ? UiTheme.onSurface : UiTheme.outline)
            }
            .width(48)
            .height(48)
            .backgroundColor(Color.Transparent)
            .enabled(this.player !== null)
            .opacity(this.player !== null ? 1 : 0.35)
            .onClick(() => {
              this.callStop();
            })
          }
          .layoutWeight(1)
          .height(56)
          .justifyContent(FlexAlign.Center)
          .alignItems(HorizontalAlign.Center)

          // ff
          if (this.isSeekAllowed()) {
            Column() {
              Button({ type: ButtonType.Circle, stateEffect: true }) {
                Text('»')
                  .fontSize(22)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(UiTheme.onSurface)
              }
              .width(48)
              .height(48)
              .backgroundColor(Color.Transparent)
              .onClick(() => {
                this.callSeek(this.seekStepUs);
              })
            }
            .layoutWeight(1)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else {
            Column().layoutWeight(1).height(56)
          }

          // next
          if (this.showPrevNext()) {
            Column() {
              Button({ type: ButtonType.Circle, stateEffect: true }) {
                SymbolGlyph($r('sys.symbol.chevron_right'))
                  .fontSize(24)
                  .fontColor([
                    this.player !== null && this.player.canGoNext
                      ? UiTheme.onSurface : UiTheme.outline
                  ])
              }
              .width(48)
              .height(48)
              .backgroundColor(Color.Transparent)
              .enabled(this.player !== null && this.player.canGoNext)
              .opacity(this.player !== null && this.player.canGoNext ? 1 : 0.35)
              .onClick(() => {
                this.callNext();
              })
            }
            .layoutWeight(1)
            .height(56)
            .justifyContent(FlexAlign.Center)
            .alignItems(HorizontalAlign.Center)
          } else {
            Column().layoutWeight(1).height(56)
          }
        }
        .width('100%')
        .height(60)
        .padding({ left: 8, right: 8 })
        .margin({ bottom: 8 })
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)

        // progress_slider — GONE when !isSeekAllowed (podcast often hidden)
        if (this.isSeekAllowed() && this.player !== null) {
          Row() {
            Text(this.fmtTime(this.seekValue))
              .fontSize(14)
              .fontColor(UiTheme.onSurface)
              .width(52)
              .textAlign(TextAlign.Center)

            Slider({
              value: this.seekValue,
              min: 0,
              max: this.player.length >= 0 ? Math.max(this.player.length, 1) : 1,
              step: 500
            })
              .blockColor(UiTheme.primary)
              .trackColor('#22000000')
              .selectedColor(UiTheme.primary)
              .trackThickness(3)
              .blockSize({ width: 14, height: 14 })
              .layoutWeight(1)
              .onChange((value: number, mode: SliderChangeMode) => {
                // Android: update label while dragging; SetPosition on stop
                if (mode === SliderChangeMode.Begin) {
                  this.scrubbing = true;
                }
                this.seekValue = value;
                if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.scrubbing = false;
                  this.callSetPosition(Math.round(value));
                }
              })

            Text(this.fmtTime(this.player.length >= 0 ? this.player.length : 0))
              .fontSize(14)
              .fontColor(UiTheme.onSurface)
              .width(52)
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .padding({ left: 8, right: 8 })
          .margin({ top: 4, bottom: 8 })
        }

        // volume_layout — GONE when !isSetVolumeAllowed
        if (this.isSetVolumeAllowed() && this.player !== null) {
          Row({ space: 10 }) {
            SymbolGlyph($r('sys.symbol.speaker_wave_2'))
              .fontSize(22)
              .fontColor([UiTheme.onSurfaceVariant])
              .width(30)
              .height(30)

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
              .onChange((value: number, mode: SliderChangeMode) => {
                // Android volumeSeek: send on every user progress change
                if (mode === SliderChangeMode.Moving || mode === SliderChangeMode.End ||
                  mode === SliderChangeMode.Click) {
                  this.callSetVolume(Math.round(value));
                }
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16 })
          .margin({ top: 8 })
        }

        if (this.playerNames.length === 0) {
          Text('在对端设备上播放音乐后，此处将显示播放控制')
            .fontSize(13)
            .fontColor(UiTheme.textMuted)
            .textAlign(TextAlign.Center)
            .width('100%')
            .padding({ left: 32, right: 32, top: 24 })
        }

        Column().height(this.navBarHeight + 24)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Center)
      .justifyContent(FlexAlign.Center)
    }
    .layoutWeight(1)
    .scrollBar(BarState.Off)
    .align(Alignment.Top)
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
