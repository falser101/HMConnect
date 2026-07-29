import { common } from '@kit.AbilityKit';
import { KdeDiscover } from './KdeDiscover';
import { KdeClient } from './KdeClient';
import { DeviceSession } from './DeviceSession';
import { FileSendJob } from './FileSendJob';
import {
  KdeDevice,
  KdeStatus,
  KdeShareRequestBody,
  DeviceListItem,
  DeviceRowStatus,
  PairUiState,
  PeerBatteryInfo,
  KDE_PROTOCOL_VERSION,
  MY_DEVICE_ID
} from './KdeTypes';
import { DeviceStore } from '../store/DeviceStore';
import { PluginSettingsStore } from '../store/PluginSettingsStore';

/**
 * Facade that wires discovery + multi-device sessions for the app.
 */
export class KdeService {
  private discover: KdeDiscover = new KdeDiscover();
  private client: KdeClient = new KdeClient();
  private started: boolean = false;
  private discovered: Map<string, KdeDevice> = new Map();
  private devicesCallback?: (items: DeviceListItem[]) => void;
  private statusCallback?: (status: KdeStatus) => void;
  private lastStatus: KdeStatus = { state: 'idle', message: '' };

  public async start(
    context: common.UIAbilityContext,
    onDevices: (items: DeviceListItem[]) => void,
    onStatus: (status: KdeStatus) => void
  ): Promise<void> {
    this.devicesCallback = onDevices;
    this.statusCallback = onStatus;

    if (this.started) {
      this.pushDeviceList();
      onStatus(this.lastStatus);
      return;
    }
    this.started = true;

    await DeviceStore.getInstance().init(context);
    await PluginSettingsStore.getInstance().init(context);
    this.client.setContext(context);
    this.client.loadTrustedFromStore();
    this.client.setStatusListener((status: KdeStatus) => {
      this.lastStatus = status;
      if (this.statusCallback) {
        const sc: (status: KdeStatus) => void = this.statusCallback;
        setTimeout(() => {
          if (this.statusCallback === sc) {
            sc(status);
          }
        }, 0);
      }
      this.pushDeviceList();
    });
    this.client.setSessionChangeListener((_live: boolean, _paired: boolean) => {
      // Keep broadcast for new devices, but skip unicast poke to already-live peers
      // so they don't reverse-connect every 8s and thrash our sessions.
      this.discover.setAnnouncePaused(false);
      this.discover.setConnectedPeerIps(this.client.getLivePeerIps());
      this.pushDeviceList();
    });

    let port: number = await this.client.startServer();
    this.discover.setTcpPort(port);
    this.discover.startListen((devices: KdeDevice[]) => {
      this.discovered.clear();
      for (let i = 0; i < devices.length; i++) {
        let d = devices[i];
        this.discovered.set(d.deviceId, d);
        if (DeviceStore.getInstance().isTrusted(d.deviceId)) {
          DeviceStore.getInstance().touchSeen(d.deviceId, d.ip, d.tcpPort, d.deviceName).catch(() => {
          });
        }
      }
      this.pushDeviceList();
    });

    this.lastStatus = { state: 'discovering', message: '正在搜索局域网设备…' };
    onStatus(this.lastStatus);
    this.pushDeviceList();
  }

  private pushDeviceList(): void {
    if (!this.devicesCallback) {
      return;
    }
    const cb: (items: DeviceListItem[]) => void = this.devicesCallback;
    const items: DeviceListItem[] = this.buildDeviceList();
    setTimeout(() => {
      if (this.devicesCallback === cb) {
        cb(items);
      }
    }, 0);
  }

