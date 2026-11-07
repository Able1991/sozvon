// Which processes use the microphone, from Core Audio (macOS 14.2+ process objects).
//
// No permission is needed: these are Core Audio HAL properties (is a device running, which client
// processes have input running, their pid and bundle id), not audio. Nothing here opens an input
// stream or reads a sample, so the microphone TCC prompt never appears and the orange mic indicator
// is not lit by Sozvon. The same properties are what mic-indicator utilities read.
//
// Change notifications: the process object list, each process's IsRunningInput, the default input
// device and its IsRunningSomewhere. While the input device runs, a slow poll backs them up
// (a listener the HAL skipped must not leave a stale prompt on screen).

import CoreAudio
import Darwin
import Foundation

@MainActor
public final class CoreAudioMicSource: MicActivitySource {
    private typealias Listener = (object: AudioObjectID, address: AudioObjectPropertyAddress,
                                  block: AudioObjectPropertyListenerBlock)
    private var onChange: (@MainActor () -> Void)?
    private var systemListeners: [Listener] = []
    private var deviceListener: Listener?
    private var processListeners: [AudioObjectID: Listener] = [:]
    private var poll: Timer?
    /// Poll interval while the input device is running somewhere.
    static let pollInterval: TimeInterval = 3

    public init() {}

    public func start(onChange: @escaping @MainActor () -> Void) {
        guard self.onChange == nil else { return }
        self.onChange = onChange
        let system = AudioObjectID(kAudioObjectSystemObject)
        systemListeners = [
            listen(system, kAudioHardwarePropertyProcessObjectList) { $0.processesChanged() },
            listen(system, kAudioHardwarePropertyDefaultInputDevice) { $0.deviceChanged() },
        ].compactMap { $0 }
        deviceChanged()
        processesChanged()
    }

    public func stop() {
        for l in systemListeners { remove(l) }
        systemListeners = []
        if let d = deviceListener { remove(d) }
        deviceListener = nil
        for l in processListeners.values { remove(l) }
        processListeners = [:]
        poll?.invalidate()
        poll = nil
        onChange = nil
    }

    public func activeClients() -> [MicClient] {
        Self.processObjects().compactMap { obj in
            guard Self.uint32(obj, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            let pid = Self.pid(obj)
            return MicClient(pid: pid, bundleID: Self.string(obj, kAudioProcessPropertyBundleID) ?? "",
                             processName: Self.processName(pid))
        }
    }

    // MARK: Listeners

    private func changed() {
        updatePoll()
        onChange?()
    }

    private func processesChanged() {
        let now = Set(Self.processObjects())
        for (obj, l) in processListeners where !now.contains(obj) {
            remove(l)
            processListeners[obj] = nil
        }
        for obj in now where processListeners[obj] == nil {
            if let l = listen(obj, kAudioProcessPropertyIsRunningInput, { $0.changed() }) { processListeners[obj] = l }
        }
        changed()
    }

    private func deviceChanged() {
        if let d = deviceListener { remove(d) }
        deviceListener = nil
        let dev = Self.defaultInput()
        if dev != kAudioObjectUnknown {
            deviceListener = listen(dev, kAudioDevicePropertyDeviceIsRunningSomewhere) { $0.changed() }
        }
        changed()
    }

    private func updatePoll() {
        let dev = Self.defaultInput()
        let running = dev != kAudioObjectUnknown && Self.uint32(dev, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
        if running, poll == nil {
            let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.onChange?() }
            }
            RunLoop.main.add(t, forMode: .common)
            poll = t
        } else if !running {
            poll?.invalidate()
            poll = nil
        }
    }

    private func listen(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        _ handler: @escaping @MainActor (CoreAudioMicSource) -> Void) -> Listener? {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Delivered on the main queue (below).
            MainActor.assumeIsolated {
                if let self { handler(self) }
            }
        }
        guard AudioObjectAddPropertyListenerBlock(obj, &address, DispatchQueue.main, block) == noErr else { return nil }
        return (obj, address, block)
    }

    private func remove(_ l: Listener) {
        var address = l.address
        AudioObjectRemovePropertyListenerBlock(l.object, &address, DispatchQueue.main, l.block)
    }

    // MARK: Core Audio reads

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func defaultInput() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &dev) == noErr
        else { return AudioObjectID(kAudioObjectUnknown) }
        return dev
    }

    private static func uint32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &v) == noErr ? v : nil
    }

    private static func pid(_ obj: AudioObjectID) -> Int32 {
        var address = address(kAudioProcessPropertyPID)
        var v: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &v) == noErr ? v : -1
    }

    private static func string(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &address, 0, nil, &size, $0) }
        guard status == noErr, let s = value?.takeRetainedValue() else { return nil }
        return s as String
    }

    private static func processName(_ pid: Int32) -> String {
        guard pid > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return "" }
        return String(cString: buf)
    }
}
