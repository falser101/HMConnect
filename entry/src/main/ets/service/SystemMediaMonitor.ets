/**
 * System media session monitor (Android MprisReceiver equivalent).
 *
 * AVSession controller side: discover sessions, export metadata, forward control.
 * Requires ohos.permission.MANAGE_MEDIA_RESOURCES_FOR_PUBLIC (API 23+).
 */
import { avSession } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { audio } from '@kit.AudioKit';
import { image } from '@kit.ImageKit';

/** Snapshot for kdeconnect.mpris (field names match Android MprisPlugin). */
export interface LocalMediaSnapshot {
  player: string;
  sessionId: string;
  bundleName: string;
  title: string;
  artist: string;
  album: string;
  albumArtUrl: string;
  isPlaying: boolean;
  pos: number;
  length: number;
  canPlay: boolean;
  canPause: boolean;
  canGoNext: boolean;
  canGoPrevious: boolean;
  canSeek: boolean;
  volume: number;
  nowPlaying: string;
}

export interface SystemMediaExporter {
  onLocalPlayerList(names: string[]): void;
  onLocalPlayerMetadata(snap: LocalMediaSnapshot): void;
  isMediaExportActive(): boolean;
}

/** Generic sessionTag values that must not be used as player display names. */
const GENERIC_TAGS: string[] = [
  'AVSessionPlayer',
  'SESSION_NAME',
  'SessionName',
  'session_name',
  'avsession',
  'audio',
  'video',
  'voice_call',
  'REMOTE_MEDIA_SESSION',
  'HMConnect',
  'default',
  'Default',
  'Player',
  'player'
];

function errText(err: Object): string {
  try {
    const e = err as BusinessError;
    if (e !== null && e !== undefined && (e.code !== undefined || e.message !== undefined)) {
      return `code=${e.code} msg=${e.message}`;
    }
  } catch (_e) {
  }
  try {
    return JSON.stringify(err);
  } catch (_e2) {
    return String(err);
  }
}

function stateName(st: number): string {
  switch (st) {
    case 0:
      return 'INITIAL';
    case 1:
      return 'PREPARE';
    case 2:
      return 'PLAY';
    case 3:
      return 'PAUSE';
    case 4:
      return 'FF';
    case 5:
      return 'REWIND';
    case 6:
      return 'STOP';
    case 7:
      return 'COMPLETED';
    case 8:
      return 'RELEASED';
    case 9:
      return 'ERROR';
    case 10:
      return 'IDLE';
    case 11:
      return 'BUFFERING';
    default:
      return `state(${st})`;
  }
}

function shortBundle(bundle: string): string {
  if (bundle.length === 0) {
    return 'Player';
  }
  const parts = bundle.split('.');
  const last = parts.length > 0 ? parts[parts.length - 1] : bundle;
  return last.length > 0 ? last : bundle;
}

function isGenericTag(tag: string): boolean {
  const t = tag.trim();
  if (t.length === 0) {
    return true;
  }
  for (let i = 0; i < GENERIC_TAGS.length; i++) {
    if (t === GENERIC_TAGS[i] || t.toLowerCase() === GENERIC_TAGS[i].toLowerCase()) {
      return true;
    }
  }
  return false;
}

class SessionControllerEntry {
  controller: avSession.AVSessionController;
  sessionId: string;
  bundleName: string;
  playerName: string;
  sessionTag: string;
  isActive: boolean;
  isTop: boolean;
  title: string = '';
  artist: string = '';
  album: string = '';
  albumArtUrl: string = '';
  /** Raw album art bitmap from AVMetadata.mediaImage (PixelMap branch). */
  mediaPixelMap: image.PixelMap | null = null;
  length: number = -1;
  isPlaying: boolean = false;
  pos: number = 0;
  rawState: number = 0;
  canPlay: boolean = true;
  canPause: boolean = true;
  canGoNext: boolean = true;
  canGoPrevious: boolean = true;
  canSeek: boolean = false;
  volume: number = 50;
  valid: boolean = true;
  /** Last non-zero position (some apps report pos=0 on PAUSE). */
  private lastGoodPos: number = 0;
  /** Wall clock of last applyPlayback with advancing position. */
  private lastPosWallMs: number = 0;
  private lastPushedSig: string = '';
  private owner: SystemMediaMonitor;
  private listenersOn: boolean = false;

  constructor(
    controller: avSession.AVSessionController,
    sessionId: string,
    bundleName: string,
    playerName: string,
    sessionTag: string,
    isActive: boolean,
    isTop: boolean,
    owner: SystemMediaMonitor
  ) {
    this.controller = controller;
    this.sessionId = sessionId;
    this.bundleName = bundleName;
    this.playerName = playerName;
    this.sessionTag = sessionTag;
    this.isActive = isActive;
    this.isTop = isTop;
    this.owner = owner;
  }

  async init(): Promise<void> {
    try {
      await this.refreshFromController('init');
      this.wireListeners();
      console.info(
        `[SysMedia] READY player="${this.playerName}" session=${this.sessionId} ` +
          `bundle=${this.bundleName} tag=${this.sessionTag} active=${this.isActive} top=${this.isTop} ` +
          `playing=${this.isPlaying} state=${stateName(this.rawState)} ` +
          `title="${this.title}" artist="${this.artist}" ` +
          `cmds=play:${this.canPlay}/pause:${this.canPause}/next:${this.canGoNext}/prev:${this.canGoPrevious}/seek:${this.canSeek}`
      );
    } catch (err) {
      this.valid = false;
      console.error(`[SysMedia] init FAIL player=${this.playerName} session=${this.sessionId} ${errText(err)}`);
    }
  }

