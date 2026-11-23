//
//  LinkedPageContextLoader.swift
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
import BrowserServicesKit
import Common
import ConcurrencyExtensions
import FeatureFlags_macOS
import Foundation
import MaliciousSiteProtection
import os.log
import PrivacyConfig
import UserScript
import WebKit

enum LinkedPageContextLoadResult: Equatable {
    case success(AIChatPageContextData)
    case failed(PageContextExtractionOutcome.FailureReason)
    case prevented(String)
}

/// Reads a page the user hasn't opened, for "Ask about page" on a link.
@MainActor
protocol LinkedPageContextLoading {
    /// Loads `url` out of sight and reads its page context. Cancelling the calling task stops the load.
    func load(_ url: URL) async -> LinkedPageContextLoadResult
}

/// Loads a link in a bare, windowless `WKWebView` on the tab's profile, reads it with the standard
/// page-context user script, then throws the web view away. A hidden `Tab` would record history and
/// run the download, permission and autofill extensions, so this applies the tab's main-frame
/// protections itself and allows nothing but a same-origin load of the page.
@MainActor
final class LinkedPageContextLoader: LinkedPageContextLoading {

    static let timeout: TimeInterval = 30

    private let burnerMode: BurnerMode
    private let contentBlocking: AnyContentBlocking
    private let httpsUpgrade: HTTPSUpgrade
    private let maliciousSiteDetector: MaliciousSiteDetecting
    private let isGPCEnabled: () -> Bool
    private let featureFlagger: FeatureFlagger

    private lazy var linkProtection = LinkProtection(privacyManager: contentBlocking.privacyConfigurationManager,
                                                     contentBlockingManager: contentBlocking.contentBlockingManager,
                                                     errorReporting: NavigationProtectionTabExtension.debugEvents,
                                                     isFastTrackingParameterFilterEnabled: { [featureFlagger] in featureFlagger.isFeatureOn(.fastTrackingParameterFilter) })

    init(burnerMode: BurnerMode,
         contentBlocking: AnyContentBlocking,
         httpsUpgrade: HTTPSUpgrade,
         maliciousSiteDetector: MaliciousSiteDetecting,
         isGPCEnabled: @escaping () -> Bool,
         featureFlagger: FeatureFlagger) {
        self.burnerMode = burnerMode
        self.contentBlocking = contentBlocking
        self.httpsUpgrade = httpsUpgrade
        self.maliciousSiteDetector = maliciousSiteDetector
        self.isGPCEnabled = isGPCEnabled
        self.featureFlagger = featureFlagger
    }

    /// Only plain web links: no other schemes, and no credentials in the URL.
    nonisolated static func isSupported(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return false }
        return url.user == nil && url.password == nil
    }

    func load(_ url: URL) async -> LinkedPageContextLoadResult {
        guard Self.isSupported(url) else { return .failed(.unsupportedURL) }
        do {
            return try await withTimeout(Self.timeout) { @MainActor [self] in
                await self.protectAndLoad(url)
            }
        } catch {
            return .failed(.timeout)
        }
    }

    private func protectAndLoad(_ url: URL) async -> LinkedPageContextLoadResult {
        // The main-frame protections a tab applies before it loads a link.
        var url = await linkProtection.getCleanURL(from: url, onStartExtracting: {}, onFinishExtracting: {})
        if url.isHttp, url.port == nil, case .success(let upgradedURL) = await httpsUpgrade.upgrade(url: url) {
            url = upgradedURL
        }
        // A flagged site is never loaded: there's no warning page to show here.
        if await maliciousSiteDetector.evaluate(url) != nil {
            return .failed(.unsupportedURL)
        }
        var request = URLRequest(url: url)
        if let gpcRequest = GPCRequestFactory().requestForGPC(basedOn: request,
                                                              config: contentBlocking.privacyConfigurationManager.privacyConfig,
                                                              gpcEnabled: isGPCEnabled()) {
            request = gpcRequest
        }
        guard !Task.isCancelled else { return .failed(.timeout) }

        let configuration = WKWebViewConfiguration()
        configuration.applyStandardConfiguration(featureFlagger: featureFlagger, contentBlocking: contentBlocking, burnerMode: burnerMode)
        if #available(macOS 15.4, *) {
            // The user didn't open this page, so their browser extensions don't get to see it.
            configuration.webExtensionController = nil
        }
        guard let userContentController = configuration.userContentController as? UserContentController else {
            return .failed(.scriptError)
        }
        let userContentControllerDelegate = IgnoringUserContentControllerDelegate()
        userContentController.delegate = userContentControllerDelegate
        defer { userContentController.cleanUpBeforeClosing() }

        // The tab's tracker blocking only applies once the rule lists are installed.
        await userContentController.awaitContentBlockingAssetsInstalled()
        guard !Task.isCancelled else { return .failed(.timeout) }
        guard let pageContextUserScript = (userContentController.contentBlockingAssets?.userScripts as? UserScripts)?.pageContextUserScript else {
            return .failed(.scriptError)
        }

        return await LinkedPageLoad(configuration: configuration) { webView in
            pageContextUserScript.webView = webView
            return await pageContextUserScript.collectAndWait(timeout: 10)
        }.run(request)
    }
}

