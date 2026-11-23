//
//  AskAboutLinkTests.swift
//
//  Copyright © 2026 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import AIChat
import AppKit
import Combine
import Common
import FeatureFlags_macOS
@_spi(Testing) import PixelKit
import PrivacyConfig
import PrivacyConfigTestsUtils
import SharedTestUtilities
import Testing
import WebKit
import WebKitExtensions
@testable import DuckDuckGo_Privacy_Browser

// MARK: - Link context menu

@MainActor
@Suite("Ask About Page in a link's context menu")
struct AskAboutLinkMenuTests {

    private let featureFlagger = MockFeatureFlagger()
    private let attacher = LinkContextAttacherSpy()
    private static let page = URL(string: "https://example.com/article")!
    private static let serp = URL(string: "https://duckduckgo.com/?q=privacy")!

    init() {
        featureFlagger.featuresStub[FeatureFlag.aiChatPageContext.rawValue] = true
    }

    private func setFlags(serp: Bool, other: Bool) {
        featureFlagger.featuresStub[FeatureFlag.aiChatAskAboutSerpPage.rawValue] = serp
        featureFlagger.featuresStub[FeatureFlag.aiChatAskAboutLinkedPage.rawValue] = other
    }

    private func makeManager(tabContent: Tab.TabContent, isLoadedInSidebar: Bool = false) -> ContextMenuManager {
        ContextMenuManager(contextMenuSubfeaturePublisher: Empty<ContextMenuSubfeature?, Never>(),
                           contentPublisher: Just(tabContent),
                           tabsPreferences: TabsPreferences(persistor: MockTabsPreferencesPersistor(), windowControllersManager: WindowControllersManagerMock()),
                           isLoadedInSidebar: isLoadedInSidebar,
                           internalUserDecider: MockInternalUserDecider(),
                           aiChatMenuConfiguration: AIChatMenuConfiguration(storage: MockAIChatPreferencesStorage(),
                                                                            remoteSettings: MockRemoteAISettings(),
                                                                            featureFlagger: featureFlagger),
                           aiChatLinkContextAttacher: attacher,
                           tld: TLD())
    }

