import SwiftUI
import PhotosUI

// MARK: - Модели данных
struct ChatMessageModel: Identifiable, Codable {
    var id = UUID()
    let sender: String // "user" или "assistant"
    var text: String
    var imageData: Data? = nil
    var timestamp = Date()
}

struct ChatConversation: Identifiable, Codable {
    var id = UUID()
    var title: String
    var messages: [ChatMessageModel]
    var updatedTime = Date()
}

// MARK: - Главный экран чата
ContentView: View {
    @AppStorage("userApiKey") private var userApiKey: String = ""
    @AppStorage("apiEndpoint") private var apiEndpoint: String = "https://api.openai.com/v1"
    @AppStorage("activeModel") private var activeModel: String = "gpt-4o-mini"
    @AppStorage("systemPromptText") private var systemPromptText: String = "Ты полезный и вежливый ИИ-ассистент."
    @AppStorage("storedChatsData") private var storedChatsData: Data = Data()
    
    @State private var conversations: [ChatConversation] = []
    @State private var activeChatId: UUID? = nil
    @State private var userInputText: String = ""
    @State private var photoPickerItem: PhotosPickerItem? = nil
    @State private var currentImageData: Data? = nil
    @State private var isWaitingForResponse: Bool = false
    @State private var isSettingsPresented: Bool = false
    @State private var statusMessage: String? = nil
    
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Список сообщений
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            if let activeIndex = currentChatIndex, !conversations[activeIndex].messages.isEmpty {
                                ForEach(conversations[activeIndex].messages) { message in
                                    MessageRowView(message: message)
                                        .id(message.id)
                                }
                            } else {
                                // Приветственный пустой экран
                                VStack(spacing: 14) {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 48))
                                        .foregroundColor(.blue)
                                    Text("Новый диалог")
                                        .font(.title2.bold())
                                    Text("Задайте вопрос, отправьте фото или настройте системный промпт.")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 24)
                                }
                                .padding(.top, 80)
                            }
                            
                            if isWaitingForResponse {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("ИИ думает...")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .id("loadingIndicator")
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture {
                        isTextFieldFocused = false
                    }
                    .onChange(of: conversations.first(where: { $0.id == activeChatId })?.messages.count) { _ in
                        if let idx = currentChatIndex, let lastId = conversations[idx].messages.last?.id {
                            withAnimation {
                                scrollProxy.scrollTo(lastId, anchor: .bottom)
                            }
                        }
                    }
                }
                
                // Ошибки или уведомления
                if let errorText = statusMessage {
                    Text(errorText)
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.85))
                        .onTapGesture { statusMessage = nil }
                }
                
                // Превью выбранной картинки
                if let imgData = currentImageData, let uiImage = UIImage(data: imgData) {
                    HStack {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(
                                Button(action: { currentImageData = nil; photoPickerItem = nil }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.white)
                                        .background(Circle().fill(Color.black.opacity(0.6)))
                                }
                                .offset(x: 6, y: -6),
                                alignment: .topTrailing
                            )
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
                
                Divider()
                
                // Панель ввода сообщения
                HStack(alignment: .bottom, spacing: 10) {
                    PhotosPicker(selection: $photoPickerItem, matching: .images) {
                        Image(systemName: "photo.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.blue)
                    }
                    .onChange(of: photoPickerItem) { newItem in
                        Task {
                            if let data = try? await newItem?.loadTransferable(type: Data.self),
                               let img = UIImage(data: data),
                               let compressed = img.jpegData(compressionQuality: 0.7) {
                                currentImageData = compressed
                            }
                        }
                    }
                    
                    TextField("Сообщение...", text: $userInputText, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($isTextFieldFocused)
                        .padding(10)
                        .background(Color(.systemGray6))
                        .cornerRadius(18)
                    
                    Button(action: handleSendMessage) {
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
            .navigationTitle(activeModel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: startNewChat) {
                        Image(systemName: "square.and.pencil")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { isSettingsPresented = true }) {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .sheet(isPresented: $isSettingsPresented) {
                SettingsModalView(
                    apiKey: $userApiKey,
                    endpoint: $apiEndpoint,
                    model: $activeModel,
                    prompt: $systemPromptText
                )
            }
        }
        .onAppear(perform: loadStoredChats)
    }
    
    private var currentChatIndex: Int? {
        conversations.firstIndex(where: { $0.id == activeChatId })
    }
    
    private var canSend: Bool {
        (!userInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || currentImageData != nil) && !isWaitingForResponse
    }
    
    private func loadStoredChats() {
        if let decoded = try? JSONDecoder().decode([ChatConversation].self, from: storedChatsData), !decoded.isEmpty {
            conversations = decoded
            activeChatId = conversations.first?.id
        } else {
            startNewChat()
        }
    }
    
    private func saveStoredChats() {
        if let encoded = try? JSONEncoder().encode(conversations) {
            storedChatsData = encoded
        }
    }
    
    private func startNewChat() {
        let newConv = ChatConversation(title: "Новый чат", messages: [])
        conversations.insert(newConv, at: 0)
        activeChatId = newConv.id
        saveStoredChats()
    }
    
    private func handleSendMessage() {
        isTextFieldFocused = false
        guard !userApiKey.isEmpty else {
            statusMessage = "Укажите API ключ в настройках!"
            isSettingsPresented = true
            return
        }
        
        if currentChatIndex == nil {
            startNewChat()
        }
        guard let index = currentChatIndex else { return }
        
        statusMessage = nil
        let textContent = userInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imagePayload = currentImageData
        
        let userMessage = ChatMessageModel(sender: "user", text: textContent, imageData: imagePayload)
        conversations[index].messages.append(userMessage)
        
        if conversations[index].title == "Новый чат" && !textContent.isEmpty {
            conversations[index].title = String(textContent.prefix(30))
        }
        conversations[index].updatedTime = Date()
        saveStoredChats()
        
        userInputText = ""
        currentImageData = nil
        photoPickerItem = nil
        isWaitingForResponse = true
        
        let historySnapshot = conversations[index].messages
        
        Task {
            do {
                let responseText = try await sendRequestToAPI(messages: historySnapshot)
                await MainActor.run {
                    if let curIdx = currentChatIndex {
                        conversations[curIdx].messages.append(ChatMessageModel(sender: "assistant", text: responseText))
                        saveStoredChats()
                    }
                    isWaitingForResponse = false
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Ошибка: \(error.localizedDescription)"
                    isWaitingForResponse = false
                }
            }
        }
    }
    
    private func sendRequestToAPI(messages: [ChatMessageModel]) async throws -> String {
        let cleanBase = apiEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let endpointURL = cleanBase.hasSuffix("/chat/completions") ? cleanBase : "\(cleanBase)/chat/completions"
        
        guard let url = URL(string: endpointURL) else {
            throw URLError(.badURL)
        }
        
        var payloadMessages: [[String: Any]] = []
        if !systemPromptText.isEmpty {
            payloadMessages.append(["role": "system", "content": systemPromptText])
        }
        
        for msg in messages {
            if let imgData = msg.imageData {
                let base64String = imgData.base64EncodedString()
                var contentList: [[String: Any]] = []
                if !msg.text.isEmpty {
                    contentList.append(["type": "text", "text": msg.text])
                }
                contentList.append([
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(base64String)"]
                ])
                payloadMessages.append(["role": msg.sender, "content": contentList])
            } else {
                payloadMessages.append(["role": msg.sender, "content": msg.text])
            }
        }
        
        let requestBody: [String: Any] = [
            "model": activeModel,
            "messages": payloadMessages
        ]
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(userApiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let errorMessage = String(data: data, encoding: .utf8) ?? "Код ошибки: \(httpResponse.statusCode)"
            throw NSError(domain: "APIError", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMessage])
        }
        
        guard let jsonResult = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = jsonResult["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let messageObj = firstChoice["message"] as? [String: Any],
              let content = messageObj["content"] as? String else {
            throw NSError(domain: "ParseError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать ответ от сервера"])
        }
        
        return content
    }
}

// MARK: - Компонент отображения сообщения
struct MessageRowView: View {
    let message: ChatMessageModel
    private var isUser: Bool { message.sender == "user" }
    
    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            
            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if let imgData = message.imageData, let image = UIImage(data: imgData) {
                    Image(uiImage: image)
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
            
            if !isUser { Spacer(minLength: 40) }
        }
        .padding(.horizontal, 12)
    }
}

// MARK: - Модальное окно настроек
struct SettingsModalView: View {
    @Binding var apiKey: String
    @Binding var endpoint: String
    @Binding var model: String
    @Binding var prompt: String
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Параметры подключения")) {
                    SecureField("API Ключ", text: $apiKey)
                    TextField("Base URL", text: $endpoint)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                    TextField("Модель", text: $model)
                        .autocapitalization(.none)
                }
                
                Section(header: Text("Системный промпт")) {
                    TextEditor(text: $prompt)
                        .frame(minHeight: 100)
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