  private wireListeners(): void {
    if (this.listenersOn) {
      return;
    }
    this.listenersOn = true;
    this.controller.on('metadataChange', 'all', (data: avSession.AVMetadata) => {
      this.applyMetadata(data);
      console.info(
        `[SysMedia] EVT metadata player="${this.playerName}" title="${this.title}" artist="${this.artist}" ` +
          `album="${this.album}" len=${this.length}`
      );
      this.owner.notifyMetadata(this, false);
    });
    this.controller.on('playbackStateChange', 'all', (st: avSession.AVPlaybackState) => {
      const prevPlaying = this.isPlaying;
      const prevPos = this.pos;
      const prevState = this.rawState;
      this.applyPlayback(st);
      console.info(
        `[SysMedia] EVT playback player="${this.playerName}" state=${stateName(this.rawState)} ` +
          `playing=${this.isPlaying} pos=${this.pos} vol=${this.volume}` +
          (prevPlaying !== this.isPlaying || prevState !== this.rawState
            ? ` (was ${stateName(prevState)} playing=${prevPlaying} pos=${prevPos})`
            : '')
      );
      // Skip noisy INITIAL flicker that doesn't change isPlaying/title (Huawei Music)
      const transientInitial =
        this.rawState === avSession.PlaybackState.PLAYBACK_STATE_INITIAL &&
        prevPlaying === this.isPlaying;
      this.owner.notifyMetadata(this, transientInitial);
    });
    this.controller.on('sessionDestroy', () => {
      console.info(
        `[SysMedia] EVT sessionDestroy player="${this.playerName}" session=${this.sessionId} bundle=${this.bundleName}`
      );
      this.valid = false;
      this.owner.onControllerSessionDestroy(this.sessionId);
    });
    try {
      this.controller.on('validCommandChange', (cmds: Array<avSession.AVControlCommandType>) => {
        this.applyCommands(cmds);
        console.info(
          `[SysMedia] EVT validCmds player="${this.playerName}" n=${cmds.length} ` +
            `play=${this.canPlay} pause=${this.canPause} next=${this.canGoNext} prev=${this.canGoPrevious} seek=${this.canSeek}`
        );
        this.owner.notifyMetadata(this, false);
      });
    } catch (err) {
      console.warn(`[SysMedia] validCommandChange unsupported: ${errText(err)}`);
    }
  }

  async refreshFromController(reason: string): Promise<void> {
    try {
      try {
        const cmds = await this.controller.getValidCommands();
        this.applyCommands(cmds);
        console.info(
          `[SysMedia] refresh(${reason}) cmds player="${this.playerName}" count=${cmds.length} ` +
            `[${cmds.join(',')}]`
        );
      } catch (err) {
        console.warn(`[SysMedia] refresh(${reason}) getValidCommands fail: ${errText(err)}`);
      }
      try {
        const metadata = await this.controller.getAVMetadata();
        this.applyMetadata(metadata);
      } catch (err) {
        console.warn(`[SysMedia] refresh(${reason}) getAVMetadata fail: ${errText(err)}`);
      }
      try {
        const state = await this.controller.getAVPlaybackState();
        this.applyPlayback(state);
      } catch (err) {
        console.warn(`[SysMedia] refresh(${reason}) getAVPlaybackState fail: ${errText(err)}`);
        throw new Error(`getAVPlaybackState: ${errText(err)}`);
      }
      this.valid = true;
      console.info(
        `[SysMedia] refresh(${reason}) OK player="${this.playerName}" playing=${this.isPlaying} ` +
          `state=${stateName(this.rawState)} pos=${this.pos} title="${this.title}"`
      );
    } catch (err) {
      this.valid = false;
      console.error(
        `[SysMedia] refresh(${reason}) FAIL player="${this.playerName}" session=${this.sessionId} ${errText(err)}`
      );
      throw new Error(`refresh(${reason}): ${errText(err)}`);
    }
  }

  private applyCommands(cmds: Array<avSession.AVControlCommandType>): void {
    let hasPlay = false;
    let hasPause = false;
    let hasNext = false;
    let hasPrev = false;
    let hasSeek = false;
    for (let i = 0; i < cmds.length; i++) {
      const c = cmds[i] as string;
      if (c === 'play') {
        hasPlay = true;
      } else if (c === 'pause') {
        hasPause = true;
      } else if (c === 'playNext') {
        hasNext = true;
      } else if (c === 'playPrevious') {
        hasPrev = true;
      } else if (c === 'seek') {
        hasSeek = true;
      }
    }
    // If app reports no cmds, still allow transport (many players omit list)
    if (cmds.length === 0) {
      this.canPlay = true;
      this.canPause = true;
      this.canGoNext = true;
      this.canGoPrevious = true;
      this.canSeek = this.length >= 0;
      return;
    }
    this.canPlay = hasPlay || this.isPlaying;
    this.canPause = hasPause || this.isPlaying;
    this.canGoNext = hasNext;
    this.canGoPrevious = hasPrev;
    this.canSeek = hasSeek;
  }

  private applyMetadata(metadata: avSession.AVMetadata): void {
    this.title = metadata.title ?? '';
    this.artist = metadata.artist ?? metadata.author ?? '';
    this.album = metadata.album ?? '';
    const dur = metadata.duration;
    if (typeof dur === 'number' && dur >= 0) {
      this.length = dur;
    } else {
      this.length = -1;
    }
    const img = metadata.mediaImage;
    if (typeof img === 'string') {
      if (img.length > 0) {
        this.albumArtUrl = img;
      } else {
        this.albumArtUrl = '';
      }
      this.mediaPixelMap = null;
    } else if (img !== undefined && img !== null) {
      // PixelMap branch — export via payload transfer (Android transferringAlbumArt).
      this.mediaPixelMap = img;
      if (this.albumArtUrl.length === 0) {
        this.albumArtUrl = `kdeconnect://albumArt/${this.sessionId}`;
      }
    }
  }

