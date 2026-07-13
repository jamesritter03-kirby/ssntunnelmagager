import Foundation

/// A saved MikroTik router the app can manage over the RouterOS REST API
/// (RouterOS v7+, the `/rest` endpoint). Credentials live in the Keychain,
/// keyed by `id`; only non-secret metadata is persisted to UserDefaults.
struct MikroTikRouter: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    /// Host or IP of the router's web/API service (no scheme).
    var host: String
    /// REST port. Defaults to 443 (https) or 80 (http) depending on `useHTTPS`.
    var port: Int
    var username: String
    /// Use HTTPS for the REST API. RouterOS often ships a self-signed cert, which
    /// we accept (see `MikroTikAPI`), so HTTPS works out of the box.
    var useHTTPS: Bool

    init(id: UUID = UUID(), name: String = "", host: String = "",
         port: Int = 443, username: String = "admin", useHTTPS: Bool = true) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.useHTTPS = useHTTPS
    }

    /// The base REST URL, e.g. "https://192.168.88.1:443/rest".
    var baseURL: String {
        let scheme = useHTTPS ? "https" : "http"
        return "\(scheme)://\(host):\(port)/rest"
    }

    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? (host.isEmpty ? "New Router" : host) : n
    }
}

/// A RouterOS interface (`/interface`).
struct MikroTikInterface: Identifiable, Hashable {
    let id: String
    var name: String
    var type: String
    var running: Bool
    var disabled: Bool
    var rxByte: Int?
    var txByte: Int?
    var macAddress: String?
    var comment: String?
}

/// A RouterOS IP address entry (`/ip/address`).
struct MikroTikAddress: Identifiable, Hashable {
    let id: String
    var address: String
    var network: String?
    var interface: String
    var disabled: Bool
}

/// A DHCP lease (`/ip/dhcp-server/lease`).
struct MikroTikLease: Identifiable, Hashable {
    let id: String
    var address: String
    var macAddress: String
    var hostName: String?
    var comment: String?
    var status: String?
    var dynamic: Bool
}

/// Router system health / identity (`/system/resource` + `/system/identity`).
struct MikroTikResource: Hashable {
    var identity: String?
    var boardName: String?
    var version: String?
    var uptime: String?
    var cpuLoad: Int?
    var freeMemory: Int?
    var totalMemory: Int?
    var architecture: String?

    var memoryUsedPercent: Int? {
        guard let total = totalMemory, total > 0, let free = freeMemory else { return nil }
        return Int(Double(total - free) / Double(total) * 100.0)
    }
}

enum MikroTikError: LocalizedError {
    case notConfigured
    case badURL
    case auth
    case http(Int)
    case transport(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "This router has no saved password. Edit it and enter one."
        case .badURL:        return "The router address is invalid."
        case .auth:          return "Login failed — check the username and password."
        case .http(let c):   return "Router API error (HTTP \(c))."
        case .transport(let m): return "Couldn’t reach the router: \(m)"
        case .decoding:      return "The router returned data the app couldn’t read."
        }
    }
}

/// Talks to one router's RouterOS REST API. Stateless apart from its config +
/// token; construct one per request batch. Accepts self-signed TLS via a
/// per-session delegate (RouterOS default certs are self-signed).
struct MikroTikAPI {
    let router: MikroTikRouter
    let password: String

    private var authHeader: String {
        let raw = "\(router.username):\(password)"
        let b64 = Data(raw.utf8).base64EncodedString()
        return "Basic \(b64)"
    }

    /// A URLSession that accepts the router's (usually self-signed) certificate.
    private var session: URLSession {
        URLSession(configuration: .ephemeral,
                   delegate: InsecureTLSDelegate(), delegateQueue: nil)
    }

    // MARK: Reads

    func resource() async throws -> MikroTikResource {
        var r = MikroTikResource()
        if let res: [String: JSONValue] = try? await getObject("/system/resource") {
            r.boardName = res["board-name"]?.stringValue
            r.version = res["version"]?.stringValue
            r.uptime = res["uptime"]?.stringValue
            r.cpuLoad = res["cpu-load"]?.intValue
            r.freeMemory = res["free-memory"]?.intValue
            r.totalMemory = res["total-memory"]?.intValue
            r.architecture = res["architecture-name"]?.stringValue
        }
        if let ident: [String: JSONValue] = try? await getObject("/system/identity") {
            r.identity = ident["name"]?.stringValue
        }
        return r
    }

    func interfaces() async throws -> [MikroTikInterface] {
        let rows: [[String: JSONValue]] = try await getArray("/interface")
        return rows.map { row in
            MikroTikInterface(
                id: row[".id"]?.stringValue ?? UUID().uuidString,
                name: row["name"]?.stringValue ?? "?",
                type: row["type"]?.stringValue ?? "",
                running: row["running"]?.boolValue ?? false,
                disabled: row["disabled"]?.boolValue ?? false,
                rxByte: row["rx-byte"]?.intValue,
                txByte: row["tx-byte"]?.intValue,
                macAddress: row["mac-address"]?.stringValue,
                comment: row["comment"]?.stringValue)
        }
    }

    func addresses() async throws -> [MikroTikAddress] {
        let rows: [[String: JSONValue]] = try await getArray("/ip/address")
        return rows.map { row in
            MikroTikAddress(
                id: row[".id"]?.stringValue ?? UUID().uuidString,
                address: row["address"]?.stringValue ?? "?",
                network: row["network"]?.stringValue,
                interface: row["interface"]?.stringValue ?? "",
                disabled: row["disabled"]?.boolValue ?? false)
        }
    }

