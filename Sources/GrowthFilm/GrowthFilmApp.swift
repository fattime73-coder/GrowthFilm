import SwiftUI
import AppKit
import AlignmentCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: StudioModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model?.busy == true {
            let alert = NSAlert(); alert.messageText = "処理中です。画面の「中止」を押してから終了してください。"
            alert.runModal(); return .terminateCancel
        }
        if model?.dirty == true {
            let alert = NSAlert(); alert.messageText = "編集内容が保存されていません。"
            alert.informativeText = "再開するには先に「プロジェクト保存」を選んでください。"
            alert.addButton(withTitle: "戻る"); alert.addButton(withTitle: "保存せず終了")
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        model?.shutdown()
        return .terminateNow
    }
}

@main
@MainActor
struct GrowthFilmApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = StudioModel()
    var body: some Scene {
        WindowGroup("GrowthFilm — 成長の記録") {
            StudioView(model: model).onAppear { delegate.model = model }
                .frame(minWidth: 1050, minHeight: 720)
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("写真を追加…", action: model.addLocal).keyboardShortcut("o").disabled(model.busy)
                Button("プロジェクトを開く…", action: model.openProject).keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.busy)
                Button("プロジェクトを保存…", action: model.saveProject).keyboardShortcut("s").disabled(model.busy || model.photos.isEmpty)
            }
        }
    }
}

