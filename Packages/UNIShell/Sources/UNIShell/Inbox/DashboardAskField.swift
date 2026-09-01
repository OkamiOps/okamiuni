import AppKit
import SwiftUI
import UNIDesign

/// Barra de pergunta do Dashboard: uma linha, no máximo quatro.
///
/// Return envia. Shift+Return insere `\n` e o campo cresce só o suficiente
/// para as linhas novas — nunca para preencher o cartão.
struct DashboardAskField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var textColor: NSColor
    var placeholderColor: NSColor
    var onSubmit: () -> Void
    var onEscape: () -> Void = {}

    static let lineHeight: CGFloat = 18
    static let minHeight: CGFloat = 22
    static let maxHeight: CGFloat = 76

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Shell {
        let text = AskTextView()
        text.delegate = context.coordinator
        text.coordinator = context.coordinator
        text.drawsBackground = false
        text.isRichText = false
        text.allowsUndo = true
        text.font = NSFont.systemFont(ofSize: 13)
        text.textColor = textColor
        text.insertionPointColor = textColor
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.lineFragmentPadding = 0
        text.minSize = NSSize(width: 0, height: Self.minHeight)
        text.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        text.textContainer?.size = NSSize(
            width: 100,
            height: CGFloat.greatestFiniteMagnitude
        )
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.string = self.text
        text.placeholder = placeholder
        text.placeholderColor = placeholderColor

        let scroll = Shell()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = text
        scroll.textView = text
        scroll.setContentHuggingPriority(.required, for: .vertical)
        scroll.setContentCompressionResistancePriority(.required, for: .vertical)

        context.coordinator.parent = self
        context.coordinator.shell = scroll
        return scroll
    }

    func updateNSView(_ scroll: Shell, context: Context) {
        context.coordinator.parent = self
        context.coordinator.shell = scroll
        guard let view = scroll.textView else { return }
        view.coordinator = context.coordinator
        view.textColor = textColor
        view.insertionPointColor = textColor
        view.placeholder = placeholder
        view.placeholderColor = placeholderColor
        if view.string != text {
            let selected = view.selectedRanges
            view.string = text
            if selected.count == 1,
               let range = selected.first as? NSRange,
               range.location <= (view.string as NSString).length {
                view.selectedRanges = selected
            }
        }
        scroll.invalidateIntrinsicContentSize()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DashboardAskField?
        weak var shell: Shell?

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent?.text = view.string
            shell?.invalidateIntrinsicContentSize()
            view.needsDisplay = true
        }

        func submit() { parent?.onSubmit() }
        func escape() { parent?.onEscape() }
    }

    final class Shell: NSScrollView {
        weak var textView: AskTextView?
        private var lastFitted: CGFloat = DashboardAskField.minHeight

        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: fittedHeight)
        }

        var fittedHeight: CGFloat {
            guard let view = textView, let container = view.textContainer else {
                return DashboardAskField.minHeight
            }
            view.layoutManager?.ensureLayout(for: container)
            let used = view.layoutManager?.usedRect(for: container).height ?? 0
            let padded = ceil(used) + 4
            return min(
                DashboardAskField.maxHeight,
                max(DashboardAskField.minHeight, padded)
            )
        }

        override func layout() {
            super.layout()
            guard let view = textView else { return }
            let width = max(contentSize.width, 1)
            if abs(view.frame.width - width) > 0.5 {
                view.frame.size.width = width
                view.textContainer?.size = NSSize(
                    width: width,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
            let height = fittedHeight
            hasVerticalScroller = height >= DashboardAskField.maxHeight - 0.5
            if abs(height - lastFitted) > 0.5 {
                lastFitted = height
                invalidateIntrinsicContentSize()
            }
        }
    }

    final class AskTextView: NSTextView {
        weak var coordinator: Coordinator?
        var placeholder = ""
        var placeholderColor: NSColor = .placeholderTextColor

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, !placeholder.isEmpty else { return }
            let rect = bounds.insetBy(dx: 0, dy: textContainerInset.height)
            placeholder.draw(
                in: rect,
                withAttributes: [
                    .font: font ?? NSFont.systemFont(ofSize: 13),
                    .foregroundColor: placeholderColor,
                ]
            )
        }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76 {
                if event.modifierFlags.contains(.shift) {
                    insertText("\n", replacementRange: selectedRange())
                    coordinator?.shell?.invalidateIntrinsicContentSize()
                    return
                }
                coordinator?.submit()
                return
            }
            super.keyDown(with: event)
        }

        override func cancelOperation(_ sender: Any?) {
            coordinator?.escape()
        }
    }
}