    /// Opens a link's context menu the way WebKit does and returns the items shown.
    private func openMenu(_ manager: ContextMenuManager, link: String) -> NSMenu {
        let menu = NSMenu()
        for identifier: WKMenuItemIdentifier in [.openLinkInNewWindow, .copyLink, .shareMenu] {
            let item = NSMenuItem(title: identifier.rawValue, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(identifier.rawValue)
            menu.addItem(item)
        }
        manager.willShowContextMenu(withSelectedText: nil, linkURL: link)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        manager.webView(WebView(featureFlagger: featureFlagger, privacyConfig: MockPrivacyConfiguration()), willOpenContextMenu: menu, with: event)
        return menu
    }

    private func click(_ item: NSMenuItem) {
        _ = (item.target as? NSObject)?.perform(item.action, with: item)
    }

    private func askAboutPageItem(in menu: NSMenu) -> NSMenuItem? {
        menu.items.first { $0.title == UserText.aiChatMenuAskAboutPage }
    }

    @available(iOS 16, macOS 13, *)
    @Test("Each page kind follows its own flag", .timeLimit(.minutes(1)),
          arguments: [(false, false), (true, false), (false, true), (true, true)])
    func eachPageKindFollowsItsFlag(serpFlag: Bool, otherFlag: Bool) {
        setFlags(serp: serpFlag, other: otherFlag)

        let onSERP = openMenu(makeManager(tabContent: .url(Self.serp, source: .link)), link: "https://example.com/result")
        let onPage = openMenu(makeManager(tabContent: .url(Self.page, source: .link)), link: "https://example.com/other")

        #expect((askAboutPageItem(in: onSERP) != nil) == serpFlag)
        #expect((askAboutPageItem(in: onPage) != nil) == otherFlag)
    }

    @available(iOS 16, macOS 13, *)
    @Test("No item without page context", .timeLimit(.minutes(1)))
    func noItemWithoutPageContext() {
        setFlags(serp: true, other: true)
        featureFlagger.featuresStub[FeatureFlag.aiChatPageContext.rawValue] = false
        let menu = openMenu(makeManager(tabContent: .url(Self.page, source: .link)), link: "https://example.com/other")
        #expect(askAboutPageItem(in: menu) == nil)
    }

    @available(iOS 16, macOS 13, *)
    @Test("The item sits under a Duck.ai header after the link items", .timeLimit(.minutes(1)))
    func itemSitsUnderDuckAIHeader() throws {
        setFlags(serp: false, other: true)
        let menu = openMenu(makeManager(tabContent: .url(Self.page, source: .link)), link: "https://example.com/other")

        let index = try #require(menu.items.firstIndex { $0.title == UserText.aiChatMenuAskAboutPage })
        #expect(menu.items[index - 1].title == UserText.aiChatTitle)
        #expect(menu.items[index - 2].isSeparatorItem)
        #expect(menu.items.last?.identifier?.rawValue == WKMenuItemIdentifier.shareMenu.rawValue)
    }

    @available(iOS 16, macOS 13, *)
    @Test("Links that can't be read in the background get no item", .timeLimit(.minutes(1)),
          arguments: ["mailto:someone@example.com", "ftp://example.com/file", "https://user:secret@example.com/", "javascript:alert(1)"])
    func unsupportedLinksGetNoItem(link: String) {
        setFlags(serp: true, other: true)
        let menu = openMenu(makeManager(tabContent: .url(Self.page, source: .link)), link: link)
        #expect(askAboutPageItem(in: menu) == nil)
    }

    @available(iOS 16, macOS 13, *)
    @Test("Pages that aren't plain web pages get no item", .timeLimit(.minutes(1)),
          arguments: ["file:///Users/someone/page.html", "https://user:secret@example.com/"])
    func unsupportedPagesGetNoItem(page: String) throws {
        setFlags(serp: true, other: true)
        let menu = openMenu(makeManager(tabContent: .url(try #require(URL(string: page)), source: .link)), link: "https://example.com/a")
        #expect(askAboutPageItem(in: menu) == nil)
    }

    @available(iOS 16, macOS 13, *)
    @Test("No item in the sidebar's own web view or on a Duck.ai tab", .timeLimit(.minutes(1)))
    func noItemInSidebarOrDuckAITab() {
        setFlags(serp: true, other: true)
        let sidebar = openMenu(makeManager(tabContent: .url(Self.page, source: .link), isLoadedInSidebar: true), link: "https://example.com/a")
        let duckAITab = openMenu(makeManager(tabContent: .aiChat(URL(string: "https://duck.ai")!)), link: "https://example.com/a")

        #expect(askAboutPageItem(in: sidebar) == nil)
        #expect(askAboutPageItem(in: duckAITab) == nil)
    }

    @available(iOS 16, macOS 13, *)
    @Test("Turning the flag on while running shows the item on the next menu", .timeLimit(.minutes(1)))
    func flagFlipWhileRunning() {
        let manager = makeManager(tabContent: .url(Self.page, source: .link))
        setFlags(serp: false, other: false)
        #expect(askAboutPageItem(in: openMenu(manager, link: "https://example.com/a")) == nil)

        setFlags(serp: false, other: true)
        #expect(askAboutPageItem(in: openMenu(manager, link: "https://example.com/a")) != nil)

        setFlags(serp: false, other: false)
        #expect(askAboutPageItem(in: openMenu(manager, link: "https://example.com/a")) == nil)
    }

    @available(iOS 16, macOS 13, *)
    @Test("Clicking asks about the link, typed by the page it's on", .timeLimit(.minutes(1)))
    func clickAsksAboutTheLink() throws {
        setFlags(serp: true, other: true)

        // Menu items hold their target weakly, as WebKit's menu does.
        let serpManager = makeManager(tabContent: .url(Self.serp, source: .link))
        let serpMenu = openMenu(serpManager, link: "https://example.com/result")
        let serpItem = try #require(askAboutPageItem(in: serpMenu))
        click(serpItem)

        let pageManager = makeManager(tabContent: .url(Self.page, source: .link))
        let pageMenu = openMenu(pageManager, link: "https://example.com/other")
        let pageItem = try #require(askAboutPageItem(in: pageMenu))
        click(pageItem)
        withExtendedLifetime((serpManager, pageManager)) {}

        #expect(attacher.requests == [LinkContextAttacherSpy.Request(url: URL(string: "https://example.com/result")!, linkType: .serp),
                                      LinkContextAttacherSpy.Request(url: URL(string: "https://example.com/other")!, linkType: .other)])
    }
}

@MainActor
private final class LinkContextAttacherSpy: AIChatLinkContextAttaching {
    struct Request: Equatable {
        let url: URL
        let linkType: AIChatLinkAskAboutPageType
    }
    private(set) var requests: [Request] = []

    func askAboutLink(_ url: URL, linkType: AIChatLinkAskAboutPageType) {
        requests.append(Request(url: url, linkType: linkType))
    }
}

// MARK: - Same-origin rule

@Suite("Linked page main-frame navigations stay on their origin")
struct LinkedPageSameOriginTests {

    @available(iOS 16, macOS 13, *)
    @Test("Same scheme, host and port is the same origin", .timeLimit(.minutes(1)), arguments: [
        ("https://example.com/a", "https://example.com/b?x=1#y"),
        ("https://EXAMPLE.com/a", "https://example.com/b"),
        ("https://example.com/a", "https://example.com:443/b"),
        ("http://example.com:80/a", "http://example.com/b"),
    ])
    func sameOrigin(initial: String, next: String) {
        #expect(LinkedPageLoad.isSameOrigin(URL(string: next)!, as: URL(string: initial)!))
    }

    @available(iOS 16, macOS 13, *)
    @Test("Any change of scheme, host or port leaves the origin", .timeLimit(.minutes(1)), arguments: [
        ("https://example.com/a", "http://example.com/a"),
        ("https://example.com/a", "https://www.example.com/a"),
        ("https://example.com/a", "https://example.com:8443/a"),
        ("https://example.com/a", "https://evil.com/a"),
        ("https://example.com/a", "about:blank"),
    ])
    func crossOrigin(initial: String, next: String) {
        #expect(!LinkedPageLoad.isSameOrigin(URL(string: next)!, as: URL(string: initial)!))
    }
}

// MARK: - Hidden web view load

@MainActor
@Suite("Loading a linked page out of sight")
struct LinkedPageLoadTests {

    private let schemeHandler = TestSchemeHandler()

    private func load(_ url: String, extracted: String = "Page text") async -> LinkedPageContextLoadResult {
        let load = LinkedPageLoad(configuration: schemeHandler.webViewConfiguration()) { webView in
            AIChatPageContextData(title: "Title", favicon: [], url: webView.url?.absoluteString ?? "", content: extracted, truncated: false, fullContentLength: extracted.count)
        }
        return await load.run(URLRequest(url: URL(string: url)!))
    }

    @available(iOS 16, macOS 13, *)
    @Test("A page that loads is read, stamped with its URL and type", .timeLimit(.minutes(1)))
    func loadedPageIsRead() async {
        schemeHandler.middleware = [{ _ in .ok(.html("<html><body>Hi</body></html>")) }]

        let result = await load("https://a.test/page")

        #expect(result == .success(AIChatPageContextData(title: "Title", favicon: [], url: "https://a.test/page", content: "Page text",
                                                         truncated: false, fullContentLength: 9, mimeType: "text/html")))
    }

    @available(iOS 16, macOS 13, *)
    @Test("An HTTP error status is an HTTP error", .timeLimit(.minutes(1)))
    func httpErrorStatus() async {
        schemeHandler.middleware = [{ _ in .ok(code: 404, .html("<html>Not found</html>")) }]
        #expect(await load("https://a.test/missing") == .failed(.httpError))
    }

    @available(iOS 16, macOS 13, *)
    @Test("A redirect to another origin is blocked", .timeLimit(.minutes(1)))
    func crossOriginRedirectIsBlocked() async {
        schemeHandler.middleware = [{ request in
            request.url?.host == "a.test" ? .redirect(to: "https://b.test/") : .ok(.html("<html>Other site</html>"))
        }]
        #expect(await load("https://a.test/") == .failed(.redirectBlocked))
    }

    @available(iOS 16, macOS 13, *)
    @Test("A script navigation to another origin is blocked", .timeLimit(.minutes(1)))
    func crossOriginScriptNavigationIsBlocked() async {
        schemeHandler.middleware = [{ request in
            request.url?.host == "a.test"
                ? .ok(.html("<html><script>location.href = 'https://b.test/'</script></html>"))
                : .ok(.html("<html>Other site</html>"))
        }]
        // Extraction waits on the main frame: it never ends while the script navigates away first.
        let result = await load("https://a.test/", extracted: "")
        #expect(result == .failed(.redirectBlocked) || result == .failed(.emptyContent))
    }

    @available(iOS 16, macOS 13, *)
    @Test("A PDF is not read", .timeLimit(.minutes(1)))
    func pdfIsPrevented() async {
        schemeHandler.middleware = [{ _ in .ok(.data(Data("%PDF-1.4".utf8), mime: "application/pdf")) }]
        #expect(await load("https://a.test/file") == .prevented("pdf"))
    }

    @available(iOS 16, macOS 13, *)
    @Test("A page with no text attaches nothing", .timeLimit(.minutes(1)))
    func emptyPage() async {
        schemeHandler.middleware = [{ _ in .ok(.html("<html></html>")) }]
        #expect(await load("https://a.test/", extracted: "") == .failed(.emptyContent))
    }

    @available(iOS 16, macOS 13, *)
    @Test("A failed connection is a navigation failure", .timeLimit(.minutes(1)))
    func connectionFailure() async {
        schemeHandler.middleware = [{ _ in .failure(URLError(.cannotConnectToHost)) }]
        #expect(await load("https://a.test/") == .failed(.navigationFailed))
    }

    @available(iOS 16, macOS 13, *)
    @Test("Certificate failures are reported as such", .timeLimit(.minutes(1)))
    func certificateFailureReason() {
        #expect(LinkedPageLoad.failureReason(for: URLError(.serverCertificateUntrusted)) == .certificateError)
        #expect(LinkedPageLoad.failureReason(for: URLError(.secureConnectionFailed)) == .certificateError)
        #expect(LinkedPageLoad.failureReason(for: URLError(.timedOut)) == .navigationFailed)
    }

    @available(iOS 16, macOS 13, *)
    @Test("Only plain web links without credentials are loaded", .timeLimit(.minutes(1)))
    func supportedLinks() async {
        #expect(LinkedPageContextLoader.isSupported(URL(string: "https://example.com/a")!))
        #expect(LinkedPageContextLoader.isSupported(URL(string: "http://example.com/a")!))
        #expect(!LinkedPageContextLoader.isSupported(URL(string: "https://user@example.com/a")!))
        #expect(!LinkedPageContextLoader.isSupported(URL(string: "file:///etc/hosts")!))
        #expect(!LinkedPageContextLoader.isSupported(URL(string: "duck://newtab")!))
    }
}

