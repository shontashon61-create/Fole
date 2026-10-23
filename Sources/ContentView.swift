import SwiftUI
import PhotosUI
import Speech
import AVFoundation
import UniformTypeIdentifiers

struct ChatEntry: Identifiable, Codable {
    var id = UUID()
    let role: String
    var content: String
    var photoData: Data? = nil
    var attachedFileName: String? = nil
}

struct DialogueThread: Identifiable, Codable {
    var id = UUID()
    var name: String
    var items: [ChatEntry]
}

struct CameraPickerView: UIViewControllerRepresentable {
    var onImagePicked: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPickerView
        init(_ parent: CameraPickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let img = info[.originalImage] as? UIImage, let jpeg = img.jpegData(compressionQuality: 0.7) {
                parent.onImagePicked(jpeg)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

class SpeechService: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var voiceError: String? = nil
    
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ru-RU"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var engine = AVAudioEngine()
    private let speaker = AVSpeechSynthesizer()
    
    func toggleDictation(existingText: String, onUpdate: @escaping (String) -> Void) {
        isListening ? stopDictation() : startDictation(existingText: existingText, onUpdate: onUpdate)
    }
    
    private func startDictation(existingText: String, onUpdate: @escaping (String) -> Void) {
        voiceError = nil
        if speaker.isSpeaking { speaker.stopSpeaking(at: .immediate) }
        
        SFSpeechRecognizer.requestAuthorization { auth in
            DispatchQueue.main.async {
                guard auth == .authorized else { self.voiceError = "Разрешите речь в Настройках"; return }
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        guard granted else { self.voiceError = "Разрешите микрофон в Настройках"; return }
                        self.launchEngine(existingText: existingText, onUpdate: onUpdate)
                    }
                }
            }
        }
    }
    
    private func launchEngine(existingText: String, onUpdate: @escaping (String) -> Void) {
        stopDictation()
        guard let recognizer = recognizer, recognizer.isAvailable else {
            voiceError = "Распознавание недоступно"
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            
            engine = AVAudioEngine()
            request = SFSpeechAudioBufferRecognitionRequest()
            guard let req = request else { return }
            req.shouldReportPartialResults = true
            
            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buf, _ in
                self?.request?.append(buf)
            }
            engine.prepare()
            try engine.start()
            isListening = true
            
            let prefix = existingText.isEmpty ? "" : existingText + " "
            task = recognizer.recognitionTask(with: req) { [weak self] res, err in
                if let text = res?.bestTranscription.formattedString {
                    DispatchQueue.main.async { onUpdate(prefix + text) }
                }
                if err != nil || (res?.isFinal ?? false) {
                    DispatchQueue.main.async { self?.stopDictation() }
                }
            }
        } catch {
            voiceError = "Ошибка микрофона: \(error.localizedDescription)"
            stopDictation()
        }
    }
    
    func stopDictation() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio(); request = nil
        task?.cancel(); task = nil
        isListening = false
    }
    
    func readAloud(_ text: String) {
        if isListening { stopDictation() }
        if speaker.isSpeaking { speaker.stopSpeaking(at: .immediate); return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        u.rate = 0.52
        speaker.speak(u)
    }
}

struct ContentView: View {
    @AppStorage("cfg_key") private var apiKey = ""
    @AppStorage("cfg_url") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("cfg_model") private var modelName = "gpt-4o-mini"
    @AppStorage("cfg_prompt") private var systemPrompt = "Ты умный ИИ-помощник. Отвечай понятно и без тегов LaTeX."
    @AppStorage("cfg_threads") private var threadsStorage = Data()
    @AppStorage("cfg_models") private var cachedModelsData = Data()
    
    @State private var threads: [DialogueThread] = []
    @State private var selectedThreadId: UUID? = nil
    @State private var availableModels: [String] = []
    @State private var isFetchingModels = false
    @State private var showModelSelector = false
    