    func leases() async throws -> [MikroTikLease] {
        let rows: [[String: JSONValue]] = try await getArray("/ip/dhcp-server/lease")
        return rows.map { row in
            MikroTikLease(
                id: row[".id"]?.stringValue ?? UUID().uuidString,
                address: row["address"]?.stringValue ?? "?",
                macAddress: row["mac-address"]?.stringValue ?? "",
                hostName: row["host-name"]?.stringValue,
                comment: row["comment"]?.stringValue,
                status: row["status"]?.stringValue,
                dynamic: row["dynamic"]?.boolValue ?? false)
        }
    }

    // MARK: Writes / actions

    /// Enable or disable an interface (`/interface/set`).
    func setInterfaceDisabled(_ id: String, disabled: Bool) async throws {
        try await post("/interface/set", body: [".id": id, "disabled": disabled ? "yes" : "no"])
    }

    /// Reboot the router (`/system/reboot`).
    func reboot() async throws {
        try await post("/system/reboot", body: [:])
    }

    /// Apply a RouterOS configuration script (the contents of a `.rsc` file, or
    /// any sequence of console commands). RouterOS has no file-upload REST
    /// endpoint, so this wraps the script's source in a temporary
    /// `/system/script`, runs it, then deletes it — which is equivalent to
    /// running `/import` on an uploaded file for command-style configs.
    func applyConfig(_ source: String) async throws {
        let name = "rs-apply-\(Int(Date().timeIntervalSince1970))"
        // Create the script and read back its assigned `.id`.
        let data = try await request("/system/script", method: "PUT", body: [
            "name": name,
            "source": source,
            "dont-require-permissions": "no",
        ])
        let created = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        let scriptID = created?[".id"]?.stringValue

        do {
            // Run by name (RouterOS `run` takes a `number` parameter).
            try await post("/system/script/run", body: ["number": name])
        } catch {
            // Best-effort cleanup even if the run failed, then surface the error.
            if let scriptID { _ = try? await request("/system/script/\(scriptID)", method: "DELETE", body: nil) }
            throw error
        }
        if let scriptID {
            _ = try? await request("/system/script/\(scriptID)", method: "DELETE", body: nil)
        }
    }

    /// Export the router's current configuration as a RouterOS script (`.rsc`
    /// text), equivalent to running `/export`. Returns the script source.
    func exportConfig() async throws -> String {
        let data = try await request("/export", method: "POST", body: [:])
        // RouterOS returns the export in a few shapes depending on version:
        // a single object {"output": "..."} , an array of such objects, or a
        // bare JSON string. Handle all three.
        let decoder = JSONDecoder()
        if let obj = try? decoder.decode([String: JSONValue].self, from: data),
           let out = obj["output"]?.stringValue ?? obj["ret"]?.stringValue {
            return out
        }
        if let arr = try? decoder.decode([[String: JSONValue]].self, from: data) {
            let joined = arr.compactMap { $0["output"]?.stringValue ?? $0["ret"]?.stringValue }
                .joined(separator: "\n")
            if !joined.isEmpty { return joined }
        }
        if let str = try? decoder.decode(String.self, from: data) { return str }
        if let raw = String(data: data, encoding: .utf8), !raw.isEmpty { return raw }
        throw MikroTikError.decoding
    }

    /// Create a binary backup file on the router (`/system/backup/save`). The
    /// file is written to the router's own storage; returns the file name.
    /// Binary backups can't be streamed out over REST, so this leaves the file
    /// on the device for download via WinBox/FTP.
    func createBackup(name: String) async throws -> String {
        try await post("/system/backup/save", body: ["name": name])
        return name + ".backup"
    }

    // MARK: - HTTP plumbing

    private func request(_ path: String, method: String, body: [String: Any]?) async throws -> Data {
        guard !password.isEmpty else { throw MikroTikError.notConfigured }
        guard let url = URL(string: router.baseURL + path) else { throw MikroTikError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw MikroTikError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw MikroTikError.decoding }
        if http.statusCode == 401 { throw MikroTikError.auth }
        guard (200..<300).contains(http.statusCode) else { throw MikroTikError.http(http.statusCode) }
        return data
    }

    private func getArray(_ path: String) async throws -> [[String: JSONValue]] {
        let data = try await request(path, method: "GET", body: nil)
        do {
            return try JSONDecoder().decode([[String: JSONValue]].self, from: data)
        } catch {
            throw MikroTikError.decoding
        }
    }

    private func getObject(_ path: String) async throws -> [String: JSONValue] {
        let data = try await request(path, method: "GET", body: nil)
        do {
            return try JSONDecoder().decode([String: JSONValue].self, from: data)
        } catch {
            throw MikroTikError.decoding
        }
    }

    private func post(_ path: String, body: [String: Any]) async throws {
        _ = try await request(path, method: "POST", body: body)
    }

    // MARK: Generic RouterOS REST (for the WinBox-style config explorer)

    /// List a menu (`ip/address`, `ip/firewall/filter`, …). Handles both the
    /// array responses (most menus) and single-object responses (settings menus
    /// like `ip/dns`), which are wrapped in a one-element array.
    func listRaw(_ menuPath: String) async throws -> [[String: JSONValue]] {
        let data = try await request("/" + menuPath, method: "GET", body: nil)
        if let arr = try? JSONDecoder().decode([[String: JSONValue]].self, from: data) {
            return arr
        }
        if let obj = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            return [obj]
        }
        throw MikroTikError.decoding
    }

    /// Create a new entry in a menu (`PUT /rest/{menu}`).
    func createRaw(_ menuPath: String, fields: [String: Any]) async throws {
        _ = try await request("/" + menuPath, method: "PUT", body: fields)
    }

    /// Update an entry (`PATCH /rest/{menu}/{.id}`). For settings menus with no
    /// per-row id, pass an empty `id` to patch the menu itself.
    func updateRaw(_ menuPath: String, id: String, fields: [String: Any]) async throws {
        let path: String
        if id.isEmpty {
            path = "/" + menuPath
        } else {
            let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
            path = "/\(menuPath)/\(enc)"
        }
        _ = try await request(path, method: "PATCH", body: fields)
    }

    /// Delete an entry (`DELETE /rest/{menu}/{.id}`).
    func removeRaw(_ menuPath: String, id: String) async throws {
        let enc = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        _ = try await request("/\(menuPath)/\(enc)", method: "DELETE", body: nil)
    }
}

