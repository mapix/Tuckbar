//
//  ControlItemImage.swift
//  Ice
//

import Cocoa

/// A Codable image for a control item.
enum ControlItemImage: Codable, Hashable {
    /// An image created from drawing code built into the app.
    case builtin(_ name: ImageBuiltinName)
    /// A system symbol image.
    case symbol(_ name: String)
    /// An image in an asset catalog.
    case catalog(_ name: String)
    /// An image stored as data.
    case data(_ data: Data)

    /// A Cocoa representation of this image.
    @MainActor
    func nsImage(for appState: AppState) -> NSImage? {
        switch self {
        case .builtin(let name):
            return switch name {
            case .chevronLarge: StaticBuiltins.Chevron.large
            case .chevronSmall: StaticBuiltins.Chevron.small
            case .tuckbarClosed: StaticBuiltins.Tuckbar.closed
            case .tuckbarOpen: StaticBuiltins.Tuckbar.open
            }
        case .symbol(let name):
            let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            image?.isTemplate = true
            return image
        case .catalog(let name):
            guard let originalImage = NSImage(named: name) else {
                return nil
            }
            let originalWidth = originalImage.size.width
            let originalHeight = originalImage.size.height
            let ratio = max(originalWidth / 25, originalHeight / 17)
            let newSize = CGSize(width: originalWidth / ratio, height: originalHeight / ratio)
            return originalImage.resized(to: newSize)
        case .data(let data):
            let image = NSImage(data: data)
            let generalSettingsManager = appState.settingsManager.generalSettingsManager
            image?.isTemplate = generalSettingsManager.customIceIconIsTemplate
            return image
        }
    }
}

extension ControlItemImage {
    /// A name for an image that is created from drawing code in the app.
    enum ImageBuiltinName: Codable, Hashable {
        /// A large chevron.
        case chevronLarge
        /// A small chevron.
        case chevronSmall
        /// Tuckbar signature two-layer mark (collapsed).
        case tuckbarClosed
        /// Tuckbar signature two-layer mark (expanded).
        case tuckbarOpen
    }
}

extension ControlItemImage {
    /// A namespace for static builtin images.
    ///
    /// - Note: We use the static properties `large` and `small` to avoid repeatedly
    ///   executing code every time ``nsImage(for:)`` is called.
    private enum StaticBuiltins {
        /// Tuckbar signature menu bar icon: a sleek top pill bar with a tucked secondary capsule/chevron beneath.
        enum Tuckbar {
            private static func make(expanded: Bool) -> NSImage {
                let size = CGSize(width: 18, height: 14)
                let image = NSImage(size: size, flipped: false) { _ in
                    NSColor.black.setFill()
                    NSColor.black.setStroke()

                    // Top primary menu bar capsule
                    let topBar = NSBezierPath(roundedRect: CGRect(x: 1.5, y: 9.2, width: 15.0, height: 3.2), xRadius: 1.6, yRadius: 1.6)
                    topBar.fill()

                    if expanded {
                        // Expanded secondary shelf outline with two inner dots
                        let shelf = NSBezierPath(roundedRect: CGRect(x: 3.0, y: 1.6, width: 12.0, height: 5.4), xRadius: 2.2, yRadius: 2.2)
                        shelf.lineWidth = 1.4
                        shelf.stroke()
                        NSBezierPath(ovalIn: CGRect(x: 5.8, y: 3.3, width: 2.0, height: 2.0)).fill()
                        NSBezierPath(ovalIn: CGRect(x: 10.2, y: 3.3, width: 2.0, height: 2.0)).fill()
                    } else {
                        // Sleek downward tuck chevron + subtle drawer lip beneath the top bar
                        let chev = NSBezierPath()
                        chev.move(to: CGPoint(x: 5.5, y: 5.8))
                        chev.line(to: CGPoint(x: 9.0, y: 2.5))
                        chev.line(to: CGPoint(x: 12.5, y: 5.8))
                        chev.lineWidth = 1.85
                        chev.lineCapStyle = .round
                        chev.lineJoinStyle = .round
                        chev.stroke()
                    }
                    return true
                }
                image.isTemplate = true
                return image
            }

            static let closed = make(expanded: false)
            static let open = make(expanded: true)
        }

        /// A namespace for static builtin chevron images.
        enum Chevron {
            /// Creates a chevron image with the given size and line width.
            private static func chevron(size: CGSize, lineWidth: CGFloat) -> NSImage {
                let image = NSImage(size: size, flipped: false) { bounds in
                    let insetBounds = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
                    let path = NSBezierPath()
                    path.move(to: CGPoint(x: (insetBounds.midX + insetBounds.maxX) / 2, y: insetBounds.maxY))
                    path.line(to: CGPoint(x: (insetBounds.minX + insetBounds.midX) / 2, y: insetBounds.midY))
                    path.line(to: CGPoint(x: (insetBounds.midX + insetBounds.maxX) / 2, y: insetBounds.minY))
                    path.lineWidth = lineWidth
                    path.lineCapStyle = .butt
                    NSColor.black.setStroke()
                    path.stroke()
                    return true
                }
                image.isTemplate = true
                return image
            }

            /// A large chevron.
            static let large = chevron(size: CGSize(width: 12, height: 12), lineWidth: 2)

            /// A small chevron.
            static let small = chevron(size: CGSize(width: 9, height: 9), lineWidth: 2)
        }
    }
}
