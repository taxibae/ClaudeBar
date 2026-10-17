import Foundation

/// Supported app languages with native display names
enum AppLanguage: String, CaseIterable {
    case system = "system"
    case en = "en"

    var displayName: String {
        switch self {
        case .system: return L("settings.language.system")
        case .en: return "English"
        }
    }
}

/// SwiftPM'in ürettiği Bundle.module yalnızca .app kökünü ve derleme dizinini arar.
/// Kökte duran bir paket codesign tarafından "unsealed content" sayılıp imzayı bozduğu
/// için build.sh kaynakları Contents/Resources altına koyar; önce orası denenir.
/// swift run ve testlerde orada bir şey yoktur, Bundle.module derleme dizinini bulur.
private let resourceBundle: Bundle = {
    let name = "LLMBar_LLMBar.bundle"
    if let resources = Bundle.main.resourceURL,
       let bundle = Bundle(url: resources.appendingPathComponent(name)) {
        return bundle
    }
    return Bundle.module
}()

/// Cached bundle state to avoid repeated UserDefaults reads and bundle lookups
private var cachedLanguageCode: String?
private var cachedBundle: Bundle?

/// Invalidates the cached bundle so the next L() call resolves it fresh
func invalidateBundleCache() {
    cachedLanguageCode = nil
    cachedBundle = nil
}

/// A stored language that is no longer shipped behaves as the system default
private func selectedLanguageCode() -> String {
    let stored = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
    return (AppLanguage(rawValue: stored) ?? .system).rawValue
}

/// Returns the override bundle for the selected language, or nil for system default
private func resolvedBundle() -> Bundle {
    let code = selectedLanguageCode()
    
    if code == cachedLanguageCode, let cached = cachedBundle {
        return cached
    }
    
    cachedLanguageCode = code
    
    guard code != "system" else {
        cachedBundle = resourceBundle
        return resourceBundle
    }

    if let path = resourceBundle.path(forResource: code, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        cachedBundle = bundle
        return bundle
    }

    let bundlePath = resourceBundle.bundlePath
    let candidates = [code, code.lowercased()]
    for candidate in candidates {
        let lprojPath = (bundlePath as NSString).appendingPathComponent("\(candidate).lproj")
        if FileManager.default.fileExists(atPath: lprojPath),
           let bundle = Bundle(path: lprojPath) {
            cachedBundle = bundle
            return bundle
        }
    }

    cachedBundle = resourceBundle
    return resourceBundle
}

/// Returns the active locale based on user's language selection
func activeLocale() -> Locale {
    let code = selectedLanguageCode()
    guard code != "system" else { return .current }
    return Locale(identifier: code)
}

/// Localized string lookup with language override support
func L(_ key: String) -> String {
    let bundle = resolvedBundle()
    return NSLocalizedString(key, bundle: bundle, comment: "")
}

/// Localized string with format arguments
func L(_ key: String, _ args: CVarArg...) -> String {
    let bundle = resolvedBundle()
    let format = NSLocalizedString(key, bundle: bundle, comment: "")
    return String(format: format, arguments: args)
}