    @State private var draftText = ""
    @State private var pickerItem: PhotosPickerItem? = nil
    @State private var draftPhoto: Data? = nil
    @State private var draftFileName: String? = nil
    @State private var draftFileContent: String? = nil
    
    @State private var showPhotoLibrary = false
    @State private var showCamera = false
    @State private var showFiles = false
    @State private var isGenerating = false
    @State private var showPrefs = false
    @State private var showDrawer = false
    @State private var alertBanner: String? = nil
    
    @FocusState private var keyboardActive: Bool
    @StateObject private var speech = SpeechService()

    private var activeIndex: Int? { threads.firstIndex(where: { $0.id == selectedThreadId }) }

    var body: some View {
        ZStack {
            NavigationView {
                VStack(spacing: 0) {
                    ScrollViewReader { scroller in
                        ScrollView {
                            LazyVStack(spacing: 14) {
                                if let idx = activeIndex, !threads[idx].items.isEmpty {
                                    ForEach(threads[idx].items) { item in
                                        ChatBubbleView(entry: item) { speech.readAloud(item.content) }.id(item.id)
                                    }
                                } else {
                                    VStack(spacing: 14) {
                                        Spacer(minLength: 60)
                                        Image(systemName: "sparkles").font(.system(size: 50)).foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
                                        Text("Привет! Чем помочь?").font(.title2.bold())
                                        Text("Выберите модель сверху или нажмите «+» для камеры, фото и файлов.").font(.subheadline).foregroundColor(.secondary).multilineTextAlignment(.center).padding(.horizontal, 32)
                                    }
                                }
                                if isGenerating {
                                    HStack(spacing: 10) { ProgressView(); Text("Думаю...").font(.subheadline).foregroundColor(.secondary); Spacer() }.padding(.horizontal, 20)
                                }
                            }
                            .padding(.vertical, 14)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onTapGesture { keyboardActive = false }
                        .onChange(of: threads.first(where: { $0.id == selectedThreadId })?.items.count) { _ in
                            if let idx = activeIndex, let lastId = threads[idx].items.last?.id {
                                withAnimation { scroller.scrollTo(lastId, anchor: .bottom) }
                            }
                        }
                    }
                    
                    if let banner = alertBanner ?? speech.voiceError {
                        HStack {
                            Text(banner).font(.caption).lineLimit(2)
                            Spacer()
                            Button(action: { alertBanner = nil; speech.voiceError = nil }) { Image(systemName: "xmark") }
                        }.foregroundColor(.white).padding(8).background(Color.red.opacity(0.9))
                    }
                    
                    if speech.isListening {
                        Text("Слушаю вас... Говорите").font(.caption.bold()).foregroundColor(.red).padding(.vertical, 4)
                    }
                    
                    if draftPhoto != nil || draftFileName != nil {
                        HStack(spacing: 12) {
                            if let d = draftPhoto, let img = UIImage(data: d) {
                                Image(uiImage: img).resizable().scaledToFill().frame(width: 54, height: 54).clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(Button(action: { draftPhoto = nil; pickerItem = nil }) { Image(systemName: "xmark.circle.fill").foregroundColor(.white) }, alignment: .topTrailing)
                            }
                            if let fName = draftFileName {
                                HStack {
                                    Image(systemName: "doc.text.fill").foregroundColor(.blue)
                                    Text(fName).font(.caption.bold()).lineLimit(1)
                                    Button(action: { draftFileName = nil; draftFileContent = nil }) { Image(systemName: "xmark.circle.fill") }
                                }.padding(8).background(Color(.secondarySystemBackground)).cornerRadius(10)
                            }
                            Spacer()
                        }.padding(.horizontal, 16).padding(.top, 6)
                    }
                    
                    HStack(alignment: .bottom, spacing: 8) {
                        Menu {
                            Button(action: { showCamera = true }) { Label("Сделать фото", systemImage: "camera.fill") }
                            Button(action: { showPhotoLibrary = true }) { Label("Выбрать из галереи", systemImage: "photo.on.rectangle") }
                            Button(action: { showFiles = true }) { Label("Прикрепить файл", systemImage: "doc.fill") }
                        } label: {
                            Image(systemName: "plus.circle.fill").font(.system(size: 28)).foregroundStyle(.linearGradient(colors: [.blue, .purple], startPoint: .top, endPoint: .bottom))
                        }
                        
                        TextField("Спросите ИИ...", text: $draftText, axis: .vertical).lineLimit(1...5).focused($keyboardActive).padding(.vertical, 6)
                        
                        Button(action: {
                            keyboardActive = false
                            let start = draftText
                            speech.toggleDictation(existingText: start) { draftText = $0 }
                        }) {
                            Image(systemName: speech.isListening ? "stop.circle.fill" : "mic.fill")
                                .font(.system(size: speech.isListening ? 26 : 20))
                                .foregroundColor(speech.isListening ? .red : .secondary).padding(.bottom, 4)
                        }
                        
                        if readyToSend {
                            Button(action: submitQuery) {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundColor(.blue)
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8).background(Color(.secondarySystemBackground)).clipShape(RoundedRectangle(cornerRadius: 24)).padding(10)
                }
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(action: { keyboardActive = false; withAnimation { showDrawer.toggle() } }) { Image(systemName: "line.3.horizontal") }
                    }
                    ToolbarItem(placement: .principal) {
                        Button(action: {
                            keyboardActive = false; showModelSelector = true
                            if availableModels.isEmpty { loadModels() }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "sparkles").font(.caption).foregroundColor(.purple)
                                Text(modelName).font(.subheadline.bold()).foregroundColor(.primary).lineLimit(1)
                                Image(systemName: "chevron.down").font(.caption2).foregroundColor(.secondary)
                            }.padding(.horizontal, 10).padding(.vertical, 5).background(Color(.secondarySystemBackground)).clipShape(Capsule())
                        }
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        if keyboardActive { Button(action: { keyboardActive = false }) { Image(systemName: "keyboard.chevron.compact.down") } }
                        Button(action: createNewThread) { Image(systemName: "square.and.pencil") }
                        Button(action: { keyboardActive = false; showPrefs = true }) { Image(systemName: "gearshape.fill") }
                    }
                }
                .photosPicker(isPresented: $showPhotoLibrary, selection: $pickerItem, matching: .images)
                .onChange(of: pickerItem) { val in
                    Task {
                        if let raw = try? await val?.loadTransferable(type: Data.self), let img = UIImage(data: raw), let jpg = img.jpegData(compressionQuality: 0.7) { draftPhoto = jpg }
                    }
                }
                .fullScreenCover(isPresented: $showCamera) { CameraPickerView { draftPhoto = $0 }.ignoresSafeArea() }
                .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: false, onCompletion: handleFile)
                .sheet(isPresented: $showModelSelector) {
                    ModelPickerSheet(selectedModel: $modelName, models: $availableModels, isLoading: $isFetchingModels, onRefresh: loadModels)
                }
                .sheet(isPresented: $showPrefs) {
                    PreferencesSheet(apiKey: $apiKey, baseURL: $baseURL, modelName: $modelName, systemPrompt: $systemPrompt, onSave: loadModels)
                }
            }
            .navigationViewStyle(.stack)
            
            if showDrawer {
                Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { withAnimation { showDrawer = false } }
                HStack(spacing: 0) {
                    VStack(alignment: .leading) {
                        Button(action: { createNewThread(); withAnimation { showDrawer = false } }) {
                            Label("Новый диалог", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.blue.opacity(0.15)).cornerRadius(12)
                        }.padding()
                        List {
                            ForEach(threads) { item in
                                HStack {
                                    Text(item.name).lineLimit(1)
                                    Spacer()
                                    Button(action: { removeThread(id: item.id) }) { Image(systemName: "trash").foregroundColor(.red) }.buttonStyle(.plain)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { selectedThreadId = item.id; withAnimation { showDrawer = false } }
                            }
                        }.listStyle(.plain)
                    }.frame(width: 270).background(Color(.systemBackground))
                    Spacer()
                }.transition(.move(edge: .leading))
            }
        }
        .onAppear {
            if let list = try? JSONDecoder().decode([DialogueThread].self, from: threadsStorage), !list.isEmpty {
                threads = list; selectedThreadId = threads.first?.id
            } else { createNewThread() }
            if let mods = try? JSONDecoder().decode([String].self, from: cachedModelsData) { availableModels = mods }
            if !apiKey.isEmpty { loadModels() }
        }
    }
    
