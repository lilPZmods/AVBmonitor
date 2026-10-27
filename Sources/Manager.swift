// Manager: owns the watcher, builds the live routing picture of every AVB device,
// handles lock / unlock / patch requests, and reverts changes to locked routes.

import Foundation

struct StreamInfo: Codable { var uid: UInt16; var name: String }

struct SinkInfo: Codable {
    var uid: UInt16
    var name: String
    var talker: String?        // current source entity (hex), nil if not connected
    var talkerUID: UInt16?
    var locked: Bool
    var lockTalker: String?
    var lockTalkerUID: UInt16?
    var state: String          // "ok", "unlocked", or the problem text for a locked route
    var ok: Bool
}

struct DeviceInfo: Codable {
    var id: String
    var name: String
    var mac: String
    var local: Bool
    var sources: [StreamInfo]
    var sinks: [SinkInfo]
}

struct EventInfo: Codable { var time: String; var kind: String; var text: String }

struct StateInfo: Codable {
    var time: String
    var link: Bool
    var healthy: Bool
    var adminConfigured: Bool
    var sniffing: Bool
    var engineWarning: String?
    var recovery: RecoveryInfo
    var devices: [DeviceInfo]
    var events: [EventInfo]
    var notices: [Notice] = []
}

struct APIError: Error { var status: Int; var message: String }

final class Manager {
    let watcher: Watcher
    let queue = DispatchQueue(label: "avb")          // every AVB operation runs here, one at a time
    private let stateLock = NSLock()
    private var snapshot: StateInfo?
    private var events: [EventInfo] = []
    private var names: [UInt64: (name: String, sources: [String], sinks: [String])] = [:]
    let wake = DispatchSemaphore(value: 0)
    var sniffing = false
    var recoveryState = RecoveryInfo()
    var deadCycles = 0
    private var engineBadSince: Date?
    private var engineAlerted = false

    var cfg: Config { watcher.cfg }
    var ctl: AVBControl { watcher.ctl }

    init(_ cfg: Config) {
        watcher = Watcher(cfg)
        watcher.describe = { [unowned self] in self.describe($0) }
    }

    // MARK: events

    func event(_ kind: String, _ text: String, logIt: Bool = true) {
        if logIt { log(text) }
        stateLock.lock()
        events.insert(EventInfo(time: tsFormat.string(from: Date()), kind: kind, text: text), at: 0)
        if events.count > 300 { events.removeLast(events.count - 300) }
        stateLock.unlock()
    }

    // MARK: names

    func deviceName(_ id: UInt64) -> String {
        if let n = cfg.deviceNames[hex(id)], !n.isEmpty { return n }
        if let n = names[id]?.name { return n }
        return "device \(hex(id).suffix(6))"
    }

    func sourceName(_ id: UInt64, _ uid: UInt16) -> String {
        if let s = names[id]?.sources, Int(uid) < s.count { return s[Int(uid)] }
        return "out \(uid + 1)"
    }

    func sinkName(_ id: UInt64, _ uid: UInt16) -> String {
        if let s = names[id]?.sinks, Int(uid) < s.count { return s[Int(uid)] }
        return "in \(uid + 1)"
    }

    func describe(_ c: Connection) -> String {
        if names.isEmpty && cfg.deviceNames.isEmpty && !c.label.isEmpty { return c.label }   // CLI: names not loaded
        return "\(deviceName(c.talkerID)) / \(sourceName(c.talkerID, c.talkerUID)) -> \(deviceName(c.listenerID)) / \(sinkName(c.listenerID, c.listenerUID))"
    }

    /// Which device a controller entity ID belongs to (controller IDs are normally derived from a MAC address).
    func whoName(_ controller: UInt64) -> String {
        if controller == ctl.controller { return "this iMac" }
        for e in entities() where e.mac.count == 6 {
            let m = e.mac.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            let eui = (m >> 24) << 40 | 0xFFFE << 24 | (m & 0xFFFFFF)
            if controller == e.id || controller >> 16 == m || controller == eui { return "\(deviceName(e.id)) (\(e.macString))" }
        }
        let m = controller >> 16
        let mac = (0..<6).map { String(format: "%02x", (m >> (8 * (5 - $0))) & 0xff) }.joined(separator: ":")
        return "controller \(hex(controller)) (probably \(mac))"
    }