// MARK: - Tab page-context slot

@MainActor
@Suite("Attaching a linked page in the tab")
struct PageContextLinkedPageTests {

    private let content = PassthroughSubject<Tab.TabContent, Never>()
    private let loader = ControlledLinkedPageLoader()
    private let pixels = PixelRecorder()
    private let pageContext: PageContextTabExtension

    init() {
        let privacyConfig = MockPrivacyConfiguration()
        // Extraction outcomes are measured once the blocklist config is present.
        privacyConfig.featureSettings = ["aiPageContextBlocklist": ["image": ["contentTypePrefixes": ["image/"]]]]
        pageContext = PageContextTabExtension(scriptsPublisher: Empty<UserScripts, Never>(),
                                              webViewPublisher: Empty<WKWebView, Never>(),
                                              contentPublisher: content,
                                              tabID: "tab",
                                              featureFlagger: MockFeatureFlagger(),
                                              privacyConfigurationManager: MockPrivacyConfigurationManager(privacyConfig: privacyConfig),
                                              extractionPixelHandler: PageContextExtractionPixelHandler(firePixel: { [pixels] in pixels.fired.append($0) }),
                                              aiChatSessionStore: MockAIChatSessionStore(),
                                              aiChatMenuConfiguration: MockAIChatConfig(),
                                              isLoadedInSidebar: false,
                                              faviconManagement: FaviconManagerMock(),
                                              linkedPageLoader: loader)
    }

