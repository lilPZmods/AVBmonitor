// Recovery: when this Mac's AVB audio engine stops sending (reconnecting can't fix that), the manager
// proposes a recovery and waits for the admin to approve it.
//
// RULE: the audio engine is never restarted while the DAW (Pro Tools) is open. The user must quit it
// themselves; the manager never quits it. Approval is refused while it runs, and it is checked again
// immediately before the restart.
//
// Steps once approved:
//   1. confirm Pro Tools is closed
//   2. restart the macOS audio engine (coreaudiod)        (needs the sudoers rule from setup-recovery.sh)
//   3. wait for the AVB device to come back
//   4. reconnect every locked route to/from this Mac and verify packets are flowing
//   5. loop test: tone out on a channel, check it comes back (optional)
//   6. reopen the session that was open when the problem was found (optional)

import Foundation

struct RecoveryStep: Codable { var name: String; var status: String; var detail: String }  // pending/running/ok/failed/skipped

struct RecoveryInfo: Codable {
    var pending = false            // waiting for admin approval
    var running = false
    var reason = ""
    var proposedAt = ""
    var steps: [RecoveryStep] = []
    var finishedAt = ""
    var ok: Bool?
    var dawName = ""
    var dawRunning = false         // while true, approval is refused
    var sessionName = ""           // session to reopen afterwards (noted while the DAW was still open)
    var sessionPath = ""
    var sessionCheckedAt: Double = 0
    var loopChannel = 0
    var helperInstalled = false
}

struct RecoveryOptions { var reopenDAW: Bool; var loopChannel: Int }

@discardableResult
func runProcess(_ path: String, _ args: [String], timeout: Double = 30) -> (status: Int32, out: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
    if p.isRunning { p.terminate(); return (-2, "timed out") }
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
}

let venvPython = supportDir.appendingPathComponent("venv/bin/python").path
let ptHelper = supportDir.appendingPathComponent("pthelper.py").path
let probeTool = supportDir.appendingPathComponent("avbprobe").path

/// The sudoers rule lets this user restart coreaudiod without a password, and nothing else.
func recoveryHelperInstalled() -> Bool {
    runProcess("/usr/bin/sudo", ["-n", "-l", "/usr/bin/killall", "coreaudiod"], timeout: 5).status == 0
}

func proToolsInfo() -> (path: String, name: String)? {
    let r = runProcess(venvPython, [ptHelper, "info"], timeout: 20)
    guard r.status == 0, let d = r.out.split(separator: "\n").last?.data(using: .utf8),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let path = j["path"] as? String, !path.isEmpty else { return nil }
    return (path, j["name"] as? String ?? "")
}

extension Manager {

    var dawOpen: Bool { !cfg.daw.isEmpty && processRunning(cfg.daw) }

    // MARK: detection (called on `queue` after each watcher cycle)

    func checkEngineDead() {
        if recoveryState.pending { updateRecoveryDAW() }
        guard let me = entities().first(where: { $0.local }) else { return }
        let mine = cfg.connections.filter { $0.talkerID == me.id }
        guard !mine.isEmpty else { return }
        let silent = mine.allSatisfy { c in
            let p = watcher.lastResult[c.sinkKey]
            return p == .stalled || p == .unlocked
        }
        if silent {
            deadCycles += 1
            if watcher.suppressRepairForTalker == nil {
                watcher.suppressRepairForTalker = me.id     // reconnecting can't fix a dead engine; stop hammering it
                event("problem", "This Mac has stopped sending AVB audio on all \(mine.count) locked streams - holding off on reconnects")
            }
            if deadCycles >= 2 && !recoveryState.pending && !recoveryState.running {
                propose(reason: "This Mac's AVB audio engine stopped sending: the receivers get no packets on any of its \(mine.count) streams. Reconnecting can't fix this; the audio engine has to be restarted.")
            }
        } else if deadCycles > 0 || watcher.suppressRepairForTalker != nil {
            deadCycles = 0
            watcher.suppressRepairForTalker = nil
            if recoveryState.pending {
                recoveryState.pending = false
                publishRecovery()
                event("ok", "This Mac is sending audio again - recovery request withdrawn")
            }
        }
    }

