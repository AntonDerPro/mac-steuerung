import Foundation
import SwiftUI
import Combine
import UserNotifications

// MARK: - Configuration

class AgentConfig: ObservableObject {

    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "agentHost") }
    }
    @Published var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "agentPort") }
    }
    @Published var colorSchemeRaw: String {
        didSet { UserDefaults.standard.set(colorSchemeRaw, forKey: "colorScheme") }
    }
    @Published var accentColorRaw: String {
        didSet { UserDefaults.standard.set(accentColorRaw, forKey: "accentColorRaw") }
    }
    @Published var userName: String {
        didSet { UserDefaults.standard.set(userName, forKey: "userName") }
    }
    @Published var hapticsEnabled: Bool {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "hapticsEnabled") }
    }
    @Published var animationsEnabled: Bool {
        didSet { UserDefaults.standard.set(animationsEnabled, forKey: "animationsEnabled") }
    }
    @Published var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    @Published var compactDashboard: Bool {
        didSet { UserDefaults.standard.set(compactDashboard, forKey: "compactDashboard") }
    }
    @Published var autoRefreshInterval: Int {
        didSet { UserDefaults.standard.set(autoRefreshInterval, forKey: "autoRefreshInterval") }
    }

    init() {
        let d = UserDefaults.standard
        host                = d.string(forKey: "agentHost")       ?? "192.168.1.100"
        port                = d.integer(forKey: "agentPort") == 0  ? 8765 : d.integer(forKey: "agentPort")
        colorSchemeRaw      = d.string(forKey: "colorScheme")     ?? "dark"
        accentColorRaw      = d.string(forKey: "accentColorRaw")  ?? "blue"
        userName            = d.string(forKey: "userName")        ?? ""
        hapticsEnabled      = d.object(forKey: "hapticsEnabled")   == nil ? true  : d.bool(forKey: "hapticsEnabled")
        animationsEnabled   = d.object(forKey: "animationsEnabled") == nil ? true  : d.bool(forKey: "animationsEnabled")
        notificationsEnabled = d.object(forKey: "notificationsEnabled") == nil ? true : d.bool(forKey: "notificationsEnabled")
        compactDashboard    = d.bool(forKey: "compactDashboard")
        autoRefreshInterval = d.object(forKey: "autoRefreshInterval") == nil ? 5 : d.integer(forKey: "autoRefreshInterval")
    }

    var baseURL: String { "http://\(host):\(port)" }

    var preferredColorScheme: ColorScheme? {
        switch colorSchemeRaw {
        case "dark":  return .dark
        case "light": return .light
        default:      return nil
        }
    }

    var accentColor: Color {
        switch accentColorRaw {
        case "purple": return .purple
        case "teal":   return .teal
        case "orange": return .orange
        case "pink":   return .pink
        case "mint":   return .mint
        case "indigo": return .indigo
        default:       return .blue
        }
    }

    var accentColorGlow: Color { accentColor.opacity(0.18) }
    var isDark: Bool { colorSchemeRaw != "light" }
}

// MARK: - API Client

class AgentAPI: ObservableObject {
    private var config: AgentConfig

    init(config: AgentConfig) {
        self.config = config
    }

    func updateConfig(_ config: AgentConfig) {
        self.config = config
    }

    private func url(_ path: String) -> URL {
        URL(string: config.baseURL + path)!
    }

    func fetchStatus() async throws -> SystemStatus {
        let (data, _) = try await URLSession.shared.data(from: url("/status"))
        return try JSONDecoder().decode(SystemStatus.self, from: data)
    }