    private func loadNames(_ e: Entity) {
        if names[e.id] != nil { return }
        let published = ctl.descriptorName(entity: e, type: 0, index: 0)
        var name = published ?? (e.local ? Host.current().localizedName ?? "This Mac" : "device \(hex(e.id).suffix(6))")
        if e.local && !name.contains("(this") { name += " (this Mac)" }
        // devices that don't answer the name request (e.g. Macs) won't name their streams either - don't wait on them
        let src = (0..<e.sources).map { published == nil ? "out \($0 + 1)" : ctl.descriptorName(entity: e, type: 6, index: UInt16($0)) ?? "out \($0 + 1)" }
        let snk = (0..<e.sinks).map { published == nil ? "in \($0 + 1)" : ctl.descriptorName(entity: e, type: 5, index: UInt16($0)) ?? "in \($0 + 1)" }
        names[e.id] = (name, src, snk)
    }

    // MARK: snapshot

    private func refresh(link: Bool) {
        let ents = entities().sorted { ($0.local ? 0 : 1, $0.id) < ($1.local ? 0 : 1, $1.id) }
        var devices: [DeviceInfo] = []
        let locks = Dictionary(cfg.connections.map { ($0.sinkKey, $0) }, uniquingKeysWith: { a, _ in a })
        for e in ents {
            loadNames(e)
            var sinks: [SinkInfo] = []
            for u in 0..<e.sinks {
                let uid = UInt16(u)
                let r = link ? ctl.rxState(listener: e.id, uid: uid).0 : nil
                let connected = r.map { $0.status == 0 && $0.count > 0 && $0.talker != 0 } ?? false
                let key = "\(hex(e.id))[\(uid)]"
                let lock = locks[key]
                let p = watcher.lastResult[key]
                sinks.append(SinkInfo(uid: uid, name: sinkName(e.id, uid),
                                      talker: connected ? hex(r!.talker) : nil, talkerUID: connected ? r!.talkerUID : nil,
                                      locked: lock != nil, lockTalker: lock?.talker, lockTalkerUID: lock?.talkerUID,
                                      state: lock == nil ? "unlocked" : (p?.text ?? "checking"),
                                      ok: lock == nil || p == .ok))
            }
            devices.append(DeviceInfo(id: hex(e.id), name: deviceName(e.id), mac: e.macString, local: e.local,
                                      sources: (0..<e.sources).map { StreamInfo(uid: UInt16($0), name: sourceName(e.id, UInt16($0))) },
                                      sinks: sinks))
        }
        stateLock.lock()
        snapshot = StateInfo(time: tsFormat.string(from: Date()), link: link,
                             healthy: link && cfg.connections.allSatisfy { watcher.lastResult[$0.sinkKey] == .ok },
                             adminConfigured: !cfg.adminHash.isEmpty, sniffing: sniffing,
                             engineWarning: engineWarning(), recovery: recoveryState, devices: devices, events: events)
        stateLock.unlock()
    }

    /// Push recovery changes to the published state right away (the app shows progress live).
    func publishRecovery() {
        stateLock.lock(); snapshot?.recovery = recoveryState; stateLock.unlock()
    }

    func state() -> StateInfo? {
        stateLock.lock(); defer { stateLock.unlock() }
        guard var s = snapshot else { return nil }
        s.events = events
        s.notices = recentNotices()
        return s
    }

    // MARK: DAW engine check (e.g. Pro Tools left on the bare AVB device instead of the aggregate)

    private var engineMessage: String?
    private func engineWarning() -> String? { engineMessage }

