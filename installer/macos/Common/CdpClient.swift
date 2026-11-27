import Foundation
#if canImport(Darwin)
import Darwin
#endif

struct CdpPageInfo {
    let id: String
    let title: String
    let url: String
    let webSocketDebuggerUrl: String
}

struct BareHostAppInfo {
    let pid: Int32
    let appPath: String
    let startTimeMs: Int64
    let uptimeMs: Int64
}

struct CdpError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { return message }
}

enum InstallerI18n {
    private static let lock = NSLock()
    private static var cachedLang: String? = nil

    static func normalizeLangCode(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !s.isEmpty else {
            return nil
        }
        if s == "zh" || s.hasPrefix("zh-") || s.hasPrefix("zh_") || s == "cn" {
            return "zh"
        }
        if s == "en" || s.hasPrefix("en-") || s.hasPrefix("en_") {
            return "en"
        }
        return nil
    }

    static func parseCliLang(_ args: [String] = CommandLine.arguments) -> String? {
        var i = 1
        while i < args.count {
            let a = args[i]
            if a == "--lang", i + 1 < args.count {
                if let norm = normalizeLangCode(args[i + 1]) {
                    return norm
                }
                i += 2
                continue
            }
            if a.hasPrefix("--lang=") {
                let val = String(a.dropFirst("--lang=".count))
                if let norm = normalizeLangCode(val) {
                    return norm
                }
            }
            i += 1
        }
        return nil
    }

    static func detectLanguage(
        args: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> String {
        if let cli = parseCliLang(args) {
            return cli
        }
        if let envVal = normalizeLangCode(environment["AG_PRISM_LANG"]) {
            return envVal
        }
        if let first = preferredLanguages.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           first.hasPrefix("zh") {
            return "zh"
        }
        return "en"
    }

    static func setExplicitLanguage(_ raw: String?) {
        guard let norm = normalizeLangCode(raw) else { return }
        lock.lock()
        cachedLang = norm
        lock.unlock()
    }

    static var currentLanguage: String {
        lock.lock()
        if let existing = cachedLang {
            lock.unlock()
            return existing
        }
        let resolved = detectLanguage()
        cachedLang = resolved
        lock.unlock()
        return resolved
    }

    static var isChinese: Bool {
        return currentLanguage == "zh"
    }

    static func tr(_ zh: String, _ en: String) -> String {
        return isChinese ? zh : en
    }
}

final class PluginManifest {
    let version: String
    let styleId: String
    let settingBinding: String
    let parts: [String]
    let defaultConfig: [String: JsonValue]
    let validators: [String: JsonValue]
    let removeExpression: String

    init(
        version: String,
        styleId: String,
        settingBinding: String,
        parts: [String],
        defaultConfig: [String: JsonValue],
        validators: [String: JsonValue],
        removeExpression: String
    ) {
        self.version = version
        self.styleId = styleId
        self.settingBinding = settingBinding
        self.parts = parts
        self.defaultConfig = defaultConfig
        self.validators = validators
        self.removeExpression = removeExpression
    }

    static func load(baseDir: String) throws -> PluginManifest {
        let manifestPath = (baseDir as NSString).appendingPathComponent("manifest.json")
        let text = try String(contentsOfFile: manifestPath, encoding: .utf8)
        let raw = try MiniJson.parseObject(text)
        let version = raw["version"]?.stringValue ?? "1.0.8-beta.4"
        let styleId = raw["styleId"]?.stringValue ?? "ag-prism-css"
        let settingBinding = raw["settingBinding"]?.stringValue ?? "__agPrismSetting"
        let removeExpression = raw["removeExpression"]?.stringValue ?? ""
        var parts: [String] = []
        if let arr = raw["parts"]?.arrayValue {
            for item in arr {
                if let s = item.stringValue, !s.isEmpty {
                    parts.append(s)
                }
            }
        }
        var defaultConfig = CdpHelper.createDefaultConfig()
        if let rawDef = raw["defaultConfig"]?.objectValue {
            for (k, v) in rawDef {
                if case .null = v { continue }
                defaultConfig[k] = v
            }
        }
        var validators = CdpHelper.createDefaultValidators()
        if let rawVal = raw["validators"]?.objectValue {
            for (k, v) in rawVal {
                if case .null = v { continue }
                validators[k] = v
            }
        }
        return PluginManifest(
            version: version,
            styleId: styleId,
            settingBinding: settingBinding,
            parts: parts,
            defaultConfig: defaultConfig,
            validators: validators,
            removeExpression: removeExpression
        )
    }
}

final class CdpSession: NSObject, URLSessionWebSocketDelegate {
    private var urlSession: URLSession!
    private var wsTask: URLSessionWebSocketTask!
    private let lock = NSLock()
    private let sendQueue = DispatchQueue(label: "io.github.rmvdesi.obsidian-prism.cdp.send")
    private var nextId: Int = 0
    private var pending: [Int: (Result<[String: JsonValue], Error>) -> Void] = [:]
    private var listeners: [String: [([String: JsonValue]) -> Void]] = [:]
    private var closed = false
    private var opened = false
    private var openCallback: ((Error?) -> Void)?

    var onClose: (() -> Void)?

    private override init() {
        super.init()
    }

    static func connect(wsUrl: String, timeoutMs: Int = 3000) throws -> CdpSession {
        guard let url = URL(string: wsUrl) else {
            throw CdpError("Invalid WebSocket URL: \(wsUrl)")
        }
        let session = CdpSession()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = max(1.0, Double(timeoutMs) / 1000.0)
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "io.github.rmvdesi.obsidian-prism.cdp.ws"

        let sem = DispatchSemaphore(value: 0)
        var connectErr: Error?

        session.lock.lock()
        session.openCallback = { err in
            connectErr = err
            sem.signal()
        }
        session.lock.unlock()

        let urlSession = URLSession(configuration: cfg, delegate: session, delegateQueue: delegateQueue)
        let task = urlSession.webSocketTask(with: url)
        task.maximumMessageSize = 64 * 1024 * 1024
        session.urlSession = urlSession
        session.wsTask = task
        task.resume()

        let waitResult = sem.wait(timeout: .now() + .milliseconds(timeoutMs))
        if waitResult == .timedOut {
            session.lock.lock()
            session.openCallback = nil
            session.lock.unlock()
            session.close()
            throw CdpError("CDP connect timeout")
        }
        if let err = connectErr {
            session.close()
            throw err
        }
        return session
    }

    func on(_ method: String, callback: @escaping ([String: JsonValue]) -> Void) {
        lock.lock()
        var list = listeners[method] ?? []
        list.append(callback)
        listeners[method] = list
        lock.unlock()
    }

    func send(_ method: String, params: [String: JsonValue]? = nil, timeoutMs: Int = 5000) throws -> [String: JsonValue] {
        lock.lock()
        if closed {
            lock.unlock()
            throw CdpError("CDP connection closed")
        }
        nextId += 1
        let id = nextId
        let sem = DispatchSemaphore(value: 0)
        var outcome: Result<[String: JsonValue], Error>?
        pending[id] = { res in
            outcome = res
            sem.signal()
        }
        lock.unlock()

        let payload: JsonValue = .object([
            "id": .int(Int64(id)),
            "method": .string(method),
            "params": .object(params ?? [:])
        ])
        let json = MiniJson.stringify(payload, pretty: false)

        sendQueue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let isClosed = self.closed
            let task = self.wsTask
            self.lock.unlock()
            if isClosed || task == nil { return }
            task!.send(.string(json)) { [weak self] err in
                if let err = err {
                    self?.failPending(id: id, error: err)
                }
            }
        }

        let waitRes = sem.wait(timeout: .now() + .milliseconds(timeoutMs))
        if waitRes == .timedOut {
            lock.lock()
            pending.removeValue(forKey: id)
            let wasClosed = closed
            lock.unlock()
            if wasClosed {
                throw CdpError("CDP connection closed")
            }
            throw CdpError("CDP \(method) timeout")
        }

        switch outcome {
        case .success(let val):
            return val
        case .failure(let err):
            throw err
        case .none:
            throw CdpError("CDP \(method) failed")
        }
    }

    func evaluate(_ expression: String, awaitPromise: Bool = false) throws -> JsonValue {
        let res = try send("Runtime.evaluate", params: [
            "expression": .string(expression),
            "returnByValue": .bool(true),
            "awaitPromise": .bool(awaitPromise)
        ], timeoutMs: 15000)

        if let exDetails = res["exceptionDetails"]?.objectValue {
            var msg = exDetails["exception"]?.objectValue?["description"]?.stringValue
            if msg == nil || msg!.isEmpty {
                msg = exDetails["text"]?.stringValue
            }
            throw CdpError(msg ?? "Runtime.evaluate exception")
        }

        if let resultObj = res["result"]?.objectValue, let val = resultObj["value"] {
            return val
        }
        return .null
    }

    func close() {
        markClosed()
        lock.lock()
        let task = wsTask
        let session = urlSession
        lock.unlock()
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
    }

    private func failPending(id: Int, error: Error) {
        lock.lock()
        let cb = pending.removeValue(forKey: id)
        lock.unlock()
        cb?(.failure(error))
    }

    private func startReceiveLoop() {
        lock.lock()
        let isClosed = closed
        let task = wsTask
        lock.unlock()
        if isClosed || task == nil { return }

        task!.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        self.handleMessage(text)
                    }
                @unknown default:
                    break
                }
                self.startReceiveLoop()
            case .failure:
                self.markClosed()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let msg = try? MiniJson.parseObject(text) else { return }

        if let method = msg["method"]?.stringValue {
            let params = msg["params"]?.objectValue ?? [:]
            lock.lock()
            let callbacks = listeners[method] ?? []
            lock.unlock()
            for cb in callbacks {
                cb(params)
            }
            return
        }

        if let id = msg["id"]?.intValue {
            lock.lock()
            let cb = pending.removeValue(forKey: id)
            lock.unlock()
            guard let callback = cb else { return }
            if let errVal = msg["error"], case .null = errVal {
                // error is null -> treat as success
            } else if let errVal = msg["error"] {
                let errMsg = errVal.objectValue?["message"]?.stringValue ?? MiniJson.stringify(errVal, pretty: false)
                callback(.failure(CdpError(errMsg)))
                return
            }
            let resDict = msg["result"]?.objectValue ?? [:]
            callback(.success(resDict))
        }
    }

    private func markClosed() {
        lock.lock()
        if closed {
            lock.unlock()
            return
        }
        closed = true
        let pendingCallbacks = pending
        pending.removeAll()
        let closeHandler = onClose
        let openCb = openCallback
        openCallback = nil
        lock.unlock()

        openCb?(CdpError("CDP connection closed"))
        for (_, cb) in pendingCallbacks {
            cb(.failure(CdpError("CDP connection closed")))
        }
        closeHandler?()
    }

    // MARK: - URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock()
        opened = true
        let cb = openCallback
        openCallback = nil
        lock.unlock()
        startReceiveLoop()
        cb?(nil)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        markClosed()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let wasOpened = opened
        let cb = openCallback
        openCallback = nil
        lock.unlock()
        if !wasOpened, let cb = cb {
            cb(error ?? CdpError("CDP connect failed"))
        }
        markClosed()
    }
}

