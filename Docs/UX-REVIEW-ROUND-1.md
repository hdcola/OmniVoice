# OmniVoice 代码审查结论报告 (Round 1)

> **评审对象**：分支 `hdcola/feature-ui-ux-optimization`（基线 `765f5a3` 到 `HEAD` 之间由 4 个里程碑提交构成的改动，涉及 14 个文件、约 1900 行增删）  
> **设计规格依据**：[`Docs/UX-SETTINGS-MODEL-MANAGEMENT.md`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Docs/UX-SETTINGS-MODEL-MANAGEMENT.md)  
> **审查日期**：2026-09-29  
> **评审结论**：**不予合入 (Changes Requested)**。整体完成度高，全部 15 条 WBS 均有代码落地，构建及单元测试通过，但在**运行中会话状态保护**、**SwiftUI 布局自适应**、**高频节流性能**及**首次引导闭环**上发现 **5 项必须修复问题 (Must-Fix)** 与 **5 项体验打磨建议 (Nice-to-Have)**。

---

## 1. 构建与测试验证结果

- **构建验证**：`swift build` 在 macOS 环境下一次性成功（用时 0.23 秒），无编译错误与警告。
- **单元测试验证**：`swift test` 执行 9 个测试套件、共 109 个单元测试用例全部通过（用时 0.30 秒）。
- **约束符合性**：实现未篡改 `third_party/`、未改动底层 C ABI 桥接代码与构建脚本。

---

## 2. WBS 15 条任务实现符合度逐条对照

对照设计规格文档第 4、5、7 节，逐条复核实现情况：

| 任务编号 | 任务名称 | 预期规格 | 实际实现与符合度评估 | 审查判定 |
| :--- | :--- | :--- | :--- | :--- |
| **Task 1.1** | 目标语言防静默错译 | 选中本地翻译模型且目标语言非中英日韩时展示黄色警告卡片并支持一键切换 | 已在 `TargetLanguagePicker` 实现分组与警告卡片；但切换按钮在活跃录制中未加保护，且浮窗布局被挤压 | **存在缺陷** (见 Must-Fix 1/2) |
| **Task 1.2** | 源语言自动检测显性化 | 系统 ASR 模式下保留置灰“自动检测（需本地 R2T2 引擎）”，点击弹出解释 | 已在 `SourceLanguagePicker` 实现置灰项与问号 Popover 解释 | **符合规格** |
| **Task 1.3** | 引擎列表全量展示 | 未下载引擎不从 Picker 移除，标注“（未下载 · 点击配置）” | 已在 `SettingsView` 的两个引擎选择器全量遍历，配合 `inlineDownloadSection` | **符合规格** |
| **Task 1.4** | 清理无效参数干扰 | 识别引擎为系统 ASR 时隐藏或置灰长句提前翻译阈值 | 在系统 ASR 模式下已直接隐藏该 Stepper，文案矛盾消除 | **符合规格** |
| **Task 2.1** | 下载后自动激活与反馈 | 下载完成后若仍为系统引擎自动切换，并弹出带撤销横幅 | 已在 `ModelManagementView` 实现横幅与切换；但未防范活跃录制中被触发 | **存在缺陷** (见 Must-Fix 3) |
| **Task 2.2** | 模型卡片说明丰富化 | 展示规格、显存占用预估、特性优势与功能定位 | `ProviderCatalog` 增加 `badge`/`summary`/`recommendedMemoryGB`，卡片已渲染 | **符合规格** |
| **Task 2.3** | 推荐方案组合包 | 提供标准实时方案与轻量方案卡片，支持一键批量下载 | 已在 `ProviderCatalog.bundles` 与 `ModelManagementView.bundleSection` 实现 | **符合规格** (见 Nice-to-Have 3/4) |
| **Task 2.4** | 下载进度指标完善 | 进度条下方展示瞬时速度 (MB/s) 与剩余时间预估 (ETA) | 已引入 `DownloadStats` 并展示；但其计算位置击穿了节流阀 | **存在缺陷** (见 Must-Fix 5) |
| **Task 3.1** | SettingsView 多标签体系 | 引入 TabView（4 个标签页），窗口固定 560×480 | 已完成 TabView 重构，尺寸更新为 560×480 | **符合规格** |
| **Task 3.2** | 引擎内联下载与状态 | 选中未下载引擎时在下方内联展开下载按钮与进度 | 已在 `SettingsView.inlineDownloadSection` 实现就地一键下载与启用 | **符合规格** |
| **Task 3.3** | 显存与预加载控制台 | 设置页集成模型显存状态灯、预估内存占用、预加载与释放按钮 | 已实现 `memoryConsole`，联动 `preloadModel()` 与 `unloadModels()` | **符合规格** (见 Nice-to-Have 2) |
| **Task 3.4** | 菜单栏与 Tab 联动 | 菜单栏“模型管理…”直接跳转设置窗口的模型库 Tab | 已引入 `SettingsNavigationState` 驱动跨窗口与跨组件路由 | **符合规格** |
| **Task 4.1** | 首次启动向导向导页 | 初次启动弹出 3 步向导卡片（权限 -> 模式选择 -> 启动） | 已实现 `OnboardingView` 并由 `AppDelegate` 调起；但大模型模式下载后未自动激活 | **存在缺陷** (见 Must-Fix 4) |
| **Task 4.2** | 下载前磁盘空间预检 | 下载发起前检查可用空间，不足时拦截并引导系统存储 | 已在 `ModelDownloadManager` 增加预检并挂载弹窗；但向导页未走预检 | **部分符合** (见 Must-Fix 4) |
| **Task 4.3** | 异常状态内联重试 | 网络中断或校验失败收敛到卡片内联重试与复制链接 | 已在模型卡片与设置内联行实现内联错误条、重试与复制链接 | **符合规格** |