/// Accepts self-signed TLS certificates (RouterOS default). Scoped to the
/// ephemeral session used only for router API calls, so this never affects the
/// app's other (validated) HTTPS traffic.
private final class InsecureTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

/// A minimal JSON value decoder — RouterOS returns every field as a string, but
/// this tolerates numbers/bools too, and exposes typed accessors.
enum JSONValue: Decodable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { self = .null }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        case .null: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return s == "true" || s == "yes"
        default: return nil
        }
    }
}

/// One editable field in a config menu's add/edit form.
struct MikroTikField: Hashable {
    enum Kind: Hashable { case text, number, bool }
    var key: String
    var label: String
    var kind: Kind = .text
    var placeholder: String = ""
    /// Fixed set of choices, when the field is really an enum.
    var choices: [String] = []
}

/// A WinBox-style configuration menu, mapped onto a RouterOS REST path.
struct MikroTikMenu: Identifiable, Hashable {
    var id: String { path }
    var group: String            // e.g. "IP", "System"
    var title: String            // e.g. "Addresses"
    var icon: String
    var path: String             // REST path, e.g. "ip/address"
    /// Field keys shown as columns in the list.
    var columns: [String]
    /// Fields offered when adding a new entry.
    var addFields: [MikroTikField]
    /// A settings menu (single object) rather than a list of rows.
    var isSingleton: Bool = false
    /// Whether the user can add / delete rows (false for read-only menus).
    var editable: Bool = true

    static let catalog: [MikroTikMenu] = MikroTikMenu.buildCatalog()
}

/// One row returned from a config menu: its RouterOS `.id` plus every field as a
/// string (RouterOS returns everything stringy anyway).
struct MikroTikEntry: Identifiable, Hashable {
    let id: String
    var fields: [String: String]

    var disabled: Bool { fields["disabled"] == "true" }
    var comment: String { fields["comment"] ?? "" }

    func value(_ key: String) -> String { fields[key] ?? "" }

    /// A short label for the row, best-effort across menu types.
    func title(columns: [String]) -> String {
        for k in ["name", "address", "target", "dst-address", "chain", "list", "server", "interface"] {
            if let v = fields[k], !v.isEmpty { return v }
        }
        if let first = columns.first, let v = fields[first], !v.isEmpty { return v }
        return id
    }
}

/// A MikroTik device found on the local network via MNDP (MikroTik Neighbor
/// Discovery Protocol). This is broadcast, unauthenticated info — enough to
/// pre-fill the “Add Router” form.
struct DiscoveredRouter: Identifiable, Hashable {
    var id: String { macAddress }
    var macAddress: String
    var identity: String?
    var board: String?
    var version: String?
    var platform: String?
    var ipv4: String?
    var interfaceName: String?
    var uptimeSeconds: Int?

    /// A friendly display name for the discovered device.
    var displayName: String {
        if let i = identity, !i.isEmpty { return i }
        if let ip = ipv4 { return ip }
        return macAddress
    }

    /// The best host string to use when saving this router (IP if known).
    var suggestedHost: String { ipv4 ?? "" }
}

/// Manages the saved list of MikroTik routers and their live, per-router data.
/// A singleton shared by the Network browser. Router metadata persists to
/// UserDefaults; passwords live in the Keychain.
@MainActor
final class MikroTikStore: ObservableObject {
    static let shared = MikroTikStore()

    @Published private(set) var routers: [MikroTikRouter] = []
    @Published private(set) var resources: [UUID: MikroTikResource] = [:]
    @Published private(set) var interfaces: [UUID: [MikroTikInterface]] = [:]
    @Published private(set) var addresses: [UUID: [MikroTikAddress]] = [:]
    @Published private(set) var leases: [UUID: [MikroTikLease]] = [:]
    @Published private(set) var loading: Set<UUID> = []
    @Published var errors: [UUID: String] = [:]

    /// MikroTik devices found on the LAN that aren’t already saved.
    @Published private(set) var discovered: [DiscoveredRouter] = []
    @Published private(set) var isDiscovering = false
    /// Generic config-menu rows, keyed by "routerID|menuPath".
    @Published private(set) var menuEntries: [String: [MikroTikEntry]] = [:]
    @Published private(set) var menuLoading: Set<String> = []
    @Published var menuErrors: [String: String] = [:]
    private let storeKey = "mikrotik.routers.v1"

    private init() { load() }

    var hasRouters: Bool { !routers.isEmpty }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let list = try? JSONDecoder().decode([MikroTikRouter].self, from: data) else { return }
        routers = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(routers) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    func password(for id: UUID) -> String? {
        KeychainStore.shared.mikroTikPassword(for: id)
    }

    // MARK: Router CRUD

    @discardableResult
    func addRouter(_ router: MikroTikRouter, password: String) -> Bool {
        guard !router.host.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        routers.append(router)
        if !password.isEmpty { _ = KeychainStore.shared.setMikroTikPassword(password, for: router.id) }
        save()
        Task { await refresh(router) }
        return true
    }

