import { batteryInfo } from '@kit.BasicServicesKit';
import { KdeBatteryBody } from '../service/KdeTypes';

const THRESHOLD_NONE: number = 0;
const THRESHOLD_LOW: number = 1;
const LOW_BATTERY_PERCENT: number = 15;

/**
 * Read local battery and map to KDE Connect battery packet body.
 */
export class BatteryHelper {
  public static readLocalBattery(): KdeBatteryBody {
    let charge = 0;
    let isCharging = false;
    try {
      charge = Math.round(batteryInfo.batterySOC);
      if (charge < 0) {
        charge = 0;
      }
      if (charge > 100) {
        charge = 100;
      }
      let state = batteryInfo.chargingStatus;
      // ENABLE = charging, FULL = full (treat as charging for UI), DISABLE/NONE = not charging
      isCharging =
        state === batteryInfo.BatteryChargeState.ENABLE ||
        state === batteryInfo.BatteryChargeState.FULL;
    } catch (e) {
      console.warn('[Battery] read failed:', JSON.stringify(e));
    }
    let thresholdEvent = THRESHOLD_NONE;
    if (!isCharging && charge <= LOW_BATTERY_PERCENT) {
      thresholdEvent = THRESHOLD_LOW;
    }
    return {
      currentCharge: charge,
      isCharging: isCharging,
      thresholdEvent: thresholdEvent,
      batteryQuantity: 1
    };
  }

  public static formatLabel(charge: number, isCharging: boolean): string {
    let suffix = isCharging ? ' · 充电中' : '';
    return `电量 ${charge}%${suffix}`;
  }
}
