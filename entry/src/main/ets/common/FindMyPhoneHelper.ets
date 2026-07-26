import { vibrator } from '@kit.SensorServiceKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppNotifier } from './AppNotifier';

/**
 * Ring/vibrate when desktop sends kdeconnect.findmyphone.request.
 * Stops on explicit stop(), timeout, or user tapping the notification (open app).
 */
export class FindMyPhoneHelper {
  private static instance: FindMyPhoneHelper | null = null;
  private active: boolean = false;
  private loopToken: number = 0;
  private stopTimer: number = -1;

  public static getInstance(): FindMyPhoneHelper {
    if (!FindMyPhoneHelper.instance) {
      FindMyPhoneHelper.instance = new FindMyPhoneHelper();
    }
    return FindMyPhoneHelper.instance;
  }

  public isActive(): boolean {
    return this.active;
  }

  /**
   * Start find-me alert: vibration loop + high-priority notification.
   * @param peerName desktop device name
   * @param durationMs auto-stop after this many ms (default 45s)
   */
  public async start(peerName: string, durationMs: number = 45000): Promise<void> {
    // Restart if already ringing
    this.stopInternal(false);
    this.active = true;
    this.loopToken += 1;
    let token = this.loopToken;

    AppNotifier.getInstance().notifyFindMyPhone(peerName).catch((e: Error) => {
      console.error('[FindPhone] notify failed:', e.message);
    });

    this.pulse(token);
    this.stopTimer = setTimeout(() => {
      if (token === this.loopToken) {
        console.info('[FindPhone] auto-stop after timeout');
        this.stop();
      }
    }, durationMs) as number;
  }

  public stop(): void {
    this.stopInternal(true);
  }

  private stopInternal(cancelNotify: boolean): void {
    this.active = false;
    this.loopToken += 1;
    if (this.stopTimer >= 0) {
      clearTimeout(this.stopTimer);
      this.stopTimer = -1;
    }
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
    if (cancelNotify) {
      AppNotifier.getInstance().cancelFindMyPhone().catch(() => {
      });
    }
  }

  private pulse(token: number): void {
    if (!this.active || token !== this.loopToken) {
      return;
    }
    // ~1.2s vibration, then pause, repeat
    vibrator.startVibration(
      { type: 'time', duration: 1200 },
      { usage: 'alarm' }
    ).then(() => {
      if (!this.active || token !== this.loopToken) {
        return;
      }
      setTimeout(() => {
        this.pulse(token);
      }, 600);
    }).catch((e: BusinessError) => {
      console.error(`[FindPhone] vibrate failed: code=${e.code} ${e.message}`);
      // Keep trying a few more times even if one pulse fails
      if (this.active && token === this.loopToken) {
        setTimeout(() => {
          this.pulse(token);
        }, 1500);
      }
    });
  }
}