    /// Track whether the DAW is open while a recovery waits, and note its session so it can be reopened later.
    func updateRecoveryDAW() {
        let open = dawOpen
        let now = Date().timeIntervalSince1970
        if open && cfg.daw == "Pro Tools" && (recoveryState.sessionPath.isEmpty || now - recoveryState.sessionCheckedAt > 30) {
            recoveryState.sessionCheckedAt = now
            if let info = proToolsInfo() {
                recoveryState.sessionPath = info.path
                recoveryState.sessionName = info.name
            }
        }
        if open != recoveryState.dawRunning {
            recoveryState.dawRunning = open
            if !open && recoveryState.pending { event("info", "\(cfg.daw) closed - recovery can be approved") }
        }
        publishRecovery()
    }

    // MARK: proposal / approval

    func propose(reason: String) {
        var r = RecoveryInfo()
        r.pending = true
        r.reason = reason
        r.proposedAt = tsFormat.string(from: Date())
        r.loopChannel = cfg.loopTestChannel
        r.dawName = cfg.daw
        r.helperInstalled = recoveryHelperInstalled()
        recoveryState = r
        updateRecoveryDAW()
        let ask = recoveryState.dawRunning ? " Quit \(cfg.daw) first, then approve." : ""
        event("problem", "RECOVERY NEEDS ADMIN APPROVAL: \(reason)\(ask)")
        notify("AVB recovery needs approval", "\(reason)\(ask)")
    }

    func dismissRecovery() {
        guard recoveryState.pending else { return }
        recoveryState.pending = false
        publishRecovery()
        event("info", "Recovery request dismissed by admin")
    }

    func approveRecovery(_ o: RecoveryOptions) throws {
        guard !recoveryState.running else { throw APIError(status: 409, message: "Recovery is already running.") }
        if !recoveryState.pending { propose(reason: "Recovery started manually by the admin.") }
        // RULE: the user has to quit the DAW themselves before the audio engine can be restarted
        updateRecoveryDAW()
        if recoveryState.dawRunning {
            throw APIError(status: 409, message: "Quit \(cfg.daw) first. The audio engine can't be restarted while it's open.")
        }
        recoveryState.helperInstalled = recoveryHelperInstalled()
        recoveryState.pending = false
        recoveryState.running = true
        recoveryState.ok = nil
        recoveryState.finishedAt = ""
        let canReopen = o.reopenDAW && !recoveryState.sessionPath.isEmpty
        recoveryState.steps = [
            RecoveryStep(name: "\(cfg.daw.isEmpty ? "DAW" : cfg.daw) is closed", status: "pending", detail: ""),
            RecoveryStep(name: "Restart macOS audio engine", status: "pending", detail: ""),
            RecoveryStep(name: "Wait for the AVB device", status: "pending", detail: ""),
            RecoveryStep(name: "Reconnect and verify locked routes", status: "pending", detail: ""),
            RecoveryStep(name: o.loopChannel > 0 ? "Loop test on channel \(o.loopChannel)" : "Loop test", status: o.loopChannel > 0 ? "pending" : "skipped", detail: o.loopChannel > 0 ? "" : "off"),
            RecoveryStep(name: canReopen ? "Reopen \(recoveryState.sessionName)" : "Reopen session", status: canReopen ? "pending" : "skipped",
                         detail: canReopen ? "" : (o.reopenDAW ? "no session was open" : "off")),
        ]
        publishRecovery()
        event("info", "RECOVERY APPROVED by admin")
        let path = canReopen ? recoveryState.sessionPath : nil
        Thread.detachNewThread { [self] in self.executeRecovery(o, reopenPath: path) }
    }

    // MARK: execution (background thread; AVB operations hop onto `queue`)

    private func step(_ i: Int, _ status: String, _ detail: String = "") {
        queue.sync {
            recoveryState.steps[i].status = status
            if !detail.isEmpty { recoveryState.steps[i].detail = detail }
            publishRecovery()
            let name = recoveryState.steps[i].name
            if status != "running" { event(status == "failed" ? "problem" : "info", "recovery: \(name) - \(status)\(detail.isEmpty ? "" : ": \(detail)")") }
        }
    }

    private func finish(_ ok: Bool, _ msg: String) {
        queue.sync {
            recoveryState.running = false
            recoveryState.ok = ok
            recoveryState.finishedAt = tsFormat.string(from: Date())
            publishRecovery()
            event(ok ? "ok" : "problem", "RECOVERY \(ok ? "FINISHED" : "FAILED"): \(msg)")
        }
        notify(ok ? "AVB recovery finished" : "AVB recovery failed", msg)
        wake.signal()
    }

