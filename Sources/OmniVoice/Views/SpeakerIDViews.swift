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
        alert.informativeText = String(localized: "Everything this person said in this transcription will show this name. Leave it empty to go back to “Speaker \(key)”.")
        let field = NSTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        field.placeholderString = String(localized: "For example: Alex")
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
        tagger.rename(key, to: field.stringValue)
        if check.state == .on { tagger.remember(key) }
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
                    : String(localized: "Future transcriptions show these names as soon as the person speaks.")
            ) {
                EmptyView()
            }
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
