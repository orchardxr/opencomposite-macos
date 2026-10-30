// SteamVR's web server mailbox (vrserver's CWebThread role) on ws://localhost:27062.
// Protocol (text frames from clients): "mailbox_open <name>", "mailbox_close <name>", "mailbox_send <name> <json>",
// "websocket_close". A message sent to a mailbox goes to every connection that opened that name.
// "web_server_mailbox" is handled here: request_mailbox_registration_notification /
// request_mailbox_unavailable_notification (as SteamVR), and register_external_webroot from OpenComposite (SteamVR's
// IVRControlPanel::RegisterExternalWebRoot IPC): reads <webroot>/vrwebui.config.json, starts oc-webhelper and
// sends it create_overlays on "vrwebhelper/main"; destroy_overlays when the registering connection closes.
// OpenComposite's vrclient starts the broker on demand and marks its connections with "oc_vrclient <pid>"; the broker
// exits a few seconds after the last of them closed.
import Foundation
import Network

func argument(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

// stdout/stderr go to the log (also the helper's, which inherits them), unless --log -.
let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
let logPath = argument("--log") ?? (home + "/Library/Logs/OpenComposite/web-overlays.log")
if logPath != "-" {
    let url = URL(fileURLWithPath: logPath)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let size = (try? FileManager.default.attributesOfItem(atPath: logPath))?[.size] as? Int, size > 4 << 20 {
        _ = try? FileManager.default.removeItem(atPath: logPath + ".1")
        _ = try? FileManager.default.moveItem(atPath: logPath, toPath: logPath + ".1")
    }
    let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    if fd >= 0 {
        dup2(fd, 1)
        dup2(fd, 2)
        close(fd)
    }
}
setvbuf(stdout, nil, _IOLBF, 0)
setvbuf(stderr, nil, _IOLBF, 0)

func log(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    print("\(f.string(from: Date())) \(s)")
}

let port: UInt16 = UInt16(argument("--port") ?? ProcessInfo.processInfo.environment["OC_MAILBOX_PORT"] ?? "") ?? 27062
let idleGrace = TimeInterval(argument("--idle-exit") ?? "") ?? 5
let queue = DispatchQueue(label: "broker")
let pendingTTL: TimeInterval = 10
let webrootTimeout: TimeInterval = 15

final class Client {
    let id: Int
    let conn: NWConnection
    var mailboxes = Set<String>()
    var webroots = Set<String>()
    var vrclient = false
    init(id: Int, conn: NWConnection) { self.id = id; self.conn = conn }

    func send(_ text: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "t", metadata: [meta])
        conn.send(content: text.data(using: .utf8), contentContext: ctx, isComplete: true, completion: .idempotent)
    }
}

struct Pending { let text: String; let time: Date }
struct Waiter { let returnAddress: String; let messageId: Any?; let type: String }
struct WebrootRequest { let client: Int; let returnAddress: String; let messageId: Any?; let name: String; let started: Date }

var clients = [Int: Client]()
var nextId = 1
var pending = [String: [Pending]]()
var registrationWaiters = [String: [Waiter]]()
var unavailableWaiters = [String: [Waiter]]()
var webroots = [String: [String: Any]]() // name -> create_overlays entry
var webrootRequests = [WebrootRequest]()
var helper: Process?
var idleSince: Date? = Date()

func isOpen(_ name: String) -> Bool { clients.values.contains { $0.mailboxes.contains(name) } }

func json(_ obj: [String: Any]) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    return String(decoding: d, as: UTF8.self)
}

func deliver(_ name: String, _ text: String) {
    if name == "web_server_mailbox" {
        webServerMessage(text)
        return
    }
    let targets = clients.values.filter { $0.mailboxes.contains(name) }
    if targets.isEmpty {
        // Not in SteamVR's protocol notes; keeps e.g. the page's "ready" for a game mailbox that opens a moment later.
        var q = pending[name, default: []].filter { Date().timeIntervalSince($0.time) < pendingTTL }
        q.append(Pending(text: text, time: Date()))
        pending[name] = Array(q.suffix(64))
        return
    }
    for c in targets { c.send(text) }
}

func reply(_ w: Waiter, _ extra: [String: Any]) {
    var m = extra
    m["type"] = w.type
    if let id = w.messageId { m["message_id"] = id }
    deliver(w.returnAddress, json(m))
}

