import Cocoa

enum MenuBuilder {
    private(set) static weak var adBlockItem: NSMenuItem?

    static func install(target: MainWindowController) {
        let mainMenu = NSMenu()

        // 红果
        let appMenuItem = NSMenuItem(title: "红果", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        let about = NSMenuItem(title: "关于红果", action: #selector(MainWindowController.showAbout(_:)), keyEquivalent: "")
        about.target = target
        appMenu.addItem(about)
        let login = NSMenuItem(title: "登录红果…", action: #selector(MainWindowController.openLoginWindow(_:)), keyEquivalent: "l")
        login.keyEquivalentModifierMask = [.command, .shift]
        login.target = target
        appMenu.addItem(login)
        let reset = NSMenuItem(title: "重置登录环境", action: #selector(MainWindowController.resetWebData(_:)), keyEquivalent: "")
        reset.target = target
        appMenu.addItem(reset)
        appMenu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏红果", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        appMenu.addItem(hide)
        let hideOthers = NSMenuItem(title: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = NSApp
        appMenu.addItem(hideOthers)
        let showAll = NSMenuItem(title: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        showAll.target = NSApp
        appMenu.addItem(showAll)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出红果", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        appMenu.addItem(quit)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 编辑（走响应链，交给网页处理）
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(NSMenuItem(title: "撤销", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "剪切", action: Selector(("cut:")), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "拷贝", action: Selector(("copy:")), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "粘贴", action: Selector(("paste:")), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "全选", action: Selector(("selectAll:")), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // 浏览
        let browseItem = NSMenuItem(title: "浏览", action: nil, keyEquivalent: "")
        let browseMenu = NSMenu(title: "浏览")
        add(browseMenu, "后退", #selector(MainWindowController.goBack(_:)), "[", [.command], target)
        add(browseMenu, "前进", #selector(MainWindowController.goForward(_:)), "]", [.command], target)
        browseMenu.addItem(.separator())
        add(browseMenu, "回到首页", #selector(MainWindowController.goHome(_:)), "h", [.command, .shift], target)
        add(browseMenu, "重新载入", #selector(MainWindowController.reloadPage(_:)), "r", [.command], target)
        browseMenu.addItem(.separator())
        add(browseMenu, "在默认浏览器中打开", #selector(MainWindowController.openInBrowser(_:)), "o", [.command, .shift], target)
        browseItem.submenu = browseMenu
        mainMenu.addItem(browseItem)

        // 显示
        let viewItem = NSMenuItem(title: "显示", action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: "显示")
        add(viewMenu, "广告拦截", #selector(MainWindowController.toggleAdBlock(_:)), "a", [.command, .shift], target)
        adBlockItem = viewMenu.items.last
        adBlockItem?.state = .on
        viewMenu.addItem(.separator())
        add(viewMenu, "放大", #selector(MainWindowController.zoomIn(_:)), "+", [.command], target)
        add(viewMenu, "缩小", #selector(MainWindowController.zoomOut(_:)), "-", [.command], target)
        add(viewMenu, "实际大小", #selector(MainWindowController.actualSize(_:)), "0", [.command], target)
        viewMenu.addItem(.separator())
        let fullscreen = NSMenuItem(title: "进入全屏", action: #selector(MainWindowController.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.command, .control]
        fullscreen.target = target
        viewMenu.addItem(fullscreen)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // 窗口
        let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        windowMenu.addItem(.separator())
        windowMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        // 帮助
        let helpItem = NSMenuItem(title: "帮助", action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: "帮助")
        add(helpMenu, "打开红果官网", #selector(MainWindowController.openOfficialSite(_:)), "", [.command], target)
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)

        NSApp.mainMenu = mainMenu
    }

    @discardableResult
    private static func add(_ menu: NSMenu,
                            _ title: String,
                            _ action: Selector,
                            _ key: String,
                            _ modifiers: NSEvent.ModifierFlags = [.command],
                            _ target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        menu.addItem(item)
        return item
    }
}
