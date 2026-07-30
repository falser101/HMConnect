/**
 * Official-style remote media session for 播控中心 + 锁屏.
 *
 * Aligns with Huawei sample RemoteMediaSessionManager:
 * 1) module: KEEP_BACKGROUND_RUNNING + backgroundModes audioPlayback (+ our dataTransfer)
 * 2) createAVSession('audio') → on(commands) → activate()
 * 3) updateRemoteMedia(metadata, playbackState) when peer pushes MPRIS
 * 4) startBackgroundTask(AUDIO_PLAYBACK) so lock-screen card is not suspended
 * 5) Commands → peer via KDE Connect (RemoteMprisCommandTarget)
 *
 * Also keeps dataTransfer via KdeBackgroundService for LAN (not in sample).
 */
import { common } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { fileIo } from '@kit.CoreFileKit';
import { MprisPlayerState } from './KdeTypes';
import { KdeBackgroundService } from './KdeBackgroundService';

export interface RemoteMprisCommandTarget {
  mprisPlay(): void;
  mprisPause(): void;
  mprisStop(): void;
  mprisMediaPrevious(): void;
  mprisMediaNext(): void;
  /** Lock-screen uses notification player (not UI spinner selection). */
  mprisMediaSetPosition(positionMs: number): void;
  mprisMediaSeek(offsetUs: number): void;
  mprisToggleLoop(): void;
  isTlsLive(): boolean;
  getBoundDeviceId(): string;
}

/** 安卓/桌面推送的元数据 — 官方 RemoteMediaMetadata */
interface RemoteMediaMetadata {
  title: string;
  artist: string;
  album: string;
  albumArtUrl: string;
  duration: number;
}

/** 官方 RemotePlaybackState */
interface RemotePlaybackState {
  isPlaying: boolean;
  position: number;
}

type SessionJob = () => Promise<void>;

export class RemoteMprisMediaSession {
  private static instance: RemoteMprisMediaSession | null = null;

  private context: common.UIAbilityContext | null = null;
  private session: avSession.AVSession | null = null;
  private target: RemoteMprisCommandTarget | null = null;
  private peerName: string = '';
  private activated: boolean = false;
  private creating: boolean = false;
  private commandsWired: boolean = false;
  private bgTaskStarted: boolean = false;
  private lastMetaSig: string = '';
  private lastPlaySig: string = '';
  private pendingPlayer: MprisPlayerState | null = null;
  private debounceTimer: number = -1;
  private opQueue: SessionJob[] = [];
  private opBusy: boolean = false;

  private constructor() {
  }

  public static getInstance(): RemoteMprisMediaSession {
    if (!RemoteMprisMediaSession.instance) {
      RemoteMprisMediaSession.instance = new RemoteMprisMediaSession();
    }
    return RemoteMprisMediaSession.instance;
  }

