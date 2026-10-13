import Foundation
import Testing
@testable import OmniVoiceCore

@Suite("PolishSettings")
struct PolishSettingsTests {
    private func freshDefaults() -> UserDefaults {
        let name = "polish-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("an older version's defaults (no polish keys) give the documented defaults")
    func migration() {
        let settings = PolishSettings.load(from: freshDefaults())
        #expect(settings.isEnabled == false)
        #expect(settings.style == .clean)
        #expect(settings.timeoutSeconds == 8)
        #expect(settings.extra == "")
        #expect(settings.hasAcknowledgedPrivacy == false)
        #expect(settings.preset == .openAI)
        #expect(settings.baseURL == PolishPreset.openAI.baseURL)
    }

    @Test("saved values round-trip")
    func roundTrip() {
        let defaults = freshDefaults()
        var settings = PolishSettings()
        settings.isEnabled = true
        settings.apply(preset: .ollama)
        settings.style = .professional
        settings.extra = "称呼用您"
        settings.timeoutSeconds = 12
        settings.hasAcknowledgedPrivacy = true
        settings.save(to: defaults)
        #expect(PolishSettings.load(from: defaults) == settings)
    }

    @Test("the timeout stays within 3...30 s, also when read back")
    func timeoutClamp() {
        var settings = PolishSettings()
        settings.timeoutSeconds = 1
        #expect(settings.timeoutSeconds == 3)
        settings.timeoutSeconds = 99
        #expect(settings.timeoutSeconds == 30)
        let defaults = freshDefaults()
        defaults.set(500, forKey: PolishSettings.timeoutKey)
        #expect(PolishSettings.load(from: defaults).timeoutSeconds == 30)
    }

    @Test("a stored extra longer than the limit is cut")
    func extraCap() {
        let defaults = freshDefaults()
        defaults.set(String(repeating: "a", count: 900), forKey: PolishSettings.extraKey)
        #expect(PolishSettings.load(from: defaults).extra.count == 500)
    }

    @Test("a preset fills Base URL and model, custom keeps them")
    func presets() {
        var settings = PolishSettings()
        settings.apply(preset: .deepSeek)
        #expect(settings.baseURL == "https://api.deepseek.com/v1")
        #expect(settings.model == "deepseek-chat")
        settings.apply(preset: .custom)
        #expect(settings.baseURL == "https://api.deepseek.com/v1")
        #expect(settings.preset == .custom)
    }

    @Test("configured needs a URL, a model and a key — except on this Mac")
    func configured() {
        var settings = PolishSettings()
        #expect(settings.isConfigured(hasAPIKey: true))
        #expect(!settings.isConfigured(hasAPIKey: false))
        settings.apply(preset: .ollama)
        #expect(settings.isLocalEndpoint)
        #expect(settings.isConfigured(hasAPIKey: false))
        settings.model = " "
        #expect(!settings.isConfigured(hasAPIKey: true))
        settings.apply(preset: .custom)
        settings.baseURL = "not a url"
        settings.model = "m"
        #expect(!settings.isConfigured(hasAPIKey: true))
    }

    @Test("plain http to a remote host is flagged, localhost and https are not")
    func insecure() {
        var settings = PolishSettings()
        settings.baseURL = "http://example.com/v1"
        #expect(settings.usesInsecureRemoteEndpoint)
        settings.baseURL = "http://127.0.0.1:11434/v1"
        #expect(!settings.usesInsecureRemoteEndpoint)
        settings.baseURL = "https://example.com/v1"
        #expect(!settings.usesInsecureRemoteEndpoint)
    }

    @Test("the in-memory credential store holds and clears a key")
    func credentials() {
        let store = InMemoryPolishCredentialStore()
        #expect(!store.hasAPIKey)
        store.setAPIKey("sk-x")
        #expect(store.apiKey() == "sk-x")
        store.setAPIKey(nil)
        #expect(!store.hasAPIKey)
    }
}
