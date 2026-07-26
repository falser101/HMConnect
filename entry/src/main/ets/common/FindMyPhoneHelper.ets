import { common, Want, wantAgent, WantAgent } from '@kit.AbilityKit';
import { vibrator } from '@kit.SensorServiceKit';
import { media } from '@kit.MediaKit';
import { audio } from '@kit.AudioKit';
import { avSession } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppNotifier } from './AppNotifier';
import { startContinuousTask as bgStart, stopContinuousTask as bgStop } from './BackgroundTaskWrap';

export type FindPhoneStateListener = (active: boolean, peerName: string) => void;

/**
 * Continuous ring + vibrate for desktop "Find My Phone".
 *
 * Background path relies on:
 * - continuous task (audioPlayback) when SysCap available
 * - AVSession (system keeps audio task alive)
 * - AVPlayer loop
 *
 * Stops only on explicit stop() / safety timeout / disconnect.
 */
export class FindMyPhoneHelper {
  private static instance: FindMyPhoneHelper | null = null;
  private context: common.UIAbilityContext | null = null;
  private active: boolean = false;
  private peerName: string = '';
  private loopToken: number = 0;
  private stopTimer: number = -1;
  private vibTimer: number = -1;
  private player: media.AVPlayer | null = null;
  private session: avSession.AVSession | null = null;
  private bgTaskStarted: boolean = false;
  private listeners: Map<number, FindPhoneStateListener> = new Map();
  private nextListenerId: number = 1;
  private static readonly DEFAULT_DURATION_MS: number = 120000;

  public static getInstance(): FindMyPhoneHelper {
    if (!FindMyPhoneHelper.instance) {
      FindMyPhoneHelper.instance = new FindMyPhoneHelper();
    }
    return FindMyPhoneHelper.instance;
  }

