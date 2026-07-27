import socket from '@ohos.net.socket';
import deviceInfo from '@ohos.deviceInfo';
import {
  KdeDevice,
  KdeIdentityBody,
  KDE_UDP_PORT,
  KDE_PROTOCOL_VERSION,
  MY_DEVICE_ID,
  INCOMING_CAPABILITIES,
  OUTGOING_CAPABILITIES,
  sanitizeDeviceName,
  serializePacket,
  parsePacketLine
} from './KdeTypes';
import { utf8Decode } from '../common/Utf8';

/**
 * LAN discovery for KDE Connect:
 * - Listen UDP 1716 for peer identity broadcasts
 * - Periodically announce our identity (broadcast + unicast to known peers)
 */
export class KdeDiscover {
  private udpSocket: socket.UDPSocket | null = null;
  private discoveredDevices: Map<string, KdeDevice> = new Map();
  private onDeviceFoundCallback?: (devices: KdeDevice[]) => void;
  private broadcastTimer: number = -1;
  private tcpPort: number = KDE_UDP_PORT;
  private myDeviceName: string =
    sanitizeDeviceName(deviceInfo.marketName || deviceInfo.productModel || 'HarmonyOS Device');
  private running: boolean = false;
  private broadcastEnabled: boolean = false;
  /** When true, skip periodic announce (already paired / session live). */
  private announcePaused: boolean = false;

  public setTcpPort(port: number): void {
    this.tcpPort = port;
  }

  /** Pause/resume periodic identity announce to avoid PC reconnect storms. */
  public setAnnouncePaused(paused: boolean): void {
    this.announcePaused = paused;
    console.info(`[KDE-MVP] UDP announce paused=${paused}`);
  }

  public getMyDeviceName(): string {
    return this.myDeviceName;
  }

  public startListen(onDeviceFound: (devices: KdeDevice[]) => void): void {
    this.onDeviceFoundCallback = onDeviceFound;
    if (this.running) {
      return;
    }
    this.running = true;
    this.udpSocket = socket.constructUDPSocketInstance();

    let bindAddr: socket.NetAddress = {
      address: '0.0.0.0',
      port: KDE_UDP_PORT,
      family: 1
    };

    this.udpSocket.bind(bindAddr, (err) => {
      if (err) {
        console.error('[KDE-MVP] UDP Bind Failed:', JSON.stringify(err));
        this.tryBindAlternate();
        return;
      }
      console.info(`[KDE-MVP] UDP listening on ${KDE_UDP_PORT}`);
      this.enableBroadcastAndStart();
    });
  }

  private tryBindAlternate(): void {
    if (!this.udpSocket) {
      this.udpSocket = socket.constructUDPSocketInstance();
    }
    this.udpSocket.bind({ address: '0.0.0.0', port: 0, family: 1 }, (err2) => {
      if (err2) {
        console.error('[KDE-MVP] UDP ephemeral bind failed:', JSON.stringify(err2));
        return;
      }
      console.warn('[KDE-MVP] UDP bound to ephemeral port; only outbound announce available');
      this.enableBroadcastAndStart();
    });
  }

  private enableBroadcastAndStart(): void {
    if (!this.udpSocket) {
      return;
    }
    // Required for 255.255.255.255; without it send returns errno 13 Permission denied
    this.udpSocket.setExtraOptions({ broadcast: true }, (optErr) => {
      if (optErr) {
        console.warn('[KDE-MVP] enable UDP broadcast failed, will unicast only:', JSON.stringify(optErr));
        this.broadcastEnabled = false;
      } else {
        this.broadcastEnabled = true;
        console.info('[KDE-MVP] UDP broadcast enabled');
      }
      this.wireMessageHandler();
      this.startBroadcastLoop();
    });
  }

