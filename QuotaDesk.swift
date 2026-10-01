import AppKit
import SwiftUI
import Security
import LocalAuthentication
import Combine
import ServiceManagement

// MARK: - Language

func usesThai() -> Bool {
    switch UserDefaults.standard.string(forKey: "language") ?? "system" {
    case "th": return true
    case "en": return false
    default: return Locale.preferredLanguages.first?.hasPrefix("th") ?? false
    }
}
func L(_ th: String, _ en: String) -> String { usesThai() ? th : en }
/// Both translations are kept so an already-shown message follows a language switch.
struct Localized: Hashable {
    let th: String
    let en: String
    init(_ th: String, _ en: String) { self.th = th; self.en = en }
    var text: String { usesThai() ? th : en }
}

struct Quota: Identifiable {
    var id: String { label.en }
    let label: Localized
    let used: Double
    let reset: Date?
}
struct Reading {
    var rows: [Quota] = []
    var message = Localized("กำลังเชื่อมต่อ…", "Connecting…")
    var updated: Date?
}
enum UsageError: Error { case message(Localized) }
func failure(_ th: String, _ en: String) -> UsageError { .message(Localized(th, en)) }

enum Provider: String, CaseIterable { case codex, claude }

// MARK: - Settings

@MainActor final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let refreshChoices = [1, 2, 5, 10, 15, 30, 60]
    private let defaults = UserDefaults.standard
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    /// Empty means follow the Mac's time zone.
    @Published var timeZoneID: String { didSet { defaults.set(timeZoneID, forKey: "timeZone") } }
    @Published var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: "refreshMinutes") } }
    /// "both", "codex" or "claude".
    @Published var providers: String { didSet { defaults.set(providers, forKey: "providers") } }
    /// "custom" (wherever it was dragged) or a corner: "topRight", "topLeft", "bottomRight", "bottomLeft".
    @Published var position: String { didSet { defaults.set(position, forKey: "position") } }
    /// Display used for corner placement, by name; empty means the main display.
    @Published var screenName: String { didSet { defaults.set(screenName, forKey: "screenName") } }
    @Published var locked: Bool { didSet { defaults.set(locked, forKey: "locked") } }
    /// "auto" follows macOS; "light" or "dark" forces one.
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    @Published var dragHintSeen: Bool { didSet { defaults.set(dragHintSeen, forKey: "dragHintSeen") } }
    static let positions = ["custom", "topRight", "topLeft", "bottomRight", "bottomLeft"]
    static func positionLabel(_ position: String) -> String {
        switch position {
        case "topRight": return L("มุมขวาบน", "Top right")
        case "topLeft": return L("มุมซ้ายบน", "Top left")
        case "bottomRight": return L("มุมขวาล่าง", "Bottom right")
        case "bottomLeft": return L("มุมซ้ายล่าง", "Bottom left")
        default: return L("กำหนดเอง (ลากวาง)", "Custom (drag)")
        }
    }
    /// Frame for a corner placement inside a screen's visible area, with an even margin.
    nonisolated static func corner(_ position: String, size: NSSize, in area: NSRect, margin: CGFloat = 16) -> NSRect {
        let left = position.hasSuffix("Left"), top = position.hasPrefix("top")
        let x = left ? area.minX + margin : area.maxX - margin - size.width
        let y = top ? area.maxY - margin - size.height : area.minY + margin
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }
    private init() {
        language = defaults.string(forKey: "language") ?? "system"
        timeZoneID = defaults.string(forKey: "timeZone") ?? ""
        let saved = defaults.integer(forKey: "refreshMinutes")
        refreshMinutes = Self.refreshChoices.contains(saved) ? saved : 5
        providers = ["codex", "claude"].contains(defaults.string(forKey: "providers")) ? defaults.string(forKey: "providers")! : "both"
        position = Self.positions.contains(defaults.string(forKey: "position") ?? "") ? defaults.string(forKey: "position")! : "topRight"
        screenName = defaults.string(forKey: "screenName") ?? ""
        locked = defaults.bool(forKey: "locked")
        appearance = ["light", "dark"].contains(defaults.string(forKey: "appearance") ?? "") ? defaults.string(forKey: "appearance")! : "auto"
        dragHintSeen = defaults.bool(forKey: "dragHintSeen")
    }
    func shows(_ provider: Provider) -> Bool { providers == "both" || providers == provider.rawValue }
    var timeZone: TimeZone { timeZoneID.isEmpty ? .current : TimeZone(identifier: timeZoneID) ?? .current }
    static func zoneLabel(_ zone: TimeZone) -> String {
        "\(zone.identifier) (\(zone.abbreviation() ?? "GMT"))"
    }
}

// MARK: - Provider access

