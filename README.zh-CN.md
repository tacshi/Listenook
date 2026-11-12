# 聆页

[English](README.md) · 简体中文

聆页（Listenook）用来听播客和本地音视频，并配有同步的文字稿。你可以阅读双语翻译、逐句重听、练习英语听写，并在可搜索的资料库里整理录音。

它可在 macOS、Windows、iPhone、iPad 和 Android 上运行。云端转写和 AI 功能使用你自己的 API 密钥；本地转写在所有平台上都在设备本机完成。

[下载](https://github.com/tacshi/Listenook/releases) ·
[隐私](PRIVACY.md)

## 使用聆页

1. 把音频、视频或文件夹拖到窗口里，添加到资料库；或者在“播客”里找一期节目。
2. 选择转写服务商，使用播客自带的文字稿，或者为本地媒体配上已有的 SRT、WebVTT 或 ASS/SSA 文件。
3. 打开文字稿，边听边读，翻译、编辑、练习或导出。

支持的媒体：MP3、WAV、M4A、OGG、MP4、MKV 和 AVI。本地转写支持最长 5 小时的文件。

## 功能

- **边听边读：** 音视频同步播放、按时间戳跳转、搜索文字稿、单句重复和盲听。
- **练习：** 把听到的内容打出来，与文字稿对照；或者逐句跟读，每句重复指定的次数后自动进入下一句。停顿可以选自动，或固定为 1、2、3、5、10 秒。自动停顿等于该句在所选速度下的时长再加半秒，最短 1.5 秒。点按一句即可练习它。开启盲听后，跟读时文字保持隐藏。单词核对目前只支持英语。
- **翻译：** 查看并编辑原文、译文或双语对照。再次翻译只会补上还没有译文的句子，也可以单独重译某一句。
- **订阅播客：** 搜索 Apple Podcasts 的公开结果、打开 RSS 源、订阅节目、试听单集，并下载单集以便进一步学习。发布者提供文字稿（WebVTT 或 SRT）时会直接使用。
- **看带字幕的视频：** 双击视频（或用 **⇧⌘O** / **Ctrl+Shift+O** 打开）即可配着它自己的字幕播放，不必转写，也不会加入资料库。内嵌的文字字幕轨（MKV 的 SRT/ASS/WebVTT，MP4 的 mov_text）以及视频旁边的 SRT、WebVTT 或 ASS/SSA 文件都会列在字幕菜单里。←/→ 跳到上一条/下一条字幕，**R** 开关当前字幕的重复播放。播放器会记住每个视频的字幕选择和播放位置。图形字幕（PGS、VobSub）无法显示。播放器可打开 MP4、M4V、MOV、MKV、WebM 和 AVI：在 macOS 上聆页会出现在**打开方式**里，Windows 安装程序会注册这些类型。可在访达的**显示简介 → 打开方式**或 Windows 的**默认应用**里把它设为默认。
- **导入字幕：** 与媒体同名的 SRT、WebVTT 或 ASS/SSA 文件会成为它的文字稿；有多个匹配的文件时由你选择。导入的字幕使用解析出的时间轴，不会运行语音识别。
- **转写录音：** 批量处理文件，支持说话人标签（服务商支持时）、语言提示、上下文词汇、进度显示和取消。中断的云端任务再次开始时会从停下的地方继续，不会重复上传文件。
- **生成 AI 简报：** 生成可编辑的概览、章节、要点、决定、待办事项、未决问题，以及可选的语言笔记。带时间戳的依据可以跳回原录音。
- **整理与导出：** 编辑文字稿和说话人名称，重新关联丢失的媒体，导出 TXT、Markdown、SRT 或 WebVTT。简报导出为 Markdown。
- **设备间同步：** 与同一局域网内另一台运行聆页的设备互相拷贝资料库。拷贝任何内容之前，对方设备都会先询问。
- **监视文件夹：** 被监视文件夹里的新媒体会加入资料库，随时可以转写。聆页可以留在 macOS 菜单栏或 Windows 托盘里持续监视，也可以开机时启动。

提供跟随系统、浅色和深色主题，以及英文和简体中文界面。键盘快捷键列在**设置 → 快捷键**里。

## 手机和平板

iPhone、iPad 和 Android 应用功能相同，布局为窄屏做了调整：侧边栏变成抽屉，阅读界面里视频位于文字稿上方。

- **导入：** 在 iPhone 和 iPad 上，**添加媒体**会打开“文件”浏览器。在 Android 上，先把媒体放进共享存储里聆页的文件夹，再选择**添加媒体**。聆页会保留自己的一份拷贝；删除录音时这份拷贝也会删除。
- **导出：** 文字稿和简报写入聆页文件夹里的 `Exports`，可以在“文件”应用里看到。

文件夹监视、开机启动、托盘图标和应用内更新只在桌面端提供。

## 转写与 AI 服务商

| 服务商 | 可用范围 | 说明 |
| --- | --- | --- |
| Soniox | 所有平台；需要 API 密钥 | 说话人标签、逐词时间、语言检测，并可在转写时同时翻译。 |
| MOSS Pro | 所有平台；需要 API 密钥 | 通过 MOSI 进行带说话人标签的转写。 |
| MOSS Local | Apple 芯片的 Mac，macOS 15 及以上 | 本地 Core ML 转写，带说话人标签。 |
| Qwen3 Local | 所有平台 | 在 CPU 上进行本地多语言转写，带逐词时间，不带说话人标签。 |

Qwen3 Local 还需要 Qwen3 ForcedAligner 模型来为每个词计时；同一个模型也可以为 MOSS 的文字稿加上逐词时间。本地语音模型需要另行下载并校验，不随应用附带。

文本翻译和 AI 简报共用一个可配置的 AI 服务商。服务商预设会填好连接信息，连接测试成功后会列出该服务商的模型供你选择。

## 数据与隐私

聆页没有自己的后端。开始任务时，云端转写会把媒体直接发送给所选的 Soniox 或 MOSI 服务商。本地转写和字幕导入不会上传媒体。文件夹监视只是发现文件，不会上传。同步只把资料库发送给你在局域网里选定的设备。

手动或自动的大模型翻译，以及你要求生成的 AI 简报，会把文字稿文本发送到你配置的 AI 接口。播客的搜索、订阅源、在线播放和下载会访问相应的公开服务。API 密钥在 macOS、iPhone 和 iPad 上保存在钥匙串里，在 Windows 上保存在凭据管理器里；在 Android 上保存在只有聆页能读取的文件里。

文字稿、设置、本地模型和下载的播客单集都保存在本地。在桌面端，导入的源媒体留在原来的位置；在手机和平板上，聆页会保留自己的一份拷贝。服务商一侧的清理和保留细节见 [PRIVACY.md](PRIVACY.md)。

## 标识与更新

| 项目 | 值 |
| --- | --- |
| Bundle ID | `app.capyvibe.listenook` |
| macOS 数据目录 | `~/Library/Application Support/app.capyvibe.listenook` |
| Windows 数据目录 | `%APPDATA%\Capyvibe\Listenook` |

资料库、设置和密钥沿用早期版本写下的那些：升级后都会保留。选择**设置 → 关于 → 检查更新**时，桌面应用会从本仓库的 [GitHub Releases](https://github.com/tacshi/Listenook/releases) 自行更新。

## 开发

应用是一个 Rust crate，基于 [Native Shell](https://github.com/longbridge/nsh) 构建。需要 Rust 工具链和 `nsh` 命令行工具。

```sh
git clone git@github.com:tacshi/Listenook.git
cd Listenook
cargo run
```

开发运行使用你真实的资料库。`LISTENOOK_DATA_DIR=<文件夹>` 可以把数据放到别处，`LISTENOOK_START=reader|podcasts|settings` 会直接打开最新的文字稿、播客或设置。

`make check` 检查格式和 lint，`make test` 运行测试，`make pr` 两者都跑：这是提交 pull request 之前要过的关。

| 路径 | 内容 |
| --- | --- |
| `src` | 应用本身：页面、UI 组件（[DESIGN.md](DESIGN.md)）、状态和服务 |
| `crates/listenook-core` | 不含 UI 的领域逻辑 |
| `tests` | 无界面运行的用户操作流程 |
| `vendor/qwen-asr` | 打过补丁的语音引擎 |
| `native/speech_worker` | 在 Mac 上运行 MOSS 的 Swift 辅助程序 |
| `scripts`、`packaging` | 构建、发布，以及安装包里附带的内容 |
| `nsh.json`、`theme.json` | 应用的名称、ID 和版本，以及它的主题 |

## 打包

| 平台 | 命令 | 产物 |
| --- | --- | --- |
| macOS 14+ | `scripts/build-macos.sh debug\|release [--arch arm64\|x64]` | 已签名的 `.app`；release 还会生成已公证的 `.dmg` 和更新器用的压缩包 |
| Windows 10+ | `scripts\build-windows.ps1 debug\|release` | 应用文件夹；release 还会生成安装程序和更新器用的压缩包 |
| iOS、iPadOS 18+ | `scripts/build-ios.sh debug\|release`、`scripts/run-ios.sh` | 未签名的构建、已签名的 `.ipa`，或直接装到设备上 |
| Android 8+ | `scripts/build-android.sh debug\|release [--aab]` | `.apk` 或 App Bundle |

产物写入 `build/`。每个脚本在开头列出它读取的签名设置。用 MOSS 做本地语音识别需要 Apple 芯片的 Mac 和 macOS 15 及以上；`scripts/build-speech-worker.sh` 构建它的辅助程序，macOS 构建会把它一并打包。

发布是单独的一步：`scripts/publish.sh <版本号>`，可用选项见 `scripts/publish.sh --help`。先在 Windows 上用 `scripts\build-windows.ps1 release -Version <版本号>` 构建，再把安装程序、它的 `.build.json` 和更新器用的 `.zip` 拷进 `build/`。安装包所附带内容的许可证在 [packaging/notices](packaging/notices) 里。