  public buildDeviceList(): DeviceListItem[] {
    let items: DeviceListItem[] = [];
    let seen: Set<string> = new Set();
    let sessions = this.client.getSessions();
    let sessionById: Map<string, DeviceSession> = new Map();
    for (let i = 0; i < sessions.length; i++) {
      let s = sessions[i];
      let id = s.getBoundDeviceId();
      if (id.length > 0) {
        sessionById.set(id, s);
      }
    }

    // Connecting targets from last status (outbound in progress before TLS live)
    let connectingId: string | undefined =
      (this.lastStatus.state === 'connecting' || this.lastStatus.state === 'tls_handshake')
        ? this.lastStatus.peerDeviceId
        : undefined;

    // Trusted first
    let trusted = DeviceStore.getInstance().getAll();
    for (let i = 0; i < trusted.length; i++) {
      let t = trusted[i];
      seen.add(t.deviceId);
      let online = this.discovered.has(t.deviceId);
      let disc = this.discovered.get(t.deviceId);
      let sess = sessionById.get(t.deviceId);
      let sessionActive = sess !== undefined && sess.isSessionLive();
      let peerPaired = sess !== undefined && sess.isPaired();
      let isConnectingTarget = connectingId !== undefined && connectingId === t.deviceId && !sessionActive;
      // status is for list bucketing only; home UI shows name only (Android PairingScreen)
      let status: DeviceRowStatus = 'offline';
      let statusLabel = '';
      if (sessionActive && peerPaired) {
        status = 'paired';
      } else if (sessionActive) {
        status = 'connected';
      } else if (isConnectingTarget) {
        status = 'connecting';
      } else if (online) {
        status = 'available';
      }

      let peer = sess?.getPeer();
      let name = t.deviceName;
      if (disc?.deviceName) {
        name = disc.deviceName;
      } else if (peer?.deviceName) {
        name = peer.deviceName;
      }
      let ip = '';
      if (peer?.ip) {
        ip = peer.ip;
      } else if (disc?.ip) {
        ip = disc.ip;
      } else {
        ip = t.lastIp ?? '';
      }
      let tcpPort = 1716;
      if (peer?.tcpPort) {
        tcpPort = peer.tcpPort;
      } else if (disc?.tcpPort) {
        tcpPort = disc.tcpPort;
      } else if (t.lastTcpPort) {
        tcpPort = t.lastTcpPort;
      }
      let proto = KDE_PROTOCOL_VERSION;
      if (disc?.protocolVersion) {
        proto = disc.protocolVersion;
      } else if (peer?.protocolVersion) {
        proto = peer.protocolVersion;
      }
      let peerBat: PeerBatteryInfo | undefined = undefined;
      if (sessionActive && sess) {
        let b = sess.getPeerBattery();
        if (b) {
          peerBat = b;
        }
      }
      let pairState: PairUiState = sess ? sess.getPairState() : (online || sessionActive ? 'not_paired' : 'paired');
      if (!sess) {
        // Trusted offline → paired for UI; trusted online without session → not_paired until TLS
        pairState = 'paired';
      }
      let reachable = online || sessionActive || isConnectingTarget;
      const peerFromSess = sess?.getPeer();
      const incCaps = peerFromSess?.incomingCapabilities ?? disc?.incomingCapabilities;
      const outCaps = peerFromSess?.outgoingCapabilities ?? disc?.outgoingCapabilities;
      const vKey = sess ? sess.getVerificationKey() : '';
      items.push({
        deviceId: t.deviceId,
        deviceName: name,
        deviceType: disc?.deviceType ?? t.deviceType,
        ip: ip,
        tcpPort: tcpPort,
        protocolVersion: proto,
        trusted: true,
        online: reachable,
        sessionActive: sessionActive,
        status: status,
        statusLabel: statusLabel,
        peerBattery: peerBat,
        pairState: pairState,
        incomingCapabilities: incCaps,
        outgoingCapabilities: outCaps,
        verificationKey: vKey.length > 0 ? vKey : undefined
      });
    }

    // Available (discovered, not trusted)
    this.discovered.forEach((d: KdeDevice) => {
      if (seen.has(d.deviceId)) {
        return;
      }
      seen.add(d.deviceId);
      let sess = sessionById.get(d.deviceId);
      let sessionActive = sess !== undefined && sess.isSessionLive();
      let peerPaired = sess !== undefined && sess.isPaired();
      let isConnectingTarget = connectingId !== undefined && connectingId === d.deviceId && !sessionActive;
      let status: DeviceRowStatus = 'available';
      let statusLabel = '';
      if (sessionActive && peerPaired) {
        status = 'paired';
      } else if (sessionActive) {
        status = 'connected';
      } else if (isConnectingTarget) {
        status = 'connecting';
      }
      let peerBat2: PeerBatteryInfo | undefined = undefined;
      if (sessionActive && sess) {
        let b2 = sess.getPeerBattery();
        if (b2) {
          peerBat2 = b2;
        }
      }
      let pairState2: PairUiState = sess ? sess.getPairState() : 'not_paired';
      const peerFromSess2 = sess?.getPeer();
      const incCaps2 = peerFromSess2?.incomingCapabilities ?? d.incomingCapabilities;
      const outCaps2 = peerFromSess2?.outgoingCapabilities ?? d.outgoingCapabilities;
      const vKey2 = sess ? sess.getVerificationKey() : '';
      items.push({
        deviceId: d.deviceId,
        deviceName: d.deviceName,
        deviceType: d.deviceType,
        ip: d.ip,
        tcpPort: d.tcpPort,
        protocolVersion: d.protocolVersion,
        trusted: false,
        online: true,
        sessionActive: sessionActive,
        status: status,
        statusLabel: statusLabel,
        peerBattery: peerBat2,
        pairState: pairState2,
        incomingCapabilities: incCaps2,
        outgoingCapabilities: outCaps2,
        verificationKey: vKey2.length > 0 ? vKey2 : undefined
      });
    });

    // Sessions that are live but not in trusted/discovered (announce paused, etc.)
    sessionById.forEach((sess: DeviceSession, id: string) => {
      if (seen.has(id)) {
        return;
      }
      if (!sess.isSessionLive() && !(connectingId === id)) {
        return;
      }
      let peer = sess.getPeer();
      if (!peer) {
        return;
      }
      let sessionActive = sess.isSessionLive();
      let peerPaired = sess.isPaired();
      let status: DeviceRowStatus = sessionActive
        ? (peerPaired ? 'paired' : 'connected')
        : 'connecting';
      let statusLabel = '';
      let peerBat3: PeerBatteryInfo | undefined = undefined;
      if (sessionActive) {
        let b3 = sess.getPeerBattery();
        if (b3) {
          peerBat3 = b3;
        }
      }
      const vKey3 = sess.getVerificationKey();
      items.push({
        deviceId: peer.deviceId,
        deviceName: peer.deviceName,
        deviceType: peer.deviceType,
        ip: peer.ip,
        tcpPort: peer.tcpPort,
        protocolVersion: peer.protocolVersion,
        trusted: DeviceStore.getInstance().isTrusted(peer.deviceId),
        online: true,
        sessionActive: sessionActive,
        status: status,
        statusLabel: statusLabel,
        peerBattery: peerBat3,
        pairState: sess.getPairState(),
        incomingCapabilities: peer.incomingCapabilities,
        outgoingCapabilities: peer.outgoingCapabilities,
        verificationKey: vKey3.length > 0 ? vKey3 : undefined
      });
    });

    return items;
  }

