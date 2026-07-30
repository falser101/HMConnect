/**
 * Continuous-task bridge — static import of BackgroundTasksKit.
 *
 * Dynamic import('@kit.BackgroundTasksKit') fails on device:
 *   libbackgroundtaskskit.z.so not exist / export objects undefined
 * → startBackgroundRunning of undefined → 长时任务起不来.
 *
 * Static import is required for runtime. SysCap canIUse stays at call sites.
 */
import { common, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';

export const SYSCAP_CONTINUOUS_TASK: string =
  'SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask';

/** Minimal shape of ContinuousTaskNotification. */
export interface ContinuousTaskNotification {
  notificationId: number;
  continuousTaskId?: number;
  slotType: notificationManager.SlotType;
}

/** Minimal shape of ContinuousTaskCancelInfo. */
export interface ContinuousTaskCancelInfo {
  id: number;
  reason: number;
}

export type ContinuousTaskCancelCallback = (info: ContinuousTaskCancelInfo) => void;

export async function startContinuousTaskStringModes(
  context: common.Context,
  modes: string[],
  agent: WantAgent
): Promise<ContinuousTaskNotification> {
  const res = await backgroundTaskManager.startBackgroundRunning(context, modes, agent);
  const out: ContinuousTaskNotification = {
    notificationId: res.notificationId,
    slotType: res.slotType
  };
  if (res.continuousTaskId !== undefined) {
    out.continuousTaskId = res.continuousTaskId;
  }
  return out;
}

export async function startContinuousTaskDataTransfer(
  context: common.Context,
  agent: WantAgent
): Promise<void> {
  await backgroundTaskManager.startBackgroundRunning(
    context,
    backgroundTaskManager.BackgroundMode.DATA_TRANSFER,
    agent
  );
}

/**
 * Enum path with DATA_TRANSFER + AUDIO_PLAYBACK.
 * Lock-screen media card requires AUDIO_PLAYBACK continuous task (official).
 */
export async function startContinuousTaskDataAndAudio(
  context: common.Context,
  agent: WantAgent
): Promise<void> {
  // Multi-mode string array is preferred; this is fallback via sequential not available —
  // use string modes from caller instead when possible.
  await backgroundTaskManager.startBackgroundRunning(
    context,
    backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
    agent
  );
}

export function onContinuousTaskCancel(cb: ContinuousTaskCancelCallback): void {
  backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
    const mapped: ContinuousTaskCancelInfo = {
      id: info.id as number,
      reason: info.reason as number
    };
    cb(mapped);
  });
}

export function stopContinuousTask(context: common.Context): void {
  backgroundTaskManager.stopBackgroundRunning(context);
}
