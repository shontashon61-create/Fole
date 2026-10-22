import SwiftUI
import PhotosUI
import Speech
import AVFoundation

// MARK: - Модели данных
struct ChatEntry: Identifiable, Codable {
    var id = UUID()
    let role: String
    var content: String
    var photoData: Data? = nil
    var createdAt = Date()
}

struct DialogueThread: Identifiable, Codable {
    var id = UUID()
    var name: String
    var items: [ChatEntry]
    var modifiedAt = Date()
}

// MARK: - Голосовой движок (диктовка + озвучка)
class SpeechService: NSObject, ObservableObject {
    @Published var isListening = false
    
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    private let speaker = AVSpeechSynthesizer()
    
    func toggleDictation(onUpdate: @escaping (String) -> Void) {
        if isListening {
            stopDictation()
        } else {
            startDictation(onUpdate: onUpdate)
        }
    }
    
    private func startDictation(onUpdate: @escaping (String) -> Void) {
        SFSpeechRecognizer.requestAuthorization { authStatus in
            guard authStatus == .authorized else { return }
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                guard granted else { return }
                DispatchQueue.main.async {
                    self.launchAudioEngine(onUpdate: onUpdate)
                }
            }
        }
    }
    
    private func launchAudioEngine(onUpdate: @escaping (String) -> Void) {
        task?.cancel()
        task = nil
        
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        
        request = SFSpeechAudioBufferRecognitionRequest()
        guard let activeRequest = request else { return }
        activeRequest.shouldReportPartialResults = true
        
        let input = engine.inputNode
        task = recognizer?.recognitionTask(with: activeRequest) { result, err in
            if let text = result?.bestTranscription.formattedString {
                DispatchQueue.main.async { onUpdate(text) }
            }
            if err != nil || (result?.isFinal ?? false) {
                self.stopDictation()
            }
        }
        
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
            self.request?.append(buf)
        }
        
        engine.prepare()
        try? engine.start()
        isListening = true
    }
    
    func stopDictation() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        isListening = false
    }
    
    func readAloud(_ text: String) {
        if speaker.isSpeaking {
            speaker.stopSpeaking(at: .immediate)
            return
        }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        
        let phrase = AVSpeechUtterance(string: text)
        phrase.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        phrase.rate = 0.52
        speaker.speak(phrase)
    }
}

// MARK: - Основной интерфейс приложения
struct ContentView: View {
    @AppStorage("cfg_key") private var apiKey: String = ""
    @AppStorage("cfg_url") private var baseURL: String = "https://api.openai.com/v1"
    @AppStorage("cfg_model") private var modelName: String = "gpt-4o-mini"
    @AppStorage("cfg_prompt") private var systemPrompt: String = "Ты умный ИИ-помощник. Отвечай понятно, красиво и без громоздких тегов LaTeX."
    @AppStorage("cfg_threads") private var threadsStorage: Data = Data()
    
    @State private var threads: [DialogueThread] = []
    @State private var selectedThreadId: UUID? = nil
    
    @State private var draftText: String = ""
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var draftPhoto: Data? = nil
    @State private var isGenerating: Bool = false
    @State private var showPrefs: Bool = false
    @State private var showDrawer: Bool = false
    @State private var alertBanner: String? = nil
    
    @FocusState private var keyboardActive: Bool
    @StateObject private var speech = SpeechService()

    private var activeThreadIndex: Int? {
        threads.firstIndex(where: { $0.id == selectedThreadId })
    }

