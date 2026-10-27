// Core: paths, logging, config, AVB device discovery and 1722.1 control (ACMP / AECP).

import AudioVideoBridging
import CoreAudio
import CryptoKit
import Foundation
import IOKit

// MARK: - Paths & logging

let supportDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/AVBWatch")
let configURL = supportDir.appendingPathComponent("config.json")
let statusURL = supportDir.appendingPathComponent("status.json")
let tokenURL = supportDir.appendingPathComponent("admin.token")

/// A fresh random token on every start, readable only by this user. The menu-bar app sends it to act as admin.
func makeAdminToken() -> String {
    let t = (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined()
    FileManager.default.createFile(atPath: tokenURL.path, contents: Data(t.utf8), attributes: [.posixPermissions: 0o600])
    return t
}

let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/AVBWatch.log")

let tsFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
private let logLock = NSLock()

func log(_ s: String) {
    let line = "\(tsFormat.string(from: Date()))  \(s)\n"
    logLock.lock(); defer { logLock.unlock() }
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: logURL, atomically: true, encoding: .utf8)
    }
}

/// An alert for the menu-bar app to show. The manager only queues it; the app posts it as a macOS
/// notification, so alerts appear only while the app is running and clicking one opens the app.
struct Notice: Codable { var id: Int64; var title: String; var message: String }

private let noticeLock = NSLock()
private var notices: [Notice] = []

func notify(_ title: String, _ msg: String) {
    noticeLock.lock(); defer { noticeLock.unlock() }
    // ids are millisecond timestamps, so they keep increasing across manager restarts
    let id = max(Int64(Date().timeIntervalSince1970 * 1000), (notices.last?.id ?? 0) + 1)
    notices.append(Notice(id: id, title: title, message: msg))
    if notices.count > 20 { notices.removeFirst(notices.count - 20) }
}

func recentNotices() -> [Notice] {
    noticeLock.lock(); defer { noticeLock.unlock() }
    return notices
}

func hex(_ v: UInt64) -> String { String(format: "%016llx", v) }

// MARK: - Config

/// A locked route: listener sink `listenerUID` on `listener` must receive talker stream `talkerUID` from `talker`.
struct Connection: Codable, Hashable {
    var talker: String      // entity ID, hex
    var talkerUID: UInt16
    var listener: String
    var listenerUID: UInt16
    var label: String
    var talkerID: UInt64 { UInt64(talker, radix: 16)! }
    var listenerID: UInt64 { UInt64(listener, radix: 16)! }
    var key: String { "\(talker)[\(talkerUID)]->\(listener)[\(listenerUID)]" }
    /// A listener sink can only have one source, so locks are identified by the sink.
    var sinkKey: String { "\(listener)[\(listenerUID)]" }
}

struct Config: Codable {
    var interface = "en0"
    var pollSeconds: Double = 5
    var graceChecks = 2               // consecutive bad checks before healing a fault
    var maxBackoffSeconds: Double = 60
    var alertAfterFailedFixes = 4
    var checkCounters = true          // verify the receiver's frame counters are advancing
    var webPort: UInt16 = 8077
    var loopTestChannel = 30                            // channel for the recovery loop test (0 = off)
    var daw = "Pro Tools"                               // process to watch ("" = skip the engine check)
    var expectedAudioDevice = "Pro Tools Aggregate I/O" // device the DAW should be running on
    var adminSalt = ""
    var adminHash = ""
    var deviceNames: [String: String] = [:]   // entity ID (hex) -> name set by the admin
    var connections: [Connection] = []   // the locked routes

    init() {}