  public setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
  }

  /**
   * 官方 initSession：create → 注册命令 → activate
   * 元数据在后续 updateRemoteMedia 里设置。
   */
  public async initSession(): Promise<void> {
    if (this.session && this.activated) {
      // 仍确保长时任务（锁屏条件 2）
      await this.startBackgroundTask();
      return;
    }
    if (this.creating) {
      await this.yieldMs(400);
      if (this.session && this.activated) {
        return;
      }
    }
    if (!this.context) {
      throw new Error('no UIAbilityContext');
    }
    this.creating = true;
    try {
      // 创建 audio 类型媒体会话
      this.session = await avSession.createAVSession(
        this.context,
        'REMOTE_MEDIA_SESSION',
        'audio'
      );
      console.info(`[RemoteMpris] createAVSession id=${this.session.sessionId}`);

      // 注册控制命令（activate 之前）
      this.registerRemoteCommands();

      // 激活会话（官方：命令注册完成后 activate）
      await this.session.activate();
      this.activated = true;
      console.info(
        `[RemoteMpris] AVSession 激活成功 sessionId=${this.session.sessionId}`
      );

      // 官方第二步：AUDIO_PLAYBACK 长时任务（锁屏卡片持续显示）
      await this.startBackgroundTask();
    } catch (err) {
      const e = err as BusinessError;
      console.error(
        `[RemoteMpris] 创建 AVSession 失败: code=${e.code}, message=${e.message}`
      );
      this.session = null;
      this.activated = false;
      this.commandsWired = false;
    } finally {
      this.creating = false;
    }
  }

  /**
   * 官方 updateRemoteMedia：对端推送后更新播控/锁屏展示。
   */
  public async updateRemoteMedia(
    metadata: RemoteMediaMetadata,
    playbackState: RemotePlaybackState
  ): Promise<void> {
    if (!this.session) {
      console.warn('[RemoteMpris] AVSession 尚未初始化，跳过更新');
      return;
    }
    try {
      const avMetadata: avSession.AVMetadata = {
        assetId: 'remote_media_001',
        title: metadata.title,
        artist: metadata.artist,
        album: metadata.album,
        duration: metadata.duration
      };
      if (metadata.albumArtUrl.length > 0) {
        if (metadata.albumArtUrl.startsWith('http://') ||
          metadata.albumArtUrl.startsWith('https://')) {
          avMetadata.mediaImage = metadata.albumArtUrl;
        } else {
          const pm = await this.loadPixelMap(metadata.albumArtUrl);
          if (pm) {
            avMetadata.mediaImage = pm;
          }
        }
      }
      await this.session.setAVMetadata(avMetadata);

      const avPlaybackState: avSession.AVPlaybackState = {
        state: playbackState.isPlaying
          ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
          : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
        position: {
          elapsedTime: playbackState.position,
          updateTime: new Date().getTime()
        },
        speed: 1.0,
        bufferedTime: playbackState.position,
        loopMode: avSession.LoopMode.LOOP_MODE_SEQUENCE,
        isFavorite: false
      };
      await this.session.setAVPlaybackState(avPlaybackState);
      console.info(
        `[RemoteMpris] updateRemoteMedia title="${metadata.title}" playing=${playbackState.isPlaying} pos=${playbackState.position}`
      );
    } catch (err) {
      const e = err as BusinessError;
      console.error(
        `[RemoteMpris] 更新播放状态失败: code=${e.code}, message=${e.message}`
      );
    }
  }

  /**
   * 官方 startBackgroundTask：AUDIO_PLAYBACK 保证锁屏不被挂起。
   * 我们同时保留 dataTransfer（KDE 局域网），由 KdeBackgroundService 统一申请。
   */
  public async startBackgroundTask(): Promise<void> {
    if (this.bgTaskStarted) {
      // 仍确保 BgSvc 持有 audioPlayback
      KdeBackgroundService.getInstance().setMediaPlaybackLongTask(true);
      return;
    }
    this.bgTaskStarted = true;
    console.info('[RemoteMpris] 启动 AUDIO_PLAYBACK 长时任务（锁屏播控）');
    KdeBackgroundService.getInstance().setMediaPlaybackLongTask(true);
  }

  /** DeviceSession 入口：MPRIS 状态 → 官方 updateRemoteMedia */
  public updateFromRemote(
    target: RemoteMprisCommandTarget,
    peerName: string,
    player: MprisPlayerState | null
  ): void {
    this.target = target;
    this.peerName = peerName.length > 0 ? peerName : 'Remote';

    if (!player || player.player.length === 0) {
      this.showIdle();
      return;
    }
    if (player.title.length === 0 && !player.isPlaying && player.pos <= 0) {
      this.showIdle();
      return;
    }

    this.pendingPlayer = player;
    if (this.debounceTimer >= 0) {
      return;
    }
    // 合并高频 MPRIS，避免 AVSession syncExecutor timeout
    this.debounceTimer = setTimeout(() => {
      this.debounceTimer = -1;
      const p = this.pendingPlayer;
      this.pendingPlayer = null;
      if (!p) {
        return;
      }
      this.enqueue(async () => {
        if (!this.session || !this.activated) {
          await this.initSession();
        }
        await this.startBackgroundTask();

        const title = p.title.length > 0 ? p.title : p.player;
        const artist = p.artist.length > 0
          ? `${p.artist} · ${this.peerName}`
          : this.peerName;
        const album = p.album.length > 0 ? p.album : p.player;
        const duration = p.length > 0 ? p.length : (p.isPlaying ? 180000 : 0);
        const position = this.estimatePosition(p);
        const art = this.resolveArtSource(p);

        const metaSig = `${p.player}|${title}|${artist}|${album}|${duration}|${art}`;
        const playSig = `${p.isPlaying}|${Math.floor(position / 2000)}`;
        // 无变化则跳过（仍保证长时任务）
        if (metaSig === this.lastMetaSig && playSig === this.lastPlaySig) {
          return;
        }
        this.lastMetaSig = metaSig;
        this.lastPlaySig = playSig;

        await this.updateRemoteMedia(
          {
            title: title,
            artist: artist,
            album: album,
            albumArtUrl: art,
            duration: duration
          },
          {
            isPlaying: p.isPlaying,
            position: Math.max(0, Math.floor(position))
          }
        );
      });
    }, 100) as number;
  }

  public clearIfTarget(target: RemoteMprisCommandTarget): void {
    if (this.target === target) {
      this.target = null;
      this.showIdle();
    }
  }

  public showIdle(): void {
    this.enqueue(async () => {
      if (!this.session) {
        return;
      }
      try {
        await this.updateRemoteMedia(
          {
            title: 'HMConnect',
            artist: this.peerName.length > 0 ? this.peerName : '未在播放',
            album: '',
            albumArtUrl: '',
            duration: 0
          },
          { isPlaying: false, position: 0 }
        );
      } catch (_e) {
      }
    });
  }

  /** 官方：注册播控命令 → 转发对端（KDE MPRIS） */
  private registerRemoteCommands(): void {
    if (!this.session || this.commandsWired) {
      return;
    }
    this.commandsWired = true;
    const s = this.session;

    s.on('play', () => {
      console.info('[RemoteMpris] 锁屏/播控：播放 → 对端');
      this.target?.mprisPlay();
    });
    s.on('pause', () => {
      console.info('[RemoteMpris] 锁屏/播控：暂停 → 对端');
      this.target?.mprisPause();
    });
    s.on('playNext', () => {
      console.info('[RemoteMpris] 锁屏/播控：下一首 → 对端');
      this.target?.mprisMediaNext();
    });
    s.on('playPrevious', () => {
      console.info('[RemoteMpris] 锁屏/播控：上一首 → 对端');
      this.target?.mprisMediaPrevious();
    });
    s.on('stop', () => {
      console.info('[RemoteMpris] 锁屏/播控：停止 → 对端');
      this.target?.mprisStop();
    });
    s.on('seek', (timeMs: number) => {
      console.info(`[RemoteMpris] 锁屏/播控：seek ${timeMs} → 对端`);
      this.target?.mprisMediaSetPosition(Math.round(timeMs));
    });
  }

  private enqueue(job: SessionJob): void {
    this.opQueue.push(job);
    this.pump();
  }

  private pump(): void {
    if (this.opBusy) {
      return;
    }
    const job = this.opQueue.shift();
    if (!job) {
      return;
    }
    this.opBusy = true;
    job().catch((e: Error) => {
      console.warn('[RemoteMpris] job:', e.message);
    }).then(() => {
      this.opBusy = false;
      this.pump();
    });
  }

  private estimatePosition(player: MprisPlayerState): number {
    if (player.isPlaying && player.length > 0) {
      const elapsed = Date.now() - player.lastPositionTime;
      return Math.min(player.pos + elapsed, player.length);
    }
    return Math.max(0, player.pos);
  }

  private resolveArtSource(player: MprisPlayerState): string {
    if (player.albumArtLocalPath.length > 0) {
      return player.albumArtLocalPath;
    }
    if (player.albumArtUrl.startsWith('http://') || player.albumArtUrl.startsWith('https://')) {
      return player.albumArtUrl;
    }
    return '';
  }

  private async loadPixelMap(path: string): Promise<image.PixelMap | null> {
    let filePath = path;
    if (filePath.startsWith('file://')) {
      filePath = filePath.substring(7);
    }
    try {
      const src = image.createImageSource(filePath);
      try {
        return await src.createPixelMap();
      } finally {
        try {
          src.release();
        } catch (_r) {
        }
      }
    } catch (_e) {
      try {
        const file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
        try {
          const src2 = image.createImageSource(file.fd);
          try {
            return await src2.createPixelMap();
          } finally {
            try {
              src2.release();
            } catch (_r2) {
            }
          }
        } finally {
          try {
            fileIo.closeSync(file);
          } catch (_c) {
          }
        }
      } catch (_e2) {
        return null;
      }
    }
  }

  private yieldMs(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, ms);
    });
  }

  /**
   * 官方 destroy：停会话 + 停后台任务。
   * 注意：不直接 stopBackgroundRunning，避免误杀 dataTransfer；
   * 只取消 audioPlayback 模式，由 BgSvc 保留 LAN 长时任务。
   */
  public async destroyRemoteSession(): Promise<void> {
    this.opQueue = [];
    this.target = null;
    this.bgTaskStarted = false;
    this.activated = false;
    this.commandsWired = false;
    this.lastMetaSig = '';
    this.lastPlaySig = '';
    KdeBackgroundService.getInstance().setMediaPlaybackLongTask(false);

    const s = this.session;
    this.session = null;
    if (s) {
      try {
        await s.deactivate();
      } catch (_d) {
      }
      try {
        await s.destroy();
      } catch (_d2) {
      }
    }
    console.info('[RemoteMpris] AVSession 已销毁，audioPlayback 已请求释放');
  }

  public destroy(): void {
    this.destroyRemoteSession().catch(() => {
    });
  }
}
