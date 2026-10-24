# DriveTemp

macOS 菜单栏外接硬盘温度监控，原生 Swift 编写，无第三方运行时依赖。

<img src="docs/screenshot.png" width="320" alt="截图">

## 它解决什么问题

Mac 上看不到外接硬盘的温度。iStat Menus、Stats 这类工具只读 Apple 自家传感器，外接盘的温度藏在盘自己的 SMART 日志里，它们读不到。

这个工具直接调用 `smartctl` 读 NVMe 的 SMART 健康日志，把主控和闪存温度放进菜单栏，超过阈值弹通知，并保留历史曲线。

## 功能

- 菜单栏直接显示当前最高温度，点开是完整面板
- 多块盘同时在线，顶部标签切换，各自独立记录与告警
- 温度曲线带坐标轴刻度，固定 20 到 90 度量程，84 度为告警参考线
- 超过阈值（默认 75 度）弹系统通知，30 分钟内不重复提醒
- 记录连接时长，拔出清零，插回重新计时
- 数据存 CSV，可导出 HTML 报告

## 依赖

- macOS 13 或更高
- `smartctl`（smartmontools）

```bash
brew install smartmontools
```

脚本默认找 `~/.local/bin/smartctl`，找不到时回落到 PATH。如果装在别处，改 `main.swift` 顶部的 `smartctlPath`。

## 构建

```bash
xcode-select --install      # 需要 swiftc
./build.sh                  # 只编译到 build/
./build.sh install          # 编译并安装到 ~/Applications
```

装好后到 系统设置 > 通用 > 登录项 添加这个 app，就能开机自启。

## 配置

改阈值：

```bash
defaults write com.leo.tbtemp threshold 70
```

采样间隔、量程、曲线点数在 `main.swift` 顶部的常量区。

## 文件位置

| 内容 | 路径 |
|---|---|
| 采样数据 | `~/Library/Logs/tb-monitor.csv` |
| 告警记录 | `~/Library/Logs/tb-alerts.log` |
| HTML 报告 | `~/Library/Logs/TBTemp-report.html` |
| 连接状态 | `defaults read com.leo.tbtemp connectedSince` |

CSV 格式：`时间,复合,主控,闪存,告警,链路,设备序列号`。第七列是后加的，老数据的六列行会归到第一块盘。

## 支持范围与限制

**能读温度的前提**：硬盘走雷雳或 USB4 的 PCIe 隧道，`smartctl` 才能拿到 NVMe 的 SMART 日志。

**读不到的情况**：普通 USB 接口的移动硬盘，多数桥芯片不透传 SMART。典型报错：

```
Read NVMe SMART/Health Information failed: GetLogPage failed: code=706
```

这种盘会被识别出来，型号、接口、连接时间都正常，但温度显示「无数据」。这是盒子硬件的限制，换任何工具都一样。

内置的 Apple SSD 默认被排除，因为它不是「外接」，且没必要盯。

## 已知问题

- 未签名的本地编译应用，首次打开可能需要右键选择「打开」
- 面板不会随失焦自动关闭，再点一次菜单栏图标收起
- 曲线横轴按采样点均匀分布，不是严格时间轴，采样中断处不会留白

## 许可

MIT
