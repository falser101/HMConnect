import { abilityAccessCtrl, common, PermissionRequestResult, Permissions } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** User-grant (runtime) camera permission — used by findmyphone flashlight. */
export const PERMISSION_CAMERA: Permissions = 'ohos.permission.CAMERA';

/** Whether a runtime (user_grant) permission is currently granted. */
export function isPermissionGranted(ctx: common.UIAbilityContext | undefined, permission: Permissions): boolean {
  if (!ctx) {
    return false;
  }
  try {
    const atManager = abilityAccessCtrl.createAtManager();
    const tokenId: number = ctx.applicationInfo.accessTokenId;
    return atManager.checkAccessTokenSync(tokenId, permission) ===
      abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
  } catch (e) {
    console.warn('[Perm] checkAccessTokenSync failed:', JSON.stringify(e));
    return false;
  }
}

/** Request a runtime (user_grant) permission from the user. Resolves true if granted. */
export function requestPermission(ctx: common.UIAbilityContext, permission: Permissions): Promise<boolean> {
  const atManager = abilityAccessCtrl.createAtManager();
  return atManager.requestPermissionsFromUser(ctx, [permission]).then((result: PermissionRequestResult) => {
    for (let i = 0; i < result.permissions.length; i++) {
      if (result.permissions[i] === permission) {
        return result.authResults[i] === 0;
      }
    }
    return false;
  }).catch((e: BusinessError) => {
    console.error(`[Perm] requestPermissionsFromUser failed: code=${e.code} ${e.message}`);
    return false;
  });
}
