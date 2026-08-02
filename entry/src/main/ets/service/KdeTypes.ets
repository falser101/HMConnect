/**
 * KDE Connect protocol shared types.
 * Wire format: newline-delimited JSON (protocol v8).
 */

export const KDE_UDP_PORT: number = 1716;
export const KDE_MIN_TCP_PORT: number = 1716;
export const KDE_MAX_TCP_PORT: number = 1764;
/** Align with Android DeviceHelper.PROTOCOL_VERSION. */
export const KDE_PROTOCOL_VERSION: number = 8;
/** Android PairingHandler.allowedTimestampDifferenceSeconds (±30 min). */
export const PAIR_TIMESTAMP_MAX_DIFF_SEC: number = 1800;

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

/** System volume control of remote sinks (Android SystemVolumePlugin). */
export const PACKET_TYPE_SYSTEMVOLUME: string = 'kdeconnect.systemvolume';
export const PACKET_TYPE_SYSTEMVOLUME_REQUEST: string = 'kdeconnect.systemvolume.request';

/** Receive notifications from peer (Android ReceiveNotificationsPlugin). */
export const PACKET_TYPE_NOTIFICATION: string = 'kdeconnect.notification';
export const PACKET_TYPE_NOTIFICATION_REQUEST: string = 'kdeconnect.notification.request';
export const PACKET_TYPE_NOTIFICATION_REPLY: string = 'kdeconnect.notification.reply';
export const PACKET_TYPE_NOTIFICATION_ACTION: string = 'kdeconnect.notification.action';

/**
 * Remote input (Android MousePadPlugin + MouseReceiverPlugin / RemoteKeyboardPlugin).
 * One packet type carries both directions; fields decide the meaning.
 */
export const PACKET_TYPE_MOUSEPAD_REQUEST: string = 'kdeconnect.mousepad.request';
/** Remote keyboard availability (state: boolean). */
export const PACKET_TYPE_MOUSEPAD_KEYBOARDSTATE: string = 'kdeconnect.mousepad.keyboardstate';
/** Key acknowledgement when sendAck=true (isAck=true). */
export const PACKET_TYPE_MOUSEPAD_ECHO: string = 'kdeconnect.mousepad.echo';

/** Remote command (Android RunCommandPlugin). */
export const PACKET_TYPE_RUNCOMMAND: string = 'kdeconnect.runcommand';
export const PACKET_TYPE_RUNCOMMAND_REQUEST: string = 'kdeconnect.runcommand.request';
export const PACKET_TYPE_RUNCOMMAND_OUTPUT: string = 'kdeconnect.runcommand.output';

/** Drawing tablet (Android DigitizerPlugin) — this device is the pen surface. */
export const PACKET_TYPE_DIGITIZER: string = 'kdeconnect.digitizer';
export const PACKET_TYPE_DIGITIZER_SESSION: string = 'kdeconnect.digitizer.session';

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
  'kdeconnect.mpris.request',
  // Control peer system volume (receive sink list / updates)
  PACKET_TYPE_SYSTEMVOLUME,
  // Receive peer notifications (receive-only; we do not forward our own)
  PACKET_TYPE_NOTIFICATION,
  // Remote input: desktop may send mouse/keyboard events; we reply keyboardstate
  PACKET_TYPE_MOUSEPAD_REQUEST,
  PACKET_TYPE_MOUSEPAD_KEYBOARDSTATE,
  PACKET_TYPE_MOUSEPAD_ECHO,
  // Remote command: receive the peer's command list + command output
  PACKET_TYPE_RUNCOMMAND,
  PACKET_TYPE_RUNCOMMAND_OUTPUT
];