    private var readyToSend: Bool { (!draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draftPhoto != nil || draftFileContent != nil) && !isGenerating }
    
    private func persist() { if let d = try? JSONEncoder().encode(threads) { threadsStorage = d } }
    private func createNewThread() { let t = DialogueThread(name: "Новый чат", items: []); threads.insert(t, at: 0); selectedThreadId = t.id; persist() }
    private func removeThread(id: UUID) { threads.removeAll { $0.id == id }; if threads.isEmpty { createNewThread() } else if selectedThreadId == id { selectedThreadId = threads.first?.id }; persist() }
    
    private func loadModels() {
        guard !apiKey.isEmpty else { return }
        isFetchingModels = true
        Task {
            var clean = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if clean.hasSuffix("/chat/completions") { clean = String(clean.dropLast("/chat/completions".count)) }
            guard let url = URL(string: "\(clean)/models") else { isFetchingModels = false; return }
            var req = URLRequest(url: url); req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            if let (data, _) = try? await URLSession.shared.data(for: req),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = (root["data"] as? [[String: Any]]) ?? (root["models"] as? [[String: Any]]) {
                let ids = arr.compactMap { ($0["id"] as? String) ?? ($0["name"] as? String) }.sorted()
                await MainActor.run {
                    if !ids.isEmpty { availableModels = Array(Set(ids)).sorted(); if let enc = try? JSONEncoder().encode(availableModels) { cachedModelsData = enc } }
                    isFetchingModels = false
                }
            } else { await MainActor.run { isFetchingModels = false } }
        }
    }
    
