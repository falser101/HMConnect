import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { AppSession } from '../app/AppSession';
import { FindMyPhoneHelper } from '../common/FindMyPhoneHelper';
import { ImmersiveUtil } from '../common/ImmersiveUtil';
import { UiTheme } from '../common/ui/UiTheme';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');

    // Start protocol stack at Ability level (survives page switches)
    AppSession.getInstance().ensureStarted(this.context).then(() => {
      hilog.info(DOMAIN, 'testTag', 'AppSession started');
      this.handleWant(want);
    }).catch((e: Error) => {
      hilog.error(DOMAIN, 'testTag', 'AppSession start failed: %{public}s', e.message);
    });
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    this.handleWant(want);
  }

  /** Notification actions: open find UI or stop ring. */
  private handleWant(want: Want): void {
    let from = '';
    if (want.parameters && want.parameters['fromNotification'] !== undefined) {
      from = String(want.parameters['fromNotification']);
    }
    if (from === 'stopfindmyphone') {
      hilog.info(DOMAIN, 'testTag', 'stop find-my-phone from notification action');
      FindMyPhoneHelper.getInstance().stop();
      return;
    }
    if (from === 'findmyphone') {
      // Open control page if already ringing; do NOT stop
      if (FindMyPhoneHelper.getInstance().isActive()) {
        AppSession.getInstance().openFindPhonePage();
      }
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
    AppSession.getInstance().shutdown();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    // Full-screen before first paint so status/nav bars blend with app surface.
    ImmersiveUtil.prepaint(windowStage, UiTheme.pageBg, UiTheme.onSurface);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      ImmersiveUtil.applyChrome(UiTheme.pageBg, UiTheme.onSurface);
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    // If ringing, show the stop UI — do not auto-stop on open alone
    if (FindMyPhoneHelper.getInstance().isActive()) {
      AppSession.getInstance().openFindPhonePage();
    }
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
