// AVB Manager — menu-bar app for the admin. It's a front end to the background manager
// (the avbwatch LaunchAgent): it reads state from and sends commands to http://127.0.0.1:8077,
// authenticating with the private admin token the manager writes on start.

import AppKit
import SwiftUI
import UserNotifications

// MARK: - Models (mirror the manager's /api/state JSON)

struct StreamInfo: Codable, Hashable { var uid: Int; var name: String }
struct SinkInfo: Codable, Hashable {
    var uid: Int; var name: String; var talker: String?; var talkerUID: Int?
    var locked: Bool; var lockTalker: String?; var lockTalkerUID: Int?; var state: String; var ok: Bool
}
struct DeviceInfo: Codable, Hashable, Identifiable {
    var id: String; var name: String; var mac: String; var local: Bool; var sources: [StreamInfo]; var sinks: [SinkInfo]
}
struct EventInfo: Codable, Hashable { var time: String; var kind: String; var text: String }
struct RecoveryStep: Codable, Hashable { var name: String; var status: String; var detail: String }
struct RecoveryInfo: Codable, Hashable {
    var pending: Bool; var running: Bool; var reason: String; var proposedAt: String; var steps: [RecoveryStep]
    var finishedAt: String; var ok: Bool?; var dawName: String; var dawRunning: Bool; var sessionName: String; var sessionPath: String
    var loopChannel: Int; var helperInstalled: Bool
}
struct Notice: Codable, Hashable { var id: Int64; var title: String; var message: String }
struct StateInfo: Codable {
    var time: String; var link: Bool; var healthy: Bool; var adminConfigured: Bool; var sniffing: Bool
    var engineWarning: String?; var recovery: RecoveryInfo; var devices: [DeviceInfo]; var events: [EventInfo]
    var notices: [Notice]?
}

// MARK: - Client

@MainActor
final class Store: ObservableObject {
    @Published var state: StateInfo?
    @Published var reachable = false
    @Published var message: String?
    private let base = URL(string: "http://127.0.0.1:8077")!
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { await self?.load() } }
        Task { await load() }
    }

    var token: String {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AVBWatch/admin.token")
        return (try? String(contentsOf: url)) ?? ""
    }

    func load() async {
        do {
            let (d, r) = try await URLSession.shared.data(from: base.appendingPathComponent("api/state"))
            guard (r as? HTTPURLResponse)?.statusCode == 200 else { return }
            state = try JSONDecoder().decode(StateInfo.self, from: d)
            reachable = true
            deliver(state?.notices ?? [])
        } catch {
            reachable = false
        }
    }

    /// Post the manager's new alerts as macOS notifications. Alerts only show while this app runs.
    private var lastNotice: Int64?
    private func deliver(_ notices: [Notice]) {
        let newest = notices.map(\.id).max() ?? 0
        guard let last = lastNotice else { lastNotice = newest; return }   // don't replay old alerts at launch
        for n in notices where n.id > last {
            let c = UNMutableNotificationContent()
            c.title = n.title
            c.body = n.message
            c.sound = UNNotificationSound(named: UNNotificationSoundName("Basso.aiff"))
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "avb-\(n.id)", content: c, trigger: nil))
        }
        lastNotice = max(last, newest)
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any?] = [:]) async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(token, forHTTPHeaderField: "X-Admin-Token")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body.compactMapValues { $0 })
        req.timeoutInterval = 30
        do {
            let (d, r) = try await URLSession.shared.data(for: req)
            let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
            let ok = (r as? HTTPURLResponse)?.statusCode == 200
            message = ok ? (j?["message"] as? String) : (j?["error"] as? String ?? "Request failed")
            await load()
            return ok
        } catch {
            message = "Manager not reachable: \(error.localizedDescription)"
            return false
        }
    }

    // derived
    var lockedSinks: [(DeviceInfo, SinkInfo)] { (state?.devices ?? []).flatMap { d in d.sinks.filter(\.locked).map { (d, $0) } } }
    var failing: [(DeviceInfo, SinkInfo)] { lockedSinks.filter { !$0.1.ok } }

    enum Level { case ok, warn, bad, offline }
    var level: Level {
        guard reachable, let s = state else { return .offline }
        if !s.link || !failing.isEmpty || s.recovery.pending || s.recovery.ok == false { return .bad }
        if s.engineWarning != nil || s.recovery.running { return .warn }
        return .ok
    }

    var summary: String {
        guard reachable, let s = state else { return "Manager not running" }
        if !s.link { return "No AVB link" }
        if s.recovery.running { return "Recovery running…" }
        if s.recovery.pending { return "Recovery needs your approval" }
        if !failing.isEmpty { return "\(failing.count) locked route\(failing.count == 1 ? "" : "s") failing" }
        if let w = s.engineWarning { return w }
        return lockedSinks.isEmpty ? "Connected" : "All \(lockedSinks.count) locked routes OK"
    }

    func sourceLabel(_ id: String?, _ uid: Int?) -> String {
        guard let id = id, let uid = uid else { return "nothing" }
        guard let d = state?.devices.first(where: { $0.id == id }) else { return "device …\(id.suffix(6)) / out \(uid + 1)" }
        return "\(d.name) / \(d.sources.first { $0.uid == uid }?.name ?? "out \(uid + 1)")"
    }
}

