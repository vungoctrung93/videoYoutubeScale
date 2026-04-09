//
//  ContentView.swift
//  video
//
//  Created by Trung on 8/4/26.
//

import SwiftUI
import WebKit
import UIKit

struct ContentView: View {
    @State private var urlText = "https://m.youtube.com"
    @State private var loadedURL: URL? = URL(string: "https://m.youtube.com")
    @State private var objectFit: String = "contain"
    @State private var resizeTrigger = 0
    @State private var statusBarHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let screenWidth = max(proxy.size.width, 0)
            let computedVideoWidth = max(screenWidth - 32, 1)
            let computedVideoHeight = max((screenWidth * 2.0 / 3.0) - 32, 1)

            VStack(spacing: 0) {
                BrowserWebView(
                    url: $loadedURL,
                    videoWidth: Int(computedVideoWidth.rounded()),
                    videoHeight: Int(computedVideoHeight.rounded()),
                    objectFit: objectFit,
                    resizeTrigger: resizeTrigger
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 0))
            }
            .padding()
            .onAppear(perform: updateStatusBarHeight)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                updateStatusBarHeight()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
                updateStatusBarHeight()
            }
        }
        .statusBar(hidden: shouldHideStatusBar)
        .ignoresSafeArea(.container, edges: shouldHideStatusBar ? .top : [])
    }

    private var shouldHideStatusBar: Bool {
        statusBarHeight >= 32
    }

    private func updateStatusBarHeight() {
        let currentHeight = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .compactMap { $0.statusBarManager?.statusBarFrame.height }
            .max() ?? 0

        statusBarHeight = currentHeight
    }
    

    private func openURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let directURL = URL(string: trimmed)
        let resolvedURL = (directURL?.scheme != nil) ? directURL : URL(string: "https://\(trimmed)")

        if let resolvedURL {
            loadedURL = inlineFriendlyURL(from: resolvedURL)
        }
    }

    private func inlineFriendlyURL(from sourceURL: URL) -> URL {
        guard let host = sourceURL.host?.lowercased() else { return sourceURL }

        // iPad often hits YouTube embed restriction (error 152-4).
        // Keep YouTube on mobile watch pages instead of forcing /embed.
        if UIDevice.current.userInterfaceIdiom == .pad, host.contains("youtube.com") {
            var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
            if components?.host?.contains("youtube.com") == true {
                components?.host = "m.youtube.com"
            }
            return components?.url ?? sourceURL
        }

        if host.contains("youtu.be") {
            let videoId = sourceURL.pathComponents.dropFirst().first ?? ""
            if !videoId.isEmpty {
                return URL(string: "https://www.youtube.com/embed/\(videoId)?playsinline=1") ?? sourceURL
            }
        }

        if host.contains("youtube.com") {
            if sourceURL.path.hasPrefix("/shorts/") {
                let videoId = sourceURL.pathComponents.dropFirst().dropFirst().first ?? ""
                if !videoId.isEmpty {
                    return URL(string: "https://www.youtube.com/embed/\(videoId)?playsinline=1") ?? sourceURL
                }
            }

            if sourceURL.path == "/watch",
               let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
               let videoId = components.queryItems?.first(where: { $0.name == "v" })?.value,
               !videoId.isEmpty {
                return URL(string: "https://www.youtube.com/embed/\(videoId)?playsinline=1") ?? sourceURL
            }

            if sourceURL.path.hasPrefix("/embed/") {
                var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
                var queryItems = components?.queryItems ?? []
                if !queryItems.contains(where: { $0.name == "playsinline" }) {
                    queryItems.append(URLQueryItem(name: "playsinline", value: "1"))
                }
                components?.queryItems = queryItems
                return components?.url ?? sourceURL
            }
        }

        return sourceURL
    }
}

struct BrowserWebView: UIViewRepresentable {
    @Binding var url: URL?
    var videoWidth: Int
    var videoHeight: Int
    var objectFit: String
    var resizeTrigger: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        let shouldForceYouTubeEmbed = UIDevice.current.userInterfaceIdiom != .pad

