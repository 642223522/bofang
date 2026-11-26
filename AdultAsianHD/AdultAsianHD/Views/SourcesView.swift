// SourcesView.swift — 源 Tab（v2 重建）
// 导入是本次验收第一项。重点：从文件导入不许用 SwiftUI 的 .fileImporter
// （旧 App 就是它回调丢了才坏的），改用 UIDocumentPickerViewController +
// 自写的 DocumentPicker（NSObject + UIDocumentPickerDelegate）。
//
// 防丢回调设计（见文件底部 DocumentPicker 与 presentDocumentPicker）：
//  1. DocumentPicker 实例由 SourcesView 的 @State 强引用（documentPicker），
//     delegate 是弱引用，没有这个强引用 picker 会在 present 后被释放、
//     回调永远不到——这就是旧版「点外部 porn.js 半天没反应」的根因之一。
//  2. present 时从 keyWindow 的 rootViewController 一路找到最顶层
//     presentedViewController 再 present，避免被别的 sheet 盖住导致无响应。
//  3. didPickDocumentsAt / documentPickerWasCancelled 里先把 onPick/onCancel
//     置 nil 再回调，断开 picker→闭包→View 的引用环；读取在后台线程做
//     （startAccessingSecurityScopedResource → Data(contentsOf:) →
//     stopAccessingSecurityScopedResource），读完回主线程调 importData。
//  4. 全程 UI 给反馈：isReading 时显示「正在读取文件…」遮罩；取消也关掉它；
//     成功/失败都弹 Alert（成功「已导入 <标题>」，失败用 ImportError 的中文原因）。
// 从链接导入、码云同步同样给读取中提示与结果 Alert。

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SourcesView: View {
    @EnvironmentObject private var store: SourceStore

    // MARK: - 导入器强引用（防回调丢失，见文件底部说明）

    @State private var documentPicker: DocumentPicker?

    // MARK: - UI 状态

    @State private var isReading = false
    @State private var readingLabel = "正在读取文件…"
    @State private var alertMessage = ""
    @State private var showAlert = false

    @State private var showURLSheet = false
    @State private var urlString = ""

    @State private var showSyncSheet = false
    @State private var giteeToken = ""

    /// “仅 Wi-Fi 时自动自检”开关（默认关）。只影响后台自动自检；
    /// 手动自检和下载不受影响（下载仍可走流量）。
    @AppStorage(SourceStore.wifiOnlyAutoCheckDefaultsKey) private var wifiOnlyAutoCheck = false

    /// 当前源 id（同步后首个源自动设为当前）。
    @AppStorage("currentSourceId") private var currentSourceId = ""

    var body: some View {
        ZStack {
            // 宽屏限宽 700pt 居中（展开的 Duo 内屏 / 横屏不再两边大黑边），
            // 底色用分组灰：浅色如旧版，深色是深灰而非纯黑。
            WideContent {
                VStack(spacing: 0) {
                    actionRow
                        .padding()

                    syncInfoRow
                        .padding(.horizontal)
                        .padding(.bottom, 8)

                    checkRow
                        .padding(.horizontal)
                        .padding(.bottom, 8)

                    wifiToggleRow
                        .padding(.horizontal)
                        .padding(.bottom, 8)

                    sourceList
                }
            }

            if isReading {
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView()
                    Text(readingLabel)
                        .font(.subheadline)
                }
                .padding(24)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .navigationTitle("源")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: $showAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .sheet(isPresented: $showURLSheet) {
            urlImportSheet
        }
        .sheet(isPresented: $showSyncSheet) {
            giteeSyncSheet
        }
    }

    // MARK: - 顶部三个操作
    //
    // 三列等宽卡片：图标在上、单行文字在下，固定高度。
    // 原来是 HStack 里三个 .bordered 按钮，窄竖屏下 Label 会折成图标在上、
    // 文字在圆钮里换行（深色下更像三个黑圆坨）；卡片式从根上杜绝了这种折叠。

    private var actionRow: some View {
        HStack(spacing: 12) {
            actionCard(title: "从文件导入", systemImage: "doc.badge.plus") {
                presentDocumentPicker()
            }
            actionCard(title: "从链接导入", systemImage: "link.badge.plus") {
                urlString = ""
                showURLSheet = true
            }
            actionCard(title: "码云同步", systemImage: "arrow.triangle.2.circlepath") {
                // 打开同步表单时把 Keychain 里存过的 Token 预填进密文框。
                giteeToken = store.loadSavedGiteeToken() ?? ""
                showSyncSheet = true
            }
        }
    }

    private func actionCard(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var syncInfoRow: some View {
        HStack {
            Text("上次同步：\(lastSyncText)")
            Spacer()
            Text("源数量：\(store.sources.count)")
        }
        .font(.footnote)
        .foregroundColor(.secondary)
    }

    private var lastSyncText: String {
        guard let date = store.lastSyncAt else { return "从未同步" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    /// 自检失败的源个数（上传按钮角标与可用状态用）。
    private var failedCheckCount: Int {
        store.checkResults.values.filter { $0.status == .failed }.count
    }

    // MARK: - 自检 / 上传坏模块操作行

    private var checkRow: some View {
        HStack(spacing: 12) {
            Button {
                checkAll()
            } label: {
                Label("自检全部", systemImage: "stethoscope")
            }
            .buttonStyle(.bordered)
            .disabled(store.sources.isEmpty)

            Button {
                uploadBroken()
            } label: {
                Label("上传坏的模块\(failedCheckCount > 0 ? "（\(failedCheckCount)）" : "")", systemImage: "arrow.up.doc")
            }
            .buttonStyle(.bordered)
            .disabled(failedCheckCount == 0)

            Spacer()
        }
    }

    /// “仅 Wi-Fi 时自动自检”开关行（默认关，只影响后台自动自检）。
    /// 主文案和说明分两行：原来说明跟在主文案后面 inline，窄屏下两处一起换行、
    /// 挤成三行；现在主文案一行、说明一行，永不乱折。
    private var wifiToggleRow: some View {
        Toggle(isOn: $wifiOnlyAutoCheck) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "wifi")
                    Text("仅 Wi-Fi 时自动自检")
                }
                Text("后台自检，12 小时一轮")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .font(.footnote)
        }
        .toggleStyle(.switch)
    }

    private func checkAll() {
        isReading = true
        readingLabel = "正在自检全部源…"
        Task {
            let (ok, failed, skipped) = await store.runCheckAll()
            isReading = false
            var text = "自检完成：\(ok) 个正常，\(failed) 个失败"
            if skipped > 0 { text += "，\(skipped) 个重复跳过" }
            showResultAlert(text)
        }
    }

    private func uploadBroken() {
        isReading = true
        readingLabel = "正在上传坏的模块…"
        Task {
            // 传空串：store 里先用 Keychain 存过的 Token，没有才报错。
            let result = await store.uploadBrokenSources(token: giteeToken)
            // 账本一起传（reports 分支，Muse 每天读报告时一起读到）；账本传失败不影响坏模块的结果。
            let ledgerResult = await store.uploadLedger(token: giteeToken)
            isReading = false
            var parts: [String] = []
            switch result {
            case .success(let count):
                parts.append("已上传 \(count) 个坏的模块到码云 broken 分支")
            case .failure(let error):
                parts.append(error.localizedDescription)
            }
            switch ledgerResult {
            case .success(let file):
                parts.append("账本已传到 reports 分支（\(file)）")
            case .failure(let error):
                parts.append("账本没传上去：\(error.localizedDescription)")
            }
            showResultAlert(parts.joined(separator: "；"))
        }
    }

    /// 列表行里的自检状态：正常（绿）/ 失败（红，死在哪步）/ 跳过（灰，重复）/ 未自检（灰）。
    /// 深探针坏了在下面另起一行标出来。
    @ViewBuilder
    private func checkStatusLine(for source: SourceRecord) -> some View {
        if let result = store.checkResults[source.id] {
            switch result.status {
            case .ok:
                VStack(alignment: .leading, spacing: 2) {
                    Text("自检正常" + (result.checkedAt.map { " · \($0.formatted(date: .numeric, time: .shortened))" } ?? ""))
                        .font(.caption)
                        .foregroundColor(.green)
                    if let probe = result.deepProbe, !probe.passed {
                        Text("深探针：坏了（\(probe.failedStep ?? "首片")）· \(probe.checkedAt.formatted(date: .numeric, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            case .failed:
                VStack(alignment: .leading, spacing: 2) {
                    let step = result.failedStep.map { "死在\($0)步" } ?? "自检失败"
                    // 拆成三段再拼：整句一次拼完类型检查超时（GitHub Actions
                    // 首次运行报错：unable to type-check in reasonable time）。
                    let reason = result.failedReason ?? result.failedLines.sorted(by: { $0.key < $1.key }).first.map { "\($0.key)：\($0.value)" } ?? ""
                    let checked = result.checkedAt.map { " · \($0.formatted(date: .numeric, time: .shortened))" } ?? ""
                    Text("\(step)：\(reason)\(checked)")
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(1)
                    if let probe = result.deepProbe, !probe.passed {
                        Text("深探针：坏了（\(probe.failedStep ?? "首片")）· \(probe.checkedAt.formatted(date: .numeric, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            case .skipped:
                Text("与 \(duplicateTitle(for: result.duplicateOf)) 重复，跳过")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else {
            Text("未自检")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// 重复的那个源的标题（duplicateOf 是源 id；找不到显示 id）。
    private func duplicateTitle(for duplicateOf: String?) -> String {
        guard let id = duplicateOf else { return "其他源" }
        return store.sources.first(where: { $0.id == id })?.title ?? id
    }

    // MARK: - 源列表

    private var sourceList: some View {
        Group {
            if store.sources.isEmpty {
                EmptyState(
                    title: "还没有源",
                    message: "从文件或链接导入一个 .js 源，或用码云同步拉取。",
                    actionTitle: "从文件导入",
                    action: { presentDocumentPicker() }
                )
            } else {
                List {
                    ForEach(store.sources) { source in
                        HStack(spacing: 12) {
                            NavigationLink {
                                SourceCodeView(source: source)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.title)
                                        .font(.headline)
                                        .lineLimit(1)
                                    HStack(spacing: 8) {
                                        Text(originLabel(for: source))
                                            .font(.caption)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            // 实色灰 5：分组底色上浅色深色都看得见
                                            //（原来的 secondarySystemBackground
                                            // 在分组底色上浅色/深色都几乎同色）。
                                            .background(Color(.systemGray5))
                                            .clipShape(Capsule())
                                        Text("版本 \(source.version)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        if source.id == currentSourceId {
                                            Text("当前")
                                                .font(.caption)
                                                .foregroundColor(.accentColor)
                                        }
                                    }
                                    checkStatusLine(for: source)
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            if let url = store.exportURL(for: source) {
                                ShareLink(item: url) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                store.delete(source)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// 来源标记：origin 为 gitee / 含「码云」即码云同步，否则外部导入。
    /// （契约未规定 origin 的取值；导入时本文件固定传 "外部导入"，同步走 Core 层。）
    private func originLabel(for source: SourceRecord) -> String {
        if source.origin == "gitee" || source.origin.contains("码云") || source.origin.contains("Gitee") {
            return "码云同步"
        }
        return "外部导入"
    }

    // MARK: - 从文件导入（UIDocumentPicker，不用 .fileImporter）

    private func presentDocumentPicker() {
        let picker = DocumentPicker()
        picker.onPick = { urls in
            handlePickedDocuments(urls)
        }
        picker.onCancel = {
            isReading = false
        }
        // 强引用：delegate 是弱引用，不留住 picker 实例，回调会在 present 后丢失。
        documentPicker = picker

        let contentTypes = [UTType(filenameExtension: "js") ?? .plainText]
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        controller.delegate = picker
        controller.allowsMultipleSelection = true

        guard let top = Self.topViewController() else {
            documentPicker = nil
            showResultAlert("打不开文件选择器，请重试。")
            return
        }
        top.present(controller, animated: true)
    }

    /// 从 keyWindow 的 rootViewController 一路找到最顶层 presentedViewController。
    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) else {
            return nil
        }
        var top = window.rootViewController
        while let presented = top?.presentedViewController {
            top = presented
        }
        return top
    }

    /// 批量导入：一次选多个 .js 一起导。逐个处理（每个文件单独开安全域读），
    /// 最后汇总弹一次结果，不一个一个弹。单个文件也走同一条路。
    private func handlePickedDocuments(_ urls: [URL]) {
        documentPicker = nil
        guard !urls.isEmpty else { return }
        isReading = true
        readingLabel = "正在导入 1/\(urls.count)…"
        Task { @MainActor in
            var importedTitles: [String] = []
            var skippedTitles: [String] = []
            var failedLines: [String] = []
            for (index, url) in urls.enumerated() {
                readingLabel = "正在导入 \(index + 1)/\(urls.count)…"
                let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer {
                        if scoped { url.stopAccessingSecurityScopedResource() }
                    }
                    return try? Data(contentsOf: url)
                }.value
                guard let data else {
                    failedLines.append("\(url.lastPathComponent)：读取文件失败")
                    continue
                }
                switch await store.importData(data, fileName: url.lastPathComponent, origin: "外部导入") {
                case .success(let record):
                    importedTitles.append(record.title)
                case .failure(let error):
                    // 已存在相同源：算跳过，不算失败
                    if case .duplicate(let existingTitle) = error {
                        skippedTitles.append(existingTitle)
                    } else {
                        failedLines.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
            }
            isReading = false
            var parts: [String] = []
            if !importedTitles.isEmpty {
                parts.append("已导入 \(importedTitles.count) 个源：\(importedTitles.joined(separator: "、"))")
            }
            if !skippedTitles.isEmpty {
                parts.append("已跳过 \(skippedTitles.count) 个重复源：\(skippedTitles.joined(separator: "、"))")
            }
            if !failedLines.isEmpty {
                parts.append("失败 \(failedLines.count) 个：\n\(failedLines.joined(separator: "\n"))")
            }
            showResultAlert(parts.isEmpty ? "没有导入任何源。" : parts.joined(separator: "\n"))
        }
    }

    // MARK: - 从链接导入

    private var urlImportSheet: some View {
        NavigationStack {
            Form {
                Section("输入 .js 直链") {
                    TextField("https://…/xxx.js", text: $urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
                Section {
                    Text("粘贴 JS 源的直接下载链接，App 会下载并校验后导入。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("从链接导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showURLSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { importFromURL() }
                }
            }
        }
    }

    private func importFromURL() {
        let text = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            showResultAlert("请先输入 .js 直链。")
            return
        }
        showURLSheet = false
        isReading = true
        readingLabel = "正在导入链接…"
        Task {
            let result = await store.importURL(text)
            isReading = false
            switch result {
            case .success(let record):
                showResultAlert("已导入 \(record.title)")
            case .failure(let error):
                showResultAlert(error.localizedDescription)
            }
        }
    }

    // MARK: - 码云同步

    private var giteeSyncSheet: some View {
        NavigationStack {
            Form {
                Section("Gitee token") {
                    SecureField("在 App 内输入 Gitee token", text: $giteeToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("token 只存在本机，不会发给别人；从「自用资料备份」js 分支拉取源。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Section {
                    Text("上次同步：\(lastSyncText)")
                    Text("源数量：\(store.sources.count)")
                }
            }
            .navigationTitle("码云同步")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showSyncSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("同步") { syncFromGitee() }
                }
            }
        }
    }

    private func syncFromGitee() {
        // Token 为空也照常调：store 里先用 Keychain 存过的，两个都没有才报错。
        let token = giteeToken.trimmingCharacters(in: .whitespacesAndNewlines)
        showSyncSheet = false
        isReading = true
        readingLabel = "正在从码云同步…"
        Task {
            let result = await store.syncFromGitee(token: token)
            isReading = false
            switch result {
            case .success(let count):
                if let first = store.sources.first {
                    currentSourceId = first.id
                }
                if let warning = store.lastSyncError {
                    showResultAlert("同步完成，共 \(count) 个源；有个文件没同步上：\(warning)")
                } else {
                    showResultAlert("同步完成，共 \(count) 个源")
                }
            case .failure(let error):
                showResultAlert(error.localizedDescription)
            }
        }
    }

    // MARK: - 结果提示

    private func showResultAlert(_ message: String) {
        alertMessage = message
        showAlert = true
    }
}

// MARK: - DocumentPicker：UIDocumentPickerDelegate 封装
//
// 关键点：UIDocumentPickerViewController.delegate 是弱引用。
// 旧版 .fileImporter 回调丢失，就是因为没人强引用 coordinator。
// 这里由 SourcesView 的 @State 强引用本类实例（documentPicker），
// present 期间实例一直活着；回调触发时先把闭包置 nil 断开引用环，
// 再把 URL 交出去，View 侧随后把 @State 引用也清掉。

final class DocumentPicker: NSObject, UIDocumentPickerDelegate {
    var onPick: (([URL]) -> Void)?
    var onCancel: (() -> Void)?

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let callback = onPick
        onPick = nil
        onCancel = nil
        // UIKit 回调不保证在 MainActor 上下文，强制回主线程再碰 UI 状态。
        DispatchQueue.main.async { callback?(urls) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let callback = onCancel
        onPick = nil
        onCancel = nil
        DispatchQueue.main.async { callback?() }
    }
}