  private wireMessageHandler(): void {
    this.udpSocket?.on('message', (value: socket.SocketMessageInfo) => {
      try {
        let str: string = utf8Decode(new Uint8Array(value.message));
        let lines: string[] = str.split('\n');
        for (let i = 0; i < lines.length; i++) {
          let packet = parsePacketLine(lines[i]);
          if (!packet || packet.type !== 'kdeconnect.identity') {
            continue;
          }
          let body = packet.body as KdeIdentityBody;
          if (!body || !body.deviceId || body.deviceId === MY_DEVICE_ID) {
            continue;
          }

          let device: KdeDevice = {
            deviceId: body.deviceId,
            deviceName: sanitizeDeviceName(body.deviceName ?? '未知设备'),
            ip: value.remoteInfo.address,
            tcpPort: body.tcpPort ?? KDE_UDP_PORT,
            protocolVersion: body.protocolVersion ?? KDE_PROTOCOL_VERSION,
            deviceType: body.deviceType ?? 'desktop'
          };

          let existed = this.discoveredDevices.has(device.deviceId);
          this.discoveredDevices.set(device.deviceId, device);
          if (this.onDeviceFoundCallback) {
            this.onDeviceFoundCallback(Array.from(this.discoveredDevices.values()));
          }
          if (!existed) {
            console.info(`[KDE-MVP] Found device: ${device.deviceName} ${device.ip}:${device.tcpPort}`);
          }
        }
      } catch (e) {
        console.error('[KDE-MVP] Parse UDP packet error:', JSON.stringify(e));
      }
    });
  }

  private startBroadcastLoop(): void {
    this.broadcastIdentity();
    this.broadcastTimer = setInterval(() => {
      this.broadcastIdentity();
    }, 8000) as number;
  }

  public broadcastIdentity(targetIp?: string): void {
    if (!this.udpSocket) {
      return;
    }
    // Explicit unicast (user connect) always allowed; periodic announce may pause
    if (!targetIp && this.announcePaused) {
      return;
    }

    let body: KdeIdentityBody = {
      deviceId: MY_DEVICE_ID,
      deviceName: this.myDeviceName,
      deviceType: 'phone',
      protocolVersion: KDE_PROTOCOL_VERSION,
      tcpPort: this.tcpPort,
      incomingCapabilities: INCOMING_CAPABILITIES,
      outgoingCapabilities: OUTGOING_CAPABILITIES
    };
    let payload: string = serializePacket('kdeconnect.identity', body);

    let destinations: string[] = [];
    if (targetIp) {
      destinations.push(targetIp);
    } else {
      if (this.broadcastEnabled) {
        destinations.push('255.255.255.255');
      }
      // Always unicast to known peers (works even when broadcast is denied)
      this.discoveredDevices.forEach((d: KdeDevice) => {
        if (destinations.indexOf(d.ip) < 0) {
          destinations.push(d.ip);
        }
      });
    }

    if (destinations.length === 0) {
      // No peers yet and broadcast off — silent
      return;
    }

    for (let i = 0; i < destinations.length; i++) {
      this.sendUdp(destinations[i], payload);
    }
  }

  private sendUdp(dest: string, payload: string): void {
    if (!this.udpSocket) {
      return;
    }
    let options: socket.UDPSendOptions = {
      data: payload,
      address: {
        address: dest,
        port: KDE_UDP_PORT,
        family: 1
      }
    };
    this.udpSocket.send(options, (err) => {
      if (err) {
        // Downgrade noise: broadcast failure is common if option not applied yet
        console.warn(`[KDE-MVP] UDP send to ${dest} failed:`, JSON.stringify(err));
      } else {
        console.info(`[KDE-MVP] UDP identity → ${dest}:${KDE_UDP_PORT}`);
      }
    });
  }

  /** Unicast identity to a PC to trigger reverse TCP connection. */
  public requestReverseConnect(device: KdeDevice): void {
    this.broadcastIdentity(device.ip);
  }

  /** Network change callback: fire an immediate announce so peers see us. */
  public onNetworkChange(): void {
    if (!this.running) {
      return;
    }
    console.info('[KdeDiscover] onNetworkChange — re-announcing');
    this.broadcastIdentity();
  }

  public stopListen(): void {
    this.running = false;
    if (this.broadcastTimer !== -1) {
      clearInterval(this.broadcastTimer);
      this.broadcastTimer = -1;
    }
    if (this.udpSocket) {
      try {
        this.udpSocket.close();
      } catch (_e) {
        // ignore
      }
      this.udpSocket = null;
    }
  }
}