    var body: some View {
        ZStack {
            NavigationView {
                VStack(spacing: 0) {
                    // Окно переписки
                    ScrollViewReader { scroller in
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                if let idx = activeThreadIndex, !threads[idx].items.isEmpty {
                                    ForEach(threads[idx].items) { item in
                                        ChatBubbleView(entry: item) {
                                            speech.readAloud(item.content)
                                        }
                                        .id(item.id)
                                    }
                                } else {
                                    WelcomeHeroView(onSelectHint: { sample in
                                        draftText = sample
                                        keyboardActive = true
                                    })
                                }
                                
                                if isGenerating {
                                    HStack(spacing: 10) {
                                        Image(systemName: "sparkles")
                                            .foregroundColor(.purple)
                                        ProgressView()
                                        Text("Генерирую ответ...")
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 20)
                                }
                            }
                            .padding(.vertical, 14)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onTapGesture { keyboardActive = false }
                        .onChange(of: threads.first(where: { $0.id == selectedThreadId })?.items.count) { _ in
                            if let idx = activeThreadIndex, let lastId = threads[idx].items.last?.id {
                                withAnimation { scroller.scrollTo(lastId, anchor: .bottom) }
                            }
                        }
                    }
                    
                    // Плашка ошибки
                    if let banner = alertBanner {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                            Text(banner).font(.caption).lineLimit(2)
                            Spacer()
                            Button(action: { alertBanner = nil }) {
                                Image(systemName: "xmark")
                            }
                        }
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.red.opacity(0.9))
                    }
                    
                    // Превью прикреплённого фото
                    if let data = draftPhoto, let img = UIImage(data: data) {
                        HStack {
                            Image(uiImage: img)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(
                                    Button(action: { draftPhoto = nil; pickerItem = nil }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.title3)
                                            .foregroundColor(.white)
                                            .background(Circle().fill(Color.black.opacity(0.6)))
                                    }
                                    .offset(x: 6, y: -6),
                                    alignment: .topTrailing
                                )
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                    
                    // Нижняя панель ввода (в стиле Gemini)
                    HStack(alignment: .bottom, spacing: 8) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                        }
                        .onChange(of: pickerItem) { newVal in
                            Task {
                                if let raw = try? await newVal?.loadTransferable(type: Data.self),
                                   let uiImg = UIImage(data: raw),
                                   let jpeg = uiImg.jpegData(compressionQuality: 0.7) {
                                    draftPhoto = jpeg
                                }
                            }
                        }
                        
                        TextField("Спросите ИИ...", text: $draftText, axis: .vertical)
                            .lineLimit(1...5)
                            .focused($keyboardActive)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                        
                        // Микрофон
                        Button(action: {
                            keyboardActive = false
                            speech.toggleDictation { recognized in
                                draftText = recognized
                            }
                        }) {
                            Image(systemName: speech.isListening ? "waveform.circle.fill" : "mic.fill")
                                .font(.system(size: speech.isListening ? 28 : 20))
                                .foregroundColor(speech.isListening ? .red : .secondary)
                                .padding(.bottom, 4)
                        }
                        
                        // Отправка
                        if readyToSend {
                            Button(action: submitQuery) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundStyle(
                                        LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                                    )
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 24))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: {
                            keyboardActive = false
                            withAnimation(.easeInOut(duration: 0.25)) { showDrawer.toggle() }
                        }) {
                            Image(systemName: "line.3.horizontal")
                                .font(.title3.bold())
                        }
                    }
                    
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 6) {
                            Image(systemName: "sparkles")
                                .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
                            Text(modelName).font(.headline)
                        }
                    }
                    
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        if keyboardActive {
                            Button(action: { keyboardActive = false }) {
                                Image(systemName: "keyboard.chevron.compact.down")
                            }
                        }
                        Button(action: createFreshThread) {
                            Image(systemName: "square.and.pencil")
                        }
                        Button(action: {
                            keyboardActive = false
                            showPrefs = true
                        }) {
                            Image(systemName: "gearshape.fill")
                        }
                    }
                }
                .sheet(isPresented: $showPrefs) {
                    PreferencesSheet(apiKey: $apiKey, baseURL: $baseURL, modelName: $modelName, systemPrompt: $systemPrompt)
                }
            }
            .navigationViewStyle(.stack)
            
            // Боковое выдвижное меню с историей диалогов
            if showDrawer {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) { showDrawer = false }
                    }
                
                HStack(spacing: 0) {
                    DrawerMenuView(
                        threads: $threads,
                        selectedId: $selectedThreadId,
                        onPick: { id in
                            selectedThreadId = id
                            withAnimation { showDrawer = false }
                        },
                        onCreate: {
                            createFreshThread()
                            withAnimation { showDrawer = false }
                        },
                        onRemove: { id in removeThread(id: id) }
                    )
                    .frame(width: 280)
                    .background(Color(.systemBackground))
                    
                    Spacer()
                }
                .transition(.move(edge: .leading))
            }
        }
        .onAppear(perform: restoreThreads)
    }
    
    private var readyToSend: Bool {
        (!draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftPhoto != nil) && !isGenerating
    }
    
    // MARK: - Управление историей чатов
    private func restoreThreads() {
        if let list = try? JSONDecoder().decode([DialogueThread].self, from: threadsStorage), !list.isEmpty {
            threads = list
            selectedThreadId = threads.first?.id
        } else {
            createFreshThread()
        }
    }
    
    private func persistThreads() {
        if let data = try? JSONEncoder().encode(threads) {
            threadsStorage = data
        }
    }
    
    private func createFreshThread() {
        let fresh = DialogueThread(name: "Новый чат", items: [])
        threads.insert(fresh, at: 0)
        selectedThreadId = fresh.id
        persistThreads()
    }
    
    private func removeThread(id: UUID) {
        threads.removeAll { $0.id == id }
        if threads.isEmpty {
            createFreshThread()
        } else if selectedThreadId == id {
            selectedThreadId = threads.first?.id
        }
        persistThreads()
    }
    
    // MARK: - Запрос к нейросети
    private func submitQuery() {
        keyboardActive = false
        if speech.isListening { speech.stopDictation() }
        
        guard !apiKey.isEmpty else {
            alertBanner = "Сначала добавьте API ключ в настройках ⚙️"
            showPrefs = true
            return
        }
        
        if activeThreadIndex == nil { createFreshThread() }
        guard let idx = activeThreadIndex else { return }
        
        alertBanner = nil
        let cleanText = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachedPic = draftPhoto
        
        let userEntry = ChatEntry(role: "user", content: cleanText, photoData: attachedPic)
        threads[idx].items.append(userEntry)
        
        if threads[idx].name == "Новый чат" && !cleanText.isEmpty {
            threads[idx].name = String(cleanText.prefix(30))
        }
        threads[idx].modifiedAt = Date()
        persistThreads()
        
        draftText = ""
        draftPhoto = nil
        pickerItem = nil
        isGenerating = true
        
        let snapshot = threads[idx].items
        
        Task {
            do {
                let rawAnswer = try await requestCompletion(history: snapshot)
                let prettyAnswer = sanitizeMathSymbols(rawAnswer)
                await MainActor.run {
                    if let cur = activeThreadIndex {
                        threads[cur].items.append(ChatEntry(role: "assistant", content: prettyAnswer))
                        persistThreads()
                    }
                    isGenerating = false
                }
            } catch {
                await MainActor.run {
                    alertBanner = error.localizedDescription
                    isGenerating = false
                }
            }
        }
    }
    
    private func sanitizeMathSymbols(_ input: String) -> String {
        var out = input
        let replacements: [(String, String)] = [
            ("\\(", ""), ("\\)", ""), ("\\[", "\n"), ("\\]", "\n"),
            ("\\left", ""), ("\\right", ""), ("\\cdot", "·"),
            ("\\times", "×"), ("\\div", "÷"), ("\\pm", "±"),
            ("\\approx", "≈"), ("\\neq", "≠"), ("\\leq", "≤"), ("\\geq", "≥")
        ]
        for (target, replacement) in replacements {
            out = out.replacingOccurrences(of: target, with: replacement)
        }
        return out
    }
    
    private func requestCompletion(history: [ChatEntry]) async throws -> String {
        let trimmedURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fullPath = trimmedURL.hasSuffix("/chat/completions") ? trimmedURL : "\(trimmedURL)/chat/completions"
        
        guard let endpoint = URL(string: fullPath) else { throw URLError(.badURL) }
        
        var messagesArray: [[String: Any]] = [
            ["role": "system", "content": systemPrompt + "\nНе используй LaTeX-формулы вроде \\frac или \\left, пиши обычными понятными символами."]
        ]
        
        for item in history {
            if let pic = item.photoData {
                let b64 = pic.base64EncodedString()
                var parts: [[String: Any]] = []
                if !item.content.isEmpty {
                    parts.append(["type": "text", "text": item.content])
                }
                parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]])
                messagesArray.append(["role": item.role, "content": parts])
            } else {
                messagesArray.append(["role": item.role, "content": item.content])
            }
        }
        
        let payload: [String: Any] = ["model": modelName, "messages": messagesArray]
        
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? "Ошибка сервера \(http.statusCode)"
            throw NSError(domain: "NetErr", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let msgDict = first["message"] as? [String: Any],
              let replyText = msgDict["content"] as? String else {
            throw NSError(domain: "FormatErr", code: 0, userInfo: [NSLocalizedDescriptionKey: "Не удалось разобрать ответ от ИИ"])
        }
        
        return replyText
    }
}

