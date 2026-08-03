import { AbilityConstant, ConfigurationConstant, UIAbility, Want, wantConstant } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { fileUri, fileIo } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import util from '@ohos.util';
import { ShareSendData } from '../service/KdeTypes';
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
    // System share target (ohos.want.action.sendData) — share from another app
    if (want.action === 'ohos.want.action.sendData') {
      hilog.info(DOMAIN, 'testTag', 'System share received: type=%{public}s uri=%{public}s',
        want.type ?? '', want.uri ?? '');
      hilog.info(DOMAIN, 'testTag', 'System share WANT: %{public}s', JSON.stringify(want));
      this.handleSharedData(want);
      return;
    }

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

    // Mirrored-notification action button (deviceId in value)
    const notifAction: string | undefined =
      want.parameters !== undefined ? want.parameters['notifAction'] as string : undefined;
    if (notifAction) {
      const remoteId: string = want.parameters !== undefined
        ? String(want.parameters['notifActionRemoteId'] ?? '')
        : '';
      const key: string = want.parameters !== undefined
        ? String(want.parameters['notifActionKey'] ?? '')
        : '';
      const title: string = want.parameters !== undefined
        ? String(want.parameters['notifActionTitle'] ?? '')
        : '';
      hilog.info(DOMAIN, 'testTag', 'Notification action device=%{public}s key=%{public}s', notifAction, key);
      AppSession.getInstance().sendNotificationAction(notifAction, remoteId, key, title);
      return;
    }

    // Mirrored-notification quick-reply (deviceId in value; text in userInput)
    const notifReply: string | undefined =
      want.parameters !== undefined ? want.parameters['notifReply'] as string : undefined;
    if (notifReply) {
      const remoteId: string = want.parameters !== undefined
        ? String(want.parameters['notifReplyRemoteId'] ?? '')
        : '';
      const requestReplyId: string = want.parameters !== undefined
        ? String(want.parameters['notifReplyRequestId'] ?? '')
        : '';
      // NotificationUserInput text arrives under 'notificationUserInput'.
      const message: string = want.parameters !== undefined
        ? String(want.parameters['notificationUserInput'] ?? '')
        : '';
      hilog.info(DOMAIN, 'testTag', 'Notification reply device=%{public}s len=%{public}d',
        notifReply, message.length);
      if (message.length > 0) {
        AppSession.getInstance().sendNotificationReply(notifReply, remoteId, requestReplyId, message);
      }
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

  /**
   * System share sheet picked us: copy the shared FD/URI into the cache and
   * route to the device-picker (Android ShareActivity equivalent).
   */
  private handleSharedData(want: Want): void {
    this.copySharedToCache(want).then((data: ShareSendData) => {
      hilog.info(DOMAIN, 'testTag', 'Share ready file=%{public}s text=%{public}d',
        data.fileName, data.isText ? 1 : 0);
      AppSession.getInstance().openShareSend(data);
    }).catch((e: Error) => {
      hilog.error(DOMAIN, 'testTag', 'handleSharedData failed: %{public}s', e.message);
    });
  }

  private async copySharedToCache(want: Want): Promise<ShareSendData> {
    const mime: string = typeof want.type === 'string' && want.type.length > 0
      ? want.type
      : 'application/octet-stream';
    const uris: string[] = this.sharedUris(want);
    const fileName: string = this.sharedFileName(want, uris);

    // Text/URL share (no file URI) → pure text path.
    if (uris.length === 0) {
      return {
        filePaths: [],
        fileName: fileName,
        mime: mime,
        isText: true,
        textContent: this.sharedText(want)
      };
    }

    // Copy each shared URI into the cache (temp permission lasts the invocation).
    const cacheDir: string = this.context.cacheDir;
    const paths: string[] = [];
    for (let i = 0; i < uris.length; i++) {
      const target: string = `${cacheDir}/shared_${Date.now()}_${i}_${this.sanitizeShareName(fileName)}`;
      try {
        await this.copyUriToFile(uris[i], target);
        paths.push(target);
      } catch (e) {
        hilog.error(DOMAIN, 'testTag', 'copy shared uri failed: %{public}s', JSON.stringify(e));
      }
    }
    if (paths.length === 0) {
      return {
        filePaths: [],
        fileName: fileName,
        mime: mime,
        isText: true,
        textContent: ''
      };
    }

    return { filePaths: paths, fileName: fileName, mime: mime, isText: false, textContent: '' };
  }

  /**
   * File URIs delivered by the share panel. Newer HarmonyOS puts them in
   * parameters['ability.params.stream'] (array); classic want.uri also works.
   */
  private sharedUris(want: Want): string[] {
    const out: string[] = [];
    try {
      const stream = want.parameters ? want.parameters['ability.params.stream'] as object : undefined;
      if (stream && Array.isArray(stream)) {
        for (let i = 0; i < stream.length; i++) {
          if (typeof stream[i] === 'string' && (stream[i] as string).length > 0) {
            out.push(stream[i] as string);
          }
        }
      }
    } catch (_e) {
    }
    if (typeof want.uri === 'string' && want.uri.length > 0) {
      out.push(want.uri);
    }
    return out;
  }

  private sharedFileName(want: Want, uris: string[]): string {
    try {
      const names = want.parameters ? want.parameters['ability.picker.fileNames'] as object : undefined;
      if (names && Array.isArray(names) && names.length > 0) {
        const first = names[0] as string;
        if (first && first.length > 0) {
          return first;
        }
      }
    } catch (_e) {
    }
    if (uris.length > 0) {
      const seg = uris[0].split('/');
      const last = seg[seg.length - 1] || '';
      if (last.length > 0) {
        return decodeURIComponent(last);
      }
    }
    const type: string = typeof want.type === 'string' ? want.type : 'file';
    return `shared.${this.extForMime(type)}`;
  }

  private sharedText(want: Want): string {
    try {
      const t = want.parameters ? want.parameters['text'] as string : undefined;
      if (t && t.length > 0) {
        return t;
      }
    } catch (_e) {
    }
    return '';
  }

  private sanitizeShareName(name: string): string {
    const cleaned: string = name.replace(/[\\/:*?"<>|]/g, '_');
    return cleaned.length > 0 ? cleaned : 'shared';
  }

  private extForMime(mime: string): string {
    if (mime.startsWith('image/')) {
      return mime === 'image/png' ? 'png' : 'jpg';
    }
    if (mime.startsWith('video/')) {
      return 'mp4';
    }
    if (mime.startsWith('audio/')) {
      return 'mp3';
    }
    if (mime === 'application/pdf') {
      return 'pdf';
    }
    if (mime === 'text/plain') {
      return 'txt';
    }
    return 'bin';
  }

  private async copyUriToFile(uri: string, target: string): Promise<void> {
    const src = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
    const out = fileIo.openSync(target, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY |
      fileIo.OpenMode.TRUNC);
    const buf: ArrayBuffer = new ArrayBuffer(65536);
    try {
      while (true) {
        const n: number = fileIo.readSync(src.fd, buf);
        if (n <= 0) {
          break;
        }
        const slice: ArrayBuffer = new ArrayBuffer(n);
        new Uint8Array(slice).set(new Uint8Array(buf, 0, n));
        fileIo.writeSync(out.fd, slice);
      }
    } finally {
      fileIo.closeSync(src);
      fileIo.closeSync(out);
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
