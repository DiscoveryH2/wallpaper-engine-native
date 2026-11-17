# Wallpaper Engine Native（实验性）

`Wallpaper Engine Native` 是一个**独立、非官方**的 macOS 原生实验项目，用于研究本地动态壁纸的浏览、预览和桌面播放。它与 Wallpaper Engine、Steam、Valve 及其关联方均无隶属、赞助或认可关系。

本公开源码快照仅面向 Apple Silicon（arm64）且 macOS 14 或更高版本的开发和实验用途。

## 这个仓库包含与不包含的内容

包含：

- 本项目的 Swift / Metal / Web / Scene 实验性播放器源码；
- 三个由本项目制作的离线 Starter Wallpaper 演示资源（Scene、Web、Video）；
- 用于校验这些内置演示资源的离线脚本。

不包含，也不会分发：

- Wallpaper Engine 或 Steam/Valve 的二进制文件、SDK、账户凭据；
- Steam 创意工坊下载内容、订阅内容、预览图或其他第三方壁纸资产；
- 任何 Windows 兼容层、第三方壁纸客户端或逆向分析材料。

若尝试读取自己电脑上本地已安装的内容，使用者必须自行拥有相应 Steam、Wallpaper Engine 和内容的合法授权，并尊重每个壁纸作者的许可与使用条件。项目不提供、也不绕过购买、下载、DRM、平台或内容访问限制。

## 状态与限制

这是一个实验性原生原型，而不是 Windows 版 Wallpaper Engine 的移植版或替代品。它不承诺对 Steam 创意工坊、所有壁纸类型、所有 Scene 脚本、特效、着色器、交互或音频响应提供兼容性，更不承诺与 Windows 版的功能或界面做到 1:1 一致。

### 0.216.1 修复

- **Steam 接口版本协商。** Steam 客户端 2026-11-13 的更新把 `SteamUser` 从 v023 升到 v024，并移除了旧的导出符号，因此之前写死 `SteamAPI_SteamUser_v023` 的构建会以 `Installed Steam API lacks SteamAPI_SteamUser_v023` 失败（订阅同步、工坊浏览/下载、投票、收藏全部不可用）。现在改为探测该 Steam 安装实际导出的最新 `NNN` 访问器；访问器与同一份签名 dylib 内的 `SteamAPI_ISteam*` 包装函数配套，因此不需要重新固定 ABI 版本。`SteamUGC`/`SteamUtils`/`SteamApps` 同样按此规则解析，未来版本上调不会再次写死失败。
- **切换壁纸后桌面不变化。** 0.215 的逐显示器分配会在主库手动选择默认壁纸时继续压住该屏幕：`lastProject` 和库里的“默认”标记都更新了，桌面窗口却仍按保存的分配渲染旧壁纸。现在手动选择默认壁纸时，会在同一提交窗口内清掉**已连接**显示器的独立分配并持久化布局；断开连接的显示器条目保留，重新插上后仍恢复自己的壁纸。
- 补完源码中未完成的截屏请求重构（`NativeDesktopWallpaperScreenshotRequest`），使 `./native/build.sh` 可以从这份快照完整编译。

已知限制包括：

- 仅支持 Apple Silicon / macOS 14+；Intel Mac 和更早的 macOS 不在支持范围内；
- 对本地内容的解析与渲染覆盖有限；复杂的 Scene、Web、视频或特定 Windows 渲染路径可能无法加载、显示异常或回退；
- 多显示器、桌面合成、Finder 图标层级、睡眠恢复与跨桌面空间等系统行为仍需在各机器上单独验证；
- 发布构建使用 ad-hoc 签名，**没有 Developer ID 签名，也没有 Apple 公证（notarization）**。Gatekeeper 可能阻止启动；仅应由理解风险的开发测试者使用。

## 从源码构建

前提：Apple Silicon Mac、macOS 14+、Xcode Command Line Tools（包含 `xcrun swiftc`）和 Python 3。

先在仓库根目录验证项目自带演示资源：

```sh
python3 tools/bundled_wallpapers.py --verify
```

然后构建到一个新的、绝对路径的 `.app` 输出目录：

```sh
./native/build.sh --output "$PWD/out/Wallpaper Engine Native.app"
```

脚本会编译本项目自己的辅助工具和应用，并对产物进行 ad-hoc 签名；不会下载 Steam、Wallpaper Engine 或创意工坊内容。`out/`、`native/build/` 和 `synchronizer/build/` 是本地构建输出，不应提交。

## 许可与贡献

本项目的原创源码按仓库根目录的 [MIT License](LICENSE) 发布。随附的 Starter Wallpapers 是项目制作的演示资源；品牌、商标、官方程序以及任何用户自行安装或下载的内容仍归各自权利人所有。

请在问题报告中附上 macOS 版本、芯片型号、壁纸类别和可公开分享的最小复现信息；不要上传创意工坊内容、Steam 凭据、个人目录或其他私有数据。