        let inlineVideoScript = WKUserScript(
            source: """
            (function() {
                function setupVideo(video) {
                    video.setAttribute('playsinline', '');
                    video.setAttribute('webkit-playsinline', '');
                    video.playsInline = true;
                }

                function applyToAllVideos() {
                    document.querySelectorAll('video').forEach(setupVideo);
                }

                applyToAllVideos();

                const observer = new MutationObserver(function() {
                    applyToAllVideos();
                });
                observer.observe(document.documentElement, { childList: true, subtree: true });
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(inlineVideoScript)

        let youtubeEmbedRedirectScript = WKUserScript(
            source: """
            (function() {
                const forceEmbed = \(shouldForceYouTubeEmbed ? "true" : "false");
                if (!forceEmbed) { return; }

                const host = (location.hostname || '').toLowerCase();
                const isYouTubeHost = host === 'youtube.com' || host.endsWith('.youtube.com');
                if (!isYouTubeHost) { return; }

                function toEmbedUrl() {
                    const path = location.pathname || '';
                    if (path.startsWith('/embed/')) {
                        return null;
                    }

                    let videoId = '';
                    if (path === '/watch') {
                        const params = new URLSearchParams(location.search);
                        videoId = params.get('v') || '';
                    } else if (path.startsWith('/shorts/')) {
                        const parts = path.split('/');
                        videoId = parts.length > 2 ? parts[2] : '';
                    }

                    if (!videoId) {
                        return null;
                    }

                    return 'https://www.youtube.com/embed/' + videoId + '?playsinline=1';
                }

                function normalizeToEmbed() {
                    const embedUrl = toEmbedUrl();
                    if (embedUrl && location.href !== embedUrl) {
                        location.replace(embedUrl);
                    }
                }

                normalizeToEmbed();

                let lastHref = location.href;
                setInterval(function() {
                    if (location.href !== lastHref) {
                        lastHref = location.href;
                        normalizeToEmbed();
                    }
                }, 350);
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(youtubeEmbedRedirectScript)

        let webView = WKWebView(frame: .zero, configuration: config)

        if UIDevice.current.userInterfaceIdiom == .pad {
            webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        }

        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.webView = webView

        if let url {
            webView.load(URLRequest(url: url))
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if let url, uiView.url?.absoluteString != url.absoluteString {
            uiView.load(URLRequest(url: url))
            return
        }

        let styleKey = "\(videoWidth)x\(videoHeight)-\(objectFit)-\(resizeTrigger)"
        if context.coordinator.lastStyleKey != styleKey {
            context.coordinator.lastStyleKey = styleKey
            context.coordinator.resizeVideos(width: videoWidth, height: videoHeight, objectFit: objectFit)
        }
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: BrowserWebView
        weak var webView: WKWebView?
        var lastStyleKey = ""

        init(_ parent: BrowserWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            resizeVideos(width: parent.videoWidth, height: parent.videoHeight, objectFit: parent.objectFit)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            let blockedSchemes = ["youtube", "itms-apps", "itms-appss"]
            if let scheme = url.scheme?.lowercased(), blockedSchemes.contains(scheme) {
                decisionHandler(.cancel)
                return
            }

            let inlineURL = inlineFriendlyURL(from: url)
            if inlineURL.absoluteString != url.absoluteString {
                webView.load(URLRequest(url: inlineURL))
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }

        func resizeVideos(width: Int, height: Int, objectFit: String) {
            let script = """
            (function() {
                const targetWidth = '\(width)px';
                const targetHeight = '\(height)px';
                const fit = '\(objectFit)';
                const host = (location.hostname || '').toLowerCase();
                const isYouTube = host === 'youtube.com' || host.endsWith('.youtube.com');
                let count = 0;

                function ensureGlobalStyle(doc) {
                    const styleId = 'copilot-inline-video-style';
                    const css = `
                        video {
                            width: ${targetWidth} !important;
                            height: ${targetHeight} !important;
                            max-width: ${targetWidth} !important;
                            max-height: ${targetHeight} !important;
                            object-fit: fill !important;
                        }
                        #movie_player,
                        #movie_player .html5-video-player,
                        #movie_player .html5-video-container,
                        #movie_player .html5-main-video,
                        .ytp-embed,
                        .ytp-player-content,
                        #player,
                        ytd-player,
                        ytd-watch-flexy #player {
                            width: ${targetWidth} !important;
                            height: ${targetHeight} !important;
                            max-width: ${targetWidth} !important;
                            max-height: ${targetHeight} !important;
                        }
                        #masthead {
                            opacity: 0.1 !important;
                        }
                        ytd-masthead,
                        ytm-masthead-container,
                        #header-bar,
                        ytm-mobile-topbar-renderer,
                        .mobile-topbar-header {
                            opacity: 0.1 !important;
                        }
                        #movie_player,
                        #movie_player .html5-video-player,
                        #movie_player .html5-video-container {
                            overflow: hidden !important;
                            position: relative !important;
                        }
                        #movie_player video.video-stream,
                        #movie_player .html5-main-video {
                            width: 100% !important;
                            height: 100% !important;
                            max-width: none !important;
                            max-height: none !important;
                            left: 0 !important;
                            top: 0 !important;
                            transform: none !important;
                            object-fit: fill !important;
                            object-position: center center !important;
                        }
                    `;

                    let style = doc.getElementById(styleId);
                    if (!style) {
                        style = doc.createElement('style');
                        style.id = styleId;
                        doc.head && doc.head.appendChild(style);
                    }
                    if (style) {
                        style.textContent = css;
                    }
                }

                function applyMastheadOpacity(doc) {
                    if (!doc) { return; }

                    const selectors = [
                        '#masthead',
                        'ytd-masthead',
                        'ytm-masthead-container',
                        '#header-bar',
                        'ytm-mobile-topbar-renderer',
                        '.mobile-topbar-header'
                    ];

                    selectors.forEach(function(selector) {
                        doc.querySelectorAll(selector).forEach(function(el) {
                            el.style.setProperty('opacity', '0.1', 'important');
                        });
                    });
                }

                function styleVideo(video) {
                    const shouldFillContainer = isYouTube && fit === 'fill';
                    video.style.setProperty('width', shouldFillContainer ? '100%' : targetWidth, 'important');
                    video.style.setProperty('height', shouldFillContainer ? '100%' : targetHeight, 'important');
                    video.style.setProperty('max-width', shouldFillContainer ? 'none' : targetWidth, 'important');
                    video.style.setProperty('max-height', shouldFillContainer ? 'none' : targetHeight, 'important');
                    video.style.setProperty('object-fit', 'fill', 'important');
                    video.style.setProperty('object-position', 'center center', 'important');
                    video.style.setProperty('display', 'block', 'important');
                    if (shouldFillContainer) {
                        video.style.setProperty('left', '0', 'important');
                        video.style.setProperty('top', '0', 'important');
                        video.style.setProperty('transform', 'none', 'important');
                    }
                    video.setAttribute('width', '\(width)');
                    video.setAttribute('height', '\(height)');
                    video.setAttribute('playsinline', '');
                    video.setAttribute('webkit-playsinline', '');
                    video.playsInline = true;
                    count += 1;

                    if (shouldFillContainer) {
                        let parent = video.parentElement;
                        let depth = 0;
                        while (parent && depth < 10) {
                            parent.style.setProperty('width', targetWidth, 'important');
                            parent.style.setProperty('height', targetHeight, 'important');
                            parent.style.setProperty('max-width', targetWidth, 'important');
                            parent.style.setProperty('max-height', targetHeight, 'important');
                            parent.style.setProperty('min-height', targetHeight, 'important');
                            parent.style.setProperty('padding-top', '0px', 'important');
                            parent.style.setProperty('padding-bottom', '0px', 'important');
                            parent.style.setProperty('aspect-ratio', 'auto', 'important');
                            parent.style.setProperty('overflow', 'hidden', 'important');
                            parent.style.setProperty('background-color', 'transparent', 'important');
                            parent = parent.parentElement;
                            depth += 1;
                        }
                    }
                }

                function styleIframe(iframe) {
                    iframe.style.setProperty('width', targetWidth, 'important');
                    iframe.style.setProperty('height', targetHeight, 'important');
                    iframe.style.setProperty('max-width', targetWidth, 'important');
                    iframe.style.setProperty('max-height', targetHeight, 'important');

                    if (isYouTube && fit === 'fill') {
                        let parent = iframe.parentElement;
                        let depth = 0;
                        while (parent && depth < 8) {
                            parent.style.setProperty('width', targetWidth, 'important');
                            parent.style.setProperty('height', targetHeight, 'important');
                            parent.style.setProperty('max-width', targetWidth, 'important');
                            parent.style.setProperty('max-height', targetHeight, 'important');
                            parent.style.setProperty('padding-top', '0px', 'important');
                            parent.style.setProperty('padding-bottom', '0px', 'important');
                            parent.style.setProperty('aspect-ratio', 'auto', 'important');
                            parent.style.setProperty('overflow', 'hidden', 'important');
                            parent = parent.parentElement;
                            depth += 1;
                        }
                    }
                }

                function walkDocument(doc) {
                    if (!doc) { return; }
                    ensureGlobalStyle(doc);
                    applyMastheadOpacity(doc);
                    doc.querySelectorAll('video').forEach(styleVideo);
                    doc.querySelectorAll('iframe').forEach(function(iframe) {
                        styleIframe(iframe);
                        try {
                            if (iframe.contentDocument) {
                                walkDocument(iframe.contentDocument);
                            }
                        } catch (_) {
                            // Ignore cross-origin frames.
                        }
                    });
                }

                walkDocument(document);

                // YouTube frequently rewrites inline styles after load; enforce a few more passes.
                let attempts = 0;
                const timer = setInterval(function() {
                    walkDocument(document);
                    attempts += 1;
                    if (attempts >= 20) {
                        clearInterval(timer);
                    }
                }, 200);

                return count;
            })();
            """

            webView?.evaluateJavaScript(script, completionHandler: nil)
        }

        private func inlineFriendlyURL(from sourceURL: URL) -> URL {
            guard let host = sourceURL.host?.lowercased() else { return sourceURL }

            if UIDevice.current.userInterfaceIdiom == .pad, host.contains("youtube.com") {
                var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
                if components?.host?.contains("youtube.com") == true {
                    components?.host = "m.youtube.com"
                }
                return components?.url ?? sourceURL
            }

            if host.contains("youtu.be") {
                let videoId = sourceURL.pathComponents.dropFirst().first ?? ""
                if !videoId.isEmpty {
                    return URL(string: "https://www.youtube.com/embed/\(videoId)?playsinline=1") ?? sourceURL
                }
            }

            if host.contains("youtube.com") {
                if sourceURL.path.hasPrefix("/shorts/") {
                    let videoId = sourceURL.pathComponents.dropFirst().dropFirst().first ?? ""
                    if !videoId.isEmpty {
                        return URL(string: "https://www.youtube.com/embed/\(videoId)?playsinline=1") ?? sourceURL
                    }
                }

                if sourceURL.path == "/watch",
                   let components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false),
                   let videoId = components.queryItems?.first(where: { $0.name == "v" })?.value,
                   !videoId.isEmpty {
                    return URL(string: "https://www.youtube.com/embed/\(videoId)?playsinline=1") ?? sourceURL
                }

                if sourceURL.path.hasPrefix("/embed/") {
                    var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
                    var queryItems = components?.queryItems ?? []
                    if !queryItems.contains(where: { $0.name == "playsinline" }) {
                        queryItems.append(URLQueryItem(name: "playsinline", value: "1"))
                    }
                    components?.queryItems = queryItems
                    return components?.url ?? sourceURL
                }
            }

            return sourceURL
        }
    }
}

#Preview {
    ContentView()
}