@MainActor
struct StudioView: View {
    @ObservedObject var model: StudioModel
    @State private var showGoogle = false
    private let accent = Color(red: 0.32, green: 0.84, blue: 0.75)
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar.frame(width: 255)
                Divider()
                workspace.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .preferredColorScheme(.dark)
        .onChange(of: model.selected) { _ in if !model.playing { model.selectionChanged() } }
        .alert("確認してください", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented: $showGoogle) { googleSheet }
    }
    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "camera.aperture").font(.system(size: 30)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("GrowthFilm").font(.system(size: 23, weight: .semibold, design: .rounded))
                Text("同じまなざしで、時をつなぐ。").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: model.addLocal) { Label("写真を追加", systemImage: "plus") }
            Button(action: model.addGoogle) { Label("Googleフォト", systemImage: "photo.on.rectangle") }
            Menu {
                Button("プロジェクトを保存…", action: model.saveProject).disabled(model.photos.isEmpty)
                Button("プロジェクトを開く…", action: model.openProject)
                Divider()
                Button("Google設定…") { showGoogle = true }
            } label: { Image(systemName: "ellipsis.circle").font(.title3) }
            .menuStyle(.borderlessButton).frame(width: 28)
            Button(action: model.exportMovie) { Label("MP4を書き出す", systemImage: "square.and.arrow.up") }
                .buttonStyle(.borderedProminent).foregroundStyle(.black).disabled(model.ready.isEmpty)
        }
        .buttonStyle(.bordered)
        .padding(18)
        .disabled(model.busy)
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("写真のタイムライン").font(.headline)
                Spacer()
                Text("\(model.photos.count)").foregroundStyle(.secondary)
            }.padding(.horizontal, 14).padding(.top, 18)
            HStack {
                Button("撮影日順", action: model.sortByDate)
                Spacer()
                Button { model.move(-1) } label: { Image(systemName: "arrow.up") }
                Button { model.move(1) } label: { Image(systemName: "arrow.down") }
                Button(action: model.removeSelected) { Image(systemName: "trash") }
            }.buttonStyle(.borderless).padding(.horizontal, 14).disabled(model.busy || model.playing)
            VStack(alignment: .leading, spacing: 6) {
                Button(action: model.extractEvenly) {
                    Label("期間全体から最大2,000枚を抽出", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                }.disabled(model.photos.isEmpty)
                Text("動画対象の写真から撮影日で抽出。日付不明は対象外。写真は削除しません。")
                    .font(.caption2).foregroundStyle(.secondary)
                if model.canUndoExtraction {
                    Button("抽出前に戻す", action: model.undoExtraction).font(.caption)
                }
            }.padding(.horizontal, 14).disabled(model.busy || model.playing)
            if model.photos.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "photo.stack").font(.largeTitle)
                    Text("まずは写真を追加").font(.headline)
                    Text("Mac内の写真、またはGoogleフォトから選べます。JPEG / HEIC / PNG / TIFFに対応。")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(20)
                Spacer()
            } else {
                List(selection: $model.selected) {
                    ForEach(Array(model.photos.enumerated()), id: \.element.id) { index, photo in
                        HStack(spacing: 9) {
                            Text(String(format: "%02d", index + 1)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(photo.title).lineLimit(1)
                                HStack(spacing: 4) {
                                    Image(systemName: photo.eyes == nil ? "exclamationmark.circle" : "checkmark.circle")
                                        .foregroundStyle(photo.eyes == nil ? Color.orange : accent)
                                    Text(photo.date.map { $0.formatted(date: .numeric, time: .omitted) } ?? "撮影日なし")
                                        .foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                            Spacer(minLength: 0)
                            if !photo.included { Image(systemName: "eye.slash").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 7).tag(photo.id)
                    }
                }.listStyle(.sidebar).disabled(model.busy || model.playing)
            }
            Text("要確認 \(model.unresolved)枚 / 動画対象 \(model.ready.count)枚")
                .font(.caption).foregroundStyle(model.unresolved > 0 ? Color.orange : Color.secondary)
                .padding(14)
        }
    }
    private var workspace: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("目の位置をそろえる").font(.title2.weight(.semibold))
                Spacer()
                Button(action: model.togglePlayback) {
                    Label(model.playing ? "停止" : "連続プレビュー", systemImage: model.playing ? "pause.fill" : "play.fill")
                }.disabled(model.busy || model.ready.isEmpty)
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("元の写真 · 目の位置").font(.caption).foregroundStyle(.secondary)
                    OriginalCanvas(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text(model.manual ? (model.firstEye == nil ? "① 画面左側の目をクリック" : "② もう片方の目をクリック") : "緑の印が目の中心です。必要に応じて修正できます。")
                        .font(.caption).foregroundStyle(model.manual ? accent : Color.secondary)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("動画の仕上がり").font(.caption).foregroundStyle(.secondary)
                    ZStack {
                        Color.black.opacity(0.35)
                        if let image = model.fadeFrom {
                            Image(nsImage: image).resizable().scaledToFit()
                        }
                        if let image = model.aligned {
                            Image(nsImage: image).resizable().scaledToFit().opacity(model.fadeOpacity)
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "viewfinder").font(.system(size: 42, weight: .ultraLight))
                                Text(model.current == nil ? "写真を選ぶと、ここに表示されます" : "両目の位置を指定してください")
                                    .font(.callout)
                            }.foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).clipShape(RoundedRectangle(cornerRadius: 12))
                    Text("両目の位置を固定 · 顔の形は変えません")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxHeight: .infinity)
            if let photo = model.current {
                HStack(spacing: 12) {
                    Button(model.manual ? "目の指定を中止" : "両目を手動で指定") {
                        model.manual.toggle(); model.firstEye = nil
                    }
                    if !photo.faces.isEmpty {
                        Menu("検出した顔を選ぶ（\(photo.faces.count)人）") {
                            ForEach(Array(photo.faces.enumerated()), id: \.offset) { index, pair in
                                Button("顔 \(index + 1)") { model.selectFace(pair) }
                            }
                        }.fixedSize()
                    }
                    Spacer()
                    Toggle("動画に含める", isOn: Binding(get: { model.current?.included ?? false }, set: model.setIncluded))
                        .toggleStyle(.checkbox)
                }.disabled(model.busy || model.playing)
                HStack {
                    Text("撮影日").foregroundStyle(.secondary)
                    DatePicker("撮影日", selection: Binding(get: { model.current?.date ?? Date() }, set: model.setDate), displayedComponents: .date)
                        .labelsHidden()
                    if photo.date == nil { Button("今日の日付を設定") { model.setDate(Date()) }; Text("未設定").foregroundStyle(.orange) }
                    Spacer()
                }.font(.caption).disabled(model.busy || model.playing)
            }
            Divider()
            settingsPanel.disabled(model.busy || model.playing)
        }.padding(22)
    }
    private func setting<Value>(_ key: WritableKeyPath<FilmSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: key] }, set: {
            model.settings[keyPath: key] = $0
            model.dirty = true
            model.invalidatePreview()
        })
    }
    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                Picker("画面", selection: setting(\.portrait)) {
                    Text("縦 9:16").tag(true); Text("横 16:9").tag(false)
                }.pickerStyle(.segmented).frame(width: 210)
                Text("1枚 \(model.settings.seconds, specifier: "%.1f")秒").monospacedDigit()
                Slider(value: setting(\.seconds), in: 0.1...5, step: 0.1).frame(maxWidth: 190)
                Spacer()
                Toggle("滑らかに切替", isOn: setting(\.fade)).toggleStyle(.checkbox)
                Toggle("日付表示", isOn: setting(\.showDate)).toggleStyle(.checkbox)
            }
            HStack(spacing: 14) {
                Text("顔の大きさ").font(.caption)
                Slider(value: setting(\.spacing), in: 0.1...0.5).frame(maxWidth: 210)
                Text("目の高さ").font(.caption)
                Slider(value: setting(\.eyeHeight), in: 0.3...0.8).frame(maxWidth: 210)
                Spacer()
                Text("\(Double(model.ready.count) * model.settings.seconds, specifier: "%.1f")秒 · 1080p / 30fps")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var footer: some View {
        HStack {
            if model.busy {
                ProgressView().controlSize(.small)
                if model.progress > 0 { ProgressView(value: model.progress).frame(width: 110) }
            } else { Circle().fill(accent).frame(width: 6, height: 6) }
            Text(model.status).font(.caption).lineLimit(2)
            Spacer()
            if model.busy { Button("中止", action: model.cancel) }
            else { Text(model.dirty ? "未保存の変更あり" : "写真の処理はMac内で実行").font(.caption).foregroundStyle(.secondary) }
        }.padding(.horizontal, 18).padding(.vertical, 10)
    }
    private var googleSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Googleフォトの設定").font(.title2.bold())
            Text("初回のみ、ご自身のGoogle Cloudプロジェクトの認証設定が必要です。Mac内の写真は設定なしで使えます。")
            Text("① Google CloudでGoogle Photos Picker APIを有効にする\n② Google Auth Platformで同意画面と自分のテストユーザーを設定\n③ OAuthクライアント「デスクトップアプリ」を作成\n④ ダウンロードしたJSONを下のボタンから読み込む")
                .lineSpacing(7)
            HStack {
                Link("Google Cloudを開く", destination: URL(string: "https://console.cloud.google.com/")!)
                Link("公式設定ガイド", destination: URL(string: "https://developers.google.com/photos/picker/guides/get-started-picker")!)
            }
            Text("Googleフォトの画面で使う写真を選択します。既存アルバムの自動監視は行いません。認証設定はキーチェーン、アクセストークンは起動中のメモリに保持します。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("OAuth JSONを読み込む…") { model.configureGoogle() }
                Text(model.googleConfigured ? "設定済み" : "未設定").foregroundStyle(model.googleConfigured ? Color.green : .secondary)
                Spacer()
                if model.googleConfigured { Button("設定を削除", action: model.clearGoogle) }
            }
            HStack { Spacer(); Button("閉じる") { showGoogle = false }.keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 600)
    }
}