// MARK: - Приветственный экран с быстрыми идеями
struct WelcomeHeroView: View {
    let onSelectHint: (String) -> Void
    
    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 50)
            Image(systemName: "sparkles")
                .font(.system(size: 54))
                .foregroundStyle(LinearGradient(colors: [.blue, .purple, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
            
            Text("Привет! Чем помочь?")
                .font(.title2.bold())
            
            Text("Задайте любой вопрос, прикрепите картинку или нажмите на микрофон.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    HintButton(label: "Объясни просто", icon: "lightbulb.fill") {
                        onSelectHint("Объясни простыми словами: ")
                    }
                    HintButton(label: "Помоги по фото", icon: "camera.viewfinder") {
                        onSelectHint("Разбери задание на фото понятным текстом")
                    }
                    HintButton(label: "Придумай идею", icon: "wand.and.stars") {
                        onSelectHint("Придумай 5 интересных идей для ")
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }
}

struct HintButton: View {
    let label: String
    let icon: String
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundColor(.blue)
                Text(label).font(.subheadline).foregroundColor(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
        }
    }
}

// MARK: - Боковое меню со списком чатов
struct DrawerMenuView: View {
    @Binding var threads: [DialogueThread]
    @Binding var selectedId: UUID?
    let onPick: (UUID) -> Void
    let onCreate: () -> Void
    let onRemove: (UUID) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
                Text("Чаты").font(.title3.bold())
                Spacer()
            }
            .padding()
            
            Button(action: onCreate) {
                HStack {
                    Image(systemName: "plus")
                    Text("Новый диалог").fontWeight(.semibold)
                    Spacer()
                }
                .padding(12)
                .background(Color.blue.opacity(0.15))
                .foregroundColor(.blue)
                .cornerRadius(14)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
            
            Divider()
            
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(threads) { item in
                        HStack {
                            Image(systemName: "bubble.left.fill")
                                .font(.subheadline)
                                .foregroundColor(item.id == selectedId ? .blue : .secondary)
                            Text(item.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            Button(action: { onRemove(item.id) }) {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(12)
                        .background(item.id == selectedId ? Color(.secondarySystemBackground) : Color.clear)
                        .cornerRadius(12)
                        .contentShape(Rectangle())
                        .onTapGesture { onPick(item.id) }
                    }
                }
                .padding(10)
            }
        }
    }
}

