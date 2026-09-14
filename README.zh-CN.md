<img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_128.png" width="80" height="80" alt="SmartShot 图标">

# SmartShot

**macOS 截图、标注与录屏工具。**

SmartShot 将智能选区、区域截图、长截图、图片编辑、本地 OCR 和录屏集成在一个原生 macOS 应用中。截图处理在本机完成，无需账号，不包含分析遥测或云端上传服务。

[English](README.md) | [简体中文](README.zh-CN.md)

macOS 14+ · Swift 6 · 开发版本 0.2.2

## 功能

| 使用场景 | 已实现内容 |
| --- | --- |
| 截图 | 选择窗口或具有辅助功能信息的内容块，切换嵌套选区，或手动拖出区域。支持自定义全局快捷键和延时截图。 |
| 长截图 | 手动滚动固定区域并拼接；对兼容的原生滚动区域使用 **Automatic App Scroll（实验性）**；通过浏览器扩展截取完整网页内容块。 |
| 图片编辑 | 裁剪、画笔、箭头、矩形、椭圆、文字和编号；马赛克、模糊、不透明遮挡、聚光灯和放大镜。支持移动、删除、撤销、重做以及 100% 至 400% 缩放。 |
| OCR 与遮挡 | 使用 Apple Vision 在本机识别文字，复制文字或遮挡识别结果。敏感信息辅助检测支持邮箱、电话、银行卡号和中国身份证号等模式，分享前仍需检查。 |
| 保存与贴图 | 复制编辑后的截图、置顶贴图、保存 PNG/JPEG，或快速保存到指定文件夹。**Flatten** 将编辑结果合并到当前图片及其历史副本。 |
| 历史与隐私 | 浏览、搜索、重开和管理本地历史。OCR 搜索需要主动开启；私密截图跳过自动存历史和自动复制，仍可手动复制、贴图或保存。 |
| 录屏 | 将区域或当前显示器录制为 MP4，可选系统声音、麦克风及鼠标指针。支持 15/30/60 fps、1920/2560/3840 像素长边上限，以及预览、另存为和 GIF 导出。 |
| 自动化 | 通过 URL Scheme 或应用内置的命令行工具触发截图、快速保存和显示主窗口。 |

## 开始使用

1. 按下方说明构建并启动 SmartShot。
2. 截图与录屏需要 **屏幕录制** 权限。**辅助功能** 权限用于智能内容块选择；没有该权限时仍可手动框选。麦克风权限独立且可选。
3. 点击 **Capture**，或使用应用中显示的快捷键。选择 **Smart**、**Region**、**Long** 或 **App Scroll**，按 Escape 取消。
4. 编辑截图后选择 Copy、Pin、Save 或 Quick Save。录屏入口为 **More > Record Region** 或 **Record Current Display**；Stop 保存 MP4，Cancel 丢弃本次录制。

原生截图的初始快捷键为 `Control-Shift-2`。如果与其他应用冲突，以 SmartShot 显示的快捷键为准，也可以在 Settings 中修改。

## 本地构建

