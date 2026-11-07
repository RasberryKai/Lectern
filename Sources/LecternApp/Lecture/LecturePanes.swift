import AppKit
import LecternCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum LectureSideTab: String { case content, chat }

/// Independent layouts for the thumbnail workspace and the wider review list.
@Observable final class LecturePaneState {
    var prepareLeft: Double = UserDefaults.standard.object(forKey: "v2.prepare.left") as? Double ?? 210
    var prepareRight: Double = UserDefaults.standard.object(forKey: "v2.prepare.right") as? Double ?? 400
    var reviewLeft: Double = UserDefaults.standard.object(forKey: "v2.review.left") as? Double ?? 260
    var reviewRight: Double = UserDefaults.standard.object(forKey: "v2.review.right") as? Double ?? 400
    var focusedDivider: PaneSide?
    var reviewLeftVisible = true
    private var prepareTab = LectureSideTab(rawValue: UserDefaults.standard.string(forKey: "v2.prepare.tab") ?? "content") ?? .content
    private var reviewTab = LectureSideTab(rawValue: UserDefaults.standard.string(forKey: "v2.review.tab") ?? "content") ?? .content

    func tab(for mode: LectureMode) -> LectureSideTab { mode == .prepare ? prepareTab : reviewTab }
    func setTab(_ tab: LectureSideTab, for mode: LectureMode) {
        if mode == .prepare { prepareTab = tab } else { reviewTab = tab }
        UserDefaults.standard.set(tab.rawValue, forKey: "v2.\(mode == .prepare ? "prepare" : "review").tab")
    }
    func openChat(_ mode: LectureMode) { setTab(.chat, for: mode) }
    func width(_ side: PaneSide, mode: LectureMode) -> Double {
        mode == .prepare ? (side == .left ? prepareLeft : prepareRight) : (side == .left ? reviewLeft : reviewRight)
    }
    func resize(_ side: PaneSide, mode: LectureMode, width: Double) {
        let value = min(max(width, side == .left ? 150 : 300), side == .left ? 420 : 680)
        if mode == .prepare {
            if side == .left { prepareLeft = value } else { prepareRight = value }
        } else {
            if side == .left { reviewLeft = value } else { reviewRight = value }
        }
        UserDefaults.standard.set(value, forKey: "v2.\(mode == .prepare ? "prepare" : "review").\(side.rawValue)")
    }
}

nonisolated enum PaneSide: String { case left, right }

struct LecturePanes<Left: View, Stage: View, Right: View>: View {
    @Bindable var model: LectureWindowModel
    @ViewBuilder let left: () -> Left
    @ViewBuilder let stage: () -> Stage
    @ViewBuilder let right: () -> Right

    private var leftVisible: Bool { model.mode == .prepare ? model.thumbnailsVisible : model.panes.reviewLeftVisible }

    var body: some View {
        GeometryReader { geometry in
            let available = max(360, geometry.size.width)
            let showLeft = leftVisible && available >= 516
            let showRight = model.askVisible && available >= (showLeft ? 822 : 666)
            let budget = available - 360 - (showLeft ? 6 : 0) - (showRight ? 6 : 0)
            let desiredLeft = model.panes.width(.left, mode: model.mode)
            let desiredRight = model.panes.width(.right, mode: model.mode)
            let rightWidth = showRight ? min(desiredRight, max(300, budget - (showLeft ? 150 : 0))) : 0
            let leftWidth = showLeft ? min(desiredLeft, max(150, budget - rightWidth)) : 0
            HStack(spacing: 0) {
                if showLeft {
                    left().frame(width: leftWidth).background(Theme.sidebar)
                    divider(.left, displayedWidth: leftWidth, maximum: budget - rightWidth)
                }
                stage().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                if showRight {
                    divider(.right, displayedWidth: rightWidth, maximum: budget - leftWidth)
                    right().frame(width: rightWidth).background(Theme.canvas)
                }
            }
        }
    }

    private func divider(_ side: PaneSide, displayedWidth: Double, maximum: Double) -> some View {
        PaneDivider(side: side, width: displayedWidth, maximum: maximum, defaultWidth: side == .left ? (model.mode == .prepare ? 210 : 260) : 400) { width in
            model.panes.resize(side, mode: model.mode, width: width)
        } focusChanged: { active in
            model.panes.focusedDivider = active ? side : nil
        } collapse: {
            if side == .right { model.askVisible = false }
            else if model.mode == .prepare { model.thumbnailsVisible = false }
            else { model.panes.reviewLeftVisible = false }
        }
    }
}

private struct PaneDivider: View {
    let side: PaneSide
    let width: Double
    let maximum: Double
    let defaultWidth: Double
    let resize: (Double) -> Void
    let focusChanged: (Bool) -> Void
    let collapse: () -> Void
    @State private var dragStart: Double?
    @FocusState private var focused: Bool

    private var minimum: Double { side == .left ? 150 : 300 }

