import SwiftUI
import DiskScopeCore

struct ContentView: View {
    @ObservedObject var model: ScannerModel
    @State private var showIssues = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 208)
            Rectangle().fill(Theme.line).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.line).frame(height: 1)
                if model.scanning { scanningView }
                else if let snapshot = model.snapshot { dashboard(snapshot) }
                else { welcome }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.background)
        .sheet(isPresented: $showIssues) { issuesSheet }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 24)).foregroundStyle(Theme.accent)
                Text("DiskScope").font(.system(size: 22, weight: .semibold, design: .rounded))
            }.padding(.top, 45).padding(.bottom, 30)
            Button { model.navigate(0) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "square.grid.2x2.fill")
                    Text("ストレージ概要")
                    Spacer()
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                }.font(.system(size: 12, weight: .medium)).padding(11)
                    .foregroundStyle(Theme.accent).background(Theme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            }.buttonStyle(.plain).padding(.horizontal, -8)
            Button(action: model.chooseFolder) { Label("フォルダ・SSDを選択", systemImage: "folder.badge.plus").font(.system(size: 12)).padding(.vertical, 13) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
            if !model.recentRoots.isEmpty {
                Text("最近解析した場所").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted).padding(.top, 27).padding(.bottom, 13)
                ForEach(model.recentRoots, id: \.self) { path in
                    Button { model.chooseFolder(at: URL(fileURLWithPath: path)) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "folder").foregroundStyle(Theme.muted)
                            Text(URL(fileURLWithPath: path).lastPathComponent.isEmpty ? "/" : URL(fileURLWithPath: path).lastPathComponent).lineLimit(1)
                        }.font(.system(size: 11)).padding(.vertical, 7)
                    }.buttonStyle(.plain).disabled(model.scanning).help("場所を確認して解析")
                }
            }
            Spacer()
            if model.volumeTotal > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    Label("選択先のボリューム", systemImage: "internaldrive").font(.system(size: 11, weight: .medium))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.07))
                            Capsule().fill(Theme.accent.opacity(0.65)).frame(width: geo.size.width * max(0, min(1, 1 - Double(model.volumeAvailable) / Double(model.volumeTotal))))
                        }
                    }.frame(height: 5)
                    Text("空き \(ByteText.format(model.volumeAvailable)) / \(ByteText.format(model.volumeTotal))")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                }.padding(13).background(Theme.panel, in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, -5).padding(.bottom, 22)
            }
        }
        .padding(.horizontal, 22).frame(maxHeight: .infinity).background(Theme.sidebar)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text("ストレージ概要").font(.system(size: 20, weight: .semibold))
                if let root = model.rootURL {
                    Text(root.lastPathComponent.isEmpty ? "/" : root.lastPathComponent)
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer()
            if model.snapshot != nil {
                Button { if let url = model.rootURL { model.start(url) } } label: { Label("再解析", systemImage: "arrow.clockwise") }
                    .buttonStyle(QuietButtonStyle())
            }
            Button(action: model.chooseFolder) { Label("フォルダを選択", systemImage: "plus") }
                .buttonStyle(PrimaryButtonStyle()).disabled(model.scanning)
        }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 22)
    }

    private func dashboard(_ snapshot: ScanSnapshot) -> some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                statCard("解析した使用量", value: ByteText.format(snapshot.nodes[0].bytes(model.metric)), detail: model.metric.rawValue, icon: "externaldrive", accent: true)
                statCard("ファイル", value: snapshot.payload.fileCount.formatted(), detail: "\(snapshot.payload.directoryCount.formatted()) フォルダを走査", icon: "doc.on.doc", accent: false)
                statCard("解析時間", value: String(format: "%.2f 秒", snapshot.payload.elapsed), detail: "走査・集計", icon: "bolt", accent: false)
            }
            if snapshot.payload.issueCount > 0 {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(snapshot.payload.issueCount) 件を読み取れませんでした。表示は読み取れた範囲の集計です。")
                    Spacer()
                    Button("詳細") { showIssues = true }.buttonStyle(.plain).underline()
                }.font(.system(size: 11)).foregroundStyle(.orange).padding(11)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 0) {
                    mapHeader
                    if model.current?.bytes(model.metric) == 0 {
                        VStack(spacing: 10) {
                            Image(systemName: "square.dashed").font(.system(size: 34)).foregroundStyle(Theme.muted)
                            Text("面積で表示する使用量がありません").font(.system(size: 13))
                            Text("空のフォルダや0バイトの項目は下の一覧で確認できます。")
                                .font(.system(size: 11)).foregroundStyle(Theme.muted)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else { TreemapView(model: model).padding(8) }
                    HStack(spacing: 13) {
                        ForEach([FileCategory.folder, .video, .image, .audio, .archive, .code, .document, .other], id: \.self) { category in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2).fill(Theme.color(category)).frame(width: 7, height: 7)
                                Text(category.rawValue).font(.system(size: 9))
                            }
                        }
                        Spacer(minLength: 0)
                    }.foregroundStyle(Theme.muted).padding(.horizontal, 14).padding(.vertical, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
                inspector.frame(width: 224)
            }.frame(minHeight: 200)
            fileList.frame(height: 210)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statCard(_ title: String, value: String, detail: String, icon: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 11)).foregroundStyle(Theme.muted)
                Spacer()
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(accent ? Theme.accent : Theme.muted)
            }
            Text(value).font(.system(size: 28, weight: .medium, design: .rounded)).foregroundStyle(accent ? Theme.accent : .white).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 10)).foregroundStyle(Theme.muted)
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    private var mapHeader: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("容量の地図").font(.system(size: 13, weight: .semibold))
                Spacer()
                Picker("集計方法", selection: $model.metric) {
                    ForEach(SizeMetric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 170).controlSize(.small)
            }
            HStack(spacing: 5) {
                Button(action: model.up) { Image(systemName: "arrow.up") }.buttonStyle(.plain).disabled(model.currentID == 0)
                    .help("上の階層へ（⌘↑）").padding(.trailing, 5)
                if let snapshot = model.snapshot {
                    let ancestors = snapshot.ancestors(of: model.currentID)
                    ForEach(Array(ancestors.suffix(4).enumerated()), id: \.element) { offset, id in
                        if offset > 0 { Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Theme.muted) }
                        Button(snapshot.nodes[id].name) { model.navigate(id) }.buttonStyle(.plain)
                            .foregroundStyle(id == model.currentID ? Theme.accent : Theme.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                Text(ByteText.format(model.current?.bytes(model.metric) ?? 0)).foregroundStyle(Theme.muted).monospacedDigit()
            }.font(.system(size: 10))
        }.padding(14)
    }

    private var inspector: some View {
        GeometryReader { geometry in
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Text("選択した項目").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.muted)
            if let node = model.selected, let snapshot = model.snapshot {
                Image(systemName: node.category.symbol).font(.system(size: 28)).foregroundStyle(Theme.color(node.category))
                Text(node.name).font(.system(size: 15, weight: .semibold)).lineLimit(3).textSelection(.enabled)
                Text(model.relativePath(node.id)).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(3)
                Rectangle().fill(Theme.line).frame(height: 1)
                detailRow("ディスク上", ByteText.format(node.allocated))
                detailRow("ファイルサイズ", ByteText.format(node.logical))
                detailRow("表示範囲の割合", ByteText.percent(node.bytes(model.metric), of: model.current?.bytes(model.metric) ?? 0))
                if node.isDirectory { detailRow("含まれるファイル", snapshot.descendantFiles[node.id].formatted()) }
                if node.modified > 0 {
                    detailRow("更新日", Date(timeIntervalSince1970: Double(node.modified)).formatted(.dateTime.year().month().day()))
                }
                if node.duplicate { note("ハードリンク：容量は別の項目に計上済み") }
                if node.excluded { note("別ボリュームまたは特殊ファイルのため集計対象外") }
                if node.unreadable { note("読み取れない項目を含みます") }
                if node.kind == .symlink { note("リンク先は走査していません") }
                Spacer(minLength: 0)
                if node.isDirectory {
                    Button { model.navigate(node.id) } label: { Label("このフォルダを表示", systemImage: "arrow.down.right") }
                        .buttonStyle(QuietButtonStyle())
                }
                Button { model.reveal(node.id) } label: { Label("Finderで表示", systemImage: "arrow.up.forward.square") }
                    .buttonStyle(QuietButtonStyle())
            } else {
                Image(systemName: "cursorarrow.rays").font(.system(size: 28)).foregroundStyle(Theme.muted).padding(.top, 24)
                Text("項目を選択").font(.system(size: 19, weight: .medium))
                Text("クリックで詳細を表示\nダブルクリックでフォルダを開く")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text("小さな項目は「その他」にまとめて表示する場合があります。全項目は一覧で検索できます。")
                    .font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(18).frame(minHeight: geometry.size.height, alignment: .topLeading)
        }
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label).foregroundStyle(Theme.muted)
            Spacer(minLength: 4)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }.font(.system(size: 10))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }

    private var fileList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("項目一覧（容量順）").font(.system(size: 12, weight: .semibold))
                Text("\(model.currentSelection.count.formatted()) 項目").font(.system(size: 10)).foregroundStyle(Theme.muted)
                Spacer()
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("この階層を検索", text: $model.search).textFieldStyle(.plain).font(.system(size: 11)).frame(width: 150)
            }.padding(13)
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if let snapshot = model.snapshot {
                        let matches = model.filteredChildren
                        ForEach(matches.prefix(300), id: \.self) { id in
                            fileRow(snapshot.nodes[id])
                        }
                        if matches.isEmpty { Text(model.searching ? "検索中…" : (model.search.isEmpty ? "この階層には項目がありません" : "一致する項目がありません")).font(.system(size: 11)).foregroundStyle(Theme.muted).padding(20) }
                        if model.filteredSelection.count > 300 { Text("上位300件を表示しています。名前で検索すると残りの項目も確認できます。")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted).padding(10) }
                    }
                }
            }
        }.background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
    }

    private func fileRow(_ node: ScanNode) -> some View {
        HStack(spacing: 10) {
            Image(systemName: node.category.symbol).foregroundStyle(Theme.color(node.category)).frame(width: 18)
            Button { model.selectedID = node.id } label: {
                Text(node.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            if node.unreadable { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
            if node.excluded || node.duplicate { Text(node.excluded ? "対象外" : "計上済").font(.system(size: 9)).foregroundStyle(Theme.muted) }
            GeometryReader { geo in
                Capsule().fill(Theme.color(node.category)).frame(width: max(0, geo.size.width * Double(node.bytes(model.metric)) / max(1, Double(model.current?.bytes(model.metric) ?? 0)))).frame(maxHeight: .infinity)
            }.frame(width: 86, height: 3)
            Text(ByteText.percent(node.bytes(model.metric), of: model.current?.bytes(model.metric) ?? 0)).foregroundStyle(Theme.muted).frame(width: 54, alignment: .trailing)
            Text(ByteText.format(node.bytes(model.metric))).monospacedDigit().frame(width: 80, alignment: .trailing)
            if node.isDirectory {
                Button { model.navigate(node.id) } label: { Image(systemName: "chevron.right").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("このフォルダを表示")
            } else {
                Button { model.reveal(node.id) } label: { Image(systemName: "arrow.up.forward.square").frame(width: 22, height: 22).contentShape(Rectangle()) }
                    .buttonStyle(.plain).help("Finderで表示")
            }
        }.font(.system(size: 11)).padding(.horizontal, 14).padding(.vertical, 5)
            .background(model.selectedID == node.id ? Theme.accent.opacity(0.09) : .clear)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { if node.isDirectory { model.navigate(node.id) } }
            .onTapGesture { model.selectedID = node.id }
            .contextMenu {
                Button("Finderで表示") { model.reveal(node.id) }
                if node.isDirectory { Button("このフォルダを表示") { model.navigate(node.id) } }
            }
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "folder").font(.system(size: 40)).foregroundStyle(Theme.muted)
            Text("解析対象を選択してください").font(.system(size: 18, weight: .medium))
            Button(action: model.chooseFolder) { Label("フォルダ・SSDを選択", systemImage: "folder") }.buttonStyle(PrimaryButtonStyle()).padding(.top, 7)
            if let error = model.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled).padding().frame(maxWidth: 560) }
            if let notice = model.notice { Text(notice).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanningView: some View {
        VStack(spacing: 22) {
            Spacer()
            ProgressView().controlSize(.large).tint(Theme.accent)
            Text(model.preparing ? "表示を準備中" : "解析中").font(.system(size: 23, weight: .medium))
            Text(model.rootURL?.lastPathComponent ?? "").font(.system(size: 12)).foregroundStyle(Theme.muted)
            HStack(spacing: 40) {
                scanStat("ファイル", (model.progress?.files ?? 0).formatted())
                scanStat("フォルダ", (model.progress?.directories ?? 0).formatted())
                scanStat("確認した使用量", ByteText.format(model.progress?.allocated ?? 0))
            }.padding(.vertical, 18)
            Button("キャンセル") { model.cancel() }.buttonStyle(QuietButtonStyle())
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func scanStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 8) {
            Text(value).font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(Theme.accent)
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "info.circle")
            Text(model.snapshot == nil ? "解析対象を選んで開始 · ⌘O" : "面積 = 選択した集計方法の容量  /  ダブルクリックでフォルダ内へ")
            Spacer()
            if let snapshot = model.snapshot {
                Button { showIssues = true } label: {
                    Text("対象外 \(snapshot.payload.excludedCount) · 重複 \(snapshot.payload.duplicateCount) · 集計について")
                }.buttonStyle(.plain)
            }
        }.font(.system(size: 9)).foregroundStyle(Theme.muted).padding(.horizontal, 25).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var issuesSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("集計について").font(.title2.bold())
                Spacer()
                Button("閉じる") { showIssues = false }.keyboardShortcut(.cancelAction)
            }
            Text("「ディスク上の使用量」は各ファイルの割り当て済みブロック数から計算します。「ファイルサイズ」は論理サイズです。1 KB = 1,000 B で表示しています。")
            Text("APFSのクローン・スナップショット・圧縮・共有領域などにより、合計はSSD全体の実使用量や削除で空く容量とは一致しません。フォルダ自体の管理領域は含みません。")
            Text("シンボリックリンクの参照先と、選択先とは別のファイルシステムは走査しません。別のSSDは直接選択して解析してください。ハードリンクの容量は、最初に見つかった1件に計上します。")
            Text("アクセス権で読み取れない場所はスキップします。必要な場合は「システム設定 → プライバシーとセキュリティ → フルディスクアクセス」でDiskScopeを許可し、再解析してください。解析中の変更は結果に反映されない場合があります。")
            if let snapshot = model.snapshot, !snapshot.payload.issues.isEmpty {
                Divider()
                Text("読み取れなかった項目（最大100件）").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(snapshot.payload.issues.enumerated()), id: \.offset) { _, issue in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.path.replacingOccurrences(of: snapshot.payload.rootPath, with: snapshot.nodes[0].name)).font(.system(size: 11, weight: .medium))
                                Text(issue.message).font(.system(size: 10)).foregroundStyle(Theme.muted)
                            }.textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 220)
            }
        }.font(.system(size: 12)).lineSpacing(4).padding(28).frame(width: 620).background(Theme.background)
    }
}