    private static let page = AIChatPageContextData(title: "Linked", favicon: [], url: "https://example.com/linked",
                                                    content: "Linked text", truncated: false, fullContentLength: 11)

    @available(iOS 16, macOS 13, *)
    @Test("A read page is attached and reported as a link extraction success", .timeLimit(.minutes(1)))
    func successIsReported() async {
        let attach = pageContext.attachLinkedPage(URL(string: "https://example.com/linked")!)
        loader.complete(with: .success(Self.page))

        #expect(await attach.value == .success(Self.page))
        #expect(pixels.names == ["aichat_page_context_extraction_success"])
    }

    @available(iOS 16, macOS 13, *)
    @Test("Each failure is reported with its reason and trigger link", .timeLimit(.minutes(1)),
          arguments: [PageContextExtractionOutcome.FailureReason.httpError, .redirectBlocked, .certificateError, .timeout, .emptyContent])
    func failureIsReported(reason: PageContextExtractionOutcome.FailureReason) async {
        let attach = pageContext.attachLinkedPage(URL(string: "https://example.com/linked")!)
        loader.complete(with: .failed(reason))

        #expect(await attach.value == .failed(reason))
        #expect(pixels.parameters == [["reason": reason.rawValue, "trigger": "link", "latency": "under_1s", "context_type": "markdown"]])
    }