/** Packets this device can send. */
export const OUTGOING_CAPABILITIES: string[] = [
  'kdeconnect.clipboard',
  'kdeconnect.clipboard.connect',
  'kdeconnect.pair',
  'kdeconnect.ping',
  'kdeconnect.battery',
  // Must advertise so Android loads FindMyPhonePlugin (pluginsForCapabilities
  // requires peer.outgoing ∩ Android supportedPacketTypes). Without this,
  // ring packets arrive but Android ignores them — no plugin registered.
  'kdeconnect.findmyphone.request',
  'kdeconnect.share.request',
  'kdeconnect.mpris',
  'kdeconnect.mpris.request',
  // Adjust peer system volume / mute / default sink
  PACKET_TYPE_SYSTEMVOLUME_REQUEST,
  // Ask peer to stream its notifications to us (receive-only sync)
  PACKET_TYPE_NOTIFICATION_REQUEST,
  // Remote input: we act as touchpad/keyboard for the desktop
  PACKET_TYPE_MOUSEPAD_REQUEST,
  PACKET_TYPE_MOUSEPAD_KEYBOARDSTATE,
  PACKET_TYPE_MOUSEPAD_ECHO,
  // Remote command: request list / run by key / setup / stop
  PACKET_TYPE_RUNCOMMAND_REQUEST
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
  /** Peer packets it can receive (from identity). Empty/undefined = unknown. */
  incomingCapabilities?: string[];
  /** Peer packets it can send (from identity). Empty/undefined = unknown. */
  outgoingCapabilities?: string[];
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

/**
 * Pairing UI state — Android PairingHandler.PairState.
 * not_paired | requested (we sent) | requested_by_peer | paired
 */
export type PairUiState = 'not_paired' | 'requested' | 'requested_by_peer' | 'paired';

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
  /** Live pairing state for this peer (Android PairingHandler). */
  pairState?: PairUiState;
  /** Peer identity capabilities (for plugin UI filter). */
  incomingCapabilities?: string[];
  outgoingCapabilities?: string[];
  /**
   * Pairing verification code (Android pairVerification).
   * Non-empty only while pairState is requested / requested_by_peer.
   */
  verificationKey?: string;
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
  /** SharePlugin receiveText — peer shared a text snippet. */
  text?: string;
  /** SharePlugin receiveUrl — peer shared a link. */
  url?: string;
}

/** Per-file info used by FileSendJob before constructing packets. */
export interface FileSendInfo {
  uri: string;
  displayName: string;
  size: number;
  lastModified: number;
}

/** Direction of a file transfer (Android CompositeUploadFileJob / CompositeReceiveFileJob). */
export type FileTransferRole = 'send' | 'receive';

/** Shared cancel flag between UI / notification action and the transfer loop. */
export interface TransferCancelToken {
  cancelled: boolean;
}

/** Progress payload for the ongoing transfer notification (Android Upload/ReceiveNotification). */
export interface FileTransferNotifyInfo {
  role: FileTransferRole;
  jobId: string;
  deviceName: string;
  /** Peer device id — used by the notification cancel action to find the session. */
  deviceId: string;
  fileName: string;
  fileIndex: number;
  totalFiles: number;
  percent: number;
}

/** Result payload for the finished / failed transfer notification. */
export interface FileTransferResultInfo {
  role: FileTransferRole;
  jobId: string;
  deviceName: string;
  deviceId: string;
  numFiles: number;
  totalFiles: number;
  /** Last received file name — enables open/share actions (Android setURI). */
  fileName?: string;
  /** Last received file path — enables open/share actions (Android setURI). */
  filePath?: string;
}

/** Payload transfer metadata sent in the JSON packet (Android: payloadTransferInfo). */
export interface PayloadTransferInfo {
  port: number;
}

/**
 * kdeconnect.notification body (Android NotificationsPlugin → ReceiveNotificationsPlugin).
 * Cancel packets may only set id + isCancel.
 */
/** kdeconnect.notification body (Android NotificationsPlugin.sendNotification). */
export interface KdeNotificationBody {
  id?: string;
  appName?: string;
  ticker?: string;
  title?: string;
  text?: string;
  time?: string;
  silent?: boolean;
  isCancel?: boolean;
  isClearable?: boolean;
  /** MD5 of the app-icon payload (Android NotificationPlugin payloadHash). */
  payloadHash?: string;
  /** Non-reply action titles (Android extractActions → JSONArray of strings). */
  actions?: string[];
  /** Reply action id (Android requestReplyId) — enables inline quick-reply. */
  requestReplyId?: string;
  /** Present on request packets when embedded in notification.request. */
  request?: boolean;
  cancel?: string;
}

