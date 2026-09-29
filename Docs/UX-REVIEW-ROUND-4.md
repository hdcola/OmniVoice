# OmniVoice 代码审查结论报告 (Round 4)

> **评审对象**：分支 `hdcola/feature-ui-ux-optimization`（提交 `6cf530e` 与 `b927f92`，相对 Round 3 基线 `d1416a8` 的全量改动）  
> **审查依据**：[`Docs/UX-SETTINGS-MODEL-MANAGEMENT.md`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Docs/UX-SETTINGS-MODEL-MANAGEMENT.md)、Round 1~3 审查报告及用户实测反馈  
> **审查日期**：2026-09-29  
> **最终评审结论**：**零 must-fix，可合入 (Zero must-fix, Ready to merge)**。Round 4 针对用户实测反馈的 3 项优化与修复全部经受住了深度审计：第三模式卡（均衡低内存模式）的下载/预检/激活/录音守卫逻辑与既有模式严格一致；长句提前翻译阈值的说明文案与底层分词及提交语义完全吻合；开发关于“组合包状态逻辑原本无 bug”的判断完全站得住脚，并通过变体清单展示（✅/⬜）从根源上消除了用户的信息差与困惑；工程质量优秀，构建与 114 项单元测试全部通过。

---

## 1. 构建与测试验证结果

- **构建验证**：`swift build` 成功编译通过（耗时 0.38 秒），0 编译警告，0 编译错误。
- **单元测试验证**：`swift test` 执行 10 个测试套件，共 114 个单元测试全部通过（耗时 0.33 秒）。
  - 新增测试套件 [`ModelBundleStatusTests`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Tests/OmniVoiceCoreTests/ModelBundleStatusTests.swift) 包含 5 个专项测试，覆盖用户实测场景、共享变体独立性、兄弟量化隔离与全量方案定义校验，全部毫秒级通过。
- **审查约束遵从**：本次审查严格执行只读代码原则，未修改任何 Swift 代码文件，仅产出本评审文档。

---

## 2. 用户反馈 3 项改动规格符合度与深度审计

### 2.1 改动 1：OnboardingView 新增第三模式“均衡低内存模式” (feat)

**用户诉求与改动背景**：向导原本仅提供“极速轻量模式”（系统引擎 0GB）与“高精离线大模型模式”（R2T2+T3PO ~12.4GB），跨度过大；新增折中的“均衡低内存模式”（R2T2+HY-MT1.5 ~3.4GB），并解决 3 张卡片在固定宽度下的布局问题。

#### 核心审计点核对：