func opened(_ c: Client, _ name: String) {
    c.mailboxes.insert(name)
    log("client \(c.id) opened \(name)")
    if let q = pending.removeValue(forKey: name) {
        for p in q where Date().timeIntervalSince(p.time) < pendingTTL { c.send(p.text) }
    }
    for w in registrationWaiters.removeValue(forKey: name) ?? [] { reply(w, ["mailbox_name": name]) }
}

func closed(_ name: String) {
    guard !isOpen(name) else { return }
    for w in unavailableWaiters.removeValue(forKey: name) ?? [] { reply(w, ["mailbox_name": name]) }
}

func webServerMessage(_ text: String) {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
          let type = obj["type"] as? String else { log("web_server_mailbox: bad message \(text.prefix(200))"); return }
    let ret = obj["returnAddress"] as? String
    let mid = obj["message_id"]
    switch type {
    case "request_mailbox_registration_notification":
        guard let name = obj["mailbox_name"] as? String, let ret else { return }
        let w = Waiter(returnAddress: ret, messageId: mid, type: "mailbox_registered")
        if isOpen(name) { reply(w, ["mailbox_name": name]) } else { registrationWaiters[name, default: []].append(w) }
    case "request_mailbox_unavailable_notification":
        guard let name = obj["mailbox_name"] as? String, let ret else { return }
        let w = Waiter(returnAddress: ret, messageId: mid, type: "mailbox_unavailable")
        if !isOpen(name) { reply(w, ["mailbox_name": name]) } else { unavailableWaiters[name, default: []].append(w) }
    case "register_external_webroot":
        registerWebroot(obj)
    case "overlays_loaded":
        guard let name = obj["name"] as? String else { return }
        log("webui \(name) loaded")
        finishWebrootRequests(name, result: 0)
    default:
        log("web_server_mailbox: unhandled \(type)")
    }
}

func finishWebrootRequests(_ name: String, result: Int) {
    let done = webrootRequests.filter { $0.name == name }
    webrootRequests.removeAll { $0.name == name }
    for r in done {
        reply(Waiter(returnAddress: r.returnAddress, messageId: r.messageId, type: "register_external_webroot_response"),
              ["name": name, "result": result])
    }
}

func registerWebroot(_ obj: [String: Any]) {
    guard let name = obj["name"] as? String, let unixPath = obj["unix_path"] as? String,
          let ret = obj["returnAddress"] as? String else { log("register_external_webroot: missing fields"); return }
    let owner = clients.values.first { $0.mailboxes.contains(ret) }
    let path = obj["path"] as? String ?? ""
    let cfgURL = URL(fileURLWithPath: unixPath).appendingPathComponent("vrwebui.config.json")
    guard let data = try? Data(contentsOf: cfgURL),
          let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        log("RegisterExternalWebRoot: Failed to read vrwebui.config.json from \(unixPath)")
        reply(Waiter(returnAddress: ret, messageId: obj["message_id"], type: "register_external_webroot_response"),
              ["name": name, "result": 1])
        return
    }
    var overlays = [[String: Any]]()
    for (key, value) in cfg {
        guard var o = value as? [String: Any] else { continue }
        o["name"] = key
        overlays.append(o)
    }
    log("Creating webui for \(name)=\(path) (\(unixPath)): \(overlays.compactMap { $0["name"] as? String })")
    let entry: [String: Any] = ["type": "create_overlays", "name": name, "path": path, "unix_path": unixPath,
                                "drives": obj["drives"] ?? [String: String](), "overlays": overlays]
    webroots[name] = entry
    owner?.webroots.insert(name)
    webrootRequests.append(WebrootRequest(client: owner?.id ?? 0, returnAddress: ret, messageId: obj["message_id"],
                                          name: name, started: Date()))
    startHelper()
    deliver("vrwebhelper/main", json(entry))
    queue.asyncAfter(deadline: .now() + webrootTimeout) {
        if webrootRequests.contains(where: { $0.name == name && Date().timeIntervalSince($0.started) >= webrootTimeout - 0.5 }) {
            log("Timed out waiting for \(name) to load")
            finishWebrootRequests(name, result: 2)
        }
    }
}

