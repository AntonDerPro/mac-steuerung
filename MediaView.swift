import SwiftUI

struct MediaView: View {
    @EnvironmentObject var api: AgentAPI
    @EnvironmentObject var config: AgentConfig
    @Binding var showSettings: Bool

    @State private var media: MediaStatus?
    @State private var volume: VolumeStatus?
    @State private var error: String?
    @State private var volumeSlider: Double = 50
    @State private var isDraggingVolume = false
    @State private var pollingTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                if let cover = media?.cover, let img = base64UIImage(cover) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        .blur(radius: 60)
                        .opacity(0.35)
                        .animation(.easeInOut(duration: 0.8), value: cover)
                } else {
                    FrostedBackground()
                }

                Color.black.opacity(0.5).ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        albumArtSection
                        trackInfoSection
                        controlsSection
                        volumeSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Musik")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsToolbarButton(showSettings: $showSettings)
                }
            }
            .task { await startPolling() }
            .onDisappear { pollingTask?.cancel() }
        }
        .preferredColorScheme(config.preferredColorScheme)
    }

    // MARK: - Album Art

    var albumArtSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 240, height: 240)
                .shadow(color: .black.opacity(0.4), radius: 20, y: 10)

            if let cover = media?.cover, let img = base64UIImage(cover) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 240, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 64))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .scaleEffect(media?.playing == true ? 1.0 : 0.92)
        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: media?.playing)
        .shadow(color: .black.opacity(0.5), radius: 30, y: 15)
    }

    // MARK: - Track Info

    var trackInfoSection: some View {
        VStack(spacing: 4) {
            Text(media?.title ?? "Keine Wiedergabe")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .animation(.easeInOut, value: media?.title)

            Text(media?.artist ?? "–")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
                .animation(.easeInOut, value: media?.artist)

            if let m = media, m.duration > 0 {
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15)).frame(height: 3)
                            Capsule()
                                .fill(.white.opacity(0.7))
                                .frame(width: max(CGFloat(m.position) / CGFloat(m.duration) * geo.size.width, 0), height: 3)
                        }
                    }
                    .frame(height: 3)
                    .padding(.top, 12)

                    HStack {
                        Text(formatTime(m.position)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                        Spacer()
                        Text(formatTime(m.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Controls

    var controlsSection: some View {
        HStack(spacing: 40) {
            controlButton(icon: "backward.fill", size: 28) {
                if config.hapticsEnabled { Haptics.impact(.medium) }
                Task { try? await api.mediaControl(action: "previous") }
            }

            controlButton(icon: media?.playing == true ? "pause.fill" : "play.fill", size: 44) {
                if config.hapticsEnabled { Haptics.impact(.medium) }
                Task {
                    try? await api.mediaControl(action: "playpause")
                    try? await Task.sleep(for: .milliseconds(400))
                    await refreshMedia()
                }
            }

            controlButton(icon: "forward.fill", size: 28) {
                if config.hapticsEnabled { Haptics.impact(.medium) }
                Task { try? await api.mediaControl(action: "next") }
            }
        }
        .padding(.vertical, 8)
    }

    func controlButton(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Volume

    var volumeSection: some View {
        VStack(spacing: 12) {
            SectionHeader(title: "Lautstärke", icon: "speaker.wave.2")

            HStack(spacing: 12) {
                Image(systemName: volume?.muted == true ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .onTapGesture {
                        if config.hapticsEnabled { Haptics.impact(.light) }
                        Task {
                            try? await api.setMute(muted: !(volume?.muted == true))
                            await refreshMedia()
                        }
                    }

                Slider(value: $volumeSlider, in: 0...100, step: 1,
                       onEditingChanged: { editing in
                    isDraggingVolume = editing
                    if !editing {
                        if config.hapticsEnabled { Haptics.selection() }
                        Task { try? await api.setVolume(level: Int(volumeSlider)) }
                    }
                })
                .tint(config.accentColor)

                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(14)
            .glassCard()
        }
    }

    // MARK: - Helpers

    func base64UIImage(_ b64: String) -> UIImage? {
        guard let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: data)
    }

    func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func refreshMedia() async {
        do {
            let s = try await api.fetchStatus()
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.4)) {
                    media = s.media
                    volume = s.volume
                    if !isDraggingVolume, let v = s.volume?.volume {
                        volumeSlider = Double(v)
                    }
                }
            }
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
    }

    func startPolling() async {
        await refreshMedia()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if !Task.isCancelled { await refreshMedia() }
            }
        }
    }
}
