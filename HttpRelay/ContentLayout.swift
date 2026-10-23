import CoreGraphics

/// Rules that decide how the main screen is arranged.
///
/// The window can be any size: an iPhone in either orientation, the folded or
/// unfolded iPhone Duo, or an iPad. These rules only look at the space that is
/// actually available, never at the device, its idiom or its orientation.
enum ContentLayout {
    /// Width of the sidebar in the two column layout.
    static let sidebarWidth: CGFloat = 360
    /// Smallest width the log console gets in the two column layout.
    static let minLogColumnWidth: CGFloat = 320
    /// The log console never gets shorter than this.
    static let minLogHeight: CGFloat = 200
    /// Spacing between the blocks of the layout.
    static let blockSpacing: CGFloat = 16
    /// Padding around the layout.
    static let layoutPadding: CGFloat = 16

    /// Window width from which the two column layout fits: the padding around
    /// the layout, the sidebar, the spacing and a log console that is still
    /// wide enough to read.
    static let wideLayoutMinWidth: CGFloat =
        2 * layoutPadding + sidebarWidth + blockSpacing + minLogColumnWidth

    /// Whether the window is wide enough for a sidebar next to the log console.
    static func isWide(windowWidth: CGFloat) -> Bool {
        windowWidth >= wideLayoutMinWidth
    }

    /// Height the log console takes: the window height minus everything that
    /// is laid out above and below it, but never less than `minLogHeight`.
    static func logHeight(windowHeight: CGFloat, reservedHeight: CGFloat) -> CGFloat {
        max(minLogHeight, windowHeight - reservedHeight)
    }
}
