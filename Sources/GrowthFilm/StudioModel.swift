import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AlignmentCore

@MainActor
final class StudioModel: ObservableObject {
    @Published var photos: [Photo] = []
    @Published var selected: UUID?
    @Published var settings = FilmSettings()
    @Published var busy = false
    @Published var status = "写真を追加して、成長の記録を始めましょう。"
    @Published var progress: Double = 0
    @Published var errorMessage: String?
    @Published var googleConfigured = false
    @Published var playing = false
    @Published var manual = false
    @Published var firstEye: Point?
    @Published var original: NSImage?
    @Published var aligned: NSImage?
    @Published var dirty = false
    @Published private var extractionSnapshot: ExtractionSnapshot?
    private struct ExtractionSnapshot {
        let order: [UUID]
        let included: [UUID: Bool]
    }
    var canUndoExtraction: Bool { extractionSnapshot != nil }
    private(set) var directory: URL
    private let google = GooglePhotos()
    private var operation: Task<Void, Never>?
    private var previewWork: Task<Void, Never>?
    private var playback: Task<Void, Never>?
    private var previewCache: [UUID: NSImage] = [:]
    private var previousPreview: NSImage?
    @Published var fadeFrom: NSImage?
    @Published var fadeOpacity = 1.0
    var current: Photo? { photos.first { $0.id == selected } }
    var ready: [Photo] { photos.filter { $0.included && $0.eyes != nil } }
    var unresolved: Int { photos.filter { $0.included && $0.eyes == nil }.count }

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GrowthFilm-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { errorMessage = "作業フォルダを作れません: \(error.localizedDescription)" }
        googleConfigured = CredentialStore.read() != nil
    }
    func shutdown() {
        operation?.cancel(); previewWork?.cancel(); playback?.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
    func fail(_ error: Error) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            status = "中止しました。"
        } else { errorMessage = error.localizedDescription; status = "処理を完了できませんでした。" }
    }
    func start(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        stopPlayback(); busy = true; progress = 0
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await action() } catch { fail(error) }
        }
    }
    func cancel() { operation?.cancel() }
    func addLocal() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "成長動画に使用する写真をまとめて選んでください。"
        guard panel.runModal() == .OK else { return }
        let sources = panel.urls.map { ImportSource(url: $0) }
        start { try await self.importSources(sources) }
    }
    private func importSources(_ sources: [ImportSource]) async throws {
        let folder = directory
        status = "目の位置を検出しています…"
        let worker = Task.detached(priority: .userInitiated) {
            try PhotoEngine.importPhotos(sources, to: folder) { done, total in
                Task { @MainActor in
                    self.progress = Double(done) / Double(max(1, total))
                    self.status = "目の位置を検出中 \(done) / \(total)"
                }
            }
        }
        let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        photos += result.photos
        sortByDate()
        if selected == nil { selected = photos.first?.id }
        dirty = true; invalidatePreview()
        status = "\(result.photos.count)枚を追加しました。要確認 \(unresolved)枚。"
        if !result.failures.isEmpty { errorMessage = "次の写真を取り込めませんでした。\n" + result.failures.prefix(10).joined(separator: "\n") }
    }
    func addGoogle() {
        guard googleConfigured else { errorMessage = "「Google設定」から、デスクトップアプリ用のOAuth JSONを読み込んでください。"; return }
        start {
            let downloads = self.directory.appendingPathComponent("download-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: downloads) }
            let sources = try await self.google.pick(to: downloads) { self.status = $0 }
            try await self.importSources(sources)
        }
    }
    func configureGoogle() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        panel.message = "Google Cloudの「デスクトップアプリ」用OAuth JSONを選択"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let config = try OAuthConfiguration.loadJSON(Data(contentsOf: url))
            try CredentialStore.save(config)
            google.disconnect(); googleConfigured = true
            status = "Google設定を保存しました。「Googleフォト」から写真を選べます。"
        } catch { fail(error) }
    }
    func clearGoogle() {
        google.disconnect(); CredentialStore.delete(); googleConfigured = false
        status = "このMacのGoogle認証設定を削除しました。"
    }
    func sortByDate() {
        photos = photos.enumerated().sorted { a, b in
            let da = a.element.date ?? .distantFuture, db = b.element.date ?? .distantFuture
            return da == db ? a.offset < b.offset : da < db
        }.map(\.element)
        dirty = true
    }
    func extractEvenly() {
        guard !busy, !playing else { return }
        let timestamps: [Double?] = photos.map { photo in
            photo.included ? photo.date?.timeIntervalSinceReferenceDate : nil
        }
        let indices = TemporalSampler.indices(timestamps: timestamps, maximum: 2000)
        guard !indices.isEmpty else {
            errorMessage = "抽出できる写真がありません。「動画に含める」がオンで、撮影日が設定された写真が必要です。"
            return
        }
        extractionSnapshot = ExtractionSnapshot(order: photos.map(\.id),
            included: Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0.included) }))
        let eligible = timestamps.compactMap { $0 }.filter { $0.isFinite }.count
        let unknown = photos.filter { $0.included && ($0.date == nil || !($0.date?.timeIntervalSinceReferenceDate.isFinite ?? false)) }.count
        let ids = Set(indices.map { photos[$0].id })
        let firstID = photos[indices[0]].id
        for index in photos.indices { photos[index].included = ids.contains(photos[index].id) }
        sortByDate()
        selected = firstID
        dirty = true; invalidatePreview()
        status = "期間全体から \(indices.count)枚を抽出（撮影日あり \(eligible)枚／日付不明 \(unknown)枚は対象外）。要確認 \(unresolved)枚。"
    }
    func undoExtraction() {
        guard !busy, !playing, let snapshot = extractionSnapshot else { return }
        let positions = Dictionary(uniqueKeysWithValues: snapshot.order.enumerated().map { ($0.element, $0.offset) })
        for index in photos.indices {
            if let included = snapshot.included[photos[index].id] { photos[index].included = included }
        }
        photos = photos.enumerated().sorted { a, b in
            let pa = positions[a.element.id] ?? snapshot.order.count + a.offset
            let pb = positions[b.element.id] ?? snapshot.order.count + b.offset
            return pa < pb
        }.map(\.element)
        extractionSnapshot = nil
        dirty = true; invalidatePreview()
        status = "抽出前の対象写真と並び順に戻しました。"
    }
    func move(_ delta: Int) {
        guard let index = photos.firstIndex(where: { $0.id == selected }), photos.indices.contains(index + delta) else { return }
        photos.swapAt(index, index + delta); dirty = true
    }
    func removeSelected() {
        guard let index = photos.firstIndex(where: { $0.id == selected }) else { return }
        let old = photos.remove(at: index)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(old.filename))
        selected = photos.isEmpty ? nil : photos[min(index, photos.count - 1)].id
        previewCache.removeValue(forKey: old.id); dirty = true
    }
    func setIncluded(_ value: Bool) {
        guard let index = photos.firstIndex(where: { $0.id == selected }) else { return }
        photos[index].included = value; dirty = true
    }
    func setDate(_ value: Date) {
        guard let index = photos.firstIndex(where: { $0.id == selected }) else { return }
        photos[index].date = value; dirty = true; invalidatePreview()
    }
    func selectFace(_ pair: EyePair) {
        guard let index = photos.firstIndex(where: { $0.id == selected }) else { return }
        photos[index].eyes = pair; manual = false; firstEye = nil; dirty = true; invalidatePreview()
    }
    func clickEye(_ point: Point) {
        guard manual else { return }
        if let firstEye {
            guard hypot(point.x - firstEye.x, point.y - firstEye.y) > 2 else {
                errorMessage = "2つの目を別々の位置に指定してください。"; return
            }
            selectFace(EyePair(firstEye, point))
        } else { firstEye = point }
    }
    func selectionChanged() {
        firstEye = nil; manual = false
        refreshPreview()
    }
    func invalidatePreview() {
        previewCache.removeAll(); stopPlayback(); refreshPreview()
    }
    func refreshPreview() {
        previewWork?.cancel()
        guard let photo = current else { original = nil; aligned = nil; return }
        let folder = directory, config = settings
        let cached = previewCache[photo.id]
        if !playing { original = nil; aligned = nil }
        previewWork = Task {
            let worker = Task.detached(priority: .userInitiated) { () -> (CGImage?, CGImage?) in
                let original = try? PhotoEngine.image(folder.appendingPathComponent(photo.filename))
                let rendered = cached == nil && photo.eyes != nil ? try? PhotoEngine.render(photo, directory: folder,
                    settings: config, width: config.portrait ? 432 : 768, height: config.portrait ? 768 : 432) : nil
                return (original, rendered)
            }
            let result = await worker.value
            guard !Task.isCancelled, selected == photo.id else { return }
            if let image = result.0 { original = NSImage(cgImage: image, size: .zero) }
            let next = cached ?? result.1.map { NSImage(cgImage: $0, size: .zero) }
            if let next {
                if previewCache.count >= 80 { previewCache.removeAll() }
                previewCache[photo.id] = next
            }
            if playing && settings.fade {
                fadeFrom = previousPreview; fadeOpacity = 0
                aligned = next
                withAnimation(.linear(duration: max(1.0 / 30, settings.seconds / 3))) { fadeOpacity = 1 }
            } else { fadeFrom = nil; fadeOpacity = 1; aligned = next }
            previousPreview = next
        }
    }
    func togglePlayback() {
        if playing { stopPlayback(); return }
        let items = ready
        guard !items.isEmpty else { return }
        manual = false; playing = true
        playback = Task {
            var index = items.firstIndex(where: { $0.id == selected }) ?? 0
            while !Task.isCancelled {
                selected = items[index].id
                refreshPreview()
                await previewWork?.value
                do { try await Task.sleep(nanoseconds: UInt64(settings.seconds * 1_000_000_000)) }
                catch { break }
                index = (index + 1) % items.count
            }
        }
    }
    func stopPlayback() {
        playback?.cancel(); playback = nil; playing = false; fadeFrom = nil; fadeOpacity = 1
    }
    func exportMovie() {
        guard unresolved == 0 else { errorMessage = "要確認の写真があります。顔・両目を指定するか、「動画に含める」を外してください。"; return }
        let items = ready
        guard !items.isEmpty else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "成長記録.mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let folder = directory, config = settings
        start {
            self.status = "MP4動画を作成しています…"
            // Write a sibling temporary file, then atomically replace the destination only on success.
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".growthfilm-" + UUID().uuidString + ".mp4")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let worker = Task.detached(priority: .userInitiated) {
                try await MovieExporter.export(photos: items, directory: folder, settings: config, to: temporary) { value in
                    Task { @MainActor in self.progress = value }
                }
            }
            try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
            self.status = "動画を保存しました: \(destination.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }
    func saveProject() {
        guard !photos.isEmpty else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "成長記録.growthfilm"
        panel.message = "写真と位置合わせをまとめて保存します。"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let project = Project(photos: photos, settings: settings), folder = directory
        start {
            self.status = "プロジェクトを保存しています…"
            let worker = Task.detached {
                let fm = FileManager.default
                let stage = destination.deletingLastPathComponent().appendingPathComponent(".growthfilm-stage-" + UUID().uuidString)
                try fm.createDirectory(at: stage, withIntermediateDirectories: true)
                defer { try? fm.removeItem(at: stage) }
                let assets = stage.appendingPathComponent("Photos", isDirectory: true)
                try fm.createDirectory(at: assets, withIntermediateDirectories: true)
                for photo in project.photos {
                    try Task.checkCancellation()
                    try fm.copyItem(at: folder.appendingPathComponent(photo.filename), to: assets.appendingPathComponent(photo.filename))
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(project).write(to: stage.appendingPathComponent("project.json"), options: .atomic)
                try Task.checkCancellation()
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: stage)
                } else { try fm.moveItem(at: stage, to: destination) }
            }
            try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            self.dirty = false; self.status = "プロジェクトを保存しました。"
        }
    }
    func openProject() {
        if dirty {
            let alert = NSAlert(); alert.messageText = "現在の未保存の編集を破棄して開きますか？"
            alert.addButton(withTitle: "開く"); alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = ".growthfilmプロジェクトを選択してください。"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        start {
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent("GrowthFilm-" + UUID().uuidString)
            var committed = false
            defer { if !committed { try? FileManager.default.removeItem(at: stage) } }
            let worker = Task.detached { () -> Project in
                let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: source.appendingPathComponent("project.json")))
                guard project.version == 1, project.photos.count <= 100000,
                      (0.1...5).contains(project.settings.seconds), (0.1...0.5).contains(project.settings.spacing),
                      (0.3...0.8).contains(project.settings.eyeHeight),
                      Set(project.photos.map(\.id)).count == project.photos.count,
                      Set(project.photos.map(\.filename)).count == project.photos.count else { throw AppError("対応していないプロジェクトです。") }
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                for photo in project.photos {
                    try Task.checkCancellation()
                    guard photo.filename == photo.id.uuidString + ".jpg", photo.width > 0, photo.height > 0 else {
                        throw AppError("プロジェクト内の写真情報が不正です。")
                    }
                    for pair in photo.faces + (photo.eyes.map { [$0] } ?? []) {
                        guard [pair.left, pair.right].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 && $0.x <= Double(photo.width) && $0.y <= Double(photo.height) }) else {
                            throw AppError("プロジェクト内の目の座標が不正です。")
                        }
                    }
                    let asset = source.appendingPathComponent("Photos").appendingPathComponent(photo.filename)
                    let resolvedRoot = source.appendingPathComponent("Photos").resolvingSymlinksInPath().path + "/"
                    guard asset.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot) else { throw AppError("写真の参照先が不正です。") }
                    try FileManager.default.copyItem(at: asset.resolvingSymlinksInPath(), to: stage.appendingPathComponent(photo.filename))
                }
                return project
            }
            let project = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
            try Task.checkCancellation()
            let old = self.directory; self.directory = stage; committed = true
            self.extractionSnapshot = nil
            self.photos = project.photos; self.settings = project.settings
            self.selected = project.photos.first?.id; self.dirty = false; self.invalidatePreview()
            try? FileManager.default.removeItem(at: old)
            self.status = "プロジェクトを開きました。"
        }
    }
}