@MainActor
struct OriginalCanvas: View {
    @ObservedObject var model: StudioModel
    var body: some View {
        GeometryReader { geo in
            if let photo = model.current, let image = model.original {
                let scale = min(geo.size.width / CGFloat(photo.width), geo.size.height / CGFloat(photo.height))
                let size = CGSize(width: CGFloat(photo.width) * scale, height: CGFloat(photo.height) * scale)
                let ox = (geo.size.width - size.width) / 2, oy = (geo.size.height - size.height) / 2
                ZStack(alignment: .topLeading) {
                    Color.clear
                    Image(nsImage: image).resizable().frame(width: size.width, height: size.height).offset(x: ox, y: oy)
                    if let eyes = photo.eyes, !model.manual {
                        marker(eyes.left, scale: scale, ox: ox, oy: oy, height: photo.height, label: "")
                        marker(eyes.right, scale: scale, ox: ox, oy: oy, height: photo.height, label: "")
                    } else if !model.manual {
                        ForEach(Array(photo.faces.enumerated()), id: \.offset) { index, pair in
                            marker(pair.left, scale: scale, ox: ox, oy: oy, height: photo.height, label: "\(index + 1)")
                        }
                    }
                    if let first = model.firstEye {
                        marker(first, scale: scale, ox: ox, oy: oy, height: photo.height, label: "1")
                    }
                }.contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                    guard !model.busy, !model.playing else { return }
                    let x = (value.location.x - ox) / scale
                    let y = CGFloat(photo.height) - (value.location.y - oy) / scale
                    guard x >= 0, y >= 0, x <= CGFloat(photo.width), y <= CGFloat(photo.height) else { return }
                    model.clickEye(Point(Double(x), Double(y)))
                })
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "photo.badge.plus").font(.system(size: 42, weight: .ultraLight))
                    Text("写真を追加してください").font(.callout)
                }.foregroundStyle(.secondary).frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
    private func marker(_ p: Point, scale: CGFloat, ox: CGFloat, oy: CGFloat, height: Int, label: String) -> some View {
        ZStack {
            Circle().stroke(Color.mint, lineWidth: 2).frame(width: 16, height: 16)
            Circle().fill(Color.mint).frame(width: 3, height: 3)
            if !label.isEmpty { Text(label).font(.caption.bold()).foregroundStyle(.black).padding(3).background(Color.mint).offset(x: 17, y: -15) }
        }.position(x: ox + CGFloat(p.x) * scale, y: oy + (CGFloat(height) - CGFloat(p.y)) * scale)
    }
}