/** kdeconnect.notification.request body. */
export interface KdeNotificationRequestBody {
  request?: boolean;
  cancel?: string;
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

/**
 * MPRIS player state (mirrors Android MprisPlugin.MprisPlayer).
 * length/pos: milliseconds. Seek command uses microseconds.
 */
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
  /** Player volume 0–100; -1 means setVolume not allowed (Android isSetVolumeAllowed). */
  volume: number;
  length: number;  // ms
  pos: number;     // ms
  lastPositionTime: number;
  /** "None" | "Track" | "Playlist" (empty until peer reports). */
  loopStatus: string;
  /** True once peer has sent loopStatus at least once. */
  loopStatusAllowed: boolean;
  shuffle: boolean;
  /** True once peer has sent shuffle at least once. */
  shuffleAllowed: boolean;
  /** Remote album art URL (http/https/file/kdeconnect). */
  albumArtUrl: string;
  /** Local file path after payload transfer (optional). */
  albumArtLocalPath: string;
  /** Player media URL (Android MprisPlayer.url) — used for continue-watching. */
  url: string;
  /** Epoch ms when playback last started (Android MprisPlayer.playStartTime). */
  playStartTime: number;
}

/** Default Seek offset: 10s in microseconds (Android mpris_time_default). */
export const MPRIS_DEFAULT_SEEK_US: number = 10000000;

/** Remote audio sink (mirrors Android systemvolume.Sink). */
export interface SystemVolumeSink {
  name: string;
  description: string;
  volume: number;
  maxVolume: number;
  muted: boolean;
  /** true = default/enabled output (Pulse/Windows "enabled"). */
  enabled: boolean;
}

/**
 * kdeconnect.mousepad.request body — mirrors Android MousePadPlugin /
 * MouseReceiverPlugin / RemoteKeyboardPlugin field-for-field.
 * All fields optional; the receiver decides meaning by which are present.
 */
export interface KdeMousepadRequestBody {
  dx?: number;
  dy?: number;
  x?: number;
  y?: number;
  singleclick?: boolean;
  doubleclick?: boolean;
  middleclick?: boolean;
  rightclick?: boolean;
  forwardclick?: boolean;
  backclick?: boolean;
  singlehold?: boolean;
  singlerelease?: boolean;
  scroll?: boolean;
  key?: string;
  specialKey?: number;
  shift?: boolean;
  ctrl?: boolean;
  alt?: boolean;
  super?: boolean;
  sendAck?: boolean;
}

/** kdeconnect.mousepad.keyboardstate body (remote keyboard availability). */
export interface KdeMousepadKeyboardStateBody {
  state: boolean;
}

/** kdeconnect.mousepad.echo body — key acknowledgement (isAck=true). */
export interface KdeMousepadEchoBody {
  key?: string;
  specialKey?: number;
  shift?: boolean;
  ctrl?: boolean;
  alt?: boolean;
  isAck: boolean;
}

/** Modifier keys carried on specialKey packets (Android KeyEvent modifiers). */
export interface MousepadModifiers {
  shift?: boolean;
  ctrl?: boolean;
  alt?: boolean;
  super?: boolean;
}

/** Parsed remote-input event delivered to UI listeners (receiver direction). */
export interface MousepadInputInfo {
  /** singleclick | doubleclick | middleclick | rightclick | hold | release | scroll | move | key */
  kind: string;
  dx?: number;
  dy?: number;
  button?: string;
  key?: string;
  specialKey?: number;
}

/**
 * kdeconnect.runcommand.request body — mirrors Android RunCommandPlugin.
 * We are the controller: we ask for the peer's list, run a preset by key,
 * open its config UI (setup) or stop the running command.
 */
export interface KdeRunCommandRequestBody {
  /** Ask the peer to resend its command list. */
  requestCommandList?: boolean;
  /** Run a command on the peer by its preset key. */
  key?: string;
  /** Ask the peer to open its runcommand configuration UI. */
  setup?: boolean;
  /** Ask the peer to terminate the currently running command. */
  stop?: boolean;
}