    func updateRouter(_ router: MikroTikRouter, password: String?) {
        guard let idx = routers.firstIndex(where: { $0.id == router.id }) else { return }
        routers[idx] = router
        if let password, !password.isEmpty {
            _ = KeychainStore.shared.setMikroTikPassword(password, for: router.id)
        }
        save()
        Task { await refresh(router) }
    }

    func removeRouter(_ id: UUID) {
        KeychainStore.shared.deleteMikroTikPassword(for: id)
        routers.removeAll { $0.id == id }
        resources[id] = nil
        interfaces[id] = nil
        addresses[id] = nil
        leases[id] = nil
        errors[id] = nil
        save()
    }

    // MARK: Live data

    /// Fetch resource + interfaces + addresses + leases for one router.
    func refresh(_ router: MikroTikRouter) async {
        guard let pw = password(for: router.id), !pw.isEmpty else {
            errors[router.id] = MikroTikError.notConfigured.errorDescription
            return
        }
        loading.insert(router.id)
        errors[router.id] = nil
        defer { loading.remove(router.id) }

        let api = MikroTikAPI(router: router, password: pw)
        do {
            async let res = api.resource()
            async let ifs = api.interfaces()
            async let addr = api.addresses()
            async let lease = api.leases()
            let (r, i, a, l) = try await (res, ifs, addr, lease)
            resources[router.id] = r
            interfaces[router.id] = i
            addresses[router.id] = a
            leases[router.id] = l.sorted { $0.address.compare($1.address, options: .numeric) == .orderedAscending }
        } catch {
            errors[router.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Toggle an interface enabled/disabled, then refresh that router.
    func setInterface(_ router: MikroTikRouter, interfaceID: String, disabled: Bool) async {
        guard let pw = password(for: router.id), !pw.isEmpty else { return }
        let api = MikroTikAPI(router: router, password: pw)
        do {
            try await api.setInterfaceDisabled(interfaceID, disabled: disabled)
            await refresh(router)
        } catch {
            errors[router.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Reboot a router.
    func reboot(_ router: MikroTikRouter) async {
        guard let pw = password(for: router.id), !pw.isEmpty else { return }
        let api = MikroTikAPI(router: router, password: pw)
        do {
            try await api.reboot()
            errors[router.id] = nil
        } catch {
            errors[router.id] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Apply a `.rsc`/console configuration script to a router. Throws so the
    /// caller (the config view) can report success or the exact failure.
    func applyConfig(_ router: MikroTikRouter, source: String) async throws {
        guard let pw = password(for: router.id), !pw.isEmpty else {
            throw MikroTikError.notConfigured
        }
        let api = MikroTikAPI(router: router, password: pw)
        try await api.applyConfig(source)
        errors[router.id] = nil
    }

    /// Export a router's configuration as `.rsc` script text.
    func exportConfig(_ router: MikroTikRouter) async throws -> String {
        guard let pw = password(for: router.id), !pw.isEmpty else {
            throw MikroTikError.notConfigured
        }
        let api = MikroTikAPI(router: router, password: pw)
        let text = try await api.exportConfig()
        errors[router.id] = nil
        return text
    }

    /// Create a binary backup file on a router; returns its file name.
    func createBackup(_ router: MikroTikRouter, name: String) async throws -> String {
        guard let pw = password(for: router.id), !pw.isEmpty else {
            throw MikroTikError.notConfigured
        }
        let api = MikroTikAPI(router: router, password: pw)
        let file = try await api.createBackup(name: name)
        errors[router.id] = nil
        return file
    }

    // MARK: - Generic config menus (WinBox-style)

    func menuKey(_ router: MikroTikRouter, _ path: String) -> String {
        "\(router.id.uuidString)|\(path)"
    }

    func entries(_ router: MikroTikRouter, _ path: String) -> [MikroTikEntry] {
        menuEntries[menuKey(router, path)] ?? []
    }

    func isMenuLoading(_ router: MikroTikRouter, _ path: String) -> Bool {
        menuLoading.contains(menuKey(router, path))
    }

    func menuError(_ router: MikroTikRouter, _ path: String) -> String? {
        menuErrors[menuKey(router, path)]
    }

    private func api(for router: MikroTikRouter) -> MikroTikAPI? {
        guard let pw = password(for: router.id), !pw.isEmpty else { return nil }
        return MikroTikAPI(router: router, password: pw)
    }

    /// Load (or reload) all rows of one config menu.
    func loadMenu(_ router: MikroTikRouter, _ menu: MikroTikMenu) async {
        let key = menuKey(router, menu.path)
        guard let api = api(for: router) else {
            menuErrors[key] = MikroTikError.notConfigured.errorDescription
            return
        }
        menuLoading.insert(key)
        menuErrors[key] = nil
        defer { menuLoading.remove(key) }
        do {
            let rows = try await api.listRaw(menu.path)
            menuEntries[key] = rows.map { row in
                var f: [String: String] = [:]
                for (k, v) in row where k != ".id" { f[k] = v.stringValue }
                return MikroTikEntry(id: row[".id"]?.stringValue ?? "", fields: f)
            }
        } catch {
            menuErrors[key] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Add a new entry to a menu, then reload it.
    func addEntry(_ router: MikroTikRouter, _ menu: MikroTikMenu, fields: [String: String]) async {
        let key = menuKey(router, menu.path)
        guard let api = api(for: router) else { return }
        do {
            try await api.createRaw(menu.path, fields: fields)
            await loadMenu(router, menu)
        } catch {
            menuErrors[key] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Patch an existing entry (or a settings menu when `id` is empty).
    func updateEntry(_ router: MikroTikRouter, _ menu: MikroTikMenu, id: String, fields: [String: String]) async {
        let key = menuKey(router, menu.path)
        guard let api = api(for: router) else { return }
        do {
            try await api.updateRaw(menu.path, id: id, fields: fields)
            await loadMenu(router, menu)
        } catch {
            menuErrors[key] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Delete an entry, then reload the menu.
    func removeEntry(_ router: MikroTikRouter, _ menu: MikroTikMenu, id: String) async {
        let key = menuKey(router, menu.path)
        guard let api = api(for: router) else { return }
        do {
            try await api.removeRaw(menu.path, id: id)
            await loadMenu(router, menu)
        } catch {
            menuErrors[key] = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Toggle an entry's enabled/disabled flag.
    func setEntryDisabled(_ router: MikroTikRouter, _ menu: MikroTikMenu, id: String, disabled: Bool) async {
        await updateEntry(router, menu, id: id, fields: ["disabled": disabled ? "true" : "false"])
    }

    // MARK: - Auto-discovery (MNDP)

    /// Whether a discovered device is already one of the saved routers (matched
    /// by IP address).
    func isSaved(_ device: DiscoveredRouter) -> Bool {
        guard let ip = device.ipv4 else { return false }
        return routers.contains { $0.host == ip }
    }

    /// Scan the local network for MikroTik devices using MNDP (UDP 5678) and
    /// publish any that aren't already saved. Safe to call repeatedly (e.g. on
    /// every refresh); it de-dupes by MAC address.
    ///
    /// MNDP is a link-local broadcast protocol, so it only finds routers on the
    /// directly-attached subnets. To also surface routers reachable over
    /// ZeroTier (a routed L3 overlay where MNDP usually won't propagate), this
    /// additionally probes the ZeroTier member IPs the app already knows about
    /// for an open WinBox/API port, which is a reliable MikroTik fingerprint.
    func discover() async {
        if isDiscovering { return }
        isDiscovering = true
        defer { isDiscovering = false }

        // Collect ZeroTier member IPs (label them by member name where known)
        // before hopping off the main actor for the network work.
        let ztCandidates = zeroTierCandidates()

        async let mndp = Self.runDiscovery(timeout: 3.0)
        async let overlay = Self.probeRouters(ztCandidates, timeout: 1.2)
        let (found, probed) = await (mndp, overlay)

        // Merge MNDP results (keyed by MAC) with overlay probe results (keyed by
        // IP). Prefer richer MNDP data when the same IP shows up in both.
        var byIP: [String: DiscoveredRouter] = [:]
        for d in probed { if let ip = d.ipv4 { byIP[ip] = d } }
        for d in found { if let ip = d.ipv4 { byIP[ip] = d } }
        let ipless = found.filter { $0.ipv4 == nil }

        let all = Array(byIP.values) + ipless
        // Keep only devices we haven't saved yet.
        discovered = all.filter { device in
            guard let ip = device.ipv4 else { return true }
            return !routers.contains { $0.host == ip }
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Gather candidate (IP, label) pairs from every known ZeroTier member,
    /// excluding IPs already saved as routers. Strips any CIDR suffix.
    private func zeroTierCandidates() -> [(ip: String, label: String?)] {
        var seen = Set<String>()
        var out: [(String, String?)] = []
        for members in ZeroTierStore.shared.membersByNetwork.values {
            for member in members {
                let label = member.name.trimmingCharacters(in: .whitespaces)
                for raw in member.ipAssignments {
                    let ip = raw.split(separator: "/").first.map(String.init) ?? raw
                    guard ip.contains("."), seen.insert(ip).inserted else { continue }
                    if routers.contains(where: { $0.host == ip }) { continue }
                    out.append((ip, label.isEmpty ? nil : label))
                }
            }
        }
        return out
    }

    // MARK: - MNDP socket service (runs off the main actor)

    /// Broadcast an MNDP discovery request and collect replies for `timeout`
    /// seconds. Uses a plain UDP socket (the app isn't sandboxed, so no special
    /// entitlement is needed). Never throws — returns whatever it finds.
    nonisolated static func runDiscovery(timeout: TimeInterval) async -> [DiscoveredRouter] {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: blockingDiscovery(timeout: timeout))
            }
        }
    }

    // MARK: - Overlay (ZeroTier) probing

    /// The MikroTik-specific service ports we look for. WinBox (8291) is the
    /// strongest fingerprint; the API and API-SSL ports also indicate RouterOS.
    private nonisolated static let routerFingerprintPorts: [UInt16] = [8291, 8728, 8729]

    /// Probe each candidate IP for an open MikroTik service port and return a
    /// `DiscoveredRouter` for the ones that respond. Runs the probes concurrently
    /// with a bounded degree of parallelism so large ZeroTier networks stay fast.
    nonisolated static func probeRouters(_ candidates: [(ip: String, label: String?)],
                                         timeout: TimeInterval) async -> [DiscoveredRouter] {
        guard !candidates.isEmpty else { return [] }
        return await withTaskGroup(of: DiscoveredRouter?.self) { group in
            let maxConcurrent = 24
            var index = 0
            func addProbe(_ c: (ip: String, label: String?)) {
                group.addTask {
                    for port in routerFingerprintPorts {
                        if tcpConnectSucceeds(host: c.ip, port: port, timeout: timeout) {
                            return DiscoveredRouter(
                                macAddress: "zt:\(c.ip)",
                                identity: c.label,
                                board: nil, version: nil,
                                platform: "MikroTik", ipv4: c.ip,
                                interfaceName: "ZeroTier", uptimeSeconds: nil)
                        }
                    }
                    return nil
                }
            }
            while index < candidates.count && index < maxConcurrent {
                addProbe(candidates[index]); index += 1
            }
            var results: [DiscoveredRouter] = []
            while let done = await group.next() {
                if let r = done { results.append(r) }
                if index < candidates.count { addProbe(candidates[index]); index += 1 }
            }
            return results
        }
    }

    /// Attempt a non-blocking TCP connect to `host:port`, returning whether it
    /// succeeds within `timeout`. Never blocks longer than the timeout.
    private nonisolated static func tcpConnectSucceeds(host: String, port: UInt16,
                                                       timeout: TimeInterval) -> Bool {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // Non-blocking so we can bound the connect with select().
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }               // connected immediately
        if errno != EINPROGRESS { return false } // real error

        // Bound the in-progress connect with poll().
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(max(1, timeout * 1000))
        let sel = poll(&pfd, 1, ms)
        guard sel > 0 else { return false }      // timed out or error

        // Connect finished — check for a socket-level error.
        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len)
        return soErr == 0
    }

    /// Enumerate the directed broadcast address of every active IPv4 interface
    /// (`addr | ~netmask`), so discovery can reach each attached subnet rather
    /// than only the default one. Skips loopback and non-broadcast interfaces.
    private nonisolated static func broadcastAddresses() -> [String] {
        var results = Set<String>()
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0 else { return [] }
        defer { freeifaddrs(ifap) }
        var ptr = ifap
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  flags & IFF_BROADCAST != 0,
                  let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let mask = cur.pointee.ifa_netmask else { continue }

            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            let nm = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_addr.s_addr
            }
            // Directed broadcast = network bits + all-ones host bits.
            let bcast = in_addr(s_addr: ip | ~nm)
            let str = String(cString: inet_ntoa(bcast))
            if !str.isEmpty, str != "0.0.0.0" { results.insert(str) }
        }
        return Array(results)
    }

    private nonisolated static func blockingDiscovery(timeout: TimeInterval) -> [DiscoveredRouter] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        var yes: Int32 = 1
        let optLen = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, optLen)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, optLen)
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, optLen)

        // A short per-recv timeout so the loop wakes up to check the deadline.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Bind to 0.0.0.0:5678 so we receive broadcast replies.
        var bindAddr = sockaddr_in()
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = in_port_t(5678).bigEndian
        bindAddr.sin_addr.s_addr = INADDR_ANY
        _ = withUnsafePointer(to: &bindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        // Send the discovery request (4 zero bytes) to the broadcast address.
        var dst = sockaddr_in()
        dst.sin_family = sa_family_t(AF_INET)
        dst.sin_port = in_port_t(5678).bigEndian
        inet_pton(AF_INET, "255.255.255.255", &dst.sin_addr)
        let request: [UInt8] = [0, 0, 0, 0]
        _ = withUnsafePointer(to: &dst) { dptr in
            dptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                request.withUnsafeBytes { rb in
                    sendto(fd, rb.baseAddress, rb.count, 0, sa,
                           socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        // Also send to every interface's directed broadcast address so we reach
        // subnets beyond the default one (Ethernet, Wi-Fi, VLANs, VPNs, etc.).
        for bcast in broadcastAddresses() {
            var ba = sockaddr_in()
            ba.sin_family = sa_family_t(AF_INET)
            ba.sin_port = in_port_t(5678).bigEndian
            inet_pton(AF_INET, bcast, &ba.sin_addr)
            _ = withUnsafePointer(to: &ba) { dptr in
                dptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    request.withUnsafeBytes { rb in
                        sendto(fd, rb.baseAddress, rb.count, 0, sa,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        // Collect replies until the deadline, de-duped by MAC.
        let deadline = Date().addingTimeInterval(timeout)
        var results: [String: DiscoveredRouter] = [:]
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) { fptr in
                fptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(fd, &buf, buf.count, 0, sa, &fromLen)
                }
            }
            if n <= 4 { continue }   // timeout (EAGAIN) or empty header
            if var device = parseMNDP(Array(buf[0..<n])) {
                if device.ipv4 == nil {
                    device.ipv4 = String(cString: inet_ntoa(from.sin_addr))
                }
                results[device.macAddress] = device
            }
        }
        return results.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    /// Parse an MNDP reply packet: a 4-byte header followed by big-endian
    /// type/length/value triplets. Field numbers follow the MikroTik / MAC-Telnet
    /// convention.
    private nonisolated static func parseMNDP(_ data: [UInt8]) -> DiscoveredRouter? {
        guard data.count > 4 else { return nil }
        func u16(_ o: Int) -> Int { (Int(data[o]) << 8) | Int(data[o + 1]) }

        var mac: String?
        var identity, version, platform, board, iface: String?
        var ipv4: String?
        var uptime: Int?

        var i = 4
        while i + 4 <= data.count {
            let type = u16(i)
            let len = u16(i + 2)
            i += 4
            guard len >= 0, i + len <= data.count else { break }
            let val = Array(data[i..<i + len])
            i += len
            switch type {
            case 1:  // MAC address
                if val.count == 6 {
                    mac = val.map { String(format: "%02X", $0) }.joined(separator: ":")
                }
            case 5:  identity = String(bytes: val, encoding: .utf8)
            case 7:  version = String(bytes: val, encoding: .utf8)
            case 8:  platform = String(bytes: val, encoding: .utf8)
            case 10: // uptime (little-endian uint32)
                if val.count == 4 {
                    uptime = Int(val[0]) | (Int(val[1]) << 8) | (Int(val[2]) << 16) | (Int(val[3]) << 24)
                }
            case 12: board = String(bytes: val, encoding: .utf8)
            case 16: iface = String(bytes: val, encoding: .utf8)
            case 17: // IPv4 address
                if val.count == 4 {
                    ipv4 = "\(val[0]).\(val[1]).\(val[2]).\(val[3])"
                }
            default: break
            }
        }

        guard let mac else { return nil }
        return DiscoveredRouter(macAddress: mac, identity: identity, board: board,
                                version: version, platform: platform, ipv4: ipv4,
                                interfaceName: iface, uptimeSeconds: uptime)
    }
}

// MARK: - Config menu catalog

extension MikroTikMenu {
    /// A curated set of common WinBox menus mapped to RouterOS REST paths. Each
    /// lists the columns to show and the fields offered when adding a row. The
    /// edit form additionally shows every field the router returns, so anything
    /// not listed here is still editable — this catalog just drives discovery,
    /// column layout and sensible "add" defaults.
    static func buildCatalog() -> [MikroTikMenu] {
        func f(_ key: String, _ label: String, _ kind: MikroTikField.Kind = .text,
               _ placeholder: String = "", _ choices: [String] = []) -> MikroTikField {
            MikroTikField(key: key, label: label, kind: kind, placeholder: placeholder, choices: choices)
        }

        return [
            // Interfaces
            MikroTikMenu(group: "Interfaces", title: "Interface List", icon: "cable.connector",
                path: "interface", columns: ["name", "type", "running", "actual-mtu"],
                addFields: [f("name", "Name"), f("comment", "Comment")], editable: false),
            MikroTikMenu(group: "Interfaces", title: "Bridge", icon: "square.split.2x2",
                path: "interface/bridge", columns: ["name", "protocol-mode", "vlan-filtering"],
                addFields: [f("name", "Name", .text, "bridge1"),
                            f("vlan-filtering", "VLAN Filtering", .bool),
                            f("comment", "Comment")]),
            MikroTikMenu(group: "Interfaces", title: "Bridge Ports", icon: "square.stack.3d.up",
                path: "interface/bridge/port", columns: ["interface", "bridge", "pvid"],
                addFields: [f("interface", "Interface"), f("bridge", "Bridge", .text, "bridge1"),
                            f("pvid", "PVID", .number, "1")]),
            MikroTikMenu(group: "Interfaces", title: "VLAN", icon: "rectangle.split.3x1",
                path: "interface/vlan", columns: ["name", "vlan-id", "interface"],
                addFields: [f("name", "Name", .text, "vlan10"),
                            f("vlan-id", "VLAN ID", .number, "10"),
                            f("interface", "Interface", .text, "bridge")]),
            MikroTikMenu(group: "Interfaces", title: "List Members", icon: "list.bullet.rectangle",
                path: "interface/list/member", columns: ["list", "interface"],
                addFields: [f("list", "List", .text, "LAN"), f("interface", "Interface")]),

            // Wireless (RouterOS v7 "wifi" and legacy "wireless" both tried by the UI)
            MikroTikMenu(group: "Wireless", title: "WiFi", icon: "wifi",
                path: "interface/wifi", columns: ["name", "configuration.ssid", "disabled"],
                addFields: [f("name", "Name"), f("comment", "Comment")], editable: false),

            // IP
            MikroTikMenu(group: "IP", title: "Addresses", icon: "number",
                path: "ip/address", columns: ["address", "network", "interface"],
                addFields: [f("address", "Address", .text, "192.168.88.1/24"),
                            f("interface", "Interface", .text, "bridge"),
                            f("comment", "Comment")]),
            MikroTikMenu(group: "IP", title: "ARP", icon: "arrow.left.arrow.right",
                path: "ip/arp", columns: ["address", "mac-address", "interface"],
                addFields: [f("address", "Address"), f("mac-address", "MAC Address"),
                            f("interface", "Interface")]),
            MikroTikMenu(group: "IP", title: "DHCP Server", icon: "server.rack",
                path: "ip/dhcp-server", columns: ["name", "interface", "address-pool", "lease-time"],
                addFields: [f("name", "Name", .text, "dhcp1"),
                            f("interface", "Interface", .text, "bridge"),
                            f("address-pool", "Address Pool", .text, "dhcp"),
                            f("lease-time", "Lease Time", .text, "10m")]),
            MikroTikMenu(group: "IP", title: "DHCP Networks", icon: "point.3.connected.trianglepath.dotted",
                path: "ip/dhcp-server/network", columns: ["address", "gateway", "dns-server"],
                addFields: [f("address", "Address", .text, "192.168.88.0/24"),
                            f("gateway", "Gateway", .text, "192.168.88.1"),
                            f("dns-server", "DNS Server", .text, "192.168.88.1")]),
            MikroTikMenu(group: "IP", title: "DHCP Leases", icon: "person.crop.rectangle.stack",
                path: "ip/dhcp-server/lease", columns: ["address", "mac-address", "host-name", "status"],
                addFields: [f("address", "Address"), f("mac-address", "MAC Address"),
                            f("server", "Server", .text, "dhcp1"), f("comment", "Comment")]),
            MikroTikMenu(group: "IP", title: "DHCP Client", icon: "arrow.down.circle",
                path: "ip/dhcp-client", columns: ["interface", "status", "address"],
                addFields: [f("interface", "Interface"),
                            f("add-default-route", "Add Default Route", .bool),
                            f("use-peer-dns", "Use Peer DNS", .bool)]),
            MikroTikMenu(group: "IP", title: "DNS", icon: "globe",
                path: "ip/dns", columns: ["servers", "allow-remote-requests"],
                addFields: [f("servers", "Servers", .text, "1.1.1.1,8.8.8.8"),
                            f("allow-remote-requests", "Allow Remote Requests", .bool)],
                isSingleton: true),
            MikroTikMenu(group: "IP", title: "DNS Static", icon: "text.book.closed",
                path: "ip/dns/static", columns: ["name", "address", "type", "ttl"],
                addFields: [f("name", "Name"), f("address", "Address"),
                            f("ttl", "TTL", .text, "1d")]),
            MikroTikMenu(group: "IP", title: "Routes", icon: "arrow.triangle.branch",
                path: "ip/route", columns: ["dst-address", "gateway", "distance", "active"],
                addFields: [f("dst-address", "Dst. Address", .text, "0.0.0.0/0"),
                            f("gateway", "Gateway"),
                            f("distance", "Distance", .number, "1")]),
            MikroTikMenu(group: "IP", title: "Pool", icon: "tray.full",
                path: "ip/pool", columns: ["name", "ranges"],
                addFields: [f("name", "Name", .text, "dhcp"),
                            f("ranges", "Ranges", .text, "192.168.88.10-192.168.88.254")]),
            MikroTikMenu(group: "IP", title: "Cloud (DDNS)", icon: "cloud",
                path: "ip/cloud", columns: ["ddns-enabled", "dns-name", "public-address"],
                addFields: [f("ddns-enabled", "DDNS Enabled", .bool)], isSingleton: true),
            MikroTikMenu(group: "IP", title: "Services", icon: "switch.2",
                path: "ip/service", columns: ["name", "port", "disabled"],
                addFields: [], editable: false),
            MikroTikMenu(group: "IP", title: "Neighbors", icon: "dot.radiowaves.left.and.right",
                path: "ip/neighbor", columns: ["address", "identity", "interface", "mac-address"],
                addFields: [], editable: false),

            // Firewall
            MikroTikMenu(group: "Firewall", title: "Filter Rules", icon: "shield.lefthalf.filled",
                path: "ip/firewall/filter", columns: ["chain", "action", "src-address", "dst-address"],
                addFields: [f("chain", "Chain", .text, "forward", ["input", "forward", "output"]),
                            f("action", "Action", .text, "accept",
                              ["accept", "drop", "reject", "log", "fasttrack-connection"]),
                            f("src-address", "Src. Address"),
                            f("dst-address", "Dst. Address"),
                            f("protocol", "Protocol", .text, "", ["tcp", "udp", "icmp"]),
                            f("comment", "Comment")]),
            MikroTikMenu(group: "Firewall", title: "NAT", icon: "arrow.uturn.right",
                path: "ip/firewall/nat", columns: ["chain", "action", "src-address", "to-addresses"],
                addFields: [f("chain", "Chain", .text, "srcnat", ["srcnat", "dstnat"]),
                            f("action", "Action", .text, "masquerade",
                              ["masquerade", "src-nat", "dst-nat", "redirect", "accept"]),
                            f("out-interface", "Out Interface"),
                            f("to-addresses", "To Addresses"),
                            f("comment", "Comment")]),
            MikroTikMenu(group: "Firewall", title: "Mangle", icon: "slider.horizontal.3",
                path: "ip/firewall/mangle", columns: ["chain", "action", "new-packet-mark"],
                addFields: [f("chain", "Chain", .text, "prerouting"),
                            f("action", "Action", .text, "mark-packet"),
                            f("comment", "Comment")]),
            MikroTikMenu(group: "Firewall", title: "Address Lists", icon: "list.bullet.rectangle.portrait",
                path: "ip/firewall/address-list", columns: ["list", "address", "timeout"],
                addFields: [f("list", "List"), f("address", "Address"),
                            f("comment", "Comment")]),

            // Queues
            MikroTikMenu(group: "Queues", title: "Simple Queues", icon: "gauge.with.dots.needle.bottom.50percent",
                path: "queue/simple", columns: ["name", "target", "max-limit"],
                addFields: [f("name", "Name"), f("target", "Target", .text, "192.168.88.0/24"),
                            f("max-limit", "Max Limit", .text, "10M/10M")]),

            // System
            MikroTikMenu(group: "System", title: "Identity", icon: "tag",
                path: "system/identity", columns: ["name"],
                addFields: [f("name", "Name")], isSingleton: true),
            MikroTikMenu(group: "System", title: "Clock", icon: "clock",
                path: "system/clock", columns: ["time", "date", "time-zone-name"],
                addFields: [f("time-zone-name", "Time Zone", .text, "America/New_York")],
                isSingleton: true),
            MikroTikMenu(group: "System", title: "NTP Client", icon: "clock.arrow.2.circlepath",
                path: "system/ntp/client", columns: ["enabled", "servers", "status"],
                addFields: [f("enabled", "Enabled", .bool),
                            f("servers", "Servers", .text, "pool.ntp.org")], isSingleton: true),
            MikroTikMenu(group: "System", title: "Users", icon: "person.2",
                path: "user", columns: ["name", "group", "disabled"],
                addFields: [f("name", "Name"), f("group", "Group", .text, "full",
                              ["full", "read", "write"]),
                            f("password", "Password")]),
            MikroTikMenu(group: "System", title: "Packages", icon: "shippingbox",
                path: "system/package", columns: ["name", "version", "disabled"],
                addFields: [], editable: false),
            MikroTikMenu(group: "System", title: "Scheduler", icon: "calendar.badge.clock",
                path: "system/scheduler", columns: ["name", "interval", "next-run"],
                addFields: [f("name", "Name"), f("interval", "Interval", .text, "1d"),
                            f("on-event", "On Event")]),
            MikroTikMenu(group: "System", title: "Scripts", icon: "curlybraces",
                path: "system/script", columns: ["name", "run-count"],
                addFields: [f("name", "Name"), f("source", "Source")]),
            MikroTikMenu(group: "System", title: "Logs", icon: "doc.text",
                path: "log", columns: ["time", "topics", "message"],
                addFields: [], editable: false),
        ]
    }
}

