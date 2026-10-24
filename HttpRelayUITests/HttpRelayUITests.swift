//
//  HttpRelayUITests.swift
//  HttpRelayUITests
//
//  Created by Africamonkey on 2026/4/23.
//

import XCTest
import Network

final class HttpRelayUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    /// Turning the toggle on has to start a proxy that actually answers.
    ///
    /// The listener is created on a background queue, so the screen reacts
    /// before the server is up. This test waits until the screen shows the
    /// device's IP address - which only happens once the listener is up -
    /// and then talks to the proxy.
    @MainActor
    func testToggleStartsAProxyThatAnswers() throws {
        let app = XCUIApplication()
        // The setup guide would cover the screen; it is not part of this test.
        app.launchArguments = ["-showTutorial", "NO"]
        app.launch()

        let toggle = app.switches["Enable Debugger Server"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "the toggle never appeared")

        // The port the app is about to listen on.
        let port = try proxyPort(in: app)
        toggle.tap()

        // The IP address is only published once the listener is up, so this
        // is the point where the server is really running. The "Running"
        // label cannot be used for this: it is set optimistically, before
        // the listener even exists.
        let ip = try waitForPublishedIP(in: app)

        let reply = try connectAndReadCONNECTReply(port: port)
        // The proxy answers a CONNECT to a closed port with "502 Bad
        // Gateway". Any other proxy on this port would answer differently,
        // so this also proves that the app's own proxy is the one that
        // answered and not something else that happens to listen on the
        // same port.
        XCTAssertTrue(
            reply.hasPrefix("HTTP/1.1 502"),
            "the proxy answered \(reply), expected a 502 from the app's proxy at \(ip)"
        )
    }

    /// The setup guide is presented once the server is up, not while the
    /// user is tapping the toggle.
    @MainActor
    func testSetupGuideAppearsWhenTheServerIsUp() throws {
        let app = XCUIApplication()
        app.launch()

        let toggle = app.switches["Enable Debugger Server"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "the toggle never appeared")
        toggle.tap()

        let done = app.buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 30), "the setup guide never appeared")
    }

    /// The setup guide stays away when it is switched off in the settings.
    @MainActor
    func testSetupGuideStaysAwayWhenItIsSwitchedOff() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-showTutorial", "NO"]
        app.launch()

        let toggle = app.switches["Enable Debugger Server"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 30), "the toggle never appeared")
        toggle.tap()

        // Wait until the server is up, then make sure no guide is covering
        // the screen.
        _ = try waitForPublishedIP(in: app)
        XCTAssertFalse(
            app.buttons["Done"].exists,
            "the setup guide appeared although it is switched off"
        )
    }

    /// The port the app listens on, read from the port field.
    private func proxyPort(in app: XCUIApplication) throws -> UInt16 {
        let field = app.textFields["Port"]
        XCTAssertTrue(field.waitForExistence(timeout: 30), "the port field never appeared")
        let text = (field.value as? String) ?? ""
        guard let port = UInt16(text) else {
            XCTFail("the port field does not hold a port number, it holds '\(text)'")
            throw XCTSkip("no port")
        }
        return port
    }

    /// Waits until the screen shows an IP address instead of the "—"
    /// placeholder, which the app only does once the listener is up.
    private func waitForPublishedIP(in app: XCUIApplication) throws -> String {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let texts = app.staticTexts.allElementsBoundByIndex
            if let index = texts.firstIndex(where: { $0.label == "IP:" }),
               index + 1 < texts.count {
                let ip = texts[index + 1].label
                if ip != "—" && !ip.isEmpty {
                    return ip
                }
            }
            usleep(200_000)
        }
        XCTFail("the server never published an IP address")
        throw XCTSkip("no IP")
    }

    /// Sends an HTTP CONNECT request to the proxy and returns the status line.
    private func connectAndReadCONNECTReply(port: UInt16) throws -> String {
        let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = expectation(description: "connection ready")
        connection.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        connection.start(queue: .global())
        wait(for: [ready], timeout: 10)
        defer { connection.cancel() }

        let request = "CONNECT 127.0.0.1:1 HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let sent = expectation(description: "request sent")
        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in
            sent.fulfill()
        })
        wait(for: [sent], timeout: 10)

        let reply = expectation(description: "reply received")
        var received = Data()
        connection.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, isComplete, error in
            if let data { received = data }
            if error != nil || isComplete || received.count > 0 { reply.fulfill() }
        }
        wait(for: [reply], timeout: 10)

        return String(data: received.prefix(64), encoding: .utf8) ?? ""
    }
}