    private func checkEngine() {
        guard !cfg.daw.isEmpty, !cfg.expectedAudioDevice.isEmpty, processRunning(cfg.daw) else {
            engineBadSince = nil; engineMessage = nil; engineAlerted = false; return
        }
        let h = audioDeviceHealth(named: cfg.expectedAudioDevice)
        // Pro Tools drives an aggregate's member devices directly, so "selected + every member running" counts as in use
        let inUse = h.running || (proToolsEngineIs(uid: h.uid) && h.membersRunning)
        if inUse {
            if engineMessage != nil { event("ok", "\(cfg.daw) is running on \(cfg.expectedAudioDevice) again") }
            engineBadSince = nil; engineMessage = nil; engineAlerted = false; return
        }
        let msg: String
        if !h.exists { msg = "\(cfg.expectedAudioDevice) is missing." }
        else if !h.missingMembers.isEmpty { msg = "\(cfg.expectedAudioDevice) has lost a device (\(h.missingMembers.joined(separator: ", "))). Restart \(cfg.daw) once it is back." }
        else if !proToolsEngineIs(uid: h.uid) { msg = "\(cfg.daw) is not using \(cfg.expectedAudioDevice). Check Setup > Playback Engine." }
        else { msg = "\(cfg.daw) is set to \(cfg.expectedAudioDevice) but its devices are not running. Restart \(cfg.daw)." }
        if engineBadSince == nil { engineBadSince = Date() }
        engineMessage = msg
        // allow 20 s for the DAW to start its engine before alerting
        if !engineAlerted, Date().timeIntervalSince(engineBadSince!) > 20 {
            engineAlerted = true
            event("problem", "ENGINE: " + msg)
            notify("\(cfg.daw) audio engine", msg)
        }
    }

    // MARK: main loop

    func tick() {
        queue.sync {
            autoreleasepool {
                let link = linkUp(cfg.interface)
                if !cfg.connections.isEmpty || !link { watcher.cycle(fix: true) }
                checkEngine()
                if link { checkEngineDead() }
                refresh(link: link)
            }
        }
    }

    func run() -> Never {
        let sniffer = Sniffer(cfg.interface)
        sniffer.onEvent = { [weak self] e in self?.queue.async { self?.handle(e) } }
        sniffing = sniffer.start()
        event("info", "manager started - \(cfg.connections.count) locked routes, web page on port \(cfg.webPort)")
        while true {
            tick()
            _ = wake.wait(timeout: .now() + cfg.pollSeconds)
        }
    }

    /// A connect/disconnect happened somewhere on the network.
    private func handle(_ e: ACMPEvent) {
        let ours = e.controller == ctl.controller && watcher.isSelfAction(e.sinkKey)
        if ours { return }
        let who = whoName(e.controller)
        let what = e.connect
            ? "connected \(deviceName(e.talker)) / \(sourceName(e.talker, e.talkerUID)) -> \(deviceName(e.listener)) / \(sinkName(e.listener, e.listenerUID))"
            : "disconnected \(deviceName(e.listener)) / \(sinkName(e.listener, e.listenerUID))"
        if let lock = cfg.connections.first(where: { $0.sinkKey == e.sinkKey }) {
            let sameAsLock = e.connect && e.talker == lock.talkerID && e.talkerUID == lock.talkerUID
            if sameAsLock { event("info", "\(who) \(what) (matches lock)"); return }
            event("revert", "LOCKED ROUTE CHANGED by \(who): \(what) - restoring \(describe(lock))")
            watcher.forceNow.insert(lock.sinkKey)
            wake.signal()
        } else {
            event("info", "\(who) \(what)")
        }
    }

    // MARK: API operations (call on `queue`)

    private func persist() { saveConfig(watcher.cfg) }

    func lock(listener: UInt64, luid: UInt16, talker: UInt64?, tuid: UInt16?) throws -> String {
        var t = talker, tu = tuid
        if t == nil {
            guard let r = ctl.rxState(listener: listener, uid: luid).0, r.status == 0, r.count > 0, r.talker != 0 else {
                throw APIError(status: 409, message: "That input has no source to lock. Pick a source first.")
            }
            t = r.talker; tu = r.talkerUID
        }
        let c = Connection(talker: hex(t!), talkerUID: tu!, listener: hex(listener), listenerUID: luid, label: "")
        watcher.cfg.connections.removeAll { $0.sinkKey == c.sinkKey }
        var labeled = c; labeled.label = describe(c)
        watcher.cfg.connections.append(labeled)
        persist()
        watcher.forceNow.insert(c.sinkKey)   // connect it now if it isn't already
        event("lock", "LOCKED by admin: \(describe(c))")
        wake.signal()
        return describe(c)
    }