| 审计维度 | 预期规格与防呆标准 | 实际代码实现 | 审计判定 |
| :--- | :--- | :--- | :--- |
| **组合包映射与下载** | 准确映射至预设推荐组合包，下载逻辑与既有离线模式复用同一套机制 | [`selectedBundleID`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/OnboardingView.swift#L221-L228) 在 `.balanced` 时映射为 `"bundle.lightweight"`；在 `startBundleDownload()` 中统一使用 `bundle.status(isDownloaded:).remainingVariants` 提取未下载变体，避免重复造轮子。 | **完全符合 (Pass)** |
| **磁盘前置容量预检** | 下载前统一预检组合包剩余组件的合计大小，空间不足时拦截且窗口不关闭 | [`startBundleDownload()`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/OnboardingView.swift#L244-L253) 使用 `variants.reduce(0) { $0 + $1.approximateSizeMB }` 计算合并总大小，调用 `insufficientDiskSpaceWarning(forTotalMB:)` 预检；不足时设置 `diskSpaceWarningMessage` 并返回 `false`；`finish(startDownload:)` 中的 `guard startBundleDownload() else { return }` 安全拦截，向导窗口保持打开并弹窗，不写入完成持久化标记。 | **完全符合 (Pass)** |
| **下载完成自动激活** | 下载成功后静默为用户激活对应的识别与翻译引擎 | 针对下载完成的变体逐个调用 [`activateIfStillSystemEngine(_:)`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/OnboardingView.swift#L282-L293)；若当前仍为系统引擎，识别引擎被激活为 `model.r2t2`（`r2t2-q8_0`），翻译引擎被激活为 `model.hymt15`（`hymt15-1.8b-q4_k_m`），激活链条完整无遗漏。 | **完全符合 (Pass)** |
| **录音状态防护守卫** | 后台下载完成时，若用户已在录音，不得强制变更引擎导致录音提供者崩溃 | `activateIfStillSystemEngine` 严格设置 `guard !session.isSessionActive else { return }` 前置守卫，彻底杜绝录音中途被篡改引擎。 | **完全符合 (Pass)** |
| **布局与尺寸适配** | 3 张模式卡片不能被挤压变形或发生溢出截断 | 3 张模式卡片包裹于 [`ScrollView(.horizontal, showsIndicators: false)`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/OnboardingView.swift#L79)，每张卡片改为固定 `frame(width: 220, alignment: .leading)`，消除无界宽度贪婪；同时在 [`AppDelegate.presentOnboardingIfNeeded()`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/AppDelegate.swift#L104) 中将宿主窗口高度由 420 适度提升至 440，为多行描述文案提供了充足的安全裕量，底部按钮行完全可见且无挤压。 | **完全符合 (Pass)** |

---

### 2.2 改动 2：“长句提前翻译阈值”独立小节与文案语义核实 (feat)

**用户诉求与改动背景**：阈值步进器原本突兀夹在翻译引擎选择器与显存控制台之间，缺乏上下文；开发将其移入独立“翻译输出”小节并增加详细释义与 tooltip。

#### 核心审计点核对：

1. **显隐条件严谨性**：
   - 过滤条件：[`if session.translationEngineID != "model.t3po", session.transcriptionEngineKind != .system`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/SettingsView.swift#L133)。
   - **核验**：T3PO 属于流式引擎，采用独有的 WAIT/TRANS 提交策略（由上方的 `Picker("翻译提交策略", selection: $session.translationCommitEagerness)` 控制）；系统语音识别 (System ASR) 仅在整句结束时发射 `.segmentClosed`，`feed` 与 `flush` 紧密相随，提前阈值对系统 ASR 毫无生效窗口；因此在这两种情况下彻底隐藏该小节，逻辑严丝合缝。

2. **文案描述与真实代码语义核实**：
   - **UI 说明文案**：
     > “缓存的原文达到该字数的一半、且遇到句号/问号/换行等断句点时，会提前把已缓存内容翻译一次；达到完整阈值后，即使还没遇到断句点也会强制翻译，避免长句迟迟不出字。数值越低出字越快，但长句越容易被拆成更多段；数值越高单段更完整，但可能等得更久。”
   - **底层代码核查（[`HYMT15Translator.swift#L180-L185`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoiceCore/Inference/HYMT15Translator.swift#L180-L185) 与 [`SystemTranslationProvider.swift#L131-L135`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoiceCore/Providers/SystemTranslationProvider.swift#L131-L135)）**：
     ```swift
     let crossedHardCap = bufferedLength >= threshold
     let crossedSoftBreak = bufferedLength >= threshold / 2 && SentenceBoundary.endsSentence(sourceDelta)
     if crossedHardCap || crossedSoftBreak {
         self.translateBufferLocked() // 提前触发翻译
     }
     ```
   - **`ModelLanguageMapping` 与翻译提交逻辑语义对比**：
     - `SentenceBoundary.endsSentence(...)` 严格检测断句标点（`。？！…；.!?`），且自动剔除末尾空格与换行；
     - `bufferedLength >= threshold / 2 && SentenceBoundary.endsSentence(...)` 完全对应文案所述的“达到字数一半且遇到断句点时提前翻译”；
     - `bufferedLength >= threshold` 完全对应文案所述的“达到完整阈值强制翻译”；
     - 提前翻译完成后触发 `onCommit`，进入 [`RecordingSession.appendTranslation(_:)`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoiceCore/Session/RecordingSession.swift#L1227)，仅追加当前行的翻译内容而不推进 `translationRowIndex`，整句终了 `flush()` 时才推进换行，用户能无缝看到长句的早期分段译文；
     - `ModelLanguageMapping` 仅负责目标语种与源语种的模型内部枚举转换，未与字符长度逻辑发生耦合；文案完全聚焦于断句机制与字数控制，不存在任何与语种映射相冲突或失实的描述。
   - **审计结论**：文案真实准确地反映了底层实现与分词提交机制，**无任何失实或误导，完全达标**。

---

### 2.3 改动 3：模型库 Tab 滚动支持与组合包状态无 bug 判定审计 (fix)

**用户诉求与改动背景**：
- 3a. 设置窗口模型库 Tab 在 560×480 固定尺寸下由于卡片增多，底部内容被裁切无法访问；
- 3b. 用户反馈组合包状态疑似有 bug：截图显示方案 A 处于“已下载 1/2 且按钮显示约 10,021 MB”，而方案 B 却显示“状态：已全部下载”。开发审计后判定底层计算完全正确，系用户真实下载状态，但因缺少变体清单展示而导致理解歧义。

#### 核心审计点核对：

##### A. 模型库 Tab 滚动包裹验证 (3a)
- [`ModelManagementView.swift#L60-L79`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/ModelManagementView.swift#L60-L79) 使用 `ScrollView { Form { ... }.padding(20) }` 将全量表单包裹。
- 在 560×480 固定窗口内，当推荐组合包卡片、识别引擎列表、翻译引擎列表全部展开时，内容能够垂直流畅滚动，底部按钮与卡片完整可达，解决了原版直接使用裸 `Form` 导致的内容截断。

##### B. 开发对 3b “无 bug” 判断的数学与逻辑推演 (3b)
针对用户截图与模型定义进行逐条全链路推演：

1. **模型与组合包定义基准（[`ProviderCatalog.swift`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoiceCore/Providers/ProviderCatalog.swift#L147-L219)）**：
   - 变体定义：
     - `r2t2-q8_0`（识别，2,363 MB）
     - `t3po-q5_k_m`（翻译，10,021 MB）
     - `hymt15-1.8b-q4_k_m`（翻译，1,080 MB）
     - `hymt15-1.8b-q8_0`（翻译，1,820 MB）
   - 组合包定义：
     - **方案 A (标准实时双语方案)**：`variantIDs = ["r2t2-q8_0", "t3po-q5_k_m"]`，包含 2 个变体。
     - **方案 B (轻量低内存方案)**：`variantIDs = ["r2t2-q8_0", "hymt15-1.8b-q4_k_m"]`，包含 2 个变体。

2. **状态计算实现推演**：
   无论是 `b927f92` 重构前还是重构后，底层计算均**严格基于具体变体的唯一 `variantID`** 进行过滤，绝非按 `engineID` 模糊匹配：
   ```swift
   let variants = variantIDs.compactMap(ProviderCatalog.variant(forID:))
   downloadedVariants = variants.filter(isDownloaded)
   remainingVariants = variants.filter { !isDownloaded($0) }
   remainingSizeMB = remainingVariants.reduce(0) { $0 + $1.approximateSizeMB }
   ```
   [`ModelDownloadManager.isDownloaded(_:)`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoiceCore/Inference/ModelDownloadManager.swift#L207) 依据 `cacheDirectory.appendingPathComponent("\(variant.id).gguf")` 检查真实物理文件是否存在。

3. **用户截图场景还原与推演**：
   - 用户磁盘上的真实文件状态：
     - `r2t2-q8_0.gguf` **已存在**（用户此前下载过 R2T2）；
     - `t3po-q5_k_m.gguf` **不存在**（体积高达 10GB，用户未下载）；
     - `hymt15-1.8b-q4_k_m.gguf` **已存在**（用户此前在内联卡片或模型列表中下载过 HY-MT1.5 轻量模型）。
   - **对方案 A 的推演**：
     - 变体列表：`["r2t2-q8_0", "t3po-q5_k_m"]`
     - 已下载项：`["r2t2-q8_0"]`（计数 1）
     - 未下载项：`["t3po-q5_k_m"]`（计数 1）
     - 剩余下载大小：`10,021 MB`（恰好等于 `t3po-q5_k_m` 的大小）
     - 渲染结果：**“状态：已下载 1/2”**，按钮 **“⬇️ 一键下载剩余组件（约 10021 MB）”**。
   - **对方案 B 的推演**：
     - 变体列表：`["r2t2-q8_0", "hymt15-1.8b-q4_k_m"]`
     - 已下载项：`["r2t2-q8_0", "hymt15-1.8b-q4_k_m"]`（两个变体在磁盘上均已存在，计数 2）
     - 未下载项：`[]`（计数 0）
     - 剩余下载大小：`0 MB`
     - 渲染结果：**“状态：已全部下载”**。

4. **可能怀疑的 bug 假说排除**：
   - *假说 1：方案 B 是不是只要 R2T2 下载了就误判为全部完成？*
     - **排除**：单元测试 `lightweightBundleDoesNotFalselyReportCompleteFromASharedVariantAlone` 证明，当仅有 `r2t2-q8_0` 时，方案 B 严格呈现 `1/2`，剩余大小准确为 `1080 MB`，`isFullyDownloaded == false`。
   - *假说 2：同引擎的其他兄弟量化版本（如 HY-MT1.5 Q8_0）是否会误计入方案 B？*
     - **排除**：单元测试 `aSiblingQuantizationNeverCountsTowardABundleThatNamesADifferentOne` 证明，即使磁盘上存在 `r2t2-q8_0` 与 `hymt15-1.8b-q8_0`，方案 B 依然识别出缺少 `hymt15-1.8b-q4_k_m`，绝不混淆。
   - *假说 3：计数或剩余大小是否存在重复累加？*
     - **排除**：单元测试 `everyBundlesVariantCountMatchesItsVariantIDsExactlyWithNoDuplicates` 保证各方案变体列表唯一且与定义完全对应。

5. **结论与优化价值**：
   开发对“无 bug”的判断完全站得住脚。原版 UI 的问题在于**缺乏明细透明度**——只显示宏观的 `已下载 1/2` 或 `已全部下载`，用户无法得知方案 B 包含哪些变体、为什么方案 B 会“不请自来”地显示已完成。  
   提交 `b927f92` 增加了 [`bundleChecklist(_:)`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/ModelManagementView.swift#L238-L249)，在卡片中清晰呈现变体级清单（✅/⬜）：
   - 方案 A 明确呈现：`[✅ R2T2 (Q8_0)]` 与 `[⬜ T3PO (Q5_K_M)]`；
   - 方案 B 明确呈现：`[✅ R2T2 (Q8_0)]` 与 `[✅ HY-MT1.5 1.8B (Q4_K_M)]`。  
   用户一目了然得知方案 B 是因为共享了 R2T2 且本地已具备 HY-MT1.5，彻底消除了认知偏差。

---

## 3. 常规质量与工程稳健性审计

1. **ScrollView 嵌套与手势/滚动冲突**：
   - `SettingsView` 的模型库 Tab 是单一垂直方向的 `ScrollView`，内部没有其他 `ScrollView`，无任何方向冲突；
   - `OnboardingView` 的主体采用固定高度 `VStack`，模式卡片使用单一水平方向 `ScrollView(.horizontal)`，垂直方向无滚动容器，水平滑动灵敏顺畅，两者均零嵌套、零冲突。
2. **新增 API 封装规范**：
   - 抽离出独立的 `ModelBundleStatus` 结构体，具备 `Sendable` 契约，属性均为只读值；
   - `ModelBundle.status(isDownloaded:)` 采用纯函数依赖注入设计，使视图和业务逻辑彻底解耦，不仅代码整洁，而且在无需真实文件系统与并发环境的前提下实现了 100% 单元测试覆盖。
3. **测试有效性**：
   - [`ModelBundleStatusTests.swift`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Tests/OmniVoiceCoreTests/ModelBundleStatusTests.swift) 采用 Swift Testing 现代化框架编写，精准锁定了用户报告场景、状态共享边界、异构量化隔离和定义幂等性 4 个核心维度，断言严格，测试有效性极高。

---

## 4. 缺陷与优化建议统计

### 4.1 Must-Fix 级别（阻塞性缺陷）
- **统计**：**0 项 (零 must-fix)**。代码逻辑严谨，文案语义真实，无任何阻塞合入的问题。

### 4.2 Nice-to-Have 级别（后续演进建议，不阻塞合入）
1. **[NICE-TO-HAVE 1] OnboardingView 水平滚动视觉引导微调**：当前 3 张卡片在 520pt 宽度下，第 3 张卡片右侧自然露出约 56pt，具备标准的“Peek-in”视觉暗示。若未来有极度不习惯触控板横滑的用户反馈，可考虑为该水平 `ScrollView` 在初始状态下显示一个微妙的右侧淡出渐变或轻微引导提示。
2. **[NICE-TO-HAVE 2] 组合包卡片变体清单与下载中状态的细粒度联动**：当前变体清单中已下载项显示为绿色实心勾（✅），未下载项显示为灰色空心圆（⬜）。当用户点击“一键配置/下载剩余组件”后，按钮本身已显示 `ProgressView`，未来可考虑将清单中正在下载的那一项空心圆同步呈现为微型旋转指示器，体验更极致。

---

## 5. 审查总结与合入决议

- **改动 1（向导新增均衡模式）**：下载、容量预检、自动激活与录音保护规格与其它模式完全一致，横向滚动与窗口高度调整得当，**通过**。
- **改动 2（阈值独立小节与文案）**：文案对“半阈值断句点提前译”、“全阈值强制译”、“碎度与时延权衡”的阐释与底层实现高度吻合，语种映射与提交流程语义精准，**通过**。
- **改动 3（模型库 Tab 滚动与状态逻辑）**：Tab 滚动彻底解决截断；底层状态无 bug 的判断在数学与逻辑上完全成立；清单（✅/⬜）从根源消除了用户困惑；新增测试套件严谨高效，**通过**。
- **最终合入决议**：
  **零 must-fix，可合入 (Zero must-fix, Ready to merge)**。
