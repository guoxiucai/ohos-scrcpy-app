# 应用安装 / 卸载 设计文档

> 配套主设计文档 `spec_doc/design.md` §3 协议、§5 客户端 UI；与 `spec_doc/terminal_design.md` 同级的功能子文档。

## 1. 目标与变更

### 1.1 安装应用（既有功能改造）
- HDC 安装强制走 `hdc install -r`（覆盖安装、跳过签名时间戳冲突）。
- 不再在面板里实时打印安装日志；安装结果以**模态弹窗**告知：
  - 成功：「安装成功」+ hap 文件名
  - 失败：「安装失败」+ 错误详情（mono 字体可复制）

### 1.2 卸载应用（新增功能，位于安装区下方）
- 输入框 + 下拉，**输入关键字模糊匹配**（包名或显示名）。
- 应用列表来源：连接成功后**自动从服务端请求**一次，缓存在客户端；点击「刷新」按钮可手动重拉。
- 仅展示**可卸载**的应用（`removable === true`），系统应用与不可移除应用在服务端就过滤掉。
- 卸载前二次确认弹窗；结果同样以模态弹窗告知成功/失败。

## 2. 应用列表来源：方案选型

### 2.1 候选

| 方案 | 实现 | 优点 | 缺点 |
|------|------|------|------|
| A. 客户端 `hdc shell bm` | `bm dump -a` 列名 + 逐个 `bm dump -n` | 不动服务端 | N+1 次 hdc 冷启动慢；文本格式跨 SDK 不稳；`removable` 字段在 API 12-20 字段名/位置不稳 |
| **B. 服务端 NAPI + 协议**（采用） | `bundleManager.getAllBundleInfo` 一次拿全 → 服务端过滤 → 走既有 TCP 通道下发 | 一次调用毫秒级；强类型；与现有协议风格一致；权限已申请 (`GET_INSTALLED_BUNDLES`) | 需扩协议、写服务端代码 |

**结论**：选 B。N+1 次 hdc 冷启动 + 文本解析。

### 2.2 服务端 API

```ts
import bundleManager from '@ohos.bundle.bundleManager';

const flags = bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION
            | bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT;
const list = await bundleManager.getAllBundleInfo(flags);
const filtered = list.filter(b => b.appInfo?.removable === true);
```

注意：
- 必须有 `ohos.permission.GET_INSTALLED_BUNDLES`（系统级，已在 module.json5 申请）。
- `removable` 字段从 API 9 起在 `ApplicationInfo` 上，名字稳定。
- `label` 是字符串型显示名；若拿到的是 `$string:xxx` 资源引用，服务端解析失败时回落空串，由客户端展示包名。

## 3. 协议扩展

### 3.1 控制子类型（C→S，复用现有 0x10 控制包）
| sub-type | 名称       | payload | 说明                       |
|----------|------------|---------|----------------------------|
| `0x30`   | ListApps   | 空      | 请求一次可卸载应用列表     |

### 3.2 设备状态子类型（S→C，复用现有 0x20 状态包）
| sub-type | 名称     | payload                                                                |
|----------|----------|------------------------------------------------------------------------|
| `0x10`   | AppList  | `count(2 BE)` + N×`{ bundleLen(2 BE) + bundle(UTF-8) + labelLen(2 BE) + label(UTF-8) }` |

约束：
- `count` 上限 1024；超出由服务端截断（极端场景不会触发）。
- `bundleLen` / `labelLen` 都是 uint16 BE，单段 ≤ 65535 字节。
- 顺序按 `appInfo.label || bundle` 升序排列，方便客户端不再额外排。
- label 取不到时长度为 0，客户端展示 bundle name。

### 3.3 失败语义
- 服务端拉列表失败（权限缺失 / NAPI 抛错）→ 仍然下发 0x20/0x10 包，但 `count=0`，并在日志里打错误（不另起 error subType，避免协议表面臃肿）。客户端 UI 提示「未获取到可卸载应用」。

## 4. 服务端改动 (`scrcpy_server`)

### 4.1 新建文件
- `entry/src/main/ets/scrcpyservice/AppListProvider.ets`
  - `listRemovableApps(): Promise<AppEntry[]>`
  - 内部封装 try/catch，异常时 return `[]`。

### 4.2 修改文件
- `scrcpyservice/Protocol.ets`
  - 加 `ControlSubType.LIST_APPS = 0x30`
  - 加 `DeviceStatusSubType.APP_LIST = 0x10`
  - 加 `encodeAppList(entries: AppEntry[]): Uint8Array`
