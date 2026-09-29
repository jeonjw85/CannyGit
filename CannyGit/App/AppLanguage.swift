import AppKit

enum AppLanguage: String {
    case english = "en"
    case korean = "ko"

    static let storageKey = "cannyGitLanguage"
    private static let relaunchKey = "cannyGitRelaunchLanguage"

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? Self.english.rawValue) ?? .english
    }

    static func bootstrap() {
        guard !isTestProcess else { return }
        let language = UserDefaults.standard.string(forKey: storageKey) ?? Self.english.rawValue
        UserDefaults.standard.set(language, forKey: storageKey)
        UserDefaults.standard.set([language], forKey: "AppleLanguages")
    }

    @MainActor static func requestChange(to language: AppLanguage) {
        guard language != current else { return }
        UserDefaults.standard.set(language.rawValue, forKey: relaunchKey)
        NSApp.terminate(nil)
    }

    static func cancelRelaunch() {
        UserDefaults.standard.removeObject(forKey: relaunchKey)
    }

    @MainActor static func finishRelaunchIfNeeded() {
        guard let raw = UserDefaults.standard.string(forKey: relaunchKey), AppLanguage(rawValue: raw) != nil else { return }
        UserDefaults.standard.removeObject(forKey: relaunchKey)
        UserDefaults.standard.set(raw, forKey: storageKey)
        UserDefaults.standard.set([raw], forKey: "AppleLanguages")
        CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
    }

    private static var isTestProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CANNYGIT_TEST_SETTINGS"] != nil
            || environment["CANNYGIT_TEST_HOST"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
    }
}
