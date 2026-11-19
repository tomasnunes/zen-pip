import ApplicationServices

/// Undocumented macOS functions that most window managers rely on. They are looked up at run time,
/// so if a future macOS removes one, ZenPiP loses that feature instead of failing to start:
///
/// - `_AXUIElementGetWindow` matches an Accessibility window to its window number. Without it,
///   PiP windows are matched by position and size instead.
/// - The `CGS…` functions say whether the space on a display is a full-screen app. Without them,
///   every space is treated as a normal desktop (the PiP stays above the Dock).
enum PrivateAPI {
    private static let anyLoadedImage = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT

    private static func lookup<T>(_ name: String, as type: T.Type) -> T? {
        guard let symbol = dlsym(anyLoadedImage, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    typealias MainConnection = @convention(c) () -> Int32
    typealias ActiveSpace = @convention(c) (Int32) -> UInt64
    typealias DisplaySpace = @convention(c) (Int32, CFString) -> UInt64
    typealias SpaceType = @convention(c) (Int32, UInt64) -> Int32

    static let axGetWindow = lookup("_AXUIElementGetWindow", as: GetWindow.self)
    static let mainConnection = lookup("CGSMainConnectionID", as: MainConnection.self)
    static let activeSpace = lookup("CGSGetActiveSpace", as: ActiveSpace.self)
    static let displaySpace = lookup("CGSManagedDisplayGetCurrentSpace", as: DisplaySpace.self)
    static let spaceType = lookup("CGSSpaceGetType", as: SpaceType.self)

    /// The space type `CGSSpaceGetType` reports for a full-screen app (or Split View).
    static let fullScreenSpaceType: Int32 = 4
}
