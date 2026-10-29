from pathlib import Path
import plistlib
root=Path(__file__).resolve().parents[1]
p=root/'Ice.xcodeproj/project.pbxproj'
s=p.read_text().replace('com.jordanbaird.Ice','io.novarock.MacMenuY').replace('PRODUCT_NAME = "$(TARGET_NAME)";', 'PRODUCT_NAME = MacMenuY;').replace('DEVELOPMENT_TEAM = K2ATHQPJDP;', 'DEVELOPMENT_TEAM = BDH2HLQA9V;').replace('MARKETING_VERSION = 0.11.12;', 'MARKETING_VERSION = 1.0.0;')
p.write_text(s)
p=root/'Ice/Info.plist'
p.write_bytes(plistlib.dumps({'CFBundleDisplayName':'MacMenuY','NSHumanReadableCopyright':'MacMenuY contributors; menu bar engine © Jordan Baird, GPL-3.0','LSUIElement':True}))
p=root/'Ice/Utilities/Constants.swift'; s=p.read_text().replace('settingsWindowTitle = "Ice"','settingsWindowTitle = "MacMenuY"').replace('permissionsWindowTitle = "Permissions"','permissionsWindowTitle = "MacMenuY · 权限"'); p.write_text(s)
p=root/'Ice/Settings/SettingsManagers/GeneralSettingsManager.swift';s=p.read_text().replace('useIceBar = false','useIceBar = true').replace('iceBarLocation: IceBarLocation = .dynamic','iceBarLocation: IceBarLocation = .iceIcon').replace('showOnClick = true','showOnClick = false').replace('showOnScroll = true','showOnScroll = false');s=s.replace('        Defaults.ifPresent(key: .useIceBar, assign: &useIceBar)','        useIceBar = true');p.write_text(s)
p=root/'Ice/Main/AppState.swift';s=p.read_text().replace('    /// Manager for menu bar item spacing.','    private(set) lazy var shelfManager = ShelfManager(appState: self)\n\n    /// Manager for menu bar item spacing.').replace('        userNotificationManager.performSetup()','        userNotificationManager.performSetup()\n        shelfManager.performSetup()');p.write_text(s)
p=root/'Ice/MenuBar/MenuBarItems/MenuBarItemManager.swift';s=p.read_text().replace('    func cacheItemsIfNeeded() async {','    func refreshItems() async {\n        cachedItemWindowIDs = []\n        await cacheItemsIfNeeded()\n    }\n\n    func cacheItemsIfNeeded() async {');
# Surface native activation failures instead of only logging them.
a=s.index('    func tempShowItem(');b=s.index('    func rehideTempShownItems()',a)
section=s[a:b].replace('Logger.itemManager.error("ERROR: \\(error)")','Logger.itemManager.error("ERROR: \\(error)")\n                        appState?.shelfManager.message = "无法打开 \\(item.displayName)：\\(error.localizedDescription)"')
# Within the main Task appState is a nonoptional local binding.
section=section.replace('appState?.shelfManager.message', 'self.appState?.shelfManager.message')
s=s[:a]+section+s[b:];p.write_text(s)
p=root/'Ice/MenuBar/ControlItem/ControlItem.swift';s=p.read_text().replace('"Ice Settings…"','"MacMenuY 设置…"').replace('NSMenu(title: "Ice")','NSMenu(title: "MacMenuY")').replace('"Quit Ice"','"退出 MacMenuY"');p.write_text(s)
p=root/'Ice/Permissions/PermissionsView.swift';s=p.read_text().replace('"Ice needs permission to manage the menu bar."','"MacMenuY 需要辅助功能权限来移动和点击菜单栏图标。"').replace('"Absolutely no personal information is collected or stored."','"屏幕录制仅用于本机显示图标；无联网、无上传。"').replace('"Ice needs this to:"','"用途："').replace('"Ice can work in a limited mode without this permission."','"未授权屏幕录制时，列表将显示应用图标。"').replace('"Permissions"','"MacMenuY 权限"').replace('"Grant Permission"','"授权"').replace('"Permission Granted"','"已授权"').replace('"Continue in Limited Mode"','"继续（显示应用图标）"').replace('"Continue"','"开始使用"').replace('            appState.appDelegate?.openSettingsWindow()','');p.write_text(s)