    // Decode field by field so older config files (missing newer keys) still load.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = Config()
        interface = try c.decodeIfPresent(String.self, forKey: .interface) ?? def.interface
        pollSeconds = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? def.pollSeconds
        graceChecks = try c.decodeIfPresent(Int.self, forKey: .graceChecks) ?? def.graceChecks
        maxBackoffSeconds = try c.decodeIfPresent(Double.self, forKey: .maxBackoffSeconds) ?? def.maxBackoffSeconds
        alertAfterFailedFixes = try c.decodeIfPresent(Int.self, forKey: .alertAfterFailedFixes) ?? def.alertAfterFailedFixes
        checkCounters = try c.decodeIfPresent(Bool.self, forKey: .checkCounters) ?? def.checkCounters
        webPort = try c.decodeIfPresent(UInt16.self, forKey: .webPort) ?? def.webPort
        loopTestChannel = try c.decodeIfPresent(Int.self, forKey: .loopTestChannel) ?? def.loopTestChannel
        daw = try c.decodeIfPresent(String.self, forKey: .daw) ?? def.daw
        expectedAudioDevice = try c.decodeIfPresent(String.self, forKey: .expectedAudioDevice) ?? def.expectedAudioDevice
        adminSalt = try c.decodeIfPresent(String.self, forKey: .adminSalt) ?? ""
        adminHash = try c.decodeIfPresent(String.self, forKey: .adminHash) ?? ""
        deviceNames = try c.decodeIfPresent([String: String].self, forKey: .deviceNames) ?? [:]
        connections = try c.decodeIfPresent([Connection].self, forKey: .connections) ?? []
    }

    func passwordMatches(_ pw: String) -> Bool {
        !adminHash.isEmpty && Config.hash(pw, salt: adminSalt) == adminHash
    }

    static func hash(_ pw: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + pw).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

func loadConfig() -> Config? {
    guard let d = try? Data(contentsOf: configURL) else { return nil }
    return try? JSONDecoder().decode(Config.self, from: d)
}

func saveConfig(_ c: Config) {
    let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
    try? e.encode(c).write(to: configURL)
}

// MARK: - IORegistry (entities, link)

struct Entity { var id: UInt64; var mac: [UInt8]; var sinks: Int; var sources: Int; var gm: UInt64; var local: Bool
    var macString: String { mac.map { String(format: "%02x", $0) }.joined(separator: ":") }
}

func entities() -> [Entity] {
    var out: [Entity] = []
    for (cls, local) in [("IOAVB17221LocalEntity", true), ("IOAVB17221RemoteEntity", false)] {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &it) == KERN_SUCCESS else { continue }
        while case let svc = IOIteratorNext(it), svc != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let d = props?.takeRetainedValue() as? [String: Any] {
                let mac = ((d["MACAddresses"] as? [Data])?.first).map { [UInt8]($0) } ?? []
                out.append(Entity(id: (d["EntityID"] as? NSNumber)?.uint64Value ?? 0, mac: mac,
                                  sinks: (d["ListenerStreamSinks"] as? Int) ?? 0, sources: (d["TalkerStreamSources"] as? Int) ?? 0,
                                  gm: (d["gPTPGrandmasterID"] as? NSNumber)?.uint64Value ?? 0, local: local))
            }
            IOObjectRelease(svc)
        }
        IOObjectRelease(it)
    }
    return out
}

func linkUp(_ ifname: String) -> Bool {
    // SIOCGIFMEDIA: is there an active Ethernet link?
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var req = [UInt8](repeating: 0, count: 44)          // struct ifmediareq (packed, 44 bytes)
    let name = Array(ifname.utf8.prefix(15))
    req.replaceSubrange(0..<name.count, with: name)
    let SIOCGIFMEDIA: UInt = 0xC02C6938
    let rc = req.withUnsafeMutableBytes { ioctl(fd, SIOCGIFMEDIA, $0.baseAddress!) }
    guard rc == 0 else { return false }
    let status = req.withUnsafeBytes { $0.load(fromByteOffset: 24, as: Int32.self) }  // ifm_status
    return status & 0x3 == 0x3                          // IFM_AVALID | IFM_ACTIVE
}

// MARK: - 1722.1 control (ACMP / AECP)

final class AVBControl {
    let acmp: AVB17221ACMPInterface
    let aecp: AVB17221AECPInterface?
    let controller = AVBInterface.myEntityID()

