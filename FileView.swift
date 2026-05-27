import SwiftUI

struct FileView: View {
    @EnvironmentObject var api: AgentAPI
    @EnvironmentObject var config: AgentConfig
    @Binding var showSettings: Bool

    @State private var files: [FileItem] = []
    @State private var currentPath = "~/Downloads"
    @State private var error: String?
    @State private var loading = false
    @State private var navigationStack: [String] = []
    // Forward-stack for right-swipe (redo)
    @State private var forwardStack: [String] = []
    // Gesture offset for visual feedback
    @State private var dragOffset: CGFloat = 0
    @State private var isDragging = false

    let quickFolders = [
        ("Downloads",  "~/Downloads",  "arrow.down.circle"),
        ("Desktop",    "~/Desktop",    "display"),
        ("Dokumente",  "~/Documents",  "doc.fill"),
        ("Bilder",     "~/Pictures",   "photo"),
        ("iCloud",     "icloud:/",     "icloud"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()

                VStack(spacing: 0) {
                    // Quick access bar
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(quickFolders, id: \.0) { name, path, icon in
                                Button {
                                    if config.hapticsEnabled { Haptics.impact(.light) }
                                    navigateTo(path: path, clearStacks: true)
                                } label: {
                                    Label(name, systemImage: icon)
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .background(
                                            currentPath == path
                                                ? config.accentColor.opacity(0.25)
                                                : Color.white.opacity(0.06),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(currentPath == path ? config.accentColor : .secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }

                    // Path indicator with back/forward buttons
                    HStack(spacing: 6) {
                        // Back button
                        Button {
                            goBack()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(navigationStack.isEmpty ? .secondary.opacity(0.3) : config.accentColor)
                        }
                        .disabled(navigationStack.isEmpty)
                        .buttonStyle(.plain)

                        // Forward button
                        Button {
                            goForward()
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(forwardStack.isEmpty ? .secondary.opacity(0.3) : config.accentColor)
                        }
                        .disabled(forwardStack.isEmpty)
                        .buttonStyle(.plain)

                        Image(systemName: "folder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(currentPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)

                    Divider().opacity(0.2)

                    if loading {
                        Spacer()
                        ProgressView().tint(config.accentColor)
                        Spacer()
                    } else if let error {
                        Spacer()
                        ConnectionBanner(error: error)
                        Spacer()
                    } else {
                        GeometryReader { geo in
                            let screenWidth = geo.size.width
                            fileList
                                .frame(maxWidth: .infinity, maxHeight: .infinity) // Fixes empty rendering issue inside GeometryReader
                                .offset(x: dragOffset)
                                .gesture(
                                    DragGesture(minimumDistance: 20)
                                        .onChanged { value in
                                            let startX = value.startLocation.x
                                            if startX < 30 && value.translation.width > 0 && !navigationStack.isEmpty {
                                                isDragging = true
                                                dragOffset = min(value.translation.width * 0.4, 80)
                                            } else if startX > screenWidth - 30 && value.translation.width < 0 && !forwardStack.isEmpty {
                                                isDragging = true
                                                dragOffset = max(value.translation.width * 0.4, -80)
                                            }
                                        }
                                        .onEnded { value in
                                            let startX = value.startLocation.x
                                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                dragOffset = 0
                                            }
                                            isDragging = false
                                            if startX < 30 && value.translation.width > 60 && !navigationStack.isEmpty {
                                                if config.hapticsEnabled { Haptics.impact(.medium) }
                                                goBack()
                                            } else if startX > screenWidth - 30 && value.translation.width < -60 && !forwardStack.isEmpty {
                                                if config.hapticsEnabled { Haptics.impact(.medium) }
                                                goForward()
                                            }
                                        }
                                )
                        }
                    }
                }
            }
            .navigationTitle("Dateien")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SettingsToolbarButton(showSettings: $showSettings)
                }
            }
            .task { await loadFiles(path: currentPath) }
        }
        .preferredColorScheme(config.preferredColorScheme)
    }

    // MARK: - Navigation

    func goBack() {
        guard let prev = navigationStack.last else { return }
        forwardStack.append(currentPath)
        navigationStack.removeLast()
        withAnimation(config.animationsEnabled ? .easeInOut(duration: 0.2) : .none) {
            currentPath = prev
        }
        Task { await loadFiles(path: prev) }
    }

    func goForward() {
        guard let next = forwardStack.last else { return }
        navigationStack.append(currentPath)
        forwardStack.removeLast()
        withAnimation(config.animationsEnabled ? .easeInOut(duration: 0.2) : .none) {
            currentPath = next
        }
        Task { await loadFiles(path: next) }
    }

    func navigateTo(path: String, clearStacks: Bool = false) {
        if clearStacks {
            navigationStack = []
            forwardStack = []
        } else {
            navigationStack.append(currentPath)
            forwardStack = []
        }
        currentPath = path
        Task { await loadFiles(path: path) }
    }

    // MARK: - File List

    var fileList: some View {
        List {
            ForEach(files) { file in
                Button {
                    if file.is_dir {
                        if config.hapticsEnabled { Haptics.impact(.light) }
                        navigateTo(path: file.path)
                    }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: fileIcon(file))
                            .font(.system(size: 20))
                            .foregroundStyle(fileColor(file))
                            .frame(width: 32)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(file.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(formatDate(file.modified))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if !file.is_dir {
                                    Text("·")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(formatSize(file.size))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        Spacer()

                        if file.is_dir {
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(Color.primary.opacity(0.08))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Helpers

    func fileIcon(_ f: FileItem) -> String {
        if f.is_dir { return "folder.fill" }
        let ext = (f.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.fill"
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "mp3", "m4a", "aac", "wav", "flac": return "music.note"
        case "zip", "rar", "7z", "tar", "gz": return "archivebox"
        case "swift", "py", "js", "ts", "html", "css", "json": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }

    func fileColor(_ f: FileItem) -> Color {
        if f.is_dir { return .yellow }
        let ext = (f.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return .red
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return .teal
        case "mp4", "mov", "avi", "mkv": return .purple
        case "mp3", "m4a", "aac", "wav", "flac": return .pink
        case "zip", "rar", "7z", "tar", "gz": return .brown
        default: return config.accentColor
        }
    }

    func formatSize(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1 { return "\(bytes) B" }
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }

    func formatDate(_ ts: Double) -> String {
        let date = Date(timeIntervalSince1970: ts)
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    func loadFiles(path: String) async {
        await MainActor.run { loading = true; error = nil }
        do {
            guard let url = URL(string: "http://" + config.host + ":" + String(config.port) + "/list") else {
                await MainActor.run {
                    self.error = "Ungültige Server-URL"
                    loading = false
                }
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(["path": path])
            let (data, _) = try await URLSession.shared.data(for: request)
            print(String(data: data, encoding: .utf8) ?? "<no data>")
            struct FileListResponse: Decodable {
                let files: [FileItem]?
            }
            let decoded = try JSONDecoder().decode(FileListResponse.self, from: data)
            let result = decoded.files ?? []
            await MainActor.run {
                withAnimation(config.animationsEnabled ? .easeInOut(duration: 0.2) : .none) {
                    let filteredResults = result.filter { !$0.name.hasPrefix(".") }
                    files = filteredResults.sorted { a, b in
                        if a.is_dir != b.is_dir { return a.is_dir }
                        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                    }
                    loading = false
                }
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }
}