  private applyPlayback(state: avSession.AVPlaybackState): void {
    const st = state.state ?? avSession.PlaybackState.PLAYBACK_STATE_INITIAL;
    this.rawState = st as number;
    const prevPlaying = this.isPlaying;
    const prevPos = this.pos;
    const now = Date.now();

    let newPos = 0;
    try {
      const real = this.controller.getRealPlaybackPositionSync();
      if (typeof real === 'number' && real >= 0) {
        newPos = Math.floor(real);
      } else {
        newPos = Math.floor(state.position?.elapsedTime ?? 0);
      }
    } catch (_e) {
      newPos = Math.floor(state.position?.elapsedTime ?? 0);
    }

    // Explicit play / pause / stop from provider
    const explicitPlay =
      st === avSession.PlaybackState.PLAYBACK_STATE_PLAY ||
      st === avSession.PlaybackState.PLAYBACK_STATE_FAST_FORWARD ||
      st === avSession.PlaybackState.PLAYBACK_STATE_REWIND ||
      st === avSession.PlaybackState.PLAYBACK_STATE_BUFFERING;
    const explicitPause =
      st === avSession.PlaybackState.PLAYBACK_STATE_PAUSE ||
      st === avSession.PlaybackState.PLAYBACK_STATE_STOP ||
      st === avSession.PlaybackState.PLAYBACK_STATE_COMPLETED ||
      st === avSession.PlaybackState.PLAYBACK_STATE_RELEASED;

    if (explicitPlay) {
      this.isPlaying = true;
    } else if (explicitPause) {
      this.isPlaying = false;
    } else {
      // INITIAL / PREPARE / IDLE: many apps (podcast, Huawei Music) spam INITIAL
      // while still playing — infer from advancing position, else keep previous.
      const advanced = newPos > prevPos + 200; // >200ms advance
      const wallOk = this.lastPosWallMs > 0 && (now - this.lastPosWallMs) < 3000;
      if (advanced && (prevPlaying || wallOk || prevPos > 0)) {
        this.isPlaying = true;
        console.info(
          `[SysMedia] infer playing=true from pos advance ` +
            `player="${this.playerName}" state=${stateName(this.rawState)} ${prevPos}→${newPos}`
        );
      } else if (st === avSession.PlaybackState.PLAYBACK_STATE_INITIAL &&
        prevPlaying && newPos > 0 && Math.abs(newPos - prevPos) < 1500) {
        // Transient INITIAL between PLAY↔PAUSE: keep playing until explicit PAUSE
        this.isPlaying = prevPlaying;
      } else if (!prevPlaying) {
        this.isPlaying = false;
      }
      // else keep prevPlaying
    }

    // Position: ignore bogus 0 when we had a solid mid-track position
    if (newPos > 0) {
      this.pos = newPos;
      this.lastGoodPos = newPos;
      if (this.isPlaying || newPos > prevPos) {
        this.lastPosWallMs = now;
      }
    } else if (this.lastGoodPos > 1000 &&
      (explicitPause || st === avSession.PlaybackState.PLAYBACK_STATE_INITIAL)) {
      this.pos = this.lastGoodPos;
      console.info(
        `[SysMedia] keep lastGoodPos=${this.lastGoodPos} (provider reported 0) player="${this.playerName}"`
      );
    } else {
      this.pos = newPos;
    }

    if (typeof state.volume === 'number' && state.volume >= 0) {
      const maxV = typeof state.maxVolume === 'number' && state.maxVolume > 0 ? state.maxVolume : 100;
      this.volume = Math.max(0, Math.min(100, Math.round((state.volume / maxV) * 100)));
    }
    if (this.isPlaying) {
      this.canPlay = true;
      this.canPause = true;
    }
  }

  /**
   * Peer-facing signature (ignore rawState flicker; bucket pos to 1s so INITIAL spam
   * with +1s ticks still can push occasionally, but not every 50ms).
   */
  peerSig(): string {
    const posBucket = Math.floor(this.pos / 1000);
    return `${this.playerName}|${this.isPlaying ? 1 : 0}|${this.title}|${this.artist}|${posBucket}|${this.length}`;
  }

  getLastPushedSig(): string {
    return this.lastPushedSig;
  }

  setLastPushedSig(sig: string): void {
    this.lastPushedSig = sig;
  }

  toSnapshot(): LocalMediaSnapshot {
    const title = this.title;
    const artist = this.artist;
    let nowPlaying = '';
    if (artist.length > 0 && title.length > 0) {
      nowPlaying = `${artist} - ${title}`;
    } else if (title.length > 0) {
      nowPlaying = title;
    } else if (artist.length > 0) {
      nowPlaying = artist;
    }
    return {
      player: this.playerName,
      sessionId: this.sessionId,
      bundleName: this.bundleName,
      title: title,
      artist: artist,
      album: this.album,
      albumArtUrl: this.albumArtUrl,
      isPlaying: this.isPlaying,
      pos: this.pos,
      length: this.length,
      canPlay: this.canPlay || !this.isPlaying,
      canPause: this.canPause || this.isPlaying,
      canGoNext: this.canGoNext,
      canGoPrevious: this.canGoPrevious,
      canSeek: this.canSeek && this.length >= 0,
      volume: this.volume,
      nowPlaying: nowPlaying
    };
  }