/// Assets installed into the hidden web view need no per-tab wiring.
private final class IgnoringUserContentControllerDelegate: UserContentControllerDelegate {
    func userContentController(_ userContentController: UserContentController,
                               didInstallContentRuleLists contentRuleLists: [String: WKContentRuleList],
                               userScripts: UserScriptsProvider,
                               updateEvent: ContentBlockerRulesManager.UpdateEvent) {}
}

/// One load of one linked page in a windowless web view. It only lets the main frame stay on the
/// origin it started on, never opens windows or downloads and denies every permission prompt.
@MainActor
final class LinkedPageLoad: NSObject {

    private let webView: WKWebView
    private let extract: @MainActor (WKWebView) async -> AIChatPageContextData?
    private var initialURL: URL?
    private var mimeType: String?
    private var isExtracting = false
    private var continuation: CheckedContinuation<LinkedPageContextLoadResult, Never>?

    init(configuration: WKWebViewConfiguration, extract: @escaping @MainActor (WKWebView) async -> AIChatPageContextData?) {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: configuration)
        self.extract = extract
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    /// Main-frame navigations may not leave the origin (scheme, host and port) they started on.
    nonisolated static func isSameOrigin(_ url: URL, as initialURL: URL) -> Bool {
        func origin(_ url: URL) -> (String?, String?, Int?) {
            let scheme = url.scheme?.lowercased()
            let defaultPort: Int? = switch scheme {
            case "http": 80
            case "https": 443
            default: nil
            }
            return (scheme, url.host?.lowercased(), url.port ?? defaultPort)
        }
        return origin(url) == origin(initialURL)
    }

    func run(_ request: URLRequest) async -> LinkedPageContextLoadResult {
        initialURL = request.url
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                webView.load(request)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failed(.timeout)) }
        }
    }

    private func finish(_ result: LinkedPageContextLoadResult) {
        guard let continuation else { return }
        self.continuation = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        continuation.resume(returning: result)
    }

    private func extractPageContext() async {
        guard !isExtracting, continuation != nil else { return }
        isExtracting = true
        let context = await extract(webView)
        guard let context, !context.content.isEmpty else {
            finish(.failed(.emptyContent))
            return
        }
        // The sidebar shows where the content came from: the page as finally loaded.
        finish(.success(AIChatPageContextData(title: context.title,
                                              favicon: context.favicon,
                                              url: webView.url?.absoluteString ?? context.url,
                                              content: context.content,
                                              truncated: context.truncated,
                                              fullContentLength: context.fullContentLength,
                                              pageTypeSignals: context.pageTypeSignals,
                                              mimeType: mimeType ?? context.mimeType)))
    }

    nonisolated static func failureReason(for error: Error) -> PageContextExtractionOutcome.FailureReason {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return .navigationFailed }
        switch error.code {
        case NSURLErrorSecureConnectionFailed,
             NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid,
             NSURLErrorClientCertificateRejected,
             NSURLErrorClientCertificateRequired:
            return .certificateError
        default:
            return .navigationFailed
        }
    }
}

extension LinkedPageLoad: WKNavigationDelegate {

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // A nil target frame is a new window: no popups.
        guard let targetFrame = navigationAction.targetFrame else {
            decisionHandler(.cancel)
            return
        }
        guard targetFrame.isMainFrame else {
            decisionHandler(navigationAction.shouldPerformDownload ? .cancel : .allow)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.cancel)
            finish(.failed(.navigationFailed))
            return
        }
        // Covers server redirects as well as script and meta-refresh navigations.
        guard let url = navigationAction.request.url, let initialURL, Self.isSameOrigin(url, as: initialURL) else {
            decisionHandler(.cancel)
            finish(.failed(.redirectBlocked))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        guard navigationResponse.isForMainFrame else {
            decisionHandler(.allow)
            return
        }
        if let statusCode = (navigationResponse.response as? HTTPURLResponse)?.statusCode, statusCode >= 400 {
            decisionHandler(.cancel)
            finish(.failed(.httpError))
            return
        }
        let mimeType = navigationResponse.response.mimeType
        if mimeType == AIChatPageContextData.pdfMIMEType {
            decisionHandler(.cancel)
            finish(.prevented("pdf"))
            return
        }
        // Anything WebKit can't display would become a download.
        guard navigationResponse.canShowMIMEType else {
            decisionHandler(.cancel)
            finish(.failed(.navigationFailed))
            return
        }
        self.mimeType = mimeType
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await extractPageContext() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failed(Self.failureReason(for: error)))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failed(Self.failureReason(for: error)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failed(.navigationFailed))
    }
}

extension LinkedPageLoad: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        nil
    }

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    // Geolocation and notification prompts go through private delegate methods this class doesn't
    // implement, and WebKit denies them when they're missing.
}
