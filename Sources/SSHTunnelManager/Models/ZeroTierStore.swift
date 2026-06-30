import Foundation
import SwiftUI

// MARK: - Models

/// One ZeroTier network the account can see (from `GET /api/v1/network`).
///
/// **ZeroTier Central** wraps most fields under `config` and exposes member
/// counts at the top level; **self-hosted controllers (ZTNET)** return a
/// flattened object (`nwid`, top-level `name`/`routes`, `memberCount`). The
/// decoder accepts either shape.
struct ZeroTierNetwork: Identifiable, Decodable, Hashable {
    let id: String
    var name: String
    var description: String
    var onlineMemberCount: Int?
    var authorizedMemberCount: Int?
    var totalMemberCount: Int?
    /// The managed routes (e.g. `10.147.20.0/24`) advertised on this network.
    var routes: [String]
    /// Which added account this network came from (set after fetch, not decoded).
    var accountId: UUID?
    /// For self-hosted (ZTNET) **organization** tokens, the org this network
    /// belongs to — its members live under `/org/{orgId}/…` (set after fetch).
    var orgId: String?

    /// A display name that falls back to the raw network id when unnamed.
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? id : n
    }

    enum CodingKeys: String, CodingKey {
        case id, nwid, config, description, name, routes
        case onlineMemberCount, authorizedMemberCount, totalMemberCount, memberCount
    }
    private enum ConfigKeys: String, CodingKey {
        case name, routes
    }
    private struct Route: Codable { var target: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = nil
        orgId = nil
        id = (try? c.decodeIfPresent(String.self, forKey: .id))?.flatMap { $0 }
            ?? (try? c.decodeIfPresent(String.self, forKey: .nwid)) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        onlineMemberCount = try? c.decodeIfPresent(Int.self, forKey: .onlineMemberCount) ?? nil
        authorizedMemberCount = try? c.decodeIfPresent(Int.self, forKey: .authorizedMemberCount) ?? nil
        totalMemberCount = (try? c.decode(Int.self, forKey: .totalMemberCount))
            ?? (try? c.decode(Int.self, forKey: .memberCount))

        // Central nests name/routes under `config`; ZTNET returns them flat.
        var resolvedName = (try? c.decode(String.self, forKey: .name)) ?? ""
        var resolvedRoutes = (try? c.decode([Route].self, forKey: .routes)) ?? []
        if let cfg = try? c.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config) {
            if resolvedName.isEmpty {
                resolvedName = (try? cfg.decodeIfPresent(String.self, forKey: .name)) ?? ""
            }
            if resolvedRoutes.isEmpty {
                resolvedRoutes = (try? cfg.decode([Route].self, forKey: .routes)) ?? []
            }
        }
        name = resolvedName
        routes = resolvedRoutes.compactMap { $0.target }
    }
}

/// One device (member node) on a ZeroTier network (from
/// `GET /api/v1/network/{id}/member`).
///
/// **Central** nests `ipAssignments` / `authorized` under `config` and names the
/// node `nodeId`; **self-hosted (ZTNET)** returns them flat with the node id in
/// `id` / `address`. The decoder accepts either; online status comes from an
/// explicit `online` flag when present, else the `lastOnline` / `lastSeen` time.
struct ZeroTierMember: Identifiable, Decodable, Hashable {
    var networkId: String
    let nodeId: String
    var name: String
    var description: String
    var authorized: Bool
    var hidden: Bool
    var deleted: Bool
    var ipAssignments: [String]
    var physicalAddress: String?
    var clientVersion: String?
    /// Epoch milliseconds of the last time the controller heard from this member.
    var lastOnline: Double?
    /// An explicit online flag, when the controller provides one.
    var onlineFlag: Bool?
    /// Which added account this member came from (set after fetch, not decoded).
    var accountId: UUID?

    var id: String { "\(networkId)-\(nodeId)" }

    /// How recently a member must have checked in to count as "online".
    private static let onlineWindow: TimeInterval = 5 * 60   // 5 minutes

    /// Whether the member is online — by explicit flag if given, else by how
    /// recently it last checked in.
    var isOnline: Bool {
        if let flag = onlineFlag { return flag }
        guard let ms = lastOnline, ms > 0 else { return false }
        let last = Date(timeIntervalSince1970: ms / 1000)
        return Date().timeIntervalSince(last) < Self.onlineWindow
    }

