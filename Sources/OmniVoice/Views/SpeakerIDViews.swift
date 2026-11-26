import AppKit
import OmniVoiceCore
import SwiftUI

// Speaker identification UI: labels in the Caption panel and History, the
// rename dialog, the on/off switches and the Settings section.

/// The speaker label in History (display only). Shows nothing when `name` is nil.
struct SpeakerBadge: View {
    let name: String?

    var body: some View {
        if let name {
            SpeakerChip(text: name, color: SpeakerChip.color(for: name))
        }
    }
}

/// The speaker label above each row of the Caption panel:
/// - click the name to rename the speaker (optionally remembering the voice)
/// - the bookmark button next to it remembers the voice; filled when remembered
struct SpeakerLiveBadge: View {
    let key: String?
    @ObservedObject private var tagger = SpeakerTagger.shared

    var body: some View {
        if let key {
            let name = tagger.displayName(for: key)
            let remembered = tagger.isRemembered(key)
            HStack(spacing: 4) {
                Button {
                    SpeakerNameDialog.present(key: key, rememberChecked: remembered)
                } label: {
                    SpeakerChip(text: name, color: SpeakerChip.color(for: name))
                }
                .buttonStyle(.plain)
                .help("Click to rename this speaker")

                Button {
                    if remembered { return }
                    if !tagger.remember(key) {
                        // No name yet: ask for one, then remember.
                        SpeakerNameDialog.present(key: key, rememberChecked: true)
                    }
                } label: {
                    Image(systemName: remembered ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 10))
                        .foregroundStyle(remembered ? Color.green : .secondary)
                }
                .buttonStyle(.plain)
                .help(remembered
                    ? "Voice remembered: future transcriptions show “\(name)” automatically (remove it in Settings)"
                    : "Remember voice: show this name automatically the next time this person speaks")
            }
        }
    }
}

/// A small colored capsule.
struct SpeakerChip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
    }

    /// The same name always gets the same color.
    static func color(for seed: String) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .brown, .indigo]
        let n = seed.unicodeScalars.reduce(UInt32(7)) { ($0 &* 31) &+ $1.value }
        return palette[Int(n % UInt32(palette.count))]
    }
}

/// Rename dialog. The Caption panel doesn't take keyboard input, so the name
/// is typed into a standard alert.
@MainActor
enum SpeakerNameDialog {
    static func present(key: String, rememberChecked: Bool) {
        let tagger = SpeakerTagger.shared
        let alert = NSAlert()
        alert.messageText = String(localized: "Name this speaker")
        let saved = tagger.profiles.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        alert.informativeText = saved.isEmpty
            ? String(localized: "Everything this person said in this transcription will show this name. Leave it empty to go back to “Speaker \(key)”.")
            : String(localized: "Pick a remembered person from the list (they are merged into the same voice) or type a new name. Leave it empty to go back to “Speaker \(key)”.")
        // Combo box: remembered names to pick from, or type a new one. Picking
        // avoids near-duplicates like “Irene” vs “Me (Irene)”.
        let field = NSComboBox(frame: NSRect(x: 0, y: 28, width: 260, height: 26))
        field.addItems(withObjectValues: saved)
        field.completes = true
        field.numberOfVisibleItems = min(max(saved.count, 1), 10)
        field.placeholderString = saved.isEmpty
            ? String(localized: "For example: Alex")
            : String(localized: "Pick a remembered person or type a new name")
        field.stringValue = tagger.names[key] ?? ""
        let check = NSButton(checkboxWithTitle: String(localized: "Remember this voice (recognize it next time)"), target: nil, action: nil)
        check.frame = NSRect(x: 0, y: 0, width: 260, height: 20)
        check.state = rememberChecked ? .on : .off
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        box.addSubview(field)
        box.addSubview(check)
        alert.accessoryView = box
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tagger.rename(key, to: name)
        // Picking a remembered person already merged the voice in `rename`.
        if check.state == .on, !saved.contains(name) { tagger.remember(key) }
    }
}

