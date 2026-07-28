/**
 * KDE Connect protocol shared types (MVP, protocol v7-compatible wire format).
 * Packets are newline-delimited JSON.
 */

export const KDE_UDP_PORT: number = 1716;
export const KDE_MIN_TCP_PORT: number = 1716;
export const KDE_MAX_TCP_PORT: number = 1764;
export const KDE_PROTOCOL_VERSION: number = 7;

/** Port range for temporary payload transfer sockets (Android: PAYLOAD_TRANSFER_MIN_PORT). */
export const PAYLOAD_TRANSFER_MIN_PORT: number = 1739;
export const PAYLOAD_TRANSFER_MAX_PORT: number = 1764;

/** Protocol packet type constants. */
export const PACKET_TYPE_SHARE_REQUEST: string = 'kdeconnect.share.request';
export const PACKET_TYPE_SHARE_REQUEST_UPDATE: string = 'kdeconnect.share.request.update';

/** Fixed MVP device id (must match CN of bundled TLS cert). */
export const MY_DEVICE_ID: string = 'a1b2c3d4e5f6789012345678abcdef01';

export const PACKET_TYPE_MPRIS: string = 'kdeconnect.mpris';
export const PACKET_TYPE_MPRIS_REQUEST: string = 'kdeconnect.mpris.request';

/** Packets this device can receive. */
export const INCOMING_CAPABILITIES: string[] = [
  'kdeconnect.clipboard',
  'kdeconnect.clipboard.connect',
  'kdeconnect.pair',
  'kdeconnect.ping',
  'kdeconnect.battery',
  'kdeconnect.findmyphone.request',
  'kdeconnect.share.request',
  'kdeconnect.mpris',
  'kdeconnect.mpris.request'
];

/** Packets this device can send. */
export const OUTGOING_CAPABILITIES: string[] = [
  'kdeconnect.clipboard',
  'kdeconnect.clipboard.connect',
  'kdeconnect.pair',
  'kdeconnect.ping',
  'kdeconnect.battery',
  'kdeconnect.share.request',
  'kdeconnect.mpris',
  'kdeconnect.mpris.request'
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

/** kdeconnect.share.request body — matches Android SharePlugin. */
export interface KdeShareRequestBody {
  filename?: string;
  numberOfFiles: number;
  totalPayloadSize: number;
  lastModified?: number;
  open?: boolean;
}

/** Per-file info used by FileSendJob before constructing packets. */
export interface FileSendInfo {
  uri: string;
  displayName: string;
  size: number;
  lastModified: number;
}

/** Payload transfer metadata sent in the JSON packet (Android: payloadTransferInfo). */
export interface PayloadTransferInfo {
  port: number;
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
  payloadSize?: number;
  payloadTransferInfo?: PayloadTransferInfo;
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

/**
 * Serialise a packet that carries a binary payload via side-channel.
 * Aligns with Android NetworkPacket.serialize() when payload is present.
 */
export function serializePacketWithPayload<T extends object>(
  type: string,
  body: T,
  payloadSize: number,
  payloadTransferInfo: PayloadTransferInfo
): string {
  // Use an explicit interface to satisfy ArkTS strict mode
  let obj: KdePacketWithPayload<T> = {
    id: makePacketId(),
    type: type,
    body: body,
    payloadSize: payloadSize,
    payloadTransferInfo: payloadTransferInfo
  };
  return JSON.stringify(obj) + '\n';
}

interface KdePacketWithPayload<T extends object> {
  id: number;
  type: string;
  body: T;
  payloadSize: number;
  payloadTransferInfo: PayloadTransferInfo;
}

export function parsePacketLine(line: string): KdePacket<object> | null {
  let trimmed: string = line.trim();
  if (trimmed.length === 0) {
    return null;
  }
  try {
    let raw: Record<string, Object> = JSON.parse(trimmed) as Record<string, Object>;
    if (!raw || typeof raw['type'] !== 'string') {
      return null;
    }
    let packet: KdePacket<object> = {
      id: typeof raw['id'] === 'number' ? raw['id'] as number : 0,
      type: raw['type'] as string,
      body: (raw['body'] ?? ({} as Record<string, Object>)) as object,
    };
    // Capture payload metadata when present (needed for kdeconnect.share.request)
    if (typeof raw['payloadSize'] === 'number') {
      packet.payloadSize = raw['payloadSize'] as number;
    }
    if (raw['payloadTransferInfo'] !== undefined && raw['payloadTransferInfo'] !== null) {
      let pti: Record<string, Object> = raw['payloadTransferInfo'] as Record<string, Object>;
      if (typeof pti['port'] === 'number') {
        packet.payloadTransferInfo = { port: pti['port'] as number };
      }
    }
    return packet;
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

/** MPRIS player state (mirrors Android MprisPlugin.MprisPlayer). */
export interface MprisPlayerState {
  player: string;
  title: string;
  artist: string;
  album: string;
  isPlaying: boolean;
  canPlay: boolean;
  canPause: boolean;
  canGoNext: boolean;
  canGoPrevious: boolean;
  canSeek: boolean;
  volume: number;
  length: number;  // ms
  pos: number;     // ms
  lastPositionTime: number;
  loopStatus: string;
  shuffle: boolean;
}