  public connect(device: KdeDevice): void {
    // Never globally pause discovery permanently for multi-device
    this.discover.setAnnouncePaused(false);
    this.discover.requestReverseConnect(device);
    this.client.connectToDevice(device);
  }

  public connectListItem(item: DeviceListItem): void {
    let d: KdeDevice = {
      deviceId: item.deviceId,
      deviceName: item.deviceName,
      ip: item.ip,
      tcpPort: item.tcpPort,
      protocolVersion: item.protocolVersion,
      deviceType: item.deviceType,
      incomingCapabilities: item.incomingCapabilities,
      outgoingCapabilities: item.outgoingCapabilities
    };
    this.connect(d);
  }

  public sendClipboardText(text: string): void {
    this.client.sendClipboardFromText(text);
  }

  public sendClipboardTextTo(deviceId: string, text: string): void {
    this.client.sendClipboardToDevice(deviceId, text);
  }

  /** Hub (multi-session manager). */
  public getClient(): KdeClient {
    return this.client;
  }

  /** Per-device session for plugins / MPRIS / file send. */
  public getClientForDevice(deviceId: string): DeviceSession | null {
    return this.client.getClientForDevice(deviceId);
  }

  public requestPairing(): void {
    this.client.requestPairing();
  }

  public requestPairingFor(deviceId: string): void {
    this.client.requestPairingFor(deviceId);
  }

