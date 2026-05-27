import SwiftUI
import UserNotifications

struct AgentMessage: Identifiable {
    var id = UUID()
    enum Kind { case user, assistant, choices([AgentTreffer], dst: String), success(String), error(String) }
    var kind: Kind
    var text: String
}

struct AgentView: View {
    @EnvironmentObject var api: AgentAPI
    @EnvironmentObject var config: AgentConfig
    @Binding var showSettings: Bool

    @State private var messages: [AgentMessage] = []
    @State private var input = ""
    @State private var loading = false
    @FocusState private var focused: Bool

    let suggestions = [
        "Rechnung in iCloud verschieben",
        "Lebenslauf von Desktop nach iCloud",
        "Alle PDFs aus Downloads nach iCloud",
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()

                VStack(spacing: 0) {
                    if messages.isEmpty {
                        welcomeView
                    } else {
                        messageList
                    }
                    inputBar
                }
            }
            .navigationTitle("AI Agent")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if !messages.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            if config.hapticsEnabled { Haptics.impact(.light) }
                            withAnimation(config.animationsEnabled ? .easeInOut : .none) {
                                messages = []
                            }
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red.opacity(0.8))
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsToolbarButton(showSettings: $showSettings)
                }
            }
        }
        .preferredColorScheme(config.preferredColorScheme)
    }

    // MARK: - Welcome

    var welcomeView: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [config.accentColor.opacity(0.3), .purple.opacity(0.2)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 80, height: 80)
                Image(systemName: "sparkles")
                    .font(.system(size: 36))
            }
            VStack(spacing: 8) {
                Text("Datei-Assistent")
                    .font(.title2.weight(.semibold))
                Text("Sage mir, welche Datei du wohin verschieben möchtest.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { s in
                    Button {
                        if config.hapticsEnabled { Haptics.impact(.light) }
                        input = s
                        focused = true
                    } label: {
                        Text(s)
                            .font(.subheadline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .glassCard()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            Spacer()
        }
    }

    // MARK: - Messages

    var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(messages) { msg in
                        AgentMessageView(message: msg) { path in
                            confirmMove(src: path, dst: msg)
                        }
                        .id(msg.id)
                        // Only user/assistant bubbles get bubble animation
                        .modifier(AgentBubbleModifier(kind: msg.kind, animate: config.animationsEnabled))
                    }
                    if loading {
                        HStack {
                            ProgressView().tint(config.accentColor).scaleEffect(0.8)
                            Text("Analysiere…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                        .glassCard()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .id("loading")
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: loading) { _, newVal in
                if newVal { withAnimation { proxy.scrollTo("loading", anchor: .bottom) } }
            }
        }
    }

    // MARK: - Input Bar

    var inputBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.2)
            HStack(spacing: 10) {
                TextField("Datei verschieben…", text: $input, axis: .vertical)
                    .font(.subheadline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .focused($focused)
                    .lineLimit(1...4)
                    .onSubmit { sendMessage() }

                Button {
                    if config.hapticsEnabled { Haptics.impact(.medium) }
                    sendMessage()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            input.trimmingCharacters(in: .whitespaces).isEmpty
                                ? .secondary
                                : config.accentColor
                        )
                        .scaleEffect(input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.9 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: input.isEmpty)
                }
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || loading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Actions

    func sendMessage() {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        input = ""
        withAnimation(config.animationsEnabled ? .spring(response: 0.35, dampingFraction: 0.72) : .none) {
            messages.append(AgentMessage(kind: .user, text: text))
        }
        loading = true
        Task {
            do {
                let result = try await api.aiMove(prompt: text)
                await MainActor.run {
                    loading = false
                    if config.hapticsEnabled { Haptics.notification(.success) }
                    withAnimation(config.animationsEnabled ? .spring(response: 0.35, dampingFraction: 0.72) : .none) {
                        if result.status == "auswahl", let treffer = result.treffer, let dst = result.dst {
                            messages.append(AgentMessage(kind: .choices(treffer, dst: dst), text: "Welche Datei meinst du?"))
                        } else if result.status == "nicht_gefunden" {
                            messages.append(AgentMessage(kind: .error(result.message ?? "Nicht gefunden"), text: ""))
                        } else if let err = result.error {
                            messages.append(AgentMessage(kind: .error(err), text: ""))
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    loading = false
                    if config.hapticsEnabled { Haptics.notification(.error) }
                    withAnimation(config.animationsEnabled ? .spring(response: 0.35, dampingFraction: 0.72) : .none) {
                        messages.append(AgentMessage(kind: .error(error.localizedDescription), text: ""))
                    }
                }
            }
        }
    }

    func confirmMove(src: String, dst msg: AgentMessage) {
        guard case .choices(_, let dst) = msg.kind else { return }
        if config.hapticsEnabled { Haptics.impact(.medium) }
        withAnimation(config.animationsEnabled ? .spring(response: 0.35, dampingFraction: 0.72) : .none) {
            messages.append(AgentMessage(kind: .user, text: "📄 \(src.split(separator: "/").last ?? "Datei")"))
        }
        loading = true
        Task {
            do {
                let ok = try await api.aiConfirm(src: src, dst: dst)
                await MainActor.run {
                    loading = false
                    withAnimation(config.animationsEnabled ? .spring(response: 0.35, dampingFraction: 0.72) : .none) {
                        if ok {
                            if config.hapticsEnabled { Haptics.notification(.success) }
                            messages.append(AgentMessage(kind: .success("Datei verschoben nach \(dst)"), text: ""))
                            // Notification if in background
                            if config.notificationsEnabled {
                                let appState = UIApplication.shared.applicationState
                                if appState == .background || appState == .inactive {
                                    let fileName = src.split(separator: "/").last.map(String.init) ?? "Datei"
                                    NotificationManager.shared.send(
                                        title: "Datei verschoben",
                                        body: "\(fileName) wurde nach \(dst) verschoben."
                                    )
                                }
                            }
                        } else {
                            if config.hapticsEnabled { Haptics.notification(.error) }
                            messages.append(AgentMessage(kind: .error("Verschieben fehlgeschlagen"), text: ""))
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    loading = false
                    if config.hapticsEnabled { Haptics.notification(.error) }
                    withAnimation(config.animationsEnabled ? .spring(response: 0.35, dampingFraction: 0.72) : .none) {
                        messages.append(AgentMessage(kind: .error(error.localizedDescription), text: ""))
                    }
                }
            }
        }
    }
}

// MARK: - Bubble Appear Modifier for Agent

struct AgentBubbleModifier: ViewModifier {
    let kind: AgentMessage.Kind
    let animate: Bool
    @State private var appeared = false

    var isUser: Bool {
        if case .user = kind { return true }
        return false
    }

    var shouldAnimate: Bool {
        switch kind {
        case .user, .assistant: return true
        default: return false
        }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(
                (!shouldAnimate || appeared) ? 1 : 0.7,
                anchor: isUser ? .bottomTrailing : .bottomLeading
            )
            .opacity((!shouldAnimate || appeared) ? 1 : 0)
            .offset(x: (!shouldAnimate || appeared) ? 0 : (isUser ? 20 : -20), y: (!shouldAnimate || appeared) ? 0 : 8)
            .onAppear {
                guard shouldAnimate && animate else { appeared = true; return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                    appeared = true
                }
            }
    }
}

// MARK: - Agent Message View

struct AgentMessageView: View {
    let message: AgentMessage
    let onChoose: (String) -> Void
    @EnvironmentObject var config: AgentConfig

    var body: some View {
        switch message.kind {
        case .user:
            HStack {
                Spacer()
                Text(message.text)
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(config.accentColor.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
            }

        case .choices(let treffer, _):
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text)
                    .font(.subheadline)
                ForEach(treffer) { t in
                    Button { onChoose(t.path) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "doc").foregroundStyle(config.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.name).font(.subheadline.weight(.medium))
                                Text(t.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(12)
                        .glassCard()
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .success(let text):
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(text).font(.subheadline)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()

        case .error(let text):
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                Text(text).font(.subheadline)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()

        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles").font(.caption).foregroundStyle(.purple).padding(.top, 2)
                Text(message.text).font(.subheadline)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }
}