extension SpeakerNameDialog {
    /// Asks for a single name (used when tidying up). Returns nil on Cancel.
    static func ask(title: String, message: String, initial: String = "") -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let saved = SpeakerTagger.shared.profiles.map(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let field = NSComboBox(frame: NSRect(x: 0, y: 0, width: 260, height: 26))
        field.addItems(withObjectValues: saved)
        field.completes = true
        field.numberOfVisibleItems = min(max(saved.count, 1), 10)
        field.stringValue = initial
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "OK"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// Settings → Tidy Up remembered voices: points out a name whose samples
/// disagree and names that sound alike, with merge / split / remove actions.
struct SpeakerOrganizerView: View {
    @ObservedObject var tagger = SpeakerTagger.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tidy Up Remembered Voices").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            List {
                let issues = tagger.profileIssues
                Section(issues.isEmpty ? String(localized: "Nothing to check") : String(localized: "To check (\(issues.count))")) {
                    if issues.isEmpty {
                        Text("Each person's samples agree, and different people are well apart.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(issues) { issue in issueRow(issue).padding(.vertical, 4) }
                }
                Section(String(localized: "All (\(tagger.profiles.count))")) {
                    ForEach(tagger.profiles) { p in profileRow(p, issues: issues) }
                }
                Section {
                    Text("Similarity says how alike two voices are: 1 is identical; the same person in two transcriptions is usually above 0.45, different people usually below 0.3. Merges and splits take effect from the next transcription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 560, height: 520)
    }

    private func name(_ id: UUID) -> String { tagger.profiles.first { $0.id == id }?.name ?? "?" }
    private func fmt(_ v: Float) -> String { String(format: "%.2f", v) }

    @ViewBuilder
    private func issueRow(_ issue: SpeakerProfileIssue) -> some View {
        switch issue.kind {
        case let .similar(a, b, sim, likelySame):
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(likelySame
                         ? String(localized: "“\(name(a))” and “\(name(b))” sound very alike (similarity \(fmt(sim))) and are probably the same person.")
                         : String(localized: "“\(name(a))” and “\(name(b))” sound fairly alike (similarity \(fmt(sim))) and may be mixed up during a transcription."))
                } icon: {
                    Image(systemName: likelySame ? "person.2.fill" : "exclamationmark.triangle")
                        .foregroundStyle(likelySame ? Color.orange : .yellow)
                }
                HStack {
                    Button(String(localized: "Merge into “\(name(a))”")) { tagger.mergeProfile(b, into: a) }
                    Button(String(localized: "Merge into “\(name(b))”")) { tagger.mergeProfile(a, into: b) }
                    Button("Different People") { tagger.markDistinct(a, b) }
                }
                .controlSize(.small)
            }
        case let .mixed(pid, samples, sims):
            let all = tagger.profiles.first { $0.id == pid }?.allSamples ?? []
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text(String(localized: "The samples remembered for “\(name(pid))” don't agree; one may have picked up somebody else."))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                ForEach(Array(zip(samples, sims)), id: \.0) { index, sim in
                    if all.indices.contains(index) {
                        HStack {
                            Text(String(localized: "\(sampleText(all[index])): similarity to the others only \(fmt(sim))"))
                                .font(.callout)
                            Spacer()
                            Button("Remove This One") { tagger.removeSample(of: pid, at: index) }
                            Button("Somebody Else…") {
                                if let n = SpeakerNameDialog.ask(
                                    title: String(localized: "Who was this?"),
                                    message: String(localized: "This sample moves to that name (merged in if the name is already remembered).")
                                ) {
                                    tagger.splitSample(of: pid, at: index, as: n)
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func sampleText(_ s: SpeakerSample) -> String {
        let date = s.date.formatted(date: .abbreviated, time: .shortened)
        return s.seconds > 0
            ? String(localized: "Remembered \(date) (\(Int(s.seconds.rounded())) s)")
            : String(localized: "Remembered \(date)")
    }

    private func profileRow(_ p: SpeakerProfile, issues: [SpeakerProfileIssue]) -> some View {
        let involved = issues.contains { i in
            switch i.kind {
            case let .mixed(id, _, _): return id == p.id
            case let .similar(a, b, _, _): return a == p.id || b == p.id
            }
        }
        let count = p.allSamples.count
        return HStack(spacing: 8) {
            SpeakerChip(text: p.name, color: SpeakerChip.color(for: p.name))
            Image(systemName: involved ? "exclamationmark.circle" : "checkmark.circle")
                .foregroundStyle(involved ? Color.orange : .green)
            Text(involved ? String(localized: "See above")
                 : count > 1 ? String(localized: "Remembered \(count) times, consistent") : String(localized: "Remembered once"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Rename…") {
                if let n = SpeakerNameDialog.ask(
                    title: String(localized: "Rename “\(p.name)”"),
                    message: String(localized: "Renaming to another remembered name merges the two."),
                    initial: p.name
                ) {
                    tagger.renameProfile(p.id, to: n)
                }
            }
            Button("Forget", role: .destructive) { tagger.forget(p.id) }
        }
        .controlSize(.small)
    }
}

/// The switch in the Caption panel's control bar.
struct SpeakerToggleButton: View {
    @ObservedObject var tagger = SpeakerTagger.shared

    var body: some View {
        Button {
            tagger.isEnabled.toggle()
        } label: {
            Image(systemName: tagger.isEnabled ? "person.2.wave.2.fill" : "person.2.wave.2")
                .foregroundStyle(tagger.isEnabled ? Color.accentColor : .secondary)
                .overlay(alignment: .topTrailing) {
                    if tagger.status == .loading || tagger.status == .downloading {
                        ProgressView().controlSize(.mini).offset(x: 6, y: -6)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(helpText)
    }

    private var helpText: String {
        switch tagger.status {
        case .off: return String(localized: "Identify speakers: off (click to turn on)")
        case .downloading: return String(localized: "Identify speakers: downloading the voice model (about 28 MB)…")
        case .loading: return String(localized: "Identify speakers: loading…")
        case .ready: return String(localized: "Identify speakers: on, speakers heard so far: \(tagger.speakerCount) (click to turn off)")
        case .failed(let m): return String(localized: "Identify speakers: \(m)")
        }
    }
}

/// The switch in the menu bar popover.
struct SpeakerMenuToggle: View {
    @ObservedObject var tagger = SpeakerTagger.shared

    var body: some View {
        Toggle(isOn: $tagger.isEnabled) {
            Text("Identify speakers")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        if case .failed(let m) = tagger.status {
            Text(m).font(.caption).foregroundStyle(.red)
        }
    }
}

/// Settings → Speech Recognition: switch, sensitivity and remembered voices.
struct SpeakerIDSettingsSection: View {
    @ObservedObject var tagger = SpeakerTagger.shared
    @State private var showOrganizer = false

    var body: some View {
        Section("Identify speakers") {
            SettingsFormRow(title: "Identify speakers", subtitle: subtitle, subtitleTint: subtitleTint) {
                Toggle("", isOn: $tagger.isEnabled).labelsHidden().toggleStyle(.switch)
            }
            SettingsFormRow(
                title: "Speaker sensitivity",
                subtitle: String(localized: "Currently \(String(format: "%.2f", tagger.threshold)). Lower it if one person keeps being split in two; raise it if different people are merged. Default \(String(format: "%.2f", SpeakerTagger.defaultThreshold)).")
            ) {
                HStack {
                    Slider(value: $tagger.threshold, in: 0.35...0.85, step: 0.05).frame(width: 160)
                    Button("Restore Default") { tagger.threshold = SpeakerTagger.defaultThreshold }
                        .controlSize(.small)
                }
            }
            SettingsFormRow(
                title: "Remembered voices",
                subtitle: tagger.profiles.isEmpty
                    ? String(localized: "None yet. Click the bookmark next to a speaker in the Caption panel to remember their voice.")
                    : rememberedHint
            ) {
                if !tagger.profiles.isEmpty {
                    Button(issueCount > 0 ? String(localized: "Tidy Up (\(issueCount) to Check)…") : String(localized: "Tidy Up…")) {
                        showOrganizer = true
                    }
                    .controlSize(.small)
                }
            }
            .sheet(isPresented: $showOrganizer) { SpeakerOrganizerView() }
            ForEach(tagger.profiles) { profile in
                LabeledContent {
                    Button("Forget", role: .destructive) { tagger.forget(profile.id) }
                        .controlSize(.small)
                } label: {
                    HStack(spacing: 6) {
                        SpeakerChip(text: profile.name, color: SpeakerChip.color(for: profile.name))
                        Text("Remembered \(profile.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var issueCount: Int { tagger.profileIssues.count }

    private var rememberedHint: String {
        issueCount > 0
            ? String(localized: "Future transcriptions show these names as soon as the person speaks. \(issueCount) may be mixed up or duplicated; click Tidy Up to check.")
            : String(localized: "Future transcriptions show these names as soon as the person speaks.")
    }

    private var subtitle: String {
        switch tagger.status {
        case .off: return String(localized: "Uses no resources while off. When on, each row takes a few extra milliseconds in the background, without slowing translation.")
        case .downloading: return String(localized: "Downloading the voice model (about 28 MB)…")
        case .loading: return String(localized: "Loading the voice model…")
        case .ready: return String(localized: "On. Each transcription numbers new voices from “Speaker A”; remembered voices show their names.")
        case .failed(let m): return m
        }
    }

    private var subtitleTint: Color {
        if case .failed = tagger.status { return .red }
        return .secondary
    }
}
