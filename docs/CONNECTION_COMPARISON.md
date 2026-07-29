# 连接相关功能对照表（HMConnect vs kdeconnect-android）

> 记录时间：2026-07-29  
> 范围：发现、链路、TLS、配对、信任、多设备、后台保活等**连接相关**能力（不含插件业务本身）。  
> 状态会随实现更新；实现多设备后请同步改本表。

## 总览

| 维度 | 结论 |
|------|------|
| 主链路（同 Wi‑Fi 发现 → TLS → 配对） | 鸿蒙已可用 |
| 与安卓功能对等 | **否**（约 45%–55%，多设备实现后预计提升） |
| 最大结构性差距 | 单 TLS 会话 vs 安卓 `Map<deviceId, Device>` 多会话；证书 TOFU；协议 v7 vs v8 |

## 功能点对照

| 功能点 | 安卓 (kdeconnect-android) | 鸿蒙 (HMConnect) | 是否对齐 | 备注 |
|--------|---------------------------|------------------|----------|------|
| LAN UDP 1716 发现 / 广播 | ✅ `LanLinkProvider` | ✅ `KdeDiscover` | 基本 | 鸿蒙无严格 identity 校验与包大小上限 |
| mDNS / NSD 发现 | ✅ `MdnsDiscovery` | ❌ | 否 | |
| TCP 1716–1764 监听 | ✅ | ✅ `KdeClient.startServer` | 是 | |
| 反向连接（PC 连入） | ✅ Locally | ✅ reverse + loopback TLS 桥 | 是 | 鸿蒙 API 限制需桥接 |
| 主动 outbound TLS | ✅ Remotely | ✅ 5s 后 fallback outbound | 是 | |
| **多设备同时在线** | ✅ `ConcurrentHashMap<String, Device>` | ✅ `KdeClient` hub + `Map<deviceId, DeviceSession>` | 基本 | 2026-07-29 已实现并行 TLS 会话；插件级能力仍按会话路由 |
| 连接频率限制 | ✅ IP + deviceId 1s | ✅ IP（及部分 deviceId） | 基本 | |
| 非私网地址丢弃 | ✅ `isPrivateAddress` | ❌ | 否 | |
| targetDeviceId / protocol 匹配 | ✅ 严格 | ⚠️ 弱 | 部分 | |
| TLS 加密通道 | ✅ `SslHelper` | ✅ TLSv1.2/1.3 | 是 | 鸿蒙 `skipRemoteValidation` |
| 本机 deviceId | 运行时生成并持久化 | 固定 `MY_DEVICE_ID` | 否 | |
| 本机证书 | 动态 RSA + 签发，CN=deviceId | rawfile 固定 PEM | 否 | |
| 对端证书 TOFU 存证 | ✅ 配对后校验 | ❌ 不存证 | 否 | |
| 校验码 verification key | ✅ v7/v8 | ✅ v8（双方≥8）/ v7 回退 | 基本 | TLS 取对端证书公钥 |
| 协议版本 | **v8** | **v8** | 是 | 2026-07-29 升级；含 TLS 后 identity 交换 |
| 配对 4 态状态机 | ✅ `PairingHandler` | ✅ `not_paired/requested/requested_by_peer/paired` + UI | 基本 | 2026-07-29 对齐 |
| 配对超时 25s/30s | ✅ | ✅ 30s 主动 / 25s 被请求 | 是 | |
| 取消进行中的配对 | ✅ Cancel pairing | ✅ 菜单+等待页按钮 | 是 | |
| 进详情自动 TLS | 发现即 link | ✅ 进详情 auto-connect | 基本 | |
| 接受/拒绝仅 RequestedByPeer | ✅ | ✅ | 是 | |
| pair timestamp 时钟差（v8） | ✅ ±30min | ✅ 发送 + 校验 ±30min | 是 | |
| TLS 后加密 identity（v8） | ✅ 双方互发 | ✅ exchangeSecureIdentity | 是 | |
| 接受 / 拒绝配对（UI+通知） | ✅ | ✅ | 是 | |
| 断开（保信任） | ✅ | ✅ `disconnect` | 是 | 需带 deviceId（多设备后） |
| 取消配对（双向） | ✅ | ✅ `unpair` | 基本 | |
| 信任列表持久化 | ✅ + 证书 | ✅ `DeviceStore` 元数据 | 部分 | 无证书 |
| 已配对列表 + 在线/离线 | ✅ | ✅ `buildDeviceList` | 是 | |
| 后台保活 + 常驻通知 | ✅ Foreground Service | ✅ Continuous Task | 基本 | |
| 网络变化重发现 | ✅ | ✅ | 是 | |
| 会话 live 时 UDP 策略 | link 生命周期 | live 时 pause announce | 部分 | 多设备时应避免全局 pause |
| 蓝牙连接 | ✅ `BluetoothLinkProvider` | ❌ 设置灰掉 | 否 | |
| 按 IP 添加设备 | ✅ `CustomDevicesActivity` | ❌ 设置灰掉 | 否 | |
| 受信网络 Trusted Networks | ✅ | ❌ 设置灰掉 | 否 | |
| 可配置本机显示名 | ✅ | 只读展示 | 否 | |
| 发现列表过期清理 | link 丢失 → 不可达 | UDP map 只增不减 | 否 | |

## 架构对照（连接）

```
安卓:
  BackgroundService
    └─ LanLinkProvider / BluetoothLinkProvider
         └─ BaseLink (per connection)
  KdeConnect.devices: Map<deviceId, Device>
    └─ Device → PairingHandler + links[] + plugins

鸿蒙（当前）:
  KdeBackgroundService + AppSession
    └─ KdeService
         ├─ KdeDiscover (shared UDP)
         └─ KdeClient (hub)
              ├─ shared TCP server + certs
              └─ sessions: Map<deviceId, DeviceSession>
                   └─ TLS + pair + per-peer plugin state
```

## 已知缺陷（连接）

1. ~~配对 `pair:false` 分支误嵌套~~ → **已修**（`DeviceSession.dispatchPacket`）。
2. ~~单会话互斥~~ → **已修**（多 `DeviceSession` 并行）。
3. **安全模型偏弱**：固定 cert + skip remote validation，不满足安卓 TOFU 语义。
4. 多设备下 MPRIS 本机 AVSession 仍偏「全局一份」，远端播放器状态按会话隔离。

## 实现优先级（连接对齐）

| 优先级 | 项 |
|--------|----|
| ~~P0~~ | ~~多设备并行会话~~ ✅ |
| ~~P0~~ | ~~修复配对 pair 分支~~ ✅ |
| P1 | 证书 TOFU + 去掉裸 skip validation |
| P1 | 完整 PairingHandler（4 态 + 超时 + verification） |
| P2 | 协议升 v8 |
| P2 | 可配置设备名 / 动态 deviceId；发现列表过期 |
| P3 | mDNS、自定义 IP、受信网络、蓝牙 |

## 变更记录

| 日期 | 变更 |
|------|------|
| 2026-07-29 | 初版对照表；启动多设备 Session 改造 |
| 2026-07-29 | 实现 `DeviceSession` + `KdeClient` 多会话 Hub；修复 pair 分支；更新本表 |
