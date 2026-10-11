import SwiftUI

struct TranscriptView: View {
    @ObservedObject var model: MenuBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.statusText, systemImage: model.menuState.symbol).font(.headline)
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if model.transcriptLines.isEmpty {
                            Text("The live transcript appears here once a meeting is being transcribed.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.transcriptLines.enumerated()), id: \.offset) { index, line in
                            Text(line).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id(index)
                        }
                    }.padding(8)
                }
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Live transcript")
                .onChange(of: model.transcriptLines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            HStack {
                Button("Copy") { model.copyTranscript() }.disabled(model.transcriptLines.isEmpty)
                Button("Export…") { model.exportTranscript() }.disabled(model.transcriptLines.isEmpty)
                Spacer()
                if model.savedTranscriptURL != nil {
                    Button("Open transcript") { model.openTranscript() }
                    Button("Show in Finder") { model.revealTranscript() }
                }
            }
            if model.notesAvailable, model.savedTranscriptURL != nil {
                HStack {
                    switch model.notesStatus {
                    case .idle: Button("Create Standard German notes") { model.generateNotes() }
                    case .generating: ProgressView().controlSize(.small); Text("Creating notes…")
                    case .ready: Button("Open notes") { model.openNotes() }
                    case .failed(let message): Text(message).foregroundStyle(.red); Button("Try again") { model.generateNotes() }
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear { NSApp.activate(ignoringOtherApps: true) }
    }
}
