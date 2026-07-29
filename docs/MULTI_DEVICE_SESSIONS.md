# 多设备同时在线（实现说明）

## 目标

对齐安卓 `KdeConnect.devices: Map<deviceId, Device>`：同一局域网可同时与多台设备保持 TLS 会话。

## 结构

```
KdeService
  ├─ KdeDiscover          // 共享 UDP 发现（多设备时不再因任一会话 live 而全局 pause）
  └─ KdeClient (Hub)
       ├─ TCP listen 1716–1764（共享）
       ├─ cert/key（共享）
       ├─ trustedDeviceIds + DeviceStore
       └─ sessions: Map<deviceId, DeviceSession>
            └─ DeviceSession：单 peer 的 TLS / pair / clipboard / battery / mpris / share
```

## 连接路由

| 方向 | 行为 |
|------|------|
| 用户点「连接」设备 A | `getOrCreateSession(A)` → 仅操作 A 的会话 |
| PC 反向 TCP 连入 | Hub rate-limit → 新建 pending `DeviceSession` → 读 identity → `rebind` 到真实 deviceId |
| 同 deviceId 重连 | 新会话 bind 时 `stop()` 旧会话，替换 map 条目 |
| 设备 B 在 A 在线时连入 | 独立 `DeviceSession`，互不 `disconnect` |

## API 约定

- 面向 UI 的操作尽量带 `deviceId`：`disconnectDevice` / `requestPairingFor` / `sendPingTo` / `createFileSendJobFor` / `sendClipboardTextTo`
- 无 id 的旧 API 回落到「优先已配对 live → 任一 live → 任一 session」

## 与安卓仍有差距

- 证书 TOFU、协议 v8、配对超时 / verification key
- 蓝牙 / mDNS / 自定义 IP
- 本机 MPRIS AVSession 仍偏全局

详见 `CONNECTION_COMPARISON.md`。
