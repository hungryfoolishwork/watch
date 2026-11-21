import SwiftUI
import WatchProtocol

/// The sheet for adding a channel: paste a link or a handle, and optionally
/// give it a friendlier name.
struct ChannelAdd: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss

    @State private var input = ""
    @State private var name = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    private var isEmpty: Bool {
        input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var caption: String {
        if let playlist = state.playlist {
            "A YouTube, Rumble, or Kick channel. It's added to your channels and to “\(playlist.name)”."
        } else {
            "A YouTube, Rumble, or Kick channel."
        }
    }

    var body: some View {
        VStack.leading(spacing: .large) {
            Text("Add Channel")
                .font(.headline)
            VStack.leading(spacing: .medium) {
                TextField("Channel", text: $input, prompt: Text("@handle, rumble:name, kick:name, or channel URL"))
                    .focused($focused)
                TextField("Name", text: $name, prompt: Text("Name (optional)"))
                Text(error ?? caption)
                    .font(.callout)
                    .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .onSubmit { handleAdd() }
            HStack {
                Spacer()
                Button.cancel { handleCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Add") { handleAdd() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { focused = true }
    }

    private func handleAdd() {
        guard !isEmpty else { return }
        do {
            try state.channelAdd(input: input, name: name)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handleCancel() {
        dismiss()
    }
}
