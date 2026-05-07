import AppKit
import SwiftUI

extension View {
    func overlayScrollers() -> some View {
        background(OverlayScrollerEnforcer())
    }
}

private struct OverlayScrollerEnforcer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ScrollerEnforcerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ScrollerEnforcerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyStyle()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            applyStyle()
        }

        private func applyStyle() {
            DispatchQueue.main.async { [weak self] in
                guard let scrollView = self?.enclosingScrollView else { return }
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
            }
        }
    }
}
