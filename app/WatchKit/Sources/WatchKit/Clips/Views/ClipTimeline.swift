import SwiftUI

/// The clip editor's timeline: a filmstrip of the stretch on offer, yellow
/// handles marking where the clip starts and ends, and a playhead.
///
/// Drag a handle to trim; drag anywhere else to move the playhead.
struct ClipTimeline: View {
    let model: ClipEditorModel

    private static let handleWidth: CGFloat = 14
    private static let stripHeight: CGFloat = 44
    private static let yellow = Color.hex(0xFFD60A)

    private enum Target {
        case start
        case end
        case playhead
    }

    /// What the drag in progress took hold of.
    @State private var target: Target?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill") {
                handlePlay()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(PlayButtonStyle())
            .padding(.top, 6)

            VStack(spacing: 8) {
                GeometryReader { geo in
                    strip(width: geo.size.width)
                }
                .frame(height: Self.stripHeight)
                GeometryReader { geo in
                    labels(width: geo.size.width)
                }
                .frame(height: 14)
            }
            // The handles hang off the ends of the strip; leave them room.
            .padding(.horizontal, Self.handleWidth)
        }
        .disabled(model.phase != .ready)
    }

    // MARK: Strip

    private func strip(width: CGFloat) -> some View {
        let scale = model.duration > 0 ? width / model.duration : 0
        let startX = model.start * scale
        let endX = model.end * scale
        let playheadX = model.playhead * scale

        return ZStack(alignment: .topLeading) {
            filmstrip
                .frame(width: width, height: Self.stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if model.duration > 0 {
                // Everything outside the clip is washed out.
                Group {
                    UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                        .frame(width: max(0, startX))
                    UnevenRoundedRectangle(bottomTrailingRadius: 8, topTrailingRadius: 8)
                        .frame(width: max(0, width - endX))
                        .offset(x: endX)
                }
                .foregroundStyle(.background.opacity(0.65))
                .frame(height: Self.stripHeight)

                // The frame around the clip: a bar along the top and bottom, and
                // a handle at each end.
                Group {
                    Rectangle()
                        .frame(width: max(0, endX - startX), height: 3)
                        .offset(x: startX)
                    Rectangle()
                        .frame(width: max(0, endX - startX), height: 3)
                        .offset(x: startX, y: Self.stripHeight - 3)
                    handle(leading: true)
                        .offset(x: startX - Self.handleWidth)
                    handle(leading: false)
                        .offset(x: endX)
                }
                .foregroundStyle(Self.yellow)

                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: Self.stripHeight + 6)
                    .shadow(color: .black.opacity(0.4), radius: 1.5)
                    .offset(x: playheadX - 1.5, y: -3)
            }
        }
        .frame(width: width, height: Self.stripHeight, alignment: .topLeading)
        .contentShape(Rectangle().inset(by: -Self.handleWidth))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    handleDrag(value, startX: startX, endX: endX, scale: scale)
                }
                .onEnded { _ in
                    target = nil
                }
        )
    }

    private var filmstrip: some View {
        HStack(spacing: 1) {
            ForEach(model.thumbnails.indices, id: \.self) { index in
                Color.gray.opacity(0.35)
                    .overlay {
                        if let image = model.thumbnails[index] {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .transition(.opacity)
                        }
                    }
                    .clipped()
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.thumbnails.map { $0 != nil })
    }

    private func handle(leading: Bool) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: leading ? 8 : 0,
            bottomLeadingRadius: leading ? 8 : 0,
            bottomTrailingRadius: leading ? 0 : 8,
            topTrailingRadius: leading ? 0 : 8)
            .frame(width: Self.handleWidth, height: Self.stripHeight)
            .overlay {
                Capsule()
                    .fill(.black.opacity(0.5))
                    .frame(width: 2, height: 14)
            }
    }

    // MARK: Labels

    /// Five marks from the far end to "Now", each centered on its quarter of
    /// the strip except the two at the ends.
    private func labels(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<5) { index in
                let fraction = Double(index) / 4
                let text = index == 4 ? "Now" : "−" + (model.duration * (1 - fraction)).clock
                Text(text)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    // A frame with no width pins the text by one edge or by
                    // its middle, whichever the mark calls for.
                    .frame(width: 0, alignment: index == 0 ? .leading : index == 4 ? .trailing : .center)
                    .offset(x: width * fraction)
            }
        }
        .frame(width: width, alignment: .leading)
        .opacity(model.duration > 0 ? 1 : 0)
    }

    // MARK: Actions

    private func handlePlay() {
        model.playToggle()
    }

    private func handleDrag(_ value: DragGesture.Value, startX: CGFloat, endX: CGFloat, scale: CGFloat) {
        guard scale > 0 else { return }
        if target == nil {
            // A handle is easier to catch if it reaches a little past its edges.
            let x = value.startLocation.x
            if (startX - Self.handleWidth - 4...startX + 4).contains(x) {
                target = .start
            } else if (endX - 4...endX + Self.handleWidth + 4).contains(x) {
                target = .end
            } else {
                target = .playhead
            }
        }
        let seconds = value.location.x / scale
        switch target {
        case .start: model.setStart(seconds)
        case .end: model.setEnd(seconds)
        case .playhead: model.scrub(to: seconds)
        case nil: break
        }
    }
}

private struct PlayButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(.primary.opacity(isEnabled ? 0.85 : 0.3))
            .frame(width: 32, height: 32)
            .background(.primary.opacity(configuration.isPressed ? 0.12 : 0.06), in: Circle())
            .contentShape(Circle())
    }
}
