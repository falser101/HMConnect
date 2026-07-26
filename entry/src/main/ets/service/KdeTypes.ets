/**
 * KDE Connect protocol shared types (MVP, protocol v7-compatible wire format).
 * Packets are newline-delimited JSON.
 */

export const KDE_UDP_PORT: number = 1716;
export const KDE_MIN_TCP_PORT: number = 1716;
export const KDE_MAX_TCP_PORT: number = 1764;
export const KDE_PROTOCOL_VERSION: number = 7;

/** Fixed MVP device id (must match CN of bundled TLS cert). */
export const MY_DEVICE_ID: string = 'a1b2c3d4e5f6789012345678abcdef01';

/** Packets this device can receive. */
export const INCOMING_CAPABILITIES: string[] = [
  'kdeconnect.clipboard',
  'kdeconnect.clipboard.connect',
  'kdeconnect.pair',
  'kdeconnect.ping',
  'kdeconnect.battery',
  'kdeconnect.findmyphone.request'
];

/** Packets this device can send. */
export const OUTGOING_CAPABILITIES: string[] = [
  'kdeconnect.clipboard',
  'kdeconnect.clipboard.connect',
  'kdeconnect.pair',
  'kdeconnect.ping',
  'kdeconnect.battery'
];

/** @deprecated use INCOMING/OUTGOING; kept for any leftover imports. */
export const CAPABILITIES: string[] = INCOMING_CAPABILITIES;

export interface KdeDevice {
  deviceId: string;
  deviceName: string;
  ip: string;
  tcpPort: number;
  protocolVersion: number;
  deviceType: string;
}

/** Persisted paired device (trust). */
export interface TrustedDevice {
  deviceId: string;
  deviceName: string;
  deviceType: string;
  lastIp?: string;
  lastTcpPort?: number;
  lastSeenAt: number;
  pairedAt: number;
}

/** UI list row: merge of discovery + trust + session. */
export type DeviceRowStatus = 'available' | 'offline' | 'connecting' | 'connected' | 'paired';

export interface DeviceListItem {
  deviceId: string;
  deviceName: string;
  deviceType: string;
  ip: string;
  tcpPort: number;
  protocolVersion: number;
  trusted: boolean;
  online: boolean;
  sessionActive: boolean;
  status: DeviceRowStatus;
  statusLabel: string;
  /** Remote (desktop) battery when session is active with this device. */
  peerBattery?: PeerBatteryInfo;
}

export interface KdeIdentityBody {
  deviceId: string;
  deviceName?: string;
  deviceType?: string;
  protocolVersion: number;
  tcpPort?: number;
  incomingCapabilities?: string[];
  outgoingCapabilities?: string[];
  targetDeviceId?: string;
  targetProtocolVersion?: number;
}

export interface KdePairBody {
  pair: boolean;
  timestamp?: number;
}

export interface KdeClipboardBody {
  content: string;
}

export interface KdePingBody {
  message?: string;
}

/** kdeconnect.battery body (phone ↔ desktop). */
export interface KdeBatteryBody {
  currentCharge: number;
  isCharging: boolean;
  thresholdEvent?: number;
  batteryQuantity?: number;
}

/** Empty body for find-my-phone request from desktop. */
export interface KdeFindMyPhoneBody {
}

export interface PeerBatteryInfo {
  currentCharge: number;
  isCharging: boolean;
  thresholdEvent: number;
}

export interface KdePacket<T> {
  id: number;
  type: string;
  body: T;
}

export type ConnectionState =
  | 'idle'
  | 'discovering'
  | 'connecting'
  | 'tls_handshake'
  | 'connected'
  | 'paired'
  | 'error';

export interface KdeStatus {
  state: ConnectionState;
  message: string;
  peerName?: string;
  peerDeviceId?: string;
  lastClipboard?: string;
  peerBattery?: PeerBatteryInfo;
}

export function makePacketId(): number {
  return Date.now();
}

export function serializePacket<T>(type: string, body: T): string {
  let packet: KdePacket<T> = {
    id: makePacketId(),
    type: type,
    body: body
  };
  return JSON.stringify(packet) + '\n';
}

export function parsePacketLine(line: string): KdePacket<object> | null {
  let trimmed: string = line.trim();
  if (trimmed.length === 0) {
    return null;
  }
  try {
    let obj = JSON.parse(trimmed) as KdePacket<object>;
    if (obj && typeof obj.type === 'string') {
      return obj;
    }
  } catch (_e) {
    // ignore non-json (e.g. TLS binary noise)
  }
  return null;
}

export function sanitizeDeviceName(name: string): string {
  // Protocol: 1-32 chars, no " ',;:.!?()[]<>
  let cleaned: string = name.replace(/["',;:.!?()\[\]<>]/g, '');
  if (cleaned.length === 0) {
    cleaned = 'HarmonyOS';
  }
  if (cleaned.length > 32) {
    cleaned = cleaned.substring(0, 32);
  }
  return cleaned;
}