actor RequestCooldown {
    static let shared = RequestCooldown()
    private var blockedUntil: [String: Date] = [:]
    func check(_ url: String) throws {
        if let until = blockedUntil[url], until > Date() {
            let minutes = Int(ceil(until.timeIntervalSinceNow / 60))
            throw failure("พักตามข้อจำกัดบริการ · อีก \(minutes) นาที", "Rate limited by provider · \(minutes) min left")
        }
    }
    func rateLimited(_ url: String, retryAfter: String?) {
        blockedUntil[url] = Self.deadline(retryAfter: retryAfter, now: Date())
    }
    static func deadline(retryAfter: String?, now: Date) -> Date {
        if let raw = retryAfter, let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
            return now.addingTimeInterval(max(60, seconds))
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let raw = retryAfter, let date = format.date(from: raw) { return max(now.addingTimeInterval(60), date) }
        return now.addingTimeInterval(300)
    }
}

final class ProviderAPI {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let claudeService = "Claude Code-credentials"
    // Serialized in-process cache; never written to disk or another Keychain item.
    private static let credentialLock = NSLock()
    private static var claudeCached: (token: String, until: Date)?
    static func clearClaudeCache() {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        claudeCached = nil
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("รูปแบบข้อมูลไม่รองรับ", "Unsupported response format")
        }
        return value
    }
    static func fetch(_ url: String, token: String, headers: [String: String] = [:]) async throws -> [String: Any] {
        try await RequestCooldown.shared.check(url)
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 {
                if URL(string: url)?.host == "api.anthropic.com" { clearClaudeCache() }
                throw failure("session หมดอายุ · กดเข้าสู่ระบบในการตั้งค่า", "Session expired · sign in from Settings")
            }
            if status == 403 { throw failure("บัญชีนี้ยังไม่อนุญาตให้อ่าน usage", "This account can't read usage") }
            if status == 429 {
                await RequestCooldown.shared.rateLimited(url, retryAfter: (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"))
                throw failure("บริการจำกัดความถี่ · พักแล้วลองอัตโนมัติ", "Rate limited · will retry automatically")
            }
            throw failure("อ่าน usage ไม่สำเร็จ (HTTP \(status))", "Couldn't read usage (HTTP \(status))")
        }
        return try object(data)
    }
    static var codexAuthFile: URL {
        let dir = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
        return dir.appendingPathComponent("auth.json")
    }
    static func codex() async throws -> [Quota] {
        guard let data = try? Data(contentsOf: codexAuthFile),
              let auth = try? object(data), let tokens = auth["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String else {
            throw failure("ยังไม่ได้เข้าสู่ระบบ Codex", "Not signed in to Codex")
        }
        var headers: [String: String] = [:]
        if let account = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = account }
        let result = try await fetch("https://chatgpt.com/backend-api/wham/usage", token: token, headers: headers)
        let limits = result["rate_limit"] as? [String: Any] ?? [:]
        let windows = [("primary_window", Localized("5 ชั่วโมง", "5 hours")), ("secondary_window", Localized("รายสัปดาห์", "Weekly"))]
        let rows = windows.compactMap { key, fallback -> Quota? in
            guard let window = limits[key] as? [String: Any], let used = window["used_percent"] as? Double, used.isFinite else { return nil }
            let label = (window["limit_window_seconds"] as? Double).flatMap(windowLabel(seconds:)) ?? fallback
            let reset = (window["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            return Quota(label: label, used: max(0, min(100, used)), reset: reset)
        }
        guard !rows.isEmpty else { throw failure("บัญชีไม่ส่งข้อมูลโควตาเปอร์เซ็นต์", "Account returned no quota percentages") }
        return rows
    }
    /// Names a quota window by its length, e.g. 18000 s -> "5 hours", 604800 s -> "Weekly".
    static func windowLabel(seconds: Double) -> Localized? {
        let hours = Int((seconds / 3600).rounded())
        guard hours > 0 else { return nil }
        if hours == 168 { return Localized("รายสัปดาห์", "Weekly") }
        if hours % 24 == 0 { return Localized("\(hours / 24) วัน", "\(hours / 24) days") }
        return Localized("\(hours) ชั่วโมง", "\(hours) hours")
    }
    static func securityCLIRead(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // `-w` prints hex when the stored value isn't plain text.
        if !text.hasPrefix("{"), text.count % 2 == 0, text.allSatisfy(\.isHexDigit) {
            var bytes = [UInt8](); var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
                bytes.append(byte); index = next
            }
            return Data(bytes)
        }
        return Data(text.utf8)
    }
    static func claudeCredentialData() -> Data? {
        // Claude Code writes its item via /usr/bin/security, so that tool stays in the item's ACL
        // even after each token refresh recreates the item. Reading through it never prompts.
        (try? Data(contentsOf: home.appendingPathComponent(".claude/.credentials.json"))) ?? securityCLIRead(service: claudeService)
    }
    /// In-memory fingerprint used only to notice that a CLI sign-in finished. Never stored.
    static func credentialStamp(_ provider: Provider) -> Int? {
        switch provider {
        case .codex: return (try? Data(contentsOf: codexAuthFile))?.hashValue
        case .claude: return claudeCredentialData()?.hashValue
        }
    }
    static func claudeCredential(interactive: Bool) throws -> String {
        credentialLock.lock()
        defer { credentialLock.unlock() }
        if !interactive, let cached = claudeCached, cached.until > Date() { return cached.token }
        var data = claudeCredentialData()
        if data == nil {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: claudeService,
                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            let context = LAContext()
            context.interactionNotAllowed = !interactive
            query[kSecUseAuthenticationContext as String] = context
            // Claude Code uses a legacy login Keychain item. Suppress that UI too.
            var previousInteraction: DarwinBoolean = true
            if !interactive {
                guard SecKeychainGetUserInteractionAllowed(&previousInteraction) == errSecSuccess,
                      SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
                    throw failure("กด เชื่อมต่อ เพื่ออนุญาต Keychain", "Click Connect to allow Keychain access")
                }
            }
            defer { if !interactive { SecKeychainSetUserInteractionAllowed(previousInteraction.boolValue) } }
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecInteractionNotAllowed || status == errSecAuthFailed || status == errSecUserCanceled {
                throw failure("กด เชื่อมต่อ เพื่ออนุญาต Keychain", "Click Connect to allow Keychain access")
            }
            if status == errSecSuccess { data = item as? Data }
        }
        guard let data, let json = try? object(data),
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else {
            throw failure("ยังไม่ได้เข้าสู่ระบบ Claude Code", "Not signed in to Claude Code")
        }
        let expires = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000 - 60) }
        if let expires, expires <= Date() {
            throw failure("token หมดอายุ · เปิด claude ใน Terminal สักครั้งเพื่อต่ออายุ", "Token expired · run claude once in Terminal to renew")
        }
        claudeCached = (token, min(Date().addingTimeInterval(600), expires ?? Date().addingTimeInterval(600)))
        return token
    }
    static func claude(interactive: Bool) async throws -> [Quota] {
        let token = try await Task.detached { try claudeCredential(interactive: interactive) }.value
        let result = try await fetch("https://api.anthropic.com/api/oauth/usage", token: token, headers: ["anthropic-beta": "oauth-2025-04-20"])
        let windows = [("five_hour", Localized("5 ชั่วโมง", "5 hours")), ("seven_day", Localized("รายสัปดาห์", "Weekly"))]
        let rows = windows.compactMap { key, label -> Quota? in
            guard let window = result[key] as? [String: Any], let used = window["utilization"] as? Double, used.isFinite else { return nil }
            var reset: Date?
            if let date = window["resets_at"] as? String {
                let formatter = ISO8601DateFormatter()
                reset = formatter.date(from: date)
                if reset == nil { formatter.formatOptions.insert(.withFractionalSeconds); reset = formatter.date(from: date) }
            }
            return Quota(label: label, used: max(0, min(100, used)), reset: reset)
        }
        guard !rows.isEmpty else { throw failure("บัญชีไม่ส่งข้อมูลโควตาเปอร์เซ็นต์", "Account returned no quota percentages") }
        return rows
    }
}

