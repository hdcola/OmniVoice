# OmniVoice 代码审查结论报告 (Round 2)

> **评审对象**：分支 `hdcola/feature-ui-ux-optimization`（提交 `c2e0b69` 及相对基线 `4a4af5a` 的全部改动）  
> **设计规格依据**：[`Docs/UX-SETTINGS-MODEL-MANAGEMENT.md`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Docs/UX-SETTINGS-MODEL-MANAGEMENT.md) 及 [`Docs/UX-REVIEW-ROUND-1.md`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Docs/UX-REVIEW-ROUND-1.md)  
> **审查日期**：2026-09-29  
> **评审结论**：**暂缓合入 (Changes Requested)**。Round 1 的 5 项 Must-Fix 中，**4 项已完全正确修复**（录制中守卫、控制栏紧凑模式、下载完成自动激活守卫、下载速度节流），构建与 109 项测试全部通过；但在 Must-Fix 4 的修复落地中，**引入了 1 项新的阻塞性缺陷 (Must-Fix)**：首次向导在磁盘空间不足时，仍会无条件执行窗口关闭与向导完成标记，导致新增的磁盘空间不足 Alert 弹窗瞬间被窗口销毁而无法被用户看见。

---

## 1. 构建与测试验证结果

- **构建验证**：`swift build` 在 macOS 环境下成功编译（用时 0.31 秒），0 编译警告，0 编译错误。
- **单元测试验证**：`swift test` 执行 9 个测试套件，共 109 个单元测试用例全部通过（用时 0.62 秒）。
- **只读约束**：本次复查未修改任何 Swift 代码文件，严格保持代码只读。

---

## 2. Round 1 的 5 项 Must-Fix 修复复查结论

| 问题编号 | 问题描述 | 预期修复目标 | c2e0b69 修复方案评估 | 复查结论 |
| :--- | :--- | :--- | :--- | :--- |
| **Must-Fix 1** | 悬浮窗中允许在录制中切换引擎，导致活跃会话被清空中断 | 按钮增加 `isSessionActive` 保护并补充文字说明，回调内加 `guard` | `TargetLanguagePicker` 增加 `isSessionActive` 参数，按钮增加 `.disabled(isSessionActive)`、说明后缀文案以及回调内 `guard !isSessionActive else { return }` 双重保护；调用点全部正确传递 | **完全修复 (Pass)** |
| **Must-Fix 2** | 悬浮窗横向控制栏布局被全宽警告卡片挤压变形 | 区分紧凑模式与常规模式，紧凑模式下采用小图标 + Popover | `TargetLanguagePicker` 新增 `isCompact` 模式，在 `FloatingTranscriptView` 中收敛为单行橙色警告图标 `⚠️` + Popover 交互，`SettingsView` 保留原纵向卡片 | **完全修复 (Pass)** |
| **Must-Fix 3** | 后台下载完成时的自动激活缺乏活跃录制状态守卫 | 下载回调入口拦截活跃录制，避免强切引擎触发 Provider 卸载 | `ModelManagementView.autoActivateIfSystemEngineStillSelected` 函数入口加入 `guard !session.isSessionActive else { return }` 前置守卫 | **完全修复 (Pass)** |
| **Must-Fix 4** | 首次启动向导下载大模型后无法自动激活，且缺乏磁盘空间检查 | 向导下载前对标准组合包总容量进行磁盘预检；下载完成后自动切换引擎并加录制守卫 | 实现了组合包容量汇总预检与 `activateIfStillSystemEngine` 引擎激活；但 `finish` 退出生命周期存在严重缺陷，导致磁盘不足弹窗被立即销毁且向导被误标记完成 | **存在新缺陷 (Fail)** (见下文) |
| **Must-Fix 5** | `ModelDownloadManager` 速度计算打破节流保护，造成主线程重绘洪泛 | 将 `@Published` 属性写入与速度/ETA 计算移到节流 `return` 之后 | 节流判断上移至 `handleProgress` 最前端，仅在跨越节流阈值（100ms / 0.5%）或终止 1.0 时才更新统计数据与发布属性，彻底消除主线程重绘风暴 | **完全修复 (Pass)** |

---

## 3. 详细代码审计与新发现问题

