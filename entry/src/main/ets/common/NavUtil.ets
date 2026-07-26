import { common } from '@kit.AbilityKit';
import { UIContext, router } from '@kit.ArkUI';

export interface DeviceDetailRouteParams {
  deviceId: string;
}

export interface EmptyRouteParams {
}

/**
 * Navigation helpers via UIContext (avoids deprecated global router / getContext).
 */
export function hostContext(ui: UIContext): common.UIAbilityContext | undefined {
  let ctx = ui.getHostContext();
  if (!ctx) {
    return undefined;
  }
  return ctx as common.UIAbilityContext;
}

export function pushPage(ui: UIContext, url: string, params?: Object): void {
  try {
    let options: router.RouterOptions = {
      url: url,
      params: params
    };
    let p = ui.getRouter().pushUrl(options);
    p.catch((e: Error) => {
      console.error('[Nav] pushUrl failed:', e.message);
    });
  } catch (e) {
    console.error('[Nav] pushUrl exception:', JSON.stringify(e));
  }
}

export function goBack(ui: UIContext): void {
  try {
    ui.getRouter().back();
  } catch (e) {
    console.error('[Nav] back exception:', JSON.stringify(e));
  }
}

export function routeParams(ui: UIContext): Object {
  try {
    let p = ui.getRouter().getParams();
    if (p === undefined || p === null) {
      let empty: EmptyRouteParams = {};
      return empty;
    }
    return p;
  } catch (_e) {
    let empty: EmptyRouteParams = {};
    return empty;
  }
}