// MARK: - Sign-in

/// Sign-in is delegated to each provider's official CLI, so this app never sees a password
/// and never handles OAuth secrets itself. The script holds only the fixed command below.
enum LoginLauncher {
    static func command(_ provider: Provider) -> (binary: String, args: String, install: String) {
        switch provider {
        case .codex: return ("codex", "login", "https://github.com/openai/codex")
        case .claude: return ("claude", "auth login", "https://docs.anthropic.com/en/docs/claude-code/setup")
        }
    }
    static func open(_ provider: Provider) throws {
        let (binary, args, install) = command(provider)
        let script = """
        #!/bin/zsh -l
        [[ -f ~/.zshrc ]] && source ~/.zshrc >/dev/null 2>&1
        rm -f "$0"
        export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
        clear
        if command -v \(binary) >/dev/null 2>&1; then
          \(binary) \(args)
          echo
          echo "\(L("เสร็จแล้ว กลับไปที่ QuotaDesk ได้เลย ปิดหน้าต่างนี้ได้", "Done. Return to QuotaDesk; you can close this window."))"
        else
          echo "\(L("ไม่พบคำสั่ง \(binary) ติดตั้งก่อนที่:", "The \(binary) command was not found. Install it from:"))"
          echo "  \(install)"
        fi
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("QuotaDesk", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("\(provider.rawValue)-login.command")
        try script.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }
}

// MARK: - Model

@MainActor final class UsageModel: ObservableObject {
    @Published var codex = Reading()
    @Published var claude = Reading()
    @Published var busy = false
    @Published var floating = UserDefaults.standard.bool(forKey: "floating")
    @Published var waitingForLogin: Provider?
    private var lastRefresh: Date = .distantPast
    private var loginWatch: Task<Void, Never>?
    /// Timer tick: refresh once the user's chosen interval has passed.
    func tick() {
        let interval = Double(AppSettings.shared.refreshMinutes * 60) - 5
        if Date().timeIntervalSince(lastRefresh) >= interval { refresh() }
    }
    /// Manual/wake refreshes stay at least 55 s apart; `force` is for explicit Connect/sign-in.
    func refresh(interactive: Bool = false, force: Bool = false) {
        guard !busy else { return }
        guard force || interactive || Date().timeIntervalSince(lastRefresh) >= 55 else { return }
        lastRefresh = Date()
        busy = true
        Task {
            // Hidden providers are skipped entirely: no credential read, no network request.
            let settings = AppSettings.shared
            let (showCodex, showClaude, oldCodex, oldClaude) = (settings.shows(.codex), settings.shows(.claude), codex, claude)
            async let c = showCodex ? read { try await ProviderAPI.codex() } : oldCodex
            async let a = showClaude ? read { try await ProviderAPI.claude(interactive: interactive) } : oldClaude
            (codex, claude) = await (c, a)
            busy = false
        }
    }
    func signIn(_ provider: Provider) {
        do { try LoginLauncher.open(provider) } catch {
            let message = Localized("เปิด Terminal ไม่สำเร็จ", "Couldn't open Terminal")
            if provider == .codex { codex.message = message } else { claude.message = message }
            return
        }
        loginWatch?.cancel()
        waitingForLogin = provider
        // Watch locally (no network) for the CLI to write new credentials, then refresh once.
        loginWatch = Task {
            let before = await Task.detached { ProviderAPI.credentialStamp(provider) }.value
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if Task.isCancelled { return }
                let now = await Task.detached { ProviderAPI.credentialStamp(provider) }.value
                if now != nil, now != before {
                    ProviderAPI.clearClaudeCache()
                    waitingForLogin = nil
                    refresh(force: true)
                    return
                }
            }
            waitingForLogin = nil
        }
    }
    private func read(_ block: () async throws -> [Quota]) async -> Reading {
        do { return Reading(rows: try await block(), message: Localized("", ""), updated: Date()) }
        catch UsageError.message(let message) { return Reading(message: message) }
        catch { return Reading(message: Localized("เชื่อมต่อไม่ได้ · ตรวจสอบอินเทอร์เน็ต", "Can't connect · check your internet")) }
    }
}

// MARK: - Widget views

enum TimeText {
    /// e.g. "พรุ่งนี้ · ศ. 2 ต.ค. 2569 · 14:30 น." or "Tomorrow · Fri 2 Oct 2026 · 14:30"
    static func resetMoment(_ reset: Date, now: Date, zone: TimeZone) -> String {
        let thai = usesThai()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: reset)).day ?? 99
        let prefix = days == 0 ? L("วันนี้ · ", "Today · ") : days == 1 ? L("พรุ่งนี้ · ", "Tomorrow · ") : ""
        let format = DateFormatter()
        format.locale = Locale(identifier: thai ? "th_TH" : "en_GB")
        format.calendar = Calendar(identifier: thai ? .buddhist : .gregorian)
        format.timeZone = zone
        format.dateFormat = thai ? "EEE d MMM yyyy · HH:mm 'น.'" : "EEE d MMM yyyy · HH:mm"
        return prefix + format.string(from: reset)
    }
    static func clock(_ date: Date, zone: TimeZone) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = zone
        format.dateFormat = "HH:mm"
        return format.string(from: date)
    }
    static func countdown(_ reset: Date?, now: Date) -> String {
        guard let reset else { return L("ยังไม่มีเวลารีเซ็ต", "No reset time yet") }
        let minutes = Int(ceil(reset.timeIntervalSince(now) / 60))
        if minutes <= 0 { return L("ถึงรอบรีเซ็ต · รอข้อมูลใหม่", "Reset due · waiting for new data") }
        if minutes >= 1440 { return L("รีเซ็ตใน \(minutes / 1440) วัน \((minutes % 1440) / 60) ชม.", "Resets in \(minutes / 1440)d \((minutes % 1440) / 60)h") }
        return L("รีเซ็ตใน \(minutes / 60) ชม. \(minutes % 60) นาที", "Resets in \(minutes / 60)h \(minutes % 60)m")
    }
}

/// Widget colors for the current light/dark appearance.
struct Palette {
    let dark: Bool
    init(_ scheme: ColorScheme) { dark = scheme == .dark }
    var codex: Color { dark ? .mint : Color(red: 0.0, green: 0.58, blue: 0.5) }
    var claude: Color { dark ? Color(red: 0.91, green: 0.62, blue: 0.46) : Color(red: 0.8, green: 0.42, blue: 0.23) }
    var background: LinearGradient {
        LinearGradient(colors: dark ? [Color(red: 0.105, green: 0.125, blue: 0.15), Color(red: 0.055, green: 0.065, blue: 0.085)]
                                    : [Color(red: 0.985, green: 0.988, blue: 0.993), Color(red: 0.925, green: 0.935, blue: 0.95)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var stroke: Color { .primary.opacity(dark ? 0.14 : 0.1) }
    var cardTint: Double { dark ? 0.045 : 0.07 }
}

struct QuotaRow: View {
    let quota: Quota
    let accent: Color
    @ObservedObject var settings = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(quota.label.text).font(.system(size: 11)).foregroundStyle(.primary.opacity(0.6))
                Spacer()
                Text("\(Int(quota.used.rounded()))%").font(.system(size: 19, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            GeometryReader { geo in
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(quota.used >= 90 ? Color.red : accent).frame(width: geo.size.width * quota.used / 100)
            }.frame(height: 5)
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(TimeText.countdown(quota.reset, now: context.date)).font(.system(size: 10)).foregroundStyle(.primary.opacity(0.42))
                    if let reset = quota.reset {
                        Text(TimeText.resetMoment(reset, now: context.date, zone: settings.timeZone))
                            .font(.system(size: 10, weight: .medium)).monospacedDigit().foregroundStyle(.primary.opacity(0.7))
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
            }
        }
    }
}

struct ProviderCard: View {
    @Environment(\.colorScheme) private var scheme
    let name: String
    let symbol: String
    let accent: Color
    let reading: Reading
    let connect: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundStyle(accent)
                Text(name).font(.system(size: 16, weight: .semibold))
                Spacer()
                Circle().fill(reading.updated == nil ? Color.orange : accent).frame(width: 5, height: 5)
            }
            if reading.rows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("—").font(.system(size: 32, weight: .light))
                    Text(reading.message.text).font(.system(size: 11)).foregroundStyle(.primary.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                    Button(L("เชื่อมต่อ / เข้าสู่ระบบ", "Connect / Sign in"), action: connect).font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(accent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ForEach(reading.rows) { QuotaRow(quota: $0, accent: accent) }
            }
            Spacer(minLength: 0)
        }.padding(16).frame(maxWidth: .infinity, minHeight: 215, maxHeight: 215)
            .background(accent.opacity(Palette(scheme).cardTint), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(.primary.opacity(0.08), lineWidth: 1))
    }
}

struct WidgetView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: UsageModel
    @ObservedObject var settings = AppSettings.shared
    var delegate: AppDelegate? { NSApp.delegate as? AppDelegate }
    var single: Bool { settings.providers != "both" }
    var lastUpdated: Date? {
        Provider.allCases.filter(settings.shows).compactMap { ($0 == .codex ? model.codex : model.claude).updated }.min()
    }
    var body: some View {
        let palette = Palette(scheme)
        VStack(spacing: 13) {
            HStack(spacing: 7) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(palette.codex)
                Text("QUOTADESK").font(.system(size: 11, weight: .bold, design: .rounded)).tracking(2)
                Text(L("ใช้ไปแล้ว", "used")).font(.system(size: 10)).foregroundStyle(.primary.opacity(0.4))
                Spacer()
                // Both header icons get the same fixed hit box, apart from each other and the corner.
                Button { model.refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
                }
                    .disabled(model.busy).help(L("รีเฟรชยอดใช้ไป · เว้นอย่างน้อย 1 นาที", "Refresh usage · at most once a minute"))
                Menu {
                    Button(model.floating ? L("วางบนเดสก์ท็อป", "Place on desktop") : L("ลอยเหนือหน้าต่างอื่น", "Float above windows")) {
                        model.floating.toggle()
                        UserDefaults.standard.set(model.floating, forKey: "floating")
                        delegate?.updateLevel()
                    }
                    Picker(L("ตำแหน่ง", "Position"), selection: $settings.position) {
                        ForEach(AppSettings.positions, id: \.self) { Text(AppSettings.positionLabel($0)).tag($0) }
                    }
                    Toggle(L("ล็อกตำแหน่ง", "Lock position"), isOn: $settings.locked)
                    Divider()
                    Button(L("ตั้งค่าและบัญชี…", "Settings & accounts…")) { delegate?.showSettings() }
                    Button(L("เปิด Codex usage", "Open Codex usage")) { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/codex/settings/usage")!) }
                    Button(L("เปิด Claude usage", "Open Claude usage")) { NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!) }
                    Divider()
                    Button(L("ออกจาก QuotaDesk", "Quit QuotaDesk")) { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 22, height: 22)
                    .help(L("เมนู", "Menu"))
            }.padding(.trailing, 2).buttonStyle(.plain).foregroundStyle(.primary.opacity(0.7))
            HStack(spacing: 10) {
                if settings.shows(.codex) {
                    ProviderCard(name: "Codex", symbol: "chevron.left.forwardslash.chevron.right", accent: palette.codex, reading: model.codex) { connect(.codex) }
                }
                if settings.shows(.claude) {
                    ProviderCard(name: "Claude", symbol: "sun.max", accent: palette.claude, reading: model.claude) { connect(.claude) }
                }
            }
            // One card is too narrow for a single footer line, so the time zone moves below.
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(model.busy ? L("กำลังอัปเดต…", "Updating…") : L("อัปเดตทุก \(settings.refreshMinutes) นาที", "Updates every \(settings.refreshMinutes) min"))
                    if !single { Text("·"); Text(AppSettings.zoneLabel(settings.timeZone)).lineLimit(1) }
                    Spacer()
                    if let date = lastUpdated { Text(TimeText.clock(date, zone: settings.timeZone)).monospacedDigit() }
                }
                if single { Text(AppSettings.zoneLabel(settings.timeZone)).lineLimit(1) }
                if !settings.dragHintSeen && !settings.locked {
                    Text(L("ลากพื้นหลังเพื่อย้าย · เลือกมุมได้ที่เมนู ⋯", "Drag the background to move · corners in the ⋯ menu"))
                        .foregroundStyle(.primary.opacity(0.6))
                }
            }.font(.system(size: 10)).foregroundStyle(.primary.opacity(0.4))
        }.padding(19).frame(width: single ? 270 : 440)
            .background(palette.background, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(palette.stroke, lineWidth: 1))
            .foregroundStyle(.primary)
            // The window is moved by hand: NSHostingView ignores isMovableByWindowBackground.
            // Buttons still win taps; a drag needs a few points of movement first.
            .contentShape(RoundedRectangle(cornerRadius: 24))
            .gesture(DragGesture(minimumDistance: 3)
                .onChanged { _ in delegate?.dragMoved() }
                .onEnded { _ in delegate?.dragEnded() }, including: settings.locked ? .none : .all)
    }
    /// Retry first; if there are no credentials at all, open the settings to sign in.
    func connect(_ provider: Provider) {
        let reading = provider == .codex ? model.codex : model.claude
        let signedOut = reading.message.en.hasPrefix("Not signed in") || reading.message.en.hasPrefix("Session expired")
        if signedOut { delegate?.showSettings() } else { model.refresh(interactive: provider == .claude, force: true) }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @ObservedObject var model: UsageModel
    @ObservedObject var settings = AppSettings.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    var body: some View {
        Form {
            Section(L("ทั่วไป", "General")) {
                Picker(L("ภาษา", "Language"), selection: $settings.language) {
                    Text(L("ตามระบบ", "System")).tag("system")
                    Text("ไทย").tag("th")
                    Text("English").tag("en")
                }
                Picker(L("เขตเวลา", "Time zone"), selection: $settings.timeZoneID) {
                    Text(L("ตามเครื่อง", "System") + " — " + AppSettings.zoneLabel(.current)).tag("")
                    Divider()
                    ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { id in
                        Text(TimeZone(identifier: id).map(AppSettings.zoneLabel) ?? id).tag(id)
                    }
                }
                Picker(L("ธีม", "Appearance"), selection: $settings.appearance) {
                    Text(L("อัตโนมัติ (ตามระบบ)", "Auto (system)")).tag("auto")
                    Text(L("สว่าง", "Light")).tag("light")
                    Text(L("มืด", "Dark")).tag("dark")
                }
                Picker(L("แสดง", "Show"), selection: $settings.providers) {
                    Text(L("ทั้งคู่", "Both")).tag("both")
                    Text("Codex").tag("codex")
                    Text("Claude").tag("claude")
                }
                Picker(L("รีเฟรชทุก", "Refresh every"), selection: $settings.refreshMinutes) {
                    ForEach(AppSettings.refreshChoices, id: \.self) { Text(L("\($0) นาที", "\($0) min")).tag($0) }
                }
                Toggle(L("เปิดอัตโนมัติเมื่อเข้าสู่ระบบ Mac", "Open at login"), isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section(L("ตำแหน่ง", "Position")) {
                Picker(L("วางที่", "Place at"), selection: $settings.position) {
                    ForEach(AppSettings.positions, id: \.self) { Text(AppSettings.positionLabel($0)).tag($0) }
                }
                if NSScreen.screens.count > 1 || !settings.screenName.isEmpty {
                    Picker(L("จอ", "Display"), selection: $settings.screenName) {
                        Text(L("จอหลัก", "Main display")).tag("")
                        ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { Text($0).tag($0) }
                    }.disabled(settings.position == "custom")
                }
                Toggle(L("ล็อกตำแหน่ง (กันเผลอลาก)", "Lock position (prevents accidental drags)"), isOn: $settings.locked)
            }
            Section(L("บัญชี", "Accounts")) {
                account(.codex, name: "Codex", reading: model.codex)
                account(.claude, name: "Claude", reading: model.claude)
                HStack {
                    Button(L("ตรวจสอบตอนนี้", "Check now")) { model.refresh(interactive: true, force: true) }.disabled(model.busy)
                    if model.busy { ProgressView().controlSize(.small) }
                }
                Text(L("การเข้าสู่ระบบจะเปิด Terminal และใช้คำสั่งทางการของแต่ละบริการ (codex login / claude auth login) รหัสผ่านกรอกบนเว็บของผู้ให้บริการเท่านั้น แอปนี้ไม่เห็นรหัสผ่าน ไม่เก็บ token ลงดิสก์ และส่ง token ไปยัง endpoint usage ของผู้ให้บริการนั้นเท่านั้น",
                       "Sign-in opens Terminal and runs each provider's official command (codex login / claude auth login). You enter your password only on the provider's site. This app never sees passwords, never writes tokens to disk, and sends each token only to that provider's usage endpoint."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped).frame(width: 480, height: 770)
    }
    @ViewBuilder func account(_ provider: Provider, name: String, reading: Reading) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Circle().fill(reading.updated != nil ? Color.green : Color.orange).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                Text(model.waitingForLogin == provider ? L("รอให้เข้าสู่ระบบใน Terminal เสร็จ…", "Waiting for sign-in in Terminal…")
                     : reading.updated != nil ? L("เชื่อมต่อแล้ว", "Connected") : reading.message.text)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(reading.updated != nil ? L("เข้าสู่ระบบใหม่", "Sign in again") : L("เข้าสู่ระบบ", "Sign in")) {
                if reading.updated == nil || confirmSignInAgain(name) { model.signIn(provider) }
            }
        }
    }
    /// The CLIs drop the current session as soon as a new login starts, so make that explicit.
    func confirmSignInAgain(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = L("เข้าสู่ระบบ \(name) ใหม่?", "Sign in to \(name) again?")
        alert.informativeText = L("session ปัจจุบันจะใช้ไม่ได้ทันทีที่เริ่ม ต้องทำขั้นตอนในเบราว์เซอร์ให้เสร็จ ห้ามปิด Terminal กลางทาง",
                                  "Your current session stops working as soon as this starts. Finish the steps in your browser and don't close Terminal midway.")
        alert.addButton(withTitle: L("เข้าสู่ระบบใหม่", "Sign in again"))
        alert.addButton(withTitle: L("ยกเลิก", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = L("ตั้งค่าไม่สำเร็จ: ", "Couldn't change: ") + error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - App

final class WidgetWindow: NSPanel { override var canBecomeKey: Bool { true } }
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: WidgetWindow!
    var settingsWindow: NSWindow?
    var status: NSStatusItem!
    var timer: Timer?
    let model = UsageModel()
    var observers: Set<AnyCancellable> = []
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    /// Resize to the SwiftUI content. A corner placement snaps to that corner of the chosen
    /// display; a custom placement keeps the top-right corner where the user dragged it.
    func fitToContent() {
        guard dragStart == nil, let content = window.contentView else { return }
        let size = content.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let settings = AppSettings.shared
        var frame = window.frame
        if settings.position != "custom", let screen = targetScreen() {
            frame = AppSettings.corner(settings.position, size: size, in: screen.visibleFrame)
        } else {
            frame.origin.y += frame.height - size.height
            frame.origin.x += frame.width - size.width
            frame.size = size
            frame = keptOnScreen(frame)
        }
        if frame != window.frame { window.setFrame(frame, display: true) }
    }
    func targetScreen() -> NSScreen? {
        let name = AppSettings.shared.screenName
        return NSScreen.screens.first { $0.localizedName == name } ?? NSScreen.screens.first
    }
    /// Follows the pointer in screen coordinates, so moving the window doesn't skew the drag.
    func dragMoved() {
        let settings = AppSettings.shared
        guard !settings.locked else { return }
        let mouse = NSEvent.mouseLocation
        if dragStart == nil {
            dragStart = (mouse, window.frame.origin)
            if settings.position != "custom" { settings.position = "custom" }
            if !settings.dragHintSeen { settings.dragHintSeen = true }
        }
        guard let start = dragStart else { return }
        window.setFrameOrigin(NSPoint(x: start.origin.x + mouse.x - start.mouse.x, y: start.origin.y + mouse.y - start.mouse.y))
    }
    func dragEnded() {
        dragStart = nil
        fitToContent()
    }
    /// Keeps the whole widget inside the visible area (below the menu bar, above the Dock).
    func keptOnScreen(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.visibleFrame.intersects(frame) }) ?? NSScreen.main else { return frame }
        let area = screen.visibleFrame
        var frame = frame
        frame.origin.x = min(max(frame.minX, area.minX), area.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, area.minY), area.maxY - frame.height)
        return frame
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        window = WidgetWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 304), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: WidgetView(model: model))
        // fitToContent() owns the window size. The hosting view's default min/max sizing also
        // resizes the window, keeping the bottom edge fixed, so the widget crept upward on every
        // launch. Keep only the intrinsic size, which fittingSize needs for measuring.
        host.sizingOptions = [.intrinsicContentSize]
        window.contentView = host
        window.setFrameAutosaveName("QuotaDeskWindow")
        if !window.setFrameUsingName("QuotaDeskWindow"), let screen = NSScreen.main {
            window.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 468, y: screen.visibleFrame.maxY - 335))
        }
        fitToContent()
        model.objectWillChange.merge(with: AppSettings.shared.objectWillChange).receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.fitToContent() } }.store(in: &observers)
        AppSettings.shared.$providers.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.model.refresh(force: true) } }.store(in: &observers)
        AppSettings.shared.$appearance.receive(on: RunLoop.main)
            .sink { value in
                NSApp.appearance = value == "light" ? NSAppearance(named: .aqua) : value == "dark" ? NSAppearance(named: .darkAqua) : nil
            }.store(in: &observers)
        AppSettings.shared.$language.receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.buildMenu() } }.store(in: &observers)
        updateLevel()
        window.orderFrontRegardless()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "QuotaDesk")
        buildMenu()
        model.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.model.tick() } }
        if CommandLine.arguments.contains("--settings") { showSettings() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wakeRefresh), name: NSWorkspace.didWakeNotification, object: nil)
        // A display was unplugged, rearranged or changed resolution: pull the widget back into view.
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    @objc func screensChanged() { fitToContent() }
    func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: L("แสดง QuotaDesk", "Show QuotaDesk"), action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: L("รีเฟรช", "Refresh"), action: #selector(refresh), keyEquivalent: "")
        menu.addItem(withTitle: L("ตั้งค่าและบัญชี…", "Settings & accounts…"), action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("ออก", "Quit"), action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        status?.menu = menu
        settingsWindow?.title = L("ตั้งค่า QuotaDesk", "QuotaDesk Settings")
    }
    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.title = L("ตั้งค่า QuotaDesk", "QuotaDesk Settings")
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func updateLevel() { window.level = model.floating ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1) }
    @objc func show() { window.orderFrontRegardless() }
    @objc func refresh() { model.refresh() }
    @objc func wakeRefresh() { model.refresh() }
    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--self-test") {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    precondition(RequestCooldown.deadline(retryAfter: nil, now: now) == now.addingTimeInterval(300))
    precondition(RequestCooldown.deadline(retryAfter: "120", now: now) == now.addingTimeInterval(120))
    precondition(RequestCooldown.deadline(retryAfter: "0", now: now) == now.addingTimeInterval(60))
    precondition(RequestCooldown.deadline(retryAfter: "NaN", now: now) == now.addingTimeInterval(300))
    precondition(RequestCooldown.deadline(retryAfter: "Tue, 14 Nov 2023 22:15:20 GMT", now: now) == now.addingTimeInterval(120))
    // 2023-11-14 22:13:20 UTC: Bangkok is already the 15th, New York still the 14th.
    let reset = now.addingTimeInterval(3600)
    let savedLanguage = UserDefaults.standard.string(forKey: "language")
    UserDefaults.standard.set("en", forKey: "language")
    precondition(TimeText.resetMoment(reset, now: now, zone: TimeZone(identifier: "Asia/Bangkok")!) == "Today · Wed 15 Nov 2023 · 06:13")
    precondition(TimeText.resetMoment(reset, now: now, zone: TimeZone(identifier: "America/New_York")!) == "Today · Tue 14 Nov 2023 · 18:13")
    UserDefaults.standard.set("th", forKey: "language")
    precondition(TimeText.resetMoment(reset, now: now, zone: TimeZone(identifier: "Asia/Bangkok")!).hasSuffix("15 พ.ย. 2566 · 06:13 น."))
    UserDefaults.standard.set(savedLanguage, forKey: "language")
    let area = NSRect(x: 0, y: 0, width: 1920, height: 1050), size = NSSize(width: 440, height: 307)
    precondition(AppSettings.corner("topRight", size: size, in: area) == NSRect(x: 1464, y: 727, width: 440, height: 307))
    precondition(AppSettings.corner("bottomLeft", size: size, in: area) == NSRect(x: 16, y: 16, width: 440, height: 307))
    precondition(ProviderAPI.windowLabel(seconds: 18000)?.en == "5 hours" && ProviderAPI.windowLabel(seconds: 604800)?.en == "Weekly")
    Task {
        let gate = RequestCooldown()
        try! await gate.check("test")
        await gate.rateLimited("test", retryAfter: "60")
        do { try await gate.check("test"); fatalError("Rate-limit cooldown failed") }
        catch UsageError.message(_) { }
        catch { fatalError("Unexpected cooldown error") }
        try! await gate.check("other-provider")
        print("PASS: Retry-After seconds/date/default, minimum delay, provider-isolated cooldown, time zone + language formatting, corner placement")
        exit(0)
    }
    RunLoop.main.run()
} else if CommandLine.arguments.contains("--check") {
    Task {
        for name in ["Codex", "Claude"] {
            do {
                let rows = try await (name == "Codex" ? ProviderAPI.codex() : ProviderAPI.claude(interactive: false))
                print("\(name): " + rows.map { "\($0.label.en)=\(Int($0.used))% used" }.joined(separator: ", "))
            } catch UsageError.message(let message) { print("\(name): \(message.en)") }
            catch { print("\(name): connection unavailable (\((error as NSError).code))") }
        }
        exit(0)
    }
    RunLoop.main.run()
} else {
    MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
    }
}
