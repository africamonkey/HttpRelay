import Testing
import SwiftUI
import UIKit
@testable import HttpRelay

/// The iPhone Duo can be used folded (outer display) or unfolded (inner
/// display), in either orientation, and the window changes size while the app
/// is running. The main screen therefore has to lay out from the space that is
/// actually available, never from a fixed size.
@Suite("iPhone Duo layout")
struct DuoLayoutTests {

    /// Window sizes the app has to cope with, in points.
    private static let screenSizes: [(name: String, size: CGSize)] = [
        ("iPhone portrait", CGSize(width: 402, height: 874)),
        ("iPhone landscape", CGSize(width: 874, height: 402)),
        ("Duo folded", CGSize(width: 466, height: 678)),
        ("Duo unfolded portrait", CGSize(width: 669, height: 951)),
        ("Duo unfolded landscape", CGSize(width: 951, height: 669))
    ]

    @Test func twoColumnLayout_startsWhereThereIsRoomForIt() {
        #expect(!ContentLayout.isWide(windowWidth: 402), "iPhone portrait stays single column")
        #expect(!ContentLayout.isWide(windowWidth: 466), "folded Duo stays single column")
        #expect(!ContentLayout.isWide(windowWidth: 669), "unfolded Duo in portrait stays single column")
        #expect(ContentLayout.isWide(windowWidth: 744), "iPad uses the two column layout")
        #expect(ContentLayout.isWide(windowWidth: 951), "unfolded Duo in landscape uses the two column layout")
    }

    @Test func logConsole_takesTheSpaceThatIsLeftOver() {
        // Tall window: the console fills whatever the other blocks leave.
        #expect(ContentLayout.logHeight(windowHeight: 951, reservedHeight: 340) == 611)
        // Short window: the console keeps its minimum and the page scrolls
        // instead of clipping the content.
        #expect(ContentLayout.logHeight(windowHeight: 402, reservedHeight: 340) == ContentLayout.minLogHeight)
    }

    @Test @MainActor func mainScreen_laysOutAtEveryDuoSize() async throws {
        for screen in Self.screenSizes {
            let layout = try MainScreenLayout.make(size: screen.size)
            let usable = layout.usableHeight

            // Nothing is clipped at the trailing edge: the content never needs
            // more width than the window has.
            #expect(
                layout.contentSize.width <= layout.pageFrame.width + 0.5,
                "\(screen.name): the content is \(layout.contentSize.width)pt wide, the window is \(screen.size.width)pt"
            )

            // The log console is never squeezed away.
            #expect(
                layout.consoleHeight >= ContentLayout.minLogHeight - 0.5,
                "\(screen.name): the log console is only \(layout.consoleHeight)pt tall"
            )

            // Either the page fills the window exactly - which means the log
            // console took the space the other blocks left over - or the window
            // is too short for that, the console sits at its minimum and the
            // page scrolls.
            let consoleAtMinimum = layout.consoleHeight <= ContentLayout.minLogHeight + 0.5
            if consoleAtMinimum {
                #expect(
                    layout.contentSize.height >= usable - 1,
                    "\(screen.name): the content is \(layout.contentSize.height)pt tall in \(usable)pt of space, the log console is at its minimum"
                )
            } else {
                #expect(
                    abs(layout.contentSize.height - usable) < 1,
                    "\(screen.name): the content is \(layout.contentSize.height)pt tall in \(usable)pt of space, the log console is \(layout.consoleHeight)pt tall"
                )
            }
        }
    }
}

/// The laid out main screen, measured from the view hierarchy.
private struct MainScreenLayout {
    /// The scroll view the page scrolls in.
    let page: UIScrollView
    /// The scroll view of the log console.
    let console: UIScrollView

    var pageFrame: CGRect { page.frame }
    var contentSize: CGSize { page.contentSize }
    /// The height the page can use: the window minus the bars around it.
    var usableHeight: CGFloat {
        page.frame.height - page.adjustedContentInset.top - page.adjustedContentInset.bottom
    }
    var consoleHeight: CGFloat { console.frame.height }

    /// Lays the main screen out in a window of the given size.
    ///
    /// The window is backed by a window scene, otherwise the layout never
    /// settles: without a scene the navigation stack does not reserve room for
    /// its bars, and the second layout pass that carries the measured heights
    /// is never run.
    @MainActor
    static func make(size: CGSize) throws -> MainScreenLayout {
        let host = UIHostingController(rootView: ContentView())
        let window = UIWindow(windowScene: try scene())
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = host
        window.makeKeyAndVisible()

        // The measured heights arrive one layout pass later, so run a few.
        for _ in 0..<4 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let scrolls = scrollViews(in: host.view)
        guard let page = scrolls.first else {
            Issue.record("the main screen does not scroll")
            throw LayoutError.noPage
        }
        // The log console is the only scroll view whose content is not wider
        // than the view itself; the filter chips scroll sideways.
        guard let console = scrolls.first(where: { $0 !== page && $0.contentSize.width <= $0.bounds.width + 1 }) else {
            Issue.record("the log console was not found")
            throw LayoutError.noConsole
        }
        return MainScreenLayout(page: page, console: console)
    }

    private enum LayoutError: Error {
        case noPage
        case noConsole
    }

    @MainActor
    private static func scene() throws -> UIWindowScene {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw LayoutError.noPage
        }
        return scene
    }

    private static func scrollViews(in view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        if let scroll = view as? UIScrollView { found.append(scroll) }
        for subview in view.subviews {
            found.append(contentsOf: scrollViews(in: subview))
        }
        return found
    }
}
