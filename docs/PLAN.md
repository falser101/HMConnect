# HMConnect 下一阶段计划（对齐安卓 KDE Connect 体验）

## 已确认的产品决策

| 项 | 选择 |
|----|------|
| 主界面 | **设备列表为主**；左上角 **三横线** 打开侧栏（本机信息 / 设置 / 关于），对齐安卓版 |
| 已配对管理 | **基础档**：附近可连 vs 已配对；连接 / 断开 / 取消配对；记住名称与上次状态 |
| 常驻 + 通知 | **前台长时任务 + 常驻通知**；断线 / 配对 / 新剪贴板可推送 |
| 粘贴历史 | **本地文本列表** + **按设备分组** + **收到即入库**（本期不做搜索/收藏，删除可作轻量能力） |
| 节奏 | **2–3 个迭代** 交付 |

## 现状（基线）

- 协议层：`KdeDiscover` / `KdeClient` / `KdeService` 已能发现、反向 TLS、配对、剪贴板收发。
- UI：单页 `Index.ets`，发现列表 + 状态 + 临时输入框；**无侧栏、无已配对持久化、无后台、无通知、无历史**。
- 生命周期：`aboutToDisappear` 会 `service.stop()`，退到后台/杀页即断链。
- 权限：仅 `INTERNET` + `GET_NETWORK_INFO`。

---

## 目标架构（全局）

```
┌─────────────────────────────────────────────────────┐
│ UI (pages)                                           │
│  Index: 设备列表 + SideBar                           │
│  DeviceDetail: 单设备操作 + 该设备历史入口             │
│  ClipboardHistory: 按设备分组历史                      │
│  Settings / About                                    │
└──────────────────────┬──────────────────────────────┘
                       │ 事件 / 命令
┌──────────────────────▼──────────────────────────────┐
│ AppSession (单例)                                     │
│  - 持有 KdeService                                    │
│  - 设备仓库 DeviceStore (preferences/RDB)             │
│  - 剪贴板历史 HistoryStore                            │
│  - 通知 NotificationHelper                            │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│ 长时任务 (Continuous Task / 前台服务形态)             │
│  - 保活 UDP 发现 + TCP 监听 + 已建立 TLS 会话         │
│  - 更新常驻通知文案（发现中 / 已连接 huoya / 已配对）  │
└─────────────────────────────────────────────────────┘
```

**原则：**

1. **协议与 UI 解耦**：socket 生命周期挂在 App 级单例 + 长时任务，不挂在页面 `aboutToDisappear`。
2. **安卓对齐的信息架构**：主路径永远是「设备列表 → 点设备 → 操作」；侧栏放本机/设置/关于。
3. **信任与会话分离**：`trusted`（已配对）持久化；`online/session` 运行时状态。

---

## 迭代 1 — 页面布局 + 已配对设备管理（先交付可用壳）

**目标：** 看起来像安卓 KDE Connect 的设备首页，并具备基础设备管理。

### 1.1 页面与导航

| 页面 | 职责 |
|------|------|
| `pages/Index` | 主设备列表（附近 + 已配对分区） |
| 侧栏（`SideBar` / `Navigation` drawer） | 本机设备名、deviceId 摘要、设置、关于 |
| `pages/DeviceDetail`（可选同迭代） | 连接/断开/取消配对、快捷发送文本、跳转该设备历史 |
| `pages/Settings` | 显示名、是否自动接受重连（先占位）、清空历史 |
| `pages/About` | 版本、协议说明 |

布局要点（Index）：

- 顶栏：`☰` | 标题「设备」| 刷新（可选）
- 列表分区：
  - **已配对**（`paired`/`trusted`，展示在线/离线角标）
  - **可用设备**（局域网发现且未信任）
- 列表项：设备名、类型图标占位、IP/端口次要信息、状态文案（可连接 / 已连接 / 离线）
- 底部不堆操作栏；发送文本、粘贴历史放到 **设备详情** 或侧栏入口，避免首页杂乱。

### 1.2 已配对设备管理（基础档）

**数据模型（持久化 preferences 即可）：**

```ts
interface TrustedDevice {
  deviceId: string;
  deviceName: string;
  deviceType: string;
  lastIp?: string;
  lastTcpPort?: number;
  lastSeenAt: number;
  pairedAt: number;
}
```

