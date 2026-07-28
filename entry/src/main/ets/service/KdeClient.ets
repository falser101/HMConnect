import socket from '@ohos.net.socket';
import deviceInfo from '@ohos.deviceInfo';
import pasteboard from '@ohos.pasteboard';
import { fileIo, picker, fileUri } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { avSession } from '@kit.AVSessionKit';
import { BusinessError } from '@kit.BasicServicesKit';
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
import { utf8Decode } from '../common/Utf8';
import { BatteryHelper } from '../common/BatteryHelper';
import { FindMyPhoneHelper } from '../common/FindMyPhoneHelper';

/**
 * Active session: reverse-path preferred (PC connects to us as TCP client / TLS server),
 * with optional outbound TCP probe.
 *
 * Reverse path TLS: after plain identity, bridge the accepted connection through a
 * localhost TCP pair so we can upgrade a TCPSocket to TLS client (HarmonyOS only
 * supports TLS client upgrade on TCPSocket, not TCPSocketConnection).
 */
export class KdeClient {
  private tcpServer: socket.TCPSocketServer | null = null;
  private listenPort: number = 1716;
  private myDeviceName: string =
    sanitizeDeviceName(deviceInfo.marketName || deviceInfo.productModel || 'HarmonyOS Device');

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
  private started: boolean = false;
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

