import Cocoa
import WebKit

/// 独立登录窗口：不注入任何脚本、不做 UA 伪装、不走去广告，
/// 用于主窗口验证码异常时完成短信登录。与主窗口共享同一个 Cookie 存储。
final class LoginWindowController: NSWindowController {
    private let webView: WKWebView
    private let onFinish: () -> Void

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: MainWindowController.viewportFixScript,
                                             injectionTime: .atDocumentStart,
                                             forMainFrameOnly: false))
        controller.addUserScript(WKUserScript(source: MainWindowController.captchaFrameFixScript,
                                             injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: true))
        configuration.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: configuration)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 780),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "登录红果"
        window.minSize = NSSize(width: 760, height: 560)
        window.center()

        super.init(window: window)

        webView.navigationDelegate = self
        webView.uiDelegate = self
        buildInterface(in: window)
        webView.load(URLRequest(url: URL(string: "https://hongguoduanju.com/")!))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildInterface(in window: NSWindow) {
        let container = NSView()
        window.contentView = container

        let bar = NSView()

        let hint = NSTextField(labelWithString: "在这个窗口完成短信登录（含滑块验证），成功后点右侧「完成」")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor

        let done = NSButton(title: "完成", target: self, action: #selector(finishLogin))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        [webView, bar, hint, done].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        container.addSubview(webView)
        container.addSubview(bar)
        bar.addSubview(hint)
        bar.addSubview(done)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: bar.topAnchor),

            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 44),

            hint.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 16),
            hint.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            done.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -16),
            done.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            done.widthAnchor.constraint(equalToConstant: 84)
        ])
    }

    @objc private func finishLogin() {
        onFinish()
        close()
    }
}

extension LoginWindowController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if let host = url.host?.lowercased(),
           host == "hongguoduanju.com" || host.hasSuffix(".hongguoduanju.com") {
            decisionHandler(.allow)
            return
        }
        if url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        if let target = navigationAction.targetFrame, !target.isMainFrame {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated,
           url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           let host = url.host?.lowercased(),
           host == "hongguoduanju.com" || host.hasSuffix(".hongguoduanju.com") {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