  /** JPEG-encode the cached album art bitmap, or null when unavailable. */
  async encodeAlbumArt(): Promise<Uint8Array | null> {
    if (this.mediaPixelMap === null) {
      return null;
    }
    let packer: image.ImagePacker | null = null;
    try {
      packer = image.createImagePacker();
      const option: image.PackingOption = {
        format: 'image/jpeg',
        quality: 90
      };
      const buf: ArrayBuffer = await packer.packing(this.mediaPixelMap, option);
      if (buf.byteLength <= 0) {
        return null;
      }
      const out: Uint8Array = new Uint8Array(buf.byteLength);
      out.set(new Uint8Array(buf));
      console.info(
        `[SysMedia] encoded album art ${out.length} bytes player="${this.playerName}"`
      );
      return out;
    } catch (e) {
      console.warn(`[SysMedia] album art encode failed: ${errText(e)}`);
      return null;
    } finally {
      if (packer !== null) {
        try {
          await packer.release();
        } catch (_e) {
          // ignore
        }
      }
    }
  }

  private resolveCommand(action: string): avSession.AVControlCommandType | null {
    if (action === 'Play') {
      return 'play';
    }
    if (action === 'Pause') {
      return 'pause';
    }
    if (action === 'Stop') {
      return 'stop';
    }
    if (action === 'Next') {
      return 'playNext';
    }
    if (action === 'Previous') {
      return 'playPrevious';
    }
    if (action === 'PlayPause') {
      return this.isPlaying ? 'pause' : 'play';
    }
    return null;
  }

  async sendAction(action: string): Promise<boolean> {
    // Always refresh live state before PlayPause so we don't stick on "play"
    if (action === 'PlayPause' || action === 'Play' || action === 'Pause') {
      try {
        await this.refreshFromController(`pre-${action}`);
      } catch (err) {
        console.warn(
          `[SysMedia] pre-action refresh failed player="${this.playerName}" — will try recreate path. ${errText(err)}`
        );
        return false;
      }
    }
    const cmd = this.resolveCommand(action);
    if (cmd === null) {
      console.warn(`[SysMedia] unknown action="${action}" player="${this.playerName}"`);
      return false;
    }
    console.info(
      `[SysMedia] CMD send action=${action} → cmd=${cmd} player="${this.playerName}" ` +
        `session=${this.sessionId} bundle=${this.bundleName} playing=${this.isPlaying} valid=${this.valid}`
    );
    try {
      await this.controller.sendControlCommand({ command: cmd });
      console.info(`[SysMedia] CMD OK ${cmd} → "${this.playerName}"`);
      // Optimistic update so next PlayPause flips correctly before callback
      if (cmd === 'play') {
        this.isPlaying = true;
      } else if (cmd === 'pause' || cmd === 'stop') {
        this.isPlaying = false;
      }
      this.owner.notifyMetadata(this, false);
      return true;
    } catch (err) {
      this.valid = false;
      console.error(
        `[SysMedia] CMD FAIL ${cmd} → "${this.playerName}" session=${this.sessionId} ${errText(err)}`
      );
      return false;
    }
  }

  async setPositionMs(positionMs: number): Promise<boolean> {
    const pos = Math.max(0, Math.floor(positionMs));
    console.info(`[SysMedia] SEEK setPos=${pos} player="${this.playerName}" session=${this.sessionId}`);
    try {
      await this.controller.sendControlCommand({ command: 'seek', parameter: pos });
      this.pos = pos;
      if (pos > 0) {
        this.lastGoodPos = pos;
      }
      console.info(`[SysMedia] SEEK OK pos=${pos} → "${this.playerName}"`);
      this.owner.notifyMetadata(this, false);
      return true;
    } catch (err) {
      this.valid = false;
      console.error(`[SysMedia] SEEK FAIL player="${this.playerName}" ${errText(err)}`);
      return false;
    }
  }

  async seekByOffsetMs(offsetMs: number): Promise<boolean> {
    let base = this.pos;
    try {
      const real = this.controller.getRealPlaybackPositionSync();
      if (typeof real === 'number' && real >= 0) {
        base = Math.floor(real);
      }
    } catch (_e) {
    }
    console.info(
      `[SysMedia] SEEK offset=${offsetMs} base=${base} target=${base + offsetMs} player="${this.playerName}"`
    );
    return await this.setPositionMs(base + offsetMs);
  }

  async replaceController(controller: avSession.AVSessionController): Promise<void> {
    console.info(`[SysMedia] replaceController player="${this.playerName}" session=${this.sessionId}`);
    await this.unwireAndDestroy(false);
    this.controller = controller;
    this.listenersOn = false;
    this.valid = true;
    await this.init();
  }

  async destroy(): Promise<void> {
    await this.unwireAndDestroy(true);
  }

  private async unwireAndDestroy(callDestroy: boolean): Promise<void> {
    try {
      if (this.listenersOn) {
        this.controller.off('metadataChange');
        this.controller.off('playbackStateChange');
        this.controller.off('sessionDestroy');
        try {
          this.controller.off('validCommandChange');
        } catch (_e) {
        }
        this.listenersOn = false;
      }
      if (callDestroy) {
        await this.controller.destroy();
      }
    } catch (err) {
      console.warn(`[SysMedia] destroy controller session=${this.sessionId}: ${errText(err)}`);
    }
    this.valid = false;
  }
}

export class SystemMediaMonitor {
  private static instance: SystemMediaMonitor | null = null;

