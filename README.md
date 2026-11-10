# HiDPI Studio

原生 macOS 显示器管理工具，使用 Swift、SwiftUI、AppKit 和少量 Objective-C。支持原生 HiDPI 模式、系统与 DDC 亮度、虚拟屏幕、屏幕预览及显示配置管理。

独立项目，与 BetterDisplay 无关联。许可证：MIT。

## 下载与运行

从 [Releases](https://github.com/BrandonVee/HiDPIStudio/releases) 下载 `HiDPIStudio-v2.4.0-macOS-arm64.zip`，解压后打开 **HiDPI Studio.app**。当前版本为预览版。

- 发布的应用包适用于 **Apple Silicon**。构建目标为 macOS 13+，实际测试环境为 macOS 26.4 / Apple M5 Pro。
- 应用采用本地 ad-hoc 签名，**未经 Developer ID 签名或 Apple 公证**。下载后 macOS 可能阻止直接打开；请按系统“隐私与安全性”提示操作。
- 不需要关闭 SIP 或安装显示器驱动。硬件能力依显示器、连接方式和 macOS 版本而异。

## 功能

| 功能 | 行为 |
| --- | --- |
| 原生 HiDPI | 合并公开模式与 WindowServer 隐藏的原生 2× 模式；尺寸分组，刷新率下拉选择。 |
| 自定义 HiDPI | 指定桌面尺寸及 24–240 Hz；匹配原生模式时直接使用，否则采用虚拟 Retina 屏幕镜像。 |
| 硬件亮度 | 优先 macOS DisplayServices；外接屏不支持时使用 Apple Silicon IOKit/IOAVService DDC，写后读回确认。 |
| 软件滤镜 | 单独的软件调暗和暖色滤镜；鼠标穿透，退出移除，不冒充硬件背光。 |
| 收藏与预设 | 按显示器 UUID 保存模式及多屏配置，支持菜单栏和组合快捷键调用。 |
| 虚拟屏幕 | 最多保存 8 个定义，可独立连接、断开和移除；数量和刷新率受系统限制。 |
| 画中画 | ScreenCaptureKit 浮动预览，最高 1080p/30 fps，无音频，不转发鼠标。 |
| 布局管理 | 调整相对位置、主屏，保存分辨率、刷新率和位置。 |
| 亮度联动 | 外接屏按比例跟随内置屏；可分别选择目标和比例，默认关闭。 |
| 自动恢复 | 唤醒或重连后恢复指定的已保存配置；默认关闭，不持续覆盖手动调整。 |
| 原生亮度键 | F1/F2 系统亮度事件控制鼠标所在的受支持屏幕；默认关闭。 |

显示模式和布局采用 15 秒试用确认。确认的原生设置退出后继续生效；虚拟屏幕和镜像需要应用运行。关闭窗口仍在菜单栏运行。

单击菜单栏图标可打开显示控制中心：查看当前屏幕与分辨率、调节硬件亮度和软件滤镜、调用收藏与布局预设，以及开关亮度联动和唤醒恢复。右键图标保留原生快捷菜单。分辨率与布局变更仍需在主窗口完成试用确认。

亮度联动和自动恢复位于“联动与恢复”，F1/F2 位于“快捷键”。自动恢复需要先在“布局与预设”保存配置。

## 权限与兼容性

- **录屏权限**：只在主动启动画中画预览时请求。
- **辅助功能权限**：只在主动开启原生亮度键控制时请求。自定义组合快捷键无需此权限。
- 应用不包含联网请求、分析上报或许可证服务器。
- DisplayServices、IOAVService、CGVirtualDisplay 和 CGS 扩展模式包含**非公开系统接口**，运行时检查兼容性。后续 macOS 更新可能使部分功能不可用。
- DDC 当前仅实现亮度 `0x10`，不是通用 VCP 控制台。Intel DDC 尚未实现。扩展坞、转换器或显示器可能不传递 DDC。
- 底层 IOAV 同步调用没有可中断的硬截止时间；后台串行队列和有限重试不等于硬超时。
- 隐藏模式描述仅报告整数 Hz；应用后的实际模式需要读回校验。不匹配时恢复，不能保证任意尺寸或刷新率成功。
- 未实现 HDR/XDR 超亮、EDID 覆写、强制 RGB/YCbCr、物理屏幕软断连、输入源/音量控制或持续布局锁定。

## 从源码构建

安装 Apple Command Line Tools，包含 Swift 和 macOS SDK。无需第三方依赖或完整 Xcode 工程。

```bash
./build.sh "$PWD/.build/HiDPI Studio.app"
open '.build/HiDPI Studio.app'
```

脚本按当前 Mac 架构构建。发布包为 arm64，其他架构未验证。

## 自动构建与发布

GitHub Actions 在推送 `main`、提交 PR 或手动触发时构建 ARM64 应用，运行隔离检查并提供 ZIP 与 SHA256 下载；推送 `v*` 版本标签后，检查通过才会自动发布预览版 Release。版本标签必须与 `Resources/Info.plist` 中的三段版本号一致。

```bash
# 本地执行与 CI 相同的构建、检查、签名验证及 ZIP 打包
./scripts/package.sh

# 提交并创建版本标签后，先备份 GitLab，再推送 GitHub
# 示例标签；每次发布请使用尚未发布的新版本号
git publish --tag v2.4.0
```

发布产物为 `dist/HiDPIStudio-v<版本>-macOS-arm64.zip` 和对应的 SHA256 文件。构建日志与分支安装包在 [Actions](https://github.com/BrandonVee/HiDPIStudio/actions) 查看，标签版本在 [Releases](https://github.com/BrandonVee/HiDPIStudio/releases) 下载。

完整发布步骤、重试与签名范围见 [发布流程](docs/RELEASING.md)。

## 验证

以下检查不会主动写入物理显示器亮度或分辨率：

```bash
APP='.build/HiDPI Studio.app/Contents/MacOS/HiDPIStudio'
"$APP" --test-ci
"$APP" --diagnose
"$APP" --brightness-read
```

`--test-ci` 运行隔离偏好与模拟 I/O 检查，不切换实体显示模式、不写入硬件亮度、不创建虚拟屏幕，也不请求录屏或辅助功能权限。

`--test-automation` 的物理配置检查仅验证当前配置无需改变。使用隔离偏好，不会开启用户的自动化设置。

`--test-virtual`、`--test-workspace` 和 `--test-persistence` 会短暂添加测试虚拟屏幕，可能引起窗口或布局调整；运行前退出 GUI。`--test-ddc-live ID`、`--test-sync-live ID`、`--test-hidden-native ID` 会实际修改指定外接屏，属于显式硬件测试，不应作为普通自动化检查运行。

实际测试记录和未验证场景见 [验证范围](docs/VALIDATION.md)。

## 代码结构

- `DisplayCore.swift` / `HiddenDisplayModes.h/.m`：公开/隐藏模式、事务、快照及恢复。
- `NativeBrightness.swift` / `DDCBrightness.swift` / `DDCTransport.h/.m`：系统优先的亮度控制。
- `DailyControls.swift`：软件滤镜、收藏与亮度界面。
- `VirtualWorkspace.swift` / `ScreenPreview.swift`：虚拟桌面及画中画。
- `LayoutProfiles.swift` / `AutoRestore.swift`：布局预设与唤醒/重连恢复。
- `BrightnessSync.swift` / `NativeBrightnessKeys.swift`：亮度联动与原生亮度键。
- `StudioView.swift` / `StatusPanel.swift` / `AppDelegate.swift`：主窗口、菜单栏控制中心及生命周期。

## 实现参考

系统接口与协议语义参考 [m1ddc](https://github.com/waydabber/m1ddc)、[MonitorControl](https://github.com/MonitorControl/MonitorControl)、[Crisp](https://github.com/didriksg/Crisp) 及 [Chromium 的虚拟显示测试](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm)。桥接与应用逻辑为独立实现，未捆绑这些项目的可执行程序。BetterDisplay 的功能与概念说明见[官方文档](https://betterdisplay.pro/guide/)。