    /// A display name that falls back to the short node id when unnamed.
    var displayName: String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? nodeId : n
    }

    /// "3 minutes ago" style text for the last-seen line (nil if never seen).
    var lastSeenText: String? {
        guard let ms = lastOnline, ms > 0 else { return nil }
        let last = Date(timeIntervalSince1970: ms / 1000)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: last, relativeTo: Date())
    }

    /// Parse an ISO 8601 timestamp (with or without fractional seconds) to epoch ms.
    private static func parseTimestampMs(_ s: String) -> Double? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case networkId, nwid, nodeId, id, address, name, description, hidden, deleted, config
        case authorized, ipAssignments, online
        case physicalAddress, clientVersion, lastOnline, lastSeen
    }
    private enum ConfigKeys: String, CodingKey {
        case authorized, ipAssignments, address
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountId = nil
        networkId = (try? c.decodeIfPresent(String.self, forKey: .networkId))?.flatMap { $0 }
            ?? (try? c.decodeIfPresent(String.self, forKey: .nwid)) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        physicalAddress = try c.decodeIfPresent(String.self, forKey: .physicalAddress)
        clientVersion = try c.decodeIfPresent(String.self, forKey: .clientVersion)
        onlineFlag = try? c.decodeIfPresent(Bool.self, forKey: .online) ?? nil
        // The timestamp is `lastOnline`/`lastSeen` as epoch ms (Central / ZTNET
        // personal) or, for ZTNET org members, an ISO 8601 string.
        if let ms = try? c.decode(Double.self, forKey: .lastOnline) {
            lastOnline = ms
        } else if let ms = try? c.decode(Double.self, forKey: .lastSeen) {
            lastOnline = ms
        } else if let s = (try? c.decode(String.self, forKey: .lastSeen))
                    ?? (try? c.decode(String.self, forKey: .lastOnline)) {
            lastOnline = Self.parseTimestampMs(s)
        } else {
            lastOnline = nil
        }

        // Central nests these under `config`; ZTNET returns them flat.
        var resolvedAuthorized = try? c.decodeIfPresent(Bool.self, forKey: .authorized) ?? nil
        var resolvedIPs = (try? c.decode([String].self, forKey: .ipAssignments)) ?? []
        var resolvedNode = (try? c.decode(String.self, forKey: .nodeId)) ?? ""
        if let cfg = try? c.nestedContainer(keyedBy: ConfigKeys.self, forKey: .config) {
            if resolvedAuthorized == nil {
                resolvedAuthorized = try? cfg.decodeIfPresent(Bool.self, forKey: .authorized) ?? nil
            }
            if resolvedIPs.isEmpty {
                resolvedIPs = (try? cfg.decode([String].self, forKey: .ipAssignments)) ?? []
            }
            if resolvedNode.isEmpty {
                resolvedNode = (try? cfg.decode(String.self, forKey: .address)) ?? ""
            }
        }
        authorized = resolvedAuthorized ?? false
        ipAssignments = resolvedIPs
        // Fall back to the flat `id` / `address` node id used by self-hosted controllers.
        if resolvedNode.isEmpty {
            resolvedNode = (try? c.decode(String.self, forKey: .id))
                ?? (try? c.decode(String.self, forKey: .address)) ?? ""
        }
        nodeId = resolvedNode
    }

}

// MARK: - API client

/// Errors surfaced by the ZeroTier Central API client, with friendly messages.
enum ZeroTierError: LocalizedError {
    case notConfigured
    case http(Int)
    case transport(String)
    case decoding

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add a ZeroTier API token first."
        case .http(401), .http(403):
            return "ZeroTier rejected the API token. Check it’s correct and still valid."
        case .http(429):
            return "ZeroTier is rate-limiting requests. Wait a moment and try again."
        case .http(let code):
            return "ZeroTier API error (HTTP \(code))."
        case .transport(let m):
            return "Couldn’t reach ZeroTier: \(m)"
        case .decoding:
            return "ZeroTier returned data in an unexpected format."
        }
    }
}