- `scrcpyservice/TcpServer.ets`（或处理 control 的中心点）
  - 收到 `ControlSubType.LIST_APPS` → 调 `listRemovableApps()` → 编码 → 通过 0x20 包回发给请求者（仅该 client，不广播）。
- `scrcpyservice/ScrcpyService.ets`：无需改动（除非要预热 listApps）。

### 4.3 ArkTS 注意点（沿用 CLAUDE.md 规约）
- `AppEntry` 用 `interface { bundle: string; label: string }`，不要用内联对象类型。
- `Uint8Array` 拼装时显式 `new Uint8Array(totalLen)`，offset 推进。
- `import bundleManager from '@ohos.bundle.bundleManager'`，**不要**从 `@kit.AbilityKit` 解构。

## 5. 客户端改动 (`scrcpy_client_flutter`)

### 5.1 文件结构
```
lib/
  net/
    protocol.dart          # 加 listApps subtype + appList 解码
  hdc/
    hdc_client.dart        # installHap 改 -r；新增 uninstall()
  state/
    app_state.dart         # apps 列表、appsLoading、installApp/uninstallApp
  ui/
    sidebar.dart           # _InstallPanel 简化；新增 _UninstallPanel
    dialogs.dart           # 新建：showResultDialog / showConfirmDialog（暗色主题对齐）
```

### 5.2 状态机
```
AppState 新增字段：
  List<AppEntry> apps = [];      // 服务端下发的可卸载应用
  bool appsLoading = false;
  DateTime? appsFetchedAt;

时机：
  connect 成功后自动 requestAppList()
  收到 0x20/0x10 → 解码并 setState
  selectDevice 切设备 + 重连后再拉
  用户点「刷新」按钮也可手动触发
```

### 5.3 安装流程改造
```dart
Future<InstallResult> installHap(String hapPath) async {
  final dev = selectedDevice;
  if (dev == null) return InstallResult.fail('未选择设备');
  try {
    final out = await hdc.installHap(dev.serial, hapPath); // 内部 -r
    return InstallResult.ok(message: out);
  } catch (e) {
    return InstallResult.fail(e.toString());
  }
}
```

### 5.4 卸载流程
```dart
Future<UninstallResult> uninstallApp(String bundle) async {
  final dev = selectedDevice;
  if (dev == null) return UninstallResult.fail('未选择设备');
  try {
    final out = await hdc.uninstall(dev.serial, bundle);
    // 卸载成功后从本地 apps 中移除
    apps.removeWhere((a) => a.bundle == bundle);
    notifyListeners();
    return UninstallResult.ok(message: out);
  } catch (e) {
    return UninstallResult.fail(e.toString());
  }
}
```
HDC 命令：`hdc -t <sn> uninstall <bundle>`（不加 -k，彻底清数据）。

### 5.5 UI：安装面板（简化）
```
┌─ 应用安装 ────────────────────┐
│ [选择 .hap 文件]              │
│ (无日志区)                    │
└──────────────────────────────┘
```
按钮点击 → `installHap` 期间禁用并显示 spinner → 弹窗。

### 5.6 UI：卸载面板（新增）
```
┌─ 应用卸载 ────────────────────┐
│ [🔍 输入关键字 / 选择应用 ▾]  │  [刷新]
│ [卸载]                        │
└──────────────────────────────┘
```
- `Autocomplete<AppEntry>` 控件：
  - `optionsBuilder`：`apps.where((a) => a.bundle.contains(q) || a.label.toLowerCase().contains(q.toLowerCase()))`，最多展示 50 项避免巨长下拉。
  - `displayStringForOption`：`'${a.label.isEmpty ? a.bundle : a.label}  ·  ${a.bundle}'`。
- 「刷新」图标按钮：`appsLoading` 时旋转禁用。
- 「卸载」按钮：未选中 / 未连接 / 加载中 时禁用；点击后弹**二次确认弹窗**：
  「确定卸载 `<bundle>`？此操作不可撤销。」→ 确认后调 uninstall → 结果弹窗。
- 空列表（`apps.isEmpty && !appsLoading`）：显示「无可卸载应用」灰字。
- 未连接：显示「连接设备后将自动加载应用列表」。

