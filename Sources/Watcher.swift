// Watcher: checks every locked route and heals it. All calls happen on the manager's AVB queue.

import Foundation

enum Problem: Equatable {
    case ok
    case noResponse(String)
    case notConnected
    case wrongTalker(String)
    case stalled
    case unlocked
    case staleStream(String)

    var text: String {
        switch self {
        case .ok: return "ok"
        case .noResponse(let e): return "device not answering (\(e))"
        case .notConnected: return "not connected"
        case .wrongTalker(let t): return "connected to a different source (\(t))"
        case .stalled: return "connected but no packets arriving"
        case .unlocked: return "connected but media clock unlocked"
        case .staleStream(let s): return "listening to an old stream (\(s)) - sender restarted with a new one"
        }
    }
}

final class Watcher {
    var cfg: Config
    let ctl: AVBControl
    var badStreak: [String: Int] = [:]
    var lastFrames: [String: UInt32] = [:]
    var failedFixes: [String: Int] = [:]
    var nextAttempt: [String: Date] = [:]
    var alerted: Set<String> = []
    var lastResult: [String: Problem] = [:]   // by sinkKey
    var suppressRepairForTalker: UInt64?       // set while this Mac's engine is dead: reconnecting can't help
    var forceNow: Set<String> = []            // sinkKeys to heal immediately (someone changed a locked route)
    var selfActionUntil: [String: Date] = [:] // sinkKeys the manager itself is changing right now
    var wasHealthy = true
    var linkWasUp = true
    var describe: (Connection) -> String = { $0.label }

    init(_ cfg: Config) { self.cfg = cfg; ctl = AVBControl(cfg.interface) }

    func markSelfAction(_ sinkKey: String) { selfActionUntil[sinkKey] = Date().addingTimeInterval(8) }
    func isSelfAction(_ sinkKey: String) -> Bool { (selfActionUntil[sinkKey] ?? .distantPast) > Date() }

    func check(_ c: Connection, ents: [Entity]) -> Problem {
        let (rx, err) = ctl.rxState(listener: c.listenerID, uid: c.listenerUID)
        guard let r = rx else { return .noResponse(err ?? "?") }
        if r.status != 0 { return .noResponse("status \(r.status)") }
        if r.count == 0 || r.talker == 0 { return .notConnected }
        if r.talker != c.talkerID || r.talkerUID != c.talkerUID { return .wrongTalker("\(hex(r.talker))[\(r.talkerUID)]") }
        // Most common fault: the sender restarted its stream with a new ID and the receiver is
        // still subscribed to the old one. Everything says "connected" but no audio passes.
        if let tx = ctl.txStream(talker: c.talkerID, uid: c.talkerUID), r.stream != tx {
            return .staleStream(hex(r.stream))
        }
        if cfg.checkCounters, let ent = ents.first(where: { $0.id == c.listenerID }),
           var cnt = ctl.streamInputCounters(entity: ent, index: c.listenerUID) {
            if lastFrames[c.key] == nil {
                // no earlier sample: take a second one so we can tell right now whether packets are flowing
                lastFrames[c.key] = cnt.frames
                Thread.sleep(forTimeInterval: 0.25)
                if let again = ctl.streamInputCounters(entity: ent, index: c.listenerUID) { cnt = again }
            }
            defer { lastFrames[c.key] = cnt.frames }
            if let prev = lastFrames[c.key], cnt.frames == prev { return .stalled }
            // macOS's own entity never reports media-locked, so only trust that flag from other devices
            if !ent.local && !cnt.locked { return .unlocked }
        }
        return .ok
    }

    @discardableResult
    func repair(_ c: Connection, _ p: Problem) -> Bool {
        log("  REPAIR \(describe(c)): \(p.text)")
        markSelfAction(c.sinkKey)
        switch p {
        case .wrongTalker:
            // the sink is connected to someone else: disconnect that, then connect the locked source
            if let r = ctl.rxState(listener: c.listenerID, uid: c.listenerUID).0, r.talker != 0 {
                _ = ctl.disconnect(talker: r.talker, tuid: r.talkerUID, listener: c.listenerID, luid: c.listenerUID)
            }
            Thread.sleep(forTimeInterval: 0.5)
        case .stalled, .unlocked, .staleStream:
            _ = ctl.disconnect(c); Thread.sleep(forTimeInterval: 0.5)
        default: break
        }
        let (r, e) = ctl.connect(c)
        let ok = r?.status == 0 && e == nil
        log("  connect \(describe(c)): \(ok ? "accepted" : "failed: \(e ?? "status \(r?.status ?? 255)")")")
        lastFrames[c.key] = nil
        return ok
    }