    init(_ ifname: String) {
        acmp = AVB17221ACMPInterface(interfaceNamed: ifname)
        aecp = AVB17221AECPInterface(interfaceNamed: ifname)
    }

    struct RX { var status: UInt8; var talker: UInt64; var talkerUID: UInt16; var stream: UInt64; var count: UInt16 }

    private func acmpCommand(_ type: AVB17221ACMPMessageType, talker: UInt64 = 0, tuid: UInt16 = 0,
                             listener: UInt64, luid: UInt16, timeout: Double = 2.0) -> (RX?, String?) {
        let m = AVB17221ACMPMessage()
        m.messageType = type
        m.controllerEntityID = controller
        m.listenerEntityID = listener
        m.listenerUniqueID = luid
        m.talkerEntityID = talker
        m.talkerUniqueID = tuid
        let sem = DispatchSemaphore(value: 0)
        var res: RX?; var err: String?
        acmp.sendACMPCommand(m) { e, r in
            if let r = r {
                res = RX(status: r.status.rawValue, talker: r.talkerEntityID, talkerUID: r.talkerUniqueID, stream: r.streamID, count: r.connectionCount)
            }
            if let e = e { err = e.localizedDescription }
            sem.signal()
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut { return (nil, "timeout") }
        return (res, err)
    }

    func rxState(listener: UInt64, uid: UInt16) -> (RX?, String?) {
        acmpCommand(.getRXStateCommand, listener: listener, luid: uid, timeout: 1.5)
    }

    /// Which stream ID a talker is sending right now.
    func txStream(talker: UInt64, uid: UInt16) -> UInt64? {
        let m = AVB17221ACMPMessage()
        m.messageType = .getTXStateCommand
        m.controllerEntityID = controller
        m.talkerEntityID = talker
        m.talkerUniqueID = uid
        let sem = DispatchSemaphore(value: 0)
        var sid: UInt64?
        acmp.sendACMPCommand(m) { _, r in
            if let r = r, r.status.rawValue == 0, r.streamID != 0 { sid = r.streamID }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 1.5)
        return sid
    }

    func connect(talker: UInt64, tuid: UInt16, listener: UInt64, luid: UInt16) -> (RX?, String?) {
        acmpCommand(.connectRXCommand, talker: talker, tuid: tuid, listener: listener, luid: luid, timeout: 5)
    }

    func disconnect(talker: UInt64, tuid: UInt16, listener: UInt64, luid: UInt16) -> (RX?, String?) {
        acmpCommand(.disconnectRXCommand, talker: talker, tuid: tuid, listener: listener, luid: luid, timeout: 5)
    }

    func connect(_ c: Connection) -> (RX?, String?) {
        connect(talker: c.talkerID, tuid: c.talkerUID, listener: c.listenerID, luid: c.listenerUID)
    }

    func disconnect(_ c: Connection) -> (RX?, String?) {
        disconnect(talker: c.talkerID, tuid: c.talkerUID, listener: c.listenerID, luid: c.listenerUID)
    }

    private func aem(_ entity: Entity, _ cmd: AVB17221AEMCommandType, _ payload: Data, timeout: Double = 1.5) -> [UInt8]? {
        guard let aecp = aecp, entity.mac.count == 6 else { return nil }
        let m = AVB17221AECPAEMMessage.command()
        m.commandType = cmd
        m.targetEntityID = entity.id
        m.controllerEntityID = controller
        m.commandSpecificData = payload
        let sem = DispatchSemaphore(value: 0)
        var out: [UInt8]?
        let sent = aecp.sendCommand(m, to: AVBMACAddress(bytes: entity.mac)) { _, r in
            if let r = r as? AVB17221AECPAEMMessage, r.status.rawValue == 0, let d = r.commandSpecificData { out = [UInt8](d) }
            sem.signal()
        }
        guard sent else { return nil }
        _ = sem.wait(timeout: .now() + timeout)
        return out
    }

    /// AEM GET_COUNTERS on a STREAM_INPUT descriptor. Returns (frames received, media locked?) when supported.
    func streamInputCounters(entity: Entity, index: UInt16) -> (frames: UInt32, locked: Bool)? {
        guard let b = aem(entity, .getCounters, Data([0x00, 0x05, UInt8(index >> 8), UInt8(index & 0xff)])), b.count >= 8 + 48 else { return nil }
        func u32(_ o: Int) -> UInt32 { UInt32(b[o]) << 24 | UInt32(b[o + 1]) << 16 | UInt32(b[o + 2]) << 8 | UInt32(b[o + 3]) }
        let valid = u32(4)
        guard valid & (1 << 11) != 0 else { return nil }
        let locked = u32(8), unlocked = u32(12), frames = u32(8 + 11 * 4)
        return (frames, valid & 3 == 3 ? locked > unlocked : true)
    }

    /// AEM READ_DESCRIPTOR: returns the 64-byte name field of a descriptor, if it has one.
    /// ENTITY (0): entity_name at descriptor offset 48. STREAM_INPUT (5) / STREAM_OUTPUT (6): object_name at offset 4.
    func descriptorName(entity: Entity, type: UInt16, index: UInt16) -> String? {
        let payload = Data([0, 0, 0, 0, UInt8(type >> 8), UInt8(type & 0xff), UInt8(index >> 8), UInt8(index & 0xff)])
        guard let b = aem(entity, .readDescriptor, payload) else { return nil }
        let off = 4 + (type == 0 ? 48 : 4)   // response starts with configuration_index + reserved
        guard b.count >= off + 64 else { return nil }
        let raw = b[off..<(off + 64)].prefix { $0 != 0 }
        let s = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}

// MARK: - CoreAudio: is a given audio device in use?

private func caString(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var s: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &s) == noErr else { return nil }
    return s?.takeRetainedValue() as String?
}

private func caU32(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0; var sz = UInt32(4); AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v); return v
}