    private func executeRecovery(_ o: RecoveryOptions, reopenPath: String?) {
        // 1. the DAW must be closed - checked again right before the restart
        step(0, "running")
        if dawOpen {
            step(0, "failed", "\(cfg.daw) is open again. Quit it, then approve again.")
            return finish(false, "\(cfg.daw) was opened before the restart, so nothing was restarted.")
        }
        step(0, "ok")

        // 2. restart coreaudiod
        step(1, "running")
        let r = runProcess("/usr/bin/sudo", ["-n", "/usr/bin/killall", "coreaudiod"], timeout: 15)
        if r.status != 0 {
            step(1, "failed", "Not allowed to restart the audio engine. On this iMac run: sudo ./setup-recovery.sh  (\(r.out.prefix(100)))")
            return finish(false, "The recovery helper isn't installed.")
        }
        step(1, "ok")

        // 3. wait for the AVB device to come back
        step(2, "running")
        Thread.sleep(forTimeInterval: 3)
        let deadline = Date().addingTimeInterval(40)
        var back = false
        while Date() < deadline {
            if let me = entities().first(where: { $0.local }), me.sinks > 0, ctl.txStream(talker: me.id, uid: 0) != nil { back = true; break }
            Thread.sleep(forTimeInterval: 1)
        }
        if !back { step(2, "failed", "the AVB device didn't come back within 40 s"); return finish(false, "AVB device didn't come back after the restart.") }
        Thread.sleep(forTimeInterval: 3)
        step(2, "ok")

        // 4. reconnect + verify every locked route that touches this Mac
        step(3, "running")
        let (okCount, total, bad) = queue.sync { () -> (Int, Int, [String]) in
            watcher.suppressRepairForTalker = nil
            deadCycles = 0
            let ents = entities()
            guard let me = ents.first(where: { $0.local }) else { return (0, 0, ["no local entity"]) }
            let mine = cfg.connections.filter { $0.talkerID == me.id || $0.listenerID == me.id }
            for c in mine {
                watcher.markSelfAction(c.sinkKey)
                _ = ctl.disconnect(c); Thread.sleep(forTimeInterval: 0.2)
                _ = ctl.connect(c)
                watcher.lastFrames[c.key] = nil
            }
            Thread.sleep(forTimeInterval: 2)
            var bad: [String] = []
            for c in mine {
                var p = watcher.check(c, ents: ents)
                if p != .ok {   // one retry per route (the restart can leave a stream stuck, as seen on 2026-10-22)
                    watcher.markSelfAction(c.sinkKey)
                    _ = ctl.disconnect(c); Thread.sleep(forTimeInterval: 0.3); _ = ctl.connect(c)
                    watcher.lastFrames[c.key] = nil
                    Thread.sleep(forTimeInterval: 1.5)
                    p = watcher.check(c, ents: ents)
                }
                watcher.lastResult[c.sinkKey] = p
                if p != .ok { bad.append("\(describe(c)): \(p.text)") }
            }
            return (mine.count - bad.count, mine.count, bad)
        }
        if !bad.isEmpty {
            step(3, "failed", "\(okCount)/\(total) OK. " + bad.prefix(3).joined(separator: "; "))
            return finish(false, "\(total - okCount) routes still not passing audio after the restart.")
        }
        step(3, "ok", "\(total) routes passing packets")

        // 5. loop test (the DAW is closed, so the tone only goes out on the test channel)
        if o.loopChannel > 0 {
            step(4, "running")
            let t = runProcess(probeTool, ["1.0", "--tone", "\(o.loopChannel)", "-40"], timeout: 20)
            let key = "\"\(o.loopChannel)\":"
            if let range = t.out.range(of: key), let v = Double(t.out[range.upperBound...].prefix { "-0123456789.".contains($0) }), v > -46 {
                step(4, "ok", "tone came back at \(String(format: "%.1f", v)) dBFS")
            } else {
                step(4, "failed", "tone did not come back on input \(o.loopChannel) (check the console routing for that channel)")
            }
        }

        // 6. reopen the session
        if let path = reopenPath {
            step(5, "running")
            let r = runProcess("/usr/bin/open", ["-a", cfg.daw, path], timeout: 20)
            step(5, r.status == 0 ? "ok" : "failed", r.status == 0 ? URL(fileURLWithPath: path).lastPathComponent : r.out)
        }
        let loopFailed = recoveryState.steps[4].status == "failed"
        finish(!loopFailed, loopFailed ? "Streams restored, but the loop test failed." : "Audio engine restarted and all routes verified.")
    }
}