/// A thin async wrapper over the ZeroTier REST API. Works with **ZeroTier
/// Central** (api.zerotier.com) and **self-hosted controllers** such as ZTNET:
/// the base URL is per-account, and the token is sent in both the Central
/// (`Authorization: token …`) and ZTNET (`x-ztnet-auth`) headers so either
/// server accepts it (each ignores the header it doesn't use).
struct ZeroTierAPI {
    let token: String
    /// Base URL already including the `/api/v1` path.
    let baseURL: String

    func networks() async throws -> [ZeroTierNetwork] {
        try await get("/network")
    }

    func members(networkId: String) async throws -> [ZeroTierMember] {
        try await get("/network/\(networkId)/member")
    }

    // Self-hosted (ZTNET) organization routes, used when a token is org-scoped.
    func organizations() async throws -> [ZTOrg] {
        try await get("/org")
    }

    func networks(orgId: String) async throws -> [ZeroTierNetwork] {
        try await get("/org/\(orgId)/network")
    }

    func members(orgId: String, networkId: String) async throws -> [ZeroTierMember] {
        try await get("/org/\(orgId)/network/\(networkId)/member")
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard !token.isEmpty else { throw ZeroTierError.notConfigured }
        guard let url = URL(string: baseURL + path) else { throw ZeroTierError.transport("bad URL") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")  // ZeroTier Central
        req.setValue(token, forHTTPHeaderField: "x-ztnet-auth")              // self-hosted (ZTNET)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw ZeroTierError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw ZeroTierError.decoding }
        guard (200..<300).contains(http.statusCode) else { throw ZeroTierError.http(http.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ZeroTierError.decoding
        }
    }
}

// MARK: - Account

/// A self-hosted (ZTNET) organization the token can access. Organization-scoped
/// tokens are rejected by the personal `/network` route and must use the
/// `/org/{id}/…` routes instead.
struct ZTOrg: Identifiable, Decodable, Hashable {
    let id: String
    var orgName: String?
    enum CodingKeys: String, CodingKey { case id, orgName }
}

/// One ZeroTier account the app can browse, identified by a stable UUID that
/// also keys its API token in the Keychain. Several accounts can be added so
/// devices from multiple ZeroTier logins — including **self-hosted controllers**
/// — appear together. `baseURL` selects the server (default: ZeroTier Central).
struct ZeroTierAccount: Identifiable, Codable, Hashable {
    /// The ZeroTier Central API base, used when no custom server is given.
    static let centralBaseURL = "https://api.zerotier.com/api/v1"

    let id: UUID
    var label: String
    var baseURL: String

    init(id: UUID = UUID(), label: String, baseURL: String = ZeroTierAccount.centralBaseURL) {
        self.id = id
        self.label = label
        self.baseURL = baseURL
    }

    enum CodingKeys: String, CodingKey { case id, label, baseURL }

    // Custom decode so accounts saved before `baseURL` existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ZeroTierAccount.centralBaseURL
    }

    /// A non-empty name for menus, section headers and subtitles.
    var displayLabel: String {
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return l.isEmpty ? "ZeroTier Account" : l
    }

    /// Whether this account points at ZeroTier Central (vs. a self-hosted server).
    var isCentral: Bool { baseURL == ZeroTierAccount.centralBaseURL }

    /// A short server label for the UI ("ZeroTier Central" or the custom host).
    var serverDisplay: String {
        if isCentral { return "ZeroTier Central" }
        if let u = URL(string: baseURL), let host = u.host {
            return host + (u.port.map { ":\($0)" } ?? "")
        }
        return baseURL
    }

    /// Turn raw user input into a usable API base URL ending in `/api/v1`.
    /// Empty input means ZeroTier Central. A bare host gets `https://`; an
    /// existing `/api/v1` suffix isn't duplicated.
    static func normalizedBaseURL(from raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return centralBaseURL }
        if !s.contains("://") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.lowercased().hasSuffix("/api/v1") { s += "/api/v1" }
        return s
    }
}


// MARK: - Store

/// Holds the ZeroTier networks and their members for **one or more** accounts,
/// fetched from the Central API, plus the securely-stored API tokens. A singleton
/// so the browser window, the IP pickers and any menu actions share one cache.
@MainActor
final class ZeroTierStore: ObservableObject {
    static let shared = ZeroTierStore()