---

## 3. 必须修复问题 (Must-Fix Issues)

### [MUST-FIX 1] 悬浮窗中允许在录制中切换引擎，导致运行中活跃会话被清空中断
- **涉及文件**：
  - [`Sources/OmniVoice/Views/LanguagePickers.swift#L159-L165`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/LanguagePickers.swift#L159-L165)
  - [`Sources/OmniVoice/FloatingPanel/FloatingTranscriptView.swift#L188-L195`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/FloatingPanel/FloatingTranscriptView.swift#L188-L195)
- **问题严重性**：功能致命错误 (Severity: High)。导致正在进行的录制会话翻译输出永久丢失。
- **根因分析**：
  - `TargetLanguagePicker` 允许在录制过程中调整（因为系统翻译支持动态更新目标语言）。当用户在录制时将目标语言切为非中英日韩（如法语）时，下方渲染出 `antiFallbackWarningCard`，其内部的按钮直接执行：
    ```swift
    Button("一键将翻译引擎切换为「系统自带 (Translation)」") {
        onSwitchToSystemTranslation() // 直接将 session.translationEngineID 改为 "system.translation"
    }
    ```
  - `session.translationEngineID` 的 `didSet` 会无条件调用 `discardLoadedModelsIfStale()`。这会导致正在运行的 `translationProvider` 被执行 `unload()` 并置为 `nil`！
  - 正在工作的 `RecordingSession.handle(_:)` 后续在接收到 ASR 文本时执行 `translationProvider?.feed(...)`，由于 provider 已被置空，**本场录制接下来的所有翻译彻底哑火，不再输出任何文字**。同时违反了应用“录制生命周期内引擎不可变 (`!isSessionActive`)”的核心架构铁律。
- **建议修复方案**：
  1. 在 `antiFallbackWarningCard` 的操作按钮上增加状态保护：
     ```swift
     Button("一键将翻译引擎切换为「系统自带 (Translation)」") {
         onSwitchToSystemTranslation()
     }
     .disabled(session.isSessionActive)
     ```
  2. 若在录制中（`isSessionActive` 为 true），按钮旁补充辅助说明“（录制结束后生效）”；回调内部亦应加入 `guard !session.isSessionActive else { return }` 兜底保护。

---

### [MUST-FIX 2] 悬浮窗横向控制栏布局被全宽警告卡片挤压严重变形
- **涉及文件**：
  - [`Sources/OmniVoice/Views/LanguagePickers.swift#L112-L140`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/LanguagePickers.swift#L112-L140)
  - [`Sources/OmniVoice/FloatingPanel/FloatingTranscriptView.swift#L188-L195`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/FloatingPanel/FloatingTranscriptView.swift#L188-L195)
- **问题严重性**：UI/UX 严重破相与可用性破坏 (Severity: Medium-High)。
- **根因分析**：
  - `TargetLanguagePicker` 内部直接用 `VStack` 将选择器与 `antiFallbackWarningCard` 垂直堆叠。
  - 在 `SettingsView` 中因处于纵向表单中，显示效果正常；但是在 `FloatingTranscriptView` 中，该组件被放置在 `controlBarContent` 的**单行水平 `HStack(spacing: 10)` 工具栏**中（原本高度仅约 30pt）。
  - 当黄色警告卡片被激活展开时，卡片的 `maxWidth: .infinity` 和两行文字直接将紧凑的工具栏高度暴力撑大到 120pt 以上，将下方原本正常滚动的实时双语字幕区域大幅向下挤压，导致悬浮窗结构严重错乱。
- **建议修复方案**：
  - 为 `TargetLanguagePicker` 增加模式区分（例如新增参数 `isCompact: Bool = false`）：
    - 在 `SettingsView`（常规模式）中保持原有的纵向卡片展开；
    - 在 `FloatingTranscriptView`（紧凑模式）中，不展开多行卡片，仅在选择器旁边显示一个高亮的橙色警告小图标 `⚠️`，用户点击后以 `.popover` 呈现说明与一键切换按钮。

---

### [MUST-FIX 3] 后台下载完成时的自动激活缺乏活跃录制状态守卫
- **涉及文件**：
  - [`Sources/OmniVoice/Views/ModelManagementView.swift#L159-L181`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/ModelManagementView.swift#L159-L181)
- **问题严重性**：运行时状态冲突 (Severity: High)。
- **根因分析**：
  - `autoActivateIfSystemEngineStillSelected(_:)` 在模型下载任务完成后被调用。
  - 若用户在长达数分钟的模型下载期间，使用“系统自带引擎”开启了一次会议录制，一旦大模型刚好在此期间下载完毕，回调将在主线程强制执行：
    ```swift
    session.transcriptionEngineID = variant.engineID
    ```
  - 这会突发触发 `discardLoadedModelsIfStale()`，将正在用于当前录制的底层引擎直接强行释放！
- **建议修复方案**：
  - 在 `autoActivateIfSystemEngineStillSelected` 函数入口增加前置拦截：
    ```swift
    guard !session.isSessionActive else { return }
    ```
  - 若下载完成时处于活跃录制中，放弃自动强切，仅保留就绪状态或提示用户录制结束后手动切换。

---

### [MUST-FIX 4] 首次启动向导下载大模型后无法自动激活，且缺乏磁盘空间检查
- **涉及文件**：
  - [`Sources/OmniVoice/Views/OnboardingView.swift#L143-L157`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/OnboardingView.swift#L143-L157)
- **问题严重性**：核心交互逻辑断层与承诺落空 (Severity: High)。
- **根因分析**：
  - `OnboardingView` 文案明确承诺：“*模型正在后台下载中，下载完成后将自动为您无缝启用*”。
  - 但其代码直接调用底层 `downloadManager.ensureDownloaded(variant)`，而自动切换引擎的逻辑属于 `ModelManagementView` 的私有方法。因此，当 Onboarding 触发的 12.4GB 下载完成时，**没有任何后续代码去切换引擎**，软件依然停留在系统自带引擎，新用户首次录制仍然走的是系统框架，承诺落空。
  - 此外，`OnboardingView` 完全漏掉了 Task 4.2 规定的磁盘预检。当用户磁盘剩余不足 12.4GB 时，点击“一键开启并下载”，后台任务抛出 `insufficientDiskSpace`，由于外层被 `_ = try? await` 忽略，下载瞬间夭折，但 UI 状态却误导用户“正在下载”，造成永久卡顿假象。
- **建议修复方案**：
  1. 在 `finish(startDownload: true)` 前，调用 `downloadManager.insufficientDiskSpaceWarning` 校验 bundle 所需磁盘空间，若不足则弹窗提示；
  2. 下载任务完成回调中，加入主线程激活赋值：
     ```swift
     if !session.isSessionActive {
         session.transcriptionEngineID = "model.r2t2"
         session.translationEngineID = "model.t3po"
     }
     ```

---

### [MUST-FIX 5] `ModelDownloadManager` 速度计算打破节流保护，造成主线程重绘洪泛
- **涉及文件**：
  - [`Sources/OmniVoiceCore/Inference/ModelDownloadManager.swift#L449-L476`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoiceCore/Inference/ModelDownloadManager.swift#L449-L476)
- **问题严重性**：高网络带宽下的性能劣化与主线程卡死 (Severity: High)。
- **根因分析**：
  - `ModelDownloadManager` 原本设计了节流阀：`if fraction - last.fraction < 0.005, now.timeIntervalSince < 0.1 { return }`，用于规避千兆网络下每秒上千次 TCP 分包回调拖垮 UI。
  - 新增的 `downloadStats[variantID] = DownloadStats(...)` 被放置在该节流检查**之前**。由于 `downloadStats` 是一个 `@Published` 属性，其赋值操作会无条件同步派发 `objectWillChange.send()`。
  - 这导致节流阀被彻底绕过，主线程每秒被迫处理数百次 SwiftUI 重绘通知，不仅导致 UI 掉帧卡顿，还使得计算出的瞬时速度波动剧烈。
- **建议修复方案**：
  - 将 `downloadStats` 的更新与速度计算移到节流保护语句**之后**，确保每隔 100ms~250ms 才向主线程发布一次新的统计指标；由于时间间隔跨越了多个网络数据块，计算出的速度也将更加平滑准确。

---

## 4. 优化打磨建议 (Nice-to-Have Suggestions)

### [NICE-TO-HAVE 1] `OnboardingView` 窗口高度固定且无 `ScrollView` 兜底
- **涉及文件**：`Sources/OmniVoice/Views/OnboardingView.swift#L29-L78`、`Sources/OmniVoice/AppDelegate.swift#L99`
- **问题**：`OnboardingView` 纵向元素堆叠高度已接近 420pt，但并未包裹 `ScrollView`。在小分辨率显示器或开启系统辅助大字号时，底部的“跳过向导”与“一键开启并下载”按钮边缘可能被裁切。
- **建议**：在 `OnboardingView` 外层增加 `ScrollView`，并将窗口默认高度由 420 提升至 460。

### [NICE-TO-HAVE 2] 显存控制台中状态指示圆点与文本 Emoji 视觉冗余
- **涉及文件**：`Sources/OmniVoice/Views/SettingsView.swift#L332-L335`, `L361-L375`
- **问题**：`HStack` 中先绘制了自定义的 `statusIndicatorDot`（绿色/黄色/灰色 Circle），其后的 `memoryStatusText` 自身开头又带了一个同样的 Emoji 圆点（`🟢` / `🟡` / `⚪`），导致视觉上连续出现两个相同颜色的小圆点。
- **建议**：移除 `memoryStatusText` 中的 Emoji 前缀，仅保留纯文字，由左侧原生组件负责色彩指示。

### [NICE-TO-HAVE 3] 推荐组合包下载前置磁盘校验未计算全量总和
- **涉及文件**：`Sources/OmniVoice/Views/ModelManagementView.swift#L259-L267`
- **问题**：`downloadBundle` 逐个调用 `download(variant)`，每个模型仅检查各自的磁盘大小。若磁盘仅剩 5GB，R2T2（2.4GB）会成功通过检查并开始下载，紧接着下一个循环的 T3PO（10GB）才报错磁盘不足。
- **建议**：在启动组合包下载前，预先累加未下载组件的总容量进行一次整体校验。

### [NICE-TO-HAVE 4] 推荐组合包下载中缺少一键取消
- **涉及文件**：`Sources/OmniVoice/Views/ModelManagementView.swift#L234-L250`
- **问题**：组合包开始下载后按钮置灰为“下载中…”，用户若改变主意，必须滚动到下方各个独立的模型卡片逐一点击“取消”。
- **建议**：组合包下载中时支持“取消组合下载”动作。

### [NICE-TO-HAVE 5] `ModelManagementView` 多层 `.alert` 挂载于同一视图
- **涉及文件**：`Sources/OmniVoice/Views/ModelManagementView.swift#L68-L107`
- **问题**：在 `Form` 根视图上连续挂载了通用错误 alert、删除确认 dialog、磁盘不足 alert。尽管当前能正常展示，但在 SwiftUI 中建议使用统一的枚举状态收敛弹窗绑定，避免潜在的优先级冲突。

---

## 5. 审查总结与后续行动建议

1. **工程质量总体评价**：
   - 工程师扎实落地了 15 条 WBS 任务，代码结构层次清晰，注释极其详尽。
   - 引入的 `TabView` 重构（560×480）、内联下载与显存控制台大幅改善了原先两个窗口割裂的心智模型，完成了设计目标的核心骨架。
2. **阻断合入的关键原因**：
   - 发现的 5 个 `must-fix` 均属于与底层 C ABI 引擎生命周期产生竞争冒险的高危缺陷（录制中切引擎导致活跃 provider 卸载），以及高频网络吞吐下的主线程事件风暴。
3. **后续建议**：
   - 优先针对 5 项 `must-fix` 进行集中修复；修复后再执行 Round 2 代码复审并确认合入。
