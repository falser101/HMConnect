import socket from '@ohos.net.socket';
import deviceInfo from '@ohos.deviceInfo';
import { common } from '@kit.AbilityKit';
import { AppNotifier } from '../common/AppNotifier';
import {
  KdeDevice,
  KdeShareRequestBody,
  PeerBatteryInfo,
  KdeStatus,
  ConnectionState,
  MprisPlayerState,
  SystemVolumeSink,
  KdeMousepadRequestBody,
  MousepadInputInfo,
  MousepadModifiers,
  KdeRunCommandEntry,
  RunCommandOutputEvent,
  sanitizeDeviceName
} from './KdeTypes';
import { DeviceStore } from '../store/DeviceStore';
import { PluginSettingsStore } from '../store/PluginSettingsStore';
import { utf8Decode } from '../common/Utf8';
import { DeviceSession } from './DeviceSession';

/**
 * Multi-device connection hub (Android KdeConnect + LanLinkProvider role).
 *
 * - Owns shared TCP listen socket (1716–1764) and device certs
 * - Holds Map<deviceId, DeviceSession> for concurrent TLS sessions
 * - Routes user actions and incoming TCP by deviceId
 */
export class KdeClient {
  private tcpServer: socket.TCPSocketServer | null = null;
  private listenPort: number = 1716;
  private myDeviceName: string =
    sanitizeDeviceName(deviceInfo.marketName || deviceInfo.productModel || 'HarmonyOS Device');
  private context: common.UIAbilityContext | null = null;
  private certPem: string = '';
  private keyPem: string = '';
  private started: boolean = false;

  /** Live / remembered peer sessions keyed by deviceId. */
  private sessions: Map<string, DeviceSession> = new Map();
  /** Handshake sessions not yet bound to a deviceId (temp key). */
  private pendingSessions: Map<string, DeviceSession> = new Map();
  private bridgePortSeq: number = 0;

  private trustedDeviceIds: Set<string> = new Set();
  private lastConnTimeByIp: Record<string, number> = {};
  private static readonly CONN_RATE_MS: number = 1000;

  private statusCallback?: (status: KdeStatus) => void;
  private onSessionChange?: (live: boolean, paired: boolean) => void;
  /** deviceId → mpris listener (UI page for that device). */
  private mprisListeners: Map<string, (player: MprisPlayerState | null) => void> = new Map();
  /** deviceId → mpris player-list listener. */
  private mprisListListeners: Map<string, (names: string[]) => void> = new Map();
  /** deviceId → system volume listener. */
  private systemVolumeListeners: Map<string, (sinks: SystemVolumeSink[]) => void> = new Map();
  /** deviceId → mousepad keyboard-state listener (RemoteInput page). */
  private mousepadKeyboardListeners: Map<string, (enabled: boolean) => void> = new Map();
  /** deviceId → inbound desktop-input listener (RemoteInput page feedback). */
  private mousepadInputListeners: Map<string, (info: MousepadInputInfo) => void> = new Map();
  /** deviceId → remote command list listener (RunCommand page). */
  private runCommandListListeners: Map<string, (entries: KdeRunCommandEntry[]) => void> = new Map();
  /** deviceId → remote command output listener (RunCommand page). */
  private runCommandOutputListeners: Map<string, (event: RunCommandOutputEvent) => void> = new Map();

