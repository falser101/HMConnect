import { common } from '@kit.AbilityKit';
import { KdeDiscover } from './KdeDiscover';
import { KdeClient } from './KdeClient';
import { FileSendJob } from './FileSendJob';
import {
  KdeDevice,
  KdeStatus,
  KdeShareRequestBody,
  DeviceListItem,
  DeviceRowStatus,
  PeerBatteryInfo,
  KDE_PROTOCOL_VERSION,
  MY_DEVICE_ID
} from './KdeTypes';
import { DeviceStore } from '../store/DeviceStore';

/**
 * Facade that wires discovery + session for the app.
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
    this.client.setSessionChangeListener((live: boolean, _paired: boolean) => {
      this.discover.setAnnouncePaused(live);
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
    // Defer to next microtask so @State mutations never happen during ArkUI render.
    // TLS message handlers fire in the same event-loop tick as build().
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
    // Prefer live peer; fall back to last status peer while connecting
    let peer = this.client.getPeer();
    let activeId: string | undefined = peer?.deviceId ?? this.lastStatus.peerDeviceId;
    let live: boolean = this.client.isSessionLive();
    let peerPaired: boolean = this.client.isPaired();
    let connecting: boolean =
      this.lastStatus.state === 'connecting' || this.lastStatus.state === 'tls_handshake';

    // Trusted first
    let trusted = DeviceStore.getInstance().getAll();
    for (let i = 0; i < trusted.length; i++) {
      let t = trusted[i];
      seen.add(t.deviceId);
      let online = this.discovered.has(t.deviceId);
      let disc = this.discovered.get(t.deviceId);
      // Session is "active" only while TLS is live with this exact device
      let sessionActive = live && activeId !== undefined && activeId === t.deviceId;
      let isTarget = activeId !== undefined && activeId === t.deviceId;
      let status: DeviceRowStatus = 'offline';
      let statusLabel = '已配对 · 离线';
      if (sessionActive && peerPaired) {
        status = 'paired';
        statusLabel = '已连接 · 已配对';
      } else if (sessionActive) {
        status = 'connected';
        statusLabel = '已连接';
      } else if (isTarget && connecting) {
        status = 'connecting';
        statusLabel = '连接中…';
      } else if (online) {
        status = 'available';
        statusLabel = '在线 · 可连接';
      }
      // Only the active peer may take name/IP from the live session — never apply
      // peer fields to other trusted devices (that made every row show peer #2's name).
      let name = t.deviceName;
      if (disc?.deviceName) {
        name = disc.deviceName;
      } else if (isTarget && peer?.deviceName) {
        name = peer.deviceName;
      }
      let ip = '';
      if (isTarget && peer?.ip) {
        ip = peer.ip;
      } else if (disc?.ip) {
        ip = disc.ip;
      } else {
        ip = t.lastIp ?? '';
      }
      let tcpPort = 1716;
      if (isTarget && peer?.tcpPort) {
        tcpPort = peer.tcpPort;
      } else if (disc?.tcpPort) {
        tcpPort = disc.tcpPort;
      } else if (t.lastTcpPort) {
        tcpPort = t.lastTcpPort;
      }
      let proto = KDE_PROTOCOL_VERSION;
      if (disc?.protocolVersion) {
        proto = disc.protocolVersion;
      } else if (isTarget && peer?.protocolVersion) {
        proto = peer.protocolVersion;
      }
      let peerBat: PeerBatteryInfo | undefined = undefined;
      if (sessionActive) {
        let b = this.client.getPeerBattery();
        if (b) {
          peerBat = b;
        }
      }
      // Reachable for UI: on LAN, active TLS session, or currently connecting to this peer.
      let reachable = online || sessionActive || (isTarget && connecting);
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
        peerBattery: peerBat
      });
    }

    // Available (discovered, not trusted)
    this.discovered.forEach((d: KdeDevice) => {
      if (seen.has(d.deviceId)) {
        return;
      }
      let sessionActive = live && activeId !== undefined && activeId === d.deviceId;
      let isTarget = activeId !== undefined && activeId === d.deviceId;
      let status: DeviceRowStatus = 'available';
      let statusLabel = '可配对';
      if (sessionActive && peerPaired) {
        status = 'paired';
        statusLabel = '已连接 · 已配对';
      } else if (sessionActive) {
        status = 'connected';
        statusLabel = '已连接 · 待配对';
      } else if (isTarget && connecting) {
        status = 'connecting';
        statusLabel = '连接中…';
      }
      let peerBat2: PeerBatteryInfo | undefined = undefined;
      if (sessionActive) {
        let b2 = this.client.getPeerBattery();
        if (b2) {
          peerBat2 = b2;
        }
      }
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
        peerBattery: peerBat2
      });
    });

    // If we have a live/connecting peer that is neither trusted nor currently in
    // the discovery map (announce paused), still surface it so list/detail agree.
    if (activeId && !seen.has(activeId) && peer && (live || connecting)) {
      let sessionActive = live;
      let status: DeviceRowStatus = sessionActive
        ? (peerPaired ? 'paired' : 'connected')
        : 'connecting';
      let statusLabel = sessionActive
        ? (peerPaired ? '已连接 · 已配对' : '已连接 · 待配对')
        : '连接中…';
      let peerBat3: PeerBatteryInfo | undefined = undefined;
      if (sessionActive) {
        let b3 = this.client.getPeerBattery();
        if (b3) {
          peerBat3 = b3;
        }
      }
      items.push({
        deviceId: peer.deviceId,
        deviceName: peer.deviceName,
        deviceType: peer.deviceType,
        ip: peer.ip,
        tcpPort: peer.tcpPort,
        protocolVersion: peer.protocolVersion,
        trusted: false,
        online: true,
        sessionActive: sessionActive,
        status: status,
        statusLabel: statusLabel,
        peerBattery: peerBat3
      });
    }

    return items;
  }

  public connect(device: KdeDevice): void {
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
      deviceType: item.deviceType
    };
    this.connect(d);
  }

  public sendClipboardText(text: string): void {
    this.client.sendClipboardFromText(text);
  }

  /** Expose client for pairing acceptance. */
  public getClient(): KdeClient {
    return this.client;
  }

  public getClientForDevice(_deviceId: string): KdeClient {
    return this.client;
  }

  /** User-initiated pair request. */
  public requestPairing(): void {
    this.client.requestPairing();
  }

  /** Whether peer has requested pairing (for UI). */
  public isPairRequestedByPeer(): boolean {
    return this.client.isPairRequestedByPeer();
  }

  /** Create a FileSendJob bound to this device session. */
  public createFileSendJob(): FileSendJob {
    return new FileSendJob(this.client);
  }

  /**
   * Send a file using dual-channel (JSON on main TLS, raw bytes on temp TCP).
   * @param body  Share-request metadata (filename, numberOfFiles, totalPayloadSize)
   * @param filePath  Absolute device path of the file to send
   * @param onProgress  Optional progress callback: (percent: 0-100) => void
   */
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

  public stopFindMyPhone(): void {
    this.client.stopFindMyPhone();
  }

  /** Make the remote device ring. */
  public sendRing(): void {
    this.client.sendFindMyPhone();
  }

  public getPeerBattery(): PeerBatteryInfo | null {
    return this.client.getPeerBattery();
  }

  public disconnect(): void {
    this.client.disconnect();
    this.discover.setAnnouncePaused(false);
    this.pushDeviceList();
  }

  public async unpair(deviceId: string): Promise<void> {
    await this.client.unpair(deviceId);
    this.discover.setAnnouncePaused(false);
    this.pushDeviceList();
  }

  /** After clearing DeviceStore, refresh client trust cache. */
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

  /** Full teardown — only on Ability destroy. */
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

  /** Network change → tell discover to re-announce + re-scan. */
  public onNetworkChange(): void {
    if (!this.started) {
      return;
    }
    console.info('[KdeService] onNetworkChange — triggering discover refresh');
    this.discover.onNetworkChange();
  }

  /** Re-announce on LAN (UI pull-to-refresh / toolbar refresh). */
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
