import SwiftUI
import UserNotifications

// MARK: - Glass Card Modifier

struct GlassCard: ViewModifier {
    var prominent: Bool = false
    @EnvironmentObject var config: AgentConfig

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(config.isDark ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color(.systemBackground).opacity(0.85)))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        (config.isDark ? Color.white : Color.black).opacity(prominent ? 0.3 : 0.12),
                                        (config.isDark ? Color.white : Color.black).opacity(0.04)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    }
                    // Subtle accent color glow in background
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(config.accentColor.opacity(0.04))
                    }
            }
    }
}

extension View {
    func glassCard(prominent: Bool = false) -> some View {
        modifier(GlassCard(prominent: prominent))
    }
}

// MARK: - Gauge Ring

struct GaugeRing: View {
    var value: Double
    var total: Double = 100
    var color: Color
    var size: CGFloat = 64
    var lineWidth: CGFloat = 6
    var label: String = ""
    var sublabel: String = ""

    private var fraction: Double { min(max(value / total, 0), 1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.6), color], center: .center,
                                    startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * fraction)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.8, dampingFraction: 0.7), value: fraction)
            VStack(spacing: 0) {
                Text(label)
                    .font(.system(size: size * 0.22, weight: .bold, design: .rounded))
                Text(sublabel)
                    .font(.system(size: size * 0.14, weight: .medium))
                    .opacity(0.5)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    var icon: String = ""

    var body: some View {
        HStack(spacing: 6) {
            if !icon.isEmpty {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(title.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .kerning(1.2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}

// MARK: - Stat Row

struct StatRow: View {
    let icon: String
    let label: String
    let value: String
    var color: Color = .blue

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28)
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit())
                .fontWeight(.medium)
        }
    }
}

// MARK: - Pulse Dot

struct PulseDot: View {
    var color: Color = .green
    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.3))
                .scaleEffect(pulsing ? 1.8 : 1)
                .opacity(pulsing ? 0 : 0.6)
            Circle()
                .fill(color)
        }
        .frame(width: 8, height: 8)
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
    }
}

// MARK: - Loading Shimmer

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.20), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 2)
                    .offset(x: phase * geo.size.width * 3 - geo.size.width)
                }
                .clipped()
            }
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View { modifier(ShimmerModifier()) }
}

// MARK: - Frosted Background (Dark + Light aware)

struct FrostedBackground: View {
    @EnvironmentObject var config: AgentConfig

    var body: some View {
        ZStack {
            if config.isDark {
                Color.black.ignoresSafeArea()
                RadialGradient(
                    colors: [Color(red: 0.1, green: 0.12, blue: 0.22), .black],
                    center: .topLeading, startRadius: 0, endRadius: 500
                )
                .ignoresSafeArea()
                RadialGradient(
                    colors: [Color(red: 0.05, green: 0.15, blue: 0.25).opacity(0.6), .clear],
                    center: .bottomTrailing, startRadius: 0, endRadius: 400
                )
                .ignoresSafeArea()
                // Accent glow
                RadialGradient(
                    colors: [config.accentColor.opacity(0.12), .clear],
                    center: .top, startRadius: 0, endRadius: 300
                )
                .ignoresSafeArea()
            } else {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                RadialGradient(
                    colors: [config.accentColor.opacity(0.10), .clear],
                    center: .topLeading, startRadius: 0, endRadius: 400
                )
                .ignoresSafeArea()
                RadialGradient(
                    colors: [config.accentColor.opacity(0.06), .clear],
                    center: .bottomTrailing, startRadius: 0, endRadius: 300
                )
                .ignoresSafeArea()
            }
        }
    }
}

// MARK: - Connection Banner

struct ConnectionBanner: View {
    let error: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundStyle(.orange)
            Text(error)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassCard()
        .padding(.horizontal)
    }
}

// MARK: - Settings Button (Toolbar)

struct SettingsToolbarButton: View {
    @Binding var showSettings: Bool
    @EnvironmentObject var config: AgentConfig

    var body: some View {
        Button {
            if config.hapticsEnabled { Haptics.impact(.light) }
            showSettings = true
        } label: {
            Image(systemName: "gear")
                .foregroundStyle(config.accentColor)
        }
    }
}