  private entries: Map<string, SessionControllerEntry> = new Map();
  private exporters: SystemMediaExporter[] = [];
  private started: boolean = false;
  private starting: boolean = false;
  private ownBundleName: string = '';
  /** Serialize resync / command recovery. */
  private resyncBusy: boolean = false;
  private resyncQueued: boolean = false;

  private constructor() {
  }

  public static getInstance(): SystemMediaMonitor {
    if (!SystemMediaMonitor.instance) {
      SystemMediaMonitor.instance = new SystemMediaMonitor();
    }
    return SystemMediaMonitor.instance;
  }

  public addExporter(exporter: SystemMediaExporter): void {
    if (this.exporters.indexOf(exporter) >= 0) {
      return;
    }
    this.exporters.push(exporter);
    console.info(`[SysMedia] exporter+ total=${this.exporters.length} players=${this.getPlayerNames().join('|')}`);
    const names = this.getPlayerNames();
    exporter.onLocalPlayerList(names);
    for (let i = 0; i < names.length; i++) {
      const snap = this.getSnapshot(names[i]);
      if (snap) {
        exporter.onLocalPlayerMetadata(snap);
      }
    }
  }

  public removeExporter(exporter: SystemMediaExporter): void {
    const next: SystemMediaExporter[] = [];
    for (let i = 0; i < this.exporters.length; i++) {
      if (this.exporters[i] !== exporter) {
        next.push(this.exporters[i]);
      }
    }
    this.exporters = next;
    console.info(`[SysMedia] exporter- total=${this.exporters.length}`);
  }

  public async start(ownBundleName: string): Promise<void> {
    this.ownBundleName = ownBundleName;
    if (this.started || this.starting) {
      console.info(`[SysMedia] start ignored (started=${this.started} starting=${this.starting})`);
      return;
    }
    this.starting = true;
    console.info(`[SysMedia] start begin ownBundle=${ownBundleName}`);
    try {
      await this.resyncAll('start');

      avSession.onSessionCreate((descriptor: avSession.AVSessionDescriptor) => {
        const bundle = descriptor.elementName?.bundleName ?? '';
        console.info(
          `[SysMedia] EVT sessionCreate id=${descriptor.sessionId} tag=${descriptor.sessionTag} ` +
            `type=${descriptor.type} active=${descriptor.isActive} top=${descriptor.isTopSession} bundle=${bundle}`
        );
        this.createEntry(descriptor).then((created: boolean) => {
          if (created) {
            this.broadcastPlayerList();
            this.dumpEntries('after-create');
          }
        }).catch((err: Object) => {
          console.error(`[SysMedia] sessionCreate handler error: ${errText(err)}`);
        });
      });

      avSession.onSessionDestroy((descriptor: avSession.AVSessionDescriptor) => {
        console.info(
          `[SysMedia] EVT sessionDestroy id=${descriptor.sessionId} tag=${descriptor.sessionTag} ` +
            `bundle=${descriptor.elementName?.bundleName ?? ''}`
        );
        this.removeEntry(descriptor.sessionId).then(() => {
          this.broadcastPlayerList();
          this.dumpEntries('after-destroy');
        }).catch((err: Object) => {
          console.error(`[SysMedia] sessionDestroy handler error: ${errText(err)}`);
        });
      });

      avSession.onTopSessionChange((descriptor: avSession.AVSessionDescriptor) => {
        console.info(
          `[SysMedia] EVT topSession id=${descriptor.sessionId} tag=${descriptor.sessionTag} ` +
            `active=${descriptor.isActive} bundle=${descriptor.elementName?.bundleName ?? ''}`
        );
        this.entries.forEach((entry: SessionControllerEntry, id: string) => {
          const wasTop = entry.isTop;
          entry.isTop = id === descriptor.sessionId;
          if (entry.isTop && !wasTop) {
            console.info(`[SysMedia] top → player="${entry.playerName}" bundle=${entry.bundleName}`);
            entry.refreshFromController('top-change').then(() => {
              this.notifyMetadata(entry);
            }).catch(() => {
              // Stale controller after app switch — full resync
              this.resyncAll('top-stale').catch(() => {
              });
            });
          }
        });
        // Ensure top session has an entry (some apps activate without create event)
        if (!this.entries.has(descriptor.sessionId)) {
          console.info(`[SysMedia] top session missing entry — create id=${descriptor.sessionId}`);
          this.createEntry(descriptor).then((created: boolean) => {
            if (created) {
              this.broadcastPlayerList();
            }
          }).catch(() => {
          });
        }
      });

      this.started = true;
      this.broadcastPlayerList();
      this.entries.forEach((entry: SessionControllerEntry) => {
        this.notifyMetadata(entry);
      });
      this.dumpEntries('started');
      console.info('[SysMedia] start OK');
    } catch (err) {
      console.error(`[SysMedia] start FAIL ${errText(err)}`);
    } finally {
      this.starting = false;
    }
  }

  public async stop(): Promise<void> {
    if (!this.started && !this.starting) {
      return;
    }
    console.info('[SysMedia] stop begin');
    try {
      avSession.offSessionCreate();
      avSession.offSessionDestroy();
      avSession.offTopSessionChange();
    } catch (err) {
      console.warn(`[SysMedia] off listeners: ${errText(err)}`);
    }
    const ids: string[] = [];
    this.entries.forEach((_e: SessionControllerEntry, id: string) => {
      ids.push(id);
    });
    for (let i = 0; i < ids.length; i++) {
      await this.removeEntry(ids[i]);
    }
    this.entries.clear();
    this.started = false;
    console.info('[SysMedia] stop OK');
  }