func startHelper() {
    if let h = helper, h.isRunning { return }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("oc-webhelper")
    let p = Process()
    p.executableURL = exe
    p.arguments = ["--port", String(port)]
    p.terminationHandler = { t in queue.async {
        log("webhelper exited (\(t.terminationStatus))")
        if helper === t { helper = nil }
    } }
    do {
        try p.run()
        helper = p
        log("started webhelper pid \(p.processIdentifier)")
    } catch {
        log("can't start \(exe.path): \(error)")
    }
}

func dropClient(_ c: Client) {
    guard clients.removeValue(forKey: c.id) != nil else { return }
    log("client \(c.id) closed (\(c.mailboxes.sorted().joined(separator: ",")))")
    for name in c.mailboxes { closed(name) }
    for name in c.webroots where webroots.removeValue(forKey: name) != nil {
        log("destroying webui \(name)")
        deliver("vrwebhelper/main", json(["type": "destroy_overlays", "name": name]))
    }
    c.conn.cancel()
    if c.vrclient && !clients.values.contains(where: { $0.vrclient }) {
        log("no vrclient connections left")
        idleSince = Date()
    }
}

func handle(_ c: Client, _ text: String) {
    let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
    switch parts.first ?? "" {
    case "mailbox_open" where parts.count >= 2:
        opened(c, parts[1])
    case "mailbox_close" where parts.count >= 2:
        c.mailboxes.remove(parts[1])
        closed(parts[1])
    case "mailbox_send" where parts.count >= 3:
        deliver(parts[1], parts[2])
    case "websocket_close":
        dropClient(c)
    case "oc_vrclient":
        c.vrclient = true
        idleSince = nil
        log("client \(c.id) is vrclient \(parts.count >= 2 ? parts[1] : "?")")
    default:
        log("client \(c.id): unhandled \(text.prefix(120))")
    }
}

func receive(_ c: Client) {
    c.conn.receiveMessage { data, ctx, _, error in
        if let error {
            log("client \(c.id) error \(error)")
            dropClient(c)
            return
        }
        if let meta = ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
            if meta.opcode == .close { dropClient(c); return }
            if meta.opcode == .text, let data { handle(c, String(decoding: data, as: UTF8.self)) }
        } else if data == nil {
            dropClient(c)
            return
        }
        if clients[c.id] != nil { receive(c) }
    }
}

func listen(host: NWEndpoint.Host) -> NWListener? {
    let ws = NWProtocolWebSocket.Options()
    ws.autoReplyPing = true
    ws.maximumMessageSize = 16 << 20
    // SteamVR wants a secret (?secret= or x-steamvr-secret) and a localhost origin; loopback only here, any secret.
    ws.setClientRequestHandler(queue) { _, _ in NWProtocolWebSocket.Response(status: .accept, subprotocol: nil) }
    let params = NWParameters.tcp
    params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
    params.requiredLocalEndpoint = .hostPort(host: host, port: NWEndpoint.Port(rawValue: port)!)
    params.allowLocalEndpointReuse = true
    guard let l = try? NWListener(using: params) else { log("can't listen on \(host):\(port)"); return nil }
    l.newConnectionHandler = { conn in
        let c = Client(id: nextId, conn: conn)
        nextId += 1
        clients[c.id] = c
        conn.stateUpdateHandler = { st in
            switch st {
            case .failed, .cancelled: dropClient(c)
            default: break
            }
        }
        conn.start(queue: queue)
        receive(c)
    }
    l.stateUpdateHandler = { st in
        switch st {
        case .ready: log("listening on ws://\(host):\(port)")
        case .failed(let e): log("listener \(host) failed: \(e)"); exit(1)
        default: break
        }
    }
    l.start(queue: queue)
    return l
}

signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
term.setEventHandler {
    helper?.terminate()
    exit(0)
}
term.resume()
signal(SIGPIPE, SIG_IGN)

// Started on demand by vrclient: leave once no vrclient has been connected for idleGrace seconds.
let idleWatch = DispatchSource.makeTimerSource(queue: queue)
idleWatch.schedule(deadline: .now() + 1, repeating: 1)
idleWatch.setEventHandler {
    guard let since = idleSince, Date().timeIntervalSince(since) >= idleGrace else { return }
    log("idle for \(Int(idleGrace)) s, exiting")
    helper?.terminate()
    exit(0)
}
idleWatch.resume()

let listeners = [listen(host: "127.0.0.1"), listen(host: "::1")]
dispatchMain()
