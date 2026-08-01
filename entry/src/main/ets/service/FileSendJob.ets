import { fileIo } from '@kit.CoreFileKit';
import { AppNotifier } from '../common/AppNotifier';
import {
  FileSendInfo,
  FileTransferNotifyInfo,
  FileTransferResultInfo,
  KdeShareRequestBody,
  PACKET_TYPE_SHARE_REQUEST_UPDATE,
  TransferCancelToken,
  serializePacket
} from './KdeTypes';
import { DeviceSession } from './DeviceSession';

/**
 * Queued file-send job — mirrors Android CompositeUploadFileJob +
 * UploadNotification (progress / finished / failed banners, cancel action).
 *
 * Usage:
 *   const job = new FileSendJob(session);
 *   job.addFile({ uri, displayName, size, lastModified });
 *   await job.run((overallPercent, currentFileName) => { ... });
 *   job.cancel(); // from UI or notification
 */
export class FileSendJob {
  private files: FileSendInfo[] = [];
  private totalSize: number = 0;
  private cancelled: boolean = false;
  private client: DeviceSession;
  private jobId: string = '';
  private cancelToken: TransferCancelToken = { cancelled: false };
  /** Called once the job is done (finished/failed/cancelled) so the hub can unregister. */
  private onDone?: () => void;

  constructor(client: DeviceSession) {
    this.client = client;
  }

  /** Unique job id (registered in KdeService for notification cancel routing). */
  public getJobId(): string {
    return this.jobId;
  }

  public setJobId(id: string): void {
    this.jobId = id;
  }

  public setOnDone(cb: () => void): void {
    this.onDone = cb;
  }

  /** Append a file to the send queue. */
  addFile(info: FileSendInfo): void {
    this.files.push(info);
    this.totalSize += info.size;
  }

  get fileCount(): number {
    return this.files.length;
  }

  /** Cancel while running (Android ShareBroadcastReceiver ACTION_CANCEL_SHARE). */
  cancel(): void {
    if (this.cancelled) {
      return;
    }
    this.cancelled = true;
    this.cancelToken.cancelled = true;
  }

  get isCancelled(): boolean {
    return this.cancelled;
  }

  /**
   * Send all queued files sequentially (blocking per file, matching Android).
   * Shows an ongoing progress notification with a cancel action; finishes with
   * a sent/failed banner. Aborts the whole batch on the first error (Android).
   *
   * @param onProgress  (overallPercent 0–100, currentFileName)
   */
  async run(onProgress?: (percent: number, fileName: string) => void): Promise<void> {
    if (this.files.length === 0) {
      this.finishJob();
      return;
    }

    const totalFiles: number = this.files.length;
    const peer = this.client.getPeer();
    const deviceName: string = peer?.deviceName ?? '设备';
    const deviceId: string = this.client.getBoundDeviceId();

    // ── Send update packet (metadata ahead of files) ──
    this.sendUpdatePacket(totalFiles, this.totalSize);

    let totalSent = 0;
    let failed = false;
    let failedCount = 0;
    let lastFileName: string = '';

    try {
      for (let i = 0; i < this.files.length; i++) {
        if (this.cancelled) {
          console.info('[FileSendJob] Cancelled, stopping.');
          break;
        }

        const info = this.files[i];
        lastFileName = info.displayName;
        const fileIndex: number = i + 1;
        const body: KdeShareRequestBody = {
          filename: info.displayName,
          numberOfFiles: totalFiles,
          totalPayloadSize: this.totalSize,
          lastModified: info.lastModified
        };

        // Show the ongoing banner immediately (Android UploadNotification at job start)
        const startOverall: number = this.totalSize > 0
          ? Math.min(100, Math.round((totalSent * 100) / this.totalSize))
          : 0;
        this.notifyProgress(fileIndex, totalFiles, info.displayName, startOverall, deviceName, deviceId);
        if (onProgress) {
          onProgress(startOverall, info.displayName);
        }

        try {
          await this.client.sendPacketWithPayload(body, info.uri, (filePercent: number) => {
            // Android: send = totalSend + currentFileSize * (percent/100)
            const sendSoFar: number = totalSent + (info.size * filePercent / 100);
            const overall: number = this.totalSize > 0
              ? Math.min(100, Math.round((sendSoFar * 100) / this.totalSize))
              : filePercent;
            if (onProgress) {
              onProgress(overall, info.displayName);
            }
            // Throttled updates (Android: ≥500ms) — sendPacketWithPayload already throttles.
            this.notifyProgress(fileIndex, totalFiles, info.displayName, overall, deviceName, deviceId);
          }, this.cancelToken);
          totalSent += info.size;
        } catch (e) {
          // Cancel is a graceful stop, not an error (Android: job.cancel()).
          if (this.cancelled) {
            break;
          }
          console.error(`[FileSendJob] Failed to send "${info.displayName}":`, JSON.stringify(e));
          failed = true;
          failedCount = totalFiles - i;
          break;
        }
      }

      if (this.cancelled) {
        AppNotifier.getInstance().cancelTransferNotification(this.jobId);
        return;
      }

      if (onProgress && !failed) {
        onProgress(100, '');
      }

      if (failed) {
        const result: FileTransferResultInfo = {
          role: 'send',
          jobId: this.jobId,
          deviceName: deviceName,
          deviceId: deviceId,
          numFiles: totalFiles - failedCount,
          totalFiles: totalFiles
        };
        AppNotifier.getInstance().notifyTransferFailed(result).catch((e: Error) => {
          console.error('[FileSendJob] failed notify error:', e.message);
        });
      } else {
        const result: FileTransferResultInfo = {
          role: 'send',
          jobId: this.jobId,
          deviceName: deviceName,
          deviceId: deviceId,
          numFiles: totalFiles,
          totalFiles: totalFiles,
          fileName: lastFileName.length > 0 ? lastFileName : undefined
        };
        AppNotifier.getInstance().notifyTransferFinished(result).catch((e: Error) => {
          console.error('[FileSendJob] finished notify error:', e.message);
        });
      }
    } finally {
      this.finishJob();
    }
  }

  /** Progress banner (Android UploadNotification.setProgress). */
  private notifyProgress(
    fileIndex: number,
    totalFiles: number,
    fileName: string,
    percent: number,
    deviceName: string,
    deviceId: string
  ): void {
    const info: FileTransferNotifyInfo = {
      role: 'send',
      jobId: this.jobId,
      deviceName: deviceName,
      deviceId: deviceId,
      fileName: fileName,
      fileIndex: fileIndex,
      totalFiles: totalFiles,
      percent: percent
    };
    AppNotifier.getInstance().notifyTransferProgress(info).catch((e: Error) => {
      console.error('[FileSendJob] progress notify error:', e.message);
    });
  }

  private finishJob(): void {
    if (this.onDone) {
      const cb: (() => void) = this.onDone;
      this.onDone = undefined;
      setTimeout(() => {
        cb();
      }, 0);
    }
  }

  /**
   * Send a kdeconnect.share.request.update packet with batch metadata
   * so the receiving PC knows the total count & size ahead of time.
   */
  private sendUpdatePacket(numberOfFiles: number, totalPayloadSize: number): void {
    try {
      const body: KdeShareRequestBody = {
        numberOfFiles: numberOfFiles,
        totalPayloadSize: totalPayloadSize
      };
      const json = serializePacket(PACKET_TYPE_SHARE_REQUEST_UPDATE, body);
      this.client.sendJson(json);
    } catch (_e) {
      // Non-fatal — PC can still receive files without the update packet
    }
  }
}
