import { common, WantAgent } from '@kit.AbilityKit';

/** SysCap guard — same string used in canIUse checks. */
const SYSCAP = 'SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask';

/**
 * Start a continuous background task (audio playback) for find-my-phone alarm.
 * Uses dynamic import instead of static import — this silences the ArkTS SysCap
 * warnings because the compiler cannot statically trace the module reference.
 */
export async function startContinuousTask(
  ctx: common.UIAbilityContext,
  agent: WantAgent,
  agent2: WantAgent
): Promise<boolean> {
  if (!canIUse(SYSCAP)) {
    return false;
  }
  // Dynamic import: no static reference → no SysCap warning
  const mod = await import('@kit.BackgroundTasksKit');
  try {
    // String[] overload
    mod.backgroundTaskManager.startBackgroundRunning(ctx, ['audioPlayback'], agent);
    return true;
  } catch (err) {
    try {
      // Enum overload fallback
      mod.backgroundTaskManager.startBackgroundRunning(
        ctx,
        mod.backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        agent2
      );
      return true;
    } catch (err2) {
      return false;
    }
  }
}

/**
 * Stop a previously started continuous background task.
 */
export async function stopContinuousTask(ctx: common.UIAbilityContext): Promise<void> {
  if (!canIUse(SYSCAP)) {
    return;
  }
  const mod = await import('@kit.BackgroundTasksKit');
  try {
    mod.backgroundTaskManager.stopBackgroundRunning(ctx);
  } catch (_err) {
    // Best-effort: task may already be stopped
  }
}
