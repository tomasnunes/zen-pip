import AppKit

// MARK: - Which windows are PiP windows

/// Browsers whose always-on-top windows may be video PiP windows.
let browserBundleIDs: Set<String> = [
    // Firefox-based
    "app.zen-browser.zen", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
    "org.mozilla.nightly", "io.gitlab.librewolf-community",
    // Chromium-based
    "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "org.chromium.Chromium",
    "com.brave.Browser", "net.imput.helium", "com.microsoft.edgemac", "com.vivaldi.Vivaldi",
]

/// Titles of video PiP windows. The Firefox/Zen ones are Zen's own translations of
/// "Picture-in-Picture", so a small always-on-top window showing a web page is never moved.
let pipTitles: Set<String> = [
    "Picture-in-Picture", "Picture-in-picture", "Picture in picture", "Picture in Picture",
    "Bild-i-bild", "Bild-im-Bild", "Bilde-i-bilde", "Billede-i-billede", "Gambar-dalam-Gambar",
    "Görüntü içinde görüntü", "Hình trong hình", "Imagine în imagine", "Imatge sobre imatge",
    "Incrustation vidéo", "Kuva kuvassa", "Kép a képben", "Llun-mewn-Llun", "Mynd-í-mynd",
    "Obraz v obraze", "Obraz w obrazie", "Pictiúr i bPictiúr", "Pilt-pildis", "Slika-u-slici",
    "Vaizdas-vaizde", "Vídeo em janela flutuante", "Imagen en imagen", "Imagen dentro de imagen",
    "Εικόνα εντός εικόνας", "Зображення в зображенні", "Картина в картината", "Картинка в картинке",
    "תמונה בתוך תמונה", "تصویر در تصویر", "فديو معترِض", "ภาพซ้อนภาพ", "ピクチャーインピクチャー",
    "子母畫面", "画中画", "화면 속 화면",
]

func isPipTitle(_ title: String) -> Bool {
    // Some translations use a non-breaking space (Polish: "Obraz w obrazie").
    let normalised = title.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces)
    return pipTitles.contains(normalised)
}

// MARK: - The window list

/// What the window server reports about an on-screen window.
struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let layer: Int
    let owner: String
    let alpha: Double
}

enum WindowList {
    private static let cursorLevel = Int(CGWindowLevelForKey(.cursorWindow))

    private static func raw() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }

    /// On-screen windows, front to back.
    static func onScreen() -> [WindowInfo] {
        raw().compactMap(parse)
    }

    static func frame(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] else { return nil }
        return list.first.flatMap(parse)?.frame
    }

    static func displayFrames() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// Windows you see and click straight through, which can sit above everything else: the pointer,
    /// invisible windows, and always-on-top windows covering a whole display (the Dock's container
    /// during space swipes, screenshot and screen-recording tools such as CleanShot X, dimmers…).
    static func isSeeThroughOverlay(_ w: WindowInfo, displays: [CGRect]) -> Bool {
        if w.layer >= cursorLevel || w.owner == "Window Server" || w.alpha < 0.05 { return true }
        return w.layer != 0 && displays.contains { w.frame.insetBy(dx: -1, dy: -1).contains($0) }
    }

    /// The front-most window under a point that you could actually be scrolling or clicking on.
    static func topmost(at p: CGPoint) -> WindowInfo? {
        let displays = displayFrames()
        return onScreen().first { $0.frame.contains(p) && !isSeeThroughOverlay($0, displays: displays) }
    }

    private static func parse(_ w: [String: Any]) -> WindowInfo? {
        guard let id = w[kCGWindowNumber as String] as? CGWindowID,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let bounds = w[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return WindowInfo(id: id, pid: pid, frame: frame,
                          layer: w[kCGWindowLayer as String] as? Int ?? 0,
                          owner: w[kCGWindowOwnerName as String] as? String ?? "",
                          alpha: w[kCGWindowAlpha as String] as? Double ?? 1)
    }
}

// MARK: - Accessibility

enum AX {
    /// How long to wait for a busy browser before giving up, in seconds.
    static let timeout: Float = 0.15

    /// The Accessibility element for a window: by its window number, or by its frame as a fallback.
    static func window(pid: pid_t, id: CGWindowID, frame: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        for window in windows {
            AXUIElementSetMessagingTimeout(window, timeout)
            if let getWindow = PrivateAPI.axGetWindow {
                var number = CGWindowID(0)
                if getWindow(window, &number) == .success, number == id { return window }
            } else if let f = self.frame(of: window),
                      abs(f.minX - frame.minX) < 2, abs(f.minY - frame.minY) < 2,
                      abs(f.width - frame.width) < 2, abs(f.height - frame.height) < 2 {
                return window
            }
        }
        return nil
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    static func setPosition(_ element: AXUIElement, _ point: CGPoint) {
        var p = point
        if let value = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
    }

    static func setSize(_ element: AXUIElement, _ size: CGSize) {
        var s = size
        if let value = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
    }

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
