import AppKit
import SwiftUI

struct FileQueueView: View {
    @ObservedObject var queue: FileTranscriptionQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Audio file queue").font(.title2)
            Text("Files stay on this Mac. Live meetings take priority. Quitting clears unfinished jobs; automatic notes are not generated.")
                .font(.callout)
            if queue.jobs.isEmpty { Text("Choose Transcribe audio files… from the menu to add recordings.") }
            List(queue.jobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: job.source.lastPathComponent).font(.headline)
                    row(job)
                }
                .padding(.vertical, 6)
            }
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 360)
    }

    @ViewBuilder private func row(_ job: FileTranscriptionJob) -> some View {
        switch job.state {
        case .queued:
            HStack {
                Text("Queued")
                Button("Remove") { queue.cancel(job.id) }
            }
        case .processing, .paused:
            ProgressView(value: job.progress)
                .accessibilityLabel(tr("Processed audio: \(job.source.lastPathComponent)"))
            HStack {
                Text(job.state == .paused ? tr("Paused for a live meeting") : tr("Processing"))
                Button("Cancel") { queue.cancel(job.id) }
            }
        case .completed(let url):
            HStack {
                Text("Completed")
                Button("Open transcript") { NSWorkspace.shared.open(url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red)
            Button("Retry") { queue.retry(job.id) }
        case .cancelled: Text("Cancelled")
        }
    }
}
