import ScrobbleCore
import SwiftData
import SwiftUI

/// The latest 200 scrobbles. Swipe or right-click a row to retry or delete it.
struct RecentScrobblesView: View {
    @Environment(MenuBarController.self) private var controller
    @Query private var records: [ScrobbleRecord]

    init() {
        var descriptor = FetchDescriptor<ScrobbleRecord>(sortBy: [SortDescriptor(\.listenedAt, order: .reverse)])
        descriptor.fetchLimit = 200
        _records = Query(descriptor)
    }

    var body: some View {
        if records.isEmpty {
            ContentUnavailableView(
                "No Scrobbles Yet", systemImage: "waveform",
                description: Text("Play something in Music. Each track appears here once it counts.")
            )
        } else {
            List(records) { record in
                ScrobbleRowView(record: record)
                    .swipeActions(edge: .trailing) { actions(for: record) }
                    .contextMenu { actions(for: record) }
            }
            .animation(.smooth, value: records.map(\.id))
        }
    }

    @ViewBuilder
    private func actions(for record: ScrobbleRecord) -> some View {
        Button(role: .destructive) {
            controller.delete(record)
        } label: {
            Label("Delete", systemImage: "trash")
        }
        if !record.isFullySent {
            Button {
                controller.retry(record)
            } label: {
                Label("Retry Now", systemImage: "arrow.clockwise")
            }
            .tint(.blue)
        }
    }
}