private func caIDs(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> [AudioObjectID] {
    var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var sz: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == noErr else { return [] }
    var v = [AudioObjectID](repeating: 0, count: Int(sz) / 4)
    AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v)
    return v
}

struct AudioDeviceHealth {
    var exists = false
    var uid = ""
    var running = false          // the device itself reports running
    var membersRunning = false   // aggregate: every member present and running
    var missingMembers: [String] = []
}

/// State of the audio device with this name. For aggregates, also checks every member device.
func audioDeviceHealth(named name: String) -> AudioDeviceHealth {
    var h = AudioDeviceHealth()
    for id in caIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) where caString(id, kAudioObjectPropertyName) == name {
        h.exists = true
        h.uid = caString(id, kAudioDevicePropertyDeviceUID) ?? ""
        h.running = caU32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0
        guard caU32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeAggregate else { h.membersRunning = h.running; break }
        var a = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyFullSubDeviceList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var list: Unmanaged<CFArray>?; var sz = UInt32(MemoryLayout<Unmanaged<CFArray>?>.size)
        let configured = AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &list) == noErr ? (list?.takeRetainedValue() as? [String] ?? []) : []
        let active = caIDs(id, kAudioAggregateDevicePropertyActiveSubDeviceList)
        let activeUIDs = Dictionary(active.map { (caString($0, kAudioDevicePropertyDeviceUID) ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        h.missingMembers = configured.filter { activeUIDs[$0] == nil }
        h.membersRunning = !active.isEmpty && h.missingMembers.isEmpty && active.allSatisfy { caU32($0, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0 }
        break
    }
    return h
}

/// True when Pro Tools' saved playback-engine choice names this device UID.
func proToolsEngineIs(uid: String) -> Bool {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/Avid/Pro Tools/DSIPrefs")
    guard !uid.isEmpty, let d = try? Data(contentsOf: url) else { return false }
    return d.range(of: Data(uid.utf8)) != nil
}

func processRunning(_ name: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", name]
    p.standardOutput = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}