  public setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
  }

  public isActive(): boolean {
    return this.active;
  }

  public getPeerName(): string {
    return this.peerName;
  }

  public subscribe(cb: FindPhoneStateListener): number {
    let id = this.nextListenerId++;
    this.listeners.set(id, cb);
    cb(this.active, this.peerName);
    return id;
  }

  public unsubscribe(id: number): void {
    this.listeners.delete(id);
  }

  private notifyListeners(): void {
    this.listeners.forEach((cb) => {
      try {
        cb(this.active, this.peerName);
      } catch (e) {
        console.error('[FindPhone] listener error:', JSON.stringify(e));
      }
    });
  }

  /**
   * Start continuous alarm even when app is backgrounded.
   */
  public async start(peerName: string, durationMs: number = FindMyPhoneHelper.DEFAULT_DURATION_MS): Promise<void> {
    this.stopInternal(false);
    this.active = true;
    this.peerName = peerName.length > 0 ? peerName : '电脑';
    this.loopToken += 1;
    let token = this.loopToken;

    this.notifyListeners();

    // 1) Keep process alive for audio (must start BEFORE / with playback)
    await this.startContinuousTask();
    await this.startAvSession();

    // 2) Notification (always, including background)
    AppNotifier.getInstance().notifyFindMyPhone(this.peerName).catch((e: Error) => {
      console.error('[FindPhone] notify failed:', e.message);
    });

    // 3) Sound + vibration (continuous task should keep timers/audio alive in bg)
    this.startVibrationLoop(token);
    await this.startAudioLoop(token);

    // 4) Best-effort: bring UI to front for full-screen stop page
    this.tryBringToForeground();

    this.stopTimer = setTimeout(() => {
      if (token === this.loopToken && this.active) {
        console.info('[FindPhone] safety timeout — auto stop');
        this.stop();
      }
    }, durationMs) as number;
  }

  public stop(): void {
    this.stopInternal(true);
  }

  private stopInternal(cancelNotify: boolean): void {
    let wasActive = this.active;
    this.active = false;
    this.loopToken += 1;
    if (this.stopTimer >= 0) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
    if (this.vibTimer >= 0) {
      clearTimeout(this.vibTimer);
      this.vibTimer = -1;
    }
    this.stopVibration();
    this.stopAudio();
    this.stopAvSession();
    this.stopContinuousTask();
    if (cancelNotify) {
      AppNotifier.getInstance().cancelFindMyPhone().catch(() => {
      });
    }
    if (wasActive || cancelNotify) {
      this.notifyListeners();
    }
    if (cancelNotify) {
      this.peerName = '';
    }
  }

  private async startContinuousTask(): Promise<void> {
    if (!this.context || this.bgTaskStarted) {
      return;
    }
    let agent = await this.buildFindWantAgent(9101, 'findmyphone');
    if (!agent) {
      console.warn('[FindPhone] continuous task: no WantAgent');
      return;
    }
    let agent2 = await this.buildFindWantAgent(9102, 'findmyphone');
    let ok = await bgStart(this.context, agent, agent2 ?? agent);
    this.bgTaskStarted = ok;
    if (ok) {
      console.info('[FindPhone] continuous task started');
    }
  }

  private stopContinuousTask(): void {
    if (!this.context || !this.bgTaskStarted) {
      this.bgTaskStarted = false;
      return;
    }
    this.bgTaskStarted = false;
    bgStop(this.context);
  }

  private async startAvSession(): Promise<void> {
    if (!this.context) {
      return;
    }
    try {
      this.session = await avSession.createAVSession(this.context, 'HMConnectFindPhone', 'audio');
      await this.session.activate();
      let meta: avSession.AVMetadata = {
        assetId: 'find_phone',
        title: '正在查找设备',
        artist: this.peerName
      };
      await this.session.setAVMetadata(meta);
      let pb: avSession.AVPlaybackState = {
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY
      };
      await this.session.setAVPlaybackState(pb);
      // Map pause/stop from media controls to our stop
      this.session.on('play', () => {
      });
      this.session.on('pause', () => {
        this.stop();
      });
      this.session.on('stop', () => {
        this.stop();
      });
      console.info('[FindPhone] AVSession active');
    } catch (e) {
      console.warn('[FindPhone] AVSession failed:', JSON.stringify(e));
      this.session = null;
    }
  }

  private stopAvSession(): void {
    let s = this.session;
    this.session = null;
    if (!s) {
      return;
    }
    try {
      s.setAVPlaybackState({ state: avSession.PlaybackState.PLAYBACK_STATE_STOP }).catch(() => {
      });
      s.deactivate().then(() => {
        return s!.destroy();
      }).catch(() => {
        try {
          s!.destroy();
        } catch (_e) {
          // ignore
        }
      });
    } catch (_e) {
      // ignore
    }
  }

  private async buildFindWantAgent(requestCode: number, from: string): Promise<WantAgent | undefined> {
    if (!this.context) {
      return undefined;
    }
    try {
      let info: wantAgent.WantAgentInfo = {
        wants: [
          {
            deviceId: '',
            bundleName: this.context.abilityInfo.bundleName,
            moduleName: this.context.abilityInfo.moduleName,
            abilityName: this.context.abilityInfo.name,
            action: 'ohos.want.action.home',
            parameters: {
              'fromNotification': from
            }
          }
        ],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: requestCode,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      return await wantAgent.getWantAgent(info);
    } catch (e) {
      let err = e as BusinessError;
      console.error(`[FindPhone] WantAgent failed: ${err.code} ${err.message}`);
      return undefined;
    }
  }

  private tryBringToForeground(): void {
    if (!this.context) {
      return;
    }
    try {
      let want: Want = {
        bundleName: this.context.abilityInfo.bundleName,
        abilityName: this.context.abilityInfo.name,
        moduleName: this.context.abilityInfo.moduleName,
        parameters: {
          'fromNotification': 'findmyphone'
        }
      };
      this.context.startAbility(want).then(() => {
        console.info('[FindPhone] startAbility requested (bring to front)');
      }).catch((e: BusinessError) => {
        // Expected to fail sometimes when strictly backgrounded — continuous audio still runs
        console.warn(`[FindPhone] startAbility skipped: ${e.code} ${e.message}`);
      });
    } catch (e) {
      console.warn('[FindPhone] startAbility exception:', JSON.stringify(e));
    }
  }

  private stopVibration(): void {
    try {
      vibrator.stopVibrationSync();
    } catch (_e) {
      try {
        vibrator.stopVibration().catch(() => {
        });
      } catch (__e) {
        // ignore
      }
    }
  }

  private startVibrationLoop(token: number): void {
    const pulse = (): void => {
      if (!this.active || token !== this.loopToken) {
        return;
      }
      vibrator.startVibration(
        { type: 'time', duration: 1800 },
        { usage: 'alarm' }
      ).then(() => {
        if (!this.active || token !== this.loopToken) {
          return;
        }
        this.vibTimer = setTimeout(() => {
          pulse();
        }, 200) as number;
      }).catch((e: BusinessError) => {
        console.error(`[FindPhone] vibrate failed: code=${e.code} ${e.message}`);
        if (this.active && token === this.loopToken) {
          this.vibTimer = setTimeout(() => {
            pulse();
          }, 800) as number;
        }
      });
    };
    pulse();
  }

  private async startAudioLoop(token: number): Promise<void> {
    if (!this.context) {
      console.warn('[FindPhone] no context, skip audio');
      return;
    }
    try {
      let player = await media.createAVPlayer();
      if (!this.active || token !== this.loopToken) {
        try {
          await player.release();
        } catch (_r) {
          // ignore
        }
        return;
      }
      this.player = player;

      player.on('error', (err: BusinessError) => {
        console.error(`[FindPhone] AVPlayer error: code=${err.code} ${err.message}`);
      });

      player.on('stateChange', (state: string, _reason: media.StateChangeReason) => {
        console.info(`[FindPhone] AVPlayer state=${state}`);
        if (!this.active || token !== this.loopToken) {
          return;
        }
        if (state === 'initialized') {
          player.prepare().catch((e: BusinessError) => {
            console.error(`[FindPhone] prepare failed: ${e.code} ${e.message}`);
          });
        } else if (state === 'prepared') {
          try {
            player.loop = true;
            player.setVolume(1.0);
          } catch (_v) {
            // ignore
          }
          player.play().then(() => {
            // Refresh AVSession playing state after real play starts
            if (this.session) {
              this.session.setAVPlaybackState({
                state: avSession.PlaybackState.PLAYBACK_STATE_PLAY
              }).catch(() => {
              });
            }
          }).catch((e: BusinessError) => {
            console.error(`[FindPhone] play failed: ${e.code} ${e.message}`);
          });
        } else if (state === 'completed') {
          if (this.active && token === this.loopToken) {
            player.play().catch(() => {
            });
          }
        }
      });

      // MUSIC usage pairs with continuous-task audioPlayback verification
      try {
        player.audioRendererInfo = {
          usage: audio.StreamUsage.STREAM_USAGE_MUSIC,
          rendererFlags: 0
        };
      } catch (_a) {
        // ignore
      }

      let raw = await this.context.resourceManager.getRawFd('find_alarm.wav');
      if (!this.active || token !== this.loopToken) {
        this.closeRawFd();
        return;
      }
      player.fdSrc = {
        fd: raw.fd,
        offset: raw.offset,
        length: raw.length
      };
    } catch (e) {
      console.error('[FindPhone] startAudioLoop failed:', JSON.stringify(e));
    }
  }

  private stopAudio(): void {
    let p = this.player;
    this.player = null;
    if (!p) {
      return;
    }
    try {
      p.stop().then(() => {
        return p!.release();
      }).catch(() => {
        try {
          p!.release();
        } catch (_e) {
          // ignore
        }
      });
    } catch (_e) {
      try {
        p.release();
      } catch (__e) {
        // ignore
      }
    }
    this.closeRawFd();
  }

  private closeRawFd(): void {
    try {
      if (this.context) {
        this.context.resourceManager.closeRawFd('find_alarm.wav').catch(() => {
        });
      }
    } catch (_e) {
      // ignore
    }
  }
}
