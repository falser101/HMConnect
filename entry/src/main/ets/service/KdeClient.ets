import socket from '@ohos.net.socket';
import deviceInfo from '@ohos.deviceInfo';
import pasteboard from '@ohos.pasteboard';
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import {
  KdeDevice,
  KdeIdentityBody,
  KdePairBody,
  KdeClipboardBody,
  KdePingBody,
  KdeBatteryBody,
  KdeShareRequestBody,
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
  sanitizeDeviceName,
  serializePacket,
  serializePacketWithPayload,
  parsePacketLine
} from './KdeTypes';
import { DeviceStore } from '../store/DeviceStore';
import { utf8Decode } from '../common/Utf8';
import { AppNotifier } from '../common/AppNotifier';
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

  private paired: boolean = false;
  private sessionLive: boolean = false; // TLS channel established (may not be paired yet)
  private peerDevice: KdeDevice | null = null;
  /** DeviceIds we have successfully paired with (persist for this app run). */
  private trustedDeviceIds: Set<string> = new Set();
  /** Avoid sending multiple pair:true while waiting for PC accept. */
  private pairRequestSentForGen: number = -1;
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
   * User tapped "连接": only reverse path is used for TLS.
   * Outbound TCP+TLS is NOT attempted — HarmonyOS can only be TLS client, but
   * outbound KDE role requires TLS server, which caused false "TLS 握手失败" UI.
   * We unicast identity so the PC connects back to our TCP server.
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
    this.emit(
      'connecting',
      this.isTrusted(device.deviceId)
        ? `已通知 ${device.deviceName} 重新连入…`
        : `已通知 ${device.deviceName}，等待电脑连入并确认配对…`,
      { peerName: device.deviceName, peerDeviceId: device.deviceId }
    );
    // Optional: plain TCP identity poke (no TLS) — helps some KDE builds notice us, then close.
    this.pokeOutboundIdentity(device);
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

  private handleIncomingConnection(client: socket.TCPSocketConnection): void {
    // While we already have a healthy encrypted session, drop duplicates.
    // Periodic UDP identity makes KDE Connect reconnect every few seconds.
    if (this.sessionLive && this.handlingIncoming === false) {
      console.info('[KDE-MVP] Reject concurrent TCP: session already live');
      try {
        client.close();
      } catch (_e) {
        // ignore
      }
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
          this.upgradeClientTls(this.bridgeLocalClient, peer, gen);
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
          this.upgradeClientTls(this.bridgeLocalClient!, peer, gen);
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
        // Report phone battery as soon as the channel is up (desktop shows it even pre-pair on some builds)
        this.startBatteryReporting();

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

        this.emit('connected', '已加密连接，请在电脑上点「接受」配对', {
          peerName: peer.deviceName,
          peerDeviceId: peer.deviceId
        });
        this.sendPairRequestOnce(gen, true);
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
        this.dispatchPacket(packet.type, packet.body);
      }
    } catch (e) {
      console.error('[KDE-MVP] TLS data parse error:', JSON.stringify(e));
    }
  }

  private dispatchPacket(type: string, body: object): void {
    console.info(`[KDE-MVP] Packet: ${type}`);
    if (type === 'kdeconnect.pair') {
      let pairBody = body as KdePairBody;
      if (pairBody.pair) {
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
        // Unpair / reject — only clear trust for current peer
        this.paired = false;
        if (this.peerDevice) {
          this.removeTrust(this.peerDevice.deviceId).catch(() => {
          });
        }
        this.pairRequestSentForGen = -1;
        this.notifySessionChange();
        this.emit('error', '配对被拒绝或已取消配对');
      }
      return;
    }

    if (type === 'kdeconnect.identity') {
      // post-TLS identity (protocol 8); accept quietly
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
  }

  /** Send local battery now and refresh every 60s while session is live. */
  private startBatteryReporting(): void {
    this.stopBatteryReporting();
    this.sendLocalBattery(true);
    this.batteryTimer = setInterval(() => {
      if (!this.sessionLive || !this.tlsSocket) {
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
    if (!this.tlsSocket || !this.sessionLive) {
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
    this.tlsSocket.send(json, (err) => {
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
    if (!this.tlsSocket || gen !== this.sessionGen) {
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
    this.tlsSocket.send(json, (err) => {
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
    if (!this.tlsSocket) {
      this.emit('error', '未连接，无法发送剪贴板');
      return;
    }
    let body: KdeClipboardBody = { content: text };
    let json: string = serializePacket('kdeconnect.clipboard', body);
    this.tlsSocket.send(json, (err) => {
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
    if (!this.tlsSocket) {
      this.emit('error', '未连接，无法 Ping');
      return;
    }
    let body: KdePingBody = { message: message };
    let json: string = serializePacket('kdeconnect.ping', body);
    this.tlsSocket.send(json, (err) => {
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

  /**
   * Drop live session but KEEP trust (paired list).
   */
  public disconnect(): void {
    this.sessionGen += 1;
    // Keep this.paired / trustedDeviceIds so list still shows as paired-offline
    this.sessionLive = false;
    this.handlingIncoming = false;
    this.pairRequestSentForGen = -1;
    this.lineBuffer = '';
    this.peerBattery = null;
    this.stopBatteryReporting();
    FindMyPhoneHelper.getInstance().stop();
    this.notifySessionChange();
    try {
      this.tlsSocket?.close();
    } catch (_e) {
      // ignore
    }
    this.tlsSocket = null;
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
    if (this.tlsSocket && this.sessionLive && id && this.peerDevice?.deviceId === id) {
      let body: KdePairBody = { pair: false };
      let json: string = serializePacket('kdeconnect.pair', body);
      try {
        await new Promise<void>((resolve) => {
          this.tlsSocket?.send(json, () => {
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
    try {
      this.tlsSocket?.close();
    } catch (_e) {
      // ignore
    }
    this.tlsSocket = null;
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

  // ── File transfer (dual-channel: JSON on main TLS, raw bytes on temp TCP) ──

  /**
   * Send a plain JSON packet (no payload) over the main TLS channel.
   */
  public sendJson(json: string): void {
    if (!this.tlsSocket) {
      console.warn('[KDE-MVP] sendJson: not connected');
      return;
    }
    this.tlsSocket.send(json, (err: Object) => {
      if (err) {
        console.error('[KDE-MVP] sendJson failed:', JSON.stringify(err));
      }
    });
  }

  private payloadPort: number = 0;
  private payloadServer: socket.TCPSocketServer | null = null;
  private payloadConnection: socket.TCPSocketConnection | null = null;

  /**
   * Find a free port in the payload range and start a TCP server on it.
   */
  private async openPayloadPort(): Promise<void> {
    for (let tryPort = PAYLOAD_TRANSFER_MIN_PORT; tryPort <= PAYLOAD_TRANSFER_MAX_PORT; tryPort++) {
      const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
      try {
        const address: socket.NetAddress = { address: '0.0.0.0', port: tryPort, family: 1 };
        await server.listen(address);
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
    throw new Error('No free payload port in range');
  }

  /**
   * Send a file using the dual-channel approach (matching Android LanLink.sendPacket).
   */
  public async sendPacketWithPayload(
    body: KdeShareRequestBody,
    filePath: string,
    onProgress?: (percent: number) => void
  ): Promise<void> {
    if (!this.tlsSocket) {
      throw new Error('Not connected');
    }

    // 1. Open payload TCP server
    await this.openPayloadPort();

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
      this.tlsSocket!.send(json, (err: Object) => {
        if (err) {
          reject(new Error('Main-channel send failed'));
        } else {
          resolve();
        }
      });
    });

    // 4. Wait for PC to connect (10 s timeout)
    const connected: socket.TCPSocketConnection = await new Promise<socket.TCPSocketConnection>(
      (resolve: (value: socket.TCPSocketConnection) => void, reject: (reason: Error) => void) => {
        const timeout: number = setTimeout(() => {
          reject(new Error('Payload connection timed out'));
        }, 10000) as number;

        this.payloadServer!.on('connect', (client: socket.TCPSocketConnection) => {
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
            connected.send({ data: chunk }, (err: Object) => {
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
