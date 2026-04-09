//
//  LogWindowView.swift
//  railcart
//
//  Debug log viewer window showing live application logs.
//

import SwiftUI

struct LogWindowView: View {
    @Environment(\.appLogger) private var logger
    @State private var filterText = ""
    @State private var autoScroll = true

    private var filteredEntries: [AppLogger.LogEntry] {
        if filterText.isEmpty { return logger.entries }
        let query = filterText.lowercased()
        return logger.entries.filter {
            $0.category.lowercased().contains(query) || $0.message.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter logs...", text: $filterText)
                .textFieldStyle(.plain)

            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .controlSize(.small)

            Spacer()

            if let logFileURL = logger.logFileURL {
                Button {
                    NSWorkspace.shared.open(logFileURL)
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.borderless)
                .help("Open log file")
            }

            Text("\(filteredEntries.count) entries")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List(filteredEntries) { entry in
                logRow(entry)
                    .id(entry.id)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .font(.caption.monospaced())
            .onChange(of: logger.entries.count) {
                if autoScroll, let last = filteredEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func logRow(_ entry: AppLogger.LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timeString(entry.timestamp))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(entry.category)
                .foregroundStyle(categoryColor(entry.category))
                .frame(width: 60, alignment: .leading)

            Text(entry.message)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timeString(_ date: Date) -> String {
        AppLogger.dateFormatter.string(from: date)
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "sync": .blue
        case "bridge": .orange
        case "node": .purple
        case "error": .red
        case "system": .secondary
        case "wallet": .green
        case "shield": .cyan
        default: .secondary
        }
    }
}