  public getPlayerNames(): string[] {
    const names: string[] = [];
    this.entries.forEach((entry: SessionControllerEntry) => {
      names.push(entry.playerName);
    });
    names.sort();
    return names;
  }

  public getSnapshot(playerName: string): LocalMediaSnapshot | null {
    const entry = this.resolveEntry(playerName);
    if (entry === null) {
      return null;
    }
    return entry.toSnapshot();
  }

  /**
   * Android MprisReceiver: serve album art as a binary payload when the peer
   * asks (kdeconnect.mpris.request {player, albumArtUrl}). Encodes the local
   * PixelMap to JPEG bytes, or null when there is no bitmap for the player.
   */
  public async encodeAlbumArt(playerName: string): Promise<Uint8Array | null> {
    const entry = this.resolveEntry(playerName);
    if (entry === null) {
      return null;
    }
    return entry.encodeAlbumArt();
  }

  /**
   * Best-effort local media volume control (Android MprisReceiverPlayer.setVolume).
   * HarmonyOS restricts direct system-volume writes for third-party apps, so this
   * may fail — callers must fall back to re-pushing the current metadata.
   */
  public async setLocalVolume(volumePercent: number): Promise<void> {
    const clamped: number = Math.max(0, Math.min(100, volumePercent));
    const audioManager = audio.getAudioManager();
    const maxVolume: number = await audioManager.getMaxVolume(audio.AudioVolumeType.MEDIA);
    const level: number = maxVolume > 0 ? Math.round((clamped * maxVolume) / 100) : 0;
    console.info(`[SysMedia] setLocalVolume ${clamped}% → level ${level}/${maxVolume}`);
    await audioManager.setVolume(audio.AudioVolumeType.MEDIA, level);
  }

  public getPreferredPlayerName(): string {
    let playingTop = '';
    let playingAny = '';
    let topAny = '';
    let any = '';
    this.entries.forEach((entry: SessionControllerEntry) => {
      if (any.length === 0) {
        any = entry.playerName;
      }
      if (entry.isTop && topAny.length === 0) {
        topAny = entry.playerName;
      }
      if (entry.isPlaying) {
        if (playingAny.length === 0) {
          playingAny = entry.playerName;
        }
        if (entry.isTop) {
          playingTop = entry.playerName;
        }
      }
    });
    if (playingTop.length > 0) {
      return playingTop;
    }
    if (playingAny.length > 0) {
      return playingAny;
    }
    if (topAny.length > 0) {
      return topAny;
    }
    return any;
  }

  public async sendAction(playerName: string, action: string): Promise<void> {
    console.info(
      `[SysMedia] sendAction IN player="${playerName}" action=${action} ` +
        `entries=${this.entries.size} preferred="${this.getPreferredPlayerName()}"`
    );
    let entry = this.resolveEntry(playerName);
    if (entry === null) {
      console.warn(`[SysMedia] sendAction player not found "${playerName}" — resync`);
      await this.resyncAll('action-miss');
      entry = this.resolveEntry(playerName);
      if (entry === null) {
        // Fall back to preferred (Android may still show old name after app switch)
        const pref = this.getPreferredPlayerName();
        entry = this.resolveEntry(pref);
        console.warn(
          `[SysMedia] sendAction fallback preferred="${pref}" found=${entry !== null}`
        );
      }
    }
    if (entry === null) {
      console.error(`[SysMedia] sendAction ABORT no entry for "${playerName}"`);
      this.dumpEntries('action-abort');
      return;
    }

    let ok = await entry.sendAction(action);
    if (!ok) {
      console.warn(
        `[SysMedia] sendAction retry after resync player="${entry.playerName}" session=${entry.sessionId}`
      );
      await this.resyncAll('action-fail');
      // Resolve again — sessionId may have changed after app switch
      let retry = this.resolveEntry(playerName);
      if (retry === null) {
        retry = this.resolveEntry(this.getPreferredPlayerName());
      }
      if (retry === null) {
        console.error('[SysMedia] sendAction retry: still no entry');
        this.dumpEntries('retry-abort');
        return;
      }
      ok = await retry.sendAction(action);
      if (!ok) {
        // Last resort: recreate controller for this sessionId if still listed
        console.warn(`[SysMedia] sendAction last-resort recreate session=${retry.sessionId}`);
        await this.recreateController(retry.sessionId);
        const again = this.entries.get(retry.sessionId);
        if (again) {
          ok = await again.sendAction(action);
        }
      }
      console.info(`[SysMedia] sendAction retry result ok=${ok}`);
    }
  }

  public async setPosition(playerName: string, positionMs: number): Promise<void> {
    console.info(`[SysMedia] setPosition player="${playerName}" pos=${positionMs}`);
    let entry = this.resolveEntry(playerName);
    if (entry === null) {
      await this.resyncAll('seek-miss');
      entry = this.resolveEntry(playerName) ?? this.resolveEntry(this.getPreferredPlayerName());
    }
    if (entry === null) {
      console.warn(`[SysMedia] setPosition no entry "${playerName}"`);
      return;
    }
    let ok = await entry.setPositionMs(positionMs);
    if (!ok) {
      await this.resyncAll('seek-fail');
      const retry = this.resolveEntry(playerName) ?? this.resolveEntry(this.getPreferredPlayerName());
      if (retry) {
        await retry.setPositionMs(positionMs);
      }
    }
  }

