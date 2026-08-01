import { AbilityConstant, ConfigurationConstant, UIAbility, Want, wantConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { fileUri, fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { AppSession } from '../app/AppSession';
import { FindMyPhoneHelper } from '../common/FindMyPhoneHelper';
import { AppNotifier } from '../common/AppNotifier';
import { KdeBackgroundService } from '../service/KdeBackgroundService';
import { RemoteMprisMediaSession } from '../service/RemoteMprisMediaSession';
import { ImmersiveUtil } from '../common/ImmersiveUtil';
import { UiTheme, cssColor } from '../common/ui/UiTheme';
import { SettingsStore } from '../store/SettingsStore';

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
      this.applyPersistedTheme();
      this.handleWant(want);
      // Start background service (continuous task + persistent notification)
      KdeBackgroundService.getInstance().start(this.context);
    }).catch((e: Error) => {
      hilog.error(DOMAIN, 'testTag', 'AppSession start failed: %{public}s', e.message);
    });
  }

  /** Apply the persisted theme (light/dark/system) to the whole app at startup. */
  private applyPersistedTheme(): void {
    const theme: string = SettingsStore.getInstance().getTheme();
    let mode: number = ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
    if (theme === 'light') {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    } else if (theme === 'dark') {
      mode = ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    try {
      this.context.getApplicationContext().setColorMode(mode);
      hilog.info(DOMAIN, 'testTag', 'Persisted theme applied: %{public}s', theme);
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'setColorMode failed: %{public}s', JSON.stringify(e));
    }
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
      this.openReceivedFile(openFile).catch((e: Error) => {
        hilog.error(DOMAIN, 'testTag', 'openReceivedFile failed: %{public}s', e.message);
        this.openWithViewData(openFile);
      });
      return;
    }

    // Share-file from notification action button
    const shareFile: string | undefined =
      want.parameters !== undefined ? want.parameters['shareFile'] as string : undefined;
    if (shareFile) {
      hilog.info(DOMAIN, 'testTag', 'Share file from notification: %{public}s', shareFile);
      const mime: string = (want.parameters !== undefined ? want.parameters['shareMime'] as string : undefined) ??
        'application/octet-stream';
      const sandboxPath: string = this.copyToSandbox(shareFile);
      if (sandboxPath.length === 0) {
        hilog.error(DOMAIN, 'testTag', '%{public}s', 'share file: no sandbox copy available');
        return;
      }
      try {
        const uri: string = fileUri.getUriFromPath(sandboxPath);
        this.context.startAbility({
          action: 'ohos.want.action.sendData',
          uri: uri,
          type: mime,
          flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
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

    // Cancel file transfer from the transfer notification action button
    const cancelTransfer: string | undefined =
      want.parameters !== undefined ? want.parameters['cancelTransfer'] as string : undefined;
    if (cancelTransfer) {
      hilog.info(DOMAIN, 'testTag', 'Cancel file transfer job: %{public}s', cancelTransfer);
      const role: string = want.parameters !== undefined
        ? String(want.parameters['cancelTransferRole'] ?? 'send')
        : 'send';
      const deviceId: string = want.parameters !== undefined
        ? String(want.parameters['cancelTransferDevice'] ?? '')
        : '';
      AppSession.getInstance().cancelFileTransfer(deviceId, cancelTransfer, role);
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

  /** Map a file extension to a MIME type. */
  private static fileMime(ext: string): string {
    const mimeMap: Record<string, string> = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png',
      'gif': 'image/gif', 'bmp': 'image/bmp', 'webp': 'image/webp',
      'heic': 'image/heic', 'heif': 'image/heif',
      'mp4': 'video/mp4', 'avi': 'video/x-msvideo', 'mov': 'video/quicktime',
      'mkv': 'video/x-matroska', 'webm': 'video/webm',
      'mp3': 'audio/mpeg', 'wav': 'audio/wav', 'aac': 'audio/aac',
      'flac': 'audio/flac', 'ogg': 'audio/ogg',
      'pdf': 'application/pdf', 'doc': 'application/msword',
      'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel',
      'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint',
      'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'txt': 'text/plain', 'csv': 'text/csv', 'md': 'text/markdown',
      'json': 'application/json', 'xml': 'application/xml',
      'zip': 'application/zip', 'rar': 'application/x-rar-compressed',
      '7z': 'application/x-7z-compressed', 'apk': 'application/vnd.android.package-archive'
    };
    return mimeMap[ext] ?? 'application/octet-stream';
  }

  /**
   * Open a received file by type (HarmonyOS official guidance):
   *  - image/* → save to 图库 via the system dialog, open with the media uri
   *  - video/* → same, PhotoType.VIDEO
   *  - everything else (audio / pdf / documents) → viewData with a sandbox uri
   *    and FLAG_AUTH_READ_URI_PERMISSION so the target app can read the file.
   */
  private async openReceivedFile(filePath: string): Promise<void> {
    const ext: string = filePath.substring(filePath.lastIndexOf('.') + 1).toLowerCase();
    const mime: string = EntryAbility.fileMime(ext);
    if (mime.startsWith('image/')) {
      await this.openMediaInGallery(filePath, mime, photoAccessHelper.PhotoType.IMAGE);
      return;
    }
    if (mime.startsWith('video/')) {
      await this.openMediaInGallery(filePath, mime, photoAccessHelper.PhotoType.VIDEO);
      return;
    }
    this.openWithViewData(filePath);
  }

  /**
   * Copy a received file into the app sandbox so other apps can reach it via a
   * valid `file://<bundleName>/...` uri. Returns the sandbox path or '' on error.
   */
  private copyToSandbox(filePath: string): string {
    try {
      const fullName: string = filePath.substring(filePath.lastIndexOf('/') + 1);
      const sandboxPath: string = `${this.context.cacheDir}/kde_open_${Date.now()}_${fullName}`;
      fileIo.copyFileSync(filePath, sandboxPath);
      return sandboxPath;
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'sandbox copy failed: %{public}s', JSON.stringify(e));
      return '';
    }
  }

  /**
   * Open a file with another app via viewData.
   *
   * The uri must be a sandbox uri (file://<bundleName>/...) and the want must
   * carry FLAG_AUTH_READ_URI_PERMISSION to grant the target app read access —
   * otherwise the system file preview reports the file as "moved or renamed".
   */
  private openWithViewData(filePath: string): void {
    const ext: string = filePath.substring(filePath.lastIndexOf('.') + 1).toLowerCase();
    const mime: string = EntryAbility.fileMime(ext);
    const sandboxPath: string = this.copyToSandbox(filePath);
    if (sandboxPath.length === 0) {
      hilog.error(DOMAIN, 'testTag', '%{public}s', 'openWithViewData: no sandbox copy available');
      return;
    }
    const sandboxUri: string = fileUri.getUriFromPath(sandboxPath);
    hilog.info(DOMAIN, 'testTag', 'open viewData uri=%{public}s type=%{public}s', sandboxUri, mime);
    this.context.startAbility({
      action: 'ohos.want.action.viewData',
      uri: sandboxUri,
      type: mime,
      flags: wantConstant.Flags.FLAG_AUTH_READ_URI_PERMISSION
    }).catch((e: Error) => {
      hilog.error(DOMAIN, 'testTag', 'startAbility viewData failed: %{public}s', e.message);
    });
  }

  /**
   * Save an image / video into the gallery (图库) via the permission-free system
   * save dialog (photoAccessHelper.showAssetsCreationDialog), then open it there.
   * The dialog requires the source to live in the app sandbox, so we copy it first.
   */
  private async openMediaInGallery(
    filePath: string,
    mime: string,
    photoType: photoAccessHelper.PhotoType
  ): Promise<void> {
    const sandboxPath: string = this.copyToSandbox(filePath);
    if (sandboxPath.length === 0) {
      this.openWithViewData(filePath);
      return;
    }

    try {
      const srcUri: string = fileUri.getUriFromPath(sandboxPath);
      const helper: photoAccessHelper.PhotoAccessHelper = photoAccessHelper.getPhotoAccessHelper(this.context);
      const fullName: string = filePath.substring(filePath.lastIndexOf('/') + 1);
      const ext: string = filePath.substring(filePath.lastIndexOf('.') + 1).toLowerCase();
      const mediaExt: string = ext === 'jpeg' ? 'jpg' : (ext.length > 0 ? ext : 'jpg');
      const dot: number = fullName.lastIndexOf('.');
      const title: string = dot > 0 ? fullName.substring(0, dot) : fullName;
      const config: photoAccessHelper.PhotoCreationConfig = {
        title: title.length > 0 ? title : 'HMConnect',
        fileNameExtension: mediaExt,
        photoType: photoType
      };
      const desUris: string[] = await helper.showAssetsCreationDialog([srcUri], [config]);

      if (desUris && desUris.length > 0) {
        // Write the file content into the newly created media asset.
        const srcFile: fileIo.File = await fileIo.open(sandboxPath, fileIo.OpenMode.READ_ONLY);
        const desFile: fileIo.File = await fileIo.open(desUris[0], fileIo.OpenMode.WRITE_ONLY);
        try {
          await fileIo.copyFile(srcFile.fd, desFile.fd);
        } finally {
          try { fileIo.closeSync(srcFile); } catch (_sc) {}
          try { fileIo.closeSync(desFile); } catch (_dc) {}
        }
        hilog.info(DOMAIN, 'testTag', 'Media saved to gallery: %{public}s', desUris[0]);
        // Open the file via the officially-supported file-open path (sandbox uri +
        // read-permission flag). Opening the media uri directly can route to the
        // file-preview service which cannot render it ("预览失败").
        this.openWithViewData(filePath);
      } else {
        hilog.warn(DOMAIN, 'testTag', '%{public}s', 'User declined gallery save — fallback to viewData');
        this.openWithViewData(filePath);
      }
    } catch (e) {
      hilog.error(DOMAIN, 'testTag', 'openMediaInGallery failed: %{public}s', JSON.stringify(e));
      this.openWithViewData(filePath);
    } finally {
      try { fileIo.unlinkSync(sandboxPath); } catch (_unlinkErr) {
        // best effort cleanup
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

    // Edge-to-edge before first paint: transparent system bars + continuous app chrome.
    ImmersiveUtil.prepaint(
      windowStage,
      cssColor(this.context, UiTheme.surface),
      cssColor(this.context, UiTheme.onSurface)
    );

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      // Re-apply after content so system does not restore opaque status bar defaults.
      ImmersiveUtil.applyChrome(
        cssColor(this.context, UiTheme.surface),
        cssColor(this.context, UiTheme.onSurface)
      );
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
    // Keep remote AVSession alive for lock-screen card after resume
    const media = RemoteMprisMediaSession.getInstance();
    media.setContext(this.context);
    media.initSession().catch((e: Error) => {
      hilog.warn(DOMAIN, 'testTag', 'RemoteMpris init onForeground: %{public}s', e.message);
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