    private func handleFile(result: Result<[URL], Error>) {
        if case .success(let urls) = result, let url = urls.first {
            let acc = url.startAccessingSecurityScopedResource()
            defer { if acc { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                if let img = UIImage(data: data), let jpg = img.jpegData(compressionQuality: 0.7) { draftPhoto = jpg; return }
                if let txt = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) {
                    draftFileName = url.lastPathComponent; draftFileContent = String(txt.prefix(15000))
                } else { alertBanner = "Формат файла не текстовый" }
            }
        }
    }
    
    private func submitQuery() {
        keyboardActive = false; if speech.isListening { speech.stopDictation() }
        guard !apiKey.isEmpty else { alertBanner = "Укажите API ключ в настройках"; showPrefs = true; return }
        if activeIndex == nil { createNewThread() }
        guard let idx = activeIndex else { return }
        
        alertBanner = nil
        var fullText = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fName = draftFileName, let fTxt = draftFileContent { fullText += "\n\n[Файл: \(fName)]\n\(fTxt)" }
        
        threads[idx].items.append(ChatEntry(role: "user", content: fullText, photoData: draftPhoto, attachedFileName: draftFileName))
        if threads[idx].name == "Новый чат" { threads[idx].name = String((draftText.isEmpty ? (draftFileName ?? "Фото") : draftText).prefix(28)) }
        persist()
        
        draftText = ""; draftPhoto = nil; draftFileName = nil; draftFileContent = nil; pickerItem = nil; isGenerating = true
        let history = threads[idx].items
        
        Task {
            do {
                let reply = try await requestCompletion(history: history)
                await MainActor.run {
                    if let c = activeIndex { threads[c].items.append(ChatEntry(role: "assistant", content: reply)); persist() }
                    isGenerating = false
                }
            } catch { await MainActor.run { alertBanner = error.localizedDescription; isGenerating = false } }
        }
    }
    
