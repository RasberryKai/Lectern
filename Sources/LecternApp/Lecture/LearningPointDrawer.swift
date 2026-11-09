import LecternCore
import SwiftUI

/// Learning points the AI distilled from the chat, waiting above the composer for the student to keep or drop.
/// Slides up from behind the composer when new points land, collapses to a one-line count, and leaves once
/// every point is decided. Undecided points still count as included, so ignoring the drawer loses nothing.
struct LearningPointDrawer: View {
    @Bindable var model: LectureWindowModel
    @Binding var expanded: Bool
    @State private var listHeight: CGFloat = 0
    @State private var hovered: UUID?

    private var points: [LearningPoint] { model.newChatLearningPoints }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                Divider().overlay(Theme.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(points) { point in row(point) }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollIndicators(.automatic)
                .frame(height: min(listHeight, 196))
            }
        }
        // Extra bottom room tucks under the composer, so the drawer reads as sliding out from behind it.
        .padding(.bottom, 12)
        .background {
            UnevenRoundedRectangle(topLeadingRadius: 11, topTrailingRadius: 11).fill(Theme.inset)
        }
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: 11, topTrailingRadius: 11).strokeBorder(Theme.border)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, -12)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Button { withAnimation(.snappy(duration: 0.22)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "sparkles").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.ai)
                    Text("\(points.count)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.canvas)
                        .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16).background(Theme.ai, in: Capsule())
                    Text(points.count == 1 ? "new learning point" : "new learning points")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("for your cards").font(.system(size: 11.5)).foregroundStyle(Theme.quiet).lineLimit(1)
                    Spacer(minLength: 4)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Collapse" : "Show the learning points the AI noted for your cards")
            .accessibilityLabel("\(points.count) new learning points, \(expanded ? "expanded" : "collapsed")")
            if expanded {
                Button("Keep all") { Task { await model.keepChatLearningPoints(points.map(\.id)) } }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ai)
                    .help("Keep every point for the next Generate").disabled(model.readOnly)
            }
            Button { withAnimation(.snappy(duration: 0.22)) { expanded.toggle() } } label: {
                Image(systemName: "chevron.down").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.quiet)
                    .rotationEffect(.degrees(expanded ? 0 : 180)).frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityHidden(true)
        }
        .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8)
    }

    private func row(_ point: LearningPoint) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(point.text).font(Theme.small).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if !point.pages.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(point.pages.sorted(), id: \.self) { page in
                            Button("Slide \(page)") { model.openChatCitation("S", page) }
                                .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Theme.ai)
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Theme.aiWash, in: RoundedRectangle(cornerRadius: 4))
                                .help("Open slide \(page)")
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                decisionButton("checkmark", help: "Keep for your cards", tint: Theme.good) { await model.keepChatLearningPoints([point.id]) }
                decisionButton("xmark", help: "Drop this learning point", tint: Theme.bad) { await model.removeChatLearningPoint(point.id) }
            }
            .opacity(hovered == point.id ? 1 : 0.65)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovered == point.id ? Theme.surface.opacity(0.5) : .clear)
        .onHover { hovered = $0 ? point.id : (hovered == point.id ? nil : hovered) }
        .transition(.opacity)
    }

    private func decisionButton(_ symbol: String, help: String, tint: Color, action: @escaping () async -> Void) -> some View {
        Button { Task { await action() } } label: {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(DrawerIconButtonStyle(tint: tint))
        .help(help).accessibilityLabel(help).disabled(model.readOnly)
    }
}

private struct DrawerIconButtonStyle: ButtonStyle {
    let tint: Color
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering ? tint : Theme.quiet)
            .background(hovering ? Theme.surface : .clear, in: RoundedRectangle(cornerRadius: 5))
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onHover { hovering = $0 }
    }
}