    @Published private(set) var accounts: [ZeroTierAccount] = []
    @Published private(set) var networks: [ZeroTierNetwork] = []
    @Published private(set) var membersByNetwork: [String: [ZeroTierMember]] = [:]
    @Published private(set) var isLoadingNetworks = false
    @Published private(set) var loadingMembers: Set<String> = []
    @Published private(set) var lastError: String?

    /// True once at least one ZeroTier account (API token) has been added.
    var hasAccounts: Bool { !accounts.isEmpty }

    private let accountsKey = "zerotier.accounts.v1"
    /// Per-account network lists, combined into `networks` for display.
    private var networksByAccount: [UUID: [ZeroTierNetwork]] = [:]

    // Legacy single-token storage (pre-multi-account), migrated on first launch.
    private static let legacyTokenID = UUID(uuidString: "0F2C9B7A-7E11-4D5C-9C2A-5A65726F5469")!
    private let legacyHasTokenKey = "zerotier.hasToken"

    private init() {
        loadAccounts()
        migrateLegacyTokenIfNeeded()
    }

    // MARK: Account list persistence

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: accountsKey),
              let list = try? JSONDecoder().decode([ZeroTierAccount].self, from: data) else { return }
        accounts = list
    }

    private func saveAccounts() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: accountsKey)
        }
    }

    /// Carry a token saved by the old single-account version forward into the new
    /// accounts list, reusing the same Keychain item (its id becomes the account id).
    private func migrateLegacyTokenIfNeeded() {
        guard accounts.isEmpty,
              UserDefaults.standard.bool(forKey: legacyHasTokenKey),
              let token = token(for: Self.legacyTokenID), !token.isEmpty else {
            UserDefaults.standard.removeObject(forKey: legacyHasTokenKey)
            return
        }
        accounts = [ZeroTierAccount(id: Self.legacyTokenID, label: "ZeroTier")]
        saveAccounts()
        UserDefaults.standard.removeObject(forKey: legacyHasTokenKey)
    }

    // MARK: Token access (Keychain, keyed by account id)

    private func token(for accountId: UUID) -> String? {
        var result: String?
        // requireAuth: false reads synchronously and calls the completion inline.
        KeychainStore.shared.password(for: accountId, requireAuth: false, reason: "") { r in
            if case .success(let s) = r { result = s }
        }
        return result
    }

    // MARK: Account management

    /// Add a new account with a label, API token and optional server URL (blank =
    /// ZeroTier Central), then load its networks.
    @discardableResult
    func addAccount(label: String, token rawToken: String, server: String = "") -> Bool {
        let t = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = ZeroTierAccount(label: name.isEmpty ? "Account \(accounts.count + 1)" : name,
                                      baseURL: ZeroTierAccount.normalizedBaseURL(from: server))
        guard KeychainStore.shared.setPassword(t, for: account.id) else {
            lastError = "Couldn’t save the token to the Keychain."
            return false
        }
        accounts.append(account)
        saveAccounts()
        lastError = nil
        Task { await refresh(account: account) }
        return true
    }

    /// Update an existing account's token and/or server URL, then reload it. A nil
    /// (or blank) token keeps the current one; a nil server leaves it unchanged.
    func updateAccount(_ accountId: UUID, token rawToken: String?, server: String?) {
        if let server, let idx = accounts.firstIndex(where: { $0.id == accountId }) {
            accounts[idx].baseURL = ZeroTierAccount.normalizedBaseURL(from: server)
            saveAccounts()
        }
        if let rawToken {
            let t = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { KeychainStore.shared.setPassword(t, for: accountId) }
        }
        lastError = nil
        if let account = accounts.first(where: { $0.id == accountId }) {
            Task { await refresh(account: account) }
        }
    }

    /// Rename an account (its label is shown in headers and subtitles).
    func renameAccount(_ accountId: UUID, to label: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == accountId }) else { return }
        accounts[idx].label = label
        saveAccounts()
    }

    /// Remove an account: forget its token and drop its cached networks/members.
    func removeAccount(_ accountId: UUID) {
        KeychainStore.shared.deletePassword(for: accountId)
        accounts.removeAll { $0.id == accountId }
        let networkIDs = (networksByAccount[accountId] ?? []).map(\.id)
        networksByAccount[accountId] = nil
        for id in networkIDs { membersByNetwork[id] = nil }
        rebuildNetworks()
        saveAccounts()
        lastError = nil
    }

    // MARK: Loading

    /// Load everything if we have accounts but nothing cached yet.
    func loadIfNeeded() async {
        guard hasAccounts, networks.isEmpty, !isLoadingNetworks else { return }
        await refreshAll()
    }

    /// Reload every account's networks, then each network's members.
    func refreshAll() async {
        guard hasAccounts else { return }
        isLoadingNetworks = true
        lastError = nil
        for account in accounts {
            await loadNetworks(for: account)
        }
        isLoadingNetworks = false
        for network in networks {
            await refreshMembers(network)
        }
    }

    /// Reload a single account's networks and their members.
    func refresh(account: ZeroTierAccount) async {
        isLoadingNetworks = true
        await loadNetworks(for: account)
        isLoadingNetworks = false
        for network in networksByAccount[account.id] ?? [] {
            await refreshMembers(network)
        }
    }

    private func loadNetworks(for account: ZeroTierAccount) async {
        guard let token = token(for: account.id), !token.isEmpty else {
            lastError = "No API token saved for “\(account.displayLabel)”."
            return
        }
        let api = ZeroTierAPI(token: token, baseURL: account.baseURL)
        do {
            // Personal / Central token: the top-level network list.
            var nets = try await api.networks()
            for i in nets.indices { nets[i].accountId = account.id; nets[i].orgId = nil }
            networksByAccount[account.id] = nets
            rebuildNetworks()
        } catch let personalError {
            // A self-hosted (ZTNET) **organization** token is rejected by the
            // personal route (“Invalid Authorization Type”). Fall back to the org
            // routes automatically: list orgs, then each org’s networks.
            do {
                let orgs = try await api.organizations()
                guard !orgs.isEmpty else { throw personalError }
                var combined: [ZeroTierNetwork] = []
                for org in orgs {
                    var nets = try await api.networks(orgId: org.id)
                    for i in nets.indices { nets[i].accountId = account.id; nets[i].orgId = org.id }
                    combined.append(contentsOf: nets)
                }
                networksByAccount[account.id] = combined
                rebuildNetworks()
            } catch {
                // Surface the original personal-route error — it's the meaningful one.
                lastError = friendly(personalError, account: account)
            }
        }
    }

    private func rebuildNetworks() {
        networks = accounts
            .flatMap { networksByAccount[$0.id] ?? [] }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func refreshMembers(_ network: ZeroTierNetwork) async {
        guard let accountId = network.accountId,
              let account = accounts.first(where: { $0.id == accountId }),
              let token = token(for: accountId), !token.isEmpty else { return }
        loadingMembers.insert(network.id)
        defer { loadingMembers.remove(network.id) }
        do {
            let api = ZeroTierAPI(token: token, baseURL: account.baseURL)
            let raw: [ZeroTierMember]
            if let orgId = network.orgId {
                raw = try await api.members(orgId: orgId, networkId: network.id)
            } else {
                raw = try await api.members(networkId: network.id)
            }
            var members = raw.filter { !$0.hidden && !$0.deleted }
            for i in members.indices {
                members[i].accountId = accountId
                members[i].networkId = network.id   // self-hosted spells this `nwid`
            }
            membersByNetwork[network.id] = members.sorted { a, b in
                if a.isOnline != b.isOnline { return a.isOnline && !b.isOnline }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: Lookups

    /// The networks belonging to one account (in display order).
    func networks(for accountId: UUID) -> [ZeroTierNetwork] {
        (networksByAccount[accountId] ?? [])
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// The display name for a network id.
    func networkName(for id: String) -> String {
        networks.first { $0.id == id }?.displayName ?? id
    }

    /// The label of the account a network/member belongs to (empty if unknown).
    func accountLabel(for accountId: UUID?) -> String {
        guard let accountId else { return "" }
        return accounts.first { $0.id == accountId }?.displayLabel ?? ""
    }

    /// Clear the last error banner.
    func clearError() {
        lastError = nil
    }

    private func friendly(_ error: Error, account: ZeroTierAccount) -> String {
        let base = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return accounts.count > 1 ? "\(account.displayLabel): \(base)" : base
    }
}
