import CoreAudio
import Foundation

/// Whether an app is playing sound right now, as Core Audio sees it (this needs no permission). The
/// stash tab uses it to tell a playing video from a paused one.
enum Audio {
    /// `nil` if macOS can't say (before macOS 14.2).
    static func isPlaying(appAt bundlePath: String) -> Bool? {
        guard #available(macOS 14.2, *) else { return nil }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return nil }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return nil }
        // A browser may play sound from a helper process, so any process inside the app counts.
        let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        return processes.contains { process in
            read(process, kAudioProcessPropertyIsRunningOutput, as: UInt32.self) == 1
                && read(process, kAudioProcessPropertyPID, as: pid_t.self).map { path(of: $0).hasPrefix(prefix) } == true
        }
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, as: T.Type) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
    }
}
