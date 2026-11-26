import AgySwitchCore
@testable import AgySwitch
@testable import AgySwitchUI
import AppKit
import Combine
import SwiftUI
import XCTest

final class MenuPopoverTests: XCTestCase {
    @MainActor
    func testTwoSecondSignInPollStopsWhenHiddenAndAfterLogin() {
        let model = MenuModel()
        model.signInStarted = true
        model.showsAddAccount = true
        var polls = 0
        model.send = { [weak model] action in
            guard case .checkLogin = action else { return XCTFail("Expected a silent login check") }
            polls += 1
            XCTAssertEqual(model?.busy, false)
            model?.updatePool(PoolSnapshot(currentEmail: "new@example.com"))
        }
        model.setPopoverVisible(true)
        model.setPopoverVisible(false)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.4))
        XCTAssertEqual(polls, 0)
        model.setPopoverVisible(true)
        model.setPopoverVisible(true)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        XCTAssertEqual(polls, 0)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.2))
        XCTAssertEqual(polls, 1)
        XCTAssertEqual(model.unsavedEmail, "new@example.com")
        XCTAssertFalse(model.showsAddAccount)
        XCTAssertFalse(model.signInStarted)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2.4))
        XCTAssertEqual(polls, 1)
    }

    @MainActor func testHoverOnlyHighlightsTheCurrentRow() {
        let model = MenuModel()
        model.send = { _ in XCTFail("Hover should not send a menu action") }
        model.hover("a", inside: true)
        XCTAssertEqual(model.hoveredAccount, "a")
        model.hover("b", inside: true)
        model.hover("a", inside: false)
        XCTAssertEqual(model.hoveredAccount, "b")
        model.hover("b", inside: false)
        XCTAssertNil(model.hoveredAccount)
        model.hover("a", inside: true)
        model.clearHover()
        XCTAssertNil(model.hoveredAccount)
        XCTAssertNil(model.feedback)
    }

    func testReturningFromLoginShowsSaveEvenWhenSnapshotIsUnchangedAndErrorsRecover() {
        let signedOut = PoolSnapshot()
        let fresh = PoolSnapshot(currentEmail: "new@example.com")
        let model = MenuModel(pool: signedOut)
        for _ in 0..<2 {
            model.showsAddAccount = true
            model.signInStarted = true
            model.reportRefreshFailure(AppError.invalidCredential)
            XCTAssertEqual(model.refreshError, .invalidCredential)
            model.updatePool(fresh)
            XCTAssertNil(model.refreshError)
            XCTAssertEqual(model.unsavedEmail, fresh.currentEmail)
            XCTAssertFalse(model.showsAddAccount)
            XCTAssertFalse(model.signInStarted)
            XCTAssertFalse(model.busy)
        }
        model.reportRefreshFailure(AppError.keychainRead)
        XCTAssertEqual(model.pool, fresh)
        XCTAssertEqual(model.refreshError, .keychainRead)
    }

    @MainActor
    func testHostedPanelKeepsItsSizeThroughRefreshesBusyStatesAndFeedback() throws {
        _ = NSApplication.shared
        // Enable SwiftUI accessibility nodes for the test host without starting an assistive client.
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        let anchor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        anchor.alphaValue = 0
        anchor.orderBack(nil)
        defer { anchor.orderOut(nil) }
        for language in [AppLanguage.en, .zhHans] {
            let account = Account(accountID: String(repeating: "a", count: 64), alias: "primary", email: "one@example.com")
            let registry = Registry(accounts: [account])
            let model = MenuModel(pool: PoolSnapshot(registry: registry, currentEmail: account.email), language: language)
            var updates = 0
            let observer = model.$pool.dropFirst().sink { _ in updates += 1 }
            let host = NSHostingController(rootView: MenuPopoverView(model: model))
            host.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.animates = false
            popover.contentViewController = host
            let view = anchor.contentView!
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            host.view.window?.alphaValue = 0
            defer { popover.close() }
            XCTAssertTrue(popover.isShown)
            let compact = settledSize(popover, host: host)
            XCTAssertEqual(compact.width, MenuPopoverView.width, accuracy: 0.5)
            XCTAssertGreaterThan(compact.height, 100)

            for expanded in [false, true, false] {
                model.showsAddAccount = expanded
                let expected = settledSize(popover, host: host)
                if expanded {
                    XCTAssertGreaterThan(expected.height, compact.height)
                } else {
                    assertSize(expected, equals: compact)
                }

                for busy in [false, true, false, true, false] {
                    model.accountActionInProgress = busy
                    model.listening.toggle()
                    XCTAssertFalse(model.updatePool(PoolSnapshot(registry: registry, currentEmail: account.email)))
                    assertSize(settledSize(popover, host: host), equals: expected)
                }
            }
            XCTAssertEqual(updates, 0)
            withExtendedLifetime(observer) {}

            let windowSize = host.view.window?.frame.size
            XCTAssertNotNil(windowSize)
            func assertStable(file: StaticString = #filePath, line: UInt = #line) {
                XCTAssertEqual(settledSize(popover, host: host), compact, file: file, line: line)
                XCTAssertEqual(host.view.window?.frame.size, windowSize, file: file, line: line)
            }
            model.feedback = .switchResult(target: "primary", changed: true, offersReload: true)
            assertStable()
            model.feedback = .switchResult(target: String(repeating: "w", count: 48), changed: true, offersReload: true)
            assertStable()
            let delegate = ApplicationDelegate(model: model)
            let menu = MoreButton(model: model).makeMenu()
            let displayLanguage = model.displayLanguage
            let riskItem = try XCTUnwrap(menu.item(withTitle: displayLanguage[.quotaRiskMenu]))
            XCTAssertTrue(riskItem.isEnabled)
            XCTAssertEqual(riskItem.state, .off)
            menu.performActionForItem(at: menu.index(of: riskItem))
            XCTAssertEqual(model.feedback, MenuFeedback(.warning, .quotaRiskTitle, detail: .quotaRiskDetail))
            assertStable()

            let window = try XCTUnwrap(host.view.window)
            let contentFrame = window.convertToScreen(host.view.convert(host.view.bounds, to: nil))
            for label in [AppLabel.quotaRiskTitle, .quotaRiskDetail] {
                let text = displayLanguage[label]
                let frame = try XCTUnwrap(visibleStaticText(text, in: window), text)
                XCTAssertTrue(contentFrame.insetBy(dx: -0.5, dy: -0.5).contains(frame), text)
                XCTAssertGreaterThan(frame.height, 0, text)
            }
            withExtendedLifetime(delegate) {}

            model.feedback = nil
            assertStable()

            model.showsAddAccount = true
            model.signInStarted = true
            _ = settledSize(popover, host: host)
            XCTAssertTrue(model.updatePool(PoolSnapshot(registry: registry, currentEmail: "two@example.com")))
            XCTAssertFalse(model.showsAddAccount)
            XCTAssertFalse(model.signInStarted)
            XCTAssertEqual(model.unsavedEmail, "two@example.com")
            let withSave = settledSize(popover, host: host)
            XCTAssertGreaterThan(withSave.height, compact.height)
            assertSize(settledSize(popover, host: host), equals: withSave)
        }
    }

    @MainActor
    private func visibleStaticText(_ text: String, in element: Any) -> NSRect? {
        guard let element = element as? NSObject else { return nil }
        // SwiftUI's accessibility nodes expose these selectors without conforming to NSAccessibilityProtocol.
        func attribute(_ key: String) -> Any? {
            guard element.responds(to: NSSelectorFromString(key)) else { return nil }
            return element.value(forKey: key)
        }
        let role = attribute("accessibilityRole") as? String
        guard role != NSAccessibility.Role.scrollArea.rawValue else { return nil }
        if role == NSAccessibility.Role.staticText.rawValue, attribute("accessibilityValue") as? String == text {
            return (attribute("accessibilityFrame") as? NSValue)?.rectValue
        }
        for child in attribute("accessibilityChildren") as? [Any] ?? [] {
            if let frame = visibleStaticText(text, in: child) { return frame }
        }
        return nil
    }

    @MainActor
    private func settledSize(_ popover: NSPopover, host: NSHostingController<MenuPopoverView>) -> NSSize {
        host.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
        host.view.layoutSubtreeIfNeeded()
        let size = popover.contentSize
        assertSize(size, equals: host.preferredContentSize)
        return size
    }

    private func assertSize(_ actual: NSSize, equals expected: NSSize,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, file: file, line: line)
    }

    func testPopoverHasOneSizeSourceAndNoTooltipsOrHeightAnimation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("Sources/AgySwitchUI/MenuPopoverView.swift"),
                              encoding: .utf8)
        let app = try String(contentsOf: root.appendingPathComponent("Sources/AgySwitch/Application.swift"),
                             encoding: .utf8)
        for removed in [".help(", "GeometryReader", "PopoverHeight", "onResize", ".animation("] {
            XCTAssertFalse(view.contains(removed), removed)
        }
        XCTAssertTrue(app.contains("host.sizingOptions = .preferredContentSize"))
        XCTAssertTrue(app.contains("popover.animates = false"))
        XCTAssertFalse(app.contains("popover.contentSize"))
    }
}