  public isPairRequestedByPeer(): boolean {
    return this.client.isPairRequestedByPeer();
  }

  public isPairRequestedByPeerFor(deviceId: string): boolean {
    return this.client.isPairRequestedByPeerFor(deviceId);
  }

  public cancelPairingFor(deviceId: string): void {
    this.client.cancelPairingFor(deviceId);
  }

  public isPairRequestedFor(deviceId: string): boolean {
    return this.client.isPairRequestedFor(deviceId);
  }

  public getPairStateFor(deviceId: string): PairUiState {
    return this.client.getPairStateFor(deviceId);
  }

  public createFileSendJob(): FileSendJob {
    let s = this.client.getClient();
    if (!s) {
      throw new Error('Not connected');
    }
    return new FileSendJob(s);
  }

  public createFileSendJobFor(deviceId: string): FileSendJob {
    let s = this.client.getClientForDevice(deviceId);
    if (!s) {
      throw new Error('Not connected');
    }
    return new FileSendJob(s);
  }

  public sendFileWithPayload(
    body: KdeShareRequestBody,
    filePath: string,
    onProgress?: (percent: number) => void
  ): Promise<void> {
    return this.client.sendPacketWithPayload(body, filePath, onProgress);
  }

  public sendPing(): void {
    this.client.sendPing();
  }

  public sendPingTo(deviceId: string): void {
    this.client.sendPingTo(deviceId);
  }

  public stopFindMyPhone(): void {
    this.client.stopFindMyPhone();
  }

  public sendRing(): void {
    this.client.sendFindMyPhone();
  }

  public sendRingTo(deviceId: string): void {
    this.client.sendFindMyPhoneTo(deviceId);
  }

  public getPeerBattery(): PeerBatteryInfo | null {
    return this.client.getPeerBattery();
  }

  public disconnect(): void {
    this.client.disconnect();
    this.pushDeviceList();
  }

  public disconnectDevice(deviceId: string): void {
    this.client.disconnectDevice(deviceId);
    this.pushDeviceList();
  }

  public async unpair(deviceId: string): Promise<void> {
    await this.client.unpair(deviceId);
    this.pushDeviceList();
  }

  public reloadTrustCache(): void {
    this.client.loadTrustedFromStore();
    this.pushDeviceList();
  }

  public getDeviceById(deviceId: string): DeviceListItem | undefined {
    let list = this.buildDeviceList();
    for (let i = 0; i < list.length; i++) {
      if (list[i].deviceId === deviceId) {
        return list[i];
      }
    }
    return undefined;
  }

  public stop(): void {
    this.discover.stopListen();
    this.client.stop();
    this.started = false;
  }

  public getMyName(): string {
    return this.discover.getMyDeviceName();
  }

  public getMyDeviceId(): string {
    return MY_DEVICE_ID;
  }

  public getLastStatus(): KdeStatus {
    return this.lastStatus;
  }

  public isStarted(): boolean {
    return this.started;
  }

  public onNetworkChange(): void {
    if (!this.started) {
      return;
    }
    console.info('[KdeService] onNetworkChange — triggering discover refresh');
    this.discover.onNetworkChange();
  }

  public forceRefresh(): void {
    if (!this.started) {
      return;
    }
    this.discover.broadcastIdentity();
    this.lastStatus = { state: 'discovering', message: '正在刷新设备列表…' };
    if (this.statusCallback) {
      this.statusCallback(this.lastStatus);
    }
    this.pushDeviceList();
  }
}