// MARK: - App

extension Notification.Name { static let openRouting = Notification.Name("AVBOpenRouting") }

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // show alerts even when the app is frontmost
    func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // clicking an alert opens the menu-bar panel (or the routing window if the panel can't be found)
    func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            if !Self.openMenuPanel() { NotificationCenter.default.post(name: .openRouting, object: nil) }
            done()
        }
    }

    static func openMenuPanel() -> Bool {
        // already open: leave it (clicking the icon again would close it)
        if NSApp.windows.contains(where: { $0.isVisible && $0.className.contains("MenuBarExtra") }) { return true }
        func button(in v: NSView?) -> NSStatusBarButton? {
            guard let v = v else { return nil }
            if let b = v as? NSStatusBarButton { return b }
            for s in v.subviews { if let b = button(in: s) { return b } }
            return nil
        }
        for w in NSApp.windows where w.className.contains("StatusBar") {
            if let b = button(in: w.contentView) { b.performClick(nil); return true }
        }
        return false
    }
}

@main
struct AVBManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store()

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(store)
        } label: {
            MenuIcon(name: icon)
        }
        .menuBarExtraStyle(.window)

        Window("AVB Routing", id: "routing") {
            RoutingView().environmentObject(store).frame(minWidth: 720, minHeight: 520)
        }
    }

    var icon: String {
        switch store.level {
        case .ok: return "dot.radiowaves.left.and.right"
        case .warn: return "exclamationmark.circle"
        case .bad: return "exclamationmark.triangle.fill"
        case .offline: return "antenna.radiowaves.left.and.right.slash"
        }
    }
}

/// The menu-bar icon. It's always on screen, so it also opens the routing window when asked.
struct MenuIcon: View {
    let name: String
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Image(systemName: name)
            .onReceive(NotificationCenter.default.publisher(for: .openRouting)) { _ in openWindow(id: "routing") }
    }
}

/// Buttons in the menu-bar panel. The standard style draws them grey (as if disabled) because the
/// panel is never the key window, so these use their own fixed colours.
struct PanelButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var prominent = false
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration, tint: tint, prominent: prominent) }

    struct Face: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.callout.weight(.medium))
                .foregroundColor(prominent ? .white : tint)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(prominent ? tint : tint.opacity(0.15)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint.opacity(prominent ? 0 : 0.35), lineWidth: 1))
                .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == PanelButtonStyle {
    static var panel: PanelButtonStyle { PanelButtonStyle() }
    static func panel(_ tint: Color, prominent: Bool = false) -> PanelButtonStyle { PanelButtonStyle(tint: tint, prominent: prominent) }
}

extension Store.Level {
    var color: Color { switch self { case .ok: return .green; case .warn: return .orange; case .bad: return .red; case .offline: return .secondary } }
}

// MARK: - Menu

struct MenuView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle().fill(store.level.color).frame(width: 10, height: 10)
                Text(store.summary).font(.headline)
            }
            if let s = store.state {
                if let w = s.engineWarning { Label(w, systemImage: "music.note").foregroundColor(.orange).font(.callout) }
                if !store.failing.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.failing, id: \.1) { d, k in
                            Text("\(d.name) / \(k.name): \(k.state)").font(.callout).foregroundColor(.red)
                        }
                    }
                }
                RecoveryPanel(r: s.recovery)
            } else if !store.reachable {
                Text("The background manager isn't answering on port 8077. Run ./install.sh in the AVBmonitor folder.")
                    .font(.callout).foregroundColor(.secondary)
            }
            if let m = store.message { Text(m).font(.caption).foregroundColor(.secondary) }
            Divider()
            HStack(spacing: 8) {
                Button("Routing…") { openWindow(id: "routing"); NSApp.activate(ignoringOtherApps: true) }
                    .buttonStyle(.panel)
                Button("Web Page") { NSWorkspace.shared.open(URL(string: "http://localhost:8077/")!) }
                    .buttonStyle(.panel)
                Spacer()
                if let r = store.state?.recovery, !r.pending, !r.running {
                    Button("Recovery…") { Task { await store.post("api/recovery/propose") } }
                        .buttonStyle(.panel(.orange))
                        .help("Prepare an audio engine restart and approve it here")
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.panel(.primary))
                    .help("Quit the app. Routes stay protected in the background, but no alerts are shown until you open it again.")
            }
        }
        .padding(14)
        .frame(width: 400)
    }
}

