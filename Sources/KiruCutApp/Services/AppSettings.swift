import Foundation

enum AppSettings {
    private static let useInstalledFFmpegKey = "UseInstalledFFmpeg"
    private static let showOpenInputAtLaunchKey = "ShowOpenInputAtLaunch"

    static var useInstalledFFmpeg: Bool {
        UserDefaults.standard.bool(forKey: useInstalledFFmpegKey)
    }

    static func setUseInstalledFFmpeg(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: useInstalledFFmpegKey)
    }

    static var showOpenInputAtLaunch: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: showOpenInputAtLaunchKey) == nil {
            return true
        }
        return defaults.bool(forKey: showOpenInputAtLaunchKey)
    }

    static func setShowOpenInputAtLaunch(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: showOpenInputAtLaunchKey)
    }

    static func applyLaunchDefaults() {
        // Keep installed ffmpeg opt-in by default on every launch.
        setUseInstalledFFmpeg(false)
    }
}
