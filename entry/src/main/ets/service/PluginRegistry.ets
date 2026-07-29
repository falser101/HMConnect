/**
 * Lightweight plugin catalog — mirrors Android PluginFactory metadata
 * without a full Plugin OOP hierarchy.
 *
 * Keys are stable preference ids (not Android class names).
 */

export const PLUGIN_CLIPBOARD: string = 'clipboard';
export const PLUGIN_SHARE: string = 'share';
export const PLUGIN_MPRIS: string = 'mpris';
export const PLUGIN_PING: string = 'ping';
export const PLUGIN_BATTERY: string = 'battery';
export const PLUGIN_FIND_MY_PHONE: string = 'findmyphone';

export interface PluginMeta {
  key: string;
  enabledByDefault: boolean;
  /** Packet types this plugin receives. */
  incomingTypes: string[];
  /** Packet types this plugin may send. */
  outgoingTypes: string[];
}

/** Implemented plugins shown in per-device plugin settings. */
export const IMPLEMENTED_PLUGINS: PluginMeta[] = [
  {
    key: PLUGIN_CLIPBOARD,
    enabledByDefault: true,
    incomingTypes: ['kdeconnect.clipboard', 'kdeconnect.clipboard.connect'],
    outgoingTypes: ['kdeconnect.clipboard', 'kdeconnect.clipboard.connect']
  },
  {
    key: PLUGIN_SHARE,
    enabledByDefault: true,
    incomingTypes: ['kdeconnect.share.request'],
    outgoingTypes: ['kdeconnect.share.request']
  },
  {
    key: PLUGIN_MPRIS,
    enabledByDefault: true,
    incomingTypes: ['kdeconnect.mpris', 'kdeconnect.mpris.request'],
    outgoingTypes: ['kdeconnect.mpris', 'kdeconnect.mpris.request']
  },
  {
    key: PLUGIN_PING,
    enabledByDefault: true,
    incomingTypes: ['kdeconnect.ping'],
    outgoingTypes: ['kdeconnect.ping']
  },
  {
    key: PLUGIN_BATTERY,
    enabledByDefault: true,
    incomingTypes: ['kdeconnect.battery'],
    outgoingTypes: ['kdeconnect.battery']
  },
  {
    key: PLUGIN_FIND_MY_PHONE,
    enabledByDefault: true,
    // Local device can be found (incoming) and can ring remote (outgoing)
    incomingTypes: ['kdeconnect.findmyphone.request'],
    outgoingTypes: ['kdeconnect.findmyphone.request']
  }
];

const metaByKey: Map<string, PluginMeta> = (() => {
  const m: Map<string, PluginMeta> = new Map();
  for (let i = 0; i < IMPLEMENTED_PLUGINS.length; i++) {
    m.set(IMPLEMENTED_PLUGINS[i].key, IMPLEMENTED_PLUGINS[i]);
  }
  return m;
})();

const packetToPlugin: Map<string, string> = (() => {
  const m: Map<string, string> = new Map();
  for (let i = 0; i < IMPLEMENTED_PLUGINS.length; i++) {
    const p = IMPLEMENTED_PLUGINS[i];
    for (let j = 0; j < p.incomingTypes.length; j++) {
      m.set(p.incomingTypes[j], p.key);
    }
  }
  return m;
})();

export function getPluginMeta(key: string): PluginMeta | undefined {
  return metaByKey.get(key);
}

export function isKnownPlugin(key: string): boolean {
  return metaByKey.has(key);
}

/** Map an incoming packet type to a plugin key, or null if ungated (pair/identity). */
export function pluginKeyForPacketType(packetType: string): string | null {
  return packetToPlugin.get(packetType) ?? null;
}

/**
 * Map DeviceDetail UI button keys to plugin settings keys.
 * Unimplemented UI tiles keep their own keys and are not gated here.
 */
export function pluginKeyForUiButton(uiKey: string): string | null {
  if (uiKey === 'send_files') {
    return PLUGIN_SHARE;
  }
  if (uiKey === 'multimedia') {
    return PLUGIN_MPRIS;
  }
  if (uiKey === 'send_clipboard') {
    return PLUGIN_CLIPBOARD;
  }
  return null;
}

/** Peer deviceType is a phone (Android DeviceType.PHONE). */
export function isPhonePeer(deviceType: string): boolean {
  const t = (deviceType ?? '').toLowerCase();
  return t === 'phone' || t === 'smartphone';
}

/**
 * Packet types each detail UI button would use (Android PluginFactory.PluginInfo).
 * Unimplemented tiles still declare caps so they only appear when peer supports them.
 */
interface UiButtonCapDef {
  uiKey: string;
  /** Packets this plugin can handle (our supportedPacketTypes). */
  supportedPacketTypes: string[];
  /** Packets this plugin can send (our outgoingPacketTypes). */
  outgoingPacketTypes: string[];
  /** Android PresenterPlugin.isCompatible: hide when peer is PHONE. */
  hideForPhone: boolean;
}

