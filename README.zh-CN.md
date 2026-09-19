<img src="Resources/Assets.xcassets/AppIcon.appiconset/icon_128.png" width="80" height="80" alt="SmartShot 图标">

# SmartShot

**macOS 截图、标注与录屏工具。**

SmartShot 将智能选区、区域截图、长截图、图片编辑、本地 OCR 和录屏集成在一个原生 macOS 应用中。截图处理在本机完成，无需账号，不包含分析遥测或云端上传服务。

[English](README.md) | [简体中文](README.zh-CN.md)

macOS 14+ · Swift 6 · 预览版

![SmartShot 主界面](Docs/Images/main-window.jpg)

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

## 下载

[下载最新 SmartShot 预览版](https://github.com/infinityf4p/SmartShot/releases)。每版均提供同时包含 Apple Silicon 和 Intel 架构的通用应用，请在对应版本的附件中选择：

- macOS DMG：`SmartShot-<version>-universal.dmg`
- macOS ZIP：`SmartShot-<version>-universal.zip`
- 浏览器扩展 ZIP：`SmartShot-Web-Selector-<version>.zip`
- SHA-256 校验文件：`SHA256SUMS.txt`

该预览版使用 ad-hoc 签名，没有 Developer ID 证书或 Apple 公证。macOS 可能会阻止下载的应用，需要你在 Finder 或“隐私与安全性”中明确允许打开。安装包不含 `get-task-allow` 调试权限。

## 开始使用

1. 将 `SmartShot.app` 放入 `/Applications`，启动后允许 **屏幕录制**；**辅助功能**用于智能选区，麦克风权限可选。
2. 点击 **Capture（截图）**，或按 `Control-Shift-2`（可在设置中修改），再选择截图模式；按 Escape 取消。
3. 编辑后复制、贴图或保存。**Save（保存）**直接写入指定文件夹，旁边箭头打开保存弹窗；关闭截图返回主界面。录屏入口为 **Record（录屏）> Record Region / Record Current Display**。

默认使用英文。在 **Settings > General > Language** 中选择 **简体中文**，重启后生效，选择会保存。

## 本地构建

需要 macOS 14+、支持 Swift 6 的 Xcode 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

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

上述命令使用 ad-hoc 签名，无需签名证书；macOS 可能要求重新授权。Safari 扩展开发见 [专用构建说明](Docs/SAFARI_DEVELOPMENT_BUILD.md)。

## 浏览器扩展

扩展选择一个网页内容块并生成 PNG：可见内容直接截图，较长的内容块则在限定范围内滚动拼接，恢复页面状态后导入 SmartShot。原生导入失败时，会回退到浏览器下载。

**Chrome / Chromium / Edge / Brave**

1. 将完整的普通应用包安装到 `/Applications/SmartShot.app`，在 **Settings > Chromium Integration > Install** 中配置原生通信助手。
2. 打开浏览器的扩展管理页，启用开发者模式，选择 **加载已解压的扩展程序 / Load unpacked**，加载解压后的浏览器扩展 ZIP 目录，或本仓库的 `BrowserExtension` 目录。更新后需要重新加载扩展；应用内的 **Reveal Extension** 可以定位已安装应用所附带的扩展副本。
3. 打开允许访问的网页，通过工具栏或 macOS 上的 `Control-Shift-9` 调用 **SmartShot Web Selector**，选择内容块后点击或按 Return 确认。

**Safari**

Safari 需要兼容的 Apple 开发签名，或专用的 **Sign to Run Locally** 构建。后者需要开启 **Settings > Developer > Allow unsigned extensions**，启用扩展并授予网站访问权限；Safari 退出后会重置未签名扩展开关。普通 ad-hoc 或自定义自签名构建本身不足以完成 Safari 扩展安装。目前 Safari 截图与导入仍待完整实机验收。

安装、权限、截图限制和原生通信细节见 [浏览器扩展说明](BrowserExtension/README.md)。

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
- [自动发布预览版](Docs/PREVIEW_RELEASES.md)

维护者：[infinityf4p](https://github.com/infinityf4p)。
