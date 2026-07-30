/**
 * Legacy find-phone helper — prefer KdeBackgroundService for keep-alive.
 * Static import only: dynamic import('@kit.BackgroundTasksKit') fails on device.
 */
import { common, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

/** SysCap guard — same string used in canIUse checks. */
const SYSCAP = 'SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask';

/**
 * Start a continuous background task (audio playback).
 * Note: only one continuous task per Ability — prefer KdeBackgroundService dataTransfer.
 */
export async function startContinuousTask(
  ctx: common.UIAbilityContext,
  agent: WantAgent,
  agent2: WantAgent
): Promise<boolean> {
  if (!canIUse(SYSCAP)) {
    return false;
  }
  try {
    await backgroundTaskManager.startBackgroundRunning(ctx, ['audioPlayback'], agent);
    return true;
  } catch (_err) {
    try {
      await backgroundTaskManager.startBackgroundRunning(
        ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        agent2
      );
      return true;
    } catch (_err2) {
      return false;
    }
  }
}

/**
 * Stop a previously started continuous background task.
 * WARNING: stops the Ability's only continuous task (including dataTransfer).
 */
export async function stopContinuousTask(ctx: common.UIAbilityContext): Promise<void> {
  if (!canIUse(SYSCAP)) {
    return;
  }
  try {
    backgroundTaskManager.stopBackgroundRunning(ctx);
  } catch (_err) {
    // Best-effort: task may already be stopped
  }
}
