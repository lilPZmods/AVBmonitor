// avbwatch — AVB route manager.
//
//   avbwatch run              run the manager + web page (what the LaunchAgent runs)
//   avbwatch status           check every locked route once and print the result
//   avbwatch fix              check once and repair anything broken
//   avbwatch learn            lock this Mac's current connections (replaces the lock list)
//   avbwatch passwd           set the admin password for the web page
//   avbwatch locks            list locked routes (numbered)
//   avbwatch reconnect <n>    force a disconnect + reconnect of locked route n
//   avbwatch disconnect <n>   break locked route n (for testing the healing)
//   avbwatch counters         show stream IDs and packet counters for every locked route

import Foundation

try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let cmd = args.count > 1 ? args[1] : "status"

func learn(_ ifname: String) {
    let ctl = AVBControl(ifname)
    let ents = entities()
    guard let me = ents.first(where: { $0.local }) else { print("No local AVB entity - is AVB enabled for \(ifname) in Audio MIDI Setup?"); exit(1) }
    var conns: [Connection] = []
    for u in 0..<max(me.sinks, 1) {
        if let r = ctl.rxState(listener: me.id, uid: UInt16(u)).0, r.status == 0, r.count > 0, r.talker != 0 {
            conns.append(Connection(talker: hex(r.talker), talkerUID: r.talkerUID, listener: hex(me.id), listenerUID: UInt16(u),
                                    label: "IN  \(u + 1): device \(hex(r.talker).suffix(6)) stream \(r.talkerUID) -> Mac"))
        }
    }
    for e in ents where !e.local {
        for u in 0..<e.sinks {
            if let r = ctl.rxState(listener: e.id, uid: UInt16(u)).0, r.status == 0, r.count > 0, r.talker == me.id {
                conns.append(Connection(talker: hex(me.id), talkerUID: r.talkerUID, listener: hex(e.id), listenerUID: UInt16(u),
                                        label: "OUT \(r.talkerUID + 1): Mac -> device \(hex(e.id).suffix(6)) input \(u)"))
            }
        }
    }
    var cfg = loadConfig() ?? Config()
    cfg.interface = ifname
    cfg.connections = conns
    saveConfig(cfg)
    print("Locked \(conns.count) routes -> \(configURL.path)")
    for c in conns { print("  " + c.label) }
}

switch cmd {
case "learn":
    learn(args.count > 2 ? args[2] : (loadConfig()?.interface ?? "en0"))
    exit(0)
case "passwd":
    var cfg = loadConfig() ?? Config()
    guard let p1 = getpass("New admin password: ").map({ String(cString: $0) }), p1.count >= 4 else { print("Use at least 4 characters."); exit(1) }
    guard let p2 = getpass("Again: ").map({ String(cString: $0) }), p1 == p2 else { print("Passwords didn't match."); exit(1) }
    cfg.adminSalt = UUID().uuidString
    cfg.adminHash = Config.hash(p1, salt: cfg.adminSalt)
    saveConfig(cfg)
    print("Admin password saved. Restart the manager to apply:  launchctl kickstart -k gui/\(getuid())/ca.arraymusic.avbwatch")
    exit(0)
default: break
}

let cfg = loadConfig() ?? Config()

if cmd == "run" {
    let m = Manager(cfg)
    let web = WebServer(m)
    web.start(port: cfg.webPort)
    m.run()
}

guard !cfg.connections.isEmpty else {
    print("No locked routes yet. Lock routes on the web page, or run:  avbwatch learn")
    exit(1)
}
let m = Manager(cfg)
let w = m.watcher

switch cmd {
case "status", "fix":
    let res = m.queue.sync { w.cycle(fix: cmd == "fix", immediate: true) }
    print("link \(cfg.interface): \(linkUp(cfg.interface) ? "up" : "DOWN")")
    for (c, p) in res { print("\(p == .ok ? "  ok " : "  !! ") \(m.describe(c)): \(p.text)") }
    exit(res.allSatisfy { $0.1 == .ok } && !res.isEmpty ? 0 : 2)
case "locks":
    for (i, c) in cfg.connections.enumerated() { print("  \(i + 1)  \(m.describe(c))") }
case "reconnect", "disconnect":
    guard args.count > 2, let n = Int(args[2]), n >= 1, n <= cfg.connections.count else {
        for (i, c) in cfg.connections.enumerated() { print("  \(i + 1)  \(m.describe(c))") }
        exit(1)
    }
    let c = cfg.connections[n - 1]
    if cmd == "disconnect" {
        let (r, e) = w.ctl.disconnect(c)
        log("manual disconnect: \(m.describe(c)) -> \(e ?? "status \(r?.status ?? 255)")")
    } else {
        log("manual reconnect: \(m.describe(c))")
        _ = w.ctl.disconnect(c); Thread.sleep(forTimeInterval: 0.5)
        w.repair(c, .notConnected)
        Thread.sleep(forTimeInterval: 1.5)
        print(w.check(c, ents: entities()).text)
    }
case "counters":
    let ents = entities()
    for c in cfg.connections {
        let tx = w.ctl.txStream(talker: c.talkerID, uid: c.talkerUID)
        let rx = w.ctl.rxState(listener: c.listenerID, uid: c.listenerUID).0
        var line = "\(c.label)  sending=\(tx.map(hex) ?? "?") receiving=\(rx.map { hex($0.stream) } ?? "?")"
        if let e = ents.first(where: { $0.id == c.listenerID }), let r = w.ctl.streamInputCounters(entity: e, index: c.listenerUID) {
            line += " frames=\(r.frames) locked=\(r.locked)"
        }
        print(line)
    }
default:
    print("usage: avbwatch run | status | fix | learn | passwd | locks | reconnect <n> | disconnect <n> | counters")
    exit(1)
}