  public setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
    AppNotifier.getInstance().setContext(ctx);
    AppNotifier.getInstance().prepare();
    this.sessions.forEach((s: DeviceSession) => {
      s.configure(ctx, this.certPem, this.keyPem, this.myDeviceName, this.listenPort, 0, false);
    });
  }

  public loadTrustedFromStore(): void {
    let ids = DeviceStore.getInstance().getTrustedIds();
    this.trustedDeviceIds.clear();
    for (let i = 0; i < ids.length; i++) {
      this.trustedDeviceIds.add(ids[i]);
    }
    this.sessions.forEach((s: DeviceSession) => {
      s.setTrustedCache(this.trustedDeviceIds);
    });
    console.info(`[KDE-MVP] Hub loaded ${ids.length} trusted device(s)`);
  }

  public setStatusListener(cb: (status: KdeStatus) => void): void {
    this.statusCallback = cb;
  }

  public setSessionChangeListener(cb: (live: boolean, paired: boolean) => void): void {
    this.onSessionChange = cb;
  }

  private emitHub(state: ConnectionState, message: string, extra?: Partial<KdeStatus>): void {
    if (!this.statusCallback) {
      return;
    }
    let status: KdeStatus = {
      state: state,
      message: message,
      peerName: extra?.peerName,
      peerDeviceId: extra?.peerDeviceId,
      lastClipboard: extra?.lastClipboard,
      peerBattery: extra?.peerBattery
    };
    this.statusCallback(status);
  }

  private notifyAnySessionChange(): void {
    if (!this.onSessionChange) {
      return;
    }
    let anyLive = false;
    let anyPairedLive = false;
    this.sessions.forEach((s: DeviceSession) => {
      if (s.isSessionLive()) {
        anyLive = true;
        if (s.isPaired()) {
          anyPairedLive = true;
        }
      }
    });
    // Keep announcing when multi-device: only pause if EVERYTHING is quiet? 
    // Android keeps discovery; we pause UDP only when at least one live to reduce storms,
    // but still allow new reverse connects via unicast/poke. Discover respects announcePaused
    // for broadcast only — user connect still unicasts. OK for multi.
    this.onSessionChange(anyLive, anyPairedLive);
  }

  public getListenPort(): number {
    return this.listenPort;
  }

  public getMyDeviceName(): string {
    return this.myDeviceName;
  }

  /** Apply a user-configured device name and propagate to live sessions. */
  public setMyDeviceName(name: string): void {
    if (!name || name.length === 0) {
      return;
    }
    this.myDeviceName = sanitizeDeviceName(name);
    this.sessions.forEach((s: DeviceSession) => {
      s.configure(this.context, this.certPem, this.keyPem, this.myDeviceName, this.listenPort, 0, false);
    });
    console.info(`[KDE-MVP] Client device name set to: ${this.myDeviceName}`);
  }

  /** All peer sessions (for list building). */
  public getSessions(): DeviceSession[] {
    let list: DeviceSession[] = [];
    this.sessions.forEach((s: DeviceSession) => {
      list.push(s);
    });
    return list;
  }

  public getSession(deviceId: string): DeviceSession | undefined {
    return this.sessions.get(deviceId);
  }

  /** Prefer named session; fall back to first live session (legacy single-device callers). */
  public getClient(): DeviceSession | null {
    // Prefer a live paired session, then any live, then any
    let firstLive: DeviceSession | null = null;
    let firstPaired: DeviceSession | null = null;
    let first: DeviceSession | null = null;
    this.sessions.forEach((s: DeviceSession) => {
      if (!first) {
        first = s;
      }
      if (s.isSessionLive() && !firstLive) {
        firstLive = s;
      }
      if (s.isSessionLive() && s.isPaired() && !firstPaired) {
        firstPaired = s;
      }
    });
    return firstPaired ?? firstLive ?? first;
  }

  public getClientForDevice(deviceId: string): DeviceSession | null {
    return this.sessions.get(deviceId) ?? null;
  }

  private nextBridgePort(): number {
    // 37564..37663 unique bases; each session may bump within range internally
    this.bridgePortSeq = (this.bridgePortSeq + 1) % 100;
    return 37564 + this.bridgePortSeq;
  }

  private wireSession(session: DeviceSession, knownDeviceId: string): void {
    session.configure(
      this.context,
      this.certPem,
      this.keyPem,
      this.myDeviceName,
      this.listenPort,
      this.nextBridgePort(),
      true
    );
    session.setTrustedCache(this.trustedDeviceIds);
    session.setStatusListener((status: KdeStatus) => {
      if (this.statusCallback) {
        this.statusCallback(status);
      }
    });
    session.setSessionChangeListener((_live: boolean, _paired: boolean) => {
      this.rebindSessionIfNeeded(session);
      this.notifyAnySessionChange();
    });
    if (knownDeviceId.length > 0) {
      let mprisCb = this.mprisListeners.get(knownDeviceId);
      if (mprisCb) {
        session.setMprisChangeListener(mprisCb);
      }
      let listCb = this.mprisListListeners.get(knownDeviceId);
      if (listCb) {
        session.setMprisPlayerListListener(listCb);
      }
      let volCb = this.systemVolumeListeners.get(knownDeviceId);
      if (volCb) {
        session.setSystemVolumeChangeListener(volCb);
      }
      let kbCb = this.mousepadKeyboardListeners.get(knownDeviceId);
      if (kbCb) {
        session.setMousepadKeyboardStateListener(kbCb);
      }
      let inCb = this.mousepadInputListeners.get(knownDeviceId);
      if (inCb) {
        session.setMousepadInputListener(inCb);
      }
      let rcCb = this.runCommandListListeners.get(knownDeviceId);
      if (rcCb) {
        session.setRunCommandListListener(rcCb);
      }
      let rcoCb = this.runCommandOutputListeners.get(knownDeviceId);
      if (rcoCb) {
        session.setRunCommandOutputListener(rcoCb);
      }
    }
  }

  private createSession(deviceId: string): DeviceSession {
    let session = new DeviceSession();
    this.wireSession(session, deviceId);
    if (deviceId.length > 0) {
      this.sessions.set(deviceId, session);
    }
    return session;
  }

  /**
   * If session learned a real deviceId, ensure map key matches.
   *
   * Critical anti-reconnect rule (Android LanLink-like):
   * When we already have a LIVE TLS session for this deviceId, drop the new
   * incoming TCP instead of replacing. Peers reverse-connect on every UDP
   * announce (~8s); replacing a healthy link causes thrashing:
   *   Quiet-replace(prevLive=true) → teardown → re-handshake → repeat.
   */
  private rebindSessionIfNeeded(session: DeviceSession): void {
    let realId = session.getBoundDeviceId();
    if (realId.length === 0) {
      return;
    }
    // Drop any pending keys pointing at this session
    let pendingKeys: string[] = [];
    this.pendingSessions.forEach((s: DeviceSession, k: string) => {
      if (s === session) {
        pendingKeys.push(k);
      }
    });
    for (let i = 0; i < pendingKeys.length; i++) {
      this.pendingSessions.delete(pendingKeys[i]);
    }
    let prev = this.sessions.get(realId);
    if (prev === session) {
      return;
    }
    if (prev && prev !== session) {
      if (prev.isSessionLive()) {
        // Keep the healthy link; abort the duplicate reverse connection.
        // disposeQuietly bumps sessionGen so in-flight bridge/TLS on `session` no-ops.
        console.info(
          `[KDE-MVP] Drop duplicate incoming for ${realId} — keep live session`
        );
        session.disposeQuietly();
        return;
      }
      // Previous session is dead/orphan — take over quietly
      console.info(`[KDE-MVP] Quiet-replace dead session for ${realId}`);
      prev.disposeQuietly();
    }
    // Remove stale keys for this same object
    let staleKeys: string[] = [];
    this.sessions.forEach((s: DeviceSession, k: string) => {
      if (s === session && k !== realId) {
        staleKeys.push(k);
      }
    });
    for (let j = 0; j < staleKeys.length; j++) {
      this.sessions.delete(staleKeys[j]);
    }
    this.sessions.set(realId, session);
    let mprisCb = this.mprisListeners.get(realId);
    if (mprisCb) {
      session.setMprisChangeListener(mprisCb);
    }
    let listCb = this.mprisListListeners.get(realId);
    if (listCb) {
      session.setMprisPlayerListListener(listCb);
    }
    let volCb = this.systemVolumeListeners.get(realId);
    if (volCb) {
      session.setSystemVolumeChangeListener(volCb);
    }
    let kbCb = this.mousepadKeyboardListeners.get(realId);
    if (kbCb) {
      session.setMousepadKeyboardStateListener(kbCb);
    }
    let inCb = this.mousepadInputListeners.get(realId);
    if (inCb) {
      session.setMousepadInputListener(inCb);
    }
    let rcCb = this.runCommandListListeners.get(realId);
    if (rcCb) {
      session.setRunCommandListListener(rcCb);
    }
    let rcoCb = this.runCommandOutputListeners.get(realId);
    if (rcoCb) {
      session.setRunCommandOutputListener(rcoCb);
    }
    console.info(`[KDE-MVP] Session bound: ${realId} (total=${this.sessions.size})`);
  }

  /** IPs of peers with a live TLS session (for discover unicast skip). */
  public getLivePeerIps(): string[] {
    let ips: string[] = [];
    this.sessions.forEach((s: DeviceSession) => {
      if (!s.isSessionLive()) {
        return;
      }
      let peer = s.getPeer();
      if (peer && peer.ip && peer.ip.length > 0 && ips.indexOf(peer.ip) < 0) {
        ips.push(peer.ip);
      }
    });
    return ips;
  }

  public getOrCreateSession(deviceId: string): DeviceSession {
    let existing = this.sessions.get(deviceId);
    if (existing) {
      existing.configure(
        this.context,
        this.certPem,
        this.keyPem,
        this.myDeviceName,
        this.listenPort,
        this.nextBridgePort(),
        !existing.isSessionLive()
      );
      existing.setTrustedCache(this.trustedDeviceIds);
      return existing;
    }
    return this.createSession(deviceId);
  }

  public async startServer(): Promise<number> {
    if (this.started) {
      return this.listenPort;
    }
    await this.loadCerts();
    this.tcpServer = socket.constructTCPSocketServerInstance();

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
      this.emitHub('error', '无法绑定 1716-1764 TCP 端口');
      throw new Error('TCP bind failed');
    }

    this.started = true;
    this.tcpServer.on('connect', (client: socket.TCPSocketConnection) => {
      this.handleIncomingConnection(client);
    });
    this.emitHub('discovering', `TCP 监听 ${this.listenPort}，可同时连接多台设备…`);
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
      console.info('[KDE-MVP] Hub loaded device cert/key for TLS');
    } catch (e) {
      console.error('[KDE-MVP] Load cert failed:', JSON.stringify(e));
    }
  }

  private async handleIncomingConnection(client: socket.TCPSocketConnection): Promise<void> {
    let remoteAddr: string = '';
    try {
      remoteAddr = (await client.getRemoteAddress()).address ?? '';
    } catch (e) {
      console.warn('[KDE-MVP] Failed to get remote address:', JSON.stringify(e));
    }

    // Fast path: if we already have a live session from this IP, drop without
    // creating a pending session (avoids status flicker + socket churn).
    if (remoteAddr.length > 0 && this.hasLiveSessionFromIp(remoteAddr)) {
      console.info(`[KDE-MVP] Drop TCP from ${remoteAddr} — live session already exists`);
      try {
        client.close();
      } catch (_e) {
      }
      return;
    }

    const now: number = Date.now();
    const lastIp: number | undefined = this.lastConnTimeByIp[remoteAddr];
    if (lastIp !== undefined && (lastIp + KdeClient.CONN_RATE_MS > now)) {
      console.info('[KDE-MVP] Rate-limited duplicate TCP:', remoteAddr);
      try {
        client.close();
      } catch (_e) {
      }
      return;
    }
    this.lastConnTimeByIp[remoteAddr] = now;

    console.info(`[KDE-MVP] Incoming TCP (hub) from ${remoteAddr}`);

    // Pending session until identity packet binds a real deviceId
    const tempKey: string = `pending:${remoteAddr}:${now}`;
    const session: DeviceSession = this.createSession('');
    this.pendingSessions.set(tempKey, session);

    try {
      await session.acceptIncomingConnection(client);
      // Identity may already be bound after accept returns path is async — rebind now too
      this.rebindSessionIfNeeded(session);
      if (session.getBoundDeviceId().length > 0) {
        this.pendingSessions.delete(tempKey);
      }
    } catch (e) {
      console.error('[KDE-MVP] acceptIncoming failed:', JSON.stringify(e));
      this.pendingSessions.delete(tempKey);
      try {
        client.close();
      } catch (_e) {
      }
    }
  }

  private hasLiveSessionFromIp(ip: string): boolean {
    let found = false;
    this.sessions.forEach((s: DeviceSession) => {
      if (found || !s.isSessionLive()) {
        return;
      }
      let peer = s.getPeer();
      if (peer && peer.ip === ip) {
        found = true;
      }
    });
    return found;
  }

  public connectToDevice(device: KdeDevice): void {
    const session = this.getOrCreateSession(device.deviceId);
    session.connectToDevice(device);
  }

  public isPaired(): boolean {
    return this.getClient()?.isPaired() ?? false;
  }

  public isPairedDevice(deviceId: string): boolean {
    let s = this.sessions.get(deviceId);
    if (s) {
      return s.isPaired();
    }
    return this.trustedDeviceIds.has(deviceId) || DeviceStore.getInstance().isTrusted(deviceId);
  }

  public getPeer(): KdeDevice | null {
    return this.getClient()?.getPeer() ?? null;
  }

  public getPeerForDevice(deviceId: string): KdeDevice | null {
    return this.sessions.get(deviceId)?.getPeer() ?? null;
  }

  public getPeerBattery(): PeerBatteryInfo | null {
    return this.getClient()?.getPeerBattery() ?? null;
  }

  public getPeerBatteryForDevice(deviceId: string): PeerBatteryInfo | null {
    return this.sessions.get(deviceId)?.getPeerBattery() ?? null;
  }

  public stopFindMyPhone(): void {
    this.getClient()?.stopFindMyPhone();
  }

  public sendFindMyPhone(): void {
    this.getClient()?.sendFindMyPhone();
  }

  public sendFindMyPhoneTo(deviceId: string): void {
    this.sessions.get(deviceId)?.sendFindMyPhone();
  }

  public getMprisPlayer(): MprisPlayerState | null {
    return this.getClient()?.getMprisPlayer() ?? null;
  }

  public setMprisChangeListener(cb: (player: MprisPlayerState | null) => void): void {
    // Legacy: attach to first available session + remember for future sessions without id
    this.getClient()?.setMprisChangeListener(cb);
  }

  public setMprisChangeListenerForDevice(
    deviceId: string,
    cb: (player: MprisPlayerState | null) => void
  ): void {
    this.mprisListeners.set(deviceId, cb);
    this.sessions.get(deviceId)?.setMprisChangeListener(cb);
  }

  public setMprisPlayerListListenerForDevice(
    deviceId: string,
    cb: (names: string[]) => void
  ): void {
    this.mprisListListeners.set(deviceId, cb);
    this.sessions.get(deviceId)?.setMprisPlayerListListener(cb);
  }

  public getMprisPlayerListForDevice(deviceId: string): string[] {
    return this.sessions.get(deviceId)?.getMprisPlayerList() ?? [];
  }

  public selectMprisPlayerForDevice(deviceId: string, name: string): void {
    this.sessions.get(deviceId)?.selectMprisPlayer(name);
  }

  public mprisPlayPause(): void {
    this.getClient()?.mprisPlayPause();
  }

  public mprisStop(): void {
    this.getClient()?.mprisStop();
  }

  public mprisPrevious(): void {
    this.getClient()?.mprisPrevious();
  }

  public mprisNext(): void {
    this.getClient()?.mprisNext();
  }

  public mprisSetVolume(vol: number): void {
    this.getClient()?.mprisSetVolume(vol);
  }

  public mprisVolumeStep(stepPercent: number): void {
    this.getClient()?.mprisVolumeStep(stepPercent);
  }

  public mprisSeek(offsetUs: number): void {
    this.getClient()?.mprisSeek(offsetUs);
  }

  public mprisSetPosition(positionMs: number): void {
    this.getClient()?.mprisSetPosition(positionMs);
  }

  public mprisToggleLoop(): void {
    this.getClient()?.mprisToggleLoop();
  }

  public mprisToggleShuffle(): void {
    this.getClient()?.mprisToggleShuffle();
  }

  public requestMprisPlayerListForDevice(deviceId: string): void {
    this.sessions.get(deviceId)?.requestMprisPlayerList();
  }

  public mprisStopForDevice(deviceId: string): void {
    this.sessions.get(deviceId)?.mprisStop();
  }

  public mprisSeekForDevice(deviceId: string, offsetUs: number): void {
    this.sessions.get(deviceId)?.mprisSeek(offsetUs);
  }

  public mprisSetPositionForDevice(deviceId: string, positionMs: number): void {
    this.sessions.get(deviceId)?.mprisSetPosition(positionMs);
  }

  public mprisToggleLoopForDevice(deviceId: string): void {
    this.sessions.get(deviceId)?.mprisToggleLoop();
  }

  public mprisToggleShuffleForDevice(deviceId: string): void {
    this.sessions.get(deviceId)?.mprisToggleShuffle();
  }

  public mprisVolumeStepForDevice(deviceId: string, stepPercent: number): void {
    this.sessions.get(deviceId)?.mprisVolumeStep(stepPercent);
  }

  public mprisPlayPauseForDevice(deviceId: string): void {
    this.sessions.get(deviceId)?.mprisPlayPause();
  }

  public mprisPreviousForDevice(deviceId: string): void {
    this.sessions.get(deviceId)?.mprisPrevious();
  }

  public mprisNextForDevice(deviceId: string): void {
    this.sessions.get(deviceId)?.mprisNext();
  }

  public mprisSetVolumeForDevice(deviceId: string, vol: number): void {
    this.sessions.get(deviceId)?.mprisSetVolume(vol);
  }

  public setSystemVolumeChangeListenerForDevice(
    deviceId: string,
    cb: (sinks: SystemVolumeSink[]) => void
  ): void {
    this.systemVolumeListeners.set(deviceId, cb);
    this.sessions.get(deviceId)?.setSystemVolumeChangeListener(cb);
  }

  public getSystemVolumeSinksForDevice(deviceId: string): SystemVolumeSink[] {
    return this.sessions.get(deviceId)?.getSystemVolumeSinks() ?? [];
  }

  public requestSystemVolumeSinksForDevice(deviceId: string): void {
    this.sessions.get(deviceId)?.requestSystemVolumeSinks();
  }

  public setSystemVolumeForDevice(deviceId: string, name: string, volume: number): void {
    this.sessions.get(deviceId)?.setSystemVolume(name, volume);
  }

  public setSystemVolumeMuteForDevice(deviceId: string, name: string, muted: boolean): void {
    this.sessions.get(deviceId)?.setSystemVolumeMute(name, muted);
  }

  public setSystemVolumeDefaultForDevice(deviceId: string, name: string): void {
    this.sessions.get(deviceId)?.setSystemVolumeDefault(name);
  }

  // ── REMOTE INPUT (per-device) ────────────────────────────

  /** Send a raw mousepad packet to a device (Android MousePadPlugin.sendPacket). */
  public sendMousepadPacketTo(deviceId: string, body: KdeMousepadRequestBody): void {
    this.sessions.get(deviceId)?.sendMousepadPacket(body);
  }

  public sendMousepadDeltaTo(deviceId: string, dx: number, dy: number): void {
    this.sessions.get(deviceId)?.sendMousepadDelta(dx, dy);
  }

  public sendMousepadLeftClickTo(deviceId: string): void {
    this.sessions.get(deviceId)?.sendMousepadLeftClick();
  }

  public sendMousepadRightClickTo(deviceId: string): void {
    this.sessions.get(deviceId)?.sendMousepadRightClick();
  }

  public sendMousepadMiddleClickTo(deviceId: string): void {
    this.sessions.get(deviceId)?.sendMousepadMiddleClick();
  }

  public sendMousepadDoubleClickTo(deviceId: string): void {
    this.sessions.get(deviceId)?.sendMousepadDoubleClick();
  }

  public sendMousepadSingleHoldTo(deviceId: string): void {
    this.sessions.get(deviceId)?.sendMousepadSingleHold();
  }

  public sendMousepadSingleReleaseTo(deviceId: string): void {
    this.sessions.get(deviceId)?.sendMousepadSingleRelease();
  }

  public sendMousepadScrollTo(deviceId: string, dx: number, dy: number): void {
    this.sessions.get(deviceId)?.sendMousepadScroll(dx, dy);
  }

  public sendMousepadKeyTo(deviceId: string, text: string): void {
    this.sessions.get(deviceId)?.sendMousepadKey(text);
  }

  public sendMousepadSpecialKeyTo(
    deviceId: string,
    specialKey: number,
    modifiers: MousepadModifiers
  ): void {
    this.sessions.get(deviceId)?.sendMousepadSpecialKey(specialKey, modifiers);
  }

  public getMousepadKeyboardEnabledForDevice(deviceId: string): boolean {
    return this.sessions.get(deviceId)?.getMousepadKeyboardEnabled() ?? true;
  }

  public setMousepadKeyboardStateListenerForDevice(
    deviceId: string,
    cb: (enabled: boolean) => void
  ): void {
    this.mousepadKeyboardListeners.set(deviceId, cb);
    this.sessions.get(deviceId)?.setMousepadKeyboardStateListener(cb);
  }

  public setMousepadInputListenerForDevice(
    deviceId: string,
    cb: (info: MousepadInputInfo) => void
  ): void {
    this.mousepadInputListeners.set(deviceId, cb);
    this.sessions.get(deviceId)?.setMousepadInputListener(cb);
  }

  // ── REMOTE COMMAND (per-device, Android RunCommandPlugin) ──

  public setRunCommandListListenerForDevice(
    deviceId: string,
    cb: (entries: KdeRunCommandEntry[]) => void
  ): void {
    this.runCommandListListeners.set(deviceId, cb);
    this.sessions.get(deviceId)?.setRunCommandListListener(cb);
  }

  public setRunCommandOutputListenerForDevice(
    deviceId: string,
    cb: (event: RunCommandOutputEvent) => void
  ): void {
    this.runCommandOutputListeners.set(deviceId, cb);
    this.sessions.get(deviceId)?.setRunCommandOutputListener(cb);
  }

  public getRunCommandEntriesForDevice(deviceId: string): KdeRunCommandEntry[] {
    return this.sessions.get(deviceId)?.getRunCommandEntries() ?? [];
  }

  public getRunCommandCanAddForDevice(deviceId: string): boolean {
    return this.sessions.get(deviceId)?.getCanAddRemoteCommand() ?? false;
  }

  public requestRunCommandListForDevice(deviceId: string): void {
    this.sessions.get(deviceId)?.requestRunCommandList();
  }

  public runCommandOnDevice(deviceId: string, key: string): void {
    this.sessions.get(deviceId)?.runCommandOnPeer(key);
  }

  public setupRunCommandOnDevice(deviceId: string): void {
    this.sessions.get(deviceId)?.setupRunCommandOnPeer();
  }

  public stopRunCommandOnDevice(deviceId: string): void {
    this.sessions.get(deviceId)?.stopRunCommandOnPeer();
  }

  public async setupMprisReceiver(ctx: common.UIAbilityContext): Promise<void> {
    await this.getClient()?.setupMprisReceiver(ctx);
  }

  public teardownMprisReceiver(): void {
    this.sessions.forEach((s: DeviceSession) => {
      s.teardownMprisReceiver();
    });
  }

  public sendClipboardFromText(text: string): void {
    this.getClient()?.sendClipboardFromText(text);
  }

  public sendClipboardToDevice(deviceId: string, text: string): void {
    this.sessions.get(deviceId)?.sendClipboardFromText(text);
  }

  public sendPing(message: string = 'Hello from HarmonyOS'): void {
    this.getClient()?.sendPing(message);
  }

  public sendPingTo(deviceId: string, message: string = 'Hello from HarmonyOS'): void {
    this.sessions.get(deviceId)?.sendPing(message);
  }

  public requestPairing(): void {
    this.getClient()?.requestPairing();
  }

  public requestPairingFor(deviceId: string): void {
    this.sessions.get(deviceId)?.requestPairing();
  }

  public isPairRequestedByPeer(): boolean {
    return this.getClient()?.isPairRequestedByPeer() ?? false;
  }

  public isPairRequestedByPeerFor(deviceId: string): boolean {
    return this.sessions.get(deviceId)?.isPairRequestedByPeer() ?? false;
  }

  public acceptPairing(): void {
    // Accept on any session waiting for peer pair
    let found = false;
    this.sessions.forEach((s: DeviceSession) => {
      if (!found && s.isPairRequestedByPeer()) {
        s.acceptPairing();
        found = true;
      }
    });
    if (!found) {
      this.getClient()?.acceptPairing();
    }
  }

  public acceptPairingFor(deviceId: string): void {
    this.sessions.get(deviceId)?.acceptPairing();
  }

  public rejectPairing(): void {
    let found = false;
    this.sessions.forEach((s: DeviceSession) => {
      if (!found && s.isPairRequestedByPeer()) {
        s.rejectPairing();
        found = true;
      }
    });
    if (!found) {
      this.getClient()?.rejectPairing();
    }
  }

  public rejectPairingFor(deviceId: string): void {
    this.sessions.get(deviceId)?.rejectPairing();
  }

  public cancelPairingFor(deviceId: string): void {
    this.sessions.get(deviceId)?.cancelPairing();
  }

  public isPairRequestedFor(deviceId: string): boolean {
    return this.sessions.get(deviceId)?.isPairRequested() ?? false;
  }

  public getPairStateFor(deviceId: string): 'not_paired' | 'requested' | 'requested_by_peer' | 'paired' {
    return this.sessions.get(deviceId)?.getPairState() ?? 'not_paired';
  }

  public disconnect(): void {
    // Disconnect all live sessions (settings "clear" / legacy)
    this.sessions.forEach((s: DeviceSession) => {
      if (s.isSessionLive()) {
        s.disconnect();
      }
    });
  }

  public disconnectDevice(deviceId: string): void {
    this.sessions.get(deviceId)?.disconnect();
  }

  public async unpair(deviceId?: string): Promise<void> {
    if (deviceId && deviceId.length > 0) {
      let s = this.sessions.get(deviceId);
      if (s) {
        await s.unpair(deviceId);
      } else {
        this.trustedDeviceIds.delete(deviceId);
        await DeviceStore.getInstance().remove(deviceId);
        await PluginSettingsStore.getInstance().clearDevice(deviceId);
      }
      return;
    }
    await this.getClient()?.unpair(deviceId);
  }

  public isSessionLive(): boolean {
    let live = false;
    this.sessions.forEach((s: DeviceSession) => {
      if (s.isSessionLive()) {
        live = true;
      }
    });
    return live;
  }

  public isDeviceSessionActive(deviceId: string): boolean {
    return this.sessions.get(deviceId)?.isDeviceSessionActive(deviceId) ?? false;
  }

  public sendJson(json: string): void {
    this.getClient()?.sendJson(json);
  }

  public async sendPacketWithPayload(
    body: KdeShareRequestBody,
    filePath: string,
    onProgress?: (percent: number) => void
  ): Promise<void> {
    let s = this.getClient();
    if (!s) {
      throw new Error('Not connected');
    }
    return s.sendPacketWithPayload(body, filePath, onProgress);
  }

  public async sendPacketWithPayloadTo(
    deviceId: string,
    body: KdeShareRequestBody,
    filePath: string,
    onProgress?: (percent: number) => void
  ): Promise<void> {
    let s = this.sessions.get(deviceId);
    if (!s) {
      throw new Error('Not connected');
    }
    return s.sendPacketWithPayload(body, filePath, onProgress);
  }

  /** Cancel an inbound file transfer (notification cancel action). */
  public cancelIncomingTransfer(deviceId: string, jobId: string): void {
    const s: DeviceSession | null = this.sessions.get(deviceId) ?? null;
    if (!s) {
      console.warn('[KDE-MVP] cancelIncomingTransfer: no session for device');
      return;
    }
    s.cancelIncomingTransfer(jobId);
  }

  public stop(): void {
    this.sessions.forEach((s: DeviceSession) => {
      s.stop();
    });
    this.sessions.clear();
    this.pendingSessions.forEach((s: DeviceSession) => {
      s.stop();
    });
    this.pendingSessions.clear();
    try {
      this.tcpServer?.close();
    } catch (_e) {
    }
    this.tcpServer = null;
    this.started = false;
  }
}