let tsFormatApp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()

struct RecoveryPanel: View {
    @EnvironmentObject var store: Store
    let r: RecoveryInfo
    @State private var reopen = true
    @State private var loopTest = true
    @State private var channel = 30

    var daw: String { r.dawName.isEmpty ? "Pro Tools" : r.dawName }
    /// "14:02:10" today, "Oct 24 14:02" on an earlier day
    var finished: String {
        let today = String(tsFormatApp.string(from: Date()).prefix(10))
        if r.finishedAt.hasPrefix(today) { return String(r.finishedAt.suffix(8)) }
        guard let d = tsFormatApp.date(from: r.finishedAt) else { return r.finishedAt }
        let f = DateFormatter(); f.dateFormat = "MMM d HH:mm"
        return f.string(from: d)
    }

    var body: some View {
        if r.pending {
            VStack(alignment: .leading, spacing: 8) {
                Label("Recovery needs your approval", systemImage: "exclamationmark.octagon.fill").font(.headline).foregroundColor(.red)
                Text(r.reason).font(.callout).fixedSize(horizontal: false, vertical: true)
                // RULE: the user quits the DAW themselves; the restart stays locked until it's closed
                if r.dawRunning {
                    Label("Save your work and quit \(daw) to continue. The audio engine can't be restarted while it's open.",
                          systemImage: "lock.fill")
                        .font(.callout.weight(.semibold)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("\(daw) is closed", systemImage: "checkmark.circle.fill").font(.callout).foregroundColor(.green)
                }
                if !r.sessionName.isEmpty {
                    Toggle("Reopen \(r.sessionName) afterwards", isOn: $reopen)
                }
                HStack {
                    Toggle("Loop test on channel", isOn: $loopTest)
                    TextField("", value: $channel, format: .number).frame(width: 44).disabled(!loopTest)
                }
                if !r.helperInstalled {
                    Text("One-time setup needed first: in Terminal, in the AVBmonitor folder, run  sudo ./setup-recovery.sh")
                        .font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Approve and run") {
                        Task { await store.post("api/recovery/approve", ["reopenDAW": reopen, "loopChannel": loopTest ? channel : 0]) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.panel(.accentColor, prominent: true))
                    .disabled(r.dawRunning)
                    .help(r.dawRunning ? "Quit \(daw) first" : "Restart the audio engine and reconnect")
                    Button("Dismiss") { Task { await store.post("api/recovery/dismiss") } }
                        .buttonStyle(.panel(.primary))
                }
            }
            .padding(10).background(Color.red.opacity(0.08)).cornerRadius(8)
            .onAppear { if r.loopChannel > 0 { channel = r.loopChannel } }
        } else if r.running || !r.finishedAt.isEmpty && r.ok != nil && !r.steps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(r.running ? "Recovery running…" : (r.ok == true ? "Recovery finished \(finished)" : "Recovery failed \(finished)"))
                        .font(.headline).foregroundColor(r.running ? .orange : (r.ok == true ? .green : .red))
                    Spacer()
                    if !r.running {
                        Button("Clear") { Task { await store.post("api/recovery/clear") } }
                            .buttonStyle(.panel(.primary))
                            .help("Remove these recovery results")
                    }
                }
                ForEach(r.steps, id: \.self) { s in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: icon(s.status)).foregroundColor(color(s.status)).frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name).font(.callout)
                            if !s.detail.isEmpty { Text(s.detail).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
            }
            .padding(10).background(Color.secondary.opacity(0.08)).cornerRadius(8)
        }
    }

    func icon(_ s: String) -> String {
        ["ok": "checkmark.circle.fill", "failed": "xmark.octagon.fill", "running": "arrow.triangle.2.circlepath", "skipped": "minus.circle"][s] ?? "circle"
    }
    func color(_ s: String) -> Color { ["ok": .green, "failed": .red, "running": .orange][s] ?? .secondary }
}

// MARK: - Routing window

