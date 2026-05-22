# CLI Contract: ohscrcpy

**Date**: 2026-05-21 | **Branch**: `001-ohscrcpy-cli`

---

## 调用语法

```
ohscrcpy [OPTIONS]
```

---

## 参数定义

| 参数 | 别名 | 类型 | 默认值 | 描述 |
|------|------|------|--------|------|
| `--serial` | `-s` | String | —（单设备时自动选择）| 目标设备序列号 |
| `--max-size` | `-m` | u32（像素） | 0（不限制） | 投屏画面最大边长 |
| `--bit-rate` | `-b` | String（支持 K/M 后缀） | `8M` | 视频流目标码率 |
| `--fps` | — | u32 | `60` | 目标帧率 |
| `--verbose` | `-v` | flag | false | 启用详细日志（输出到 stderr）|
| `--version` | — | flag | — | 打印版本号后退出 |
| `--help` | `-h` | flag | — | 打印用法后退出 |

---

## 退出码

| 退出码 | 含义 |
|--------|------|
| 0 | 正常退出（用户关窗口 / Ctrl+C / 设备断连） |
| 1 | 参数错误（无效参数值、格式错误） |
| 2 | 未找到设备（无已连接设备） |
| 3 | 多设备未指定 `-s` |
| 4 | 服务端安装失败 |
| 5 | 端口转发失败或冲突（已有同设备实例） |
| 6 | TCP 连接失败或超时 |
| 7 | hdc 工具未找到 |

---

## stdout / stderr 约定

- **stdout**: 仅在 `--version`、`--help`、设备列表（多设备提示）时使用
- **stderr**: 所有错误信息、`--verbose` 日志、状态进度提示

---

## 错误信息示例

```
# 无设备
error: no OpenHarmony devices found. Connect a device via USB and retry.

# 多设备未指定 -s
error: multiple devices detected. Specify target with -s <serial>:
  SN_ABC123 (USB)
  SN_DEF456 (USB)

# 端口冲突
error: another ohscrcpy instance is already running for device SN_ABC123 (port 5001 in use).

# hdc 不存在
error: hdc not found. Install DevEco Studio or add hdc to your PATH.
  Download: https://developer.huawei.com/consumer/cn/deveco-studio/

# 服务端安装失败
error: failed to install scrcpy server: [install output]
  To install manually: ohscrcpy-server.hap is located at /tmp/ohscrcpy_server_XXXXXX.hap
```

---

## verbose 日志格式（stderr）

```
[ohscrcpy] detecting devices...
[ohscrcpy] selected device: SN_ABC123
[ohscrcpy] checking server version on device...
[ohscrcpy] server not installed, installing bundled v1.0.0...
[ohscrcpy] server installed successfully
[ohscrcpy] setting up port forward: localhost:5001 -> device:53535
[ohscrcpy] connecting to localhost:5001...
[ohscrcpy] connected, waiting for video config...
[ohscrcpy] video config: 1080x2340 @ 60fps, SPS(26B) PPS(4B)
[ohscrcpy] streaming started
[ohscrcpy] fps=59.8 bitrate=7.8Mbps latency=12ms
```

---

## 环境依赖

| 依赖 | 必须 | 检测方式 |
|------|------|----------|
| `hdc` 在 PATH | 是 | `which hdc` 或尝试运行 `hdc version` |
| macOS 11+ | 是 | 构建时静态链接 VideoToolbox |
| USB 调试模式已开启 | 是（运行期检测） | `hdc list targets` 返回非空 |
