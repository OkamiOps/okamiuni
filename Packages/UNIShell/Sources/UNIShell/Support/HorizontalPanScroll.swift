import AppKit
import SwiftUI

/// Faixa horizontal que anda com **clique-arraste** e com a roda.
///
/// A `ScrollView` do SwiftUI no macOS só ouve a roda. Esta peça não usa
/// `ScrollView`. O conteúdo é um `HStack` com `offset` dentro de um overlay
/// do tamanho **proposto pelo pai** — sem isto o `fixedSize` inflava a
/// coluna de Hoje e as cápsulas vazavam para o leitor.
struct DragScrollRail<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @State private var offset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0

    private var minOffset: CGFloat { min(0, viewportWidth - contentWidth) }

    var body: some View {
        // GeometryReader pega só a largura proposta pelo pai. Overlay de
        // `fixedSize` num `Color.clear` inflava a coluna e as cápsulas
        // vazavam para o leitor — em cima da divisória.
        GeometryReader { geo in
            content()
                .fixedSize(horizontal: true, vertical: true)
                .background {
                    GeometryReader { inner in
                        Color.clear.preference(
                            key: RailContentWidthKey.self, value: inner.size.width
                        )
                    }
                }
                .offset(x: offset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
                .clipped()
                .background {
                    RailPointerBridge(offset: $offset, minOffset: minOffset)
                }
                .preference(key: RailViewportWidthKey.self, value: geo.size.width)
        }
        .onPreferenceChange(RailContentWidthKey.self) { width in
            contentWidth = width
            clampOffset()
        }
        .onPreferenceChange(RailViewportWidthKey.self) { width in
            viewportWidth = width
            clampOffset()
        }
    }

    private func clampOffset() {
        let lo = minOffset
        if offset < lo { offset = lo }
        if offset > 0 { offset = 0 }
    }
}

private struct RailContentWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct RailViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Overlay transparente: o hit-test devolve `nil` para o clique chegar no
/// chip, e o monitor local vê o mesmo mouse.
private struct RailPointerBridge: NSViewRepresentable {
    @Binding var offset: CGFloat
    var minOffset: CGFloat

    func makeNSView(context: Context) -> RailPointerView {
        let view = RailPointerView()
        view.onOffset = { value in
            offset = value
        }
        return view
    }

    func updateNSView(_ view: RailPointerView, context: Context) {
        view.minOffset = minOffset
        view.offset = offset
        view.onOffset = { value in
            offset = value
        }
    }
}

final class RailPointerView: NSView, @unchecked Sendable {
    var offset: CGFloat = 0
    var minOffset: CGFloat = 0
    var onOffset: ((CGFloat) -> Void)?

    nonisolated(unsafe) private var monitor: Any?
    private var downX: CGFloat?
    private var offsetAtDown: CGFloat = 0
    private var dragging = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stop() : start()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if window != nil { start() }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    private func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .scrollWheel]
        ) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        downX = nil
        dragging = false
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, event.window === window else { return event }
        let loc = convert(event.locationInWindow, from: nil)

        switch event.type {
        case .leftMouseDown:
            guard bounds.contains(loc) else { return event }
            downX = event.locationInWindow.x
            offsetAtDown = offset
            dragging = false
            return event

        case .leftMouseDragged:
            guard let origin = downX else { return event }
            let dx = event.locationInWindow.x - origin
            if !dragging {
                guard abs(dx) >= 6 else { return event }
                dragging = true
            }
            apply(offsetAtDown + dx)
            return nil

        case .leftMouseUp:
            let swallow = dragging
            downX = nil
            dragging = false
            return swallow ? nil : event

        case .scrollWheel:
            guard bounds.contains(loc) else { return event }
            var dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard abs(dx) >= abs(dy), abs(dx) > 0.2 else { return event }
            if !event.hasPreciseScrollingDeltas { dx *= 12 }
            apply(offset - dx)
            return nil

        default:
            return event
        }
    }

    private func apply(_ value: CGFloat) {
        let next = min(0, max(minOffset, value))
        offset = next
        onOffset?(next)
    }
}