struct RoutingView: View {
    @EnvironmentObject var store: Store
    @State private var renaming: DeviceInfo?
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Circle().fill(store.level.color).frame(width: 10, height: 10)
                Text(store.summary).font(.headline)
                Spacer()
                if let m = store.message { Text(m).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                Button("Lock all current routes") { Task { await store.post("api/lockall") } }
            }
            .padding(12)
            Divider()
            if let s = store.state {
                List {
                    ForEach(s.devices.filter { !$0.sinks.isEmpty }) { d in
                        Section {
                            ForEach(d.sinks, id: \.uid) { k in SinkRow(device: d, sink: k) }
                        } header: {
                            HStack {
                                Text(d.name).font(.headline)
                                Text("inputs · \(d.mac)").foregroundColor(.secondary)
                                Spacer()
                                Button("Rename…") { newName = d.name; renaming = d }.buttonStyle(.borderless)
                            }
                        }
                    }
                    Section("Activity") {
                        ForEach(s.events.prefix(80), id: \.self) { e in
                            HStack(alignment: .top) {
                                Text(String(e.time.dropFirst(11))).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                Text(e.text).font(.caption).foregroundColor(["revert": .red, "problem": .red, "lock": .purple, "ok": .green][e.kind] ?? .primary)
                            }
                        }
                    }
                }
            } else {
                Spacer(); Text(store.reachable ? "Loading…" : "Manager not running").foregroundColor(.secondary); Spacer()
            }
        }
        .sheet(item: $renaming) { d in
            VStack(alignment: .leading, spacing: 12) {
                Text("Rename \(d.name)").font(.headline)
                TextField("Name", text: $newName).frame(width: 280)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }
                    Button("Save") { Task { await store.post("api/rename", ["id": d.id, "name": newName]); renaming = nil } }.keyboardShortcut(.defaultAction)
                }
            }.padding(18)
        }
    }
}

struct SinkRow: View {
    @EnvironmentObject var store: Store
    let device: DeviceInfo
    let sink: SinkInfo

    var current: String { sink.talker.map { "\($0)|\(sink.talkerUID ?? 0)" } ?? "" }

    var body: some View {
        HStack(spacing: 12) {
            Text(sink.name).frame(width: 140, alignment: .leading)
            Picker("", selection: Binding(get: { current }, set: { v in patch(v) })) {
                Text("— nothing —").tag("")
                ForEach((store.state?.devices ?? []).filter { $0.id != device.id && !$0.sources.isEmpty }) { t in
                    Section(t.name) {
                        ForEach(t.sources, id: \.uid) { o in Text(o.name).tag("\(t.id)|\(o.uid)") }
                    }
                }
                if !current.isEmpty && !(store.state?.devices ?? []).contains(where: { $0.id == sink.talker }) {
                    Text(store.sourceLabel(sink.talker, sink.talkerUID)).tag(current)
                }
            }
            .labelsHidden()
            .frame(width: 260)
            VStack(alignment: .leading, spacing: 1) {
                if sink.locked {
                    Text(sink.ok ? "Locked · OK" : sink.state).font(.callout).foregroundColor(sink.ok ? .green : .red)
                    if sink.lockTalker != sink.talker || sink.lockTalkerUID != sink.talkerUID {
                        Text("locked to \(store.sourceLabel(sink.lockTalker, sink.lockTalkerUID))").font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    Text(sink.talker == nil ? "—" : "connected").font(.callout).foregroundColor(.secondary)
                }
            }
            Spacer()
            if sink.locked {
                Button { Task { await store.post("api/unlock", ["listener": device.id, "luid": sink.uid]) } } label: { Label("Unlock", systemImage: "lock.fill") }
                    .foregroundColor(.purple)
            } else {
                Button { Task { await store.post("api/lock", ["listener": device.id, "luid": sink.uid]) } } label: { Label("Lock", systemImage: "lock.open") }
                    .disabled(sink.talker == nil)
            }
        }
        .padding(.vertical, 2)
    }

    func patch(_ v: String) {
        guard v != current else { return }
        let parts = v.split(separator: "|")
        if device.local || parts.first.map(String.init) == store.state?.devices.first(where: \.local)?.id {
            let a = NSAlert()
            a.messageText = "Change this Mac's own AVB stream?"
            a.informativeText = "Re-patching this Mac's streams while Pro Tools is running can stop its audio engine."
            a.addButton(withTitle: "Change"); a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        Task {
            await store.post("api/patch", ["listener": device.id, "luid": sink.uid,
                                           "talker": parts.count == 2 ? String(parts[0]) : nil,
                                           "tuid": parts.count == 2 ? Int(parts[1]) : nil])
        }
    }
}