  public async seek(playerName: string, offsetMs: number): Promise<void> {
    console.info(`[SysMedia] seek player="${playerName}" offset=${offsetMs}`);
    let entry = this.resolveEntry(playerName);
    if (entry === null) {
      await this.resyncAll('seekoff-miss');
      entry = this.resolveEntry(playerName) ?? this.resolveEntry(this.getPreferredPlayerName());
    }
    if (entry === null) {
      return;
    }
    let ok = await entry.seekByOffsetMs(offsetMs);
    if (!ok) {
      await this.resyncAll('seekoff-fail');
      const retry = this.resolveEntry(playerName) ?? this.resolveEntry(this.getPreferredPlayerName());
      if (retry) {
        await retry.seekByOffsetMs(offsetMs);
      }
    }
  }

  /**
   * Push metadata to peers.
   * softSkip: transient INITIAL etc. — only push if peer-facing fields changed.
   */
  notifyMetadata(entry: SessionControllerEntry, softSkip: boolean = false): void {
    const sig = entry.peerSig();
    if (sig === entry.getLastPushedSig()) {
      if (softSkip) {
        console.info(`[SysMedia] skip push (transient, unchanged) player="${entry.playerName}"`);
        return;
      }
      // Hard path: still drop pure duplicates (e.g. double PAUSE callback)
      console.info(`[SysMedia] skip push (duplicate) player="${entry.playerName}"`);
      return;
    }
    entry.setLastPushedSig(sig);
    const snap = entry.toSnapshot();
    let n = 0;
    for (let i = 0; i < this.exporters.length; i++) {
      const exp = this.exporters[i];
      if (exp.isMediaExportActive()) {
        exp.onLocalPlayerMetadata(snap);
        n++;
      }
    }
    console.info(
      `[SysMedia] push meta → ${n} peer(s) player="${snap.player}" playing=${snap.isPlaying} ` +
        `title="${snap.title}" pos=${snap.pos} soft=${softSkip}`
    );
  }

  onControllerSessionDestroy(sessionId: string): void {
    this.removeEntry(sessionId).then(() => {
      this.broadcastPlayerList();
      this.dumpEntries('ctrl-destroy');
    }).catch(() => {
    });
  }

  /**
   * Resolve by exact player name, then aliases (bundle short name / legacy AVSessionPlayer),
   * then preferred playing/top session.
   */
  private resolveEntry(playerName: string): SessionControllerEntry | null {
    if (playerName.length === 0) {
      return null;
    }
    const all: SessionControllerEntry[] = [];
    this.entries.forEach((entry: SessionControllerEntry) => {
      all.push(entry);
    });
    for (let i = 0; i < all.length; i++) {
      if (all[i].playerName === playerName) {
        return all[i];
      }
    }
    // Android may still hold generic name after we renamed to bundle short name
    if (isGenericTag(playerName) || playerName === 'AVSessionPlayer') {
      const pref = this.getPreferredPlayerName();
      console.info(`[SysMedia] resolve generic "${playerName}" → preferred "${pref}"`);
      for (let i = 0; i < all.length; i++) {
        if (all[i].playerName === pref) {
          return all[i];
        }
      }
    }
    for (let i = 0; i < all.length; i++) {
      const e = all[i];
      if (shortBundle(e.bundleName) === playerName || e.bundleName === playerName) {
        console.info(`[SysMedia] resolve by bundle "${playerName}" → "${e.playerName}"`);
        return e;
      }
    }
    return null;
  }

  private broadcastPlayerList(): void {
    const names = this.getPlayerNames();
    let n = 0;
    for (let i = 0; i < this.exporters.length; i++) {
      const exp = this.exporters[i];
      if (exp.isMediaExportActive()) {
        exp.onLocalPlayerList(names);
        n++;
      }
    }
    console.info(`[SysMedia] push playerList → ${n} peer(s): [${names.join(', ')}]`);
  }

  private dumpEntries(reason: string): void {
    const parts: string[] = [];
    this.entries.forEach((e: SessionControllerEntry) => {
      parts.push(
        `"${e.playerName}"{id=${e.sessionId.substring(0, 8)}… bundle=${e.bundleName} ` +
          `play=${e.isPlaying} top=${e.isTop} valid=${e.valid} title="${e.title}"}`
      );
    });
    console.info(`[SysMedia] dump(${reason}) n=${this.entries.size} ${parts.join(' | ')}`);
  }

  private shouldSkip(descriptor: avSession.AVSessionDescriptor): boolean {
    const bundle = descriptor.elementName?.bundleName ?? '';
    if (this.ownBundleName.length > 0 && bundle === this.ownBundleName) {
      return true;
    }
    const tag = descriptor.sessionTag ?? '';
    if (tag === 'REMOTE_MEDIA_SESSION' || tag === 'HMConnect') {
      return true;
    }
    return false;
  }

  /**
   * Prefer human-readable app id over generic "AVSessionPlayer" tags.
   * Stable per sessionId so Android player list stays consistent for a session lifetime.
   */
  private pickPlayerName(descriptor: avSession.AVSessionDescriptor): string {
    const tag = (descriptor.sessionTag ?? '').trim();
    const bundle = descriptor.elementName?.bundleName ?? 'unknown';
    let base = '';
    if (!isGenericTag(tag)) {
      base = tag;
    } else {
      base = shortBundle(bundle);
    }
    if (base.length === 0) {
      base = 'Player';
    }
    // Uniqueness: if another live entry already uses base, append short session id
    let collision = false;
    this.entries.forEach((e: SessionControllerEntry) => {
      if (e.playerName === base && e.sessionId !== descriptor.sessionId) {
        collision = true;
      }
    });
    if (collision) {
      const sid = descriptor.sessionId;
      const suffix = sid.length > 6 ? sid.substring(sid.length - 6) : sid;
      return `${base} · ${suffix}`;
    }
    return base;
  }

