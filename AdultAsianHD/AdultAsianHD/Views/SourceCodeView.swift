// SourceCodeView.swift — 源代码页（v2 重建）
// 源 Tab 点源行进这里：显示该源 .js 文件的全部代码（等宽字体、可滚动、
// 可选中，工具栏一键复制），顶部是源的基本信息；导出 / 删除
// 都能在这里用。

import SwiftUI
import UIKit

struct SourceCodeView: View {
    let source: SourceRecord

    @EnvironmentObject private var store: SourceStore
    @Environment(\.dismiss) private var dismiss

    @State private var codeText: String?
    @State private var loadFailed = false
    @State private var showDeleteConfirm = false
    @State private var resultMessage = ""
    @State private var showResultAlert = false

    private var lineCount: Int {
        codeText?.components(separatedBy: "\n").count ?? 0
    }

    var body: some View {
        Group {
            if loadFailed {
                EmptyState(title: "读不到代码", message: "这个源的 .js 文件找不到了，可能已被删除。")
            } else if let code = codeText {
                codeList(code: code)
            } else {
                LoadingView(text: "正在读取代码…")
            }
        }
        .navigationTitle(source.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let text = store.jsSource(for: source) {
                codeText = text
            } else {
                loadFailed = true
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    copyCode()
                } label: {
                    Label("复制代码", systemImage: "doc.on.doc")
                }
                .disabled(codeText == nil)
            }
        }
        .alert("删除这个源？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                store.delete(source)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删除后本地文件就没有了，同步的源下次同步还会拉回来。")
        }
        .alert("提示", isPresented: $showResultAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage)
        }
    }

    private func copyCode() {
        guard let code = codeText else { return }
        UIPasteboard.general.string = code
        resultMessage = "已复制 \(lineCount) 行代码到剪贴板"
        showResultAlert = true
    }

    // MARK: - 页面

    private func codeList(code: String) -> some View {
        List {
            Section("源信息") {
                infoRow("源 id", source.id)
                infoRow("名称", source.title)
                infoRow("版本", source.version)
                infoRow("文件名", source.fileName)
                infoRow("导入时间", dateText(source.importedAt))
                infoRow("导入方式", originText)
            }

            Section("操作") {
                if let url = store.exportURL(for: source) {
                    ShareLink(item: url) {
                        Label("导出 .js 文件", systemImage: "square.and.arrow.up")
                    }
                }
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除此源", systemImage: "trash")
                }
                NavigationLink {
                    SourceDetailView(source: source)
                } label: {
                    Label("源详情", systemImage: "info.circle")
                }
            }

            Section("代码（\(lineCount) 行）") {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - 信息行

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
    }

    /// 来源标记：origin 为 gitee / 含「码云」即码云同步，否则外部导入。
    private var originText: String {
        if source.origin == "gitee" || source.origin.contains("码云") || source.origin.contains("Gitee") {
            return "码云同步"
        }
        return "外部导入"
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

}