    @available(iOS 16, macOS 13, *)
    @Test("A linked page the blocklist covers is prevented, not attached", .timeLimit(.minutes(1)))
    func blocklistedPageIsPrevented() async {
        let attach = pageContext.attachLinkedPage(URL(string: "https://example.com/photo")!)
        loader.complete(with: .success(AIChatPageContextData(title: "", favicon: [], url: "https://example.com/photo",
                                                             content: "x", truncated: false, fullContentLength: 1, mimeType: "image/png")))

        #expect(await attach.value == .prevented("image"))
        #expect(pixels.parameters == [["category": "image", "reason": "non_attachable", "trigger": "link"]])
    }

    @available(iOS 16, macOS 13, *)
    @Test("Asking again cancels the first request", .timeLimit(.minutes(1)))
    func secondRequestCancelsFirst() async {
        let first = pageContext.attachLinkedPage(URL(string: "https://example.com/one")!)
        let second = pageContext.attachLinkedPage(URL(string: "https://example.com/two")!)
        loader.complete(with: .success(Self.page))

        #expect(await first.value == nil)
        #expect(await second.value == .success(Self.page))
        #expect(pixels.names == ["aichat_page_context_extraction_success"])
    }

    @available(iOS 16, macOS 13, *)
    @Test("Navigating the tab drops the pending link", .timeLimit(.minutes(1)))
    func navigationCancels() async throws {
        content.send(.url(URL(string: "https://example.com/start")!, source: .link))
        try await Task.sleep(nanoseconds: 300_000_000)

        let attach = pageContext.attachLinkedPage(URL(string: "https://example.com/linked")!)
        content.send(.url(URL(string: "https://example.com/elsewhere")!, source: .link))
        try await Task.sleep(nanoseconds: 300_000_000)
        loader.complete(with: .success(Self.page))

        #expect(await attach.value == nil)
        #expect(pixels.fired.isEmpty)
    }
}

/// Holds every load until the test completes them, like a page that takes a while.
@MainActor
private final class ControlledLinkedPageLoader: LinkedPageContextLoading {
    private var pending: [CheckedContinuation<LinkedPageContextLoadResult, Never>] = []
    private var result: LinkedPageContextLoadResult?

    func load(_ url: URL) async -> LinkedPageContextLoadResult {
        if let result { return result }
        return await withCheckedContinuation { pending.append($0) }
    }

    func complete(with result: LinkedPageContextLoadResult) {
        self.result = result
        pending.forEach { $0.resume(returning: result) }
        pending = []
    }
}

private final class PixelRecorder {
    var fired: [AIChatPixel] = []
    var names: [String] { fired.map(\.name) }
    var parameters: [[String: String]?] { fired.map(\.parameters) }
}

// MARK: - Attacher

@MainActor
@Suite("Ask About Page on a link opens the sidebar and attaches the page")
struct AIChatLinkContextAttacherTests {

    private let pixelFiring = PixelKitMock()
    private let coordinator = LinkAttachCoordinatorMock()
    private let pageContext = LinkedPageContextSpy()
    private let alerts = AlertCounter()

    private func makeAttacher() -> AIChatLinkContextAttacher {
        AIChatLinkContextAttacher(aiChatMenuConfig: MockAIChatConfig(),
                                  aiChatCoordinator: coordinator,
                                  pixelFiring: pixelFiring,
                                  currentPageContextProvider: { [pageContext] in pageContext },
                                  presentUnavailableAlert: { [alerts] in alerts.count += 1 },
                                  aiChatConversationSourceHandler: AIChatConversationSourceHandler())
    }

    private func firedNames() -> [String] {
        pixelFiring.actualFireCalls.map(\.pixel.name)
    }

