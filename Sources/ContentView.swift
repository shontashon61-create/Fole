import SwiftUI
import PhotosUI

// MARK: - Модели данных
struct ChatMessage: Identifiable {
    let id = UUID()
    let role: String // "user" или "assistant"
    var text: String
    var imageData: Data? = nil
}

// MARK: - Главный экран чата
struct ContentView: View {
    @AppStorage("apiKey") private var apiKey: String = ""
    @AppStorage("baseURL") private var baseURL: String = "https://api.openai.com/v1"
    @AppStorage("modelName") private var modelName: String = "gpt-4o-mini"
    @AppStorage("systemPrompt") private var systemPrompt: String = "Ты полезный ИИ-ассистент."
    
    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var selectedImageData: Data? = nil
    @State private var isLoading: Bool = false
    @State private var showSettings: Bool = false
    @State private var errorMessage: String? = nil

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Список сообщений
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            if messages.isEmpty {
                                Text("Начните диалог с ИИ.\nНе забудьте указать API ключ в настройках ⚙️")
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 60)
                            }
                            
                            ForEach(messages) { msg in
                                MessageBubble(message: msg)
                                    .id(msg.id)
                            }
                            
                            if isLoading {
                                HStack {
                                    ProgressView()
                                        .padding(10)
                                        .background(Color(.systemGray6))
                                        .cornerRadius(12)
                                    Spacer()
                                }
                                .padding(.horizontal)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onChange(of: messages.count) { _ in
                        if let lastId = messages.last?.id {
                            withAnimation {
                                proxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
                
                // Отображение ошибок
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.85))
                        .onTapGesture { errorMessage = nil }
                }
                
                // Предпросмотр выбранного фото
                if let data = selectedImageData, let uiImage = UIImage(data: data) {
                    HStack {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                Button(action: { selectedImageData = nil; selectedItem = nil }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black.opacity(0.6)))
                                }
                                .offset(x: 6, y: -6),
                                alignment: .topTrailing
                            )
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .background(Color(.systemBackground))
                }
                
                Divider()
                
                // Панель ввода
                HStack(alignment: .bottom, spacing: 10) {
                    PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 22))
                            .foregroundColor(.blue)
                            .frame(width: 36, height: 36)
                    }
                    .onChange(of: selectedItem) { newItem in
                        Task {
                            if let data = try? await newItem?.loadTransferable(type: Data.self),
                               let uiImage = UIImage(data: data),
                               let compressed = uiImage.jpegData(compressionQuality: 0.7) {
                                selectedImageData = compressed
                            }
                        }
                    }
                    
                    TextField("Сообщение...", text: $inputText, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(10)
                        .background(Color(.systemGray6))
                        .cornerRadius(18)
                    
                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(canSend ? .blue : .gray)
                    }
                    .disabled(!canSend)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemBackground))
            }
            .navigationTitle(modelName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { messages.removeAll() }) {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showSettings = true }) {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(
                    apiKey: $apiKey,
                    baseURL: $baseURL,
                    modelName: $modelName,
                    systemPrompt: $systemPrompt
                )
            }
        }
    }
    
    private var canSend: Bool {
        (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedImageData != nil) && !isLoading
    }
    
    // MARK: - Логика отправки запроса к API
    private func sendMessage() {
        guard !apiKey.isEmpty else {
            errorMessage = "Укажите API ключ в настройках!"
            showSettings = true
            return
        }
        
        errorMessage = nil
        let userText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachedImage = selectedImageData
        
        let newUserMsg = ChatMessage(role: "user", text: userText, imageData: attachedImage)
        messages.append(newUserMsg)
        
        inputText = ""
        selectedImageData = nil
        selectedItem = nil
        isLoading = true
        
        Task {
            do {
                let reply = try await fetchAIResponse()
                await MainActor.run {
                    messages.append(ChatMessage(role: "assistant", text: reply))
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Ошибка: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }
    
    private func fetchAIResponse() async throws -> String {
        let cleanBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpoint = cleanBase.hasSuffix("/chat/completions") ? cleanBase : "\(cleanBase)/chat/completions"
        
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }
        
        var apiMessages: [[String: Any]] = []
        
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiMessages.append([
                "role": "system",
                "content": systemPrompt
            ])
        }
        
        for msg in messages {
            if let imgData = msg.imageData {
                let base64 = imgData.base64EncodedString()
                var contentArray: [[String: Any]] = []
                if !msg.text.isEmpty {
                    contentArray.append(["type": "text", "text": msg.text])
                }
                contentArray.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(base64)"]
                ])
                apiMessages.append([
                    "role": msg.role,
                    "content": contentArray
                ])
            } else {
                apiMessages.append([
                    "role": msg.role,
                    "content": msg.text
                ])
            }
        }
        
        let body: [String: Any] = [
            "model": modelName,
            "messages": apiMessages
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResp = response as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
            let errText = String(data: data, encoding: .utf8) ?? "Код ошибки \(httpResp.statusCode)"
            throw NSError(domain: "APIError", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: errText])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw NSError(domain: "ParseError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать ответ от сервера"])
        }
        
        return content
    }
}

// MARK: - Ячейка сообщения
struct MessageBubble: View {
    let message: ChatMessage
    var isUser: Bool { message.role == "user" }
    
    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 50) }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if let imgData = message.imageData, let uiImg = UIImage(data: imgData) {
                    Image(uiImage: uiImg)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 220, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.body)
                        .foregroundColor(isUser ? .white : .primary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(isUser ? Color.blue : Color(.systemGray5))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .textSelection(.enabled)
                }
            }
            
            if !isUser { Spacer(minLength: 50) }
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Экран настроек
struct SettingsView: View {
    @Binding var apiKey: String
    @Binding var baseURL: String
    @Binding var modelName: String
    @Binding var systemPrompt: String
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Подключение API")) {
                    SecureField("API Ключ (sk-...)", text: $apiKey)
                    TextField("Base URL", text: $baseURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    TextField("Модель (напр. gpt-4o-mini)", text: $modelName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                
                Section(header: Text("Системный промпт (System Prompt)"), footer: Text("Задает характер, правила и поведение ИИ в диалоге.")) {
                    TextEditor(text: $systemPrompt)
                        .frame(minHeight: 120)
                }
                
                Section(header: Text("Шпаргалка по Base URL")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("• OpenAI: https://api.openai.com/v1")
                        Text("• OpenRouter: https://openrouter.ai/api/v1")
                        Text("• DeepSeek: https://api.deepseek.com/v1")
                        Text("• Groq: https://api.groq.com/openai/v1")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                        .bold()
                }
            }
        }
    }
}
