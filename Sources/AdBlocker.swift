import Foundation
import WebKit

/// 基于 WKContentRuleList 的网络层广告拦截 + 依赖注入的页面美化规则。
final class AdBlocker {
    static let shared = AdBlocker()

    private let ruleListIdentifier = "HongguoAdRulesV1"
    private let defaultsKey = "AdBlockEnabled"
    private let store = WKContentRuleListStore.default()
    private(set) var ruleList: WKContentRuleList?

    private init() {}

    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: defaultsKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: defaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
        }
    }

    /// 编译（或读取缓存）拦截规则。完成后回调主线程。
    func prepare(completion: @escaping () -> Void) {
        let finish: () -> Void = { DispatchQueue.main.async { completion() } }

        guard let store = store else {
            finish()
            return
        }

        store.lookUpContentRuleList(forIdentifier: ruleListIdentifier) { [weak self] list, _ in
            if let list = list {
                self?.ruleList = list
                finish()
                return
            }
            store.compileContentRuleList(forIdentifier: self?.ruleListIdentifier ?? "HongguoAdRulesV1",
                                         encodedContentRuleList: AdBlocker.rulesJSON) { list, error in
                if let error = error {
                    NSLog("广告规则编译失败: %@", error.localizedDescription)
                }
                self?.ruleList = list
                finish()
            }
        }
    }

    /// 把规则挂到 UserContentController；关闭时彻底移除。
    func apply(to controller: WKUserContentController) {
        controller.removeAllContentRuleLists()
        if isEnabled, let list = ruleList {
            controller.add(list)
        }
    }

    /// 纯 CSS 的页面清理：只处理 APP 下载推广与下载浮层。
    /// 注意：不要匹配 "qrcode"，登录弹窗的二维码就是 qrcode 类名。
    static let cosmeticCSS = """
    [class*="pc-download-"],
    [class*="pc-hero-download"],
    [class*="download-bar"] {
        display: none !important;
    }
    """

    /// 广告平台 / 推广归因域名（不影响视频 CDN 与页面资源）。
    private static let blockedHosts: [String] = [
        "pangle.io",
        "pangolin-sdk-toutiao.com",
        "oceanengine.com",
        "ad.oceanengine.com",
        "gdt.qq.com",
        "e.qq.com",
        "doubleclick.net",
        "googlesyndication.com",
        "googleadservices.com",
        "adnxs.com",
        "criteo.com",
        "taboola.com",
        "outbrain.com",
        "umeng.com",
        "umeng.co",
        "cnzz.com",
        "miaozhen.com",
        "admaster.com.cn",
        "zlink.toutiao.com"
    ]

    static let rulesJSON: String = {
        let rules: [[String: Any]] = blockedHosts.map { host in
            let escaped = host.replacingOccurrences(of: ".", with: "\\.")
            return [
                "trigger": ["url-filter": "^https?://([^/]+\\.)?\(escaped)[:/]"],
                "action": ["type": "block"]
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules) else { return "[]" }
        return String(data: data, encoding: .utf8) ?? "[]"
    }()
}