    func mediaControl(action: String) async throws {
        var req = URLRequest(url: url("/media-control"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["action": action])
        _ = try await URLSession.shared.data(for: req)
    }

    func setVolume(level: Int) async throws {
        var req = URLRequest(url: url("/volume"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["level": level])
        _ = try await URLSession.shared.data(for: req)
    }

    func setMute(muted: Bool) async throws {
        var req = URLRequest(url: url("/mute"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["muted": muted])
        _ = try await URLSession.shared.data(for: req)
    }

    func listFiles(path: String) async throws -> [FileItem] {
        var req = URLRequest(url: url("/list"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["path": path])
        let (data, _) = try await URLSession.shared.data(for: req)
        let decoded = try JSONDecoder().decode([String: [FileItem]].self, from: data)
        return decoded["files"] ?? []
    }

    func aiMove(prompt: String) async throws -> AgentMoveResult {
        var req = URLRequest(url: url("/ai-move"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["prompt": prompt])
        req.timeoutInterval = 120
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(AgentMoveResult.self, from: data)
    }

    func aiConfirm(src: String, dst: String) async throws -> Bool {
        var req = URLRequest(url: url("/ai-confirm"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["src": src, "dst": dst])
        let (data, _) = try await URLSession.shared.data(for: req)
        let result = try JSONDecoder().decode([String: Bool].self, from: data)
        return result["ok"] ?? false
    }

    // Type-safe multimodale API-Integration für vision models
    func aiChat(messages: [APIChatMessage], model: String) async throws -> String {
        struct ChatRequest: Encodable {
            var messages: [APIChatMessage]
            var model: String
        }
        var req = URLRequest(url: url("/ai-chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(ChatRequest(messages: messages, model: model))
        req.timeoutInterval = 180
        let (data, _) = try await URLSession.shared.data(for: req)
        let result = try JSONDecoder().decode([String: String].self, from: data)
        if let error = result["error"] { throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: error]) }
        return result["reply"] ?? ""
    }
}

// MARK: - Data Models

struct APIChatMessage: Encodable {
    var role: String
    var content: String
    var images: [String]? // Base64 image payload strings
}

struct SystemStatus: Codable {
    var battery: BatteryStatus?
    var cpu_ram: CPURamStatus?
    var wifi: WifiStatus?
    var volume: VolumeStatus?
    var gpu: GPUStatus?
    var processes: [ProcessInfo]?
    var media: MediaStatus?
}

struct BatteryStatus: Codable {
    var percent: Int?
    var charging: Bool
    var remaining: String?
    var source: String
}

struct CPURamStatus: Codable {
    var cpu_percent: Double?
    var ram_used_gb: Double?
    var ram_total_gb: Double?
}

struct WifiStatus: Codable {
    var connected: Bool
    var ssid: String?
    var signal: Int?
}

struct VolumeStatus: Codable {
    var volume: Int?
    var muted: Bool
}

struct GPUStatus: Codable {
    var gpu_percent: Double?
    var available: Bool
}

struct ProcessInfo: Codable, Identifiable {
    var id: String { pid }
    var name: String
    var cpu: Double
    var mem: Double
    var pid: String
}

struct MediaStatus: Codable {
    var playing: Bool
    var title: String
    var artist: String
    var position: Int
    var duration: Int
    var cover: String?
}

struct FileItem: Codable, Identifiable {
    var id: String { path }
    var name: String
    var path: String
    var is_dir: Bool
    var modified: Double
    var size: Int
}

struct AgentMoveResult: Codable {
    var status: String?
    var keywords: [String]?
    var dst: String?
    var treffer: [AgentTreffer]?
    var message: String?
    var error: String?
}

struct AgentTreffer: Codable, Identifiable {
    var id: Int { index }
    var index: Int
    var name: String
    var path: String
}

struct ChatMessage: Identifiable, Equatable {
    var id = UUID()
    var role: String
    var content: String
    var images: [String]? // Local representation of image payload for view history rendering
}

// MARK: - Haptic Helper

struct Haptics {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .medium) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
    static func notification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        UINotificationFeedbackGenerator().notificationOccurred(type)
    }
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}

// MARK: - Notification Helper

class NotificationManager {
    static let shared = NotificationManager()

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func send(title: String, body: String, delay: TimeInterval = 0.5) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(delay, 0.1), repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