### [MUST-FIX 1] 首次启动向导磁盘空间不足时窗口被立即销毁，导致弹窗不可见且向导被误标记完成
- **涉及文件**：[`Sources/OmniVoice/Views/OnboardingView.swift#L168-L194`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/OnboardingView.swift#L168-L194)、[`Sources/OmniVoice/AppDelegate.swift#L109-L112`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/AppDelegate.swift#L109-L112)
- **严重性**：核心交互严重缺陷 (Severity: High，阻塞合入)。
- **根因分析**：
  在 [`OnboardingView.swift`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/OnboardingView.swift) 中，用户点击“一键开启并下载”后触发 `finish(startDownload: true)`：
  ```swift
  private func finish(startDownload: Bool) {
      UserDefaults.standard.set(true, forKey: PersistedOnboardingKey.hasCompletedOnboarding)
      if startDownload {
          startBundleDownload()
      }
      onFinished()
  }
  ```
  在 `startBundleDownload()` 中：
  ```swift
  let totalMB = variants.reduce(0) { $0 + $1.approximateSizeMB }
  if let warning = downloadManager.insufficientDiskSpaceWarning(forTotalMB: totalMB) {
      diskSpaceWarningMessage =
          "下载「\(bundle.displayName)」\(warning.errorDescription ?? "")。请清理磁盘空间后重试。"
      return
  }
  ```
  当磁盘空间不足时（例如剩余 5GB，而需要 13.9GB）：
  1. `startBundleDownload()` 赋值 `diskSpaceWarningMessage` 后执行 `return`；
  2. 控制流返回到 `finish`，紧接着在下一行**无条件同步执行了 `onFinished()`**；
  3. `AppDelegate` 中的 `onFinished` 闭包为：
     ```swift
     onFinished: { [weak self, weak window] in
         window?.close()
         self?.onboardingWindow = nil
     }
     ```
  4. 宿主 `NSWindow` 被立即关闭并置空销毁，挂载在 `OnboardingView` 上的 `.alert("磁盘空间不足", isPresented: ...)` **根本来不及在屏幕上渲染就随着窗口的关闭而被瞬间销毁**！
  5. 此时 `UserDefaults` 中的 `hasCompletedOnboarding` **已被提前写入 `true`**。
  6. **用户遭遇的实际体验**：新用户在磁盘不足时点击“一键开启并下载”，向导窗口瞬间消失，无任何错误弹窗提示，没有启动任何下载，且以后启动再也不会弹出向导；用户以为软件已在后台静默下载大模型，实际却永久停留在系统自带引擎，形成典型的“吞错误 + 假象”。
- **修复方案**：
  让 `startBundleDownload()` 返回 `Bool`（校验失败返回 `false`）。只有在无需下载或下载成功启动时，才标记向导完成并关闭窗口：
  ```swift
  private func finish(startDownload: Bool) {
      if startDownload {
          guard startBundleDownload() else { return }
      }
      UserDefaults.standard.set(true, forKey: PersistedOnboardingKey.hasCompletedOnboarding)
      onFinished()
  }

  private func startBundleDownload() -> Bool {
      guard let bundle = ProviderCatalog.bundles.first(where: { $0.id == "bundle.standard-realtime" }) else {
          return true
      }
      let variants = bundle.variantIDs.compactMap(ProviderCatalog.variant(forID:))
          .filter { !downloadManager.isDownloaded($0) }
      guard !variants.isEmpty else { return true }

      let totalMB = variants.reduce(0) { $0 + $1.approximateSizeMB }
      if let warning = downloadManager.insufficientDiskSpaceWarning(forTotalMB: totalMB) {
          diskSpaceWarningMessage =
              "下载「\(bundle.displayName)」\(warning.errorDescription ?? "")。请清理磁盘空间后重试。"
          return false
      }

      for variant in variants {
          Task {
              do {
                  _ = try await downloadManager.ensureDownloaded(variant)
                  activateIfStillSystemEngine(variant)
              } catch {
              }
          }
      }
      session.statusMessage = "模型正在后台下载中，下载完成后将自动为您无缝启用"
      return true
  }
  ```

---

### [NICE-TO-HAVE 1] `ModelManagementView` 激活横幅中的“撤销切换”按钮缺少录制中保护
- **涉及文件**：[`Sources/OmniVoice/Views/ModelManagementView.swift#L128-L132`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/ModelManagementView.swift#L128-L132)
- **严重性**：边缘交互保护 (Severity: Low，不阻塞合入)。
- **分析**：
  若模型下载完成并在空闲时触发了自动切换，界面上方展示了带“撤销切换”按钮的横幅；若用户此时开启了录制，随后进入设置页模型库点击“撤销切换”，`banner.undo()` 将直接修改 `session.transcriptionEngineID`，同样会触发 `discardLoadedModelsIfStale()`。
- **建议**：
  为 `Button("撤销切换")` 添加 `.disabled(session.isSessionActive)`。

---

## 4. Round 1 的 5 项 Nice-to-Have 复核状态

经代码比对，Round 1 提出的 5 项非阻塞优化建议在 `c2e0b69` 中均未处理，维持原状：
1. **[NICE-TO-HAVE 1] `OnboardingView` 窗口高度固定且无 `ScrollView` 兜底**：未修改（窗口仍为 420pt，无 ScrollView）。
2. **[NICE-TO-HAVE 2] 显存控制台中状态指示圆点与文本 Emoji 视觉冗余**：未修改（仍保留 Emoji 与自定义圆点并存）。
3. **[NICE-TO-HAVE 3] 推荐组合包下载前置磁盘校验未计算全量总和**：未修改，但 `ModelDownloadManager` 现已提供 `insufficientDiskSpaceWarning(forTotalMB:)`，未来可直接复用。
4. **[NICE-TO-HAVE 4] 推荐组合包下载中缺少一键取消**：未修改。
5. **[NICE-TO-HAVE 5] `ModelManagementView` 多层 `.alert` 挂载于同一视图**：未修改。

上述项目均属于体验锦上添花，不阻塞合入。

---

## 5. 审查总结与合入建议

- **复核达标情况**：
  - Must-Fix 1（录制中守卫）：**完全达标**
  - Must-Fix 2（悬浮窗紧凑模式）：**完全达标**
  - Must-Fix 3（下载自动激活录制守卫）：**完全达标**
  - Must-Fix 5（下载节流与重绘优化）：**完全达标**
  - Must-Fix 4（Onboarding 磁盘预检+自动激活）：**激活逻辑与容量汇总已达标，但窗口销毁时序导致 Alert 弹窗失效并引入新缺陷**
- **当前判定**：**暂缓合入 (1 项 Must-Fix 待补丁)**。
- **后续行动**：
  仅需在 [`OnboardingView.swift`](file:///Users/hd/orca/workspaces/OmniVoice/feature-ui-ux-optimization/Sources/OmniVoice/Views/OnboardingView.swift) 中按照第 3 节方案，将 `startBundleDownload()` 改为返回 `Bool` 并在 `finish()` 中用 `guard` 拦截 `onFinished()`，即可彻底解决该问题并达到最终合入标准。
