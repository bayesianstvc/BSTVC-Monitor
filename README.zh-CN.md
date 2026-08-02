<p align="center">
  <img src="docs/images/bstvc-monitor-logo.png" alt="BSTVC Monitor 标识" width="220">
</p>

# BSTVC Monitor 中文说明

BSTVC Monitor 是面向 Windows 的 INLA 进程资源监视器。它帮助用户在相同模型、数据和收敛条件下比较不同线程参数，寻找适合自己电脑或工作站的线程数。

> 重要：产品名称是 **BSTVC Monitor**，实际监测的 Windows 进程通常仍然是 `inla.exe`，不需要修改 INLA 或模型代码。

## 快速开始：下载后只需双击一个文件

**[下载 Windows 压缩包：`BSTVC-Monitor-v0.5.0-windows.zip`](https://github.com/bayesianstvc/BSTVC-Monitor/raw/refs/heads/main/dist/BSTVC-Monitor-v0.5.0-windows.zip)**

下载完成后：

1. 打开 Windows“下载”文件夹，右键 `BSTVC-Monitor-v0.5.0-windows.zip`，选择“全部解压”。
2. 打开解压后的 `BSTVC-Monitor-v0.5.0-windows` 文件夹。
3. 双击 **`Start-BSTVC-Monitor.cmd`**。这是正确的启动文件，会启动采集器并打开网页界面。
4. 浏览器打开 `http://127.0.0.1:8765/` 后即可开始监测。

> **不要直接双击 `dashboard.html` 启动工具。** 它是由本地监视器加载的网页界面，单独打开无法连接本地 API。请始终从 **`Start-BSTVC-Monitor.cmd`** 开始。

`inla.exe` 可以在监视器启动前或启动后运行；新进程会自动识别，已结束进程仍会保留在记录中。解压后的文件夹可以直接移植使用，请保持文件完整并放在一起。

英文界面默认打开，点击顶部语言按钮即可切换中文。采样间隔默认 5 秒，页面刷新默认 10 秒，两者可以独立设置。

## 主要功能

- 与 Windows 任务管理器“进程”页直接对照的整机 0–100% CPU 主曲线。
- 平均 CPU、计算阶段 CPU、运行时间、平均线程数和 Working Set 内存（GB）比较。
- 多个 PID 分区，并用 PID、开始时间、运行时长和运行/结束状态区分进程。
- 自定义模型名称，例如 `BSTVC 10X`、`BSTVC 20X`。
- CPU 与内存曲线的同步时间选择、悬停提示、子模型曲线叠加和时间导航。
- 阶段识别、综合评价、高级监测、完整实验包和 HTML 报告。
- 页面问题处理：安全重连、清理浏览器页面缓存、开始新监测、自检和页面恢复。

## 默认数据位置

```text
%LOCALAPPDATA%\BSTVC-Monitor\runs\
```

完整 CSV 保存在本地；“重新连接监视器”和“清理页面缓存”不会删除 CSV。也可以用 PowerShell 参数指定其他目录：

```powershell
.\Start-BSTVC-Monitor.ps1 -OutputDirectory "D:\BSTVC-Monitor-Data\runs" -IntervalSeconds 5
```

## 如何判断线程参数

先比较选定窗口的平均 CPU，再结合有效计算阶段、运行时长、稳定性、平均线程、GB 内存和 I/O/内存风险。CPU 高不等于模型一定更快，也不等于结果质量更高；最终仍需核对收敛、警告、数值结果和科学解释。

主曲线使用整机 0–100% 口径，适合与任务管理器“进程”页对照。高级诊断中的单核或逻辑核心计数器可能超过 100%，不应替代主曲线。

完整的指标定义与限制见 [Accuracy and interpretation](docs/accuracy-and-interpretation.md)，英文完整说明见 [README.md](README.md)。

## 隐私与许可

工具只在本机运行，默认只绑定 `127.0.0.1`，不上传模型数据或监测结果。项目采用 [AGPL-3.0](LICENSE) 开源许可。
