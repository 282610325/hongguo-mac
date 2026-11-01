import Cocoa
import WebKit

final class MainWindowController: NSWindowController {
    private static let homeURL = URL(string: "https://hongguoduanju.com/")!
    private static let lastURLKey = "LastVisitedURL"
    private static let progressKey = "ResumeProgress"
    private static let bridgeName = "hgBridge"

    private let webView: WKWebView
    private let progressBar = NSProgressIndicator()

    private var backItem: NSToolbarItem?
    private var forwardItem: NSToolbarItem?
    private var adBlockItem: NSToolbarItem?
    private var activityToken: NSObjectProtocol?
    private var toastView: NSView?
    private var loginWindowController: LoginWindowController?
    #if HGTEST
    private var didScheduleTest = false
    private var toastCount = 0
    #endif

    // MARK: - 生命周期

    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        if #available(macOS 12.3, *) {
            configuration.preferences.isElementFullscreenEnabled = true
        }

        let controller = WKUserContentController()
        configuration.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "红果"
        window.minSize = NSSize(width: 1000, height: 660)
        window.tabbingMode = .disallowed
        window.setFrameAutosaveName("HongguoMainWindow")
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
        }

        super.init(window: window)

        window.delegate = self
        wireUpUserScripts(controller)
        buildInterface(in: window)
        observeWebView()

        #if HGTEST
        print("[HG] resume entries at launch:", Self.resumeMap.count)
        #endif

        AdBlocker.shared.prepare { [weak self] in
            guard let self = self else { return }
            AdBlocker.shared.apply(to: self.webView.configuration.userContentController)
            self.loadInitialPage()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        setPlaying(false)
    }

    // MARK: - 界面

    private func buildInterface(in window: NSWindow) {
        let container = NSView(frame: window.contentLayoutRect)
        container.wantsLayer = true
        window.contentView = container

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(progressBar)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            progressBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            progressBar.topAnchor.constraint(equalTo: container.topAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: 2)
        ])

        let toolbar = NSToolbar(identifier: "HongguoMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        updateAdBlockAppearance()
    }

    private func wireUpUserScripts(_ controller: WKUserContentController) {
        controller.add(self, name: MainWindowController.bridgeName)

        let saved = MainWindowController.jsonString(Self.resumeMap)
        let bootstrap = MainWindowController.schemeGuardScript + "\nwindow.__hgSaved = \(saved);\n" + MainWindowController.runtimeScript
        controller.addUserScript(WKUserScript(source: bootstrap,
                                             injectionTime: .atDocumentStart,
                                             forMainFrameOnly: true))

        let cosmetic = """
        (function () {
            if (window.__hgAdBlockInstalled) { return; }
            window.__hgAdBlockInstalled = true;
            window.__hgAdBlockOn = true;
            window.__hgAdBlockApply = function () {
                var id = 'hg-adblock-style';
                var node = document.getElementById(id);
                if (window.__hgAdBlockOn) {
                    if (!node) {
                        node = document.createElement('style');
                        node.id = id;
                        node.textContent = \(MainWindowController.cssLiteral);
                        (document.head || document.documentElement).appendChild(node);
                    }
                } else if (node) {
                    node.parentNode.removeChild(node);
                }
            };
            window.__hgAdBlockApply();
            var observer = new MutationObserver(function () {
                if (window.__hgAdBlockOn) { window.__hgAdBlockApply(); }
            });
            observer.observe(document.documentElement, { childList: true, subtree: true });

            // 登录弹窗：让「我已阅读并同意…」整行可点击，而不是只能点中那个小圆点
            document.addEventListener('click', function (event) {
                var target = event.target;
                if (!target || target.tagName === 'INPUT') { return; }
                if (target.closest && target.closest('a')) { return; }
                var dialog = target.closest ? target.closest('[role="dialog"]') : null;
                var note = target.closest ? target.closest('[class*="agreement-note"]') : null;
                if (!dialog || !note) { return; }
                var box = dialog.querySelector('input[type="checkbox"]');
                if (box) { box.click(); }
            }, true);

            // 登录表单：未勾选协议时，网页会把「获取验证码」变成不可点击，
            // 且没有任何提示。这里恢复点击并给出明确反馈。
            if (!document.getElementById('hg-login-style')) {
                var style = document.createElement('style');
                style.id = 'hg-login-style';
                style.textContent = '.web-login-button-input__button-text.send-input{pointer-events:auto!important;cursor:pointer!important;}';
                (document.head || document.documentElement).appendChild(style);
            }

            function hgToast(text) {
                try { window.webkit.messageHandlers.hgBridge.postMessage({ name: 'toast', data: text }); } catch (e) {}
            }
            function hgFlash(el) {
                if (!el) { return; }
                var previous = el.style.boxShadow;
                el.style.transition = 'box-shadow .2s';
                el.style.boxShadow = '0 0 0 2px rgba(255,59,48,.85)';
                setTimeout(function () { el.style.boxShadow = previous || ''; }, 1600);
            }

            var lastSendAt = 0;
            document.addEventListener('mousedown', function (event) {
                var target = event.target;
                if (!target || !target.closest) { return; }
                var send = target.closest('.web-login-button-input__button-text');
                if (!send) { return; }
                var dialog = send.closest('[role="dialog"]');
                if (!dialog) { return; }
                var box = dialog.querySelector('input[type="checkbox"]');
                if (box && !box.checked) {
                    event.preventDefault();
                    event.stopPropagation();
                    hgFlash(dialog.querySelector('[class*="agreement-note"]'));
                    hgToast('请先勾选同意《平台协议》和《隐私条款》');
                    return;
                }
                var phone = dialog.querySelector('input[placeholder="请输入手机号"]');
                var digits = phone ? String(phone.value || '').replace(/\\D/g, '') : '';
                if (digits.length !== 11) {
                    event.preventDefault();
                    event.stopPropagation();
                    if (phone) { phone.focus(); }
                    hgToast('请输入 11 位手机号');
                    return;
                }
                var now = Date.now();
                if (now - lastSendAt < 10000) {
                    event.preventDefault();
                    event.stopPropagation();
                    hgToast('操作过快，请稍等 ' + Math.ceil((10000 - (now - lastSendAt)) / 1000) + ' 秒再试');
                    return;
                }
                lastSendAt = now;
                setTimeout(function () {
                    var box = document.getElementById('captcha_container');
                    if (!box) { return; }
                    var frame = box.querySelector('iframe');
                    var rect = frame ? frame.getBoundingClientRect() : null;
                    try {
                        window.webkit.messageHandlers.hgBridge.postMessage({ name: 'captchaDiag', data: {
                            kind: 'clickProbe',
                            rect: rect ? { x: Math.round(rect.x), y: Math.round(rect.y), w: Math.round(rect.width), h: Math.round(rect.height) } : null,
                            computedW: frame ? getComputedStyle(frame).width : null,
                            computedH: frame ? getComputedStyle(frame).height : null,
                            bodyText: (document.body.innerText || '').slice(0, 300)
                        }});
                    } catch (e) {}
                }, 2500);
            }, true);

            document.addEventListener('click', function (event) {
                var target = event.target;
                if (!target || !target.closest) { return; }
                var button = target.closest('.web-login-button');
                if (!button) { return; }
                var dialog = button.closest('[role="dialog"]');
                if (!dialog) { return; }
                var box = dialog.querySelector('input[type="checkbox"]');
                if (box && !box.checked) {
                    event.preventDefault();
                    event.stopPropagation();
                    hgFlash(dialog.querySelector('[class*="agreement-note"]'));
                    hgToast('请先勾选同意《平台协议》和《隐私条款》');
                }
            }, true);

            function hgCloseCaptcha() {
                var ids = ['captcha_container', 'vc_captcha_box'];
                for (var i = 0; i < ids.length; i++) {
                    var el = document.getElementById(ids[i]);
                    if (el) { el.remove(); }
                }
                var masks = document.querySelectorAll('.vc-captcha-mask,.vc-captcha-mask-container,[class*="captcha-mask"]');
                for (var j = 0; j < masks.length; j++) { masks[j].remove(); }
            }
            window.addEventListener('message', function (event) {
                if (event.data && event.data.__hgCaptchaDone) { hgCloseCaptcha(); }
            });
            // 发送成功后网页会把按钮变成「60s后重新发送」，以此为准关闭遮罩
            setInterval(function () {
                if (!document.getElementById('captcha_container') && !document.getElementById('vc_captcha_box')) { return; }
                var send = document.querySelector('[role="dialog"] .web-login-button-input__button-text');
                var label = send ? (send.textContent || '') : '';
                if (/后重新发送|重新发送/.test(label)) { hgCloseCaptcha(); }
            }, 600);

            // 验证码 iframe 默认 300×150，装不下 552×344 的拼图；用样式表强制放大
            (function () {
                if (!document.getElementById('hg-captcha-frame-style')) {
                    var style = document.createElement('style');
                    style.id = 'hg-captcha-frame-style';
                    style.textContent = '#captcha_container{display:flex!important;align-items:center!important;justify-content:center!important}' +
                        '#captcha_container iframe{width:620px!important;height:520px!important;position:fixed!important;left:50%!important;top:50%!important;transform:translate(-50%,-50%)!important;border:0!important;border-radius:10px!important;background:#fff!important;z-index:111112!important}';
                    (document.head || document.documentElement).appendChild(style);
                }
                setInterval(function () {
                    var box = document.getElementById('captcha_container');
                    if (!box) { return; }
                    var frame = box.querySelector('iframe');
                    if (!frame) { return; }
                    frame.style.setProperty('width', '620px', 'important');
                    frame.style.setProperty('height', '520px', 'important');
                    frame.style.setProperty('position', 'fixed', 'important');
                    frame.style.setProperty('left', '50%', 'important');
                    frame.style.setProperty('top', '50%', 'important');
                    frame.style.setProperty('transform', 'translate(-50%, -50%)', 'important');
                    frame.style.setProperty('z-index', '111112', 'important');
                }, 500);
            })();

            // 把验证码接口的服务端结果直接提示出来，避免用户看不到行内错误
            (function () {
                var nativeOpen = XMLHttpRequest.prototype.open;
                var nativeSend = XMLHttpRequest.prototype.send;
                XMLHttpRequest.prototype.open = function (method, url) {
                    this.__hgUrl = String(url || '');
                    return nativeOpen.apply(this, arguments);
                };
                XMLHttpRequest.prototype.send = function () {
                    var self = this;
                    if (self.__hgUrl && self.__hgUrl.indexOf('/passport/web/send_code/') >= 0) {
                        self.addEventListener('loadend', function () {
                            try {
                                var payload = JSON.parse(self.responseText || '{}');
                                var data = payload.data || {};
                                if (data.error_code === 0) {
                                    hgToast('验证码已发送，请查收短信');
                                    hgCloseCaptcha();
                                } else if (data.description) {
                                    hgToast(String(data.description));
                                }
                            } catch (e) {}
                        });
                    }
                    return nativeSend.apply(this, arguments);
                };

                // 验证码通过后 SDK 可能改用 fetch 重新发请求，这里同样兜住
                var nativeFetch = window.fetch;
                window.fetch = function (input) {
                    var url = typeof input === 'string' ? input : ((input && input.url) || '');
                    return nativeFetch.apply(this, arguments).then(function (response) {
                        if (url.indexOf('/passport/web/send_code/') >= 0) {
                            response.clone().text().then(function (text) {
                                try {
                                    var payload = JSON.parse(text);
                                    var data = payload.data || {};
                                    if (data.error_code === 0) {
                                        hgToast('验证码已发送，请查收短信');
                                        hgCloseCaptcha();
                                    } else if (data.description) {
                                        hgToast(String(data.description));
                                    }
                                } catch (e) {}
                            }).catch(function () {});
                        }
                        return response;
                    });
                };
            })();


        })();
        """
        controller.addUserScript(WKUserScript(source: cosmetic,
                                             injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: true))
        // 验证码 iframe 默认只有 300×150，内部拼图是 552×344，直接放不下。
        // 给它足够的尺寸并居中。
        controller.addUserScript(WKUserScript(source: MainWindowController.captchaFrameFixScript,
                                             injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: true))
        // WKWebView 的 window.outerWidth/outerHeight 恒为 0，验证码 SDK 会把
        // browser 尺寸当成 0x0，导致 iframe 内容渲染异常。这里补成屏幕尺寸。
        controller.addUserScript(WKUserScript(source: MainWindowController.viewportFixScript,
                                             injectionTime: .atDocumentStart,
                                             forMainFrameOnly: false))
        // 只读诊断：找到滑块节点后上报，不修改页面
        controller.addUserScript(WKUserScript(source: MainWindowController.captchaDiagScript,
                                             injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: false))
    }

    /// 验证码 iframe 尺寸修正（父页面执行）。
    static let captchaFrameFixScript = """
    (function () {
        function fix() {
            var box = document.getElementById('captcha_container');
            if (!box) { return; }
            var frame = box.querySelector('iframe');
            if (!frame) { return; }
            try {
                box.style.setProperty('display', 'flex', 'important');
                box.style.setProperty('align-items', 'center', 'important');
                box.style.setProperty('justify-content', 'center', 'important');
                frame.style.setProperty('width', '620px', 'important');
                frame.style.setProperty('height', '520px', 'important');
                frame.style.setProperty('position', 'fixed', 'important');
                frame.style.setProperty('left', '50%', 'important');
                frame.style.setProperty('top', '50%', 'important');
                frame.style.setProperty('transform', 'translate(-50%, -50%)', 'important');
                frame.style.setProperty('border', '0', 'important');
                frame.style.setProperty('border-radius', '10px', 'important');
                frame.style.setProperty('background', '#fff', 'important');
                frame.style.setProperty('z-index', '111112', 'important');
            } catch (e) {}
        }
        setInterval(fix, 500);
    })();
    """

    /// 修正 WKWebView 中 outerWidth/outerHeight 为 0 的问题。
    static let viewportFixScript = """
    (function () {
        try {
            if (window.__hgViewportFixed) { return; }
            window.__hgViewportFixed = true;
            Object.defineProperty(window, 'outerWidth', {
                configurable: true,
                get: function () { return (window.screen && window.screen.width) || window.innerWidth || 1280; }
            });
            Object.defineProperty(window, 'outerHeight', {
                configurable: true,
                get: function () { return (window.screen && window.screen.height) || window.innerHeight || 800; }
            });
        } catch (e) {}
    })();
    """

    /// 只读诊断：抓取「滑动滑块进行验证」节点的真实结构/坐标/样式。
    static let captchaDiagScript = """
    (function () {
        if (window.__hgDiagInstalled) { return; }
        window.__hgDiagInstalled = true;
        var sent = false;
        function post(data) {
            try { window.webkit.messageHandlers.hgBridge.postMessage({ name: 'captchaDiag', data: data }); } catch (e) {}
        }
        function scan() {
            if (sent || !document.body) { return; }
            var nodes = document.querySelectorAll('[id*="captcha" i],[class*="captcha" i]');
            var real = [];
            for (var n = 0; n < nodes.length; n++) {
                var candidate = nodes[n];
                var candidateId = String(candidate.id || '');
                if (candidateId === 'hg-captcha-frame-style' || candidateId === 'hg-adblock-style' || candidateId === 'hg-login-style') { continue; }
                var candidateRect = candidate.getBoundingClientRect();
                if (candidateRect.width > 80 && candidateRect.height > 30) { real.push(candidate); }
            }
            var text = '';
            try { text = document.body.innerText || ''; } catch (e) {}
            if (text.indexOf('滑动滑块进行验证') < 0 && real.length === 0) { return; }
            var target = null;
            if (text.indexOf('滑动滑块进行验证') >= 0) {
                var all = document.body.querySelectorAll('*');
                for (var i = 0; i < all.length && i < 6000; i++) {
                    var el = all[i];
                    if (el.children.length === 0 && (el.textContent || '').indexOf('滑动滑块进行验证') >= 0) {
                        target = el;
                        break;
                    }
                }
            }
            if (!target && real.length > 0) { target = real[0]; }
            if (!target) { return; }
            sent = true;
            var chain = [];
            var node = target;
            for (var d = 0; d < 8 && node; d++) {
                var r = node.getBoundingClientRect();
                var cs = getComputedStyle(node);
                chain.push({
                    tag: node.tagName,
                    id: node.id,
                    cls: String(node.className).slice(0, 160),
                    rect: { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) },
                    position: cs.position,
                    z: cs.zIndex,
                    display: cs.display,
                    visibility: cs.visibility,
                    opacity: cs.opacity,
                    transform: cs.transform,
                    background: cs.backgroundColor
                });
                node = node.parentElement;
            }
            var frames = [];
            var iframes = document.querySelectorAll('iframe');
            for (var j = 0; j < iframes.length; j++) {
                var fr = iframes[j].getBoundingClientRect();
                var src = String(iframes[j].src || '');
                var envValue = null;
                var match = src.match(/[?&]env=([^&]+)/);
                if (match) { try { envValue = JSON.parse(decodeURIComponent(match[1])); } catch (e) {} }
                frames.push({ src: src.slice(0, 2000), env: envValue, rect: { x: Math.round(fr.x), y: Math.round(fr.y), w: Math.round(fr.width), h: Math.round(fr.height) } });
            }
            post({
                frame: String(location.href).slice(0, 200),
                isTop: window === window.top,
                vw: window.innerWidth,
                vh: window.innerHeight,
                text: text.slice(0, 400),
                html: (target.outerHTML || '').slice(0, 2000),
                chain: chain,
                iframes: frames
            });
        }
        setInterval(scan, 1000);

        // 验证码 iframe 内部探针（跨域 frame 也会被注入）
        if (/rmc\\.bytedance\\.com|verify\\.zijieapi\\.com/.test(location.href)) {
            setInterval(function () {
                var text = document.body ? (document.body.innerText || '') : '';
                if (/验证成功|验证通过|操作成功/.test(text)) {
                    try { window.parent.postMessage({ __hgCaptchaDone: true }, '*'); } catch (e) {}
                }
            }, 500);
            var errors = [];
            window.addEventListener('error', function (event) {
                var target = event.target;
                if (target && (target.tagName === 'IMG' || target.tagName === 'SCRIPT')) {
                    errors.push({ tag: target.tagName, src: String(target.src || '').slice(0, 600) });
                }
            }, true);
            function probe(stage) {
                try {
                    var body = document.body ? document.body.innerText : '';
                    var imgs = Array.prototype.slice.call(document.querySelectorAll('img'), 0, 8).map(function (i) {
                        return { src: String(i.src || '').slice(0, 600), w: i.naturalWidth, h: i.naturalHeight, complete: i.complete };
                    });
                    post({
                        kind: 'frameProbe',
                        stage: stage,
                        frame: location.href.slice(0, 300),
                        ready: document.readyState,
                        title: document.title,
                        text: body.slice(0, 400),
                        imgs: imgs,
                        errors: errors,
                        canvases: document.querySelectorAll('canvas').length,
                        vw: window.innerWidth,
                        vh: window.innerHeight
                    });
                } catch (e) {}
            }
            setTimeout(function () { probe('3s'); }, 3000);
            setTimeout(function () { probe('10s'); }, 10000);
        }
    })();
    """

    private func observeWebView() {
        let keys = ["canGoBack", "canGoForward", "estimatedProgress", "isLoading", "title", "url"]
        for key in keys {
            webView.addObserver(self, forKeyPath: key, options: [.new], context: nil)
        }
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [weak self] in
            self?.refreshChrome()
        }
    }

    private func refreshChrome() {
        backItem?.isEnabled = webView.canGoBack
        forwardItem?.isEnabled = webView.canGoForward

        if let title = webView.title, !title.isEmpty {
            window?.subtitle = MainWindowController.subtitle(from: title)
        } else {
            window?.subtitle = ""
        }

        if webView.isLoading {
            progressBar.isHidden = false
            progressBar.alphaValue = 1
            progressBar.doubleValue = min(max(webView.estimatedProgress, 0.02), 1)
        } else if !progressBar.isHidden {
            progressBar.doubleValue = 1
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                progressBar.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.progressBar.isHidden = true
                self?.progressBar.alphaValue = 1
            })
        }

        if let url = webView.url, isInternal(url) {
            UserDefaults.standard.set(url.absoluteString, forKey: MainWindowController.lastURLKey)
        }
    }

    private func loadInitialPage() {
        #if HGTEST
        if let raw = ProcessInfo.processInfo.environment["HG_TEST_URL"], let url = URL(string: raw) {
            webView.load(URLRequest(url: url))
            return
        }
        #endif
        var target = MainWindowController.homeURL
        if let saved = UserDefaults.standard.string(forKey: MainWindowController.lastURLKey),
           let url = URL(string: saved),
           isInternal(url) {
            target = url
        }
        webView.load(URLRequest(url: target))
    }

    // MARK: - 工具栏动作

    @objc func goBack(_ sender: Any?) {
        webView.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        webView.goForward()
    }

    @objc func goHome(_ sender: Any?) {
        webView.load(URLRequest(url: MainWindowController.homeURL))
    }

    @objc func reloadPage(_ sender: Any?) {
        if webView.url == nil {
            loadInitialPage()
        } else {
            webView.reload()
        }
    }

    @objc func resetWebData(_ sender: Any?) {
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            DispatchQueue.main.async {
                UserDefaults.standard.removeObject(forKey: MainWindowController.lastURLKey)
                self?.webView.load(URLRequest(url: MainWindowController.homeURL))
                self?.showToast("已重置登录环境，请重新尝试")
            }
        }
    }

    @objc func openLoginWindow(_ sender: Any?) {
        if loginWindowController == nil {
            loginWindowController = LoginWindowController { [weak self] in
                self?.webView.reload()
            }
        }
        loginWindowController?.showWindow(nil)
        loginWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openInBrowser(_ sender: Any?) {
        if let url = webView.url {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openOfficialSite(_ sender: Any?) {
        NSWorkspace.shared.open(MainWindowController.homeURL)
    }

    @objc func toggleFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }

    @objc func zoomIn(_ sender: Any?) {
        webView.pageZoom = min(2.0, webView.pageZoom + 0.1)
    }

    @objc func zoomOut(_ sender: Any?) {
        webView.pageZoom = max(0.5, webView.pageZoom - 0.1)
    }

    @objc func actualSize(_ sender: Any?) {
        webView.pageZoom = 1.0
    }

    @objc func toggleAdBlock(_ sender: Any?) {
        let enabled = !AdBlocker.shared.isEnabled
        AdBlocker.shared.isEnabled = enabled
        AdBlocker.shared.apply(to: webView.configuration.userContentController)
        let js = "window.__hgAdBlockOn = \(enabled ? "true" : "false"); window.__hgAdBlockApply && window.__hgAdBlockApply();"
        webView.evaluateJavaScript(js, completionHandler: nil)
        updateAdBlockAppearance()
        showToast(enabled ? "广告拦截已开启" : "广告拦截已关闭")
    }

    private func updateAdBlockAppearance() {
        let enabled = AdBlocker.shared.isEnabled
        let symbol = enabled ? "shield.lefthalf.filled" : "shield.slash"
        adBlockItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "广告拦截")
        adBlockItem?.toolTip = enabled ? "广告拦截：已开启" : "广告拦截：已关闭"
        MenuBuilder.adBlockItem?.state = enabled ? .on : .off
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(string: "非官方 Mac 客户端\n视频由红果短剧官方网页播放，本应用仅提供窗口、去广告与播放增强。",
                                         attributes: [
                                            .font: NSFont.systemFont(ofSize: 11),
                                            .foregroundColor: NSColor.secondaryLabelColor
                                         ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "红果",
            .applicationVersion: "1.0.0",
            .credits: credits
        ])
    }

    // MARK: - 播放状态

    private func setPlaying(_ playing: Bool) {
        if playing {
            if activityToken == nil {
                activityToken = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled],
                                                                      reason: "红果视频播放中")
            }
        } else if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    private func storeProgress(path: String, time: Double) {
        var map = Self.resumeMap
        if time < 5 {
            map.removeValue(forKey: path)
        } else {
            map[path] = time
        }
        if map.count > 400 {
            let removable = Array(map.keys.prefix(map.count - 300))
            for key in removable {
                map.removeValue(forKey: key)
            }
        }
        UserDefaults.standard.set(map, forKey: MainWindowController.progressKey)
    }

    private static var resumeMap: [String: Double] {
        return UserDefaults.standard.dictionary(forKey: MainWindowController.progressKey) as? [String: Double] ?? [:]
    }

    private func showToast(_ text: String) {
        guard let content = window?.contentView else { return }
        toastView?.removeFromSuperview()

        let container = NSVisualEffectView()
        container.material = .hudWindow
        container.blendingMode = .withinWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true
        container.alphaValue = 0

        let label = NSTextField(labelWithString: text)
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        content.addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
            container.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -30)
        ])

        toastView = container

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            container.animator().alphaValue = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak container] in
            guard let container = container else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                container.animator().alphaValue = 0
            }, completionHandler: {
                container.removeFromSuperview()
            })
        }
    }

    // MARK: - 工具

    private func isInternal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "hongguoduanju.com" || host.hasSuffix(".hongguoduanju.com")
    }

    private func openOrLoad(_ url: URL) {
        if isInternal(url) {
            webView.load(URLRequest(url: url))
        } else if url.scheme == "http" || url.scheme == "https" || url.scheme == "mailto" {
            NSWorkspace.shared.open(url)
        }
    }

    private static func subtitle(from title: String) -> String {
        var value = title.components(separatedBy: "|").first ?? title
        let junk = ["红果短剧", "免费短剧全集无广告", "好看的短剧尽在红果短剧官网", "_", "-红果", " - 红果"]
        for piece in junk {
            value = value.replacingOccurrences(of: piece, with: " ")
        }
        value = value.replacingOccurrences(of: "  ", with: " ")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > 42 {
            value = String(value.prefix(42))
        }
        return value
    }

    private static func jsonString(_ object: [String: Double]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static var cssLiteral: String {
        guard let data = try? JSONSerialization.data(withJSONObject: [AdBlocker.cosmeticCSS]),
              let json = String(data: data, encoding: .utf8) else {
            return "''"
        }
        // JSON 数组 -> JS 数组字面量，取第一个元素
        return "[\(String(json.dropFirst().dropLast()))][0]"
    }

    // MARK: - 注入脚本

    /// 登录 SDK 会用隐藏 iframe 探测 bitbrowser://cc/，WebKit 会弹出
    /// “未设定用来打开 URL 的应用程序”系统弹窗。只拦这一个协议，
    /// 不要影响相对路径 / 协议相对 / 验证码 iframe 等正常资源。
    private static let schemeGuardScript = """
    (function () {
        try {
            function isBlocked(value) {
                var v = String(value == null ? '' : value).trim().toLowerCase();
                return v.indexOf('bitbrowser:') === 0;
            }
            var proto = HTMLIFrameElement.prototype;
            var descriptor = Object.getOwnPropertyDescriptor(proto, 'src');
            if (descriptor && descriptor.set) {
                Object.defineProperty(proto, 'src', {
                    configurable: true,
                    get: descriptor.get,
                    set: function (value) {
                        if (isBlocked(value)) { return; }
                        descriptor.set.call(this, value);
                    }
                });
            }
            var setAttr = proto.setAttribute;
            proto.setAttribute = function (name, value) {
                if (String(name).toLowerCase() === 'src' && isBlocked(value)) { return; }
                return setAttr.apply(this, arguments);
            };
            var nativeOpen = window.open;
            window.open = function (url) {
                if (isBlocked(url)) { return null; }
                return nativeOpen.apply(window, arguments);
            };
            document.addEventListener('click', function (event) {
                var anchor = event.target && event.target.closest ? event.target.closest('a[href]') : null;
                if (!anchor) { return; }
                var href = String(anchor.getAttribute('href') || '');
                if (isBlocked(href) || href.trim().toLowerCase().indexOf('dragon8662:') === 0) {
                    event.preventDefault();
                    event.stopPropagation();
                }
            }, true);
        } catch (e) {}
    })();
    """

    private static let runtimeScript = """
    (function () {
        if (window.__hgRuntimeInstalled) { return; }
        window.__hgRuntimeInstalled = true;

        function post(name, data) {
            try { window.webkit.messageHandlers.hgBridge.postMessage({ name: name, data: data }); } catch (e) {}
        }
        function video() { return document.querySelector('video'); }
        function isPlayerPage() { return /^\\/player\\//.test(location.pathname); }

        var resumed = {};
        var lastReport = 0;

        function tryResume() {
            window.__hgResumeTries = (window.__hgResumeTries || 0) + 1;
            if (!isPlayerPage()) { return; }
            var key = location.pathname;
            if (resumed[key]) { return; }
            var map = window.__hgSaved || {};
            var savedTime = map[key];
            if (!(savedTime > 5)) { return; }
            var v = video();
            if (!v || v.readyState < 1 || !isFinite(v.duration) || v.duration <= 0) { return; }
            if (savedTime < v.duration - 5 && v.currentTime < 5) {
                try { v.currentTime = savedTime; window.__hgLastResume = Math.round(savedTime); } catch (e) {}
            }
            resumed[key] = true;
        }

        function report(force) {
            var v = video();
            if (!v || !isPlayerPage() || !isFinite(v.duration) || v.duration < 20) { return; }
            var now = Date.now();
            if (!force && now - lastReport < 5000) { return; }
            lastReport = now;
            var key = location.pathname;
            if (v.currentTime > 5 && v.currentTime < v.duration - 5) {
                window.__hgSaved = window.__hgSaved || {};
                window.__hgSaved[key] = v.currentTime;
                post('progress', { path: key, time: v.currentTime });
            }
        }

        document.addEventListener('play', function (e) {
            if (e.target && e.target.tagName === 'VIDEO') { post('media', 'play'); }
        }, true);

        document.addEventListener('pause', function (e) {
            if (e.target && e.target.tagName === 'VIDEO') { post('media', 'pause'); report(true); }
        }, true);

        document.addEventListener('ended', function (e) {
            if (e.target && e.target.tagName === 'VIDEO') {
                post('media', 'pause');
                post('progress', { path: location.pathname, time: 0 });
            }
        }, true);

        document.addEventListener('timeupdate', function (e) {
            if (e.target && e.target.tagName === 'VIDEO') { report(false); }
        }, true);

        window.addEventListener('pagehide', function () { report(true); post('media', 'pause'); });

        setInterval(function () { tryResume(); report(false); }, 1500);
    })();
    """
}

