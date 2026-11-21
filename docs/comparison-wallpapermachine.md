# 和 WallpaperMachine 的对照

参考对象是 [MMFoundation/WallpaperMachine](https://github.com/MMFoundation/WallpaperMachine)，同样把 Wallpaper Engine 的壁纸搬到 macOS 上。这份文档只做两件事：把两者的差距摆出来，记下这一版做了什么、没做什么。

**许可提醒：** 对方是 GPL-3.0，本项目是 MIT。代码一行都不能搬，能借的只有思路和文档里写明的取舍。

## 对方是什么规模

```
719,573 行（含第三方 stb_image / naga / msdfgen）
1,118 个 Swift 文件 + 一个 Rust workspace + 一个 C++ 引擎目录
GPL-3.0，macOS 15+，Apple Silicon
Release 经过 Apple 公证，有 brew cask、官网、四种语言的 README
```

对方的技术路线：C++ 引擎画场景，Rust 做渲染核心与桥，Swift 做壳；GLSL 方言用 vendored naga（只开 glsl-in 与 msl-out 两个 feature）翻成 MSL。这跟我们"自己写一个源码到源码的翻译器"是同一个问题的两种解法，他们的选择是复用现成编译器前端。

## 一、GPU 利用率

### 1. 渲染后端：我们有一半内容还在 OpenGL 上

这是实测出来的，不是猜的。把两张工坊里的 3D 场景设为桌面壁纸，各采样 2–3 秒：

```
Looking Deep in The Sky（1308734162）   SceneWallpaperView 命中 73 次   NativeMetalCreationView 0 次
海贼王（1134047165）                    SceneWallpaperView 命中 33 次   NativeMetalCreationView 0 次
```

`SceneWallpaperView` 是 `NSOpenGLView`。也就是说这两张真实壁纸走的是 OpenGL 回退，不是 Metal 主路径。Apple 硅上的 OpenGL 本身是"GL 调用翻译成 Metal"的一层 shim，等于在原生渲染前面又套了一层。

对方只有一条路径：Metal。文档里甚至专门写了一节"当 Native Metal 画不了这个场景时"怎么办。

### 2. 帧率：实测 18–22 fps，目标是 60

同一台 M4，默认帧率上限 60，两张场景的实测帧率：

```
Looking Deep in The Sky   18 – 26 fps
海贼王                     21 – 22 fps
```

对方的文档里不给 fps，给的是每帧 GPU 时间和每张壁纸的功耗（低 < 0.5 W，中 < 2 W，高 ≥ 2 W）。这比 fps 更接近壁纸这个品类的真实指标：壁纸是常驻程序，用户感知的是风扇和电，不是帧数。

### 3. pass 级复用：他们有 render graph，我们没有

对方的场景渲染器里有一张渲染图，按"输入签名"决定哪些子图可以复用：

- 采样视频的 pass，在同一帧视频上可以复用（慢视频、暂停的视频后面整条链都不用再画）
- 绑定音频频谱的 pass，频谱数组没变就复用（没播音乐时可视化的整条链停画）
- 图层自己的 pass，在图层和相机都不动时复用，判据是"着色器编译器证明能影响画面的 uniform"，不是"声明了哪些 uniform"

他们的实测案例：某张壁纸每帧因此少画 17 个 pass，约省 8% GPU 时间。

我们这边是固定的 pass 链，每帧全画，没有复用表。`requiresContinuousRedraw` 只做了一个粗粒度的"要不要继续重绘"判断。

### 4. 重复帧与静止画面

对方有两节专门写这个：「Frames that would repeat the picture」和「Update only when the scene changes」，判据覆盖到"慢视频、暂停视频、静音频谱、静止图层"。

我们的 `requiresContinuousRedraw` 只判断"有没有动画/脚本/视频/相机运动"，判不了的默认当动的，宁可多画。

### 5. 纹理：我们解码成 RGBA 上传

```
对方：shader 请求里显式声明纹理格式（文本里出现 `format: "bc1"`），保留块压缩
我们：SceneAssets 解出 RGBA → NativeMetalRenderer 用 .rgba8Unorm 上传
      BC3 直传（glCompressedTexImage2D）只存在于 OpenGL 回退路径
```

一张 4096×4096 的贴图，RGBA8 是 64 MB，BC3 是 16 MB，采样带宽也差 4 倍。我们单张壁纸常驻 771 MB（实测 RSS），纹理是其中主要一项。

顺带一个本机实测：Metal 支持 BC 压缩纹理（`supportsBCTextureCompression = true`，4096² 的 `bc1_rgba` / `bc3_rgba` / `bc3_rgba_srgb` 都能创建），但不暴露 ETC2 格式（`MTLPixelFormat` 里没有 `etc2_rgba8`）。所以 type 4 可以直传，type 5 只能解码。

### 6. 功耗可观测性

对方用内核的 coalition 记账（不申请 root）读本 app 的能耗，给出分级、电池占比、改设置前后的对比，并给每张壁纸一个功耗评级。

我们这一版加了一个状态栏读数：实帧率，以及 Metal 场景下每帧 GPU 毫秒与 GPU 占用率。OpenGL 回退路径只能数帧，报不出 GPU 毫秒（GL timer query 在 macOS 上的支持不可靠）。这一步只是让"改动到底省了多少"变成可比较的数字。

### 7. 管线缓存

对方文档里有「Metal compile across processes」一节。我们每次启动用 `makeLibrary(source:)` 现编 15 个 MSL 模块，没有 `.metallib`，也没有 `MTLBinaryArchive`。

## 二、功能完整性

对方 README 的功能表逐条读下来，我们缺的是这些（都是可查证的存在性，不是评价）：

| 能力 | 对方 | 我们 |
|---|---|---|
| 锁屏壁纸（Scene/视频/网页都能动） | 有，独立 Extension | 无（全仓 0 处提及） |
| 桌面小组件（时钟/日历/便签/倒计时…） | 有，可拖拽排版 | 无 |
| pixiv 排行榜与标签搜索 | 有，可存为静态壁纸 | 无 |
| 备份与恢复（设置 + 库） | 有，恢复前预览冲突 | 无 |
| 自动化（日程、日出日落、Focus、空间） | 有 | 部分（应用规则） |
| 库放外置盘 | 有 | 无 |
| 图片导入与逐屏摆放 | 有 | 无 |
| 功耗读数与每壁纸评级 | 有 | 本版新增状态栏读数 |
| 画质档位（渲染缩放、2D 分辨率、电池策略） | 有 | 部分（帧率、纹理分辨率、品质预设） |
| 多语言 UI | 5 种 | 中文 |
| WebM/VP9 视频壁纸 | 自写 WebM 播放器 | 依赖 AVFoundation，VP9 放不了 |

反过来，我们这边对方没有明确写的：本机 Steam 登录态直连（不二次登录）、逐显示器作者参数、原生编辑器与 `.wenative` 格式。

## 三、这一版做了什么

1. **状态栏渲染读数**：实帧率；Metal 场景另报每帧 GPU 毫秒和 GPU 占用率。用于判断"改一个画质档位到底省了多少"。
2. **对照文档**：就是这一份，把差距写成可执行清单。

没做、也不假装做了的：render graph 复用、Metal 覆盖工坊场景、BC3 直传、锁屏、pixiv、桌面小组件。这些每一项都是独立工程，见下一节的工作量。

## 四、按性价比排的下一步

```
① Metal 覆盖工坊场景        现在真实壁纸只有 20 fps，这是最大的一处
                            做法：把 legacyReason 收集成统计，按原因聚类，一类一类补
② BC3 直传（Metal）         一张 4K 贴图省 48 MB 显存、4 倍采样带宽
                            难点：Metal 压缩纹理不能由 compute 写入，mip 链要用作者自带的
③ 静止/重复帧跳过           慢视频、静音频谱、静止图层不必每帧重画
                            可以先用"画面签名"的粗版本，不必一上来就做完整 render graph
④ pass 复用表                在 ③ 的基础上做，收益上限最高，也最容易画错
⑤ 管线缓存（MTLBinaryArchive） 只影响启动与首次切壁纸
⑥ 锁屏 / 小组件 / pixiv      产品面扩张，跟渲染无关，逐项独立排期
```

## 五、一句话

对方领先的地方不是某行代码，是**渲染架构**：一条 Metal 管线 + 一张能复用的渲染图 + 一套功耗度量。我们现在的瓶颈也正好在这三处：真实壁纸还在 OpenGL 上、每帧全画、没有功耗数字。这一版补上了第三处的第一块，前两处写在这份文档里等排期。