**行为：**

| 操作 | 行为 |
|------|------|
| 发现已知 deviceId | 合并进「已配对」行，更新 `lastIp` / 在线 |
| 点「连接」 | 现有 `connect` 流程；信任设备重连不重复 pair |
| 点「断开」 | 关闭 TLS/桥接，保持 trust，列表显示离线 |
| 取消配对 | 发 `pair:false`（若在线）+ 本地删除 trust + 清该设备历史（可确认弹窗） |
| 冷启动 | 先渲染已配对列表，再开始发现补在线状态 |

**代码改动面：**

- 新增 `store/DeviceStore.ets`
- `KdeClient`：`trustedDeviceIds` 从内存改为读 `DeviceStore`；pair 成功写库；unpair 删库
- `KdeService` / `AppSession`：统一暴露 `getDevicesViewModel()`（合并 discovered + trusted）
- **禁止** 在 `Index.aboutToDisappear` 里 `stop()` 整站服务（为迭代 2 铺路；迭代 1 可先改为 Ability 级生命周期）

### 1.3 验收标准（迭代 1）

- [ ] 主页仅设备列表 + 侧栏，风格接近安卓设备页
- [ ] 已配对设备杀进程再开仍在列表
- [ ] 在线/离线可区分；连接/断开/取消配对可用
- [ ] 不再出现「首页堆满调试按钮」的 MVP 形态

---

## 迭代 2 — 后端常驻 + 系统通知

**目标：** 退到后台仍保持发现/连接；用户通过通知感知状态与新剪贴板。

### 2.1 常驻方案（鸿蒙）

推荐路径（按 API 23 / HarmonyOS 6.x 能力落地时以文档为准）：

1. **应用级单例 `AppSession`**：在 `EntryAbility.onCreate` 启动协议栈，在 `onDestroy` 再停。
2. **长时任务（Continuous Task）**：申请「数据传输 / 通信」类后台运行，绑定到连接会话期间。
3. **常驻通知**：前台可见通知渠道，文案随状态更新，例如：
   - `HMConnect · 搜索设备中`
   - `HMConnect · 已连接 huoya`
   - `HMConnect · 已配对 · 剪贴板同步中`

权限与配置（预期新增）：

- 通知相关：`ohos.permission.PUBLISH_AGENT_REMINDER` 或新版 notification 权限（以 SDK 实际为准）
- 长时任务：`ohos.permission.KEEP_BACKGROUND_RUNNING`（若需要）
- `module.json5`：backgroundModes / continuousTask 声明
- 用户授权：首次引导打开通知权限

**明确边界（写进设置页）：**

- 用户从多任务划掉进程后，系统可能仍杀进程；常驻 **不保证 100% 杀不死**，但应在「应用在后台、未强杀」场景下保持 socket。
- 不实现厂商保活白名单引导（可作为后续增强）。

### 2.2 通知类型

| 类型 | 触发 | 行为 |
|------|------|------|
| 常驻（ongoing） | 服务运行中 | 点按回主页；显示连接摘要 |
| 配对请求结果 | pair 成功/失败 | 短时通知 |
| 新剪贴板 | 收到 `kdeconnect.clipboard*` | 展示摘要（截断），点按打开历史或详情 |
| 断线 | session 从 live→dead | 可选，默认开 |

实现：`notify/NotificationHelper.ets`，所有 emit 状态经 `AppSession` 统一转发，避免 UI 与后台各发一套。

### 2.3 验收标准（迭代 2）

- [ ] 切到桌面 1–3 分钟后剪贴板仍可从电脑同步到手机
- [ ] 状态栏有常驻通知且文案随连接变化
- [ ] 收到新剪贴板有一次性通知
- [ ] 打开通知权限被拒时有降级（仅日志 + 应用内状态）

---

## 迭代 3 — 设备粘贴历史管理

**目标：** 收/发文本可追溯，按设备分组，支持再次发送与本机复制。

### 3.1 数据模型

```ts
interface ClipboardHistoryItem {
  id: string;           // uuid
  deviceId: string;
  deviceName: string;   // 冗余展示
  direction: 'in' | 'out';
  content: string;
  createdAt: number;
}
```

存储：