    @available(iOS 16, macOS 13, *)
    @Test("Opens the sidebar right away and attaches the link without an alert", .timeLimit(.minutes(1)))
    func successOpensSidebarAndAttaches() async {
        pageContext.result = .success(AIChatPageContextData(title: "", favicon: [], url: "https://example.com/a", content: "x", truncated: false, fullContentLength: 1))

        makeAttacher().askAboutLink(URL(string: "https://example.com/a")!, linkType: .other)
        await pageContext.lastTask?.value
        await Task.yield()

        #expect(pageContext.requestedURLs == [URL(string: "https://example.com/a")!])
        #expect(coordinator.revealChatCallCount == 1)
        #expect(firedNames() == ["aichat_link_ask_about_page_macos", AIChatPixel.aiChatSidebarOpened(source: .askAboutLink, shouldAutomaticallySendPageContext: nil, minutesSinceSidebarHidden: nil).name])
        #expect(pixelFiring.actualFireCalls.first?.pixel.parameters == ["link_type": "other"])
        #expect(pixelFiring.actualFireCalls.first?.frequency == .dailyAndCount)
        #expect(pixelFiring.actualFireCalls.last?.pixel.parameters?["source"] == "ask-about-link")
        #expect(alerts.count == 0)
    }

    @available(iOS 16, macOS 13, *)
    @Test("A sidebar that's already open isn't reported as opened", .timeLimit(.minutes(1)))
    func alreadyOpenSidebar() async {
        coordinator.isChatPresented = true
        pageContext.result = nil

        makeAttacher().askAboutLink(URL(string: "https://duckduckgo.com/a")!, linkType: .serp)

        #expect(firedNames() == ["aichat_link_ask_about_page_macos"])
        #expect(pixelFiring.actualFireCalls.first?.pixel.parameters == ["link_type": "serp"])
    }

    @available(iOS 16, macOS 13, *)
    @Test("A page that can't be read tells the user", .timeLimit(.minutes(1)),
          arguments: [LinkedPageContextLoadResult.failed(.httpError), .failed(.timeout), .prevented("pdf")])
    func failureShowsAlert(result: LinkedPageContextLoadResult) async {
        pageContext.result = result

        makeAttacher().askAboutLink(URL(string: "https://example.com/a")!, linkType: .other)
        await pageContext.lastTask?.value
        await Task.yield()

        #expect(alerts.count == 1)
    }

    @available(iOS 16, macOS 13, *)
    @Test("A cancelled request says nothing", .timeLimit(.minutes(1)))
    func cancelledShowsNothing() async {
        pageContext.result = nil

        makeAttacher().askAboutLink(URL(string: "https://example.com/a")!, linkType: .other)
        await pageContext.lastTask?.value
        await Task.yield()

        #expect(alerts.count == 0)
    }
}

private final class AlertCounter {
    var count = 0
}

@MainActor
private final class LinkedPageContextSpy: PageContextProtocol {
    var result: LinkedPageContextLoadResult?
    private(set) var requestedURLs: [URL] = []
    private(set) var lastTask: Task<LinkedPageContextLoadResult?, Never>?

    func appendSelectionContext(_ selection: AIChatSelectionContextData) {}
    func suppressAutoPageContextForSelectionAction() {}
    func requestPageContextAttachment() {}

    func attachLinkedPage(_ url: URL) -> Task<LinkedPageContextLoadResult?, Never> {
        requestedURLs.append(url)
        let task = Task { [result] in result }
        lastTask = task
        return task
    }
}

private final class LinkAttachCoordinatorMock: AIChatCoordinating {
    var isChatPresented = false
    var revealChatCallCount = 0

    func toggleSidebar() {}
    func collapseSidebar(withAnimation: Bool) {}
    func isSidebarOpen(for tabID: TabIdentifier) -> Bool { isChatPresented }
    func isSidebarOpenForCurrentTab() -> Bool { isChatPresented }
    func isChatPresentedForCurrentTab() -> Bool { isChatPresented }
    func sidebarHiddenAt(for tabID: TabIdentifier) -> Date? { nil }
    func sidebarHiddenAtForCurrentTab() -> Date? { nil }
    func hasHiddenChat(for tabID: TabIdentifier) -> Bool { false }
    var sidebarPresenceDidChangePublisher: AnyPublisher<AIChatPresenceChange, Never> { Empty().eraseToAnyPublisher() }
    func isChatFloating(for tabID: TabIdentifier) -> Bool { false }
    var chatFloatingStateDidChangePublisher: AnyPublisher<TabIdentifier, Never> { Empty().eraseToAnyPublisher() }
    func focusFloatingWindow(for tabID: TabIdentifier) {}
    func closeFloatingWindow(for tabID: TabIdentifier) {}
    func closeChat(for tabID: TabIdentifier, withAnimation: Bool) {}
    func revealChat(for prompt: AIChatNativePrompt) {}
    func revealChat() { revealChatCallCount += 1 }
}