  private async createEntry(descriptor: avSession.AVSessionDescriptor): Promise<boolean> {
    const sessionId = descriptor.sessionId;
    if (this.entries.has(sessionId)) {
      console.info(`[SysMedia] createEntry skip existing session=${sessionId}`);
      return false;
    }
    if (this.shouldSkip(descriptor)) {
      console.info(
        `[SysMedia] createEntry SKIP own/remote tag=${descriptor.sessionTag} bundle=${descriptor.elementName?.bundleName}`
      );
      return false;
    }
    try {
      console.info(
        `[SysMedia] createController… id=${sessionId} tag=${descriptor.sessionTag} ` +
          `bundle=${descriptor.elementName?.bundleName ?? ''} type=${descriptor.type}`
      );
      const controller = await avSession.createController(sessionId);
      const bundleName = descriptor.elementName?.bundleName ?? 'unknown';
      const playerName = this.pickPlayerName(descriptor);
      const entry = new SessionControllerEntry(
        controller,
        sessionId,
        bundleName,
        playerName,
        descriptor.sessionTag ?? '',
        descriptor.isActive,
        descriptor.isTopSession,
        this
      );
      this.entries.set(sessionId, entry);
      await entry.init();
      this.notifyMetadata(entry);
      return true;
    } catch (err) {
      console.error(
        `[SysMedia] createController FAIL id=${sessionId} ${errText(err)}`
      );
      return false;
    }
  }

  private async removeEntry(sessionId: string): Promise<void> {
    const entry = this.entries.get(sessionId);
    if (!entry) {
      return;
    }
    console.info(
      `[SysMedia] removeEntry player="${entry.playerName}" session=${sessionId} bundle=${entry.bundleName}`
    );
    this.entries.delete(sessionId);
    await entry.destroy();
  }

  private async recreateController(sessionId: string): Promise<void> {
    console.info(`[SysMedia] recreateController session=${sessionId}`);
    try {
      const descriptors = await avSession.getAllSessionDescriptors();
      let desc: avSession.AVSessionDescriptor | null = null;
      for (let i = 0; i < descriptors.length; i++) {
        if (descriptors[i].sessionId === sessionId) {
          desc = descriptors[i];
          break;
        }
      }
      if (desc === null) {
        console.warn(`[SysMedia] recreate: session gone ${sessionId}`);
        await this.removeEntry(sessionId);
        this.broadcastPlayerList();
        return;
      }
      const existing = this.entries.get(sessionId);
      const controller = await avSession.createController(sessionId);
      if (existing) {
        await existing.replaceController(controller);
        this.notifyMetadata(existing);
      } else {
        await this.createEntry(desc);
      }
    } catch (err) {
      console.error(`[SysMedia] recreateController FAIL ${errText(err)}`);
    }
  }

  /**
   * Diff against getAllSessionDescriptors: add missing, drop gone, refresh surviving.
   * Fixes controllerNotRegister after app switch.
   */
  public async resyncAll(reason: string): Promise<void> {
    if (this.resyncBusy) {
      this.resyncQueued = true;
      console.info(`[SysMedia] resync(${reason}) queued`);
      return;
    }
    this.resyncBusy = true;
    console.info(`[SysMedia] resync(${reason}) begin entries=${this.entries.size}`);
    try {
      const descriptors = await avSession.getAllSessionDescriptors();
      console.info(`[SysMedia] resync(${reason}) system sessions=${descriptors.length}`);
      for (let i = 0; i < descriptors.length; i++) {
        const d = descriptors[i];
        console.info(
          `[SysMedia] resync desc[${i}] id=${d.sessionId} tag=${d.sessionTag} type=${d.type} ` +
            `active=${d.isActive} top=${d.isTopSession} bundle=${d.elementName?.bundleName ?? ''}`
        );
      }

      const liveIds: Set<string> = new Set();
      for (let i = 0; i < descriptors.length; i++) {
        const d = descriptors[i];
        if (this.shouldSkip(d)) {
          continue;
        }
        liveIds.add(d.sessionId);
        if (!this.entries.has(d.sessionId)) {
          await this.createEntry(d);
        } else {
          const entry = this.entries.get(d.sessionId);
          if (entry) {
            entry.isActive = d.isActive;
            entry.isTop = d.isTopSession;
            try {
              await entry.refreshFromController(`resync-${reason}`);
              this.notifyMetadata(entry);
            } catch (_e) {
              console.warn(
                `[SysMedia] resync refresh fail → recreate session=${d.sessionId}`
              );
              await this.recreateController(d.sessionId);
            }
          }
        }
      }

      const toRemove: string[] = [];
      this.entries.forEach((_e: SessionControllerEntry, id: string) => {
        if (!liveIds.has(id)) {
          toRemove.push(id);
        }
      });
      for (let i = 0; i < toRemove.length; i++) {
        console.info(`[SysMedia] resync drop stale session=${toRemove[i]}`);
        await this.removeEntry(toRemove[i]);
      }

      this.broadcastPlayerList();
      this.dumpEntries(`resync-${reason}`);
      console.info(`[SysMedia] resync(${reason}) done entries=${this.entries.size}`);
    } catch (err) {
      console.error(`[SysMedia] resync(${reason}) FAIL ${errText(err)}`);
    } finally {
      this.resyncBusy = false;
      if (this.resyncQueued) {
        this.resyncQueued = false;
        await this.resyncAll('queued');
      }
    }
  }
}