/** One preset command advertised by the peer (name + command). */
export interface KdeRunCommandEntry {
  key: string;
  name: string;
  command: string;
}

/** kdeconnect.runcommand body — the peer's command list. */
export interface KdeRunCommandListBody {
  /** JSON map "key" → { name, command } (Android RunCommandPlugin commandList). */
  commandList?: string;
  /** True when the peer can open its config UI on setup. */
  canAddCommand?: boolean;
}

/** kdeconnect.runcommand.output body — streaming command output. */
export interface KdeRunCommandOutputBody {
  stdout?: string[];
  stderr?: string[];
  commandFinished?: boolean;
}

/** RunCommand page stream event: one output line or the finished marker. */
export interface RunCommandOutputEvent {
  line: string;
  isError: boolean;
  finished: boolean;
}

/** kdeconnect.digitizer.session body (Android DigitizerPlugin.startSession/endSession). */
export interface KdeDigitizerSessionBody {
  /** 'start' or 'end'. */
  action: string;
  /** Drawing surface width in px (start only). */
  width?: number;
  /** Drawing surface height in px (start only). */
  height?: number;
  /** Display density, dots per millimeter (start only). */
  resolutionX?: number;
  resolutionY?: number;
}

/** kdeconnect.digitizer body — one pen/touch event (Android DigitizerPlugin.reportEvent). */
export interface KdeDigitizerEventBody {
  /** Tool tracking state (false on lift). */
  active?: boolean;
  /** True while the tool contacts the surface. */
  touching?: boolean;
  /** 'Pen' or 'Rubber'. */
  tool?: string;
  /** X in px on the drawing surface. */
  x?: number;
  y?: number;
  /** Pressure, 0.0–1.0 (Android reports 1.0 for fingers). */
  pressure?: number;
}

/** Per-packet-type counters for the plugin stats dialog (Android DeviceStats). */
export interface PacketStatCount {
  packetType: string;
  received: number;
  sentOk: number;
  sentFail: number;
  total: number;
}

/**
 * KDE Connect remote-input special key numbering
 * (Android KeyListenerView.SpecialKeysMap). 1=DEL, 2=TAB, (3 unused),
 * 4..7=arrows, 8=PAGE_UP, 9=PAGE_DOWN, 10=HOME, 11=END, 12=ENTER,
 * 13=FORWARD_DEL, 14=ESC, 15=PRINTSCREEN, 16=SCROLL_LOCK, 21..32=F1..F12.
 */
export const MOUSEPAD_SPECIAL_KEY_DEL: number = 1;
export const MOUSEPAD_SPECIAL_KEY_TAB: number = 2;
export const MOUSEPAD_SPECIAL_KEY_LEFT: number = 4;
export const MOUSEPAD_SPECIAL_KEY_UP: number = 5;
export const MOUSEPAD_SPECIAL_KEY_RIGHT: number = 6;
export const MOUSEPAD_SPECIAL_KEY_DOWN: number = 7;
export const MOUSEPAD_SPECIAL_KEY_PAGE_UP: number = 8;
export const MOUSEPAD_SPECIAL_KEY_PAGE_DOWN: number = 9;
export const MOUSEPAD_SPECIAL_KEY_HOME: number = 10;
export const MOUSEPAD_SPECIAL_KEY_END: number = 11;
export const MOUSEPAD_SPECIAL_KEY_ENTER: number = 12;
export const MOUSEPAD_SPECIAL_KEY_FORWARD_DEL: number = 13;
export const MOUSEPAD_SPECIAL_KEY_ESC: number = 14;
export const MOUSEPAD_SPECIAL_KEY_PRINTSCREEN: number = 15;
export const MOUSEPAD_SPECIAL_KEY_SCROLL_LOCK: number = 16;
export const MOUSEPAD_SPECIAL_KEY_F1: number = 21;
export const MOUSEPAD_SPECIAL_KEY_F12: number = 32;