    private func requestCompletion(history: [ChatEntry]) async throws -> String {
        let clean = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = clean.hasSuffix("/chat/completions") ? clean : "\(clean)/chat/completions"
        guard let url = URL(string: path) else { throw URLError(.badURL) }
        
        var msgs: [[String: Any]] = [["role": "system", "content": systemPrompt + "\nНе используй LaTeX (\\frac, \\left)."]]
        for item in history {
            if let pic = item.photoData {
                let b64 = pic.base64EncodedString()
                let txt = item.content.isEmpty ? "Опиши фото" : item.content
                msgs.append(["role": item.role, "content": [["type": "text", "text": txt], ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]]]])
            } else { msgs.append(["role": item.role, "content": item.content]) }
        }
        
        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": modelName, "messages": msgs])
        
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "API", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Ошибка \(http.statusCode)"])
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { throw URLError(.cannotParseResponse) }
        return content.replacingOccurrences(of: "\\(", with: "").replacingOccurrences(of: "\\)", with: "").replacingOccurrences(of: "\\left", with: "").replacingOccurrences(of: "\\right", with: "")
    }
}

struct ModelPickerSheet: View {
    @Binding var selectedModel: String
    @Binding var models: [String]
    @Binding var isLoading: Bool
    let onRefresh: () -> Void
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    
    var filtered: [String] { search.isEmpty ? models : models.filter { $0.localizedCaseInsensitiveContains(search) } }
    
    var body: some View {
        NavigationView {
            List {
                Section("Своя модель") { TextField("Название модели...", text: $selectedModel).autocapitalization(.none) }
                Section(header: HStack { Text("Доступные (\(filtered.count))"); Spacer(); if isLoading { ProgressView() } else { Button("Обновить", action: onRefresh) } }) {
                    ForEach(filtered, id: \.self) { m in
                        Button(action: { selectedModel = m; dismiss() }) {
                            HStack { Text(m).foregroundColor(.primary); Spacer(); if m == selectedModel { Image(systemName: "checkmark").foregroundColor(.blue) } }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Поиск модели")
            .navigationTitle("Модели").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Готово") { dismiss() } }
        }
    }
}

struct ChatBubbleView: View {
    let entry: ChatEntry
    let onReadAloud: () -> Void
    private var isUser: Bool { entry.role == "user" }
    
    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if let d = entry.photoData, let img = UIImage(data: d) {
                    Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: 220, maxHeight: 220).cornerRadius(14)
                }
                if !entry.content.isEmpty {
                    Text((try? AttributedString(markdown: entry.content, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(entry.content))
                        .foregroundColor(isUser ? .white : .primary)
                        .padding(12)
                        .background(isUser ? Color.blue : Color(.secondarySystemBackground))
                        .cornerRadius(16)
                }
                if !isUser && !entry.content.isEmpty {
                    HStack(spacing: 14) {
                        Button(action: onReadAloud) { Label("Озвучить", systemImage: "speaker.wave.2").font(.caption) }
                        Button(action: { UIPasteboard.general.string = entry.content }) { Label("Копировать", systemImage: "doc.on.doc").font(.caption) }
                    }.foregroundColor(.secondary)
                }
            }
            if !isUser { Spacer(minLength: 20) }
        }.padding(.horizontal, 14)
    }
}

struct PreferencesSheet: View {
    @Binding var apiKey: String
    @Binding var baseURL: String
    @Binding var modelName: String
    @Binding var systemPrompt: String
    let onSave: () -> Void
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section("API") {
                    SecureField("API Ключ", text: $apiKey)
                    TextField("Base URL", text: $baseURL).autocapitalization(.none)
                    TextField("Модель", text: $modelName).autocapitalization(.none)
                }
                Section("Системный промпт") { TextEditor(text: $systemPrompt).frame(minHeight: 100) }
            }
            .navigationTitle("Настройки").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Готово") { onSave(); dismiss() } }
        }
    }
}
