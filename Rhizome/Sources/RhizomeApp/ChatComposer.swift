import AppKit
import SwiftUI
import RhizomeCore

struct ChatComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    @Binding var isFocused: Bool

    let placeholder: String
    let font: NSFont
    let textColor: NSColor
    let placeholderColor: NSColor
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScroller = ThinScroller()

        let textView = ChatComposerTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if let container = textView.textContainer {
            container.widthTracksTextView = true
            container.heightTracksTextView = false
            container.lineFragmentPadding = 0
            container.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.placeholderText = placeholder
        textView.placeholderColor = placeholderColor
        textView.onSubmit = onSubmit
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ChatComposerTextView else { return }
        context.coordinator.parent = self

        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            let utf16Count = text.utf16.count
            let safeLocation = min(selected.location, utf16Count)
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
        }
        if textView.font != font {
            textView.font = font
        }
        if textView.textColor != textColor {
            textView.textColor = textColor
            textView.insertionPointColor = textColor
        }
        textView.placeholderText = placeholder
        textView.placeholderColor = placeholderColor
        textView.onSubmit = onSubmit

        DispatchQueue.main.async {
            context.coordinator.recomputeHeight()
        }

        if isFocused,
           let window = textView.window,
           window.firstResponder !== textView {
            DispatchQueue.main.async {
                window.makeFirstResponder(textView)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatComposer
        weak var textView: ChatComposerTextView?

        init(_ parent: ChatComposer) {
            self.parent = parent
        }

        nonisolated func textDidChange(_ notification: Notification) {
            MainActor.assumeIsolated {
                guard let textView else { return }
                if parent.text != textView.string {
                    parent.text = textView.string
                }
                recomputeHeight()
            }
        }

        nonisolated func textDidBeginEditing(_ notification: Notification) {
            MainActor.assumeIsolated {
                if !parent.isFocused {
                    parent.isFocused = true
                }
            }
        }

        nonisolated func textDidEndEditing(_ notification: Notification) {
            MainActor.assumeIsolated {
                if parent.isFocused {
                    parent.isFocused = false
                }
            }
        }

        func recomputeHeight() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            let activeFont = textView.font ?? NSFont.systemFont(ofSize: 13)
            let lineHeight = layoutManager.defaultLineHeight(for: activeFont)
            let measured = max(used.height, lineHeight)
            if abs(parent.contentHeight - measured) > 0.5 {
                parent.contentHeight = measured
            }
        }
    }
}

final class ThinScroller: NSScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        return 12
    }

    override class var isCompatibleWithOverlayScrollers: Bool { true }
}

final class ChatComposerTextView: NSTextView {
    var placeholderText: String = ""
    var placeholderColor: NSColor = .placeholderTextColor
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && event.modifierFlags.contains(.command) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderText.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: placeholderColor
        ]
        let attributed = NSAttributedString(string: placeholderText, attributes: attrs)
        let inset = textContainerInset
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: inset.width + padding, y: inset.height)
        attributed.draw(at: origin)
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { needsDisplay = true }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { needsDisplay = true }
        return result
    }
}

extension AppFont {
    func nsFont(size: CGFloat) -> NSFont {
        switch self {
        case .mono:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .sans:
            return .systemFont(ofSize: size)
        case .serif:
            let base = NSFont.systemFont(ofSize: size)
            if let descriptor = base.fontDescriptor.withDesign(.serif),
               let serifFont = NSFont(descriptor: descriptor, size: size) {
                return serifFont
            }
            return base
        }
    }
}