### 5.7 弹窗样式（`ui/dialogs.dart`）
- 复用 `theme.dart` 的 `AppColors`：
  - 标题：成功 `AppColors.success`，失败 `AppColors.danger`，确认 `AppColors.warning`。
  - 内容区：纯文字 + 错误详情用 `Container(bg: bg, mono font, selectable, max 8 行 + 滚动)`。
  - 按钮：「取消」`OutlinedButton`，「确定/卸载」`FilledButton`（destructive 时改 `backgroundColor: danger`）。
- API：
  ```dart
  Future<void> showResultDialog(BuildContext, {required bool ok, required String title, String? detail});
  Future<bool> showConfirmDialog(BuildContext, {required String title, required String message, String confirmLabel='确定', bool destructive=false});
  ```

## 6. 错误与边界

| 场景                                            | 处理                                                            |
|------------------------------------------------|----------------------------------------------------------------|
| 未连接设备时点击「刷新」                          | 按钮禁用，不发包                                                |
| 服务端 NAPI 抛 permission denied                 | 客户端收到 count=0，显示「无可卸载应用」+ 提示检查权限          |
| 卸载过程中切设备                                 | 旧请求 await 完照常弹窗；新设备的 apps 自动重拉                 |
| 卸载成功但 server 没及时刷新列表                 | 客户端本地从 `apps` 移除已卸载项；下次 refresh 服务端列表对齐    |
| hdc install 因 hap 损坏 / 签名失败              | stderr 全文进失败弹窗 detail 区，可复制                          |
| Autocomplete 输入有正则元字符                    | 用 `String.contains` 不用 RegExp，避免注入                       |
| 大量应用（>500）                                  | 服务端按 label 排序后下发；客户端 Autocomplete 截断 50 显示       |

## 7. 验证方案

1. **服务端冒烟**：`hdc install` 测试 hap → 重启服务 → `nc 127.0.0.1 5005` 发 0x10/0x30 控制包 → 收到 0x20/0x10 响应包，`count > 0`。
2. **过滤正确性**：服务端日志打印 `total=X, removable=Y`；UI 列表与 `bm dump -a` 对比 `removable` 字段后人工抽查。
3. **安装弹窗**：选 hap 安装 → 成功弹绿色对勾 + 文件名；故意安装一个签名错误的 hap → 红色弹窗 + stderr 详情可复制。
4. **强制安装**：安装一个已存在的 hap → 不报「already exists」，覆盖成功。
5. **卸载流程**：输入关键字 → 列表过滤正确 → 选中 → 确认弹窗 → 确认 → 卸载成功弹窗 → 列表自动移除该项。
6. **未连接态**：断开后卸载面板禁用，提示语正确。
7. **设备切换**：A 设备列表显示 → 切到 B 设备 → 列表自动重拉为 B 的应用。
8. **大量应用**：mock 服务端下发 800 项 → Autocomplete 流畅、不卡顿。

## 8. 实施顺序

1. **协议层**：客户端 `protocol.dart` 扩 subtype + 解码（先单测）。
2. **服务端**：`AppListProvider.ets` + `TcpServer` 处理 0x30 → 0x20/0x10 回发；`hvigor assembleHap` 编译过。
3. **客户端**：`hdc_client.installHap` 改 -r 并改 Future；新增 `uninstall`；`AppState.apps/installApp/uninstallApp/requestAppList`。
4. **UI**：`dialogs.dart` 公共组件；`_InstallPanel` 简化；新增 `_UninstallPanel`。
5. **联调**：连真机，跑 §7 验证清单。
6. **回归**：原有触控/亮度/音量等控制 subType 不受影响，回归一遍。

## 9. 关联文件清单

服务端（修改/新建）：
- `scrcpy_server/entry/src/main/ets/scrcpyservice/AppListProvider.ets` ✚
- `scrcpy_server/entry/src/main/ets/scrcpyservice/Protocol.ets` ✎
- `scrcpy_server/entry/src/main/ets/scrcpyservice/TcpServer.ets` ✎
- `scrcpy_server/entry/src/main/module.json5` —（GET_INSTALLED_BUNDLES 已加）

客户端（修改/新建）：
- `scrcpy_client_flutter/lib/net/protocol.dart` ✎
- `scrcpy_client_flutter/lib/hdc/hdc_client.dart` ✎
- `scrcpy_client_flutter/lib/state/app_state.dart` ✎
- `scrcpy_client_flutter/lib/ui/sidebar.dart` ✎
- `scrcpy_client_flutter/lib/ui/dialogs.dart` ✚

文档：
- `spec_doc/design.md` 在 §5 末追加「应用安装/卸载详见 `spec_doc/app_install_uninstall_design.md`」。
