// The system input volume of the default microphone (System Settings > Sound > Input), 0...1.
// Browser calls (WebRTC) often lower it on their own, and then the recording of your voice is very quiet.

import CoreAudio
import Foundation

enum InputVolume {
    /// nil when the device has no software volume (some USB microphones).
    static func current() -> Float? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        for element in [kAudioObjectPropertyElementMain, 1] {
            var v = Float32(0)
            var vs = UInt32(MemoryLayout<Float32>.size)
            var va = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                mScope: kAudioDevicePropertyScopeInput, mElement: element)
            if AudioObjectHasProperty(device, &va), AudioObjectGetPropertyData(device, &va, 0, nil, &vs, &v) == noErr {
                return v
            }
        }
        return nil
    }
}