    var body: some View {
        Rectangle().fill(Color.clear)
            .frame(width: 6)
            .overlay { Rectangle().fill(Theme.border).frame(width: 1) }
            .contentShape(Rectangle())
            .focusable().focusEffectDisabled().focused($focused)
            .onChange(of: focused) { _, value in focusChanged(value) }
            .onDisappear { focusChanged(false) }
            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { value in
                if dragStart == nil { dragStart = width }
                let proposed = (dragStart ?? width) + value.translation.width * (side == .left ? 1 : -1)
                resize(min(maximum, max(minimum, proposed)))
            }.onEnded { value in
                let proposed = (dragStart ?? width) + value.translation.width * (side == .left ? 1 : -1)
                if proposed < minimum * 0.55 {
                    resize(dragStart ?? width)
                    collapse()
                }
                dragStart = nil
            })
            .onTapGesture(count: 2) { resize(min(maximum, defaultWidth)) }
            .onKeyPress(.leftArrow) { resize(min(maximum, width + (side == .left ? -16 : 16))); return .handled }
            .onKeyPress(.rightArrow) { resize(min(maximum, width + (side == .left ? 16 : -16))); return .handled }
            .accessibilityLabel("Resize \(side.rawValue) pane")
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in resize(min(maximum, width + (direction == .increment ? 16 : -16))) }
            .help("Drag to resize · double-click to reset · arrow keys resize")
    }
}

struct ShortcutKey: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.quiet)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.borderStrong))
    }
}

/// The content tab and chat share the same space in both workspaces.
struct LectureSidePanel: View {
    @Bindable var model: LectureWindowModel
    var focus: FocusState<EditorField?>.Binding
    @State private var imageDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tab(.chat, title: "Ask Claude", icon: "sparkles")
                tab(.content, title: model.mode == .prepare ? "Cards" : "Slide", icon: model.mode == .prepare ? "rectangle.on.rectangle" : "display")
                Spacer(minLength: 0)
                ChatHistoryControls(model: model)
            }
            .padding(.horizontal, 10).padding(.top, 8)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
            if !model.readOnly {
                Label(model.isImportingChatImages ? "Preparing images…" : (imageDropTargeted ? "Drop images to add to chat" : "Drop images anywhere in this pane"), systemImage: "photo.badge.plus")
                    .font(Theme.caption).foregroundStyle(imageDropTargeted ? Theme.ai : Theme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(imageDropTargeted ? Theme.aiWash : .clear)
            }
            if model.panes.tab(for: model.mode) != .chat, let error = model.chatAttachmentError {
                HStack(alignment: .top) {
                    Text(error).font(Theme.caption).foregroundStyle(Theme.bad)
                    Spacer(minLength: 4)
                    Button { model.chatAttachmentError = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                        .buttonStyle(.plain).help("Dismiss attachment error")
                }.padding(10)
            }
            if model.panes.tab(for: model.mode) == .chat {
                AskPanel(model: model, page: model.mode == .prepare ? (model.focusedPage ?? 0) : (model.selectedCard?.sourcePages.first ?? 0), cardID: model.mode == .review ? model.selectedCardID : nil, focus: focus)
            } else if model.mode == .prepare {
                PrepareCardsPane(model: model)
            } else {
                ReviewSourcePane(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onDrop(of: model.canAttachChatImages ? [UTType.fileURL.identifier, UTType.image.identifier] : [], isTargeted: $imageDropTargeted) { providers in
            guard model.canAttachChatImages, !providers.isEmpty else { return false }
            imageDropTargeted = false
            Task {
                if await model.importChatImageProviders(providers) {
                    model.panes.openChat(model.mode)
                    focus.wrappedValue = .ask
                }
            }
            return true
        }
        .overlay {
            if imageDropTargeted && model.canAttachChatImages {
                RoundedRectangle(cornerRadius: 10).fill(Theme.aiWash.opacity(0.4))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.ai, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                    .padding(6).allowsHitTesting(false)
            }
        }
    }

    private func tab(_ value: LectureSideTab, title: String, icon: String) -> some View {
        let active = model.panes.tab(for: model.mode) == value
        return Button {
            model.panes.setTab(value, for: model.mode)
            if value == .chat { focus.wrappedValue = .ask }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12))
                Text(title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1).fixedSize()
                if value == .chat { ShortcutKey(text: "⌘⇧A") }
                else {
                    if model.mode == .prepare { Text("\(model.cards(from: model.focusedPage ?? 0).count)").font(Theme.caption).foregroundStyle(Theme.faint) }
                    ShortcutKey(text: "⌘⇧S")
                }
            }
            .foregroundStyle(active ? Theme.ink : Theme.quiet)
            .padding(.horizontal, 7).padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(active ? Theme.ink : .clear).frame(height: 2) }
        }
        .buttonStyle(.plain)
        .help(value == .chat ? "Toggle AI chat · ⌘⇧A" : "Toggle \(model.mode == .prepare ? "cards" : "source slide") · ⌘⇧S")
    }
}
