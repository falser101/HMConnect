import { fileIo } from '@kit.CoreFileKit';
import {
  FileSendInfo,
  KdeShareRequestBody,
  PACKET_TYPE_SHARE_REQUEST_UPDATE,
  serializePacket
} from './KdeTypes';
import { DeviceSession } from './DeviceSession';

/**
 * Queued file-send job — mirrors Android CompositeUploadFileJob.
 *
 * Usage:
 *   const job = new FileSendJob(session);
 *   job.addFile({ uri, displayName, size, lastModified });
 *   await job.run((overallPercent, currentFileName) => { ... });
 *   job.cancel(); // from UI
 */
export class FileSendJob {
  private files: FileSendInfo[] = [];
  private totalSize: number = 0;
  private cancelled: boolean = false;
  private client: DeviceSession;

  constructor(client: DeviceSession) {
    this.client = client;
  }

  /** Append a file to the send queue. */
  addFile(info: FileSendInfo): void {
    this.files.push(info);
    this.totalSize += info.size;
  }

  get fileCount(): number {
    return this.files.length;
  }

  /** Cancel while running. */
  cancel(): void {
    this.cancelled = true;
  }

  /**
   * Send all queued files sequentially (blocking per file, matching Android).
   *
   * @param onProgress  (overallPercent 0–100, currentFileName)
   */
  async run(onProgress?: (percent: number, fileName: string) => void): Promise<void> {
    if (this.files.length === 0) {
      return;
    }

    const totalFiles = this.files.length;

    // ── Send update packet (metadata ahead of files) ──
    this.sendUpdatePacket(totalFiles, this.totalSize);

    let totalSent = 0;

    for (let i = 0; i < this.files.length; i++) {
      if (this.cancelled) {
        console.info('[FileSendJob] Cancelled, stopping.');
        break;
      }

      const info = this.files[i];
      const body: KdeShareRequestBody = {
        filename: info.displayName,
        numberOfFiles: totalFiles,
        totalPayloadSize: this.totalSize,
        lastModified: info.lastModified
      };

      try {
        await this.client.sendPacketWithPayload(body, info.uri, (filePercent) => {
          // filePercent is 0–100 for the current file
          const fileWeight = info.size / this.totalSize;
          const contributed = Math.round(fileWeight * filePercent);
          const overall = Math.min(100, Math.round(
            ((totalSent + (info.size * filePercent / 100)) * 100) / this.totalSize
          ));
          if (onProgress) {
            onProgress(overall, info.displayName);
          }
        });
        totalSent += info.size;
      } catch (e) {
        console.error(`[FileSendJob] Failed to send "${info.displayName}":`, JSON.stringify(e));
        // Continue with next file rather than aborting the whole batch
      }
    }

    if (onProgress) {
      onProgress(100, '');
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
