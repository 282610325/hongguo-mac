# 红果 Mac 客户端（非官方）

一个轻量的原生 macOS 客户端，用 WKWebView 承载红果短剧官方网页播放器，并在此基础上做了去广告、断点续播、登录兼容等增强。

> 非官方项目，与红果短剧 / 字节跳动无任何关联。视频内容版权归原平台所有，本项目不存储、不破解、不分发任何受版权保护的内容。

## 功能

- 原生 macOS 窗口（AppKit + WKWebView），保留官方播放器能力（720P、倍速、选集、全屏）
- 去广告：域名级拦截广告/推广/归因请求，隐藏「下载 App」推广位与二维码弹窗
- 断点续播：按剧集路径本地记录进度，下次打开自动续播
- 播放时阻止息屏，支持 HTML5 全屏、手势前进/后退、页面缩放
- 登录兼容：
  - 修复 WKWebView `outerWidth/outerHeight = 0` 导致的验证码空白
  - 放行子 frame 导航，让登录验证码 iframe 正常加载
  - 验证码 iframe 尺寸修正（300×150 → 620×520）
  - 验证码发送成功后自动关闭遮罩；发送结果以浮层显示服务端原文
  - 协议整行可点击、10 秒防连点，避免误触与限流
- 独立登录窗口（无广告拦截、无 UA 伪装），用于主窗口异常时兜底登录

## 构建

要求：macOS 12+，命令行工具（`swiftc`）。

```bash
./build.sh
```

产物为 `红果.app`（x86_64 + arm64 通用，ad-hoc 签名）。

运行：

```bash
open 红果.app
```

## 使用

- 首页、分类、榜单、搜索均在应用内浏览
- 播放页可直接选集；网页上带锁图标的剧集实际可播放
- 登录：点右上角「登录」，支持验证码登录 / 扫码登录
  - 短信发送受服务端风控影响，若提示 `访问太频繁，请稍后再试`，需等待冷却或更换网络
- 菜单「红果 → 重置登录环境」可清空 Cookie / 本地存储
- 菜单「红果 → 登录红果…」打开独立登录窗口

## 目录结构

```
Sources/
  main.swift                 程序入口
  AppDelegate.swift          App 生命周期
  MainWindowController.swift 主窗口、WKWebView、注入脚本、诊断
  LoginWindowController.swift 独立登录窗口
  AdBlocker.swift            广告域名规则与页面清理样式
  MenuBuilder.swift          菜单
Resources/Info.plist         App 配置
tools/makeicon.swift         图标生成
build.sh                     构建脚本
```

## 技术说明

- 播放走官方网页播放器，未绕开任何 DRM / 内容加密
- 播放信息接口：`POST /api/video/protected/play-info?aid=8662`
- 登录验证码为火山 RMC，渲染在 `rmc.bytedance.com` 的 iframe 中；WKWebView 下需要：
  1. 允许子 frame 导航
  2. 修正 `window.outerWidth/outerHeight`（WKWebView 恒为 0）
  3. 给 iframe 足够尺寸（拼图约 552×344）
- 短信接口：`POST /passport/web/send_code/`，风控返回 `error_code: 7`（访问太频繁）

## 已知限制

- 依赖官方网页版；官方改版后可能需要同步调整
- 短信登录受服务端 IP 限流影响，客户端无法绕过
- 非官方客户端，请自行评估使用风险

## 免责声明

本项目仅用于 macOS 桌面端与 WebView 技术学习交流，不得用于商业用途。所有视频、图片、商标等版权归红果短剧及相关权利人所有。
