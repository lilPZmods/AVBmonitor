// Web: a small HTTP server for the routing page and its JSON API.
//   GET  /               the page
//   GET  /api/state      devices, inputs, locks, events
//   POST /api/login      check the admin password            (X-Admin-Password header)
//   POST /api/patch      {listener, luid, talker?, tuid?}    anyone for unlocked inputs, admin for locked
//   POST /api/lock       {listener, luid, talker?, tuid?}    admin
//   POST /api/unlock     {listener, luid}                    admin
//   POST /api/lockall                                        admin
//   POST /api/rename     {id, name}                          admin

import Foundation
import Network

final class WebServer {
    let manager: Manager
    private var listener: NWListener?
    private let connQueue = DispatchQueue(label: "web", attributes: .concurrent)
    private var failedLogins: [String: (count: Int, until: Date)] = [:]
    private let failLock = NSLock()

    let adminToken = makeAdminToken()

    init(_ m: Manager) { manager = m }

    func start(port: UInt16) {
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { st in
                if case .failed(let e) = st { log("web server failed: \(e)") }
                if case .ready = st { log("web page: http://\(Host.current().localizedName ?? "this-mac").local:\(port)/") }
            }
            l.start(queue: connQueue)
            listener = l
        } catch {
            log("web server could not start on port \(port): \(error)")
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: connQueue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self else { return }
            var b = buf
            if let d = data { b.append(d) }
            if let req = Request(b) {
                let resp = self.handle(req, remote: c.endpoint)
                c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
            } else if done || err != nil || b.count > 1_000_000 {
                c.cancel()
            } else {
                self.receive(c, b)
            }
        }
    }

    // MARK: request handling

    private func handle(_ r: Request, remote: NWEndpoint) -> Data {
        let host: String = { if case .hostPort(let h, _) = remote { return "\(h)" }; return "?" }()
        if r.method == "GET" && (r.path == "/" || r.path == "/index.html") { return response(200, "text/html; charset=utf-8", Data(pageHTML.utf8)) }
        if r.method == "GET" && r.path == "/api/state" {
            guard let s = manager.state(), let d = try? JSONEncoder().encode(s) else { return json(503, ["error": "starting up"]) }
            return response(200, "application/json", d)
        }
        guard r.method == "POST" else { return json(404, ["error": "not found"]) }

        // admin check, with a short lockout after repeated wrong passwords
        var admin = false
        // the menu-bar app on this Mac: token from the private file, accepted from this machine only
        if let tok = r.headers["x-admin-token"], tok == adminToken, host == "127.0.0.1" || host == "::1" || host.hasPrefix("::ffff:127.") { admin = true }
        if !admin, let pw = r.headers["x-admin-password"], !pw.isEmpty {
            failLock.lock()
            let lockedOut = (failedLogins[host]?.until ?? .distantPast) > Date()
            failLock.unlock()
            if lockedOut { return json(429, ["error": "Too many wrong passwords. Try again in a minute."]) }
            admin = manager.queue.sync { manager.cfg.passwordMatches(pw) }
            failLock.lock()
            if admin { failedLogins[host] = nil } else {
                let n = (failedLogins[host]?.count ?? 0) + 1
                failedLogins[host] = (n, n >= 5 ? Date().addingTimeInterval(60) : .distantPast)
                if n >= 5 { log("web: 5 wrong admin passwords from \(host), locked out for 60 s") }
            }
            failLock.unlock()
            if !admin { return json(401, ["error": "Wrong admin password"]) }
        }

        let body = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        func id(_ k: String) -> UInt64? { (body[k] as? String).flatMap { UInt64($0, radix: 16) } }
        func uid(_ k: String) -> UInt16? { (body[k] as? NSNumber)?.uint16Value }

        do {
            switch r.path {
            case "/api/login":
                if admin && r.headers["x-admin-token"] != nil { return json(200, ["ok": true]) }
                if manager.cfg.adminHash.isEmpty { return json(400, ["error": "No admin password set. On the iMac run: avbwatch passwd"]) }
                return admin ? json(200, ["ok": true]) : json(401, ["error": "Enter the admin password"])
            case "/api/patch":
                guard let l = id("listener"), let lu = uid("luid") else { return json(400, ["error": "missing listener"]) }
                let t = id("talker"), tu = uid("tuid")
                let msg = try manager.queue.sync { try manager.patch(listener: l, luid: lu, talker: t, tuid: t == nil ? nil : tu, admin: admin) }
                log("web (\(host)): \(msg)")
                return json(200, ["ok": true, "message": msg])
            case "/api/lock":
                guard admin else { return json(401, ["error": "Admin password required"]) }
                guard let l = id("listener"), let lu = uid("luid") else { return json(400, ["error": "missing listener"]) }
                let msg = try manager.queue.sync { try manager.lock(listener: l, luid: lu, talker: id("talker"), tuid: uid("tuid")) }
                return json(200, ["ok": true, "message": "Locked: \(msg)"])
            case "/api/unlock":
                guard admin else { return json(401, ["error": "Admin password required"]) }
                guard let l = id("listener"), let lu = uid("luid") else { return json(400, ["error": "missing listener"]) }
                try manager.queue.sync { try manager.unlock(listener: l, luid: lu) }
                return json(200, ["ok": true])
            case "/api/rename":
                guard admin else { return json(401, ["error": "Admin password required"]) }
                guard let d = id("id"), let n = body["name"] as? String else { return json(400, ["error": "missing id/name"]) }
                manager.queue.sync { manager.rename(id: d, name: n) }
                return json(200, ["ok": true, "message": "Renamed"])
            case "/api/recovery/approve":
                guard admin else { return json(401, ["error": "Admin password required"]) }
                let o = RecoveryOptions(reopenDAW: body["reopenDAW"] as? Bool ?? true,
                                        loopChannel: (body["loopChannel"] as? NSNumber)?.intValue ?? 0)
                try manager.queue.sync { try manager.approveRecovery(o) }
                return json(200, ["ok": true, "message": "Recovery started"])
            case "/api/recovery/dismiss":
                guard admin else { return json(401, ["error": "Admin password required"]) }
                manager.queue.sync { manager.dismissRecovery() }
                return json(200, ["ok": true])
            case "/api/recovery/clear":
                guard admin else { return json(401, ["error": "Admin password required"]) }
                try manager.queue.sync { try manager.clearRecovery() }
                return json(200, ["ok": true, "message": "Recovery results cleared"])
            case "/api/recovery/propose":
                guard admin else { return json(401, ["error": "Admin password required"]) }
                manager.queue.sync { if !manager.recoveryState.pending && !manager.recoveryState.running { manager.propose(reason: "Recovery requested manually by the admin.") } }
                return json(200, ["ok": true])
            case "/api/lockall":
                guard admin else { return json(401, ["error": "Admin password required"]) }
                let n = manager.queue.sync { manager.lockAll() }
                return json(200, ["ok": true, "message": "Locked \(n) routes"])
            default:
                return json(404, ["error": "not found"])
            }
        } catch let e as APIError {
            return json(e.status, ["error": e.message])
        } catch {
            return json(500, ["error": "\(error)"])
        }
    }

    private func json(_ status: Int, _ obj: [String: Any]) -> Data {
        response(status, "application/json", (try? JSONSerialization.data(withJSONObject: obj)) ?? Data())
    }

    private func response(_ status: Int, _ type: String, _ body: Data) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
                      409: "Conflict", 429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway", 503: "Service Unavailable"][status] ?? "OK"
        var h = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        h += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(h.utf8) + body
    }
}

/// Minimal HTTP/1.1 request parser. Returns nil until the full request (headers + body) has arrived.
struct Request {
    var method = "", path = "", headers: [String: String] = [:], body = Data()

    init?(_ d: Data) {
        guard let end = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = head.first?.split(separator: " ") ?? []
        guard first.count >= 2 else { return nil }
        method = String(first[0]); path = String(first[1].split(separator: "?").first ?? "/")
        for line in head.dropFirst() {
            if let i = line.firstIndex(of: ":") {
                headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard d.count - bodyStart >= len else { return nil }
        body = d[bodyStart..<(bodyStart + len)]
    }
}
