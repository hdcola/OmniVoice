# OmniVoice

**[English](README.md) | 简体中文**

**macOS 上的实时转录、翻译与语音输入——默认完全在本机运行。**

OmniVoice 是一款菜单栏应用，适用于听课、开会和多语言交流。它把听到的内容实时显示在
字幕悬浮窗里，能翻译屏幕上任意位置的文字和截图，还能把你说的话输入到任何 App。
语音识别和翻译既可以用 macOS 内置框架，也可以用本地模型，不依赖云服务。

**当前版本：0.7.0——内部测试版。**

### [⬇ 下载 OmniVoice 0.7.0 (.dmg)](https://github.com/hdcola/OmniVoice/releases/download/v0.7.0/OmniVoice-0.7.0.dmg)

也可以用 [Homebrew](https://brew.sh) 安装：

```bash
brew tap hdcola/tap
brew trust hdcola/tap      # 仅 Homebrew 7+ 需要
brew install --cask omnivoice
```

此版本为 **ad-hoc 签名，未经公证**：macOS 会拒绝直接打开，需要先清除隔离标记
（`xattr -cr /path/to/OmniVoice.app`）。详见
[`Docs/RELEASE_TESTING.md`](Docs/RELEASE_TESTING.md)，其中也列出了需要的权限。

## 功能

OmniVoice 没有主窗口，一切都在菜单栏、字幕悬浮窗和设置窗口里。目前界面仅提供中文。

### 实时转录与翻译

- **字幕悬浮窗**——半透明、可拖动、可缩放，始终置顶且不抢焦点，并记住位置。
  支持双语对照 / 仅译文 / 仅原文，三档字号，背景与内容透明度可调，自动滚动并带
  “最新内容”按钮，可复制单句或全文，显示实时麦克风电平和已用时长。鼠标移开后控件自动淡出。
- **语言**——约 16 种常用语言（中、英、日、韩、法、德、西、意、葡等）。只需设置一次
  我的语言和外语，转录、快捷翻译和语音输入共用。⇄ 按钮可交换语言对；使用本地模型时
  可选“自动”检测源语言。
- **音频来源**——可选择麦克风（或不用麦克风），也可通过 ScreenCaptureKit 包含系统声音，
  为会议或视频生成字幕。
- **可调断句**——断句停顿时长、静音电平阈值，以及长句提前翻译的时机。
- **历史记录**——转录记录用 SwiftData 保存在本地：可搜索、按日期分组、可重命名、
  多选删除、“删除 30/90 天前的记录”、复制全文或仅译文、导出 Markdown。

### 快捷翻译

完全在本机运行。

- **划词翻译（⌥A）**——在任意 App 里选中文字后按 ⌥A。也可以开启连按两次 ⌘C
  翻译刚复制的内容。
- **截图翻译（⌥S）**——框选屏幕上的一块区域，文字用 Vision 在本机识别。
- **翻译面板**——我的语言的文字翻译成外语，其余内容翻译成我的语言。长文本逐段填入，
  保留换行和列表符号。⏎ 翻译，⇧⏎ 换行，Esc 隐藏。两侧文字都可以用 macOS 系统语音朗读，
  也可设为自动朗读。
- URL、路径、命令行参数和代码标识符会被保护，不会被翻译改坏。

### 语音输入（可选，默认关闭）

在任意 App 里按住右 ⌥ Option（或右 ⌘ / ⌃），或者点按开始、再点按结束，说话，
文字就会输入到光标处。

- 使用系统语音识别；如果转录已经载入了本地 R2T2 模型，则直接借用它。
- 小气泡实时显示听到的内容；Esc 取消；有时长上限（默认 2 分钟），按键释放丢失时
  也会自动关闭麦克风。
- 点按模式下，按 Return 会结束听写、输入文字并再按一次 Return（适合聊天和发送提示词）。
- **输入前翻译**——在气泡中确认翻译成外语的结果，再选择输入译文或原文。
- **LLM 润色**——可选，用你自己的 OpenAI 兼容服务（OpenAI、DeepSeek、智谱、Ollama
  或自定义 Base URL）整理标点、去掉口癖、整理列表。默认关闭，API Key 保存在钥匙串，
  任何失败都会输入原文。

### 引擎与模型

| | 系统（内置，无需下载） | 本地模型（离线） |
|---|---|---|
| 语音识别 | `SpeechAnalyzer` / `SpeechTranscriber` | R2T2（Q4_K_M / Q8_0 / F16） |
| 翻译 | `Translation` 框架 | HY-MT1.5 1.8B（轻量）、T3PO（高质量） |

识别引擎和翻译引擎可分别选择。本地模型通过 `audio.cpp` 和 `llama.cpp` 在进程内运行。
**模型库**负责下载模型，带进度、磁盘空间检查和 SHA-256 校验，显示内存占用，并支持启动时预加载。
首次引导提供三种运行模式：极速轻量（系统引擎）、均衡低内存（R2T2 + HY-MT1.5）、
高精离线大模型（全部本地）。

### 应用

菜单栏开始/停止并带闪烁的录制指示、开机自动启动、仅在设置或引导窗口打开时显示
Dock 图标、模型下载完成时发送系统通知、可重新运行的新手引导，以及更新后的新功能窗口。
设置共有六个标签页（⌘1–⌘6）：通用、语音识别、语音输入、快捷翻译、模型库、关于。

## 系统要求

- macOS 26 或更高版本（`SpeechAnalyzer`/`SpeechTranscriber` 与 `Translation`
  框架的相关 API 需要 macOS 26+）。
- 本地模型是可选下载：均衡包（R2T2 + HY-MT1.5）约 3.4 GB；模型库会显示每个模型的内存占用。
- 从源码构建需要 Swift 6.2+ 工具链。

## 权限

只在对应功能需要时才会请求：麦克风与语音识别（转录）、屏幕录制（系统声音、⌥S）、
辅助功能（⌥A、输入听写文字）、输入监控（语音输入、⌘C ⌘C）。

## 从源码构建

```bash
swift build             # 调试构建
swift test              # 单元测试
./Scripts/build_app.sh  # 打包 ad-hoc 签名的 .app 到 build/
                        # （若有 "OmniVoice Dev Signing" 证书则使用，见 Docs/SIGNING.md）
./Scripts/build_dmg.sh  # 把 .app 打成 .dmg（需先运行 build_app.sh）
```

本地模型引擎需要先构建上游源码，见
[`Docs/MODEL_ENGINE_SETUP.md`](Docs/MODEL_ENGINE_SETUP.md)（或运行
`Scripts/setup_third_party.sh`）。

## 尚未实现

- 本地化（界面目前仅有中文）
- 公证发布、自动更新和崩溃报告

## 文档

- [`CHANGELOG.md`](CHANGELOG.md)——各版本变更
- [`Docs/PROGRESS.md`](Docs/PROGRESS.md)——架构、决策与未完成事项
- [`Docs/GLOSSARY.md`](Docs/GLOSSARY.md)——界面与文档中的命名规范
- [`Docs/RELEASING.md`](Docs/RELEASING.md)——发布流程
- [`AGENTS.md`](AGENTS.md)——贡献流程

## 许可证

Apache License 2.0——见 [`LICENSE`](LICENSE)。

## 致谢

感谢以下项目：

- [Cida](https://github.com/Xuanwo/cida)——快捷翻译的灵感来源
- SnapTra Translator——卡片式设置界面的灵感来源
- [audio.cpp](https://github.com/0xShug0/audio.cpp) 与 [llama.cpp](https://github.com/ggml-org/llama.cpp)——本地进程内推理
- [R2T2](https://huggingface.co/davidxifeng/Confucius4-R2T2-gguf) 与 [T3PO](https://huggingface.co/netease-youdao/Confucius4-T3PO-GGUF)（网易有道 Confucius4）——本地语音识别与翻译模型
- [HY-MT1.5](https://huggingface.co/tencent/HY-MT1.5-1.8B-GGUF)（腾讯）——本地翻译模型
