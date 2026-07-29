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
