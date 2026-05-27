import SwiftUI

struct StatusView: View {
    @EnvironmentObject var api: AgentAPI
    @EnvironmentObject var config: AgentConfig
    @Binding var showSettings: Bool

    @State private var status: SystemStatus?
    @State private var error: String?
    @State private var loading = true
    @State private var refreshTask: Task<Void, Never>?
    @State private var currentTime = Date()
    @State private var clockTimer: Timer?

    var greetingText: String {
        let hour = Calendar.current.component(.hour, from: currentTime)
        let name = config.userName.isEmpty ? nil : config.userName
        let greeting: String
        switch hour {
        case 5..<12:  greeting = "Guten Morgen"
        case 12..<14: greeting = "Mahlzeit"
        case 14..<18: greeting = "Guten Tag"
        case 18..<22: greeting = "Guten Abend"
        default:      greeting = "Gute Nacht"
        }
        if let n = name { return "\(greeting), \(n)." }
        return "\(greeting)."
    }

    var subtitleText: String {
        let hour = Calendar.current.component(.hour, from: currentTime)
        switch hour {
        case 5..<9:   return "Dein Mac ist bereit."
        case 9..<12:  return "Einen produktiven Vormittag!"
        case 12..<14: return "Kurze Pause gefällig?"
        case 14..<18: return "Alles im Blick."
        case 18..<22: return "Wie lief der Tag?"
        default:      return "Alles ruhig auf dem Mac."
        }
    }

    var timeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: currentTime)
    }

    var dateString: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "EEEE, d. MMMM"
        return f.string(from: currentTime)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()

                ScrollView {
                    VStack(spacing: 16) {
                        // Greeting + Clock Card
                        greetingCard
                            .padding(.top, 4)

                        if let status {
                            gaugeRow(status)
                            batteryCard(status)
                            if let procs = status.processes, !procs.isEmpty {
                                processCard(procs)
                            }
                        } else if loading {
                            loadingCards
                        }

                        if let error {
                            ConnectionBanner(error: error)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .refreshable { await loadStatus() }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsToolbarButton(showSettings: $showSettings)
                }
            }
            .task { await startPolling() }
            .onDisappear {
                refreshTask?.cancel()
                clockTimer?.invalidate()
            }
            .onAppear { startClock() }
        }
        .preferredColorScheme(config.preferredColorScheme)
    }

    // MARK: - Greeting Card

    var greetingCard: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(greetingText)
                    .font(.title3.weight(.semibold))
                Text(subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(timeString)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(config.accentColor)
                    .monospacedDigit()
                Text(dateString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .glassCard()
    }

    // MARK: - Subviews

    @ViewBuilder
    func gaugeRow(_ s: SystemStatus) -> some View {
        HStack(spacing: 12) {
            if let cr = s.cpu_ram {
                VStack(spacing: 8) {
                    GaugeRing(
                        value: cr.cpu_percent ?? 0,
                        color: cpuColor(cr.cpu_percent ?? 0),
                        size: 80, lineWidth: 7,
                        label: cr.cpu_percent.map { "\(Int($0))%" } ?? "–",
                        sublabel: "CPU"
                    )
                    Text("Prozessor")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .glassCard()

                if let used = cr.ram_used_gb, let total = cr.ram_total_gb {
                    VStack(spacing: 8) {
                        GaugeRing(
                            value: used, total: total,
                            color: ramColor(used / total),
                            size: 80, lineWidth: 7,
                            label: String(format: "%.1f", used),
                            sublabel: "GB RAM"
                        )
                        Text("Arbeitsspeicher")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .glassCard()
                }

                if let gpu = s.gpu, gpu.available, let g = gpu.gpu_percent {
                    VStack(spacing: 8) {
                        GaugeRing(
                            value: g, color: .purple,
                            size: 80, lineWidth: 7,
                            label: "\(Int(g))%", sublabel: "GPU"
                        )
                        Text("Grafik")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .glassCard()
                }
            }
        }
    }

    @ViewBuilder
    func batteryCard(_ s: SystemStatus) -> some View {
        if let batt = s.battery, let pct = batt.percent {
            VStack(spacing: 12) {
                SectionHeader(title: "Energie", icon: "bolt.fill")
                HStack(spacing: 16) {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.1)).frame(height: 14)
                        Capsule()
                            .fill(batteryColor(pct))
                            .frame(width: max(CGFloat(pct) / 100 * 180, 8), height: 14)
                            .animation(.spring(response: 1, dampingFraction: 0.8), value: pct)
                    }
                    .frame(width: 180)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        HStack(spacing: 4) {
                            if batt.charging {
                                Image(systemName: "bolt.fill").foregroundStyle(.yellow).font(.caption2)
                            }
                            Text("\(pct)%").font(.subheadline.monospacedDigit().weight(.semibold))
                        }
                        Text(batt.source).font(.caption2).foregroundStyle(.secondary)
                        if let rem = batt.remaining {
                            Text(rem).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(16)
            .glassCard()
        }
    }

    @ViewBuilder
    func processCard(_ procs: [ProcessInfo]) -> some View {
        VStack(spacing: 12) {
            SectionHeader(title: "Aktive Prozesse", icon: "cpu")
            VStack(spacing: 8) {
                ForEach(procs.prefix(6)) { proc in
                    HStack(spacing: 10) {
                        Text(proc.name)
                            .font(.caption)
                            .foregroundStyle(.primary.opacity(0.85))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(String(format: "%.1f%%", proc.cpu))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(proc.cpu > 20 ? .orange : .secondary)
                            .frame(width: 48, alignment: .trailing)
                        Text(String(format: "%.1f%%", proc.mem))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .glassCard()
    }

    var loadingCards: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ForEach(0..<2, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.white.opacity(0.06))
                        .frame(height: 120)
                        .shimmer()
                }
            }
            RoundedRectangle(cornerRadius: 20)
                .fill(.white.opacity(0.06))
                .frame(height: 80)
                .shimmer()
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    func cpuColor(_ v: Double) -> Color { v < 50 ? config.accentColor : v < 80 ? .orange : .red }
    func ramColor(_ f: Double) -> Color { f < 0.7 ? .teal : f < 0.85 ? .orange : .red }
    func batteryColor(_ pct: Int) -> Color { pct > 40 ? .green : pct > 20 ? .yellow : .red }

    func startClock() {
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            currentTime = Date()
        }
    }

    // MARK: - Data Loading

    func loadStatus() async {
        do {
            let s = try await api.fetchStatus()
            await MainActor.run {
                withAnimation(config.animationsEnabled ? .easeInOut(duration: 0.3) : .none) {
                    status = s
                    loading = false
                    error = nil
                }
            }
        } catch {
            await MainActor.run {
                self.error = "Keine Verbindung: \(error.localizedDescription)"
                loading = false
            }
        }
    }

    func startPolling() async {
        await loadStatus()
        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(config.autoRefreshInterval))
                if !Task.isCancelled { await loadStatus() }
            }
        }
    }
}
