import Foundation

/// Saved sizes of the home page's resizable columns and panels, and their defaults.
/// View → Reset Layout (or the user menu) puts them all back.
enum Layout {
    static let scriptsKey = "home.scriptsFraction"
    static let queueKey = "home.queueFraction"
    static let queueHeightKey = "home.queueHeightFraction"
    static let newsHeightKey = "home.newsHeightFraction"
    static let sidebarKey = "showInfoSidebar"

    /// Scripts' share of the width; the queue and news columns split the rest evenly.
    static let defaultScripts = 0.22
    static let defaultQueue = 0.5
    /// Story Queue over Story Tracker, and team news over league news: half and half.
    static let defaultQueueHeight = 0.5
    static let defaultNewsHeight = 0.5

    /// Back to the defaults, with the right sidebar showing.
    static func reset() {
        let defaults = UserDefaults.standard
        defaults.set(defaultScripts, forKey: scriptsKey)
        defaults.set(defaultQueue, forKey: queueKey)
        defaults.set(defaultQueueHeight, forKey: queueHeightKey)
        defaults.set(defaultNewsHeight, forKey: newsHeightKey)
        defaults.set(true, forKey: sidebarKey)
    }
}