// MARK: - Settings View (Erweitert)

struct SettingsView: View {
    @EnvironmentObject var config: AgentConfig
    @Environment(\.dismiss) var dismiss

    let accentOptions: [(String, String, Color)] = [
        ("blue",   "Blau",   .blue),
        ("purple", "Lila",   .purple),
        ("teal",   "Türkis", .teal),
        ("orange", "Orange", .orange),
        ("pink",   "Rosa",   .pink),
        ("mint",   "Mint",   .mint),
        ("indigo", "Indigo", .indigo),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()
                Form {
                    // --- Verbindung ---
                    Section("Verbindung") {
                        HStack {
                            Text("Host")
                            Spacer()
                            TextField("IP-Adresse", text: $config.host)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                        }
                        HStack {
                            Text("Port")
                            Spacer()
                            TextField("8765", value: $config.port, format: .number)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.numberPad)
                        }
                        LabeledContent("URL", value: config.baseURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // --- Erscheinungsbild ---
                    Section("Erscheinungsbild") {
                        HStack {
                            Text("Name")
                            Spacer()
                            TextField("Dein Name", text: $config.userName)
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                        }

                        Picker("Modus", selection: $config.colorSchemeRaw) {
                            Text("Hell").tag("light")
                            Text("Dunkel").tag("dark")
                            Text("System").tag("system")
                        }
                        .pickerStyle(.segmented)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Akzentfarbe")
                                .font(.subheadline)
                            HStack(spacing: 10) {
                                ForEach(accentOptions, id: \.0) { id, _, color in
                                    Button {
                                        if config.hapticsEnabled { Haptics.selection() }
                                        config.accentColorRaw = id
                                    } label: {
                                        ZStack {
                                            Circle()
                                                .fill(color)
                                                .frame(width: 30, height: 30)
                                            if config.accentColorRaw == id {
                                                Image(systemName: "checkmark")
                                                    .font(.caption.weight(.bold))
                                                    .foregroundStyle(.white)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }

                    // --- Verhalten ---
                    Section("Verhalten") {
                        Toggle("Haptisches Feedback", isOn: $config.hapticsEnabled)
                            .tint(config.accentColor)
                        Toggle("Animationen", isOn: $config.animationsEnabled)
                            .tint(config.accentColor)
                        Toggle("Benachrichtigungen", isOn: $config.notificationsEnabled)
                            .tint(config.accentColor)
                            .onChange(of: config.notificationsEnabled) { _, val in
                                if val { NotificationManager.shared.requestPermission() }
                            }

                        HStack {
                            Text("Aktualisierungsintervall")
                            Spacer()
                            Picker("", selection: $config.autoRefreshInterval) {
                                Text("3s").tag(3)
                                Text("5s").tag(5)
                                Text("10s").tag(10)
                                Text("30s").tag(30)
                            }
                            .pickerStyle(.menu)
                            .tint(config.accentColor)
                        }
                    }

                    // --- Info ---
                    Section("Info") {
                        Text("Stelle sicher, dass der Mac-Agent (python3 main.py) auf dem Mac läuft und dein Gerät im selben Netzwerk ist.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        LabeledContent("Version", value: "1.1.0")
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Einstellungen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") {
                        if config.hapticsEnabled { Haptics.impact(.light) }
                        dismiss()
                    }
                    .foregroundStyle(config.accentColor)
                }
            }
            .preferredColorScheme(config.preferredColorScheme)
        }
    }
}

// MARK: - Bubble Animation Modifier

struct BubbleAppear: ViewModifier {
    @State private var appeared = false
    let isUser: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(appeared ? 1 : 0.7, anchor: isUser ? .bottomTrailing : .bottomLeading)
            .opacity(appeared ? 1 : 0)
            .offset(x: appeared ? 0 : (isUser ? 20 : -20), y: appeared ? 0 : 8)
            .onAppear {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                    appeared = true
                }
            }
    }
}

extension View {
    func bubbleAppear(isUser: Bool) -> some View {
        modifier(BubbleAppear(isUser: isUser))
    }
}
