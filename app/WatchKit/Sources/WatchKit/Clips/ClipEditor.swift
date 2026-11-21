import SwiftUI
import WatchProtocol

/// The clip editor window: the last two minutes of a live channel, frozen, to
/// cut a clip from.
public struct ClipEditor: View {
    public static let windowID = "clip"

    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    private let channelID: String?

    @State private var model: ClipEditorModel?
    /// Who had the sound before the editor took it.
    @State private var wasListening: String?

    public init(channel: String?) {
        self.channelID = channel
    }

    public var body: some View {
        Group {
            if let model {
                ClipEditorContent(model: model, onSave: handleSave, onCancel: handleCancel)
            } else {
                ContentUnavailableView("No Channel", systemImage: "scissors")
            }
        }
        .frame(minWidth: 640, minHeight: 500)
        .task {
            await handleLoad()
        }
        .onDisappear {
            handleClose()
        }
    }

    private func handleLoad() async {
        guard model == nil, let channelID, let channel = state.session.channel(channelID) else { return }
        let model = ClipEditorModel(channel: channel)
        self.model = model

        // The editor has its own sound; two copies of a stream a couple of
        // minutes apart is hard to listen to.
        wasListening = state.listening
        state.listen(nil)

        await model.capture(from: state.streams[channelID]?.url)
    }

    private func handleSave() {
        guard let model else { return }
        Task {
            guard let url = await model.save(to: state.session) else { return }
            state.clipSaved(url)
            dismiss()
        }
    }

    private func handleCancel() {
        dismiss()
    }

    private func handleClose() {
        model?.close()
        if state.listening == nil, let wasListening, state.streams[wasListening] != nil {
            state.listen(wasListening)
        }
    }
}

private struct ClipEditorContent: View {
    @Bindable var model: ClipEditorModel
    let onSave: () -> Void
    let onCancel: () -> Void

    private var subtitle: String {
        switch model.phase {
        case .capturing:
            "Live · reading the last 2 minutes"
        case .failed:
            "Live"
        case .ready, .saving:
            if model.duration >= ClipEditorModel.reach - 10 {
                "Live · clipping from the last 2 minutes"
            } else {
                "Live · clipping from the last \(Int(model.duration.rounded())) seconds"
            }
        }
    }

    private enum Focus {
        case editor
        case name
    }

    /// Space and the arrow keys work the player while the editor itself has
    /// the focus, and type as usual while the name field does.
    @FocusState private var focus: Focus?

    private var isSaving: Bool {
        if case .saving = model.phase { return true }
        return false
    }

    var body: some View {
        VStack(spacing: .large) {
            VStack(spacing: .large) {
                preview
                ClipTimeline(model: model)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in focus = .editor })
            saveRow
        }
        .padding([.horizontal, .bottom], .large)
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .editor)
        .defaultFocus($focus, .editor)
        .onKeyPress(.space) {
            model.playToggle()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            model.scrub(to: model.playhead - 1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.scrub(to: model.playhead + 1)
            return .handled
        }
        .navigationTitle(model.channel.displayName)
        #if os(macOS)
        .navigationSubtitle(subtitle)
        // A window only stacks its subtitle under its title when it has a
        // toolbar, so this one has a toolbar with nothing in it.
        .toolbar {
            ToolbarItem {
                Color.clear.frame(width: 0, height: 0)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        #endif
    }

    private var preview: some View {
        ZStack {
            Color.black
            PlayerLayer(layer: model.layer, gravity: .resizeAspect)
            switch model.phase {
            case .capturing:
                ProgressView()
                    .controlSize(.large)
                    .colorScheme(.dark)
            case .failed(let message):
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                    Text("Couldn't read the stream")
                        .font(.headline)
                    Text(message)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .opacity(0.7)
                }
                .padding(.large)
                .foregroundStyle(.white)
            case .ready, .saving:
                EmptyView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var saveRow: some View {
        HStack(spacing: .medium) {
            TextField("Clip name", text: $model.name)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(.primary.opacity(0.04), in: Capsule())
                .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
                .focused($focus, equals: .name)
                .onSubmit(onSave)

            Group {
                if case .saving(let fraction) = model.phase {
                    ProgressView(value: fraction)
                        .frame(width: 80)
                } else if let error = model.saveError {
                    Text(error)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .help(error)
                } else if model.phase == .ready {
                    Text(model.length.clipLength)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, .medium)
            .frame(minWidth: 100, alignment: .leading)

            Button.cancel { onCancel() }
                .keyboardShortcut(.cancelAction)
            Button("Save Clip", action: onSave)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.phase != .ready || model.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .controlSize(.extraLarge)
        .buttonBorderShape(.capsule)
        .disabled(isSaving)
    }
}