  public setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
    AppNotifier.getInstance().setContext(ctx);
    AppNotifier.getInstance().prepare();
  }

  /** Load trusted device ids from DeviceStore into memory. Call after DeviceStore.init. */
  public loadTrustedFromStore(): void {
    let ids = DeviceStore.getInstance().getTrustedIds();
    this.trustedDeviceIds.clear();
    for (let i = 0; i < ids.length; i++) {
      this.trustedDeviceIds.add(ids[i]);
    }
    console.info(`[KDE-MVP] Loaded ${ids.length} trusted device(s)`);
  }

  public setStatusListener(cb: (status: KdeStatus) => void): void {
    this.statusCallback = cb;
  }

  /** Used by facade to pause UDP announce while session is healthy. */
  public setSessionChangeListener(cb: (live: boolean, paired: boolean) => void): void {
    this.onSessionChange = cb;
  }

  private notifySessionChange(): void {
    if (this.onSessionChange) {
      this.onSessionChange(this.sessionLive, this.paired);
    }
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

  public getPeerBattery(): PeerBatteryInfo | null {
    return this.peerBattery;
  }

  /** Stop ringing when user opens the app after a Find My Phone alert. */
  public stopFindMyPhone(): void {
    FindMyPhoneHelper.getInstance().stop();
  }

  /** Make the remote device ring (Android FindMyPhonePlugin). */
  public sendFindMyPhone(): void {
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

    // 1) Send system media key (controls active media)
    try {
      const keyMap: Record<string, string> = { 'Play': 'playPause', 'Pause': 'playPause', 'PlayPause': 'playPause', 'Next': 'next', 'Previous': 'previous' };
      const key: string | undefined = keyMap[action];
      if (key) {
        avSession.sendSystemAVKeyEvent({ keyAction: 1, keyCode: key }, (err: BusinessError) => {
          if (err) console.warn('[KDE-MVP] AVKey FAILED:', err.code, err.message);
          else console.info('[KDE-MVP] AVKey OK:', key);
        });
      }
    } catch (_e) {}

    // 2) Try discovery-based control of other audio sessions
    this.sendToActiveAudioSession(action);
  }

  /** Discover system audio sessions and send play/pause/etc to the first one. */
  private async sendToActiveAudioSession(action: string): Promise<void> {
    try {
      const descriptors = await avSession.getAllSessions();
      if (!descriptors || descriptors.length === 0) { return; }
      let targetId: string = '';
      for (const d of descriptors) {
        if (d.sessionType === 'audio') { targetId = d.sessionId; break; }
      }
      if (targetId.length === 0) { return; }
      const controller = new avSession.AVSessionController(targetId);
      const cmdMap: Record<string, avSession.AVControlCommandType> = {
        'Play': 'play', 'Pause': 'pause', 'PlayPause': 'play',
        'Next': 'playNext', 'Previous': 'playPrevious'
      };
      const cmd: avSession.AVControlCommandType | undefined = cmdMap[action];
      if (cmd) {
        await controller.sendControlCommand({ command: cmd });
        console.info('[KDE-MVP] real audio session command OK:', cmd);
      }
    } catch (e) {
      console.warn('[KDE-MVP] getAllSessions failed:', JSON.stringify(e));
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

  /** Activate our AVSession so the system treats us as a media controller. */
  public async setupMprisReceiver(ctx: common.UIAbilityContext): Promise<void> {
    if (this.mprisSession) {
      return;
    }
    try {
      console.info('[KDE-MVP] AVSession creating…');
      this.mprisSession = await avSession.createAVSession(ctx, 'HMConnectMpris', 'audio');
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
    }
  }

  public teardownMprisReceiver(): void {
    this.mprisController = null;
    const s = this.mprisSession;
    this.mprisSession = null;
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
  }

  private isTrusted(deviceId: string): boolean {
    return this.trustedDeviceIds.has(deviceId);
  }

  public async startServer(): Promise<number> {
    if (this.started) {
      return this.listenPort;
    }
    await this.loadCerts();
    this.tcpServer = socket.constructTCPSocketServerInstance();

    // Try ports in KDE range 1716-1764
    let bound: boolean = false;
    for (let port = 1716; port <= 1764; port++) {
      try {
        await this.listenOn(port);
        this.listenPort = port;
        bound = true;
        break;
      } catch (e) {
        console.warn(`[KDE-MVP] TCP listen ${port} failed:`, JSON.stringify(e));
      }
    }
    if (!bound) {
      this.emit('error', '无法绑定 1716-1764 TCP 端口');
      throw new Error('TCP bind failed');
    }

    this.started = true;
    this.tcpServer.on('connect', (client: socket.TCPSocketConnection) => {
      console.info('[KDE-MVP] Incoming TCP connection (PC reverse-connect)');
      this.handleIncomingConnection(client);
    });
    this.emit('discovering', `TCP 监听 ${this.listenPort}，等待电脑连接…`);
    return this.listenPort;
  }

  private listenOn(port: number): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      if (!this.tcpServer) {
        reject(new Error('no server'));
        return;
      }
      this.tcpServer.listen({ address: '0.0.0.0', port: port, family: 1 }, (err) => {
        if (err) {
          reject(err);
        } else {
          console.info(`[KDE-MVP] TCP Server listening on ${port}`);
          resolve();
        }
      });
    });
  }

  private async loadCerts(): Promise<void> {
    if (!this.context) {
      console.warn('[KDE-MVP] No context, TLS will use skipRemoteValidation only');
      return;
    }
    try {
      let rm = this.context.resourceManager;
      let certBytes: Uint8Array = await rm.getRawFileContent('certs/device_cert.pem');
      let keyBytes: Uint8Array = await rm.getRawFileContent('certs/device_key.pem');
      this.certPem = utf8Decode(certBytes);
      this.keyPem = utf8Decode(keyBytes);
      console.info('[KDE-MVP] Loaded device cert/key for TLS');
    } catch (e) {
      console.error('[KDE-MVP] Load cert failed:', JSON.stringify(e));
    }
  }

  /**
   * User tapped "连接": try reverse path first (UDP poke → wait for PC to connect back).
   * If the peer does not connect back within 5 s, initiate an outbound TLS connection.
   */
  public connectToDevice(device: KdeDevice): void {
    this.peerDevice = device;
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

      // ── 8. Session is now live ──
      this.sessionLive = true;
      this.handlingIncoming = false;
      this.notifySessionChange();
      this.startBatteryReporting();

      // Wire up message handler
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

      // ── 9. Handle pairing (same logic as upgradeClientTls callback) ──
      const deviceId: string = device.deviceId;
      if (this.isTrusted(deviceId) || this.paired) {
        this.paired = true;
        this.trustedDeviceIds.add(deviceId);
        this.persistTrust(device).catch(() => {});
        this.emit('paired', `已与 ${device.deviceName} 恢复加密连接`, {
          peerName: device.deviceName,
          peerDeviceId: device.deviceId
        });
        console.info('[KDE-MVP] Trusted device, skip pair request (outbound)');
        return;
      }

      this.emit('connected', '已加密连接', {
        peerName: device.deviceName,
        peerDeviceId: device.deviceId
      });

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

  private async handleIncomingConnection(client: socket.TCPSocketConnection): Promise<void> {
    let remoteAddr: string = '';
    try {
      remoteAddr = (await client.getRemoteAddress()).address ?? '';
    } catch (e) {
      console.warn('[KDE-MVP] Failed to get remote address:', JSON.stringify(e));
    }
    const now: number = Date.now();

    // Rate limit by IP (Android: rateLimitByIp, 1s)
    const lastIp: number | undefined = this.lastConnTimeByIp[remoteAddr];
    if (lastIp !== undefined && (lastIp + KdeClient.CONN_RATE_MS > now)) {
      console.info('[KDE-MVP] Rate-limited duplicate TCP:', remoteAddr);
      try { client.close(); } catch (_e) {}
      return;
    }
    this.lastConnTimeByIp[remoteAddr] = now;

    // Outbound in progress — accept reverse connection, cancel outbound
    if (this.outboundActive) {
      if (remoteAddr.length > 0 && remoteAddr === this.outboundTargetIp) {
        console.info('[KDE-MVP] Reverse while outbound — accept, cancel outbound');
        this.cleanOutboundState();
      }
      // Don't reject — accept it (Android doesn't reject concurrent)
    }

    // Session live — don't accept duplicate
    if (this.sessionLive) {
      console.info('[KDE-MVP] Session live, drop duplicate');
      try { client.close(); } catch (_e) {}
      return;
    }
    if (this.handlingIncoming) {
      console.info('[KDE-MVP] Reject concurrent TCP: handshake in progress');
      try {
        client.close();
      } catch (_e) {
        // ignore
      }
      return;
    }

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
          deviceType: body.deviceType ?? this.peerDevice?.deviceType ?? 'desktop'
        };
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
    this.setupBridgeWithPort(remote, peer, earlyTlsBytes, 37564, gen);
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
        // Flush any pending pair-accept that arrived before TLS was fully live
        if (this.pendingPairAccept) {
          this.pendingPairAccept = false;
          const accept: string = serializePacket('kdeconnect.pair', { pair: true } as KdePairBody);
          this.sendTls(accept, () => {});
          console.info('[KDE-MVP] flushed pending pair-accept');
        }
        this.notifySessionChange();
        // Report phone battery as soon as the channel is up (desktop shows it even pre-pair on some builds)
        this.startBatteryReporting();
        // Register as media controller for remote control
        if (this.context) {
          this.setupMprisReceiver(this.context);
        }

        let deviceId: string = peer.deviceId;
        if (this.isTrusted(deviceId) || this.paired) {
          this.paired = true;
          this.trustedDeviceIds.add(deviceId);
          this.persistTrust(peer).catch(() => {
          });
          this.emit('paired', `已与 ${peer.deviceName} 恢复加密连接`, {
            peerName: peer.deviceName,
            peerDeviceId: peer.deviceId
          });
          // Already trusted — do NOT send pair:true again (causes PC re-prompt / unpair loops)
          console.info('[KDE-MVP] Trusted device, skip pair request');
          return;
        }

        this.emit('connected', '已加密连接', {
          peerName: peer.deviceName,
          peerDeviceId: peer.deviceId
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
        // Already paired → re-accept silently (break potential loop, Android: auto-accept)
        if (this.paired) {
          if (this.isTlsLive()) {
            const reAccept: string = serializePacket('kdeconnect.pair', { pair: true } as KdePairBody);
            this.sendTls(reAccept, () => {});
          } else {
            this.pendingPairAccept = true;
          }
          return;
        }

        const weRequested: boolean = this.pairRequestSentForGen >= 0;
        this.pairRequestSentForGen = -1;

        if (weRequested) {
          // Our outgoing pair request was accepted (Android: pairingDone when state==Requested)
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
        } else {
          // Peer requested pairing → show notification + enable in-app accept/reject
          // Do NOT set paired until user taps Accept
          this.pairRequestedByPeer = true;
          this.notifySessionChange();
          console.info('[KDE-MVP] Peer requested pairing, showing notification');
          AppNotifier.getInstance().notifyPairRequest(
            this.peerDevice?.deviceName ?? '未知设备',
            this.peerDevice?.deviceId ?? ''
          );
          return;
        }
        // Unpair / reject — match Android PairingHandler.packetReceived(pair=false)
        const wasPaired: boolean = this.paired;
        const wasRequesting: boolean = this.pairRequestSentForGen >= 0;
        this.paired = false;
        this.pairRequestSentForGen = -1;
        this.pairRequestedByPeer = false;
        this.notifySessionChange();
        if (this.peerDevice) {
          this.removeTrust(this.peerDevice.deviceId).catch(() => {});
          if (wasRequesting && !wasPaired) {
            // We sent a pair request, PC rejected → show error (Android: pairingFailed)
            this.emit('error', '配对被拒绝');
          } else if (wasPaired) {
            // Already paired → PC unpaired us (Android: unpaired callback)
            // Disconnect TLS so device status resets
            this.emit('paired', '设备已取消配对', {
              peerName: this.peerDevice.deviceName,
              peerDeviceId: this.peerDevice.deviceId
            });
            console.info('[KDE-MVP] Peer unpaired us, trust cleared, disconnecting');
            this.disconnect();
          }
          // else: already NotPaired, ignore (Android: "Ignoring unpair request for already unpaired device")
        }
      }
      return;
    }

    if (type === 'kdeconnect.identity') {
      // post-TLS identity (protocol 8); accept quietly
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
    let body: KdePairBody = {
      pair: pair,
      timestamp: Math.floor(Date.now() / 1000)
    };
    let json: string = serializePacket('kdeconnect.pair', body);
    if (pair) {
      this.pairRequestSentForGen = gen;
    }
    this.sendTls(json, (err) => {
      if (gen !== this.sessionGen) {
        return;
      }
      if (err) {
        console.error('[KDE-MVP] Pair send failed:', JSON.stringify(err));
        this.pairRequestSentForGen = -1;
        this.emit('error', '配对请求发送失败');
      } else {
        console.info('[KDE-MVP] Pair request sent — accept on PC');
        this.emit('connected', '配对请求已发送，请在电脑上点接受', {
          peerName: this.peerDevice?.deviceName
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
      this.emit('error', '请先连接设备');
      return;
    }
    if (this.paired) {
      console.warn('[KDE-MVP] requestPairing: already paired');
      return;
    }
    if (this.peerDevice && this.isTrusted(this.peerDevice.deviceId)) {
      this.paired = true;
      this.emit('paired', `已与 ${this.peerDevice.deviceName} 恢复加密连接`, {
        peerName: this.peerDevice.deviceName,
        peerDeviceId: this.peerDevice.deviceId
      });
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
    if (!this.isTlsLive()) {
      console.warn('[KDE-MVP] rejectPairing: TLS not live');
      return;
    }
    const reject: string = serializePacket('kdeconnect.pair', { pair: false } as KdePairBody);
    this.sendTls(reject, () => {});
    this.paired = false;
    this.pairRequestSentForGen = -1;
    this.pairRequestedByPeer = false;
    this.notifySessionChange();
    console.info('[KDE-MVP] Pair request rejected');
  }

  /**
   * Drop live session but KEEP trust (paired list).
   */
  public disconnect(): void {
    this.sessionGen += 1;
    // Keep this.paired / trustedDeviceIds so list still shows as paired-offline
    this.sessionLive = false;
    this.handlingIncoming = false;
    this.pairRequestSentForGen = -1;
    this.pairRequestedByPeer = false;
    this.pendingPairAccept = false;
    this.lineBuffer = '';
    this.peerBattery = null;
    this.stopBatteryReporting();
    this.teardownMprisReceiver();
    FindMyPhoneHelper.getInstance().stop();
    this.notifySessionChange();
    this.closeTlsChannel();
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
    this.emit('discovering', '已断开连接（仍保留配对）', {
      peerName: this.peerDevice?.deviceName,
      peerDeviceId: this.peerDevice?.deviceId
    });
  }

  /**
   * Unpair: notify PC if online, drop trust, close session.
   */
  public async unpair(deviceId?: string): Promise<void> {
    let id: string | undefined = deviceId ?? this.peerDevice?.deviceId;
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

  public stop(): void {
    this.disconnect();
    try {
      this.tcpServer?.close();
    } catch (_e) {
      // ignore
    }
    this.tcpServer = null;
    this.started = false;
  }
}
