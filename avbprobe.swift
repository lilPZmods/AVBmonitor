// avbprobe: report the state of the macOS AVB audio device and measure input levels.
// Usage: avbprobe [seconds]   (prints one JSON object)
import CoreAudio
import Foundation

func prop<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ def: T) -> T {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var v = def
    var size = UInt32(MemoryLayout<T>.size)
    let st = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &v)
    return st == noErr ? v : def
}

func cfString(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var s: Unmanaged<CFString>? = nil
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &s) == noErr, let v = s else { return "" }
    return v.takeRetainedValue() as String
}

func channelCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buf) == noErr else { return 0 }
    let abl = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
    return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func findAVBDevice() -> AudioObjectID? {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids.first { prop($0, kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, UInt32(0)) == kAudioDeviceTransportTypeAVB }
}

let args = CommandLine.arguments
let seconds = args.count > 1 ? Double(args[1]) ?? 1.0 : 1.0
// optional: --tone <channel> <dBFS>  plays a 997 Hz test tone on one output channel while measuring
var toneCh = -1; var toneAmp: Float = 0
if let i = args.firstIndex(of: "--tone"), args.count > i + 2 {
    toneCh = (Int(args[i + 1]) ?? 0) - 1
    toneAmp = Float(pow(10.0, (Double(args[i + 2]) ?? -40) / 20))
}
var phase: Double = 0
guard let dev = findAVBDevice() else {
    print("{\"found\":false}")
    exit(2)
}

let nIn = channelCount(dev, kAudioObjectPropertyScopeInput)
var peaks = [Float](repeating: 0, count: nIn)
var callbacks = 0
var lastHostTime: UInt64 = 0
let lock = NSLock()

var procID: AudioDeviceIOProcID? = nil
let st = AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, inData, inTime, outData, _ in
    if toneCh >= 0 {
        var ch = 0
        for b in UnsafeMutableAudioBufferListPointer(outData) {
            let n = Int(b.mNumberChannels)
            if let p = b.mData?.assumingMemoryBound(to: Float.self), toneCh >= ch, toneCh < ch + n {
                let frames = Int(b.mDataByteSize) / (4 * n)
                for f in 0..<frames {
                    p[f * n + (toneCh - ch)] = toneAmp * Float(sin(phase))
                    phase += 2 * Double.pi * 997 / 48000
                }
            }
            ch += n
        }
    }
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
    lock.lock()
    callbacks += 1
    lastHostTime = inTime.pointee.mHostTime
    var ch = 0
    for b in abl {
        let n = Int(b.mNumberChannels)
        guard let p = b.mData?.assumingMemoryBound(to: Float.self), n > 0 else { ch += n; continue }
        let frames = Int(b.mDataByteSize) / (4 * n)
        for f in 0..<frames {
            for c in 0..<n where ch + c < peaks.count {
                let v = abs(p[f * n + c])
                if v > peaks[ch + c] { peaks[ch + c] = v }
            }
        }
        ch += n
    }
    lock.unlock()
}

var started = false
if st == noErr, let pid = procID {
    started = AudioDeviceStart(dev, pid) == noErr
    Thread.sleep(forTimeInterval: seconds)
    AudioDeviceStop(dev, pid)
    AudioDeviceDestroyIOProcID(dev, pid)
}

func db(_ v: Float) -> Double { v > 0 ? (20 * log10(Double(v)) * 10).rounded() / 10 : -999 }

lock.lock()
let active = peaks.enumerated().filter { $0.element > 0 }.map { "\"\($0.offset + 1)\":\(db($0.element))" }
let out = """
{"found":true,"name":"\(cfString(dev, kAudioObjectPropertyName))","alive":\(prop(dev, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, UInt32(0))),\
"runningSomewhere":\(prop(dev, kAudioDevicePropertyDeviceIsRunningSomewhere, kAudioObjectPropertyScopeGlobal, UInt32(0))),\
"hogPID":\(prop(dev, kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal, pid_t(-1))),\
"sampleRate":\(prop(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0))),\
"inputs":\(nIn),"outputs":\(channelCount(dev, kAudioObjectPropertyScopeOutput)),\
"ioStarted":\(started),"callbacks":\(callbacks),"seconds":\(seconds),"activeInputsDb":{\(active.joined(separator: ","))}}
"""
lock.unlock()
print(out)
