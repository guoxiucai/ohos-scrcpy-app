# ohscrcpy

OpenHarmony 设备投屏 CLI 工具，通过 USB 连接实现设备屏幕实时镜像与远程控制。

## 快速安装

```bash
curl -sSL https://raw.githubusercontent.com/robin8yeung/ohscrcpy-cli/main/scripts/install.sh | sh
```

## 前置要求

- macOS 11+（Apple Silicon 或 Intel）
- `hdc` CLI 工具（DevEco Studio 附带）
- OpenHarmony 设备已开启开发者模式并通过 USB 连接

## 使用方法

```bash
# 连接唯一设备
ohscrcpy

# 指定设备序列号
ohscrcpy -s <serial>

# 调整分辨率和码率
ohscrcpy --max-size 1024 --bit-rate 4M

# 详细模式
ohscrcpy -v

# 查看帮助
ohscrcpy --help
```

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-s, --serial <serial>` | 指定目标设备序列号 | 自动选择唯一设备 |
| `--max-size <px>` | 限制画面最大边长 | 无限制 |
| `--bit-rate <value>` | 视频码率（支持 K/M 后缀） | 8M |
| `--fps <value>` | 目标帧率 | 60 |
| `-v, --verbose` | 启用详细日志 | 关闭 |
| `--version` | 打印版本号 | - |
| `-h, --help` | 显示帮助信息 | - |

## 构建源码

```bash
# 安装 Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin

# 安装 SDL2
brew install sdl2

# 克隆仓库
git clone https://github.com/robin8yeung/ohscrcpy-cli.git
cd ohscrcpy-cli

# 构建
bash scripts/build_cli.sh
```

## 项目结构

```
ohscrcpy-cli/
├── cli/                    # Rust CLI 源代码
│   ├── src/
│   │   ├── main.rs         # 入口
│   │   ├── args.rs         # 参数解析
│   │   ├── hdc.rs          # hdc 命令封装
│   │   ├── server.rs       # 服务端安装
│   │   ├── connection.rs   # TCP 协议
│   │   ├── decoder/        # H.264 解码
│   │   └── renderer/       # SDL 渲染
│   ├── assets/
│   │   └── scrcpy_server.hap  # 内嵌服务端 HAP
│   └── Cargo.toml
├── scrcpy_server/          # OpenHarmony 服务端
├── scripts/
│   ├── install.sh          # 一键安装脚本
│   └── build_cli.sh        # 构建脚本
└── release/                # 预编译二进制
```

## 工作原理

1. **设备检测**：通过 `hdc list targets` 检测已连接设备
2. **服务端安装**：自动检测并安装内嵌的服务端 HAP
3. **端口转发**：建立 `hdc fport tcp:<pc_port> tcp:53535`
4. **视频流传输**：服务端采集屏幕并编码为 H.264，通过 TCP 推送到客户端
5. **渲染与控制**：解码视频并渲染到 SDL 窗口，鼠标事件转换为触控指令

## 许可证

MIT
