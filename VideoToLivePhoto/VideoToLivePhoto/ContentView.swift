import SwiftUI
import PhotosUI
import AVKit

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var sourceURL: URL?
    @State private var player: AVPlayer?
    @State private var isProcessing = false
    @State private var statusText = "Выберите видео из галереи"
    @State private var showingAlert = false
    @State private var alertText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    header
                    preview
                    controls
                    status
                }
                .padding(20)
            }
            .navigationTitle("Video → Live")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }
            loadVideo(from: newItem)
        }
        .alert("Video → Live", isPresented: $showingAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertText)
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "livephoto")
                .font(.system(size: 52, weight: .medium))
                .symbolEffect(.pulse, options: .repeating)

            Text("Видео в настоящий Live Photo")
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            Text("Первая версия создаёт 3‑секундный Live Photo из центральной части ролика и сохраняет его в «Фото».")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 10)
    }

    @ViewBuilder
    private var preview: some View {
        if let player {
            VideoPlayer(player: player)
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.quaternary, lineWidth: 1)
                }
        } else {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.quaternary.opacity(0.45))
                .frame(height: 300)
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("Видео пока не выбрано")
                            .foregroundStyle(.secondary)
                    }
                }
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            PhotosPicker(selection: $selectedItem, matching: .videos) {
                Label(sourceURL == nil ? "Выбрать видео" : "Выбрать другое видео", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isProcessing)

            Button {
                createLivePhoto()
            } label: {
                HStack(spacing: 10) {
                    if isProcessing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "livephoto")
                    }
                    Text(isProcessing ? "Создание…" : "Создать Live Photo")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(sourceURL == nil || isProcessing)
        }
    }

    private var status: some View {
        Text(statusText)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private func loadVideo(from item: PhotosPickerItem) {
        isProcessing = true
        statusText = "Загрузка видео…"

        Task {
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else {
                    throw LivePhotoError.couldNotLoadVideo
                }

                await MainActor.run {
                    sourceURL = movie.url
                    player = AVPlayer(url: movie.url)
                    statusText = "Готово. Будет использован центральный 3‑секундный фрагмент."
                    isProcessing = false
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    statusText = "Не удалось загрузить видео"
                    alertText = error.localizedDescription
                    showingAlert = true
                }
            }
        }
    }

    private func createLivePhoto() {
        guard let sourceURL else { return }

        isProcessing = true
        player?.pause()
        statusText = "Подготавливаю Live Photo…"

        Task {
            do {
                let resources = try await LivePhotoMaker.make(from: sourceURL, targetDuration: 3.0)
                await MainActor.run { statusText = "Сохраняю в «Фото»…" }
                try await LivePhotoMaker.saveToPhotoLibrary(resources)

                await MainActor.run {
                    isProcessing = false
                    statusText = "Готово — Live Photo сохранено в «Фото» ✅"
                    alertText = "Live Photo успешно создан и сохранён в медиатеку."
                    showingAlert = true
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    statusText = "Ошибка при создании Live Photo"
                    alertText = error.localizedDescription
                    showingAlert = true
                }
            }
        }
    }
}