enum CdpHelper {
    static func getPortFilePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ((home as NSString)
            .appendingPathComponent("Library/Application Support/Antigravity/DevToolsActivePort"))
    }

    static func readPort(overridePort: Int?) -> Int? {
        if let p = overridePort, p > 0 { return p }
        if let envPort = ProcessInfo.processInfo.environment["AG_CDP_PORT"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envPort.isEmpty,
           let p = Int(envPort), p > 0 {
            return p
        }
        let portFile = getPortFilePath()
        guard let text = try? String(contentsOfFile: portFile, encoding: .utf8) else { return nil }
        let firstLine = text.components(separatedBy: CharacterSet.newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let p = Int(firstLine), p > 0 {
            return p
        }
        return nil
    }

    static func listPages(port: Int) throws -> [CdpPageInfo] {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/list") else {
            throw CdpError("Invalid CDP HTTP URL")
        }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 2.0
        cfg.timeoutIntervalForResource = 2.0
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }

        let sem = DispatchSemaphore(value: 0)
        var fetchedData: Data?
        var fetchedError: Error?

        let task = session.dataTask(with: url) { data, _, err in
            fetchedData = data
            fetchedError = err
            sem.signal()
        }
        task.resume()

        if sem.wait(timeout: .now() + .milliseconds(2500)) == .timedOut {
            task.cancel()
            throw CdpError("CDP /json/list timeout")
        }
        if let err = fetchedError {
            throw err
        }
        guard let data = fetchedData, let jsonText = String(data: data, encoding: .utf8) else {
            throw CdpError("Empty response from /json/list")
        }

        let targets = try MiniJson.parseArray(jsonText)
        var pages: [CdpPageInfo] = []
        for targetVal in targets {
            guard let t = targetVal.objectValue else { continue }
            let type = t["type"]?.stringValue ?? ""
            let wsUrl = t["webSocketDebuggerUrl"]?.stringValue ?? ""
            let pageUrl = t["url"]?.stringValue ?? ""
            let title = t["title"]?.stringValue ?? ""
            if isEligibleTarget(type: type, wsUrl: wsUrl, title: title, pageUrl: pageUrl) {
                let id = t["id"]?.stringValue ?? wsUrl
                pages.append(CdpPageInfo(id: id, title: title, url: pageUrl, webSocketDebuggerUrl: wsUrl))
            }
        }
        return pages
    }

    static func isBareAuxiliaryTarget(title: String, pageUrl: String) -> Bool {
        let ttl = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if ttl.caseInsensitiveCompare("Untitled") == .orderedSame ||
           ttl.caseInsensitiveCompare("launchpad") == .orderedSame {
            return true
        }
        let url = pageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEnd = url.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? url.endIndex
        let cleanLower = String(url[..<cleanEnd]).lowercased()
        if cleanLower.hasSuffix("/launchpad") || cleanLower.hasSuffix("/launchpad.html") {
            return true
        }
        return false
    }

    static func isEligibleTarget(type: String, wsUrl: String, title: String, pageUrl: String) -> Bool {
        if type != "page" || wsUrl.isEmpty { return false }
        let url = pageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let ttl = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return false }
        let lowerUrl = url.lowercased()
        let blockedPrefixes = ["devtools://", "data:", "about:", "chrome:", "chrome-extension:", "edge:", "blob:", "plugin:"]
        for pfx in blockedPrefixes {
            if lowerUrl.hasPrefix(pfx) { return false }
        }
        if isBareAuxiliaryTarget(title: ttl, pageUrl: url) { return false }
        if lowerUrl.hasPrefix("vscode-file://") || lowerUrl.hasPrefix("app://") { return true }
        if lowerUrl.hasPrefix("file://") {
            return lowerUrl.contains("workbench") || lowerUrl.contains("antigravity") || ttl.lowercased().contains("antigravity")
        }
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), (scheme == "http" || scheme == "https") else {
            return false
        }
        let host = (parsed.host ?? "").lowercased()
        if host != "127.0.0.1" && host != "localhost" && host != "::1" && host != "[::1]" { return false }
        let lowerPath = parsed.path.lowercased()
        if lowerPath == "/viewer" || lowerPath.hasPrefix("/viewer/") ||
           lowerPath == "/sandbox" || lowerPath.hasPrefix("/sandbox/") ||
           lowerPath == "/stream" || lowerPath.hasPrefix("/stream/") ||
           lowerPath == "/api" || lowerPath.hasPrefix("/api/") {
            return false
        }
        if ttl.lowercased().contains("antigravity") { return true }
        if scheme == "https" && (ttl.isEmpty || ttl.lowercased().hasPrefix("127.0.0.1")) { return true }
        return false
    }

    static func computeHash(_ str: String) -> String {
        var h: UInt32 = 2166136261
        for unit in str.utf16 {
            h ^= UInt32(unit)
            h = h &* 16777619
        }
        return String(h, radix: 36)
    }

    private static let canonicalLangValues = ["auto", "zh-CN", "zh-TW", "en", "ja", "ko", "es", "fr", "de", "tr", "ru"]
    private static let onOffValues = ["on", "off"]
    private static let autoOnOffValues = ["auto", "on", "off"]
    private static let strictOnBoolKeys = ["ignoreReducedMotion", "sidebarCompact", "codeLigatures", "autoArchiveOnExit"]
    private static let notOffBoolKeys = ["smoothCaret", "contextMenu"]

    // 单源声明式 Schema 表（与 src/config/schema.cjs 全部 54 键 100% 对齐：40 枚举 + 9 非可选布尔 + 2 字符串 + 1 整数 + 2 可选受控布尔）
    private static let enumSchemaSpecs: [(String, String, String)] = [
        ("language", "auto", "L"), ("lang", "auto", "L"),
        ("palette", "obsidian", "host,obsidian,warm,claude"), ("lightPreset", "crystal", "crystal,alabaster"),
        ("darkAuraStyle", "prism", "prism,neon"), ("motionLevel", "ultra", "off,subtle,standard,ultra"),
        ("performanceMode", "balanced", "balanced,performance,quality,auto,eco"), ("targetFps", "180", "60,120,180,native"),
        ("telemetryModule", "auto", "A"), ("telemetryQuotaMode", "compact", "compact,both"),
        ("effortSliderModule", "auto", "A"), ("effortMemory", "on", "O"), ("periodicModelPicker", "on", "O"),
        ("thoughtTranslate", "off", "off,machine,ai"), ("thoughtTrigger", "preload", "preload,expand"),
        ("homeLayout", "studio", "studio,classic,off"), ("homeMode", "studio", "studio,classic,off"),
        ("convRipple", "off", "off,subtle,medium,full"), ("ripple", "on", "O"), ("composer", "on", "O"),
        ("placeholderStyle", "studio", "studio,host"), ("promptStyle", "studio", "studio,host"),
        ("mascot", "crab", "crab,minis,quad,quad-minis,dual,off"), ("logoInk", "accent", "accent,foreground"),
        ("sidebar", "on", "O"), ("sidebarNavFold", "off", "off,on"),
        ("scrollBottomMotion", "smooth", "smooth,instant"), ("accentTone", "follow", "follow,cobalt,iris,amber,mono"),
        ("cornerStyle", "balanced", "sharp,balanced,soft"), ("chatFont", "default", "default,system-sans,noto-sans,inter,harmony,custom"),
        ("codeFont", "default", "default,jetbrains,cascadia,sfmono,custom"), ("ambientIntensity", "100", "0,35,70,100"),
        ("darkAura", "balanced", "subtle,balanced,vivid"), ("thoughtView", "immersive", "immersive,bilingual"),
        ("omniModule", "on", "O"), ("linkTarget", "builtin", "builtin,external"),
        ("sidebarStudio", "off", "O"), ("hostLocalization", "auto", "A"),
        ("autoUpdate", "off", "O"), ("updateChannel", "stable", "stable,beta"),
    ]
    private static let boolSchemaDefaultTrueKeys = ["homeRipple", "composerRestyle", "sidebarRestyle", "smoothCaret", "contextMenu"]
    private static let boolSchemaDefaultFalseKeys = ["ignoreReducedMotion", "sidebarCompact", "codeLigatures", "autoArchiveOnExit"]
    private static let stringSchemaKeys = ["chatFontCustom", "codeFontCustom"]

    private static func expandEnumSpec(_ spec: String) -> JsonValue {
        let items: [String]
        if spec == "L" { items = canonicalLangValues }
        else if spec == "A" { items = autoOnOffValues }
        else if spec == "O" { items = onOffValues }
        else { items = spec.split(separator: ",").map(String.init) }
        return .array(items.map { .string($0) })
    }

    static func createDefaultConfig() -> [String: JsonValue] {
        var d: [String: JsonValue] = [:]
        for (k, def, _) in enumSchemaSpecs { d[k] = .string(def) }
        for k in boolSchemaDefaultTrueKeys { d[k] = .bool(true) }
        for k in boolSchemaDefaultFalseKeys { d[k] = .bool(false) }
        for k in stringSchemaKeys { d[k] = .string("") }
        d["pollIntervalMs"] = .int(2500)
        return d
    }

    static func createDefaultValidators() -> [String: JsonValue] {
        var v: [String: JsonValue] = [:]
        for (k, _, spec) in enumSchemaSpecs { v[k] = expandEnumSpec(spec) }
        for k in boolSchemaDefaultTrueKeys { v[k] = .string("boolean") }
        for k in boolSchemaDefaultFalseKeys { v[k] = .string("boolean") }
        for k in stringSchemaKeys { v[k] = .string("string") }
        return v
    }

    private static let builtinValidators: [String: JsonValue] = createDefaultValidators()

    static func normalizeMascotConfigValue(_ raw: String?) -> String? {
        guard let s = raw else { return nil }
        if s == "dual" { return "crab" }
        if s == "off" || s == "crab" || s == "minis" || s == "quad" || s == "quad-minis" { return s }
        guard s.hasPrefix("r:"), s.count > 2 else { return nil }
        var body = String(s.dropFirst(2))
        let minis = body.hasSuffix("+m")
        if minis { body = String(body.dropLast(2)) }
        var counts = [0, 0, 0, 0]
        var seen = [false, false, false, false]
        var rawTotal = 0
        var total = 0
        if !body.isEmpty {
            for tok in body.split(separator: ",", omittingEmptySubsequences: false) {
                let chars = Array(tok.unicodeScalars)
                guard chars.count == 2 else { return nil }
                let idx: Int
                switch chars[0] {
                case "c": idx = 0
                case "k": idx = 1
                case "d": idx = 2
                case "w": idx = 3
                default: return nil
                }
                let digit = Int(chars[1].value) - 48
                guard digit >= 0 && digit <= 4 && !seen[idx] else { return nil }
                seen[idx] = true
                rawTotal += digit
                let clamped = digit > 0 ? 1 : 0
                counts[idx] = clamped
                total += clamped
            }
        }
        if rawTotal > 6 || total > 4 { return nil }
        if total == 0 && !minis { return "off" }
        if counts[0] == 1 && counts[1] == 1 && counts[2] == 0 && counts[3] == 0 { return minis ? "minis" : "crab" }
        if counts[0] == 1 && counts[1] == 1 && counts[2] == 1 && counts[3] == 1 { return minis ? "quad-minis" : "quad" }
        let names = ["c", "k", "d", "w"]
        var parts: [String] = []
        for i in 0..<4 where counts[i] > 0 { parts.append("\(names[i])\(counts[i])") }
        return "r:" + parts.joined(separator: ",") + (minis ? "+m" : "")
    }

    private static func extractSchemaInteger(_ value: JsonValue) -> Int64? {
        switch value {
        case .int(let n): return n
        case .double(let d):
            guard d.isFinite, d.rounded(.towardZero) == d,
                  d >= -9007199254740991.0, d <= 9007199254740991.0 else { return nil }
            return Int64(d)
        default: return nil
        }
    }

    private static func sanitizeCustomFont(_ value: JsonValue) -> String {
        guard let raw = value.stringValue else { return "" }
        var out = ""
        var u16 = 0
        for sc in raw.unicodeScalars {
            if sc == "\0" || sc == "\r" || sc == "\n" { continue }
            let cost = sc.utf16.count
            if u16 + cost > 160 { break }
            out.unicodeScalars.append(sc)
            u16 += cost
        }
        return out
    }

    private static func toBoolOnOff(_ val: JsonValue?) -> Bool {
        guard let v = val else { return true }
        if case .bool(let b) = v { return b }
        if let s = v.stringValue?.lowercased() { return s != "off" && s != "false" }
        return true
    }

    private static func toStrictOnBool(_ val: JsonValue?) -> Bool {
        guard let v = val else { return false }
        if case .bool(let b) = v { return b }
        if let s = v.stringValue?.lowercased() { return s == "on" || s == "true" }
        return false
    }

    static func reconcileConfigAliases(_ raw: [String: JsonValue]) -> [String: JsonValue] {
        var out = raw
        if let lang = out["language"] { out["lang"] = lang }
        else if let lang = out["lang"] { out["language"] = lang }

        if let langStr = out["language"]?.stringValue {
            let lowLang = langStr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "_", with: "-")
            if lowLang == "yue" || lowLang.hasPrefix("yue-") || lowLang == "zh-yue" || lowLang.contains("cantonese") {
                out["language"] = .string("zh-CN")
                out["lang"] = .string("zh-CN")
            }
        }

        if let hl = out["homeLayout"] { out["homeMode"] = hl }
        else if let hm = out["homeMode"] { out["homeLayout"] = hm }

        if out["homeRipple"] != nil || out["ripple"] != nil {
            let on = out["homeRipple"] != nil ? toBoolOnOff(out["homeRipple"]) : toBoolOnOff(out["ripple"])
            out["homeRipple"] = .bool(on)
            out["ripple"] = .string(on ? "on" : "off")
        }
        if out["composerRestyle"] != nil || out["composer"] != nil {
            let on = out["composerRestyle"] != nil ? toBoolOnOff(out["composerRestyle"]) : toBoolOnOff(out["composer"])
            out["composerRestyle"] = .bool(on)
            out["composer"] = .string(on ? "on" : "off")
        }
        if let ps = out["placeholderStyle"] { out["promptStyle"] = ps }
        else if let pr = out["promptStyle"] { out["placeholderStyle"] = pr }

        if out["sidebarRestyle"] != nil || out["sidebar"] != nil {
            let on = out["sidebarRestyle"] != nil ? toBoolOnOff(out["sidebarRestyle"]) : toBoolOnOff(out["sidebar"])
            out["sidebarRestyle"] = .bool(on)
            out["sidebar"] = .string(on ? "on" : "off")
        }
        if let cr = out["convRipple"] {
            if case .bool(let b) = cr {
                out["convRipple"] = .string(b ? "medium" : "off")
            } else if let s = cr.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                if s == "on" || s == "true" { out["convRipple"] = .string("medium") }
                else if s == "off" || s == "false" { out["convRipple"] = .string("off") }
                else if s == "subtle" || s == "medium" || s == "full" { out["convRipple"] = .string(s) }
            }
        }
        for k in strictOnBoolKeys {
            if let v = out[k], (v.boolValue != nil || v.stringValue != nil) {
                out[k] = .bool(toStrictOnBool(v))
            }
        }
        for k in notOffBoolKeys {
            if let v = out[k], (v.boolValue != nil || v.stringValue != nil) {
                out[k] = .bool(toBoolOnOff(v))
            }
        }
        for k in ["telemetryModule", "effortSliderModule", "effortMemory", "periodicModelPicker", "omniModule", "sidebarStudio", "autoUpdate", "sidebarNavFold"] {
            if let v = out[k], case .bool(let b) = v { out[k] = .string(b ? "on" : "off") }
        }
        if out["palette"]?.stringValue == "claude" { out["palette"] = .string("warm") }
        if let pm = out["performanceMode"]?.stringValue {
            if pm == "auto" { out["performanceMode"] = .string("balanced") }
            else if pm == "eco" { out["performanceMode"] = .string("performance") }
        }
        if out["mascot"]?.stringValue == "dual" {
            out["mascot"] = .string("crab")
        } else if let ms = out["mascot"]?.stringValue, let normMascot = normalizeMascotConfigValue(ms) {
            out["mascot"] = .string(normMascot)
        }
        if let cf = out["chatFontCustom"] { out["chatFontCustom"] = .string(sanitizeCustomFont(cf)) }
        if let kf = out["codeFontCustom"] { out["codeFontCustom"] = .string(sanitizeCustomFont(kf)) }
        if let pv = out["pollIntervalMs"], let iv = extractSchemaInteger(pv) { out["pollIntervalMs"] = .int(iv) }
        return out
    }

    static func readConfig(baseDir: String, manifest: PluginManifest) -> [String: JsonValue] {
        var cfg = createDefaultConfig()
        for (k, v) in manifest.defaultConfig {
            if case .null = v { continue }
            cfg[k] = v
        }
        let cfgPath = (baseDir as NSString).appendingPathComponent("config.json")
        if let text = try? String(contentsOfFile: cfgPath, encoding: .utf8),
           let userCfg = try? MiniJson.parseObject(text) {
            let reconciled = reconcileConfigAliases(userCfg)
            for (k, v) in reconciled {
                if case .null = v { continue }
                if k == "pollIntervalMs" {
                    if let iv = extractSchemaInteger(v), iv >= 500 && iv <= 60000 { cfg[k] = .int(iv) }
                    continue
                }
                if k == "autoPromptCdpRelaunch" || k == "autoRelaunchOnBareLaunch" {
                    if v.boolValue != nil { cfg[k] = v }
                    continue
                }
                let isKnown = builtinValidators[k] != nil || manifest.validators[k] != nil
                if !isKnown || validateConfigEntry(manifest: manifest, key: k, value: v) {
                    cfg[k] = v
                }
            }
        }
        return reconcileConfigAliases(cfg)
    }

    static func validateConfigEntry(manifest: PluginManifest, key: String, value: JsonValue) -> Bool {
        guard !key.isEmpty else { return false }
        if key == "mascot" {
            return normalizeMascotConfigValue(value.stringValue) != nil
        }
        if key == "pollIntervalMs" {
            guard let iv = extractSchemaInteger(value) else { return false }
            return iv >= 500 && iv <= 60000
        }
        if key == "autoPromptCdpRelaunch" || key == "autoRelaunchOnBareLaunch" {
            if case .bool = value { return true }
            return false
        }
        guard let rule = manifest.validators[key] ?? builtinValidators[key] else { return false }
        if let ruleStr = rule.stringValue {
            if ruleStr == "boolean" {
                if case .bool = value { return true }
                if let sv = value.stringValue, (sv == "on" || sv == "off") { return true }
                return false
            }
            if ruleStr == "string" {
                guard let sv = value.stringValue, sv.utf16.count <= 160 else { return false }
                return !sv.unicodeScalars.contains { $0 == "\0" || $0 == "\r" || $0 == "\n" }
            }
            return false
        } else if let allowed = rule.arrayValue {
            guard let strVal = value.stringValue else { return false }
            return allowed.contains { $0.stringValue == strVal }
        }
        return false
    }

    static func updateConfigBatch(baseDir: String, manifest: PluginManifest, entries: [String: JsonValue]) -> Bool {
        var validPatch: [String: JsonValue] = [:]
        for (k, v) in entries {
            if validateConfigEntry(manifest: manifest, key: k, value: v) {
                validPatch[k] = v
            }
        }
        if validPatch.isEmpty { return false }

        let reconciledPatch = reconcileConfigAliases(validPatch)
        var next = readConfig(baseDir: baseDir, manifest: manifest)
        for (k, v) in reconciledPatch {
            next[k] = v
        }
        next = reconcileConfigAliases(next)
        let cfgPath = (baseDir as NSString).appendingPathComponent("config.json")
        do {
            try atomicWriteJsonObject(next, toFile: cfgPath)
            return true
        } catch {
            return false
        }
    }

    static func updateConfigSetting(baseDir: String, manifest: PluginManifest, key: String, value: JsonValue) -> Bool {
        return updateConfigBatch(baseDir: baseDir, manifest: manifest, entries: [key: value])
    }

    static func getDefaultNativePluginDir() -> String {
        if let envOverride = ProcessInfo.processInfo.environment["AG_PRISM_PLUGIN_DIR"],
           !envOverride.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: envOverride.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (((home as NSString).appendingPathComponent(".gemini/config/plugins")) as NSString)
            .appendingPathComponent("obsidian-prism")
    }

    static func readNativeDaemonPid(pluginDir: String) -> Int32? {
        guard !pluginDir.isEmpty else { return nil }
        let pidPath = (pluginDir as NSString).appendingPathComponent(".daemon.pid")
        guard let raw = try? String(contentsOfFile: pidPath, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let plainPid = Int32(trimmed), plainPid > 0 { return plainPid }
        if trimmed.hasPrefix("{"),
           let obj = try? MiniJson.parseObject(trimmed),
           let pidVal = obj["pid"] {
            if case .int(let n) = pidVal, n > 0 && n <= Int64(Int32.max) {
                return Int32(n)
            }
            if case .double(let d) = pidVal, d > 0 && d <= Double(Int32.max) {
                return Int32(d)
            }
        }
        return nil
    }

    private static func runPsQuery(pid: Int32, format: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", "\(pid)", "-o", format]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    static func isExpectedDaemonProcess(pid: Int32, pluginDir: String = "") -> Bool {
        guard pid > 0 else { return false }
        let comm = runPsQuery(pid: pid, format: "comm=").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if comm.isEmpty { return false }
        let commBase = (comm as NSString).lastPathComponent
        if commBase == "obsidian-prism-watcher" ||
           comm.contains("obsidian-prism") ||
           comm.contains("agy-claude-style") {
            return true
        }
        if comm.contains("node") || comm.contains("watcher") {
            let cmd = runPsQuery(pid: pid, format: "command=")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\", with: "/")
                .lowercased()
            if cmd.isEmpty { return false }
            if cmd.contains("obsidian-prism") ||
               cmd.contains("antigravity-prism") ||
               cmd.contains("agy-claude-style") ||
               cmd.contains("sidecars/daemon/main.mjs") ||
               cmd.contains("daemon/main.mjs") ||
               cmd.contains("watch.js") {
                return true
            }
            if !pluginDir.isEmpty {
                let normPlugin = pluginDir
                    .replacingOccurrences(of: "\\", with: "/")
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    .lowercased()
                if !normPlugin.isEmpty && cmd.contains(normPlugin) {
                    return true
                }
            }
            return false
        }
        if comm.contains("antigravity") || comm.contains("electron") || comm.hasSuffix("/agy") || comm == "agy" {
            let args = runPsQuery(pid: pid, format: "args=").replacingOccurrences(of: "\\", with: "/").lowercased()
            if args.isEmpty || args.contains("--type=") { return false }
            var hasPrismOwner = args.contains("obsidian-prism") || args.contains("antigravity-prism") || args.contains("agy-claude-style")
            if !hasPrismOwner && !pluginDir.isEmpty {
                let normPlugin = pluginDir.replacingOccurrences(of: "\\", with: "/").lowercased()
                if !normPlugin.isEmpty && args.contains(normPlugin) {
                    hasPrismOwner = true
                }
            }
            let hasDaemonEntry = args.contains("sidecars/daemon/main.mjs") || args.contains("/daemon/main.mjs") || args.contains("/watch.js")
            let matchedLock = (!pluginDir.isEmpty && readNativeDaemonPid(pluginDir: pluginDir) == pid) ||
                              (readNativeDaemonPid(pluginDir: getDefaultNativePluginDir()) == pid)
            if (hasPrismOwner || matchedLock) && hasDaemonEntry { return true }
            if matchedLock && args.contains("sidecar_sdk/register_loader.js") && args.contains("main.mjs") {
                return true
            }
            return false
        }
        return false
    }

    private static let daemonCacheLock = NSLock()
    private static var verifiedDaemonPid: Int32 = 0

    private static func removeStaleDaemonLockIfMatches(pluginDir: String, stalePid: Int32) {
        guard !pluginDir.isEmpty, stalePid > 0 else { return }
        if readNativeDaemonPid(pluginDir: pluginDir) == stalePid {
            let pidPath = (pluginDir as NSString).appendingPathComponent(".daemon.pid")
            try? FileManager.default.removeItem(atPath: pidPath)
        }
    }

    static func isNativeDaemonAlive(pluginDir: String) -> Bool {
        guard let pid = readNativeDaemonPid(pluginDir: pluginDir), pid > 0 else { return false }
        if kill(pid, 0) != 0 {
            daemonCacheLock.lock()
            if verifiedDaemonPid == pid { verifiedDaemonPid = 0 }
            daemonCacheLock.unlock()
            removeStaleDaemonLockIfMatches(pluginDir: pluginDir, stalePid: pid)
            return false
        }
        daemonCacheLock.lock()
        let alreadyVerified = (verifiedDaemonPid == pid)
        daemonCacheLock.unlock()
        if alreadyVerified { return true }

        if isExpectedDaemonProcess(pid: pid, pluginDir: pluginDir) {
            daemonCacheLock.lock()
            verifiedDaemonPid = pid
            daemonCacheLock.unlock()
            return true
        }
        removeStaleDaemonLockIfMatches(pluginDir: pluginDir, stalePid: pid)
        return false
    }

    static func resolveHostGeminiConfigDir(pluginDir: String) -> String? {
        if let envDir = ProcessInfo.processInfo.environment["AG_PRISM_GEMINI_CONFIG_DIR"],
           !envDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: envDir.trimmingCharacters(in: .whitespacesAndNewlines)).standardizedFileURL.path
        }
        let defPlugin = URL(fileURLWithPath: getDefaultNativePluginDir()).standardizedFileURL.path
        let resolvedPlugin = pluginDir.isEmpty
            ? defPlugin
            : URL(fileURLWithPath: pluginDir).standardizedFileURL.path
        if resolvedPlugin == defPlugin {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return (home as NSString).appendingPathComponent(".gemini/config")
        }
        let parent = (resolvedPlugin as NSString).deletingLastPathComponent
        if (parent as NSString).lastPathComponent.caseInsensitiveCompare("plugins") == .orderedSame {
            return (parent as NSString).deletingLastPathComponent
        }
        return nil
    }

    private static func normalizeHostSystemRootPrefix(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let std = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        let clean = (std.count > 1 && std.hasSuffix("/")) ? String(std.dropLast()) : std
        if clean == "/tmp" { return "/private/tmp" }
        if clean.hasPrefix("/tmp/") { return "/private" + clean }
        if clean == "/var" { return "/private/var" }
        if clean.hasPrefix("/var/") { return "/private" + clean }
        return clean
    }

    /// 通过 lstat 检查路径是否为符号链接；除 ENOENT（目标不存在）外，所有非 ENOENT 错误均 Fail-Closed 返回 true。
    static func isSymbolicLinkOrUnsafePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return true }
        var st = stat()
        if lstat(path, &st) != 0 {
            return errno != ENOENT
        }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    /// 检查宿主配置目录祖先链（覆盖 ~/.gemini → cfgDir 或沙盒 .gemini → cfgDir）是否含符号链接或不可验证节点（Fail-Closed）。
    static func hasSymbolicLinkInHostConfigChain(_ cfgDir: String) -> Bool {
        let normDir = normalizeHostSystemRootPrefix(cfgDir)
        if normDir.isEmpty { return true }
        let normHome = normalizeHostSystemRootPrefix(FileManager.default.homeDirectoryForCurrentUser.path)
        let defaultGemini = normHome.isEmpty ? "" : (normHome as NSString).appendingPathComponent(".gemini")
        var stopRoot = normDir
        if !defaultGemini.isEmpty && (normDir == defaultGemini || normDir.hasPrefix(defaultGemini + "/")) {
            stopRoot = defaultGemini
        } else {
            var scan = normDir
            for _ in 0..<64 {
                if (scan as NSString).lastPathComponent.caseInsensitiveCompare(".gemini") == .orderedSame {
                    stopRoot = scan
                    break
                }
                let up = (scan as NSString).deletingLastPathComponent
                if up.isEmpty || up == scan { break }
                scan = up
            }
        }
        var cur = normDir
        var reachedStop = false
        for _ in 0..<64 {
            if isSymbolicLinkOrUnsafePath(cur) { return true }
            if cur == stopRoot {
                reachedStop = true
                break
            }
            let parent = (cur as NSString).deletingLastPathComponent
            if parent.isEmpty || parent == cur { break }
            cur = parent
        }
        return !reachedStop
    }

    private static func atomicWriteJsonObject(_ obj: [String: JsonValue], toFile path: String) throws {
        guard !path.isEmpty else {
            throw CdpError(InstallerI18n.tr("目标文件路径为空", "Target file path is empty"))
        }
        let parentDir = (path as NSString).deletingLastPathComponent
        if hasSymbolicLinkInHostConfigChain(parentDir) {
            throw CdpError(InstallerI18n.tr(
                "目标目录链路包含符号链接或无法安全验证，已拒绝写入: \(parentDir)",
                "Target directory chain contains a symbolic link or cannot be safely verified; write refused: \(parentDir)"
            ))
        }
        if isSymbolicLinkOrUnsafePath(path) {
            throw CdpError(InstallerI18n.tr(
                "目标文件为符号链接或无法安全验证，已拒绝覆盖: \(path)",
                "Target file is a symbolic link or cannot be safely verified; overwrite refused: \(path)"
            ))
        }
        let tmpPath = "\(path).tmp.\(getpid()).\(UUID().uuidString)"
        let content = MiniJson.stringify(.object(obj), pretty: true) + "\n"
        let bytes = Array(content.utf8)
        let openFlags: Int32 = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW
        let fd = open(tmpPath, openFlags, mode_t(0o600))
        if fd < 0 {
            let errCode = errno
            throw CdpError(InstallerI18n.tr(
                "无法安全创建临时文件 \(tmpPath) (errno=\(errCode))",
                "Failed to safely create temporary file \(tmpPath) (errno=\(errCode))"
            ))
        }
        var closed = false
        var committed = false
        defer {
            if !closed {
                _ = close(fd)
            }
            if !committed {
                _ = unlink(tmpPath)
            }
        }
        if !bytes.isEmpty {
            try bytes.withUnsafeBytes { rawBuf in
                guard let baseAddr = rawBuf.baseAddress else { return }
                var totalWritten = 0
                while totalWritten < bytes.count {
                    let remaining = bytes.count - totalWritten
                    let written = write(fd, baseAddr.advanced(by: totalWritten), remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        let errCode = errno
                        throw CdpError(InstallerI18n.tr(
                            "写入临时文件失败 \(tmpPath) (errno=\(errCode))",
                            "Failed to write temporary file \(tmpPath) (errno=\(errCode))"
                        ))
                    }
                    if written == 0 {
                        throw CdpError(InstallerI18n.tr(
                            "写入临时文件提前结束: \(tmpPath)",
                            "Short write while writing temporary file: \(tmpPath)"
                        ))
                    }
                    totalWritten += written
                }
            }
        }
        _ = fsync(fd)
        let closeRc = close(fd)
        closed = true
        if closeRc != 0 {
            let errCode = errno
            throw CdpError(InstallerI18n.tr(
                "关闭临时文件失败 \(tmpPath) (errno=\(errCode))",
                "Failed to close temporary file \(tmpPath) (errno=\(errCode))"
            ))
        }
        if hasSymbolicLinkInHostConfigChain(parentDir) {
            throw CdpError(InstallerI18n.tr(
                "目标目录链路包含符号链接或无法安全验证，已拒绝替换: \(parentDir)",
                "Target directory chain contains a symbolic link or cannot be safely verified; replace refused: \(parentDir)"
            ))
        }
        if isSymbolicLinkOrUnsafePath(path) {
            throw CdpError(InstallerI18n.tr(
                "目标文件为符号链接或无法安全验证，已拒绝覆盖: \(path)",
                "Target file is a symbolic link or cannot be safely verified; overwrite refused: \(path)"
            ))
        }
        if rename(tmpPath, path) != 0 {
            let errCode = errno
            throw CdpError(InstallerI18n.tr(
                "原子替换目标文件失败 \(path) (errno=\(errCode))",
                "Failed to atomically replace target file \(path) (errno=\(errCode))"
            ))
        }
        committed = true
    }

    @discardableResult
    static func syncHostPluginRegistry(pluginDir: String, enable: Bool) -> Bool {
        guard let cfgDir = resolveHostGeminiConfigDir(pluginDir: pluginDir), !cfgDir.isEmpty else {
            return false
        }
        let fm = FileManager.default
        let cfgPath = (cfgDir as NSString).appendingPathComponent("config.json")
        if hasSymbolicLinkInHostConfigChain(cfgDir) || isSymbolicLinkOrUnsafePath(cfgPath) {
            return false
        }
        do {
            if enable {
                try fm.createDirectory(atPath: cfgDir, withIntermediateDirectories: true, attributes: nil)
                if hasSymbolicLinkInHostConfigChain(cfgDir) || isSymbolicLinkOrUnsafePath(cfgPath) {
                    return false
                }
                var rootObj: [String: JsonValue] = [:]
                if fm.fileExists(atPath: cfgPath) {
                    let raw = (try String(contentsOfFile: cfgPath, encoding: .utf8))
                        .replacingOccurrences(of: "\u{FEFF}", with: "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !raw.isEmpty {
                        rootObj = try MiniJson.parseObject(raw)
                    }
                }
                var pluginsObj = rootObj["plugins"]?.objectValue ?? [:]
                var entryObj = pluginsObj["obsidian-prism"]?.objectValue ?? [:]
                entryObj["enabled"] = .bool(true)
                pluginsObj["obsidian-prism"] = .object(entryObj)
                pluginsObj.removeValue(forKey: "antigravity-prism")
                rootObj["plugins"] = .object(pluginsObj)
                try atomicWriteJsonObject(rootObj, toFile: cfgPath)
                return true
            }

            if fm.fileExists(atPath: cfgPath) {
                let raw = (try String(contentsOfFile: cfgPath, encoding: .utf8))
                    .replacingOccurrences(of: "\u{FEFF}", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty, var rootObj = try? MiniJson.parseObject(raw) {
                    var changed = false
                    if var pluginsObj = rootObj["plugins"]?.objectValue {
                        if pluginsObj.removeValue(forKey: "obsidian-prism") != nil { changed = true }
                        if pluginsObj.removeValue(forKey: "antigravity-prism") != nil { changed = true }
                        rootObj["plugins"] = .object(pluginsObj)
                    }
                    if var sidecarsObj = rootObj["sidecars"]?.objectValue {
                        if sidecarsObj.removeValue(forKey: "obsidian-prism/daemon") != nil { changed = true }
                        rootObj["sidecars"] = .object(sidecarsObj)
                    }
                    if changed {
                        try atomicWriteJsonObject(rootObj, toFile: cfgPath)
                    }
                }
            }
            // Remove ephemeral translation cache while strictly preserving user secret file obsidian-prism-thought.json
            let cacheFile = (cfgDir as NSString).appendingPathComponent("obsidian-prism-thought-cache.json")
            if !isSymbolicLinkOrUnsafePath(cacheFile) && fm.fileExists(atPath: cacheFile) {
                try? fm.removeItem(atPath: cacheFile)
            }
            return true
        } catch {
            return false
        }
    }

    static func findAntigravityNodeRuntime(preferredApp: String? = nil) -> (executable: String, runAsNode: Bool)? {
        let fm = FileManager.default
        if let envExe = ProcessInfo.processInfo.environment["AG_PRISM_ELECTRON_EXE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envExe.isEmpty, fm.isExecutableFile(atPath: envExe) {
            return (envExe, true)
        }
        let home = fm.homeDirectoryForCurrentUser.path
        var appBundles: [String] = []
        if let pref = preferredApp?.trimmingCharacters(in: .whitespacesAndNewlines), !pref.isEmpty {
            appBundles.append(pref)
        }
        appBundles.append("/Applications/Antigravity.app")
        appBundles.append((home as NSString).appendingPathComponent("Applications/Antigravity.app"))

        let relBinaries = [
            "Contents/Frameworks/Antigravity Helper.app/Contents/MacOS/Antigravity Helper",
            "Contents/Frameworks/Antigravity Helper (Plugin).app/Contents/MacOS/Antigravity Helper (Plugin)",
            "Contents/MacOS/Antigravity",
        ]
        for bundle in appBundles {
            for rel in relBinaries {
                let candidate = (bundle as NSString).appendingPathComponent(rel)
                if fm.isExecutableFile(atPath: candidate) {
                    return (candidate, true)
                }
            }
        }
        return nil
    }

    static func findFallbackNodeExecutable() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"], !pathEnv.isEmpty {
            for seg in pathEnv.split(separator: ":") {
                let dir = String(seg).trimmingCharacters(in: .whitespacesAndNewlines)
                if !dir.isEmpty {
                    candidates.append((dir as NSString).appendingPathComponent("node"))
                }
            }
        }
        candidates.append("/opt/homebrew/bin/node")
        candidates.append("/usr/local/bin/node")
        candidates.append((home as NSString).appendingPathComponent(".volta/bin/node"))
        candidates.append((home as NSString).appendingPathComponent(".local/share/fnm/aliases/default/bin/node"))
        candidates.append((home as NSString).appendingPathComponent("Library/Application Support/fnm/aliases/default/bin/node"))

        for cand in candidates {
            if fm.isExecutableFile(atPath: cand) { return cand }
        }

        let nvmVersions = (home as NSString).appendingPathComponent(".nvm/versions/node")
        if let dirs = try? fm.contentsOfDirectory(atPath: nvmVersions) {
            for ver in dirs.sorted().reversed() {
                let cand = ((nvmVersions as NSString).appendingPathComponent(ver) as NSString)
                    .appendingPathComponent("bin/node")
                if fm.isExecutableFile(atPath: cand) { return cand }
            }
        }
        return nil
    }

    @discardableResult
    static func ensureNativeDaemonRunning(
        pluginDir: String,
        cdpPort: Int? = nil,
        preferredApp: String? = nil,
        log: ((String) -> Void)? = nil
    ) -> Bool {
        if ProcessInfo.processInfo.environment["AG_PRISM_NO_NATIVE_DAEMON"] == "1" {
            return false
        }
        guard !pluginDir.isEmpty else { return false }
        if isNativeDaemonAlive(pluginDir: pluginDir) { return true }

        let daemonEntry = (pluginDir as NSString).appendingPathComponent("sidecars/daemon/main.mjs")
        guard FileManager.default.fileExists(atPath: daemonEntry) else { return false }

        let runtime: (executable: String, runAsNode: Bool)?
        if let electronRt = findAntigravityNodeRuntime(preferredApp: preferredApp) {
            runtime = electronRt
        } else if let nodeBin = findFallbackNodeExecutable() {
            runtime = (nodeBin, false)
        } else {
            runtime = nil
        }
        guard let rt = runtime else { return false }

        var args = [daemonEntry, "--root", pluginDir]
        if let port = cdpPort, port > 0 {
            args.append("--port")
            args.append(String(port))
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: rt.executable)
        proc.arguments = args
        proc.currentDirectoryURL = URL(fileURLWithPath: pluginDir)
        var env = ProcessInfo.processInfo.environment
        if rt.runAsNode {
            env["ELECTRON_RUN_AS_NODE"] = "1"
        } else {
            env.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        }
        proc.environment = env
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            let rtLabel = rt.runAsNode ? "Electron RunAsNode" : "Node.js"
            let deadline = Date().addingTimeInterval(3.0)
            while Date() < deadline {
                if isNativeDaemonAlive(pluginDir: pluginDir) {
                    log?(InstallerI18n.tr(
                        "已自举启动五通道原生 Sidecar Daemon (\(rtLabel))",
                        "Bootstrapped native 5-channel Sidecar Daemon (\(rtLabel))"
                    ))
                    return true
                }
                if !proc.isRunning { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return isNativeDaemonAlive(pluginDir: pluginDir)
        } catch {
            return false
        }
    }

    static let cdpOptInFlag = "--remote-debugging-port=0"

    private static func nowEpochMs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    static func parseBsdElapsedSeconds(_ raw: String) -> Int64 {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return 0 }
        var days: Int64 = 0
        var timePart = s
        if let dashIdx = s.firstIndex(of: "-") {
            days = Int64(s[..<dashIdx]) ?? 0
            timePart = String(s[s.index(after: dashIdx)...])
        }
        let parts = timePart.split(separator: ":").compactMap { Int64($0) }
        if parts.count == 3 {
            return days * 86400 + parts[0] * 3600 + parts[1] * 60 + parts[2]
        }
        if parts.count == 2 {
            return days * 86400 + parts[0] * 60 + parts[1]
        }
        return Int64(timePart) ?? 0
    }

    static func findBareAntigravityMainProcess() -> BareHostAppInfo? {
        let env = ProcessInfo.processInfo.environment
        if let mockPidStr = env["AG_PRISM_MOCK_BARE_HOST_PID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           let mockPid = Int32(mockPidStr), mockPid > 0, kill(mockPid, 0) == 0 {
            let forcedUptime = Int64(env["AG_PRISM_MOCK_BARE_HOST_UPTIME_MS"] ?? "") ?? 10000
            let nowMs = nowEpochMs()
            let appPath = env["AG_PRISM_MOCK_BARE_HOST_APP"] ?? "/Applications/Antigravity.app"
            return BareHostAppInfo(pid: mockPid, appPath: appPath, startTimeMs: nowMs - forcedUptime, uptimeMs: forcedUptime)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-ax", "-o", "pid=,etime=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let out = String(data: data, encoding: .utf8) else { return nil }
            let nowMs = nowEpochMs()
            var candidate: BareHostAppInfo?
            for rawLine in out.components(separatedBy: CharacterSet.newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                let cols = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
                guard cols.count == 3, let pid = Int32(cols[0]), pid > 0 else { continue }
                let elapsedSec = parseBsdElapsedSeconds(String(cols[1]))
                let cmd = String(cols[2])
                let lowerCmd = cmd.lowercased()
                guard let appRange = lowerCmd.range(of: ".app/contents/macos/antigravity") else { continue }
                let afterSuffix = lowerCmd[appRange.upperBound...]
                if !afterSuffix.isEmpty && afterSuffix.first != " " && afterSuffix.first != "\"" {
                    // Excludes "Antigravity Helper" and other helper binaries
                    continue
                }
                if lowerCmd.contains("--type=") ||
                   lowerCmd.contains("sidecar_sdk") ||
                   lowerCmd.contains("main.mjs") ||
                   lowerCmd.contains("watch.js") {
                    continue
                }
                if lowerCmd.contains("--remote-debugging-port") {
                    return nil
                }
                if candidate == nil {
                    let prefixUpToApp = String(cmd[..<appRange.lowerBound]) + ".app"
                    let appPath = normalizeAntigravityAppPath(prefixUpToApp)
                    let uptimeMs = max(0, elapsedSec * 1000)
                    let startMs = nowMs - uptimeMs
                    candidate = BareHostAppInfo(pid: pid, appPath: appPath, startTimeMs: startMs, uptimeMs: uptimeMs)
                }
            }
            return candidate
        } catch {
            return nil
        }
    }

    static func hasPromptedForHost(pid: Int32, startTimeMs: Int64, installDir: String, pluginDir: String) -> Bool {
        guard pid > 0 else { return true }
        if !pluginDir.isEmpty {
            let pFile = (pluginDir as NSString).appendingPathComponent(".relaunch-prompt-state.json")
            if stateFileMatchesHost(filePath: pFile, hostPid: pid, startTimeMs: startTimeMs) { return true }
        }
        if !installDir.isEmpty {
            let iFile = (installDir as NSString).appendingPathComponent(".relaunch-prompt-state.json")
            if stateFileMatchesHost(filePath: iFile, hostPid: pid, startTimeMs: startTimeMs) { return true }
        }
        return false
    }

    static func recordPromptedForHost(pid: Int32, startTimeMs: Int64, decision: String, installDir: String, pluginDir: String) {
        guard pid > 0 else { return }
        let hostKey = "\(pid):\(startTimeMs)"
        let obj: [String: JsonValue] = [
            "hostPid": .int(Int64(pid)),
            "hostStartMs": .int(startTimeMs),
            "startTimeMs": .int(startTimeMs),
            "hostKey": .string(hostKey),
            "key": .string(hostKey),
            "decision": .string(decision.isEmpty ? "prompted" : decision),
            "updatedAt": .int(nowEpochMs()),
        ]
        for dir in [pluginDir, installDir] where !dir.isEmpty {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
            let path = (dir as NSString).appendingPathComponent(".relaunch-prompt-state.json")
            try? atomicWriteJsonObject(obj, toFile: path)
        }
    }

    static func escapeAppleScriptString(_ s: String) -> String {
        return s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    static func normalizeAntigravityAppPath(_ rawPath: String) -> String {
        let fm = FileManager.default
        let fallbackSystem = "/Applications/Antigravity.app"
        let fallbackUser = (fm.homeDirectoryForCurrentUser.path as NSString).appendingPathComponent("Applications/Antigravity.app")
        let defaultFallback = (!fm.fileExists(atPath: fallbackSystem) && fm.fileExists(atPath: fallbackUser))
            ? fallbackUser
            : fallbackSystem

        let trimmed = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
        if trimmed.isEmpty {
            return defaultFallback
        }
        let std = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        let clean = (std.count > 1 && std.hasSuffix("/")) ? String(std.dropLast()) : std

        var normalized = clean
        if let innerRange = clean.range(of: ".app/contents/", options: .caseInsensitive) {
            let cutEnd = clean.index(innerRange.lowerBound, offsetBy: 4)
            normalized = String(clean[..<cutEnd])
        } else if let slashRange = clean.range(of: ".app/", options: .caseInsensitive) {
            let cutEnd = clean.index(slashRange.lowerBound, offsetBy: 4)
            normalized = String(clean[..<cutEnd])
        }

        if normalized.lowercased().hasSuffix(".app") {
            if fm.fileExists(atPath: normalized) {
                return normalized
            }
            return defaultFallback
        }
        return defaultFallback
    }

    static func getAntigravitySingletonLockPath() -> String {
        if let overridePath = ProcessInfo.processInfo.environment["AG_PRISM_SINGLETON_LOCK_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath).standardizedFileURL.path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent("Library/Application Support/Antigravity/SingletonLock")
    }

    static func isSingletonLockHeld(lockPath: String = getAntigravitySingletonLockPath()) -> Bool {
        guard !lockPath.isEmpty else { return false }
        var st = stat()
        if lstat(lockPath, &st) != 0 {
            return false
        }
        if (st.st_mode & S_IFMT) == S_IFLNK {
            if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: lockPath),
               let dashIdx = dest.lastIndex(of: "-") {
                let pidText = String(dest[dest.index(after: dashIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let lockPid = Int32(pidText), lockPid > 0 {
                    return kill(lockPid, 0) == 0
                }
            }
            return true
        }
        return true
    }

    private static func isSidecarOrWatcherCommand(_ lowerCmd: String) -> Bool {
        return lowerCmd.contains("sidecars/daemon/main.mjs") ||
            lowerCmd.contains("/daemon/main.mjs") ||
            lowerCmd.contains("sidecar_sdk") ||
            lowerCmd.contains("obsidian-prism-watcher") ||
            lowerCmd.contains("obsidian-prism") ||
            lowerCmd.contains("antigravity-prism") ||
            lowerCmd.contains("agy-claude-style") ||
            lowerCmd.contains("/watch.js")
    }

    static func listRunningAppFamilyPids(appPath: String, mainPid: Int32 = 0) -> [Int32] {
        let normalizedApp = normalizeAntigravityAppPath(appPath)
        let selfPid = getpid()
        let parentPid = getppid()

        var prefixes: [String] = []
        let appVariants = [normalizedApp, normalizeHostSystemRootPrefix(normalizedApp)]
        for variant in appVariants where !variant.isEmpty {
            let lower = variant.lowercased()
            let macosPfx = lower + "/contents/macos/"
            let fwPfx = lower + "/contents/frameworks/"
            if !prefixes.contains(macosPfx) { prefixes.append(macosPfx) }
            if !prefixes.contains(fwPfx) { prefixes.append(fwPfx) }
        }

        var pids = Set<Int32>()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-ax", "-o", "pid=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if let out = String(data: data, encoding: .utf8) {
                for rawLine in out.components(separatedBy: CharacterSet.newlines) {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    if line.isEmpty { continue }
                    let cols = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
                    guard cols.count == 2,
                          let pid = Int32(cols[0]),
                          pid > 0,
                          pid != selfPid,
                          pid != parentPid else { continue }
                    let lowerCmd = String(cols[1]).replacingOccurrences(of: "\\", with: "/").lowercased()
                    if isSidecarOrWatcherCommand(lowerCmd) { continue }
                    if prefixes.contains(where: { lowerCmd.contains($0) }) {
                        pids.insert(pid)
                    }
                }
            }
        } catch {}

        if mainPid > 0 && mainPid != selfPid && mainPid != parentPid && kill(mainPid, 0) == 0 {
            pids.insert(mainPid)
        }
        return pids.sorted()
    }

    static func findRunningAntigravityWithCdp(appPath: String) -> Int32? {
        let normalizedApp = normalizeAntigravityAppPath(appPath)
        let macosPfx = normalizedApp.lowercased() + "/contents/macos/"
        let sysMacosPfx = normalizeHostSystemRootPrefix(normalizedApp).lowercased() + "/contents/macos/"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-ax", "-o", "pid=,command="]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let out = String(data: data, encoding: .utf8) else { return nil }
            for rawLine in out.components(separatedBy: CharacterSet.newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                let cols = line.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
                guard cols.count == 2, let pid = Int32(cols[0]), pid > 0 else { continue }
                let lowerCmd = String(cols[1]).replacingOccurrences(of: "\\", with: "/").lowercased()
                if isSidecarOrWatcherCommand(lowerCmd) || lowerCmd.contains("--type=") { continue }
                let matchesApp = lowerCmd.contains(macosPfx) || (!sysMacosPfx.isEmpty && lowerCmd.contains(sysMacosPfx))
                if matchesApp && lowerCmd.contains("--remote-debugging-port") {
                    return pid
                }
            }
        } catch {}
        return nil
    }

    static func promptUserForCdpRelaunch() -> Bool {
        if let mockDec = ProcessInfo.processInfo.environment["AG_PRISM_MOCK_RELAUNCH_DECISION"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mockDec.isEmpty {
            return mockDec.caseInsensitiveCompare("yes") == .orderedSame || mockDec == "1"
        }
        let laterBtn = InstallerI18n.tr("稍后手动重开", "Later")
        let relaunchBtn = InstallerI18n.tr("立即重新打开", "Relaunch Now")
        let dialogTitle = InstallerI18n.tr(
            "Obsidian Prism · 恢复界面连接",
            "Obsidian Prism · Restore UI Connection"
        )
        let dialogMessage = InstallerI18n.tr(
            "检测到 Antigravity 已升级或无参启动，尚未开启本地光学桥接端口（--remote-debugging-port=0）。\n\n是否立即重新打开 Antigravity 以恢复 Obsidian Prism（黑曜棱镜）界面？",
            "Antigravity appears to have updated or launched without the local optical bridge flag (--remote-debugging-port=0).\n\nRelaunch Antigravity now to restore the Obsidian Prism interface?"
        )
        let escMsg = escapeAppleScriptString(dialogMessage)
        let escTitle = escapeAppleScriptString(dialogTitle)
        let escLater = escapeAppleScriptString(laterBtn)
        let escRelaunch = escapeAppleScriptString(relaunchBtn)
        let script = "display dialog \"\(escMsg)\" with title \"\(escTitle)\" buttons {\"\(escLater)\", \"\(escRelaunch)\"} default button \"\(escRelaunch)\""
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 { return false }
            let out = String(data: data, encoding: .utf8) ?? ""
            return out.contains(relaunchBtn)
        } catch {
            return false
        }
    }

    @discardableResult
    static func relaunchAntigravityWithCdp(host: BareHostAppInfo, waitExitMs: Int = 15000, abortIfStillAlive: Bool = false, log: ((String) -> Void)? = nil) -> Bool {
        guard host.pid > 0 else { return false }
        let normalizedAppPath = normalizeAntigravityAppPath(host.appPath)
        let appBaseName = (normalizedAppPath as NSString).lastPathComponent

        // Prefer native NSRunningApplication.terminate() to avoid macOS AppleEvents TCC prompts;
        // fall back to AppleScript quit and SIGTERM if unavailable.
        var quitSent = requestNativeGracefulQuit(pid: host.pid)
        if !quitSent {
            let quitScript: String
            if normalizedAppPath == "/Applications/Antigravity.app" ||
               appBaseName.caseInsensitiveCompare("Antigravity.app") == .orderedSame {
                quitScript = "tell application \"Antigravity\" to quit"
            } else {
                let escapedPath = escapeAppleScriptString(normalizedAppPath)
                quitScript = "tell application (POSIX file \"\(escapedPath)\" as text) to quit"
            }
            let quitProc = Process()
            quitProc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            quitProc.arguments = ["-e", quitScript]
            quitProc.standardOutput = FileHandle.nullDevice
            quitProc.standardError = FileHandle.nullDevice
            do {
                try quitProc.run()
                quitProc.waitUntilExit()
                quitSent = (quitProc.terminationStatus == 0)
            } catch {}
        }
        if !quitSent && kill(host.pid, 0) == 0 {
            _ = kill(host.pid, SIGTERM)
        }

        let lockPath = getAntigravitySingletonLockPath()
        let softDeadline = Date().addingTimeInterval(Double(min(10000, max(1500, waitExitMs))) / 1000.0)
        var aliveFamilyPids = listRunningAppFamilyPids(appPath: normalizedAppPath, mainPid: host.pid)
        var lockHeld = isSingletonLockHeld(lockPath: lockPath)
        while Date() < softDeadline {
            if aliveFamilyPids.isEmpty && !lockHeld { break }
            Thread.sleep(forTimeInterval: 0.12)
            aliveFamilyPids = listRunningAppFamilyPids(appPath: normalizedAppPath, mainPid: host.pid)
            lockHeld = isSingletonLockHeld(lockPath: lockPath)
        }

        if !aliveFamilyPids.isEmpty {
            for pid in aliveFamilyPids {
                if pid > 0 && pid != getpid() && pid != getppid() && kill(pid, 0) == 0 {
                    _ = kill(pid, SIGTERM)
                }
            }
            let hardDeadline = Date().addingTimeInterval(4.0)
            while Date() < hardDeadline {
                aliveFamilyPids = listRunningAppFamilyPids(appPath: normalizedAppPath, mainPid: host.pid)
                lockHeld = isSingletonLockHeld(lockPath: lockPath)
                if aliveFamilyPids.isEmpty && !lockHeld { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        } else if lockHeld {
            let lockDeadline = Date().addingTimeInterval(2.0)
            while Date() < lockDeadline {
                lockHeld = isSingletonLockHeld(lockPath: lockPath)
                if !lockHeld { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }

        if !aliveFamilyPids.isEmpty || lockHeld {
            if abortIfStillAlive {
                log?(InstallerI18n.tr(
                    "等待 Antigravity 退净超时（残留进程数=\(aliveFamilyPids.count)，SingletonLock占用=\(lockHeld)），已安全中止自动重开",
                    "Timed out waiting for Antigravity to exit (remaining=\(aliveFamilyPids.count), SingletonLockHeld=\(lockHeld)); aborting auto-relaunch safely"
                ))
                return false
            }
            log?(InstallerI18n.tr(
                "等待 Antigravity 退净超时（残留进程数=\(aliveFamilyPids.count)，SingletonLock占用=\(lockHeld)），仍将尝试以新实例拉起",
                "Timed out waiting for Antigravity to fully exit (remaining=\(aliveFamilyPids.count), SingletonLockHeld=\(lockHeld)); proceeding with new instance launch"
            ))
        }

        // Wait an extra 0.5s after full exit so LaunchServices finishes unregistering the old instance.
        Thread.sleep(forTimeInterval: 0.5)

        let launchStartedAt = Date()
        let openProc = Process()
        openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProc.arguments = ["-na", normalizedAppPath, "--args", cdpOptInFlag]
        var cleanEnv = ProcessInfo.processInfo.environment
        cleanEnv.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        openProc.environment = cleanEnv
        openProc.standardOutput = FileHandle.nullDevice
        openProc.standardError = FileHandle.nullDevice
        do {
            try openProc.run()
            openProc.waitUntilExit()
            guard openProc.terminationStatus == 0 else {
                log?(InstallerI18n.tr(
                    "重新打开 \(normalizedAppPath) 失败（open 退出码 \(openProc.terminationStatus)）",
                    "Failed to relaunch \(normalizedAppPath) (open exited with code \(openProc.terminationStatus))"
                ))
                return false
            }

            var confirmedPort: Int? = nil
            var confirmedPid: Int32? = nil
            let verifyDeadline = Date().addingTimeInterval(3.0)
            let portFile = getPortFilePath()
            while Date() < verifyDeadline {
                if let p = readPort(overridePort: nil) {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: portFile)
                    let mtime = attrs?[.modificationDate] as? Date
                    let isFresh = (mtime != nil && mtime!.timeIntervalSince(launchStartedAt) >= -0.5)
                    if isFresh || (try? listPages(port: p)) != nil {
                        confirmedPort = p
                        break
                    }
                }
                if let cdpPid = findRunningAntigravityWithCdp(appPath: normalizedAppPath) {
                    confirmedPid = cdpPid
                    break
                }
                Thread.sleep(forTimeInterval: 0.15)
            }

            if let p = confirmedPort {
                log?(InstallerI18n.tr(
                    "已带 \(cdpOptInFlag) 以新实例重新打开 \(normalizedAppPath)（检测到 DevToolsActivePort=\(p)）",
                    "Relaunched new instance of \(normalizedAppPath) with \(cdpOptInFlag) (DevToolsActivePort=\(p) ready)"
                ))
            } else if let cdpPid = confirmedPid {
                log?(InstallerI18n.tr(
                    "已带 \(cdpOptInFlag) 以新实例重新打开 \(normalizedAppPath)（新进程 PID \(cdpPid) 已存活）",
                    "Relaunched new instance of \(normalizedAppPath) with \(cdpOptInFlag) (new process PID \(cdpPid) alive)"
                ))
            } else {
                log?(InstallerI18n.tr(
                    "已带 \(cdpOptInFlag) 发起新实例启动 \(normalizedAppPath)，正在等待调试端口就绪",
                    "Dispatched new instance launch for \(normalizedAppPath) with \(cdpOptInFlag); waiting for DevToolsActivePort"
                ))
            }
            return true
        } catch {
            log?(InstallerI18n.tr(
                "重新打开 \(normalizedAppPath) 异常: \(error.localizedDescription)",
                "Exception while relaunching \(normalizedAppPath): \(error.localizedDescription)"
            ))
            return false
        }
    }

    static func readRuntimeBundle(baseDir: String, manifest: PluginManifest) throws -> String {
        var partsContent: [String] = []
        partsContent.reserveCapacity(manifest.parts.count)
        for part in manifest.parts {
            let p = (baseDir as NSString).appendingPathComponent(part)
            partsContent.append(try String(contentsOfFile: p, encoding: .utf8))
        }
        return partsContent.joined(separator: "\n")
    }

    static func buildConfigRefreshExpression(baseDir: String, manifest: PluginManifest) -> String {
        var nextCfg = readConfig(baseDir: baseDir, manifest: manifest)
        let codeHash = (try? readRuntimeBundle(baseDir: baseDir, manifest: manifest)).map { computeHash($0) } ?? ""
        nextCfg["binding"] = .string(manifest.settingBinding)
        if !codeHash.isEmpty { nextCfg["codeHash"] = .string(codeHash) }
        nextCfg["__fromFile"] = .bool(true)
        let cfgJson = MiniJson.stringify(.object(nextCfg), pretty: false)
        let verJson = MiniJson.stringifyString(manifest.version)
        let hashJson = MiniJson.stringifyString(codeHash)
        var sb = ""
        sb.reserveCapacity(cfgJson.count + 768)
        sb.append("(() => {\n")
        sb.append("    const nextCfg = ")
        sb.append(cfgJson)
        sb.append(";\n")
        sb.append("    const api = window.__agPrism || window.__agClaudeStyle;\n")
        sb.append("    if (!api || api.version !== ")
        sb.append(verJson)
        sb.append(" || typeof api.refreshConfig !== 'function') return { ok: false, refreshed: false };\n")
        sb.append("    if (")
        sb.append(hashJson)
        sb.append(" && api.codeHash && api.codeHash !== ")
        sb.append(hashJson)
        sb.append(") return { ok: false, refreshed: false };\n")
        sb.append("    api.refreshConfig(nextCfg);\n")
        sb.append("    const liveState = typeof api.getState === 'function' ? api.getState() : null;\n")
        sb.append("    const effectiveCfg = (liveState && liveState.cfg) || nextCfg;\n")
        sb.append("    try { window.__agPrismTelemetry?.sync?.(effectiveCfg); } catch {}\n")
        sb.append("    try { window.__agPrismEffortSlider?.sync?.(effectiveCfg); } catch {}\n")
        sb.append("    try { window.__agPrismThought?.sync?.(effectiveCfg); } catch {}\n")
        sb.append("    try { window.__agPrismInlineDiff?.sync?.(effectiveCfg); } catch {}\n")
        sb.append("    try { if (effectiveCfg.omniModule === 'off') window.__agPrismOmni?.destroy?.(); else window.__agPrismOmni?.sync?.(effectiveCfg, window.__agPrismOmniServerMeta || null); } catch {}\n")
        sb.append("    if (effectiveCfg && effectiveCfg.sidebarStudio !== 'on') {\n")
        sb.append("      try { window.__agPrismSidebar?.sync?.(effectiveCfg, window.__agPrismSidebarMeta || null); } catch {}\n")
        sb.append("      try { window.__agPrismSidebar?.destroy?.(); } catch {}\n")
        sb.append("      try { delete window.__agPrismSidebar; } catch {}\n")
        sb.append("      try { if (document.documentElement) ['data-ag-prism-mode', 'data-ag-prism-chat-kind', 'data-ag-prism-chat-telemetry', 'data-ag-cs-space', 'data-ag-cs-space-palette', 'data-ag-cs-space-accent'].forEach((a) => document.documentElement.removeAttribute(a)); } catch {}\n")
        sb.append("    } else {\n")
        sb.append("      try { window.__agPrismSidebar?.sync?.(effectiveCfg, window.__agPrismSidebarMeta || null); } catch {}\n")
        sb.append("    }\n")
        sb.append("    try { const hiMode = effectiveCfg.hostLocalization; const hiLang = effectiveCfg.language; const navL = String((typeof navigator !== 'undefined' && ((navigator.languages && navigator.languages[0]) || navigator.language)) || '').trim(); if (hiMode === 'off') window.__agPrismHostI18n?.setMode?.('off'); else if (hiMode === 'on') window.__agPrismHostI18n?.setMode?.('on'); else if ((hiLang && hiLang !== 'zh-CN' && hiLang !== 'tr' && hiLang !== 'ru' && hiLang !== 'auto') || ((!hiLang || hiLang === 'auto') && navL && !/^(?:zh(?:$|-(?:cn|hans|sg)(?:-|$))|tr(?:$|-)|ru(?:$|-))/i.test(navL))) window.__agPrismHostI18n?.destroy?.(); else window.__agPrismHostI18n?.setMode?.('auto'); } catch {}\n")
        sb.append("    if (document.documentElement) {\n")
        sb.append("      if (effectiveCfg && effectiveCfg.thoughtTranslate && effectiveCfg.thoughtTranslate !== 'off') document.documentElement.setAttribute('data-ag-prism-thought-view', effectiveCfg.thoughtView === 'bilingual' ? 'bilingual' : 'immersive');\n")
        sb.append("      else document.documentElement.removeAttribute('data-ag-prism-thought-view');\n")
        sb.append("      document.documentElement.setAttribute('data-ag-prism-sidebar-studio', effectiveCfg && effectiveCfg.sidebarStudio === 'on' ? 'on' : 'off');\n")
        sb.append("    }\n")
        sb.append("    return { ok: true, refreshed: true, state: liveState };\n")
        sb.append("  })()")
        return sb
    }

    static func buildOmniClientExpression(baseDir: String, manifest: PluginManifest) -> String {
        let omniPath = (baseDir as NSString).appendingPathComponent("vendor/omni-viewer/omni-client.js")
        guard let clientSource = try? String(contentsOfFile: omniPath, encoding: .utf8), !clientSource.isEmpty else {
            return ""
        }
        let config = readConfig(baseDir: baseDir, manifest: manifest)
        let cfgJson = MiniJson.stringify(.object(config), pretty: false)
        let hashJson = MiniJson.stringifyString(computeHash(clientSource))
        var sb = ""
        sb.reserveCapacity(clientSource.count + cfgJson.count + 1024)
        sb.append(
            "(() => {\n" +
            "  const href = String((typeof location !== 'undefined' && location && location.href) || '');\n" +
            "  const ttl = String((typeof document !== 'undefined' && document && document.title) || '').trim();\n" +
            "  if (/^(?:untitled|launchpad)$/i.test(ttl) || /\\/launchpad(?:\\.html)?(?:[?#]|$)/i.test(href)) return { ok: false, skipped: true };\n" +
            "  if (/^(devtools:|chrome:|chrome-extension:|edge:|about:|data:|blob:|plugin:)/i.test(href)) return { ok: false, skipped: true };\n" +
            "  if (/^https?:\\/\\/(127\\.0\\.0\\.1|localhost|\\[::1\\])(?::\\d+)?\\/(?:viewer|sandbox|stream|api)(?:[/?#]|$)/i.test(href)) return { ok: false, skipped: true };\n" +
            "  const bootCfg = "
        )
        sb.append(cfgJson)
        sb.append(";\n  const nextHash = ")
        sb.append(hashJson)
        sb.append(
            ";\n  const liveCfg = (window.__agPrism && typeof window.__agPrism.getState === 'function' && window.__agPrism.getState()?.cfg) || bootCfg;\n" +
            "  const serverMeta = window.__agPrismOmniServerMeta || null;\n" +
            "  const prev = window.__agPrismOmni;\n" +
            "  const reused = Boolean(prev && prev.codeHash === nextHash && typeof prev.sync === 'function');\n" +
            "  if (!reused) {\n    try { prev?.destroy?.(); } catch {}\n    "
        )
        sb.append(clientSource)
        sb.append(
            "\n    if (window.__agPrismOmni && typeof window.__agPrismOmni === 'object') { try { window.__agPrismOmni.codeHash = nextHash; } catch {} }\n" +
            "  }\n  try { window.__agPrismOmni?.sync?.(liveCfg, serverMeta); } catch {}\n" +
            "  if (liveCfg && liveCfg.omniModule === 'off') return { ok: true, status: 'disabled' };\n" +
            "  return { ok: true, status: reused ? 'synced' : (window.__agPrismOmni ? 'mounted' : 'ready') };\n})()"
        )
        return sb
    }

    static let thoughtRemoveExpression: String = """
    (() => {
      try { window.__agPrismThought?.destroy?.(); } catch {}
      try { document.querySelectorAll?.('[data-testid="prism-thought-ai-config"]')?.forEach?.((el) => el.remove()); } catch {}
      try { delete window.__agPrismThought; } catch {}
      try { delete globalThis.__agPrismThought; } catch {}
      try { delete window.__agPrismThoughtSettingsUi; } catch {}
      try { delete globalThis.__agPrismThoughtSettingsUi; } catch {}
      try {
        const sec = document.getElementById?.('ag-cs-settings-sec') || document.getElementById?.('ag-prism-settings-sec');
        if (sec) {
          sec.__prismThoughtUiHandle = null;
          sec.__prismMountThoughtUi?.();
        }
      } catch {}
      return { ok: true, status: 'off' };
    })()
    """

    static func shouldEnableThought(_ cfg: [String: JsonValue]?) -> Bool {
        guard let cfg = cfg else { return false }
        let reconciled = reconcileConfigAliases(cfg)
        guard let rawStr = reconciled["thoughtTranslate"]?.stringValue else { return false }
        let raw = rawStr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if raw.isEmpty || raw == "off" || raw == "false" || raw == "0" || raw == "none" {
            return false
        }
        return raw == "machine" || raw == "ai" || raw == "on" || raw == "auto"
    }

    static func resolveSafePluginFile(baseDir: String, relPath: String) -> String? {
        let trimmedBase = baseDir.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty, !relPath.isEmpty else { return nil }
        let rootUrl = URL(fileURLWithPath: trimmedBase).resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = rootUrl.path.hasSuffix("/") ? rootUrl.path : (rootUrl.path + "/")
        let targetUrl = rootUrl.appendingPathComponent(relPath).resolvingSymlinksInPath().standardizedFileURL
        guard targetUrl.path.hasPrefix(rootPrefix) else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetUrl.path, isDirectory: &isDir), !isDir.boolValue else {
            return nil
        }
        return targetUrl.path
    }

    static func buildThoughtExpression(baseDir: String, manifest: PluginManifest) -> String {
        let config = readConfig(baseDir: baseDir, manifest: manifest)
        return buildThoughtExpression(baseDir: baseDir, cfg: config)
    }

    private static let subchannelHostGuardPrefix: String =
        "(() => {\n" +
        "  try { if (window.self !== window.top) return { ok: false, status: 'skipped-subframe' }; } catch { return { ok: false, status: 'skipped-subframe' }; }\n" +
        "  const hasDomMarker = () => {\n" +
        "    try {\n" +
        "      if (document.body && document.body.classList && (document.body.classList.contains('theme-standalone') || document.body.classList.contains('monaco-workbench'))) return true;\n" +
        "      return Boolean(typeof document.querySelector === 'function' && document.querySelector('.agy-shell, .agy-home, [data-testid=\"aux-pane-split\"], [data-testid=\"conversation-view\"], [data-testid=\"agent-input-box\"], [data-testid=\"model-selector-trigger\"], .monaco-workbench'));\n" +
        "    } catch { return false; }\n" +
        "  };\n" +
        "  let needDomMarkerOnReady = false;\n" +
        "  let isPlainHttpLocalhost = false;\n" +
        "  try {\n" +
        "    const loc = typeof window !== 'undefined' && window.location;\n" +
        "    const href = loc && typeof loc.href === 'string' ? loc.href : '';\n" +
        "    if (href) {\n" +
        "      const low = href.toLowerCase();\n" +
        "      if (low.startsWith('devtools://') || low.startsWith('data:') || low.startsWith('chrome:') || low.startsWith('chrome-extension:') || low.startsWith('edge:') || low.startsWith('blob:') || low.startsWith('plugin:')) return { ok: false, status: 'skipped-non-host' };\n" +
        "      if (low.startsWith('vscode-file://') || low.startsWith('app://') || low.startsWith('about:')) {\n" +
        "        const ttl = String(document.title || '').trim();\n" +
        "        if (/^(?:untitled|launchpad)$/i.test(ttl) || /\\/launchpad(?:\\.html)?(?:[?#]|$)/i.test(low)) return { ok: false, status: 'skipped-non-host' };\n" +
        "      }\n" +
        "      if (low.startsWith('http:') || low.startsWith('https:')) {\n" +
        "        const m = /^(https?):\\/\\/(127\\.0\\.0\\.1|localhost|\\[::1\\])(?::\\d+)?(\\/[^?#]*)?(?:[?#]|$)/i.exec(href);\n" +
        "        if (!m) return { ok: false, status: 'skipped-non-host' };\n" +
        "        const pathname = (m[3] || '/').toLowerCase();\n" +
        "        if (/^\\/(?:viewer(?:\\/|$)|sandbox(?:\\/|$)|stream(?:\\/|$)|api(?:\\/|$))/.test(pathname)) return { ok: false, status: 'skipped-non-host' };\n" +
        "        if (!hasDomMarker()) {\n" +
        "          isPlainHttpLocalhost = m[1].toLowerCase() === 'http';\n" +
        "          const rs = String(document.readyState || '');\n" +
        "          if (isPlainHttpLocalhost) { if (rs === 'loading') needDomMarkerOnReady = true; else return { ok: false, status: 'skipped-non-host' }; }\n" +
        "          else if (!/\\bantigravity\\b/i.test(String(document.title || ''))) { if (rs === 'loading') needDomMarkerOnReady = true; else return { ok: false, status: 'skipped-non-host' }; }\n" +
        "        }\n" +
        "      }\n" +
        "    }\n" +
        "  } catch {}\n"

    static func buildThoughtExpression(baseDir: String, cfg: [String: JsonValue]?) -> String {
        guard shouldEnableThought(cfg), let rawCfg = cfg else { return "" }
        guard let clientPath = resolveSafePluginFile(baseDir: baseDir, relPath: "vendor/thought-translator/thought-client.js"),
              let settingsUiPath = resolveSafePluginFile(baseDir: baseDir, relPath: "vendor/thought-translator/thought-settings-ui.js"),
              let rawClientSource = try? String(contentsOfFile: clientPath, encoding: .utf8), !rawClientSource.isEmpty,
              let settingsUiSource = try? String(contentsOfFile: settingsUiPath, encoding: .utf8), !settingsUiSource.isEmpty else {
            return ""
        }
        let verbsSource = resolveSafePluginFile(baseDir: baseDir, relPath: "vendor/thought-translator/tool-step-verbs.js").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        let clientSource = verbsSource.isEmpty ? rawClientSource : (verbsSource + ";\n" + rawClientSource)
        var bootCfg = reconcileConfigAliases(rawCfg)
        let rawMode = (bootCfg["thoughtTranslate"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        bootCfg["thoughtTranslate"] = .string(rawMode == "machine" ? "machine" : "ai")
        let bootCfgJson = MiniJson.stringify(.object(bootCfg), pretty: false)
        let codeHash = computeHash(clientSource + "\n" + settingsUiSource)
        let hashJson = MiniJson.stringifyString(codeHash)

        var sb = ""
        sb.reserveCapacity(clientSource.count + settingsUiSource.count + bootCfgJson.count + 3072)
        sb.append(subchannelHostGuardPrefix)
        sb.append(
            "  const getSettingsSec = () => { try { return document.getElementById?.('ag-cs-settings-sec') || document.getElementById?.('ag-prism-settings-sec') || null; } catch { return null; } };\n" +
            "  const cleanupThought = () => {\n" +
            "    try { window.__agPrismThought?.destroy?.(); } catch {}\n" +
            "    try { document.querySelectorAll?.('[data-testid=\"prism-thought-ai-config\"]')?.forEach?.((el) => el.remove()); } catch {}\n" +
            "    try { delete window.__agPrismThought; delete globalThis.__agPrismThought; delete window.__agPrismThoughtSettingsUi; delete globalThis.__agPrismThoughtSettingsUi; } catch {}\n" +
            "    try { const sec = getSettingsSec(); if (sec) { sec.__prismThoughtUiHandle = null; sec.__prismMountThoughtUi?.(); } } catch {}\n" +
            "  };\n" +
            "  const getLiveCfg = () => { try { const st = window.__agPrism?.getState?.(); return st && st.cfg && typeof st.cfg === 'object' ? st.cfg : null; } catch { return null; } };\n" +
            "  const bootCfg = "
        )
        sb.append(bootCfgJson)
        sb.append(
            ";\n  const initialLiveCfg = getLiveCfg();\n" +
            "  if (initialLiveCfg && initialLiveCfg.thoughtTranslate === 'off') { cleanupThought(); return { ok: true, status: 'off', skippedByLiveCfg: true }; }\n" +
            "  const targetHash = "
        )
        sb.append(hashJson)
        sb.append(
            ";\n  const mountOrReuse = () => {\n" +
            "    if (needDomMarkerOnReady && !hasDomMarker() && (isPlainHttpLocalhost || !/\\bantigravity\\b/i.test(String(document.title || '')))) return { ok: false, status: 'skipped-non-host' };\n" +
            "    const liveCfg = getLiveCfg();\n" +
            "    if (liveCfg && liveCfg.thoughtTranslate === 'off') { cleanupThought(); return { ok: true, status: 'off', skippedByLiveCfg: true }; }\n" +
            "    const effectiveCfg = liveCfg || bootCfg;\n" +
            "    const existingThought = window.__agPrismThought;\n" +
            "    const existingUi = window.__agPrismThoughtSettingsUi || globalThis.__agPrismThoughtSettingsUi;\n" +
            "    if (existingThought && existingThought.__prismCodeHash === targetHash && existingUi && existingUi.__prismCodeHash === targetHash) {\n" +
            "      try { existingThought.sync?.(effectiveCfg); } catch {}\n" +
            "      try { window.__agPrism?.syncAbsorbed?.(); } catch {}\n" +
            "      try { getSettingsSec()?.__prismMountThoughtUi?.(); } catch {}\n" +
            "      return { ok: true, reused: true, codeHash: targetHash };\n" +
            "    }\n" +
            "    cleanupThought();\n    ;"
        )
        sb.append(clientSource)
        sb.append(";\n    ;")
        sb.append(settingsUiSource)
        sb.append(
            ";\n    const mountedThought = window.__agPrismThought || globalThis.__agPrismThought;\n" +
            "    const mountedUi = window.__agPrismThoughtSettingsUi || globalThis.__agPrismThoughtSettingsUi;\n" +
            "    if (mountedThought && typeof mountedThought === 'object') { mountedThought.__prismCodeHash = targetHash; try { window.__agPrismThought = mountedThought; } catch {} try { globalThis.__agPrismThought = mountedThought; } catch {} }\n" +
            "    if (mountedUi && typeof mountedUi === 'object') { mountedUi.__prismCodeHash = targetHash; try { window.__agPrismThoughtSettingsUi = mountedUi; } catch {} try { globalThis.__agPrismThoughtSettingsUi = mountedUi; } catch {} }\n" +
            "    try { mountedThought?.sync?.(effectiveCfg); } catch {}\n" +
            "    try { window.__agPrism?.syncAbsorbed?.(); } catch {}\n" +
            "    try { getSettingsSec()?.__prismMountThoughtUi?.(); } catch {}\n" +
            "    return { ok: true, status: 'mounted', codeHash: targetHash };\n" +
            "  };\n" +
            "  if ((needDomMarkerOnReady || !document.documentElement) && typeof document.addEventListener === 'function') {\n" +
            "    document.addEventListener('DOMContentLoaded', () => { try { mountOrReuse(); } catch {} }, { once: true });\n" +
            "    return { ok: true, status: 'deferred', codeHash: targetHash };\n" +
            "  }\n" +
            "  return mountOrReuse();\n})()"
        )
        return sb
    }

    static let inlineDiffRemoveExpression: String = """
    (() => {
      try { window.__agPrismInlineDiff?.destroy?.(); } catch {}
      try { document.getElementById?.('ag-prism-inline-diff-css')?.remove?.(); } catch {}
      try { document.querySelectorAll?.('.ag-cs-inline-diff-box, .ag-cs-diff-ctx-menu')?.forEach?.((el) => el.remove()); } catch {}
      try { delete window.__agPrismInlineDiff; } catch {}
      try { delete globalThis.__agPrismInlineDiff; } catch {}
      try { delete window.__agPrismInlineDiffFactory; } catch {}
      try { delete globalThis.__agPrismInlineDiffFactory; } catch {}
      try { delete window.__agPrismInlineDiffResolve; } catch {}
      return { ok: true, status: 'off' };
    })()
    """

    static func buildInlineDiffExpression(baseDir: String, manifest: PluginManifest) -> String {
        let config = readConfig(baseDir: baseDir, manifest: manifest)
        return buildInlineDiffExpression(baseDir: baseDir, cfg: config)
    }

    static func buildInlineDiffExpression(baseDir: String, cfg: [String: JsonValue]?) -> String {
        guard let clientPath = resolveSafePluginFile(baseDir: baseDir, relPath: "vendor/inline-diff/inline-diff-client.js"),
              let clientSource = try? String(contentsOfFile: clientPath, encoding: .utf8), !clientSource.isEmpty else {
            return ""
        }
        let bootCfg = reconcileConfigAliases(cfg ?? [:])
        let bootCfgJson = MiniJson.stringify(.object(bootCfg), pretty: false)
        let codeHash = computeHash(clientSource)
        let hashJson = MiniJson.stringifyString(codeHash)

        var sb = ""
        sb.reserveCapacity(clientSource.count + bootCfgJson.count + 2560)
        sb.append(subchannelHostGuardPrefix)
        sb.append(
            "  const cleanupInlineDiff = () => {\n" +
            "    try { (window.__agPrismInlineDiff || globalThis.__agPrismInlineDiff)?.destroy?.(); } catch {}\n" +
            "    try { document.getElementById?.('ag-prism-inline-diff-css')?.remove?.(); } catch {}\n" +
            "    try { document.querySelectorAll?.('.ag-cs-inline-diff-box, .ag-cs-diff-ctx-menu')?.forEach?.((el) => el.remove()); } catch {}\n" +
            "    try { delete window.__agPrismInlineDiff; delete globalThis.__agPrismInlineDiff; delete window.__agPrismInlineDiffFactory; delete globalThis.__agPrismInlineDiffFactory; delete window.__agPrismInlineDiffResolve; } catch {}\n" +
            "  };\n" +
            "  const getLiveCfg = () => { try { const st = window.__agPrism?.getState?.(); return st && st.cfg && typeof st.cfg === 'object' ? st.cfg : null; } catch { return null; } };\n" +
            "  const bootCfg = "
        )
        sb.append(bootCfgJson)
        sb.append(";\n  const targetHash = ")
        sb.append(hashJson)
        sb.append(
            ";\n  const mountOrReuse = () => {\n" +
            "    if (needDomMarkerOnReady && !hasDomMarker() && (isPlainHttpLocalhost || !/\\bantigravity\\b/i.test(String(document.title || '')))) return { ok: false, status: 'skipped-non-host' };\n" +
            "    const effectiveCfg = getLiveCfg() || bootCfg;\n" +
            "    const existing = window.__agPrismInlineDiff || globalThis.__agPrismInlineDiff;\n" +
            "    if (existing && !existing.getDebugState?.()?.destroyed && existing.__prismCodeHash === targetHash && typeof existing.sync === 'function') {\n" +
            "      try { existing.sync(effectiveCfg); } catch {}\n" +
            "      return { ok: true, reused: true, codeHash: targetHash };\n" +
            "    }\n" +
            "    cleanupInlineDiff();\n    ;"
        )
        sb.append(clientSource)
        sb.append(
            ";\n    let mounted = window.__agPrismInlineDiff || globalThis.__agPrismInlineDiff;\n" +
            "    const factory = window.__agPrismInlineDiffFactory || globalThis.__agPrismInlineDiffFactory;\n" +
            "    if (!mounted && typeof factory === 'function') { try { mounted = factory({ window, document }); } catch {} }\n" +
            "    if (mounted && typeof mounted === 'object') { mounted.__prismCodeHash = targetHash; try { window.__agPrismInlineDiff = mounted; } catch {} try { globalThis.__agPrismInlineDiff = mounted; } catch {} }\n" +
            "    if (typeof factory === 'function') { try { window.__agPrismInlineDiffFactory = factory; } catch {} try { globalThis.__agPrismInlineDiffFactory = factory; } catch {} }\n" +
            "    try { mounted?.sync?.(effectiveCfg); } catch {}\n" +
            "    return { ok: true, status: 'mounted', codeHash: targetHash };\n" +
            "  };\n" +
            "  if ((needDomMarkerOnReady || !document.documentElement) && typeof document.addEventListener === 'function') {\n" +
            "    document.addEventListener('DOMContentLoaded', () => { try { mountOrReuse(); } catch {} }, { once: true });\n" +
            "    return { ok: true, status: 'deferred', codeHash: targetHash };\n" +
            "  }\n" +
            "  return mountOrReuse();\n})()"
        )
        return sb
    }

    static func buildInjectExpression(baseDir: String, manifest: PluginManifest) throws -> String {
        let config = readConfig(baseDir: baseDir, manifest: manifest)
        let cssPath = (baseDir as NSString).appendingPathComponent("style.css")
        let css = try String(contentsOfFile: cssPath, encoding: .utf8)
        let bundle = try readRuntimeBundle(baseDir: baseDir, manifest: manifest)
        let codeHash = computeHash(bundle)

        var initCfg = config
        initCfg["binding"] = .string(manifest.settingBinding)
        initCfg["codeHash"] = .string(codeHash)
        initCfg["__fromFile"] = .bool(true)

        let styleIdJson = MiniJson.stringifyString(manifest.styleId)
        let verJson = MiniJson.stringifyString(manifest.version)
        var sb = ""
        sb.reserveCapacity(css.count + bundle.count + 4608)
        sb.append("(() => {\n")
        sb.append("    const css = ")
        sb.append(MiniJson.stringifyString(css))
        sb.append(";\n")
        sb.append("    const migrateLegacyStorage = () => {\n")
        sb.append("      try {\n")
        sb.append("        if (typeof localStorage === 'undefined' || !localStorage) return;\n")
        sb.append("        const legacyRaw = localStorage.getItem('ag-claude-style:config');\n")
        sb.append("        const v3Raw = localStorage.getItem('agClaudeStyle.settings.v3');\n")
        sb.append("        const prismRaw = localStorage.getItem('ag-prism:config');\n")
        sb.append("        if (!prismRaw && (legacyRaw || v3Raw)) localStorage.setItem('ag-prism:config', legacyRaw || v3Raw);\n")
        sb.append("        if (!v3Raw && (prismRaw || legacyRaw)) localStorage.setItem('agClaudeStyle.settings.v3', prismRaw || legacyRaw);\n")
        sb.append("      } catch {}\n")
        sb.append("    };\n")
        sb.append("    const cleanupLegacyResidue = () => {\n")
        sb.append("      try { const oldStyle = document.getElementById('ag-claude-style-css'); if (oldStyle) oldStyle.remove(); } catch {}\n")
        sb.append("      try { const oldApi = window.__agClaudeStyle; if (oldApi && (!window.__agPrism || Number(oldApi.version) <= 2)) { if (typeof oldApi.destroy === 'function') oldApi.destroy(); delete window.__agClaudeStyle; } } catch {}\n")
        sb.append("    };\n")
        sb.append("    const stripForeignMount = () => {\n")
        sb.append("      try { window.__agPrismTelemetry?.destroy?.(); } catch {}\n")
        sb.append("      try { window.__agPrismEffortSlider?.destroy?.(); } catch {}\n")
        sb.append("      try { window.__agPrismThought?.destroy?.(); } catch {}\n")
        sb.append("      try { document.querySelectorAll?.('[data-testid=\"prism-thought-ai-config\"]')?.forEach?.((el) => el.remove()); } catch {}\n")
        sb.append("      try { window.__agPrismInlineDiff?.destroy?.(); } catch {}\n")
        sb.append("      try { document.querySelectorAll?.('.ag-cs-inline-diff-box, .ag-cs-diff-ctx-menu')?.forEach?.((el) => el.remove()); } catch {}\n")
        sb.append("      try { window.__agPrismOmni?.destroy?.(); } catch {}\n")
        sb.append("      try { window.__agPrismContextMenu?.destroy?.(); } catch {}\n")
        sb.append("      try { document.querySelectorAll?.('.ag-cs-ctx-menu, .ag-cs-ctx-toast')?.forEach?.((el) => el.remove()); } catch {}\n")
        sb.append("      try { window.__agPrismHostI18n?.destroy?.(); document.documentElement?.removeAttribute?.('data-ag-prism-host-i18n'); } catch {}\n")
        sb.append("      try { document.documentElement?.removeAttribute?.('data-ag-cs-model-menu'); document.querySelectorAll?.('[data-ag-cs-aux-dual],[data-ag-cs-model-overlay]').forEach((el) => { el.removeAttribute('data-ag-cs-aux-dual'); el.removeAttribute('data-ag-cs-model-overlay'); }); } catch {}\n")
        sb.append("      try { window.__agPrism?.destroy?.(); } catch {}\n")
        sb.append("      try { document.getElementById(")
        sb.append(styleIdJson)
        sb.append(")?.remove(); } catch {}\n")
        sb.append("      try { document.getElementById('ag-claude-style-css')?.remove(); } catch {}\n")
        sb.append("      try { document.getElementById('ag-prism-settings-v101-css')?.remove(); } catch {}\n")
        sb.append("      try { document.getElementById('ag-prism-omni-css')?.remove(); } catch {}\n")
        sb.append("      try { document.getElementById('ag-prism-inline-diff-css')?.remove(); } catch {}\n")
        sb.append("      try { if (document.documentElement) document.documentElement.removeAttribute('data-ag-prism'); } catch {}\n")
        sb.append("      try { delete window.__agPrismThought; delete globalThis.__agPrismThought; delete window.__agPrismThoughtSettingsUi; delete globalThis.__agPrismThoughtSettingsUi; delete window.__agPrismInlineDiff; delete globalThis.__agPrismInlineDiff; delete window.__agPrismInlineDiffFactory; delete globalThis.__agPrismInlineDiffFactory; delete window.__agPrismInlineDiffResolve; delete window.__agPrismOmni; delete window.__agPrismContextMenu; delete globalThis.__agPrismContextMenu; delete window.__agPrism; delete window.__agClaudeStyle; } catch {}\n")
        sb.append("    };\n")
        sb.append(
            "    const hasDomWorkbenchMarkers = () => {\n      try {\n" +
            "        if (!document || !document.documentElement) return false;\n" +
            "        if (document.querySelector('.agy-shell, .monaco-workbench, .antigravity-agent-side-panel, [data-testid=\"conversation-view\"], [data-testid=\"agent-view\"]')) return true;\n" +
            "        return Boolean(window.__agPrismSetting || window.__agPrismMetricsCall || window.__agPrismThoughtCall || window.__agPrismUsageCall);\n" +
            "      } catch { return false; }\n    };\n    const checkHostIdentity = () => {\n      try {\n" +
            "        const href = String((typeof location !== 'undefined' && location && location.href) || '');\n" +
            "        const lowUrl = href.toLowerCase();\n        if (!lowUrl) return 'defer';\n" +
            "        if (/^(devtools:|data:|about:|chrome:|chrome-extension:|edge:|blob:|plugin:)/.test(lowUrl)) return 'reject';\n" +
            "        const title = String((document && document.title) || '').trim();\n" +
            "        if (/^(?:untitled|launchpad)$/i.test(title) || /\\/launchpad(?:\\.html)?(?:[?#]|$)/i.test(lowUrl)) return 'reject';\n" +
            "        if (lowUrl.startsWith('vscode-file://') || lowUrl.startsWith('app://')) return 'allow';\n" +
            "        if (lowUrl.startsWith('file://')) return (lowUrl.includes('workbench') || lowUrl.includes('antigravity') || title.toLowerCase().includes('antigravity') || hasDomWorkbenchMarkers()) ? 'allow' : 'reject';\n" +
            "        if (/^https?:\\/\\/(127\\.0\\.0\\.1|localhost|\\[::1\\])(?::\\d+)?\\/(?:viewer|sandbox|stream|api)(?:[/?#]|$)/i.test(lowUrl)) return 'reject';\n" +
            "        if (!/^https?:\\/\\/(127\\.0\\.0\\.1|localhost|\\[::1\\])(?::\\d+)?(?:[/?#]|$)/i.test(lowUrl)) return 'reject';\n" +
            "        if (title.toLowerCase().includes('antigravity') || hasDomWorkbenchMarkers()) return 'allow';\n" +
            "        if (lowUrl.startsWith('https://') && (!title || title.toLowerCase().startsWith('127.0.0.1'))) return 'allow';\n" +
            "        if (document.readyState !== 'complete') return 'defer';\n        return 'reject';\n" +
            "      } catch { return 'reject'; }\n    };\n    const applyStyle = () => {\n" +
            "      const targetParent = document.head || document.documentElement;\n      if (!targetParent) return;\n" +
            "      cleanupLegacyResidue();\n      let style = document.getElementById("
        )
        sb.append(styleIdJson)
        sb.append(");\n      if (!style) { style = document.createElement('style'); style.id = ")
        sb.append(styleIdJson)
        sb.append(
            "; }\n      if (style.textContent !== css) style.textContent = css;\n" +
            "      if (style.parentNode !== targetParent || targetParent.lastElementChild !== style) targetParent.appendChild(style);\n" +
            "    };\n\n    let status = 'ok';\n    let mounted = false;\n    let hostGateTimer = null;\n    let hostGateAttempts = 0;\n" +
            "    const mount = () => {\n      if (mounted || !document.documentElement) return;\n" +
            "      const verdict = checkHostIdentity();\n" +
            "      if (verdict === 'reject') { status = 'skipped-non-host'; stripForeignMount(); return; }\n" +
            "      if (verdict === 'defer') {\n        status = 'deferred-host-check';\n" +
            "        if (!hostGateTimer && hostGateAttempts < 20) { hostGateAttempts += 1; hostGateTimer = setTimeout(() => { hostGateTimer = null; mount(); }, 150); }\n" +
            "        else if (hostGateAttempts >= 20) { status = 'skipped-non-host'; stripForeignMount(); }\n        return;\n      }\n" +
            "      mounted = true;\n      status = 'ok';\n      try {\n        cleanupLegacyResidue();\n" +
            "        if (!window.__agPrismRepoBridge) {\n" +
            "          const fn = (a) => Promise.resolve({ ok: false, offline: true, action: typeof a === 'string' ? a : (a && a.action) || 'status', noRemote: true, hasRemote: false, branch: 'local', commit: "
        )
        sb.append(verJson)
        sb.append(", shortHash: ")
        sb.append(verJson)
        sb.append(
            " });\n          fn.call = fn; fn.request = fn; fn.status = () => fn('status'); fn.pull = () => fn('pull'); fn.sync = () => fn('pull'); fn.resolve = () => {};\n" +
            "          window.__agPrismRepoBridge = fn;\n        }\n" +
            "        if (document.head) applyStyle();\n        else document.addEventListener('DOMContentLoaded', applyStyle, { once: true });\n        const bootCfg = "
        )
        sb.append(MiniJson.stringify(.object(initCfg), pretty: false))
        sb.append(";\n        const existingPrism = window.__agPrism || window.__agClaudeStyle;\n")
        sb.append("        const bundleUnchanged = Boolean(\n")
        sb.append("          existingPrism &&\n")
        sb.append("          existingPrism.version === ")
        sb.append(verJson)
        sb.append(" &&\n")
        sb.append("          existingPrism.codeHash === bootCfg.codeHash &&\n")
        sb.append("          typeof existingPrism.refreshConfig === 'function'\n")
        sb.append("        );\n")
        sb.append("        if (bundleUnchanged) {\n")
        sb.append("          existingPrism.refreshConfig(bootCfg);\n")
        sb.append("        } else {\n")
        sb.append("          try { existingPrism?.destroy?.(); } catch {}\n")
        sb.append("          try { window.__agPrismTelemetry?.destroy?.(); } catch {}\n")
        sb.append("          try { window.__agPrismEffortSlider?.destroy?.(); } catch {}\n")
        sb.append("          try { window.__agPrismThought?.destroy?.(); } catch {}\n")
        sb.append("          try { window.__agPrismOmni?.destroy?.(); } catch {}\n")
        sb.append("          try { window.__agPrismContextMenu?.destroy?.(); } catch {}\n")
        sb.append("          try { document.querySelectorAll('[data-ag-prism-fallback=\"1\"]').forEach((n) => n.remove()); } catch {}\n")
        sb.append("          ")
        sb.append(bundle)
        sb.append("\n")
        sb.append("          if (typeof globalThis.__agCsUiMain === 'function') {\n")
        sb.append("            globalThis.__agCsUiMain(bootCfg);\n")
        sb.append("          }\n")
        sb.append("        }\n")
        sb.append(
            "        migrateLegacyStorage();\n" +
            "        if (window.__agClaudeStyle && !window.__agPrism) window.__agPrism = window.__agClaudeStyle;\n" +
            "        else if (window.__agPrism) window.__agClaudeStyle = window.__agPrism;\n" +
            "        const liveState = window.__agPrism && typeof window.__agPrism.getState === 'function' ? window.__agPrism.getState() : null;\n" +
            "        const effectiveCfg = (liveState && liveState.cfg) || bootCfg;\n" +
            "        try { window.__agPrismTelemetry?.sync?.(effectiveCfg); } catch {}\n" +
            "        try { window.__agPrismEffortSlider?.sync?.(effectiveCfg); } catch {}\n" +
            "        try { window.__agPrismThought?.sync?.(effectiveCfg); } catch {}\n" +
            "        try { if (effectiveCfg.omniModule === 'off') window.__agPrismOmni?.destroy?.(); else window.__agPrismOmni?.sync?.(effectiveCfg, window.__agPrismOmniServerMeta || null); } catch {}\n" +
            "        if (document.documentElement && !document.documentElement.hasAttribute('data-ag-prism')) document.documentElement.setAttribute('data-ag-prism', "
        )
        sb.append(verJson)
        sb.append(
            ");\n      } catch (e) {\n        status = 'error: ' + (e && e.message ? e.message : String(e));\n" +
            "        if (typeof console !== 'undefined' && console.error) console.error('[obsidian-prism] init error:', e);\n" +
            "      }\n    };\n\n    if (document.documentElement) mount();\n    else {\n      status = 'deferred';\n" +
            "      const onReady = () => { if (document.documentElement) { document.removeEventListener('readystatechange', onReady); document.removeEventListener('DOMContentLoaded', onReady); mount(); } };\n" +
            "      document.addEventListener('readystatechange', onReady);\n      document.addEventListener('DOMContentLoaded', onReady);\n    }\n" +
            "    const api = window.__agPrism || window.__agClaudeStyle;\n    const st = api && typeof api.getState === 'function' ? api.getState() : null;\n    return { version: "
        )
        sb.append(verJson)
        sb.append(", status, state: st };\n  })()")
        return sb
    }

    static func shortTitle(_ page: CdpPageInfo) -> String {
        let t = !page.title.isEmpty ? page.title : page.url
        if t.count > 60 {
            return String(t.prefix(57)) + "..."
        }
        return t
    }
}