// MARK: - WKScriptMessageHandler

extension MainWindowController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let payload = message.body as? [String: Any],
              let name = payload["name"] as? String else { return }

        switch name {
        case "media":
            if let state = payload["data"] as? String {
                setPlaying(state == "play")
            }
        case "progress":
            if let data = payload["data"] as? [String: Any],
               let path = data["path"] as? String,
               let time = data["time"] as? Double {
                storeProgress(path: path, time: time)
            }
        case "toast":
            if let text = payload["data"] as? String, !text.isEmpty {
                showToast(text)
                #if HGTEST
                toastCount += 1
                #endif
            }
        case "captchaDiag":
            if let data = payload["data"] as? [String: Any],
               let lineData = try? JSONSerialization.data(withJSONObject: data),
               let line = String(data: lineData, encoding: .utf8) {
                let path = "/tmp/hongguo-captcha.jsonl"
                if let handle = FileHandle(forWritingAtPath: path) {
                    handle.seekToEndOfFile()
                    if let bytes = (line + "\n").data(using: .utf8) { handle.write(bytes) }
                    handle.closeFile()
                } else {
                    try? (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
                }
                webView.takeSnapshot(with: nil) { image, _ in
                    guard let image = image,
                          let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff),
                          let png = rep.representation(using: .png, properties: [:]) else { return }
                    try? png.write(to: URL(fileURLWithPath: "/tmp/hongguo-captcha.png"))
                }
            }
        default:
            break
        }
    }
}

