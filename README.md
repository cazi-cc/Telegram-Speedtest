# Telegram-Speedtest

针对 Telegram 资源的测速脚本，适合在 VPS 上测试「VPS 到 Telegram 文件服务器」的真实下载表现。

本项目是对 [iyear/tdl](https://github.com/iyear/tdl) 的独立 Bash 封装。脚本不包含、不修改、不重新分发 `tdl` 源码或二进制文件，只在运行时调用 `tdl` 官方安装脚本和命令行接口。

## 一键运行

Windows PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=Join-Path $env:TEMP 'telegram-speedtest.ps1'; iwr -UseBasicParsing 'https://raw.githubusercontent.com/cazi-cc/Telegram-Speedtest/main/telegram-speedtest.ps1' -OutFile $p; & $p"
```

Linux / macOS / BSD：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cazi-cc/Telegram-Speedtest/main/telegram-speedtest.sh)
```

首次运行后，脚本会自动安装联网快捷命令，以后直接运行：

```bash
tst
```

`tst` 每次都会从 GitHub 拉取最新版脚本执行，不使用本地缓存脚本。

## 功能

- 数字菜单交互，不需要记忆 `tdl` 参数。
- 自动安装并调用 `iyear/tdl`。
- 支持二维码登录和手机号验证码登录。
- 支持 VPS 直连、SOCKS5、HTTP 代理。
- 支持 Windows PowerShell 和 Bash 两种入口。
- 使用具体 Telegram 频道/群组资源消息链接测速。
- 分别测试单连接敏感性和多连接总吞吐。
- 默认每轮只限时下载，不完整保存大文件。
- 默认推荐低资源方案：20 秒、多连接 4 线程、每轮 128MiB 磁盘上限。
- 退出、Ctrl+C、SSH 断开时自动清理临时下载文件、残片和日志。
- 退出后仍会保留上一次测试链接，方便下次继续使用。
- 如果 `tdl` 是本次脚本临时安装的，退出时默认删除 `tdl` 主程序。

## 支持环境

脚本支持 Windows PowerShell 和 Bash 两种入口。

Windows 侧使用 `telegram-speedtest.ps1`，首次运行会安装 `tst.cmd` 联网快捷命令。

Bash 侧主要面向 Linux VPS，也尽量兼容常见类 Unix 环境。

已内置的软件包管理器探测包括：

```text
apt-get / dnf / yum / zypper / pacman / apk / pkg / brew
```

只要系统能运行 PowerShell 或 Bash、curl/Invoke-WebRequest 和 `tdl` 官方安装脚本，通常都可以使用。Windows、Debian、Ubuntu、Fedora、CentOS/RHEL、AlmaLinux/Rocky、Arch、Alpine、openSUSE、FreeBSD、macOS 等环境可优先尝试。

## 第一次使用

运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/cazi-cc/Telegram-Speedtest/main/telegram-speedtest.sh)
```

看到菜单后，通常选择：

```text
1. 一键开始推荐低资源测速
```

如果没有登录 Telegram，进入：

```text
5. Telegram 登录管理
```

推荐先选择二维码登录。手机 Telegram 路径通常是：

```text
设置 -> 设备 -> 连接桌面设备
```

然后粘贴具体资源消息链接，例如：

```text
https://t.me/channel_name/12345
https://t.me/c/1234567890/123
```

私有频道或群组的前提是：登录到 `tdl` 的 Telegram 账号本身有权限访问该消息。

## 选择什么资源

建议选择：

- 500MB 以上的资源，最好 1GB 左右。
- 普通 MP4 视频、频道文件、群组文件等可由 `tdl` 下载的消息资源。
- 比较不同 VPS 时始终使用同一条消息链接。

虽然脚本不局限于视频，但仍建议优先用较大的频道视频测试，因为它更贴近日常观看、拖动和缓冲体验。

脚本默认是限时下载测速，不会把大文件完整下载完。资源太小会提前完成，影响对比。

## 怎么看结果

脚本会输出两项：

```text
单连接敏感性：x MiB/s    y Mbps
多连接总吞吐：x MiB/s    y Mbps
```

简单判断：

- 单连接慢、多连接快：节点总带宽可能不差，但 Telegram 资源打开、视频首开和拖动缓冲可能差。
- 单连接和多连接都慢：VPS 到 Telegram 文件服务器方向整体较差。
- 单连接和多连接都快：VPS 到 Telegram 方向通常不是主要瓶颈，应继续检查本地到 VPS 的线路、代理协议、分流、MTU、IPv6 或客户端缓存。

## 低资源说明

默认推荐方案：

```text
单连接：1 线程，1 DC 连接池，20 秒
多连接：4 线程，4 DC 连接池，20 秒
每轮最大下载占用：128MiB
```

更小的 VPS 可以在菜单中选择：

```text
2. 选择测速强度并开始
```

再选择「极低资源」：

```text
12 秒，多连接 2 线程，每轮 64MiB 上限
```

## 会保留什么

每次退出都会清理：

- 临时下载文件。
- 未完成残片。
- 原始测速日志。
- 临时目录。
- 本次由脚本临时安装的 `tdl` 主程序，除非你在菜单中切换为保留。

默认会保留：

- `tst` 联网快捷命令。
- Bash 少量配置：`~/.config/telegram-speedtest/`
- Bash Telegram 登录数据：`~/.tdl/telegram-speedtest/`
- Windows 配置和登录数据：`%APPDATA%\Telegram-Speedtest\`
- 上一次测试链接。

保留登录数据是为了避免每次重新扫码。保留测试链接是为了下次启动后可以直接复用。需要彻底清理登录数据时，在菜单中选择：

```text
8. 清理与空间设置
3. 删除本脚本的 Telegram 登录数据
```

## 代理

菜单内置常见代理端口：

```text
socks5://127.0.0.1:1080
socks5://127.0.0.1:10808
socks5://127.0.0.1:7891
http://127.0.0.1:7890
```

也支持自定义：

```text
socks5://user:pass@127.0.0.1:1080
http://127.0.0.1:7890
```

## 许可证

本仓库中的 Bash 脚本使用 MIT License。

`iyear/tdl` 是第三方项目，当前上游仓库标注为 AGPL-3.0 License。本项目不是 `tdl` 官方项目。
