import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { fileUri } from '@kit.CoreFileKit';
import { AppSession } from '../app/AppSession';
import { FindMyPhoneHelper } from '../common/FindMyPhoneHelper';
import { AppNotifier } from '../common/AppNotifier';
import { KdeBackgroundService } from '../service/KdeBackgroundService';
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
      // Start background service (continuous task + persistent notification)
      KdeBackgroundService.getInstance().start(this.context);
    }).catch((e: Error) => {
      hilog.error(DOMAIN, 'testTag', 'AppSession start failed: %{public}s', e.message);
    });
  }

  onNewWant(want: Want, _launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    this.handleWant(want);
  }

  /** Notification actions: open file, share file, find phone, stop ring. */
  private handleWant(want: Want): void {
    // File-open from notification tap
    const openFile: string | undefined =
      want.parameters !== undefined ? want.parameters['openFile'] as string : undefined;
    if (openFile) {
      hilog.info(DOMAIN, 'testTag', 'Open file from notification: %{public}s', openFile);
      try {
        const uri: string = openFile.startsWith('file://') ? openFile : fileUri.getUriFromPath(openFile);
        const ext: string = openFile.substring(openFile.lastIndexOf('.') + 1).toLowerCase();
        const mimeMap: Record<string, string> = {
          'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
          'gif': 'image/gif', 'bmp': 'image/bmp', 'webp': 'image/webp',
          'mp4': 'video/mp4', 'mkv': 'video/x-matroska',
          'mp3': 'audio/mpeg', 'pdf': 'application/pdf',
          'txt': 'text/plain'
        };
        const mime: string = mimeMap[ext] ?? 'application/octet-stream';
        this.context.startAbility({
          action: 'ohos.want.action.viewData',
          uri: uri,
          type: mime
        }).catch((e: Error) => {
          hilog.error(DOMAIN, 'testTag', 'startAbility for file failed: %{public}s', e.message);
        });
      } catch (e) {
        hilog.error(DOMAIN, 'testTag', 'Open file failed: %{public}s', JSON.stringify(e));
      }
      return;
    }

    // Share-file from notification action button
    const shareFile: string | undefined =
      want.parameters !== undefined ? want.parameters['shareFile'] as string : undefined;
    if (shareFile) {
      hilog.info(DOMAIN, 'testTag', 'Share file from notification: %{public}s', shareFile);
      try {
        const uri: string = shareFile.startsWith('file://') ? shareFile : fileUri.getUriFromPath(shareFile);
        const mime: string = (want.parameters !== undefined ? want.parameters['shareMime'] as string : undefined) ??
          'application/octet-stream';
        this.context.startAbility({
          action: 'ohos.want.action.sendData',
          uri: uri,
          type: mime
        }).catch((e: Error) => {
          hilog.error(DOMAIN, 'testTag', 'shareAbility for file failed: %{public}s', e.message);
        });
      } catch (e) {
        hilog.error(DOMAIN, 'testTag', 'Share file failed: %{public}s', JSON.stringify(e));
      }
      return;
    }

    // Send-clipboard from persistent notification action button
    const sendClipboard: string | undefined =
      want.parameters !== undefined ? want.parameters['sendClipboard'] as string : undefined;
    if (sendClipboard) {
      hilog.info(DOMAIN, 'testTag', 'Send clipboard to device: %{public}s', sendClipboard);
      AppSession.getInstance().openClipboardSendFor(sendClipboard);
      return;
    }

    // Send-file from persistent notification action button
    const sendFile: string | undefined =
      want.parameters !== undefined ? want.parameters['sendFile'] as string : undefined;
    if (sendFile) {
      hilog.info(DOMAIN, 'testTag', 'Send file to device: %{public}s', sendFile);
      AppSession.getInstance().openFileSendFor(sendFile);
      return;
    }

    // Pairing accept from notification (value is deviceId when present)
    const pairAccept: string | undefined =
      want.parameters !== undefined ? want.parameters['pairAccept'] as string : undefined;
    if (pairAccept) {
      hilog.info(DOMAIN, 'testTag', 'Accept pair from notification: %{public}s', pairAccept);
      AppNotifier.getInstance().cancelPairRequest();
      AppSession.getInstance().acceptPairing(pairAccept);
      return;
    }

    // Pairing reject from notification (value is deviceId when present)
    const pairReject: string | undefined =
      want.parameters !== undefined ? want.parameters['pairReject'] as string : undefined;
    if (pairReject) {
      hilog.info(DOMAIN, 'testTag', 'Reject pair from notification: %{public}s', pairReject);
      AppNotifier.getInstance().cancelPairRequest();
      AppSession.getInstance().rejectPairing(pairReject);
      return;
    }

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
    KdeBackgroundService.getInstance().stop();
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
    // Re-assert continuous task after resume (may have been cancelled while backgrounded)
    KdeBackgroundService.getInstance().ensureRunning().catch((e: Error) => {
      hilog.warn(DOMAIN, 'testTag', 'BgSvc ensureRunning onForeground: %{public}s', e.message);
    });
  }

  onBackground(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
    // Keep multi-device TLS/UDP alive under lock screen / home by holding
    // multiDeviceConnection continuous task (process freeze is the usual cause of drop).
    KdeBackgroundService.getInstance().ensureRunning().catch((e: Error) => {
      hilog.error(DOMAIN, 'testTag', 'BgSvc ensureRunning onBackground failed: %{public}s', e.message);
    });
  }
}