    /// One pass over all locked routes. Returns the problems found (after repair attempts).
    @discardableResult
    func cycle(fix: Bool, immediate: Bool = false) -> [(Connection, Problem)] {
        if !linkUp(cfg.interface) {
            if linkWasUp { log("LINK DOWN on \(cfg.interface) - check the cable / switch"); notify("AVB link down", "\(cfg.interface) has no Ethernet link") }
            linkWasUp = false; wasHealthy = false
            writeStatus(link: false, results: [])
            return []
        }
        if !linkWasUp { log("link up on \(cfg.interface)") }
        linkWasUp = true

        let ents = entities()
        var results: [(Connection, Problem)] = []
        for c in cfg.connections {
            var p = check(c, ents: ents)
            let forced = forceNow.remove(c.sinkKey) != nil
            if p == .ok {
                if (badStreak[c.key] ?? 0) > 0 || (failedFixes[c.key] ?? 0) > 0 { log("OK again: \(describe(c))") }
                badStreak[c.key] = 0; failedFixes[c.key] = 0; nextAttempt[c.key] = nil; alerted.remove(c.key)
            } else {
                let streak = (badStreak[c.key] ?? 0) + 1
                badStreak[c.key] = streak
                if streak == 1 { log("PROBLEM \(describe(c)): \(p.text)") }
                let due = (forced || Date() >= (nextAttempt[c.key] ?? .distantPast)) && c.talkerID != suppressRepairForTalker
                if fix && (immediate || forced || streak >= cfg.graceChecks) && due {
                    let n = (failedFixes[c.key] ?? 0) + 1
                    failedFixes[c.key] = n
                    repair(c, p)
                    Thread.sleep(forTimeInterval: 2.0)
                    let after = check(c, ents: ents)   // full re-test: source, stream ID, packets flowing
                    if after == .ok {
                        log("  verified \(describe(c)): packets flowing")
                        p = .ok
                    } else {
                        p = after
                        let backoff = min(cfg.pollSeconds * pow(2, Double(n)), cfg.maxBackoffSeconds)
                        nextAttempt[c.key] = Date().addingTimeInterval(backoff)
                        if n >= cfg.alertAfterFailedFixes && !alerted.contains(c.key) {
                            alerted.insert(c.key)
                            notify("AVB repair not working", "\(describe(c)): \(after.text). Try power-cycling the AVB switch or device.")
                            log("ALERT \(describe(c)): \(n) repair attempts failed")
                        }
                    }
                }
            }
            lastResult[c.sinkKey] = p
            results.append((c, p))
        }
        let healthy = results.allSatisfy { $0.1 == .ok }
        let confirmedBad = results.contains { (badStreak[$0.0.key] ?? 0) >= cfg.graceChecks }
        if healthy != wasHealthy {
            if healthy { log("ALL LOCKED ROUTES HEALTHY"); notify("AVB restored", "All \(results.count) locked routes connected") }
            else if confirmedBad {
                notify("AVB problem", results.filter { $0.1 != .ok }.map { "\(describe($0.0)): \($0.1.text)" }.joined(separator: "; "))
            }
        }
        if healthy || confirmedBad { wasHealthy = healthy }
        writeStatus(link: true, results: results)
        return results
    }

    func writeStatus(link: Bool, results: [(Connection, Problem)]) {
        let d: [String: Any] = [
            "time": tsFormat.string(from: Date()), "link": link,
            "healthy": link && results.allSatisfy { $0.1 == .ok },
            "connections": results.map { ["label": describe($0.0), "state": $0.1.text] }
        ]
        if let data = try? JSONSerialization.data(withJSONObject: d, options: [.prettyPrinted]) { try? data.write(to: statusURL) }
    }
}
