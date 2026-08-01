/**
 * Pointer acceleration profiles — port of Android
 * PointerAccelerationProfileFactory.kt (mousepadplugin).
 * Touch deltas are scaled by a speed-dependent multiplier so fast swipes move
 * the desktop cursor further; only integer parts are sent (fractional parts
 * accumulate for smooth slow movement).
 */

/** Pending accelerated delta to be sent to the desktop. */
export interface AcceleratedMouseDelta {
  x: number;
  y: number;
}

export class PointerAcceleration {
  private accumulatedX: number = 0;
  private accumulatedY: number = 0;
  private exponent: number;
  /** History of recent touch deltas for speed estimation. */
  private historyX: number[] = [];
  private historyY: number[] = [];
  private historyTime: number[] = [];
  private static readonly HISTORY_SIZE: number = 32;
  private static readonly FRESH_THRESHOLD_MS: number = 150;

  private constructor(exponent: number) {
    this.exponent = exponent;
  }

  public static forProfile(name: string): PointerAcceleration {
    if (name === 'weaker') {
      return new PointerAcceleration(0.25);
    }
    if (name === 'weak') {
      return new PointerAcceleration(0.5);
    }
    if (name === 'strong') {
      return new PointerAcceleration(1.5);
    }
    if (name === 'stronger') {
      return new PointerAcceleration(2.0);
    }
    if (name === 'noacceleration') {
      return new PointerAcceleration(0.0);
    }
    // medium (default) — also the default for unknown names
    return new PointerAcceleration(1.0);
  }

  /** Feed a raw touch delta (already scaled by sensitivity/dpi). */
  public touchMoved(deltaX: number, deltaY: number, eventTime: number): void {
    let multiplier: number = 1;
    if (this.exponent > 0) {
      multiplier = this.multiplierFromHistory(eventTime);
    }
    this.accumulatedX += deltaX * multiplier;
    this.accumulatedY += deltaY * multiplier;
    this.addHistory(deltaX, deltaY, eventTime);
  }

  private addHistory(deltaX: number, deltaY: number, eventTime: number): void {
    this.historyX.unshift(deltaX);
    this.historyY.unshift(deltaY);
    this.historyTime.unshift(eventTime);
    if (this.historyX.length > PointerAcceleration.HISTORY_SIZE) {
      this.historyX.pop();
      this.historyY.pop();
      this.historyTime.pop();
    }
  }

  private multiplierFromHistory(eventTime: number): number {
    let distanceMoved: number = 0;
    let deltaT: number = 0;
    for (let i = 0; i < this.historyX.length; i++) {
      if (eventTime - this.historyTime[i] > PointerAcceleration.FRESH_THRESHOLD_MS) {
        break;
      }
      distanceMoved += Math.sqrt(this.historyX[i] * this.historyX[i] +
        this.historyY[i] * this.historyY[i]);
      deltaT = eventTime - this.historyTime[i];
    }
    let multiplier: number = 0;
    if (deltaT !== 0) {
      const speed: number = distanceMoved / (deltaT / 1000.0);
      multiplier = Math.pow(speed / 600.0, this.exponent);
    }
    if (multiplier < 0.01) {
      multiplier = 0.01;
    }
    return multiplier;
  }

  /**
   * Commit the accumulated delta. Only integer parts are returned; the leftover
   * fractional parts stay for the next commit (smooth cursor at slow speeds).
   */
  public commitAcceleratedMouseDelta(reused: AcceleratedMouseDelta): AcceleratedMouseDelta {
    reused.x = Math.trunc(this.accumulatedX);
    reused.y = Math.trunc(this.accumulatedY);
    this.accumulatedX -= reused.x;
    this.accumulatedY -= reused.y;
    return reused;
  }
}