// MARK: - Оформление сообщений
struct ChatBubbleView: View {
    let entry: ChatEntry
    let onReadAloud: () -> Void
    private var isUser: Bool { entry.role == "user" }
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if !isUser {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 30, height: 30)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(Circle())
            } else {
                Spacer(minLength: 40)
            }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if let picData = entry.photoData, let img = UIImage(data: picData) {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 230, maxHeight: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                
                if !entry.content.isEmpty {
                    Group {
                        if let parsed = try? AttributedString(markdown: entry.content, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                            Text(parsed)
                        } else {
                            Text(entry.content)
                        }
                    }
                    .font(.body)
                    .foregroundColor(isUser ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        isUser
                        ? AnyShapeStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                        : AnyShapeStyle(Color(.secondarySystemBackground))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .textSelection(.enabled)
                }
                
                if !isUser && !entry.content.isEmpty {
                    HStack(spacing: 16) {
                        Button(action: onReadAloud) {
                            Label("Озвучить", systemImage: "speaker.wave.2")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Button(action: { UIPasteboard.general.string = entry.content }) {
                            Label("Копировать", systemImage: "doc.on.doc")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.leading, 6)
                }
            }
            
            if !isUser { Spacer(minLength: 20) }
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Экран настроек
struct PreferencesSheet: View {
    @Binding var apiKey: String
    @Binding var baseURL: String
    @Binding var modelName: String
    @Binding var systemPrompt: String
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Параметры API")) {
                    SecureField("API Ключ", text: $apiKey)
                    TextField("Base URL", text: $baseURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Модель", text: $modelName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                Section(header: Text("Системный промпт")) {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 110)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }.bold()
                }
            }
        }
    }
}
