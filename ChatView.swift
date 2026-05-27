import SwiftUI
import Combine
import UserNotifications
import PhotosUI

struct ChatAttachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let base64Data: String
    let imageRepresentation: UIImage
}

struct ChatView: View {
    @EnvironmentObject var api: AgentAPI
    @EnvironmentObject var config: AgentConfig
    @Binding var showSettings: Bool

    @State private var messages: [ChatMessage] = []
    @State private var input = ""
    @State private var loading = false
    @State private var currentModel = "gemma4"
    @FocusState private var focused: Bool

    // Media Picker States
    @State private var showImagePicker = false
    @State private var showFileImporter = false
    @State private var imageSelections: [PhotosPickerItem] = []
    @State private var attachedFiles: [ChatAttachment] = []

    let models = [
        ("gemma4-vision", "Gemma 4 Vision", "eye"),
        ("gemma4",        "Gemma 4",        "sparkles"),
        ("qwen3:4b",      "Qwen3 4B",       "cpu"),
        ("phi3:mini",     "Phi-3 Mini",     "bolt"),
        ("ibm/granite4:3b","Granite 3B",    "building.2"),
    ]

    var body: some View {
        NavigationStack {
            ZStack {
                FrostedBackground()

                VStack(spacing: 0) {
                    modelPicker
                    Divider().opacity(0.15)

                    if messages.isEmpty {
                        chatWelcome
                    } else {
                        chatMessages
                    }
                }
            }
            .navigationTitle("AI Chat")
            .navigationBarTitleDisplayMode(.large)
            // Native keyboard attachment fix for iOS/iPadOS
            .safeAreaInset(edge: .bottom) {
                chatInputBar
            }
            .toolbar {
                if !messages.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            if config.hapticsEnabled { Haptics.impact(.light) }
                            withAnimation(config.animationsEnabled ? .easeInOut(duration: 0.25) : .none) {
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
            .photosPicker(isPresented: $showImagePicker, selection: $imageSelections, maxSelectionCount: 5, matching: .images)
            .onChange(of: imageSelections) { _, newItems in
                processSelectedImages(newItems)
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .movie, .image], allowsMultipleSelection: true) { result in
                processSelectedFiles(result)
            }
        }
        .preferredColorScheme(config.preferredColorScheme)
    }

    // MARK: - Model Picker

    var modelPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(models, id: \.0) { id, name, icon in
                    Button {
                        if config.hapticsEnabled { Haptics.selection() }
                        currentModel = id
                        messages = []
                        attachedFiles = []
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: icon).font(.caption2.weight(.semibold))
                            Text(name).font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            currentModel == id
                                ? config.accentColor.opacity(0.25)
                                : Color.white.opacity(0.06),
                            in: Capsule()
                        )
                        .foregroundStyle(currentModel == id ? config.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                    .animation(.easeInOut(duration: 0.15), value: currentModel)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Welcome

    var chatWelcome: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [config.accentColor.opacity(0.35), .purple.opacity(0.2)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                Image(systemName: models.first(where: { $0.0 == currentModel })?.2 ?? "sparkles")
                    .font(.system(size: 30))
            }
            VStack(spacing: 6) {
                Text(models.first(where: { $0.0 == currentModel })?.1 ?? "AI Chat")
                    .font(.title3.weight(.semibold))
                Text("Läuft lokal auf deinem Mac über Ollama")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Messages

    var chatMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(messages) { msg in
                        ChatBubble(message: msg)
                            .id(msg.id)
                            .bubbleAppear(isUser: msg.role == "user")
                    }
                    if loading {
                        TypingIndicator()
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

    var chatInputBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.2)
            
            // Attachment Preview Strip
            if !attachedFiles.isEmpty && currentModel == "gemma4-vision" {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(attachedFiles) { file in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: file.imageRepresentation)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                                    )
                                
                                Button {
                                    if let idx = attachedFiles.firstIndex(of: file) {
                                        attachedFiles.remove(at: idx)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.gray, Color(.systemBackground))
                                        .font(.system(size: 18))
                                }
                                .offset(x: 5, y: -5)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .background(.black.opacity(0.02))
            }

            HStack(spacing: 10) {
                // Media Attachment Plus Symbol Button
                if currentModel == "gemma4-vision" {
                    Menu {
                        Button {
                            showImagePicker = true
                        } label: {
                            Label("Foto / Video", systemImage: "photo.on.rectangle")
                        }
                        Button {
                            showFileImporter = true
                        } label: {
                            Label("Datei / PDF", systemImage: "doc.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(config.accentColor)
                    }
                    .buttonStyle(.plain)
                }

                TextField("Nachricht…", text: $input, axis: .vertical)
                    .font(.subheadline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .focused($focused)
                    .lineLimit(1...6)

                Button {
                    if config.hapticsEnabled { Haptics.impact(.medium) }
                    sendChat()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(
                            input.trimmingCharacters(in: .whitespaces).isEmpty && attachedFiles.isEmpty || loading
                                ? .secondary
                                : config.accentColor
                        )
                        .scaleEffect(input.trimmingCharacters(in: .whitespaces).isEmpty && attachedFiles.isEmpty ? 0.9 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: input.isEmpty)
                }
                .disabled((input.trimmingCharacters(in: .whitespaces).isEmpty && attachedFiles.isEmpty) || loading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .padding(.bottom, 4)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - Media Handlers

    private func processSelectedImages(_ items: [PhotosPickerItem]) {
        Task {
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data),
                   let compressedData = uiImage.jpegData(compressionQuality: 0.4) {
                    let base64 = compressedData.base64EncodedString()
                    await MainActor.run {
                        attachedFiles.append(ChatAttachment(name: "Foto", base64Data: base64, imageRepresentation: uiImage))
                    }
                }
            }
            await MainActor.run { imageSelections = [] }
        }
    }

    private func processSelectedFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            for url in urls {
                guard url.startAccessingSecurityScopedResource() else { continue }
                defer { url.stopAccessingSecurityScopedResource() }
                
                if let data = try? Data(contentsOf: url) {
                    let base64 = data.base64EncodedString()
                    let isPDF = url.pathExtension.lowercased() == "pdf"
                    let thumbnail = isPDF ? (UIImage(systemName: "doc.text.fill") ?? UIImage()) : (UIImage(data: data) ?? UIImage(systemName: "doc.fill") ?? UIImage())
                    
                    attachedFiles.append(ChatAttachment(name: url.lastPathComponent, base64Data: base64, imageRepresentation: thumbnail))
                }
            }
        case .failure(let error):
            print("File import failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Send

    func sendChat() {
        let text = input.trimmingCharacters(in: .whitespaces)
        if text.isEmpty && attachedFiles.isEmpty { return }
        
        input = ""
        let currentAttachments = attachedFiles
        attachedFiles = []
        
        // Pass base64 layout arrays into the local message item
        let imageStringArray = currentAttachments.map { $0.base64Data }
        let userMsg = ChatMessage(role: "user", content: text, images: imageStringArray.isEmpty ? nil : imageStringArray)
        
        withAnimation(config.animationsEnabled ? .spring(response: 0.35, dampingFraction: 0.72) : .none) {
            messages.append(userMsg)
        }
        
        loading = true
        
        // Map messages to the secure type-safe model array
        let apiMessages = messages.map { msg in
            APIChatMessage(role: msg.role, content: msg.content, images: msg.images)
        }
        
        Task {
            do {
                let reply = try await api.aiChat(messages: apiMessages, model: currentModel)
                await MainActor.run {
                    loading = false
                    if config.hapticsEnabled { Haptics.notification(.success) }
                    withAnimation(config.animationsEnabled ? .spring(response: 0.35, dampingFraction: 0.72) : .none) {
                        messages.append(ChatMessage(role: "assistant", content: reply))
                    }
                    if config.notificationsEnabled {
                        let appState = UIApplication.shared.applicationState
                        if appState == .background || appState == .inactive {
                            let preview = String(reply.prefix(80))
                            NotificationManager.shared.send(title: "AI Chat Antwort", body: preview)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    loading = false
                    if config.hapticsEnabled { Haptics.notification(.error) }
                    withAnimation(config.animationsEnabled ? .spring(response: 0.35, dampingFraction: 0.72) : .none) {
                        messages.append(ChatMessage(role: "assistant", content: "⚠️ Fehler: \(error.localizedDescription)"))
                    }
                }
            }
        }
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    let message: ChatMessage
    @EnvironmentObject var config: AgentConfig
    @State private var copied = false

    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 60) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 6) {
                    // Display images if attached to the message
                    if let images = message.images, !images.isEmpty {
                        ForEach(0..<images.count, id: \.self) { i in
                            if let data = Data(base64Encoded: images[i]), let uiImg = UIImage(data: data) {
                                Image(uiImage: uiImg)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 220, maxHeight: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .padding(.bottom, 2)
                            }
                        }
                    }
                    
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.subheadline)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isUser
                        ? AnyShapeStyle(config.accentColor.opacity(0.85))
                        : AnyShapeStyle(.ultraThinMaterial),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.primary.opacity(isUser ? 0 : 0.08), lineWidth: 1)
                )
                .foregroundStyle(isUser ? .white : .primary)
                .textSelection(.enabled)

                if !isUser {
                    Button {
                        UIPasteboard.general.string = message.content
                        if config.hapticsEnabled { Haptics.impact(.light) }
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Label(copied ? "Kopiert" : "Kopieren",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if !isUser { Spacer(minLength: 60) }
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    @State private var phase = 0
    let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.secondary.opacity(0.6))
                    .frame(width: 7, height: 7)
                    .scaleEffect(phase == i ? 1.4 : 1.0)
                    .animation(.easeInOut(duration: 0.3), value: phase)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}