const UI_BUTTON_CAP_DEFS: UiButtonCapDef[] = [
  {
    uiKey: 'send_files',
    supportedPacketTypes: ['kdeconnect.share.request'],
    outgoingPacketTypes: ['kdeconnect.share.request'],
    hideForPhone: false
  },
  {
    // Control remote media (MprisPlugin) + expose local (MprisReceiver)
    uiKey: 'multimedia',
    supportedPacketTypes: ['kdeconnect.mpris', 'kdeconnect.mpris.request'],
    outgoingPacketTypes: ['kdeconnect.mpris', 'kdeconnect.mpris.request'],
    hideForPhone: false
  },
  {
    // MousePadPlugin
    uiKey: 'remote_input',
    supportedPacketTypes: ['kdeconnect.mousepad.keyboardstate'],
    outgoingPacketTypes: ['kdeconnect.mousepad.request'],
    hideForPhone: false
  },
  {
    // RunCommandPlugin
    uiKey: 'run_command',
    supportedPacketTypes: ['kdeconnect.runcommand'],
    outgoingPacketTypes: ['kdeconnect.runcommand.request'],
    hideForPhone: false
  },
  {
    // PresenterPlugin — not compatible with phone peers
    uiKey: 'presentation',
    supportedPacketTypes: [],
    outgoingPacketTypes: ['kdeconnect.mousepad.request', 'kdeconnect.presenter'],
    hideForPhone: true
  },
  {
    // DigitizerPlugin
    uiKey: 'drawing',
    supportedPacketTypes: [],
    outgoingPacketTypes: ['kdeconnect.digitizer.session', 'kdeconnect.digitizer'],
    hideForPhone: false
  },
  {
    uiKey: 'send_clipboard',
    supportedPacketTypes: ['kdeconnect.clipboard', 'kdeconnect.clipboard.connect'],
    outgoingPacketTypes: ['kdeconnect.clipboard', 'kdeconnect.clipboard.connect'],
    hideForPhone: false
  }
];

function findUiCapDef(uiKey: string): UiButtonCapDef | null {
  for (let i = 0; i < UI_BUTTON_CAP_DEFS.length; i++) {
    if (UI_BUTTON_CAP_DEFS[i].uiKey === uiKey) {
      return UI_BUTTON_CAP_DEFS[i];
    }
  }
  return null;
}

function setContains(set: string[], value: string): boolean {
  for (let i = 0; i < set.length; i++) {
    if (set[i] === value) {
      return true;
    }
  }
  return false;
}

/**
 * Android PluginFactory.hasCommonCapabilities:
 * peer.outgoing ∩ our.supported  OR  peer.incoming ∩ our.outgoing
 */
export function hasCommonCapabilities(
  ourSupported: string[],
  ourOutgoing: string[],
  peerIncoming: string[],
  peerOutgoing: string[]
): boolean {
  for (let i = 0; i < peerOutgoing.length; i++) {
    if (setContains(ourSupported, peerOutgoing[i])) {
      return true;
    }
  }
  for (let j = 0; j < peerIncoming.length; j++) {
    if (setContains(ourOutgoing, peerIncoming[j])) {
      return true;
    }
  }
  return false;
}

/**
 * Whether a detail-grid UI button should appear for this peer.
 * Mirrors Android loadedPlugins → getUiButtons (capabilities + isCompatible).
 *
 * When peer caps are unknown (empty), keep showing (Android assumes all until
 * identity capabilities arrive), still apply hideForPhone / phone heuristics.
 */
export function isUiButtonForPeer(
  uiKey: string,
  deviceType: string,
  peerIncoming?: string[],
  peerOutgoing?: string[]
): boolean {
  if (uiKey.length === 0) {
    return true;
  }
  const def = findUiCapDef(uiKey);
  if (def === null) {
    return true;
  }
  if (def.hideForPhone && isPhonePeer(deviceType)) {
    return false;
  }
  const inc = peerIncoming ?? [];
  const out = peerOutgoing ?? [];
  // Unknown caps → show (deviceType already applied for presenter)
  if (inc.length === 0 && out.length === 0) {
    // Without caps, hide typical desktop-only tiles for phone peers
    if (isPhonePeer(deviceType)) {
      if (uiKey === 'remote_input' || uiKey === 'run_command' || uiKey === 'drawing') {
        return false;
      }
    }
    return true;
  }
  return hasCommonCapabilities(
    def.supportedPacketTypes,
    def.outgoingPacketTypes,
    inc,
    out
  );
}

/**
 * Whether a settings/plugin key is supported by peer capabilities.
 * Android: pluginsForCapabilities filter.
 */
export function isPluginSupportedByPeer(
  pluginKey: string,
  peerIncoming?: string[],
  peerOutgoing?: string[]
): boolean {
  const meta = getPluginMeta(pluginKey);
  if (!meta) {
    return false;
  }
  const inc = peerIncoming ?? [];
  const out = peerOutgoing ?? [];
  if (inc.length === 0 && out.length === 0) {
    return true;
  }
  return hasCommonCapabilities(meta.incomingTypes, meta.outgoingTypes, inc, out);
}

/**
 * Overflow "Ring" (FindRemoteDevice).
 * Preferred: peer.incoming contains findmyphone.request.
 * Fallback: phone/tablet/tv deviceType when caps unknown.
 */
export function peerSupportsRingMenu(
  deviceType: string,
  peerIncoming?: string[]
): boolean {
  const inc = peerIncoming ?? [];
  if (inc.length > 0) {
    return setContains(inc, 'kdeconnect.findmyphone.request');
  }
  const t = (deviceType ?? '').toLowerCase();
  return t === 'phone' || t === 'smartphone' || t === 'tablet' || t === 'tv';
}