// MARK: - 导航与窗口

extension MainWindowController: WKNavigationDelegate, WKUIDelegate, NSWindowDelegate, NSMenuItemValidation {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        setPlaying(false)
        backItem?.isEnabled = webView.canGoBack
        forwardItem?.isEnabled = webView.canGoForward
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let saved = MainWindowController.jsonString(Self.resumeMap)
        webView.evaluateJavaScript("window.__hgSaved = \(saved);", completionHandler: nil)
        refreshChrome()
        #if HGTEST
        if ProcessInfo.processInfo.environment["HG_TEST_LOGIN"] != nil {
            runLoginTest()
        } else {
            scheduleTestReport()
        }
        #endif
    }

    #if HGTEST
    private func runLoginTest() {
        guard ProcessInfo.processInfo.environment["HG_TEST_OUT"] != nil, !didScheduleTest else { return }
        didScheduleTest = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let js = """
            (function(){
              var el = Array.from(document.querySelectorAll('span,div,a,button')).filter(function(e){
                return e.children.length === 0 && e.textContent.trim() === '登录';
              })[0];
              if (el) el.click();
              return el ? 'clicked' : 'no-login';
            })()
            """
            self.webView.evaluateJavaScript(js, completionHandler: nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            let js = """
            (function(){
              var d = document.querySelector('[role="dialog"]');
              var wrap = document.querySelector('.web-login-scan-code__content__qrcode-wrapper');
              var img = wrap ? wrap.querySelector('img') : null;
              var note = d ? d.querySelector('[class*="agreement-note__text"]') : null;
              var cb = d ? d.querySelector('input[type="checkbox"]') : null;
              var checkedBefore = cb ? cb.checked : null;
              if (note) { note.click(); }
              var checkedAfter = cb ? cb.checked : null;
              if (cb && cb.checked) { cb.click(); }
              var send = d ? d.querySelector('.web-login-button-input__button-text') : null;
              if (send) { send.dispatchEvent(new MouseEvent('mousedown', { bubbles: true, cancelable: true, view: window })); }
              return JSON.stringify({
                dialog: !!d,
                qrDisplay: wrap ? getComputedStyle(wrap).display : 'none',
                qrW: img ? img.naturalWidth : 0,
                qrH: img ? img.naturalHeight : 0,
                promo: (function(){ var p = document.querySelector('[class*="pc-download-"]'); return p ? getComputedStyle(p).display : 'none'; })(),
                checkboxBefore: checkedBefore,
                checkboxAfterTextClick: checkedAfter,
                adStyle: !!document.getElementById('hg-adblock-style'),
                badFrames: Array.from(document.querySelectorAll('iframe')).map(function(f){ return f.getAttribute('src') || ''; })
                    .filter(function(s){ return s && !/^(https?:|about:|data:|blob:)/i.test(s); })
              });
            })()
            """
            self.webView.evaluateJavaScript(js) { result, error in
                var payload: [String: Any] = ["login": result ?? NSNull()]
                if let error = error { payload["error"] = error.localizedDescription }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    payload["toastCount"] = self.toastCount
                    if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
                       let out = ProcessInfo.processInfo.environment["HG_TEST_OUT"] {
                        try? data.write(to: URL(fileURLWithPath: out))
                    }
                    NSApp.terminate(nil)
                }
            }
        }
    }
    #endif

    #if HGTEST
    private func scheduleTestReport() {
        guard ProcessInfo.processInfo.environment["HG_TEST_OUT"] != nil, !didScheduleTest else { return }
        didScheduleTest = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            let play = "var v=document.querySelector('video'); if(v){v.muted=true; v.play().catch(function(){});} 'ok';"
            self.webView.evaluateJavaScript(play, completionHandler: nil)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 14) {
            let js = """
            (function(){
              var v = document.querySelector('video');
              var promo = document.querySelector('[class*="pc-download-"]');
              var style = document.getElementById('hg-adblock-style');
              var before = !!style;
              window.__hgAdBlockOn = false; window.__hgAdBlockApply();
              var off = !!document.getElementById('hg-adblock-style');
              window.__hgAdBlockOn = true; window.__hgAdBlockApply();
              var back = !!document.getElementById('hg-adblock-style');
              return JSON.stringify({
                url: location.href,
                title: document.title,
                video: v ? { ready: v.readyState, cur: v.currentTime, dur: v.duration, paused: v.paused, err: v.error ? v.error.code : null } : null,
                promoHidden: promo ? getComputedStyle(promo).display : 'not-found',
                adStyle: before,
                toggleOff: off,
                toggleBack: back,
                lastResume: window.__hgLastResume || null,
                savedKeys: Object.keys(window.__hgSaved || {}),
                resumeTries: window.__hgResumeTries || 0,
                quality: (document.body.innerText.match(/\\d{3}P/g) || []).join(',')
              });
            })()
            """
            self.webView.evaluateJavaScript(js) { result, error in
                var payload: [String: Any] = ["js": result ?? NSNull()]
                if let error = error { payload["error"] = error.localizedDescription }
                payload["window"] = [
                    "visible": self.window?.isVisible ?? false,
                    "frame": NSStringFromRect(self.window?.frame ?? .zero),
                    "subtitle": self.window?.subtitle ?? "",
                    "title": self.window?.title ?? "",
                    "toolbar": self.window?.toolbar?.items.map { $0.itemIdentifier.rawValue } ?? []
                ]
                payload["menu"] = NSApp.mainMenu?.items.map { $0.title } ?? []
                if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
                   let out = ProcessInfo.processInfo.environment["HG_TEST_OUT"] {
                    try? data.write(to: URL(fileURLWithPath: out))
                }
                NSApp.terminate(nil)
            }
        }
    }
    #endif

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        refreshChrome()
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        if url.scheme == "about" || isInternal(url) {
            decisionHandler(.allow)
            return
        }

        // 子 frame（验证码 iframe 等）必须放行，否则 iframe 会是空白
        if let target = navigationAction.targetFrame, !target.isMainFrame {
            decisionHandler(.allow)
            return
        }

        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        if navigationAction.navigationType == .linkActivated || isMainFrame {
            openOrLoad(url)
        }
        // 其余为页面内的第三方 iframe / 统计跳转，直接丢弃。
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if isInternal(url) {
            webView.load(URLRequest(url: url))
        } else if navigationAction.navigationType == .linkActivated,
                  url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        setPlaying(false)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(goBack(_:)) {
            return webView.canGoBack
        }
        if menuItem.action == #selector(goForward(_:)) {
            return webView.canGoForward
        }
        if menuItem.action == #selector(zoomIn(_:)) {
            return webView.pageZoom < 1.99
        }
        if menuItem.action == #selector(zoomOut(_:)) {
            return webView.pageZoom > 0.51
        }
        if menuItem.action == #selector(actualSize(_:)) {
            return abs(webView.pageZoom - 1.0) > 0.001
        }
        if menuItem.action == #selector(toggleAdBlock(_:)) {
            menuItem.state = AdBlocker.shared.isEnabled ? .on : .off
        }
        return true
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {
    private enum ItemID {
        static let back = NSToolbarItem.Identifier("hg.back")
        static let forward = NSToolbarItem.Identifier("hg.forward")
        static let reload = NSToolbarItem.Identifier("hg.reload")
        static let home = NSToolbarItem.Identifier("hg.home")
        static let login = NSToolbarItem.Identifier("hg.login")
        static let adBlock = NSToolbarItem.Identifier("hg.adblock")
        static let browser = NSToolbarItem.Identifier("hg.browser")
        static let fullscreen = NSToolbarItem.Identifier("hg.fullscreen")
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [ItemID.back, ItemID.forward, ItemID.reload, ItemID.home, ItemID.login,
                ItemID.adBlock, ItemID.browser, ItemID.fullscreen,
                .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        return [ItemID.back, ItemID.forward, ItemID.reload, ItemID.home, ItemID.login,
                .flexibleSpace, ItemID.adBlock, ItemID.browser, ItemID.fullscreen]
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)

        switch itemIdentifier {
        case ItemID.back:
            item.label = "后退"
            item.toolTip = "后退"
            item.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "后退")
            item.action = #selector(goBack(_:))
            item.isNavigational = true
            backItem = item
        case ItemID.forward:
            item.label = "前进"
            item.toolTip = "前进"
            item.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "前进")
            item.action = #selector(goForward(_:))
            item.isNavigational = true
            forwardItem = item
        case ItemID.reload:
            item.label = "重新载入"
            item.toolTip = "重新载入"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "重新载入")
            item.action = #selector(reloadPage(_:))
        case ItemID.home:
            item.label = "首页"
            item.toolTip = "回到首页"
            item.image = NSImage(systemSymbolName: "house", accessibilityDescription: "首页")
            item.action = #selector(goHome(_:))
        case ItemID.login:
            item.label = "登录"
            item.toolTip = "打开独立登录窗口（无脚本注入，兼容滑块验证）"
            item.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: "登录")
            item.action = #selector(openLoginWindow(_:))
        case ItemID.adBlock:
            let enabled = AdBlocker.shared.isEnabled
            item.label = "广告拦截"
            item.toolTip = enabled ? "广告拦截：已开启" : "广告拦截：已关闭"
            item.image = NSImage(systemSymbolName: enabled ? "shield.lefthalf.filled" : "shield.slash",
                                 accessibilityDescription: "广告拦截")
            item.action = #selector(toggleAdBlock(_:))
            adBlockItem = item
        case ItemID.browser:
            item.label = "在浏览器中打开"
            item.toolTip = "在默认浏览器中打开"
            item.image = NSImage(systemSymbolName: "safari", accessibilityDescription: "浏览器")
            item.action = #selector(openInBrowser(_:))
        case ItemID.fullscreen:
            item.label = "全屏"
            item.toolTip = "进入全屏"
            item.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "全屏")
            item.action = #selector(toggleFullScreen(_:))
        default:
            return nil
        }

        item.target = self
        return item
    }
}