需要 macOS 14+、支持 Swift 6 的 Xcode、[XcodeGen](https://github.com/yonaskolb/XcodeGen)，以及用于浏览器测试的 Node.js。当前代码已在 Apple Silicon 和 Xcode 26.6 环境下测试。

```sh
git clone https://github.com/infinityf4p/SmartShot.git
cd SmartShot
xcodegen generate

xcodebuild -project SmartShot.xcodeproj -scheme SmartShot \
  -configuration Release -derivedDataPath DerivedData \
  build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO

open DerivedData/Build/Products/Release/SmartShot.app
```

上述命令用 ad-hoc 签名覆盖项目中的本地签名身份，**不需要 Keychain 签名证书**。生成的是本地开发应用，并非经过 Developer ID 签名或公证的发行版；签名变化后，macOS 可能要求重新授权。目前没有打包的 GitHub Release。

Safari 扩展开发请改用独立构建脚本：

```sh
Scripts/build_safari_development.sh
```

脚本会校验通用二进制及嵌套签名、打印应用路径，并保留现有 `/Applications/SmartShot.app`。该构建带有仅供开发的调试权限，不应分发。详见 [Safari 开发构建说明](Docs/SAFARI_DEVELOPMENT_BUILD.md)。

## 浏览器扩展

扩展选择一个网页内容块并生成 PNG：可见内容直接截图，较长的内容块则在限定范围内滚动拼接，恢复页面状态后导入 SmartShot。原生导入失败时，会回退到浏览器下载。

**Chrome / Chromium / Edge / Brave**

1. 将完整的普通应用包安装到 `/Applications/SmartShot.app`，在 **Settings > Chromium Integration > Install** 中配置原生通信助手。
2. 打开浏览器的扩展管理页，启用开发者模式，选择 **加载已解压的扩展程序 / Load unpacked**，加载本仓库的 `BrowserExtension` 目录。源码更新后需要重新加载扩展；应用内的 **Reveal Extension** 可以定位已安装应用所附带的扩展副本。
3. 打开允许访问的网页，通过工具栏或 macOS 上的 `Control-Shift-9` 调用 **SmartShot Web Selector**，选择内容块后点击或按 Return 确认。

**Safari**

Safari 需要兼容的 Apple 开发签名，或专用的 **Sign to Run Locally** 构建。后者需要开启 **Settings > Developer > Allow unsigned extensions**，启用扩展并授予网站访问权限；Safari 退出后会重置未签名扩展开关。普通 ad-hoc 或自定义自签名构建本身不足以完成 Safari 扩展安装。目前 Safari 截图与导入仍待完整实机验收。

安装、权限、截图限制和原生通信细节见 [浏览器扩展说明](BrowserExtension/README.md)。

## 验证状态

**2026-09-14** 重新运行了完整自动化测试：

| 测试 | 结果 |
| --- | --- |
| 原生 Swift 测试 | 205 通过，0 失败，0 跳过 |
| 浏览器扩展测试 | 114 通过，0 失败，0 跳过 |

已记录的实机检查包括：受控 Chrome 页面可见区域与长截图导入原生预览、OCR 与敏感文字遮挡、历史搜索、私密截图不写历史、置顶贴图、编辑器刷新及裁剪/移动/删除、PNG/JPEG 输出、系统声音录屏、GIF 导出和取消录制。这些结果只覆盖各自记录的场景。

仍待验收：完整编辑/输出/隐私流程、麦克风实际录制、音画同步、Safari 截图与导入、当前公开 X 网站兼容性、混合显示器与全屏空间，以及长时间录制和故障恢复。详见 [测试计划](Docs/TEST_PLAN.md) 与 [9 月 5 日](Docs/ACCEPTANCE_2026-09-05.md)、[9 月 6 日](Docs/ACCEPTANCE_2026-09-06.md)实机记录。

运行测试：

```sh
xcodebuild -project SmartShot.xcodeproj -scheme SmartShot \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath DerivedData test CODE_SIGNING_ALLOWED=NO

npm --prefix BrowserExtension test
```

上述测试目标适用于 Apple Silicon；Intel Mac 请使用对应的 macOS 架构。自动化测试不操作真实权限，也不能证明浏览器扩展已正确安装。

## 范围与隐私

- 三种长截图各有适用范围：手动固定区域滚动、实验性的原生 AX 自动滚动、浏览器 DOM 内容块截图。原生自动滚动要求内容静态且垂直辅助功能滚动条可写。动态或无限信息流、虚拟列表、嵌套滚动、横向截图和跨显示器拼接不在当前支持范围内。
- 浏览器选择逻辑包含单条 X 帖子的测试样例，但不支持自动截取整条线程或多条帖子；对当前公开 X 网站的兼容性尚未验证。
- 录屏仅使用单个显示器。GIF 无声，最多导出前 30 秒、15 fps、1280 像素长边和 450 帧。摄像头录制、视频裁剪、点击可视化、翻译、云分享和云同步尚未实现。
- 截图历史保存在本机；OCR 索引默认关闭，私密截图不会建立索引。私密截图模式不控制录屏文件或浏览器回退下载。
- 模糊和马赛克属于视觉效果。敏感内容应使用不透明遮挡，并检查导出的图片；不能保证 OCR 检出全部敏感信息。
- 浏览器向原生应用传递 PNG 和有限的技术元数据，包括网站来源，不传递页面 HTML、Cookie、凭据或 URL 路径。Safari 目前使用的命名粘贴板通道仍存在同一用户进程间认证及崩溃清理限制，详见 [交接文档](Docs/HANDOFF.md)。

## 项目文档

- [架构](Docs/ARCHITECTURE.md)
- [需求与范围](Docs/MVP_REQUIREMENTS.md)
- [后续计划](Docs/ROADMAP.md)
- [测试计划与记录](Docs/TEST_PLAN.md)
- [浏览器扩展](BrowserExtension/README.md)
- [Safari 开发构建](Docs/SAFARI_DEVELOPMENT_BUILD.md)

维护者：[infinityf4p](https://github.com/infinityf4p)。
