# HAP 文件关联安装设计

## 概述

scrcpy_server 支持 .hap 文件类型关联。用户在系统文件管理器中点击 .hap 文件时，拉起全屏安装引导界面，展示权限列表，确认后强制覆盖安装。

## 架构

```
文件管理器 ──[Want: action=viewData, uri=file://xxx.hap]──▶ HapInstallerAbility
                                                              │
                                                              ▼
                                                        pages/HapInstall
                                                        ┌──────────────────────┐
                                                        │ 1. 解压 hap (zip)     │
                                                        │ 2. 读取 module.json5  │
                                                        │ 3. 展示权限列表       │
                                                        │ 4. [取消] [安装]      │
                                                        └──────────────────────┘
                                                              │ 安装
                                                              ▼
                                                        BundleInstaller API
                                                        (REPLACE_EXISTING)
                                                              │
                                                              ▼
                                                        成功：[关闭] [打开]
                                                        失败：错误提示 + [关闭]
```

## module.json5 配置

新增 `HapInstallerAbility`：

```json5
{
  "name": "HapInstallerAbility",
  "srcEntry": "./ets/hapinstaller/HapInstallerAbility.ets",
  "description": "$string:HapInstaller_desc",
  "icon": "$media:layered_image",
  "label": "$string:HapInstaller_label",
  "startWindowIcon": "$media:startIcon",
  "startWindowBackground": "$color:start_window_background",
  "exported": true,
  "skills": [
    {
      "actions": ["ohos.want.action.viewData"],
      "uris": [
        {
          "scheme": "file",
          "utd": "openharmony.hap"
        }
      ]
    }
  ]
}
```

> 若系统无内置 `general.hap` UTD，需在 `utd.json5` 中自定义声明，关联 `.hap` 后缀。

## 权限需求

新增 `ohos.permission.INSTALL_BUNDLE`（系统权限）：
- `module.json5` 的 `requestPermissions` 追加
- `signature/permissions.json` 追加预授权条目

## HAP 解析流程

1. 从 Want.uri 获取文件真实路径
2. 使用 `@ohos.zlib` 将 .hap 解压到 `context.tempDir`
3. 读取解压目录下的 `module.json5`
4. 提取 `module.requestPermissions[].name` 数组和 `module.name`、版本等基本信息
5. 清理临时文件（安装完成后 + onDestroy 兜底）

## UI 状态机

```
confirm ──[点击安装]──▶ installing ──[成功]──▶ success
    │                       │                     │
    │                       └──[失败]──▶ failed   │
    │                                     │       │
    └──[取消]──▶ terminateSelf     [关闭]──┘  [打开]→startAbility
```

页面状态：`confirm` | `installing` | `success` | `failed`

### confirm 状态
- 展示应用名（bundleName）、版本号
- 展示 requestPermissions 原始权限名列表
- 按钮：取消（terminateSelf）、安装

### installing 状态
- 加载指示器 + "正在安装..."

### success 状态
- "安装成功"提示
- 按钮：关闭（terminateSelf）、打开（startAbility 启动目标应用主入口）

### failed 状态
- "安装失败"提示 + 错误信息
- 按钮：关闭（terminateSelf）

## 安装执行

```typescript
import installer from '@ohos.bundle.installer';

const bundleInstaller = await installer.getBundleInstaller();
const installParam: installer.InstallParam = {
  installFlag: installer.InstallFlag.REPLACE_EXISTING,
  isKeepData: false
};
bundleInstaller.install([hapFilePath], installParam, callback);
```

强制覆盖安装，不检查 versionCode。

## 错误处理

- 文件不可读 / 非有效 ZIP → "文件无法解析"
- module.json5 缺失或格式异常 → "不是有效的 HAP 文件"
- BundleInstaller 错误 → 显示错误码和描述

## 文件结构（新增）

```
scrcpy_server/entry/src/main/ets/
├── hapinstaller/
│   └── HapInstallerAbility.ets
├── pages/
│   ├── Index.ets              (现有)
│   └── HapInstall.ets         (新增)
```

## 不做的事

- 不做权限名的友好文案映射
- 不做 versionCode 比较或降级提示
- 不做签名校验
- 不支持多 HAP/HSP 批量安装（仅单文件）