- MVP：`preferences` 或轻量 RDB；建议 **按条上限**（如每设备 100 条 / 全局 500 条），超限 FIFO 删除。
- 不存图片/富文本（协议侧本期仍只做 text）。

### 3.2 写入时机

| 事件 | direction |
|------|-----------|
| 收到 `kdeconnect.clipboard` / `clipboard.connect` | `in` |
| 用户发送文本 / PasteButton 同步 | `out` |

写入点放在 `KdeClient` 回调之后的 `AppSession`，保证 UI 未打开也会入库（依赖迭代 2 常驻）。

### 3.3 UI

- **历史页**：按设备分组（`List` + sticky header 或两级：先选设备再看列表）
- 条目：时间、方向标签（收/发）、内容 2 行摘要
- 操作：点击 → 展开；「复制到本机」「再次发送到该设备」「删除本条」
- 设置：清空全部历史；可选「仅保留 N 天」（可二期）

**权限：** 复制到本机用写剪贴板；读系统剪贴板继续用 `PasteButton`，**不申请** `READ_PASTEBOARD`。

### 3.4 验收标准（迭代 3）

- [ ] 电脑复制 → 手机自动入库，历史页可见且挂在对应设备下
- [ ] 手机发送 → 出现 `out` 记录
- [ ] 杀进程再开历史仍在
- [ ] 达到上限后旧记录被淘汰，不爆存储

---

## 跨迭代技术债 / 与现有代码的衔接

| 现有问题 | 处理迭代 |
|----------|----------|
| `Index.aboutToDisappear` 停服务 | 1 改为 App 级；2 完善长时任务 |
| 信任列表仅内存 | 1 持久化 |
| UDP announce 与会话抢连 | 已部分修复；2 在后台仍保持「live 时 pause announce」 |
| UI 与协议耦合 | 1 引入 `AppSession` 单例 |
| 无通知 | 2 |
| 无历史 | 3 |

### 建议目录结构

```
entry/src/main/ets/
  app/AppSession.ets
  store/DeviceStore.ets
  store/HistoryStore.ets
  notify/NotificationHelper.ets
  service/  (现有 Kde*)
  pages/Index.ets
  pages/DeviceDetail.ets
  pages/ClipboardHistory.ets
  pages/Settings.ets
  pages/About.ets
  components/DeviceListItem.ets
  components/AppSideBar.ets
```

---

## 风险与对策

| 风险 | 对策 |
|------|------|
| 长时任务审核/权限因机型差异失败 | 设置页展示「后台同步」开关与失败原因；失败时退化为前台-only |
| 常驻耗电 | 已配对且无会话时降低 UDP 频率；会话 live 停 announce |
| 历史含敏感文本 | 关于/设置中隐私说明；支持一键清空；通知只显示截断摘要 |
| 安卓 UI 完全一致成本高 | **信息架构一致**优先，视觉用鸿蒙原生组件，不 1:1 像素复刻 |

---

## 交付节奏建议

| 迭代 | 内容 | 可演示结果 |
|------|------|------------|
| **I1** | 侧栏 + 设备列表分区 + 信任持久化 + 连接/断开/取消配对 | 「像安卓一样管设备」 |
| **I2** | AppSession 保活 + 长时任务 + 常驻/事件通知 | 「锁屏也能同步剪贴板 + 有通知」 |
| **I3** | 历史入库 + 分组页 + 再发送/复制 | 「按电脑看粘贴记录」 |

每迭代结束：真机联调电脑 KDE Connect（`huoya`），回归：发现 → 配对 → 剪贴板双向 → 杀 UI 回前台会话是否仍在（I2+）。

---

## 建议立即开工顺序（I1 细任务）

1. 抽 `AppSession`，把 `KdeService` 从页面挪到 Ability  
2. `DeviceStore` + pair/unpair 写读  
3. 改 `Index`：顶栏汉堡 + 侧栏 + 双分区列表  
4. `DeviceDetail`：断开 / 取消配对 / 简易发送  
5. 回归连接与配对（不引入通知与历史）

---

## 不在本期范围

- 文件共享、触控板、通知镜像、多媒体控制等其它 KDE 插件  
- 图片剪贴板  
- 云同步历史  
- 完整设置（主题、多语言、证书轮换 UI）  
- 搜索/收藏历史（你未勾选，可作 I3+ 增强）
