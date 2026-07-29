import socket from '@ohos.net.socket';
import pasteboard from '@ohos.pasteboard';
import { fileIo, picker, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { AppNotifier } from '../common/AppNotifier';
import {
  KdeDevice,
  KdeIdentityBody,
  KdePairBody,
  KdeClipboardBody,
  KdePingBody,
  KdeBatteryBody,
  KdeShareRequestBody,
  KdeFindMyPhoneBody,
  KdePacket,
  PayloadTransferInfo,
  PeerBatteryInfo,
  KdeStatus,
  ConnectionState,
  TrustedDevice,
  KDE_PROTOCOL_VERSION,
  PAIR_TIMESTAMP_MAX_DIFF_SEC,
  MY_DEVICE_ID,
  INCOMING_CAPABILITIES,
  OUTGOING_CAPABILITIES,
  PAYLOAD_TRANSFER_MIN_PORT,
  PAYLOAD_TRANSFER_MAX_PORT,
  PACKET_TYPE_SHARE_REQUEST,
  PACKET_TYPE_MPRIS,
  PACKET_TYPE_MPRIS_REQUEST,
  MprisPlayerState,
  sanitizeDeviceName,
  serializePacket,
  serializePacketWithPayload,
  parsePacketLine
} from './KdeTypes';
import { DeviceStore } from '../store/DeviceStore';
import { PluginSettingsStore } from '../store/PluginSettingsStore';
import {
  PLUGIN_BATTERY,
  PLUGIN_CLIPBOARD,
  PLUGIN_FIND_MY_PHONE,
  PLUGIN_MPRIS,
  PLUGIN_PING,
  PLUGIN_SHARE,
  pluginKeyForPacketType
} from './PluginRegistry';
import { utf8Decode } from '../common/Utf8';
import { BatteryHelper } from '../common/BatteryHelper';
import { FindMyPhoneHelper } from '../common/FindMyPhoneHelper';
import { VerificationKeyHelper } from '../common/VerificationKeyHelper';

/**
 * Per-device connection session (one peer).
 * Reverse-path preferred; outbound TLS fallback after reverse timeout.
 * Owned by KdeClient multi-session hub — does NOT own the shared TCP listen socket.
 */
export class DeviceSession {
  /** Stable peer id once known (may be empty during early outbound). */
  private boundDeviceId: string = '';
  /** Shared listen port from hub (advertised in identity). */
  private listenPort: number = 1716;
  private myDeviceName: string = 'HarmonyOS';
  /** Unique loopback bridge base so multi-session bridges do not collide. */
  private bridgeBasePort: number = 37564;

  private tlsSocket: socket.TLSSocket | null = null;
  private bridgeRemote: socket.TCPSocketConnection | null = null;
  private bridgeLocalAccepted: socket.TCPSocketConnection | null = null;
  private bridgeLocalServer: socket.TCPSocketServer | null = null;
  private bridgeLocalClient: socket.TCPSocket | null = null;
  /** Buffer early TLS bytes arriving before bridge is wired. */
  private pendingBridgeBytes: ArrayBuffer[] = [];

  // ── Outbound connection state (we initiate TCP to peer) ──
  private outboundActive: boolean = false;
  private outboundTargetIp: string = '';
  /** Rate limiting (Android: rateLimitByIp / rateLimitByDeviceId). */
  private lastConnTimeByIp: Record<string, number> = {};
  private lastConnTimeById: Record<string, number> = {};
  private static readonly CONN_RATE_MS: number = 1000;
  private outPeerSock: socket.TCPSocket | null = null;
  private outBridgeServer: socket.TCPSocketServer | null = null;
  private outBridgeAccepted: socket.TCPSocketConnection | null = null;
  private outBridgeClient: socket.TCPSocket | null = null;
  private outTlsServer: socket.TLSSocketServer | null = null;
  private outTlsFeeder: socket.TCPSocket | null = null;
  private outTlsConn: socket.TLSSocketConnection | null = null;

  private paired: boolean = false;
  private sessionLive: boolean = false; // TLS channel established (may not be paired yet)
  private peerDevice: KdeDevice | null = null;
  /** DeviceIds we have successfully paired with (persist for this app run). */
  private trustedDeviceIds: Set<string> = new Set();
  /** Avoid sending multiple pair:true while waiting for PC accept. */
  private pairRequestSentForGen: number = -1;
  /** Pair-accept queued — TLS not yet live when peer's pair:true arrived. */
  private pendingPairAccept: boolean = false;
  /** Peer has requested pairing — UI shows accept/reject. */
  private pairRequestedByPeer: boolean = false;
  /** Pairing timeout timer (Android: 30s we-request / 25s peer-request). */
  private pairTimeoutTimer: number = -1;
  private static readonly PAIR_REQUEST_TIMEOUT_MS: number = 30000;
  private static readonly PAIR_PEER_TIMEOUT_MS: number = 25000;
  /** Latest MPRIS player state from remote device. */
  private mprisPlayer: MprisPlayerState | null = null;
  private onMprisChange?: (player: MprisPlayerState | null) => void;
  /** Local media state for MPRIS receiver (remote controls us). */
  private localPlaying: boolean = false;
  private localVolume: number = 50;
  /** AVSession for receiving system media keys and reporting state. */
  private mprisSession: avSession.AVSession | null = null;
  private mprisController: avSession.AVSessionController | null = null;
  private statusCallback?: (status: KdeStatus) => void;
  private onSessionChange?: (live: boolean, paired: boolean) => void;
  private lineBuffer: string = '';
  private context: common.UIAbilityContext | null = null;
  private certPem: string = '';
  private keyPem: string = '';
  /** Monotonic id so stale TLS/path callbacks cannot clobber a newer session. */
  private sessionGen: number = 0;
  private activeTlsGen: number = -1;
  private handlingIncoming: boolean = false;
  /** Last battery info received from the current peer (desktop). */
  private peerBattery: PeerBatteryInfo | null = null;
  /** Periodic local battery report while TLS is live. */
  private batteryTimer: number = -1;
  private lastSentCharge: number = -1;
  private lastSentCharging: boolean = false;

  /** SPKI public keys for pairing verification (Android PairingHandler). */
  private localPubKey: Uint8Array | null = null;
  private remotePubKey: Uint8Array | null = null;
  /** Pair packet timestamp (seconds) for protocol ≥8 verification. */
  private pairingTimestamp: number = 0;
  /** Cached 8-char verification code; recomputed when certs/timestamp change. */
  private cachedVerificationKey: string = '';
  /**
   * Protocol v8: post-TLS identity exchange completed (Android LanLinkProvider
   * secureIdentityPacket). When peer is <8, treated as done immediately.
   */
  private secureIdentityDone: boolean = false;
  /** Resolver waiting for peer's encrypted identity line. */
  private secureIdentityWaiter: ((ok: boolean) => void) | null = null;
  /** Peer identity arrived before waiter was armed. */
  private pendingSecureIdentity: KdeIdentityBody | null = null;
  private static readonly SECURE_IDENTITY_TIMEOUT_MS: number = 10000;

  /**
   * Inject shared hub resources (context, certs, identity, unique bridge port).
   * When `updateBridgePort` is false, keep the existing loopback bridge base (live sessions).
   */
  public configure(
    ctx: common.UIAbilityContext | null,
    certPem: string,
    keyPem: string,
    myDeviceName: string,
    listenPort: number,
    bridgeBasePort: number,
    updateBridgePort: boolean
  ): void {
    this.context = ctx;
    this.certPem = certPem;
    this.keyPem = keyPem;
    this.myDeviceName = myDeviceName;
    this.listenPort = listenPort;
    if (updateBridgePort) {
      this.bridgeBasePort = bridgeBasePort;
    }
  }

  public setTrustedCache(ids: Set<string>): void {
    this.trustedDeviceIds = ids;
  }

  public setStatusListener(cb: (status: KdeStatus) => void): void {
    this.statusCallback = cb;
  }

  /** Hub listens so it can refresh multi-device list / announce policy. */
  public setSessionChangeListener(cb: (live: boolean, paired: boolean) => void): void {
    this.onSessionChange = cb;
  }

  private notifySessionChange(): void {
    if (this.onSessionChange) {
      this.onSessionChange(this.sessionLive, this.paired);
    }
  }

  public getBoundDeviceId(): string {
    if (this.boundDeviceId.length > 0) {
      return this.boundDeviceId;
    }
    return this.peerDevice?.deviceId ?? '';
  }

  public getListenPort(): number {
    return this.listenPort;
  }

  public isPaired(): boolean {
    return this.paired;
  }

  public getPeer(): KdeDevice | null {
    return this.peerDevice;
  }

  /** We sent pair:true and wait for peer (Android PairState.Requested). */
  public isPairRequested(): boolean {
    return this.pairRequestSentForGen >= 0 && !this.paired && !this.pairRequestedByPeer;
  }

  /**
   * Android PairingHandler.PairState for UI.
   * Trusted devices report as paired even if TLS is down.
   */
  public getPairState(): 'not_paired' | 'requested' | 'requested_by_peer' | 'paired' {
    const id = this.getBoundDeviceId();
    if (this.paired || (id.length > 0 && this.isTrusted(id))) {
      return 'paired';
    }
    if (this.pairRequestedByPeer) {
      return 'requested_by_peer';
    }
    if (this.pairRequestSentForGen >= 0) {
      return 'requested';
    }
    return 'not_paired';
  }

  private clearPairTimer(): void {
    if (this.pairTimeoutTimer >= 0) {
      clearTimeout(this.pairTimeoutTimer);
      this.pairTimeoutTimer = -1;
    }
  }

  private startPairTimer(ms: number, timeoutMessage: string): void {
    this.clearPairTimer();
    const gen = this.sessionGen;
    this.pairTimeoutTimer = setTimeout(() => {
      this.pairTimeoutTimer = -1;
      if (gen !== this.sessionGen) {
        return;
      }
      if (this.paired) {
        return;
      }
      console.warn(`[KDE-MVP] Pairing timed out after ${ms}ms`);
      this.pairRequestSentForGen = -1;
      this.pairRequestedByPeer = false;
      this.notifySessionChange();
      this.emit('error', timeoutMessage, {
        peerName: this.peerDevice?.deviceName,
        peerDeviceId: this.peerDevice?.deviceId
      });
    }, ms) as number;
  }

  public getPeerBattery(): PeerBatteryInfo | null {
    return this.peerBattery;
  }

  /**
   * Android pairVerification text — only meaningful during pairing states.
   * Empty when not pairing or certs not yet available.
   */
  public getVerificationKey(): string {
    const state = this.getPairState();
    if (state !== 'requested' && state !== 'requested_by_peer') {
      return '';
    }
    return this.cachedVerificationKey;
  }

  public getPeerIncomingCapabilities(): string[] {
    return this.peerDevice?.incomingCapabilities ?? [];
  }

  public getPeerOutgoingCapabilities(): string[] {
    return this.peerDevice?.outgoingCapabilities ?? [];
  }

  private applyPeerCapabilities(body: KdeIdentityBody): void {
    if (!this.peerDevice) {
      return;
    }
    if (body.incomingCapabilities && body.incomingCapabilities.length > 0) {
      this.peerDevice.incomingCapabilities = body.incomingCapabilities.slice();
    }
    if (body.outgoingCapabilities && body.outgoingCapabilities.length > 0) {
      this.peerDevice.outgoingCapabilities = body.outgoingCapabilities.slice();
    }
  }

  private async ensureLocalPubKey(): Promise<void> {
    if (this.localPubKey !== null) {
      return;
    }
    if (this.certPem.length === 0) {
      return;
    }
    const pk = await VerificationKeyHelper.pubKeyFromPem(this.certPem);
    if (pk) {
      this.localPubKey = pk;
    }
  }

  private async recomputeVerificationKey(): Promise<void> {
    await this.ensureLocalPubKey();
    if (!this.localPubKey || !this.remotePubKey) {
      this.cachedVerificationKey = '';
      return;
    }
    try {
      // Android PairingHandler.verificationKey: use *remote* protocolVersion.
      // With both sides on v8 → V8(timestamp). Mixed remote <8 → V7.
      const peerProto = this.peerDevice?.protocolVersion ?? KDE_PROTOCOL_VERSION;
      const useV8 = peerProto >= 8 && this.pairingTimestamp > 0;
      let key: string;
      if (useV8) {
        key = await VerificationKeyHelper.getVerificationKeyV8(
          this.localPubKey,
          this.remotePubKey,
          this.pairingTimestamp
        );
      } else {
        key = await VerificationKeyHelper.getVerificationKeyV7(
          this.localPubKey,
          this.remotePubKey
        );
      }
      this.cachedVerificationKey = key;
      console.info(
        `[KDE-MVP] Verification key: ${key} (localProto=${KDE_PROTOCOL_VERSION} peerProto=${peerProto} ` +
          `useV8=${useV8} ts=${this.pairingTimestamp} ` +
          `localPk=${this.localPubKey.byteLength}b remotePk=${this.remotePubKey.byteLength}b)`
      );
      this.notifySessionChange();
    } catch (e) {
      console.warn('[KDE-MVP] recomputeVerificationKey failed:', JSON.stringify(e));
      this.cachedVerificationKey = '';
    }
  }

  /** Android: post-TLS identity only when remote protocolVersion >= 8. */
  private needsSecureIdentityExchange(): boolean {
    // Default to our version when unknown so we don't skip against a real v8 peer
    const peerProto = this.peerDevice?.protocolVersion ?? KDE_PROTOCOL_VERSION;
    return peerProto >= 8;
  }

  /**
   * After TLS is up: optional v8 secure identity exchange, then session services.
   * Android LanLinkProvider handshakeCompletedListener.
   */
  private async afterTlsReady(gen: number, fromOutbound: boolean): Promise<void> {
    if (gen !== this.sessionGen) {
      return;
    }
    if (this.needsSecureIdentityExchange()) {
      const ok = await this.exchangeSecureIdentity(gen);
      if (!ok || gen !== this.sessionGen) {
        console.error('[KDE-MVP] Secure identity exchange failed');
        if (gen === this.sessionGen && !this.paired) {
          this.emit('error', '协议握手失败（identity），请重试');
          this.disconnect();
        }
        return;
      }
      console.info('[KDE-MVP] Protocol v8 secure identity OK');
    } else {
      this.secureIdentityDone = true;
    }

    if (gen !== this.sessionGen) {
      return;
    }

    // Flush pair-accept that arrived before channel was fully ready
    if (this.pendingPairAccept) {
      this.pendingPairAccept = false;
      const accept: string = serializePacket('kdeconnect.pair', { pair: true } as KdePairBody);
      this.sendTls(accept, () => {
      });
      console.info('[KDE-MVP] flushed pending pair-accept');
    }

    this.startBatteryReporting();
    this.captureTlsCertificates(fromOutbound);
    if (this.context) {
      this.setupMprisReceiver(this.context);
    }

    const peer = this.peerDevice;
    if (!peer) {
      return;
    }
    const deviceId = peer.deviceId;
    if (this.isTrusted(deviceId) || this.paired) {
      this.paired = true;
      this.trustedDeviceIds.add(deviceId);
      this.persistTrust(peer).catch(() => {
      });
      this.emit('paired', `已与 ${peer.deviceName} 恢复加密连接`, {
        peerName: peer.deviceName,
        peerDeviceId: peer.deviceId
      });
      console.info('[KDE-MVP] Trusted device, skip pair request');
      return;
    }
    this.emit('connected', '已加密连接', {
      peerName: peer.deviceName,
      peerDeviceId: peer.deviceId
    });
  }

  /**
   * Protocol v8: write our identity on TLS, read peer's encrypted identity.
   * Android writes first then reads (avoid deadlock).
   */
  private exchangeSecureIdentity(gen: number): Promise<boolean> {
    return new Promise<boolean>((resolve: (v: boolean) => void) => {
      if (gen !== this.sessionGen) {
        resolve(false);
        return;
      }

      const finish = (ok: boolean): void => {
        if (this.secureIdentityWaiter !== null) {
          this.secureIdentityWaiter = null;
        }
        if (timer >= 0) {
          clearTimeout(timer);
          timer = -1;
        }
        resolve(ok);
      };

      // Peer identity may already be in flight
      if (this.pendingSecureIdentity !== null) {
        const body = this.pendingSecureIdentity;
        this.pendingSecureIdentity = null;
        if (this.applySecureIdentity(body)) {
          this.secureIdentityDone = true;
          // Still send ours (peer is waiting)
          const idPacket = this.buildIdentityPacket();
          this.sendTls(idPacket, () => {
          });
          finish(true);
          return;
        }
        finish(false);
        return;
      }

      let timer: number = setTimeout(() => {
        timer = -1;
        console.error('[KDE-MVP] Secure identity timeout');
        this.secureIdentityWaiter = null;
        resolve(false);
      }, DeviceSession.SECURE_IDENTITY_TIMEOUT_MS) as number;

      this.secureIdentityWaiter = (ok: boolean): void => {
        finish(ok);
      };

      const idPacket = this.buildIdentityPacket();
      this.sendTls(idPacket, (err) => {
        if (gen !== this.sessionGen) {
          finish(false);
          return;
        }
        if (err) {
          console.error('[KDE-MVP] Send secure identity failed:', JSON.stringify(err));
          finish(false);
          return;
        }
        console.info('[KDE-MVP] Sent protocol v8 secure identity');
        // If peer packet arrived between arming waiter and send
        if (this.pendingSecureIdentity !== null && this.secureIdentityWaiter !== null) {
          const body = this.pendingSecureIdentity;
          this.pendingSecureIdentity = null;
          if (this.applySecureIdentity(body)) {
            this.secureIdentityDone = true;
            this.secureIdentityWaiter(true);
          } else {
            this.secureIdentityWaiter(false);
          }
        }
      });
    });
  }

  /** Validate encrypted identity vs pre-TLS peer; update caps/name. */
  private applySecureIdentity(body: KdeIdentityBody): boolean {
    if (!body || !body.deviceId) {
      console.error('[KDE-MVP] Secure identity missing deviceId');
      return false;
    }
    const expectedId = this.peerDevice?.deviceId ?? this.boundDeviceId;
    if (expectedId.length > 0 && body.deviceId !== expectedId) {
      console.error(
        `[KDE-MVP] Secure identity deviceId mismatch: ${body.deviceId} vs ${expectedId}`
      );
      return false;
    }
    const preProto = this.peerDevice?.protocolVersion ?? KDE_PROTOCOL_VERSION;
    const newProto = body.protocolVersion ?? preProto;
    if (body.protocolVersion !== undefined && body.protocolVersion !== preProto) {
      console.error(
        `[KDE-MVP] Protocol version changed mid-handshake: ${preProto} -> ${body.protocolVersion}`
      );
      return false;
    }
    if (!this.peerDevice) {
      this.peerDevice = {
        deviceId: body.deviceId,
        deviceName: sanitizeDeviceName(body.deviceName ?? 'PC'),
        ip: '',
        tcpPort: body.tcpPort ?? 1716,
        protocolVersion: newProto,
        deviceType: body.deviceType ?? 'desktop',
        incomingCapabilities: body.incomingCapabilities
          ? body.incomingCapabilities.slice()
          : undefined,
        outgoingCapabilities: body.outgoingCapabilities
          ? body.outgoingCapabilities.slice()
          : undefined
      };
    } else {
      if (body.deviceName) {
        this.peerDevice.deviceName = sanitizeDeviceName(body.deviceName);
      }
      if (body.deviceType) {
        this.peerDevice.deviceType = body.deviceType;
      }
      this.peerDevice.protocolVersion = newProto;
      this.applyPeerCapabilities(body);
    }
    this.boundDeviceId = body.deviceId;
    this.notifySessionChange();
    return true;
  }

  private handleSecureIdentityPacket(body: KdeIdentityBody): void {
    if (this.secureIdentityDone) {
      // Late identity — refresh caps only
      if (body.deviceId === (this.peerDevice?.deviceId ?? '')) {
        this.applyPeerCapabilities(body);
      }
      return;
    }
    if (this.secureIdentityWaiter !== null) {
      if (this.applySecureIdentity(body)) {
        this.secureIdentityDone = true;
        this.secureIdentityWaiter(true);
      } else {
        this.secureIdentityWaiter(false);
      }
      return;
    }
    // Arrived before exchangeSecureIdentity armed the waiter
    this.pendingSecureIdentity = body;
  }

  /**
   * Capture peer (and local) certs after TLS is up — for pairing verification UI.
   * Safe to call multiple times; no-ops if remote already known.
   */
  private captureTlsCertificates(fromOutbound: boolean): void {
    this.ensureLocalPubKey().then(() => {
      // Prefer live TLS remote cert; fall back already handled by local PEM
      const tryRemote = async (): Promise<void> => {
        try {
          if (fromOutbound && this.outTlsConn) {
            const raw = await this.outTlsConn.getRemoteCertificate();
            const pk = await VerificationKeyHelper.pubKeyFromCertBlob(raw);
            if (pk) {
              this.remotePubKey = pk;
            }
          } else if (this.tlsSocket) {
            const raw = await this.tlsSocket.getRemoteCertificate();
            const pk = await VerificationKeyHelper.pubKeyFromCertBlob(raw);
            if (pk) {
              this.remotePubKey = pk;
            }
          }
        } catch (e) {
          console.warn('[KDE-MVP] getRemoteCertificate failed:', JSON.stringify(e));
        }
        await this.recomputeVerificationKey();
      };
      tryRemote().catch(() => {
      });
    }).catch(() => {
    });
  }

  private clearVerificationState(): void {
    this.remotePubKey = null;
    this.pairingTimestamp = 0;
    this.cachedVerificationKey = '';
    this.secureIdentityDone = false;
    this.pendingSecureIdentity = null;
    if (this.secureIdentityWaiter !== null) {
      const w = this.secureIdentityWaiter;
      this.secureIdentityWaiter = null;
      w(false);
    }
  }

  /** Stop ringing when user opens the app after a Find My Phone alert. */
  public stopFindMyPhone(): void {
    FindMyPhoneHelper.getInstance().stop();
  }

  /** Make the remote device ring (Android FindMyPhonePlugin). */
  public sendFindMyPhone(): void {
    if (!this.isPluginEnabled(PLUGIN_FIND_MY_PHONE)) {
      console.info('[KDE-MVP] sendFindMyPhone: plugin disabled for peer');
      return;
    }
    if (!this.isTlsLive()) {
      console.warn('[KDE-MVP] sendFindMyPhone: TLS not live');
      return;
    }
    const json: string = serializePacket('kdeconnect.findmyphone.request', {} as KdeFindMyPhoneBody);
    this.sendTls(json, (err) => {
      if (err) {
        console.error('[KDE-MVP] findmyphone send failed:', JSON.stringify(err));
      }
    });
  }

  // ── MPRIS ─────────────────────────────────────────────────

  /** Latest MPRIS player state from remote. */
  public getMprisPlayer(): MprisPlayerState | null {
    return this.mprisPlayer;
  }

  public setMprisChangeListener(cb: (player: MprisPlayerState | null) => void): void {
    this.onMprisChange = cb;
  }

  private handleMprisPacket(body: object): void {
    const b = body as Record<string, Object>;
    const player: string = typeof b['player'] === 'string' ? b['player'] as string : '';
    if (player.length === 0) {
      return;
    }
    const now: number = Date.now();
    const prev: MprisPlayerState = this.mprisPlayer ?? {
      player: '', title: '', artist: '', album: '',
      isPlaying: false, canPlay: true, canPause: true,
      canGoNext: true, canGoPrevious: true, canSeek: true,
      volume: 50, length: -1, pos: 0, lastPositionTime: now,
      loopStatus: '', shuffle: false
    };
    const title: string = typeof b['title'] === 'string' ? b['title'] as string : prev.title;
    const artist: string = typeof b['artist'] === 'string' ? b['artist'] as string : prev.artist;
    const album: string = typeof b['album'] === 'string' ? b['album'] as string : prev.album;
    const isPlaying: boolean = typeof b['isPlaying'] === 'boolean' ? b['isPlaying'] as boolean : prev.isPlaying;
    const canPlay: boolean = typeof b['canPlay'] === 'boolean' ? b['canPlay'] as boolean : prev.canPlay;
    const canPause: boolean = typeof b['canPause'] === 'boolean' ? b['canPause'] as boolean : prev.canPause;
    const canGoNext: boolean = typeof b['canGoNext'] === 'boolean' ? b['canGoNext'] as boolean : prev.canGoNext;
    const canGoPrevious: boolean = typeof b['canGoPrevious'] === 'boolean' ? b['canGoPrevious'] as boolean : prev.canGoPrevious;
    const canSeek: boolean = typeof b['canSeek'] === 'boolean' ? b['canSeek'] as boolean : prev.canSeek;
    const volume: number = typeof b['volume'] === 'number' ? b['volume'] as number : prev.volume;
    const length: number = typeof b['length'] === 'number' ? b['length'] as number : prev.length;
    let pos: number = typeof b['pos'] === 'number' ? b['pos'] as number : prev.pos;
    const loopStatus: string = typeof b['loopStatus'] === 'string' ? b['loopStatus'] as string : prev.loopStatus;
    const shuffle: boolean = typeof b['shuffle'] === 'boolean' ? b['shuffle'] as boolean : prev.shuffle;

    this.mprisPlayer = {
      player, title, artist, album, isPlaying,
      canPlay, canPause, canGoNext, canGoPrevious, canSeek,
      volume, length, pos, lastPositionTime: now,
      loopStatus, shuffle
    };

    console.info(`[KDE-MVP] MPRIS: ${title} - ${artist} playing=${isPlaying}`);
    if (this.onMprisChange) {
      this.onMprisChange(this.mprisPlayer);
    }
  }

  private sendMprisCommand(cmd: Record<string, Object>): void {
    if (!this.isPluginEnabled(PLUGIN_MPRIS)) {
      return;
    }
    if (!this.isTlsLive()) {
      return;
    }
    const json: string = serializePacket(PACKET_TYPE_MPRIS_REQUEST, cmd);
    this.sendTls(json, () => {});
  }

  public mprisPlayPause(): void {
    const p = this.mprisPlayer;
    if (!p || p.player.length === 0) {
      return;
    }
    const cmd: Record<string, Object> = { 'player': p.player, 'action': 'PlayPause' };
    this.sendMprisCommand(cmd);
  }

  public mprisPrevious(): void {
    const p = this.mprisPlayer;
    if (!p || p.player.length === 0) {
      return;
    }
    const cmd: Record<string, Object> = { 'player': p.player, 'action': 'Previous' };
    this.sendMprisCommand(cmd);
  }

  public mprisNext(): void {
    const p = this.mprisPlayer;
    if (!p || p.player.length === 0) {
      return;
    }
    const cmd: Record<string, Object> = { 'player': p.player, 'action': 'Next' };
    this.sendMprisCommand(cmd);
  }

  public mprisSetVolume(vol: number): void {
    const p = this.mprisPlayer;
    if (!p || p.player.length === 0) {
      return;
    }
    const cmd: Record<string, Object> = { 'player': p.player, 'setVolume': vol };
    this.sendMprisCommand(cmd);
  }

  public mprisSeek(offset: number): void {
    const p = this.mprisPlayer;
    if (!p || p.player.length === 0) {
      return;
    }
    const cmd: Record<string, Object> = { 'player': p.player, 'Seek': offset };
    this.sendMprisCommand(cmd);
  }

  /** Handle incoming mpris.request (remote controls our media). */
  private handleMprisRequest(body: object): void {
    const b = body as Record<string, Object>;

    // Request player list
    if (b['requestPlayerList'] === true) {
      const resp: Record<string, Object> = {
        'playerList': ['HMConnect']
      };
      this.sendMprisStatus(resp);
      return;
    }

    // Send metadata for a player
    if (b['requestNowPlaying'] === true) {
      this.sendLocalMprisStatus();
      return;
    }

    // Volume control
    if (typeof b['setVolume'] === 'number') {
      const vol: number = b['setVolume'] as number;
      console.info('[KDE-MVP] MPRIS receiver setVolume:', vol);
      this.sendLocalMprisStatus();
      return;
    }

    // Seek
    if (typeof b['SetPosition'] === 'number') {
      console.info('[KDE-MVP] MPRIS receiver SetPosition:', b['SetPosition']);
      return;
    }

    // Action
    const action: string = typeof b['action'] === 'string' ? b['action'] as string : '';
    if (action.length > 0) {
      this.handleMprisAction(action);
    }
  }

  /** Execute media control via local state + AVSession update. */
  private handleMprisAction(action: string): void {
    console.info('[KDE-MVP] MPRIS receiver action:', action);

    // Update local state
    this.fallbackHandleAction(action);

    // Sync AVSession state (so system notification widget shows correct status)
    if (this.mprisSession) {
      const state = this.localPlaying
        ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
      this.mprisSession.setAVPlaybackState({
        state: state
      }).catch(() => {});
    }

    // Control the real foreground audio app (needs MANAGE_MEDIA_RESOURCES_FOR_PUBLIC)
    this.sendToActiveAudioSession(action);
  }

  /**
   * Discover active audio sessions and send commands.
   * Requires ohos.permission.MANAGE_MEDIA_RESOURCES_FOR_PUBLIC (granted for this build).
   */
  private async sendToActiveAudioSession(action: string): Promise<void> {
    try {
      const descriptors: avSession.AVSessionDescriptor[] = await avSession.getAllSessionDescriptors();
      console.info('[KDE-MVP] getAllSessionDescriptors OK, count:', descriptors.length);
      const target = descriptors.find((d: avSession.AVSessionDescriptor) => d.type === 'audio' && d.isActive);
      if (!target) {
        console.info('[KDE-MVP] no active audio session found');
        return;
      }
      console.info('[KDE-MVP] found audio session:', target.sessionTag, target.type);
      const controller = await avSession.createController(target.sessionId);
      const cmdMap: Record<string, avSession.AVControlCommandType> = {
        'Play': 'play',
        'Pause': 'pause',
        'PlayPause': 'play',
        'Next': 'playNext',
        'Previous': 'playPrevious'
      };
      const cmd: avSession.AVControlCommandType | undefined = cmdMap[action];
      if (cmd) {
        await controller.sendControlCommand({ command: cmd });
        console.info('[KDE-MVP] real audio session command OK:', cmd);
      }
    } catch (e) {
      console.warn('[KDE-MVP] getAllSessionDescriptors failed:', JSON.stringify(e));
    }
  }

  private fallbackHandleAction(action: string): void {
    switch (action) {
      case 'Play':
        this.localPlaying = true;
        break;
      case 'Pause':
        this.localPlaying = false;
        break;
      case 'PlayPause':
        this.localPlaying = !this.localPlaying;
        break;
      default:
        this.localPlaying = false;
    }
    this.sendLocalMprisStatus();
  }

  // ── AVSession for media controller identity ───────────────

  /** Only one process-wide AVSession — multi-device must share it. */
  private static mprisOwner: DeviceSession | null = null;

  /** Activate our AVSession so the system treats us as a media controller. */
  public async setupMprisReceiver(ctx: common.UIAbilityContext): Promise<void> {
    if (this.mprisSession) {
      return;
    }
    // Second peer would hit error 6600101 if we create another AVSession
    if (DeviceSession.mprisOwner !== null && DeviceSession.mprisOwner !== this) {
      console.info('[KDE-MVP] setupMprisReceiver skipped — already owned by another session');
      return;
    }
    try {
      console.info('[KDE-MVP] AVSession creating…');
      this.mprisSession = await avSession.createAVSession(ctx, 'HMConnectMpris', 'audio');
      DeviceSession.mprisOwner = this;
      console.info('[KDE-MVP] AVSession created, id:', this.mprisSession.sessionId);

      // Register commands FIRST (docs: register before activate)
      this.mprisSession.on('play', () => {
        console.info('[KDE-MVP] AVSession ★ play');
        this.localPlaying = true;
        this.sendLocalMprisStatus();
      });
      this.mprisSession.on('pause', () => {
        console.info('[KDE-MVP] AVSession ★ pause');
        this.localPlaying = false;
        this.sendLocalMprisStatus();
      });
      this.mprisSession.on('stop', () => {
        console.info('[KDE-MVP] AVSession ★ stop');
        this.localPlaying = false;
        this.sendLocalMprisStatus();
      });
      this.mprisSession.on('playNext', () => {
        console.info('[KDE-MVP] AVSession ★ playNext');
        this.sendLocalMprisStatus();
      });
      this.mprisSession.on('playPrevious', () => {
        console.info('[KDE-MVP] AVSession ★ playPrevious');
        this.sendLocalMprisStatus();
      });
      console.info('[KDE-MVP] AVSession commands registered');

      await this.mprisSession.setAVMetadata({
        assetId: 'hmconnect',
        title: 'HMConnect',
        artist: 'KDE Connect'
      });
      console.info('[KDE-MVP] AVSession metadata set');

      // Activate + get controller
      await this.mprisSession.activate();
      console.info('[KDE-MVP] AVSession activated, getting controller…');
      this.mprisController = await this.mprisSession.getController();
      console.info('[KDE-MVP] AVSession controller obtained');

      await this.mprisSession.setAVPlaybackState({
        state: avSession.PlaybackState.PLAYBACK_STATE_STOP
      });
      console.info('[KDE-MVP] AVSession initial state set to STOP');
      console.info('[KDE-MVP] MPRIS receiver AVSession activated');
    } catch (e) {
      console.warn('[KDE-MVP] setupMprisReceiver failed:', JSON.stringify(e));
      this.mprisSession = null;
      if (DeviceSession.mprisOwner === this) {
        DeviceSession.mprisOwner = null;
      }
    }
  }

  public teardownMprisReceiver(): void {
    this.mprisController = null;
    const s = this.mprisSession;
    this.mprisSession = null;
    if (DeviceSession.mprisOwner === this) {
      DeviceSession.mprisOwner = null;
    }
    if (s) {
      try { s.deactivate(); } catch (_e) {}
      try { s.destroy(); } catch (_e) {}
    }
  }

  /** Send local playback status to remote via kdeconnect.mpris. */
  private sendLocalMprisStatus(): void {
    if (!this.isTlsLive()) {
      return;
    }
    const status: Record<string, Object> = {
      'player': 'HMConnect',
      'title': 'HMConnect',
      'artist': '',
      'album': '',
      'isPlaying': this.localPlaying,
      'canPlay': true,
      'canPause': true,
      'canGoNext': true,
      'canGoPrevious': true,
      'canSeek': false,
      'volume': this.localVolume,
      'length': -1,
      'pos': 0
    };
    this.sendMprisStatus(status);
  }

  private sendMprisStatus(status: Record<string, Object>): void {
    if (!this.isPluginEnabled(PLUGIN_MPRIS)) {
      return;
    }
    const json: string = serializePacket(PACKET_TYPE_MPRIS, status);
    this.sendTls(json, () => {});
  }

  private emit(state: ConnectionState, message: string, extra?: Partial<KdeStatus>): void {
    // Never paint a red error over an already-good session (outbound probe used to do this)
    if (state === 'error' && (this.paired || this.sessionLive)) {
      console.warn(`[KDE-MVP] suppress error while session ok: ${message}`);
      return;
    }
    console.info(`[KDE-MVP] status=${state} ${message}`);
    if (this.statusCallback) {
      let s: KdeStatus = {
        state: state,
        message: message,
        peerName: extra?.peerName ?? this.peerDevice?.deviceName,
        peerDeviceId: extra?.peerDeviceId ?? this.peerDevice?.deviceId,
        lastClipboard: extra?.lastClipboard,
        peerBattery: extra?.peerBattery ?? this.peerBattery ?? undefined
      };
      this.statusCallback(s);
    }
  }

  private async persistTrust(device: KdeDevice): Promise<void> {
    let store = DeviceStore.getInstance();
    let existing = store.get(device.deviceId);
    let row: TrustedDevice = {
      deviceId: device.deviceId,
      deviceName: device.deviceName,
      deviceType: device.deviceType,
      lastIp: device.ip,
      lastTcpPort: device.tcpPort,
      lastSeenAt: Date.now(),
      pairedAt: existing?.pairedAt ?? Date.now()
    };
    await store.upsert(row);
    this.trustedDeviceIds.add(device.deviceId);
  }

  private async removeTrust(deviceId: string): Promise<void> {
    this.trustedDeviceIds.delete(deviceId);
    await DeviceStore.getInstance().remove(deviceId);
    await PluginSettingsStore.getInstance().clearDevice(deviceId);
  }

  /** Peer device id for per-device plugin gates. */
  private pluginDeviceId(): string {
    if (this.boundDeviceId.length > 0) {
      return this.boundDeviceId;
    }
    return this.peerDevice?.deviceId ?? '';
  }

  /** Whether a feature plugin is enabled for this peer (Android isPluginEnabled). */
  public isPluginEnabled(pluginKey: string): boolean {
    return PluginSettingsStore.getInstance().isEnabled(this.pluginDeviceId(), pluginKey);
  }

  private isTrusted(deviceId: string): boolean {
    if (this.trustedDeviceIds.has(deviceId)) {
      return true;
    }
    return DeviceStore.getInstance().isTrusted(deviceId);
  }

  /**
   * User tapped "连接": try reverse path first (UDP poke → wait for PC to connect back).
   * If the peer does not connect back within 5 s, initiate an outbound TLS connection.
   */
  public connectToDevice(device: KdeDevice): void {
    this.peerDevice = device;
    this.boundDeviceId = device.deviceId;
    PluginSettingsStore.getInstance().ensureDeviceLoaded(device.deviceId).catch(() => {
    });
    // Keep trust if already paired with this device; only clear live session flags
    if (!this.isTrusted(device.deviceId)) {
      this.paired = false;
    }
    if (this.sessionLive && this.paired && this.peerDevice?.deviceId === device.deviceId) {
      this.emit('paired', `已与 ${device.deviceName} 配对，无需重复连接`, {
        peerName: device.deviceName
      });
      return;
    }
    this.sessionLive = false;
    this.sessionGen += 1;
    this.pairRequestSentForGen = -1;
    this.handlingIncoming = false;
    this.pokeOutboundIdentity(device);

    // Start a background race: wait 5 s for reverse-path incoming, then try outbound.
    const gen: number = this.sessionGen;
    const deviceSnapshot: KdeDevice = {
      deviceId: device.deviceId,
      deviceName: device.deviceName,
      ip: device.ip,
      tcpPort: device.tcpPort,
      protocolVersion: device.protocolVersion,
      deviceType: device.deviceType
    };
    this.emit(
      'connecting',
      this.isTrusted(device.deviceId)
        ? `已通知 ${device.deviceName} 重新连入…`
        : `已通知 ${device.deviceName}，等待电脑连入并确认配对…`,
      { peerName: device.deviceName, peerDeviceId: device.deviceId }
    );

    setTimeout(() => {
      if (gen !== this.sessionGen) {
        return;
      }
      if (this.sessionLive) {
        return; // Reverse path succeeded
      }
      console.info('[KDE-MVP] Reverse path timeout, trying outbound…');
      this.connectOutbound(deviceSnapshot, gen);
    }, 5000);
  }

  /** Fire-and-forget: send plain identity then close. Never upgrades TLS / never emits error. */
  private pokeOutboundIdentity(device: KdeDevice): void {
    let tcp = socket.constructTCPSocketInstance();
    tcp.connect({
      address: { address: device.ip, port: device.tcpPort, family: 1 },
      timeout: 5000
    }, (err) => {
      if (err) {
        console.info('[KDE-MVP] outbound poke skipped (reverse path is primary)');
        return;
      }
      let identity = this.buildIdentityPacket(device.deviceId, device.protocolVersion);
      tcp.send({ data: identity }, () => {
        try {
          tcp.close();
        } catch (_e) {
          // ignore
        }
      });
    });
  }

  /**
   * Outbound connection: we initiate TCP to the peer, bridge through
   * loopback pair + TLSSocketServer so we can be the TLS server.
   *
   * Flow:
   *   peerSock (TCP → peer) ↔ bridge loopback ↔ TLSSocketServer.accept
   *   After TLS handshake, the TLSSocketConnection is our secure channel.
   *
   * Matches Android udpPacketReceived → identityPacketReceived(Remotely, clientMode=false).
   */
  private async connectOutbound(device: KdeDevice, gen: number): Promise<void> {
    if (gen !== this.sessionGen) {
      return;
    }
    if (this.outboundActive) {
      return;
    }

    this.outboundActive = true;
    this.outboundTargetIp = device.ip;
    this.handlingIncoming = true;
    this.peerDevice = device;

    this.emit('connecting', `正在主动连接 ${device.deviceName}…`, {
      peerName: device.deviceName,
      peerDeviceId: device.deviceId
    });

    let bridgePort: number = 0;
    let tlsServerPort: number = 0;
    let peerSock: socket.TCPSocket | null = null;
    let bridgeServer: socket.TCPSocketServer | null = null;
    let tlsServer: socket.TLSSocketServer | null = null;

    try {
      // ── 1. Open loopback bridge server ──
      for (let p = 38200; p <= 38220; p++) {
        const srv: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
        try {
          await srv.listen({ address: '127.0.0.1', port: p, family: 1 });
          bridgePort = p;
          bridgeServer = srv;
          break;
        } catch (_e) {
          try { srv.close(); } catch (_ignored) {}
        }
      }
      if (!bridgeServer) {
        throw new Error('No free bridge port');
      }
      this.outBridgeServer = bridgeServer;

      // ── 2. Open TLSSocketServer on loopback ──
      for (let p = 38300; p <= 38320; p++) {
        const srv: socket.TLSSocketServer = socket.constructTLSSocketServerInstance();
        try {
          await srv.listen({
            address: { address: '127.0.0.1', port: p, family: 1 },
            secureOptions: {
              cert: this.certPem,
              key: this.keyPem,
              protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13]
            }
          });
          tlsServerPort = p;
          tlsServer = srv;
          break;
        } catch (_e) {
          try { srv.close(); } catch (_ignored) {}
        }
      }
      if (!tlsServer) {
        throw new Error('No free outbound TLS port');
      }
      this.outTlsServer = tlsServer;

      // ── 3. Connect to peer ──
      peerSock = socket.constructTCPSocketInstance();
      await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
        peerSock!.connect({
          address: { address: device.ip, port: device.tcpPort, family: 1 },
          timeout: 5000
        }, (err: Object) => {
          if (err) {
            reject(new Error('TCP connect failed'));
          } else {
            resolve();
          }
        });
      });
      this.outPeerSock = peerSock;

      console.info(`[KDE-MVP] Outbound TCP connected to ${device.ip}:${device.tcpPort}`);

      // ── 4. Wire up bridge components ──
      const bridgeClient: socket.TCPSocket = socket.constructTCPSocketInstance();
      await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
        bridgeClient.connect({
          address: { address: '127.0.0.1', port: bridgePort, family: 1 },
          timeout: 3000
        }, (err: Object) => {
          if (err) {
            reject(new Error('Bridge client failed'));
          } else {
            resolve();
          }
        });
      });
      this.outBridgeClient = bridgeClient;

      const bridgeAccepted: socket.TCPSocketConnection = await new Promise<socket.TCPSocketConnection>(
        (resolve: (v: socket.TCPSocketConnection) => void, reject: (e: Error) => void) => {
          const t: number = setTimeout(() => reject(new Error('Bridge accept timeout')), 5000) as number;
          bridgeServer!.on('connect', (accepted: socket.TCPSocketConnection) => {
            clearTimeout(t);
            resolve(accepted);
          });
        });
      this.outBridgeAccepted = bridgeAccepted;

      const tlsFeeder: socket.TCPSocket = socket.constructTCPSocketInstance();
      await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
        tlsFeeder.connect({
          address: { address: '127.0.0.1', port: tlsServerPort, family: 1 },
          timeout: 3000
        }, (err: Object) => {
          if (err) {
            reject(new Error('TLS feeder failed'));
          } else {
            resolve();
          }
        });
      });
      this.outTlsFeeder = tlsFeeder;

      // ── 5. Bidirectional forwarding ──
      // peerSock ↔ bridgeClient
      peerSock.on('message', (v: socket.SocketMessageInfo) => {
        bridgeClient.send({ data: v.message }, (_e: Object) => {});
      });
      bridgeClient.on('message', (v: socket.SocketMessageInfo) => {
        peerSock!.send({ data: v.message }, (_e: Object) => {});
      });

      // bridgeAccepted ↔ tlsFeeder
      bridgeAccepted.on('message', (v: socket.SocketMessageInfo) => {
        tlsFeeder.send({ data: v.message }, (_e: Object) => {});
      });
      tlsFeeder.on('message', (v: socket.SocketMessageInfo) => {
        bridgeAccepted.send({ data: v.message }, (_e: Object) => {});
      });

      // ── 6. Send identity to peer (plain text, through the bridge) ──
      const identity: string = this.buildIdentityPacket(device.deviceId, device.protocolVersion);
      peerSock.send({ data: identity }, (_e: Object) => {});

      console.info('[KDE-MVP] Outbound identity sent, waiting for TLS handshake…');
      this.emit('tls_handshake', `正在与 ${device.deviceName} 建立加密通道…`, {
        peerName: device.deviceName,
        peerDeviceId: device.deviceId
      });

      // ── 7. Wait for TLS handshake via TLSSocketServer ──
      const tlsConn: socket.TLSSocketConnection = await new Promise<socket.TLSSocketConnection>(
        (resolve: (v: socket.TLSSocketConnection) => void, reject: (e: Error) => void) => {
          const t: number = setTimeout(() => reject(new Error('TLS handshake timeout')), 15000) as number;
          tlsServer!.on('connect', (conn: socket.TLSSocketConnection) => {
            clearTimeout(t);
            resolve(conn);
          });
        });

      if (gen !== this.sessionGen) {
        try { tlsConn.close(); } catch (_e) {}
        this.cleanOutboundState();
        return;
      }

      this.outTlsConn = tlsConn;
      console.info('[KDE-MVP] Outbound TLS handshake complete');

      // Wire message handler before v8 secure identity exchange
      tlsConn.on('message', (v: socket.SocketMessageInfo) => {
        if (gen !== this.sessionGen) {
          return;
        }
        this.onTlsData(v.message);
      });

      tlsConn.on('close', () => {
        console.info('[KDE-MVP] Outbound TLS connection closed');
        if (this.outboundActive) {
          this.sessionLive = false;
          this.outboundActive = false;
          this.peerBattery = null;
          this.stopBatteryReporting();
          this.cleanOutboundState();
          this.notifySessionChange();
          if (!this.paired) {
            this.emit('error', '连接已断开，可再次点连接');
          } else {
            this.emit('paired', '链路断开，等待电脑重连…', {
              peerName: this.peerDevice?.deviceName
            });
          }
        }
      });

      tlsConn.on('error', (err: Object) => {
        console.error('[KDE-MVP] Outbound TLS error:', JSON.stringify(err));
        if (gen === this.sessionGen && !this.paired) {
          this.emit('error', '加密通道异常');
        }
      });

      // ── Session live + protocol v8 secure identity + services ──
      this.sessionLive = true;
      this.handlingIncoming = false;
      this.notifySessionChange();
      await this.afterTlsReady(gen, true);

    } catch (e) {
      console.error('[KDE-MVP] Outbound connection failed:', JSON.stringify(e));
      if (gen === this.sessionGen) {
        this.handlingIncoming = false;
        this.emit('error', `无法连接 ${device.deviceName}`);
      }
      this.cleanOutboundState();
    }
  }

  /** Release all outbound resources without touching reverse-path state. */
  private cleanOutboundState(): void {
    try { this.outTlsConn?.close(); } catch (_e) {}
    this.outTlsConn = null;
    try { this.outTlsFeeder?.close(); } catch (_e) {}
    this.outTlsFeeder = null;
    try { this.outTlsServer?.close(); } catch (_e) {}
    this.outTlsServer = null;
    try { this.outBridgeAccepted?.close(); } catch (_e) {}
    this.outBridgeAccepted = null;
    try { this.outBridgeClient?.close(); } catch (_e) {}
    this.outBridgeClient = null;
    try { this.outBridgeServer?.close(); } catch (_e) {}
    this.outBridgeServer = null;
    try { this.outPeerSock?.close(); } catch (_e) {}
    this.outPeerSock = null;
    this.outboundActive = false;
    this.outboundTargetIp = '';
  }

  private buildIdentityPacket(targetId?: string, targetProto?: number): string {
    let body: KdeIdentityBody = {
      deviceId: MY_DEVICE_ID,
      deviceName: this.myDeviceName,
      deviceType: 'phone',
      protocolVersion: KDE_PROTOCOL_VERSION,
      tcpPort: this.listenPort,
      incomingCapabilities: INCOMING_CAPABILITIES,
      outgoingCapabilities: OUTGOING_CAPABILITIES
    };
    if (targetId) {
      body.targetDeviceId = targetId;
      body.targetProtocolVersion = targetProto ?? KDE_PROTOCOL_VERSION;
    }
    return serializePacket('kdeconnect.identity', body);
  }

  /** Hub routes a new TCP client here after rate-limit checks. */
  public async acceptIncomingConnection(client: socket.TCPSocketConnection): Promise<void> {
    let remoteAddr: string = '';
    try {
      remoteAddr = (await client.getRemoteAddress()).address ?? '';
    } catch (e) {
      console.warn('[KDE-MVP] Failed to get remote address:', JSON.stringify(e));
    }
    const now: number = Date.now();

    // Outbound in progress — accept reverse connection, cancel outbound
    if (this.outboundActive) {
      if (remoteAddr.length > 0 && remoteAddr === this.outboundTargetIp) {
        console.info('[KDE-MVP] Reverse while outbound — accept, cancel outbound');
        this.cleanOutboundState();
      }
    }

    // Same session object reconnect: soft-reset sockets, keep trust/paired
    const isReconnect: boolean = this.sessionLive || this.handlingIncoming;
    if (isReconnect) {
      console.info(
        `[KDE-MVP] Soft-reset for reconnect (live=${this.sessionLive}, handshaking=${this.handlingIncoming})`
      );
      this.disposeQuietly();
    } else {
      // Rate limit only for brand-new handshakes (hub also rate-limits)
      const lastIp: number | undefined = this.lastConnTimeByIp[remoteAddr];
      if (lastIp !== undefined && (lastIp + DeviceSession.CONN_RATE_MS > now)) {
        console.info('[KDE-MVP] Rate-limited duplicate TCP:', remoteAddr);
        try {
          client.close();
        } catch (_e) {
        }
        return;
      }
    }
    this.lastConnTimeByIp[remoteAddr] = now;

    this.handlingIncoming = true;
    // New reverse session — invalidate any previous TLS callbacks
    this.sessionGen += 1;
    let gen: number = this.sessionGen;
    // Do NOT clear trusted pairing; only clear live channel until TLS succeeds again
    this.sessionLive = false;
    this.pairRequestSentForGen = -1;
    this.notifySessionChange();

    this.bridgeRemote = client;
    this.emit('connecting', '电脑已连入，协商加密通道…', {
      peerName: this.peerDevice?.deviceName,
      peerDeviceId: this.peerDevice?.deviceId
    });

    let pendingBytes: number[] = [];
    let identityDone: boolean = false;

    client.on('message', (value: socket.SocketMessageInfo) => {
      if (identityDone) {
        this.forwardToLocal(value.message);
        return;
      }

      try {
        let chunk = new Uint8Array(value.message);
        for (let i = 0; i < chunk.length; i++) {
          pendingBytes.push(chunk[i]);
        }

        let nl: number = pendingBytes.indexOf(0x0A); // '\n'
        if (nl < 0) {
          return;
        }

        let lineBytes = new Uint8Array(pendingBytes.slice(0, nl));
        let restBytes = new Uint8Array(pendingBytes.slice(nl + 1));
        pendingBytes = [];

        let line: string = utf8Decode(lineBytes);
        let packet = parsePacketLine(line);
        if (!packet || packet.type !== 'kdeconnect.identity') {
          console.warn('[KDE-MVP] Expected identity, got:', line.substring(0, 120));
          return;
        }
        identityDone = true;
        let body = packet.body as KdeIdentityBody;
        console.info(`[KDE-MVP] Got plain identity from ${body.deviceId} / ${body.deviceName}`);

        // Always bind peer to the identity of the live reverse connection so list
        // sessionActive matches detail (deviceId must equal the TLS peer).
        this.peerDevice = {
          deviceId: body.deviceId,
          deviceName: sanitizeDeviceName(body.deviceName ?? this.peerDevice?.deviceName ?? 'PC'),
          ip: value.remoteInfo.address,
          tcpPort: body.tcpPort ?? this.peerDevice?.tcpPort ?? 1716,
          protocolVersion: body.protocolVersion ?? this.peerDevice?.protocolVersion ?? KDE_PROTOCOL_VERSION,
          deviceType: body.deviceType ?? this.peerDevice?.deviceType ?? 'desktop',
          incomingCapabilities: body.incomingCapabilities
            ? body.incomingCapabilities.slice()
            : this.peerDevice?.incomingCapabilities,
          outgoingCapabilities: body.outgoingCapabilities
            ? body.outgoingCapabilities.slice()
            : this.peerDevice?.outgoingCapabilities
        };
        this.applyPeerCapabilities(body);
        this.boundDeviceId = body.deviceId;
        PluginSettingsStore.getInstance().ensureDeviceLoaded(body.deviceId).catch(() => {
        });
        this.notifySessionChange();
        this.emit('connecting', `正在与 ${this.peerDevice.deviceName} 协商加密…`, {
          peerName: this.peerDevice.deviceName,
          peerDeviceId: this.peerDevice.deviceId
        });

        this.startReverseTlsBridge(
          client,
          this.peerDevice,
          restBytes.byteLength > 0 ? restBytes : null,
          gen
        );
      } catch (e) {
        console.error('[KDE-MVP] Incoming identity parse error:', JSON.stringify(e));
      }
    });

    client.on('close', () => {
      console.info('[KDE-MVP] Remote TCP closed');
      if (gen === this.sessionGen) {
        this.sessionLive = false;
        this.handlingIncoming = false;
        this.peerBattery = null;
        this.stopBatteryReporting();
        this.notifySessionChange();
        if (!this.paired) {
          this.emit('error', '连接已断开，可再次点连接');
        } else {
          // Trusted: wait for PC to reconnect without user action / without re-pair spam
          this.emit('paired', '链路断开，等待电脑重连…', {
            peerName: this.peerDevice?.deviceName
          });
        }
      }
    });
  }

  /**
   * Bridge remote accepted connection <-> localhost TCP pair,
   * then TLS-client-upgrade the local TCPSocket.
   *
   * PC is TLS server on reverse path; we are TLS client.
   */
  private startReverseTlsBridge(
    remote: socket.TCPSocketConnection,
    peer: KdeDevice,
    earlyTlsBytes: Uint8Array | null,
    gen: number
  ): void {
    this.emit('tls_handshake', '正在建立加密通道，请在电脑上确认配对…');
    this.setupBridgeWithPort(remote, peer, earlyTlsBytes, this.bridgeBasePort, gen);
  }

  private setupBridgeWithPort(
    remote: socket.TCPSocketConnection,
    peer: KdeDevice,
    earlyTlsBytes: Uint8Array | null,
    localPort: number,
    gen: number
  ): void {
    if (gen !== this.sessionGen) {
      return;
    }
    if (this.bridgeLocalServer) {
      try {
        this.bridgeLocalServer.close();
      } catch (_e) {
        // ignore
      }
    }
    this.bridgeLocalServer = socket.constructTCPSocketServerInstance();
    let bridgeReady: boolean = false;

    this.bridgeLocalServer.listen({ address: '127.0.0.1', port: localPort, family: 1 }, (err) => {
      if (gen !== this.sessionGen) {
        return;
      }
      if (err) {
        if (localPort < 37600) {
          this.setupBridgeWithPort(remote, peer, earlyTlsBytes, localPort + 1, gen);
        } else {
          this.emit('error', '本地代理端口占用');
        }
        return;
      }

      this.bridgeLocalServer?.on('connect', (localAccepted: socket.TCPSocketConnection) => {
        if (gen !== this.sessionGen) {
          return;
        }
        this.bridgeLocalAccepted = localAccepted;
        console.info('[KDE-MVP] Local bridge leg connected');

        // Flush any early TLS bytes that arrived before the bridge was ready
        if (this.pendingBridgeBytes.length > 0) {
          console.info('[KDE-MVP] Flushing', this.pendingBridgeBytes.length, 'pending bridge bytes');
          for (const ab of this.pendingBridgeBytes) {
            localAccepted.send({ data: ab }, () => {});
          }
          this.pendingBridgeBytes = [];
        }

        localAccepted.on('message', (value: socket.SocketMessageInfo) => {
          remote.send({ data: value.message }, (e) => {
            if (e) {
              console.error('[KDE-MVP] Bridge remote send failed:', JSON.stringify(e));
            }
          });
        });

        if (earlyTlsBytes && earlyTlsBytes.byteLength > 0) {
          let ab = new ArrayBuffer(earlyTlsBytes.byteLength);
          let view = new Uint8Array(ab);
          view.set(earlyTlsBytes);
          localAccepted.send({ data: ab }, () => {
          });
        }

        if (this.bridgeLocalClient && !bridgeReady) {
          bridgeReady = true;
          console.info('[KDE-MVP] Bridge ready, starting TLS client…');
          // Defer TLS to next tick so bridge data wiring is complete
          setTimeout(() => {
            this.upgradeClientTls(this.bridgeLocalClient!, peer, gen);
          }, 50);
        }
      });

      this.bridgeLocalClient = socket.constructTCPSocketInstance();
      this.bridgeLocalClient.connect({
        address: { address: '127.0.0.1', port: localPort, family: 1 },
        timeout: 3000
      }, (connErr) => {
        if (gen !== this.sessionGen) {
          return;
        }
        if (connErr) {
          console.error('[KDE-MVP] Local bridge client connect failed:', JSON.stringify(connErr));
          this.handlingIncoming = false;
          this.emit('error', '本地代理连接失败');
          return;
        }
        console.info('[KDE-MVP] Local bridge client TCP connected');
        if (this.bridgeLocalAccepted && !bridgeReady) {
          bridgeReady = true;
          console.info('[KDE-MVP] Bridge ready, starting TLS client…');
          setTimeout(() => {
            this.upgradeClientTls(this.bridgeLocalClient!, peer, gen);
          }, 50);
        }
      });
    });
  }

  private forwardToLocal(message: ArrayBuffer): void {
    if (this.bridgeLocalAccepted) {
      this.bridgeLocalAccepted.send({ data: message }, (e) => {
        if (e) {
          console.error('[KDE-MVP] Bridge local send failed:', JSON.stringify(e));
        }
      });
    } else {
      // Bridge not ready yet — buffer for later flush
      this.pendingBridgeBytes.push(message);
    }
  }

  private upgradeClientTls(tcp: socket.TCPSocket, peer: KdeDevice, gen: number): void {
    if (gen !== this.sessionGen) {
      return;
    }
    this.activeTlsGen = gen;
    try {
      this.tlsSocket = socket.constructTLSSocketInstance(tcp);
    } catch (e) {
      console.error('[KDE-MVP] constructTLSSocketInstance failed:', JSON.stringify(e));
      this.handlingIncoming = false;
      this.emit('error', '创建加密通道失败');
      return;
    }

    this.tlsSocket.on('message', (value: socket.SocketMessageInfo) => {
      if (gen !== this.sessionGen) {
        return;
      }
      this.onTlsData(value.message);
    });

    this.tlsSocket.on('error', (err) => {
      console.error('[KDE-MVP] TLS error:', JSON.stringify(err));
      if (gen === this.sessionGen) {
        this.handlingIncoming = false;
        if (!this.paired && !this.sessionLive) {
          this.emit('error', '加密协商失败，请重试连接');
        }
      }
    });

    let secure: socket.TLSSecureOptions = {
      protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13]
    };
    if (this.certPem.length > 0 && this.keyPem.length > 0) {
      secure.cert = this.certPem;
      secure.key = this.keyPem;
    }

    // Peer address is only for TLS metadata; actual bytes go through the loopback bridge
    let tlsOpts: socket.TLSConnectOptions = {
      address: {
        address: '127.0.0.1',
        port: peer.tcpPort,
        family: 1
      },
      secureOptions: secure,
      skipRemoteValidation: true
    };

    try {
      this.tlsSocket.connect(tlsOpts, (err) => {
        if (gen !== this.sessionGen) {
          return;
        }
        if (err) {
          console.error('[KDE-MVP] TLS handshake failed:', JSON.stringify(err));
          this.handlingIncoming = false;
          if (!this.paired && !this.sessionLive) {
            this.emit('error', '加密协商失败，请重试连接');
          }
          return;
        }
        console.info('[KDE-MVP] TLS handshake OK');
        this.sessionLive = true;
        this.handlingIncoming = false;
        this.notifySessionChange();
        // Protocol v8 secure identity + battery / certs / pairing UI
        this.afterTlsReady(gen, false).catch((e: Error) => {
          console.error('[KDE-MVP] afterTlsReady failed:', e.message);
        });
      });
    } catch (e) {
      console.error('[KDE-MVP] TLS connect threw:', JSON.stringify(e));
      this.handlingIncoming = false;
      if (gen === this.sessionGen && !this.paired && !this.sessionLive) {
        this.emit('error', '加密协商异常，请重试连接');
      }
    }
  }

  private onTlsData(buf: ArrayBuffer): void {
    try {
      this.lineBuffer += utf8Decode(new Uint8Array(buf));
      let parts: string[] = this.lineBuffer.split('\n');
      this.lineBuffer = parts.pop() ?? '';
      for (let i = 0; i < parts.length; i++) {
        let packet = parsePacketLine(parts[i]);
        if (!packet) {
          continue;
        }
        this.dispatchPacket(packet);
      }
    } catch (e) {
      console.error('[KDE-MVP] TLS data parse error:', JSON.stringify(e));
    }
  }

  private dispatchPacket(packet: KdePacket<object>): void {
    const type: string = packet.type;
    const body: object = packet.body;
    console.info(`[KDE-MVP] Packet: ${type}`);
    if (type === 'kdeconnect.pair') {
      let pairBody = body as KdePairBody;
      if (pairBody.pair) {
        // Already paired/trusted → re-accept silently to avoid unpair loops on reconnect
        if (this.paired || (this.peerDevice !== null && this.isTrusted(this.peerDevice.deviceId))) {
          this.paired = true;
          this.clearPairTimer();
          this.pairRequestSentForGen = -1;
          this.pairRequestedByPeer = false;
          if (this.isTlsLive()) {
            const reAccept: string = serializePacket('kdeconnect.pair', { pair: true } as KdePairBody);
            this.sendTls(reAccept, () => {});
          } else {
            this.pendingPairAccept = true;
          }
          return;
        }

        const weRequested: boolean = this.pairRequestSentForGen >= 0;

        if (weRequested) {
          // Our outgoing pair request was accepted (Android: pairingDone when state==Requested)
          this.clearPairTimer();
          this.pairRequestSentForGen = -1;
          this.pairRequestedByPeer = false;
          this.paired = true;
          if (this.peerDevice) {
            this.trustedDeviceIds.add(this.peerDevice.deviceId);
            this.persistTrust(this.peerDevice).catch((e: Error) => {
              console.error('[KDE-MVP] persistTrust failed:', e.message);
            });
          }
          this.notifySessionChange();
          this.emit('paired', '配对成功！可同步剪贴板', {
            peerName: this.peerDevice?.deviceName,
            peerDeviceId: this.peerDevice?.deviceId
          });
        } else if (this.pairRequestedByPeer) {
          // Android: ignore second pairing request before timeout
          console.warn('[KDE-MVP] Ignoring second pairing request before timeout');
        } else {
          // Peer requested pairing → RequestedByPeer (Android: 25s timeout)
          // Protocol v8: require timestamp and clock skew ≤ 30 min
          const peerProto = this.peerDevice?.protocolVersion ?? KDE_PROTOCOL_VERSION;
          if (peerProto >= 8) {
            if (typeof pairBody.timestamp !== 'number' || pairBody.timestamp <= 0) {
              console.error('[KDE-MVP] v8 pair request missing timestamp — reject');
              this.emit('error', '配对失败：缺少时间戳', {
                peerName: this.peerDevice?.deviceName,
                peerDeviceId: this.peerDevice?.deviceId
              });
              return;
            }
            const nowSec = Math.floor(Date.now() / 1000);
            const skew = Math.abs(pairBody.timestamp - nowSec);
            if (skew > PAIR_TIMESTAMP_MAX_DIFF_SEC) {
              console.error(`[KDE-MVP] v8 pair clock skew ${skew}s > ${PAIR_TIMESTAMP_MAX_DIFF_SEC}s`);
              this.emit('error', '配对失败：双方设备时间相差过大', {
                peerName: this.peerDevice?.deviceName,
                peerDeviceId: this.peerDevice?.deviceId
              });
              return;
            }
            this.pairingTimestamp = pairBody.timestamp;
            this.recomputeVerificationKey().catch(() => {
            });
          } else if (typeof pairBody.timestamp === 'number' && pairBody.timestamp > 0) {
            this.pairingTimestamp = pairBody.timestamp;
            this.recomputeVerificationKey().catch(() => {
            });
          }
          this.pairRequestedByPeer = true;
          this.pairRequestSentForGen = -1;
          this.startPairTimer(
            DeviceSession.PAIR_PEER_TIMEOUT_MS,
            '配对超时，请重试'
          );
          this.notifySessionChange();
          console.info('[KDE-MVP] Peer requested pairing, showing notification');
          AppNotifier.getInstance().notifyPairRequest(
            this.peerDevice?.deviceName ?? '未知设备',
            this.peerDevice?.deviceId ?? ''
          );
        }
      } else {
        // pair:false — match Android PairingHandler.packetReceived
        this.clearPairTimer();
        const wasPaired: boolean = this.paired;
        const wasRequesting: boolean = this.pairRequestSentForGen >= 0 || this.pairRequestedByPeer;
        this.paired = false;
        this.pairRequestSentForGen = -1;
        this.pairRequestedByPeer = false;
        this.notifySessionChange();
        if (this.peerDevice) {
          this.removeTrust(this.peerDevice.deviceId).catch(() => {});
          if (wasRequesting && !wasPaired) {
            this.emit('error', '配对被对方取消', {
              peerName: this.peerDevice.deviceName,
              peerDeviceId: this.peerDevice.deviceId
            });
          } else if (wasPaired) {
            this.emit('connected', '设备已取消配对', {
              peerName: this.peerDevice.deviceName,
              peerDeviceId: this.peerDevice.deviceId
            });
            console.info('[KDE-MVP] Peer unpaired us, trust cleared, disconnecting');
            this.disconnect();
          }
        }
      }
      return;
    }

    if (type === 'kdeconnect.identity') {
      // Protocol v8 encrypted identity (Android secureIdentityPacket)
      this.handleSecureIdentityPacket(body as KdeIdentityBody);
      return;
    }

    // Per-device plugin gate (Android: only loaded plugins receive packets)
    const gatedPlugin = pluginKeyForPacketType(type);
    if (gatedPlugin !== null && !this.isPluginEnabled(gatedPlugin)) {
      console.info(`[KDE-MVP] drop ${type}: plugin ${gatedPlugin} disabled`);
      return;
    }

    if (type === PACKET_TYPE_MPRIS) {
      this.handleMprisPacket(body);
      return;
    }

    if (type === PACKET_TYPE_MPRIS_REQUEST) {
      this.handleMprisRequest(body);
      return;
    }

    if (type === 'kdeconnect.clipboard' || type === 'kdeconnect.clipboard.connect') {
      let clip = body as KdeClipboardBody;
      if (clip && clip.content !== undefined && clip.content !== null) {
        this.writeLocalClipboard(String(clip.content));
      }
      return;
    }

    if (type === 'kdeconnect.ping') {
      let ping = body as KdePingBody;
      let peerName = this.peerDevice?.deviceName ?? '';
      let msg = ping.message ?? '';
      console.info(`[KDE-MVP] Ping from ${peerName}: ${msg}`);
      // System notification is the primary UX for inbound ping
      AppNotifier.getInstance().notifyPing(peerName, msg).catch((e: Error) => {
        console.error('[KDE-MVP] Ping notify failed:', e.message);
      });
      this.emit(this.paired ? 'paired' : 'connected',
        `收到 Ping${msg.length > 0 ? ': ' + msg : ''}`,
        { peerName: peerName, peerDeviceId: this.peerDevice?.deviceId });
      return;
    }

    if (type === 'kdeconnect.battery') {
      let bat = body as KdeBatteryBody;
      if (bat && typeof bat.currentCharge === 'number') {
        let charge = Math.round(bat.currentCharge);
        if (charge < 0) {
          charge = 0;
        }
        if (charge > 100) {
          charge = 100;
        }
        this.peerBattery = {
          currentCharge: charge,
          isCharging: bat.isCharging === true,
          thresholdEvent: typeof bat.thresholdEvent === 'number' ? bat.thresholdEvent : 0
        };
        console.info(
          `[KDE-MVP] Peer battery: ${charge}% charging=${this.peerBattery.isCharging}`
        );
        // Refresh device list (battery label) without clobbering the status banner text
        this.notifySessionChange();
      }
      return;
    }

    if (type === 'kdeconnect.findmyphone.request') {
      let peerName = this.peerDevice?.deviceName ?? '电脑';
      console.info(`[KDE-MVP] Find My Phone from ${peerName}`);
      FindMyPhoneHelper.getInstance().start(peerName).catch((e: Error) => {
        console.error('[KDE-MVP] FindMyPhone start failed:', e.message);
      });
      this.emit(this.paired ? 'paired' : 'connected',
        `${peerName} 正在找这台设备…`,
        { peerName: peerName, peerDeviceId: this.peerDevice?.deviceId });
      return;
    }

    if (type === PACKET_TYPE_SHARE_REQUEST) {
      this.handleIncomingShareRequest(packet);
      return;
    }
  }

  /**
   * Receive a file from the peer — matches Android LanLink.receivedNetworkPacket +
   * SharePlugin.receiveFile / CompositeReceiveFileJob.
   *
   * Flow: connect TLS client to peer's payload port → read bytes → save to local file.
   */
  private async handleIncomingShareRequest(packet: KdePacket<object>): Promise<void> {
    const body: KdeShareRequestBody = packet.body as KdeShareRequestBody;
    const filename: string = body.filename ?? `received_${Date.now()}`;
    const totalPayloadSize: number = body.totalPayloadSize;
    const payloadSize: number = packet.payloadSize ?? totalPayloadSize;

    if (!packet.payloadTransferInfo || !packet.payloadTransferInfo.port) {
      console.error('[KDE-MVP] share.request missing payloadTransferInfo.port');
      return;
    }
    if (!this.peerDevice) {
      console.error('[KDE-MVP] share.request but no peer device');
      return;
    }
    if (!this.context) {
      console.error('[KDE-MVP] share.request but no context for file save');
      return;
    }

    const payloadPort: number = packet.payloadTransferInfo.port;
    const peerIp: string = this.peerDevice.ip;
    console.info(`[KDE-MVP] Receiving file "${filename}" (${payloadSize} bytes) from ${peerIp}:${payloadPort}`);

    let tcp: socket.TCPSocket | null = null;
    let tls: socket.TLSSocket | null = null;
    let outFile: fileIo.File | null = null;

    try {
      // 1. Connect plain TCP to sender's payload port
      tcp = socket.constructTCPSocketInstance();
      await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
        tcp!.connect({
          address: { address: peerIp, port: payloadPort, family: 1 },
          timeout: 10000
        }, (err: Object) => {
          if (err) {
            reject(new Error('Payload TCP connect failed'));
          } else {
            resolve();
          }
        });
      });

      // 2. Upgrade to TLS client (matches Android: clientMode=true)
      tls = socket.constructTLSSocketInstance(tcp);
      const secureOpts: socket.TLSSecureOptions = {
        protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13]
      };
      if (this.certPem.length > 0 && this.keyPem.length > 0) {
        secureOpts.cert = this.certPem;
        secureOpts.key = this.keyPem;
      }

      // Register recv handlers BEFORE connect — sender starts streaming right after handshake
      const chunks: Uint8Array[] = [];
      let totalRead: number = 0;
      let recvResolve: (() => void) | null = null;
      let recvReject: ((e: Error) => void) | null = null;
      let recvTimer: number = -1;

      tls.on('message', (v: socket.SocketMessageInfo) => {
        const srcLen: number = v.message.byteLength;
        if (srcLen === 0) {
          return;
        }
        const src: Uint8Array = new Uint8Array(v.message);
        const copy: Uint8Array = new Uint8Array(srcLen);
        copy.set(src);
        chunks.push(copy);
        totalRead += srcLen;
        if (totalRead >= payloadSize && recvResolve) {
          clearTimeout(recvTimer);
          recvResolve();
        }
      });

      tls.on('close', () => {
        clearTimeout(recvTimer);
        if (totalRead >= payloadSize) {
          recvResolve?.();
        } else {
          setTimeout(() => {
            if (totalRead < payloadSize) {
              recvReject?.(new Error(`Payload closed early: got ${totalRead}/${payloadSize}`));
            } else {
              recvResolve?.();
            }
          }, 200);
        }
      });

      tls.on('error', (_err: Object) => {
        clearTimeout(recvTimer);
        recvReject?.(new Error('Payload TLS error'));
      });

      await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
        tls!.connect({
          address: { address: peerIp, port: payloadPort, family: 1 },
          secureOptions: secureOpts,
          skipRemoteValidation: true
        }, (err: Object) => {
          if (err) {
            reject(new Error('Payload TLS handshake failed'));
          } else {
            resolve();
          }
        });
      });

      console.info(`[KDE-MVP] Payload TLS connected, reading ${payloadSize} bytes…`);

      // 3. Save received bytes to temp file first
      const safeName: string = filename.replace(/[\\\/:*?"<>|]/g, '_');
      const tmpDir: string = `${this.context!.cacheDir}`;
      const tmpPath: string = `${tmpDir}/${safeName}`;
      outFile = fileIo.openSync(tmpPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY |
        fileIo.OpenMode.TRUNC);

      // 4. Wait for all payload bytes (handlers already registered)
      await new Promise<void>((resolve: () => void, reject: (e: Error) => void) => {
        recvResolve = resolve;
        recvReject = reject;
        recvTimer = setTimeout(() => {
          reject(new Error('Payload read timeout'));
        }, 30000) as number;
        if (totalRead >= payloadSize) {
          clearTimeout(recvTimer);
          resolve();
        }
      });

      // 5. Write chunks to temp file then close
      for (let i = 0; i < chunks.length; i++) {
        fileIo.writeSync(outFile.fd, chunks[i].buffer);
      }
      fileIo.closeSync(outFile);
      outFile = null;

      console.info(`[KDE-MVP] Temp file saved: ${tmpPath} (${totalRead} bytes)`);

      // 6. Auto-save to Download/<bundleName>/ via DOWNLOAD mode (no user picker)
      let finalPath: string = tmpPath;
      try {
        const saveOpts: picker.DocumentSaveOptions = new picker.DocumentSaveOptions();
        saveOpts.pickerMode = picker.DocumentPickerMode.DOWNLOAD;
        const docPicker: picker.DocumentViewPicker = new picker.DocumentViewPicker(this.context!);
        const uris: string[] = await docPicker.save(saveOpts);
        if (uris && uris.length > 0) {
          const dirUri: string = uris[0];
          // Build target path: dirUri/filename
          const targetUri: string = new fileUri.FileUri(`${dirUri}/${safeName}`).path;
          // Copy temp → Download/<bundleName>/
          const src: fileIo.File = fileIo.openSync(tmpPath, fileIo.OpenMode.READ_ONLY);
          const dst: fileIo.File = fileIo.openSync(targetUri, fileIo.OpenMode.CREATE |
            fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
          const copyBuf: ArrayBuffer = new ArrayBuffer(8192);
          let n: number;
          while ((n = fileIo.readSync(src.fd, copyBuf)) > 0) {
            const slice: ArrayBuffer = new ArrayBuffer(n);
            const sv: Uint8Array = new Uint8Array(slice);
            sv.set(new Uint8Array(copyBuf, 0, n));
            fileIo.writeSync(dst.fd, slice);
          }
          fileIo.closeSync(src);
          fileIo.closeSync(dst);
          finalPath = targetUri;
          console.info(`[KDE-MVP] File saved to Download: ${targetUri}`);
          // Clean up temp
          try { fileIo.unlinkSync(tmpPath); } catch (_u) {}
        }
      } catch (pickerErr) {
        console.warn('[KDE-MVP] DOWNLOAD mode failed, file stays in temp:', JSON.stringify(pickerErr));
      }

      // 7. Notify user
      AppNotifier.getInstance().notifyFileReceived(safeName, finalPath).catch((e: Error) => {
        console.error('[KDE-MVP] File receive notify failed:', e.message);
      });

      this.emit(this.paired ? 'paired' : 'connected', `收到文件: ${safeName}`);

    } catch (e) {
      console.error('[KDE-MVP] File receive failed:', JSON.stringify(e));
      if (outFile) {
        try { fileIo.closeSync(outFile); } catch (_e) {}
      }
      this.emit('error', `接收文件失败: ${filename}`);
    } finally {
      try { tls?.close(); } catch (_e) {}
      try { tcp?.close(); } catch (_e) {}
    }
  }

  /** Send local battery now and refresh every 60s while session is live. */
  private startBatteryReporting(): void {
    this.stopBatteryReporting();
    this.sendLocalBattery(true);
    this.batteryTimer = setInterval(() => {
      if (!this.sessionLive || !this.isTlsLive()) {
        this.stopBatteryReporting();
        return;
      }
      this.sendLocalBattery(false);
    }, 60000) as number;
  }

  private stopBatteryReporting(): void {
    if (this.batteryTimer >= 0) {
      clearInterval(this.batteryTimer);
      this.batteryTimer = -1;
    }
    this.lastSentCharge = -1;
  }

  private sendLocalBattery(force: boolean): void {
    if (!this.isPluginEnabled(PLUGIN_BATTERY)) {
      return;
    }
    if (!this.isTlsLive() || !this.sessionLive) {
      return;
    }
    let body = BatteryHelper.readLocalBattery();
    if (!force &&
      body.currentCharge === this.lastSentCharge &&
      body.isCharging === this.lastSentCharging) {
      return;
    }
    this.lastSentCharge = body.currentCharge;
    this.lastSentCharging = body.isCharging;
    let json: string = serializePacket('kdeconnect.battery', body);
    this.sendTls(json, (err) => {
      if (err) {
        console.error('[KDE-MVP] Battery send failed:', JSON.stringify(err));
      } else {
        console.info(
          `[KDE-MVP] Battery sent: ${body.currentCharge}% charging=${body.isCharging}`
        );
      }
    });
  }

  private sendPairRequestOnce(gen: number, pair: boolean): void {
    if (!this.isTlsLive() || gen !== this.sessionGen) {
      return;
    }
    if (pair && this.pairRequestSentForGen === gen) {
      console.info('[KDE-MVP] Pair request already sent for this session, skip');
      return;
    }
    if (pair && this.peerDevice && this.isTrusted(this.peerDevice.deviceId)) {
      console.info('[KDE-MVP] Device already trusted, skip pair request');
      return;
    }
    const ts: number = Math.floor(Date.now() / 1000);
    let body: KdePairBody = {
      pair: pair,
      timestamp: ts
    };
    let json: string = serializePacket('kdeconnect.pair', body);
    if (pair) {
      this.pairingTimestamp = ts;
      this.recomputeVerificationKey().catch(() => {
      });
      this.pairRequestSentForGen = gen;
      // Android: wait 30s for peer to accept
      this.startPairTimer(DeviceSession.PAIR_REQUEST_TIMEOUT_MS, '配对超时，请重试');
      this.notifySessionChange();
    }
    this.sendTls(json, (err) => {
      if (gen !== this.sessionGen) {
        return;
      }
      if (err) {
        console.error('[KDE-MVP] Pair send failed:', JSON.stringify(err));
        this.clearPairTimer();
        this.pairRequestSentForGen = -1;
        this.notifySessionChange();
        this.emit('error', '配对请求发送失败', {
          peerName: this.peerDevice?.deviceName,
          peerDeviceId: this.peerDevice?.deviceId
        });
      } else {
        console.info('[KDE-MVP] Pair request sent — accept on PC');
        this.emit('connected', '配对请求已发送，请在电脑上点接受', {
          peerName: this.peerDevice?.deviceName,
          peerDeviceId: this.peerDevice?.deviceId
        });
      }
    });
  }

  private writeLocalClipboard(text: string): void {
    try {
      let sysPasteboard = pasteboard.getSystemPasteboard();
      let pasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, text);
      sysPasteboard.setData(pasteData, (err) => {
        if (err) {
          console.error('[KDE-MVP] Clipboard write failed:', JSON.stringify(err));
        } else {
          console.info(`[KDE-MVP] Clipboard synced: "${text.substring(0, 80)}"`);
        }
      });
    } catch (e) {
      console.error('[KDE-MVP] Clipboard exception:', JSON.stringify(e));
    }
  }

  public sendClipboard(text: string): void {
    if (!this.isPluginEnabled(PLUGIN_CLIPBOARD)) {
      console.info('[KDE-MVP] sendClipboard: plugin disabled for peer');
      this.emit('error', '剪贴板插件已对该设备关闭');
      return;
    }
    if (!this.isTlsLive()) {
      this.emit('error', '未连接，无法发送剪贴板');
      return;
    }
    let body: KdeClipboardBody = { content: text };
    let json: string = serializePacket('kdeconnect.clipboard', body);
    this.sendTls(json, (err) => {
      if (err) {
        console.error('[KDE-MVP] Clipboard send failed:', JSON.stringify(err));
      } else {
        console.info('[KDE-MVP] Clipboard sent to PC');
        this.emit(this.paired ? 'paired' : 'connected', '剪贴板已发送到电脑', {
          lastClipboard: text
        });
      }
    });
  }

  public sendPing(message: string = 'Hello from HarmonyOS'): void {
    if (!this.isPluginEnabled(PLUGIN_PING)) {
      console.info('[KDE-MVP] sendPing: plugin disabled for peer');
      return;
    }
    if (!this.isTlsLive()) {
      this.emit('error', '未连接，无法 Ping');
      return;
    }
    let body: KdePingBody = { message: message };
    let json: string = serializePacket('kdeconnect.ping', body);
    this.sendTls(json, (err) => {
      if (err) {
        console.error('[KDE-MVP] Ping failed:', JSON.stringify(err));
      } else {
        this.emit(this.paired ? 'paired' : 'connected', 'Ping 已发送');
      }
    });
  }

  /**
   * Send plain text as clipboard (no READ_PASTEBOARD — avoid system getData).
   * UI should collect text via TextInput or system paste into the field.
   */
  public sendClipboardFromText(text: string): void {
    if (!text || text.length === 0) {
      this.emit('error', '文本为空');
      return;
    }
    this.sendClipboard(text);
  }

  /** User-initiated pair request (Android: requestPairing). */
  public requestPairing(): void {
    if (!this.isTlsLive()) {
      console.warn('[KDE-MVP] requestPairing: TLS not live');
      this.emit('error', '请先连接设备', {
        peerName: this.peerDevice?.deviceName,
        peerDeviceId: this.peerDevice?.deviceId
      });
      return;
    }
    if (this.paired || (this.peerDevice !== null && this.isTrusted(this.peerDevice.deviceId))) {
      console.warn('[KDE-MVP] requestPairing: already paired');
      this.paired = true;
      this.emit('paired', `已与 ${this.peerDevice?.deviceName ?? ''} 恢复加密连接`, {
        peerName: this.peerDevice?.deviceName,
        peerDeviceId: this.peerDevice?.deviceId
      });
      return;
    }
    // Android: if peer already started pairing, accept their request
    if (this.pairRequestedByPeer) {
      console.info('[KDE-MVP] Peer already requested; accepting');
      this.acceptPairing();
      return;
    }
    if (this.pairRequestSentForGen >= 0) {
      console.info('[KDE-MVP] Pair request already in flight');
      return;
    }
    this.sendPairRequestOnce(this.sessionGen, true);
  }

  /** Whether peer has requested pairing (for UI accept/reject). */
  public isPairRequestedByPeer(): boolean {
    return this.pairRequestedByPeer;
  }

  /** Accept incoming pair request (from notification action). */
  public acceptPairing(): void {
    if (!this.isTlsLive()) {
      console.warn('[KDE-MVP] acceptPairing: TLS not live');
      return;
    }
    this.clearPairTimer();
    const accept: string = serializePacket('kdeconnect.pair', { pair: true } as KdePairBody);
    this.sendTls(accept, () => {});
    this.paired = true;
    this.pairRequestSentForGen = -1;
    this.pairRequestedByPeer = false;
    if (this.peerDevice) {
      this.trustedDeviceIds.add(this.peerDevice.deviceId);
      this.persistTrust(this.peerDevice).catch((e: Error) => {
        console.error('[KDE-MVP] persistTrust failed:', e.message);
      });
    }
    this.notifySessionChange();
    this.emit('paired', '配对成功！可同步剪贴板', {
      peerName: this.peerDevice?.deviceName,
      peerDeviceId: this.peerDevice?.deviceId
    });
  }

  /** Reject incoming pair request (from notification action). */
  public rejectPairing(): void {
    this.clearPairTimer();
    if (this.isTlsLive()) {
      const reject: string = serializePacket('kdeconnect.pair', { pair: false } as KdePairBody);
      this.sendTls(reject, () => {});
    }
    this.paired = false;
    this.pairRequestSentForGen = -1;
    this.pairRequestedByPeer = false;
    this.notifySessionChange();
    this.emit('error', '已拒绝配对', {
      peerName: this.peerDevice?.deviceName,
      peerDeviceId: this.peerDevice?.deviceId
    });
    console.info('[KDE-MVP] Pair request rejected');
  }

  /**
   * Cancel in-flight pairing (Android cancelPairing).
   * Sends pair:false, clears Requested / RequestedByPeer.
   */
  public cancelPairing(): void {
    this.clearPairTimer();
    if (this.isTlsLive()) {
      const cancel: string = serializePacket('kdeconnect.pair', { pair: false } as KdePairBody);
      this.sendTls(cancel, () => {});
    }
    this.pairRequestSentForGen = -1;
    this.pairRequestedByPeer = false;
    this.notifySessionChange();
    this.emit('error', '已取消配对', {
      peerName: this.peerDevice?.deviceName,
      peerDeviceId: this.peerDevice?.deviceId
    });
    console.info('[KDE-MVP] Pairing cancelled by user');
  }

  /**
   * Drop live session but KEEP trust (paired list). User-facing disconnect.
   */
  public disconnect(): void {
    this.teardownLink(false, true);
  }

  /**
   * Hub replaces this session with a newer connection for the same deviceId.
   * Tears down sockets without emitting "已断开连接" (avoids UI flicker / false offline).
   */
  public disposeQuietly(): void {
    this.teardownLink(true, false);
  }

  /**
   * Shared teardown for user disconnect vs quiet replace.
   * @param silent       skip status emit
   * @param stopFindPhone whether to stop Find-My-Phone alarm
   */
  private teardownLink(silent: boolean, stopFindPhone: boolean): void {
    this.sessionGen += 1;
    // Keep this.paired / trustedDeviceIds so list still shows as paired-offline
    this.sessionLive = false;
    this.handlingIncoming = false;
    this.clearPairTimer();
    this.pairRequestSentForGen = -1;
    this.pairRequestedByPeer = false;
    this.pendingPairAccept = false;
    this.lineBuffer = '';
    this.peerBattery = null;
    this.clearVerificationState();
    this.stopBatteryReporting();
    this.teardownMprisReceiver();
    if (stopFindPhone) {
      FindMyPhoneHelper.getInstance().stop();
    }
    this.notifySessionChange();
    this.closeTlsChannel();
    this.cleanOutboundState();
    try {
      this.bridgeLocalClient?.close();
    } catch (_e) {
      // ignore
    }
    this.bridgeLocalClient = null;
    this.pendingBridgeBytes = [];
    try {
      this.bridgeLocalAccepted?.close();
    } catch (_e) {
      // ignore
    }
    this.bridgeLocalAccepted = null;
    try {
      this.bridgeRemote?.close();
    } catch (_e) {
      // ignore
    }
    this.bridgeRemote = null;
    try {
      this.bridgeLocalServer?.close();
    } catch (_e) {
      // ignore
    }
    this.bridgeLocalServer = null;
    if (!silent) {
      this.emit('discovering', '已断开连接（仍保留配对）', {
        peerName: this.peerDevice?.deviceName,
        peerDeviceId: this.peerDevice?.deviceId
      });
    }
  }

  /**
   * Unpair: notify PC if online, drop trust, close session.
   */
  public async unpair(deviceId?: string): Promise<void> {
    let id: string | undefined = deviceId ?? this.peerDevice?.deviceId;
    this.clearPairTimer();
    if (this.isTlsLive() && this.sessionLive && id && this.peerDevice?.deviceId === id) {
      let body: KdePairBody = { pair: false };
      let json: string = serializePacket('kdeconnect.pair', body);
      try {
        await new Promise<void>((resolve) => {
          this.sendTls(json, () => {
            resolve();
          });
        });
      } catch (_e) {
        // ignore
      }
    }
    if (id) {
      await this.removeTrust(id);
    }
    this.paired = false;
    this.sessionGen += 1;
    this.sessionLive = false;
    this.handlingIncoming = false;
    this.pairRequestSentForGen = -1;
    this.pairRequestedByPeer = false;
    this.lineBuffer = '';
    this.peerBattery = null;
    this.stopBatteryReporting();
    FindMyPhoneHelper.getInstance().stop();
    this.notifySessionChange();
    this.closeTlsChannel();
    try {
      this.bridgeLocalClient?.close();
    } catch (_e) {
      // ignore
    }
    this.bridgeLocalClient = null;
    try {
      this.bridgeLocalAccepted?.close();
    } catch (_e) {
      // ignore
    }
    this.bridgeLocalAccepted = null;
    try {
      this.bridgeRemote?.close();
    } catch (_e) {
      // ignore
    }
    this.bridgeRemote = null;
    try {
      this.bridgeLocalServer?.close();
    } catch (_e) {
      // ignore
    }
    this.bridgeLocalServer = null;
    this.emit('discovering', '已取消配对', { peerDeviceId: id });
  }

  public isSessionLive(): boolean {
    return this.sessionLive;
  }

  public isDeviceSessionActive(deviceId: string): boolean {
    return this.sessionLive && this.peerDevice?.deviceId === deviceId;
  }

  // ── TLS channel abstraction (works for both reverse + outbound) ──

  private isTlsLive(): boolean {
    if (this.outboundActive && this.outTlsConn !== null) {
      return true;
    }
    return this.tlsSocket !== null;
  }

  /** Send a JSON string over whichever TLS channel is active. */
  private sendTls(data: string, callback?: (err: Object) => void): void {
    const cb: (err: Object) => void = callback ?? ((_e: Object) => {});
    if (this.outboundActive && this.outTlsConn) {
      this.outTlsConn.send(data, cb);
    } else if (this.tlsSocket) {
      this.tlsSocket.send(data, cb);
    }
  }

  /** Close & null out whichever TLS channel + its bridges are live. */
  private closeTlsChannel(): void {
    if (this.outboundActive) {
      try { this.outTlsConn?.close(); } catch (_e) {}
      this.outTlsConn = null;
      try { this.outTlsFeeder?.close(); } catch (_e) {}
      this.outTlsFeeder = null;
      try { this.outTlsServer?.close(); } catch (_e) {}
      this.outTlsServer = null;
      try { this.outBridgeAccepted?.close(); } catch (_e) {}
      this.outBridgeAccepted = null;
      try { this.outBridgeClient?.close(); } catch (_e) {}
      this.outBridgeClient = null;
      try { this.outBridgeServer?.close(); } catch (_e) {}
      this.outBridgeServer = null;
      try { this.outPeerSock?.close(); } catch (_e) {}
      this.outPeerSock = null;
      this.outboundActive = false;
    }
    try { this.tlsSocket?.close(); } catch (_e) {}
    this.tlsSocket = null;
  }

  // ── File transfer (dual-channel: JSON on main TLS, TLS-encrypted payload on temp port) ──

  /**
   * Send a plain JSON packet (no payload) over the main TLS channel.
   */
  public sendJson(json: string): void {
    if (!this.isTlsLive()) {
      console.warn('[KDE-MVP] sendJson: not connected');
      return;
    }
    this.sendTls(json, (err: Object) => {
      if (err) {
        console.error('[KDE-MVP] sendJson failed:', JSON.stringify(err));
      }
    });
  }

  private payloadPort: number = 0;
  private payloadServer: socket.TLSSocketServer | null = null;
  private payloadConnection: socket.TLSSocketConnection | null = null;

  /**
   * Find a free port in the payload range and start a TLS server on it.
   * Matches Android: SslHelper.convertToSslSocket(..., clientMode=false)
   * — the payload channel is a TLS server presenting the device cert.
   */
  private async openPayloadTlsPort(): Promise<void> {
    for (let tryPort = PAYLOAD_TRANSFER_MIN_PORT; tryPort <= PAYLOAD_TRANSFER_MAX_PORT; tryPort++) {
      const server: socket.TLSSocketServer = socket.constructTLSSocketServerInstance();
      try {
        const tlsListenOpts: socket.TLSConnectOptions = {
          address: {
            address: '0.0.0.0',
            port: tryPort,
            family: 1
          },
          secureOptions: {
            cert: this.certPem,
            key: this.keyPem,
            protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13]
          }
        };
        await server.listen(tlsListenOpts);
        this.payloadPort = tryPort;
        this.payloadServer = server;
        return;
      } catch (_e) {
        try {
          server.close();
        } catch (_ignored) {
        }
      }
    }
    throw new Error('No free TLS payload port in range');
  }

  /**
   * Send a file using the dual-channel approach (matching Android LanLink.sendPacket).
   */
  public async sendPacketWithPayload(
    body: KdeShareRequestBody,
    filePath: string,
    onProgress?: (percent: number) => void
  ): Promise<void> {
    if (!this.isPluginEnabled(PLUGIN_SHARE)) {
      throw new Error('Share plugin disabled for this device');
    }
    if (!this.isTlsLive()) {
      throw new Error('Not connected');
    }

    // 1. Open payload TLS server
    await this.openPayloadTlsPort();

    // 2. Get file size
    let fileSize: number = 0;
    try {
      const stat: fileIo.Stat = fileIo.statSync(filePath);
      fileSize = stat.size;
    } catch (_e) {
      this.cleanupPayload();
      throw new Error('Cannot stat file: ' + filePath);
    }

    // 3. Send JSON metadata over main TLS channel
    const payloadInfo: PayloadTransferInfo = { port: this.payloadPort };
    const json: string = serializePacketWithPayload(
      PACKET_TYPE_SHARE_REQUEST,
      body,
      fileSize,
      payloadInfo
    );

    await new Promise<void>((resolve: (value: void) => void, reject: (reason: Error) => void) => {
      this.sendTls(json, (err: Object) => {
        if (err) {
          reject(new Error('Main-channel send failed'));
        } else {
          resolve();
        }
      });
    });

    // 4. Wait for PC to connect (10 s timeout)
    const connected: socket.TLSSocketConnection = await new Promise<socket.TLSSocketConnection>(
      (resolve: (value: socket.TLSSocketConnection) => void, reject: (reason: Error) => void) => {
        const timeout: number = setTimeout(() => {
          reject(new Error('Payload connection timed out'));
        }, 10000) as number;

        this.payloadServer!.on('connect', (client: socket.TLSSocketConnection) => {
          clearTimeout(timeout);
          this.payloadConnection = client;
          resolve(client);
        });

        this.payloadServer!.on('error', (err: Object) => {
          clearTimeout(timeout);
          reject(new Error('Payload server error'));
        });
      });

    // 5. Stream file bytes
    try {
      const file: fileIo.File = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(4096);
      let totalSent: number = 0;
      let lastProgressTime: number = Date.now();

      try {
        let bytesRead: number;
        let chunk: ArrayBuffer;
        while ((bytesRead = fileIo.readSync(file.fd, buf)) > 0) {
          chunk = new ArrayBuffer(bytesRead);
          const src: Uint8Array = new Uint8Array(buf, 0, bytesRead);
          const dst: Uint8Array = new Uint8Array(chunk);
          dst.set(src);

          await new Promise<void>((res: () => void, rej: (e: Object) => void) => {
            connected.send(chunk, (err: Object) => {
              if (err) {
                rej(err);
              } else {
                res();
              }
            });
          });

          totalSent += bytesRead;
          if (onProgress && fileSize > 0) {
            const now: number = Date.now();
            if (now - lastProgressTime >= 500) {
              lastProgressTime = now;
              const percent: number = Math.round((totalSent * 100) / fileSize);
              onProgress(percent);
            }
          }
        }
      } finally {
        fileIo.closeSync(file);
      }

      if (onProgress) {
        onProgress(100);
      }

      console.info('[KDE-MVP] File sent: ' + body.filename + ' (' + totalSent + ' bytes)');
    } finally {
      this.cleanupPayload();
    }
  }

  private cleanupPayload(): void {
    if (this.payloadConnection) {
      try {
        this.payloadConnection.close();
      } catch (_e) {
        // ignore
      }
      this.payloadConnection = null;
    }
    if (this.payloadServer) {
      try {
        this.payloadServer.close();
      } catch (_e) {
        // ignore
      }
      this.payloadServer = null;
    }
    this.payloadPort = 0;
  }

  /** Tear down this peer session only (hub owns the TCP listen socket). */
  public stop(): void {
    this.disconnect();
  }
}