    func unlock(listener: UInt64, luid: UInt16) throws {
        let key = "\(hex(listener))[\(luid)]"
        guard let c = watcher.cfg.connections.first(where: { $0.sinkKey == key }) else { throw APIError(status: 404, message: "Not locked") }
        watcher.cfg.connections.removeAll { $0.sinkKey == key }
        watcher.lastResult[key] = nil
        persist()
        event("lock", "UNLOCKED by admin: \(describe(c))")
    }

    func rename(id: UInt64, name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = deviceName(id)
        if n.isEmpty { watcher.cfg.deviceNames[hex(id)] = nil } else { watcher.cfg.deviceNames[hex(id)] = String(n.prefix(60)) }
        for i in watcher.cfg.connections.indices { watcher.cfg.connections[i].label = describe(watcher.cfg.connections[i]) }
        persist()
        event("lock", "renamed \(old) to \(deviceName(id))")
    }

    func lockAll() -> Int {
        var n = 0
        for e in entities() {
            for u in 0..<e.sinks {
                if let r = ctl.rxState(listener: e.id, uid: UInt16(u)).0, r.status == 0, r.count > 0, r.talker != 0 {
                    let c = Connection(talker: hex(r.talker), talkerUID: r.talkerUID, listener: hex(e.id), listenerUID: UInt16(u), label: "")
                    watcher.cfg.connections.removeAll { $0.sinkKey == c.sinkKey }
                    var l = c; l.label = describe(c)
                    watcher.cfg.connections.append(l); n += 1
                }
            }
        }
        persist()
        event("lock", "LOCKED ALL current routes by admin (\(n))")
        return n
    }

    /// Patch (or clear, when talker is nil) one listener input. Locked inputs need the admin password.
    func patch(listener: UInt64, luid: UInt16, talker: UInt64?, tuid: UInt16?, admin: Bool) throws -> String {
        let key = "\(hex(listener))[\(luid)]"
        let locked = cfg.connections.contains { $0.sinkKey == key }
        if locked && !admin { throw APIError(status: 403, message: "This input is locked by the admin.") }
        if !admin, let me = entities().first(where: { $0.local }), listener == me.id || talker == me.id {
            throw APIError(status: 403, message: "Only the admin can patch this Mac's own AVB streams (changing them can stop its audio engine).")
        }
        watcher.markSelfAction(key)
        let cur = ctl.rxState(listener: listener, uid: luid).0
        if let cur = cur, cur.count > 0, cur.talker != 0, cur.talker != talker || cur.talkerUID != tuid {
            _ = ctl.disconnect(talker: cur.talker, tuid: cur.talkerUID, listener: listener, luid: luid)
            Thread.sleep(forTimeInterval: 0.3)
        }
        var result = "cleared \(deviceName(listener)) / \(sinkName(listener, luid))"
        if let t = talker, let tu = tuid {
            let (r, e) = ctl.connect(talker: t, tuid: tu, listener: listener, luid: luid)
            guard r?.status == 0, e == nil else {
                throw APIError(status: 502, message: "Device refused the connection (\(e ?? "status \(r?.status ?? 255)"))")
            }
            result = "patched \(deviceName(t)) / \(sourceName(t, tu)) -> \(deviceName(listener)) / \(sinkName(listener, luid))"
        }
        if locked {
            // admin re-patched a locked input: the lock follows the new source (or is removed when cleared)
            watcher.cfg.connections.removeAll { $0.sinkKey == key }
            if let t = talker, let tu = tuid {
                var c = Connection(talker: hex(t), talkerUID: tu, listener: hex(listener), listenerUID: luid, label: "")
                c.label = describe(c)
                watcher.cfg.connections.append(c)
            }
            persist()
        }
        event("patch", "\(admin ? "admin" : "web user") \(result)")
        wake.signal()
        return result
    }
}
