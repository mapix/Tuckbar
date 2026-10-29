import LaunchAtLogin
import SwiftUI

struct MenuYGeneralPane: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var shelf: ShelfManager
    @EnvironmentObject var prefs: MenuYPreferences
    var body: some View {
        Form {
            Section {
                VStack(alignment:.leading,spacing:8) {
                    Label("Tuckbar · 菜单栏，留一个入口。",systemImage:"tray.full.fill").font(.title2.weight(.semibold))
                    Text("鼠标悬浮顶部入口，在系统菜单栏下方丝滑展开二级收纳栏。鼠标离开入口与收纳栏后自动收起；开启「整理」图钉模式时锁定面板不自动隐藏。")
                        .foregroundStyle(.secondary)
                }.padding(.vertical,8)
                Toggle("启用收纳",isOn:Binding(get:{shelf.isEnabled},set:{_ in shelf.toggleEnabled()})).disabled(shelf.isBusy)
                LaunchAtLogin.Toggle("登录时启动 Tuckbar")
                HStack {
                    #if MENUY_VERIFY
                    Button("调试预览") { appState.menuBarManager.section(withName:.visible)?.controlItem.openDrawer() }
                    #endif
                    Spacer()
                    Button("退出 Tuckbar") { NSApp.terminate(nil) }
                }
            }
            Section("悬浮与自动隐藏时机") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("悬浮展开延迟")
                        Spacer()
                        Text("\(Int((prefs.hoverEnterDelay * 1000).rounded())) ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $prefs.hoverEnterDelay, in: 0.05...0.60, step: 0.05)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("离开自动隐藏延迟")
                        Spacer()
                        Text("\(Int((prefs.hoverLeaveDelay * 1000).rounded())) ms")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $prefs.hoverLeaveDelay, in: 0.10...1.20, step: 0.05)
                }
                HStack {
                    Text("开启二级菜单栏内的「整理（图钉）」按钮时，自动隐藏将自动暂停，方便逐个切换图标常驻状态。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("恢复默认时机") {
                        prefs.hoverEnterDelay = 0.15
                        prefs.hoverLeaveDelay = 0.25
                    }.controlSize(.small)
                }
            }
            Section("操作说明") {
                LabeledContent("快速检索",value: "悬浮展开后直接输入应用名称")
                LabeledContent("原应用菜单",value: "左键、右键及 Option 等修饰键完整穿透")
                LabeledContent("固定/收回",value: "点击二级菜单栏「整理」锁定面板后逐个切换，或在项目管理页切换")
                LabeledContent("退出/停用",value: "入口右键菜单或二级菜单栏右侧快捷按钮")
            }
            Section("系统权限") {
                HStack {
                    Button("辅助功能设置") { appState.permissionsManager.accessibilityPermission.performRequest() }
                    Button("屏幕录制设置") { appState.permissionsManager.screenRecordingPermission.performRequest() }
                }
                Text("图标和菜单栏背景仅在本机实时合成。无法移动的系统固定项目保持原样，不遮挡系统菜单栏。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
struct MenuYAppearancePane: View {
    @EnvironmentObject var prefs: MenuYPreferences
    var body: some View {
        Form {
            Section("收纳栏样式") {
                Picker("风格",selection:$prefs.style) { ForEach(MenuYBarStyle.allCases,id:\.self) { Text($0.label).tag($0) } }
                Picker("图标大小",selection:$prefs.iconSize) {
                    ForEach(Array(Set([16,18,20,24,28,32,36,Int(prefs.iconSize)])).sorted(),id:\.self) { Text("\($0) pt").tag(Double($0)) }
                }
                VStack(alignment:.leading,spacing:8) {
                    HStack { Text("不透明度"); Spacer(); Text(prefs.opacity.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit() }
                    Slider(value:$prefs.opacity,in:0.4...1,step:0.01)
                }
                Text("默认 90% 不透明。原生风格沿用菜单栏背景；图标多时自动换行，超出屏幕高度时可滚动。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("预览") {
                HStack(spacing:18) {
                    ForEach(["wifi","battery.100percent","cloud","bell.badge","clock"],id:\.self) { Image(systemName:$0).font(.system(size:prefs.iconSize*0.75)) }
                }.frame(maxWidth:.infinity).padding(16).background(.regularMaterial,in:RoundedRectangle(cornerRadius:prefs.style == .native ? 3 : 12))
                    .opacity(prefs.opacity)
            }
            Button("恢复外观默认值") { prefs.opacity=MenuYStoredPreferences.defaultOpacity;prefs.iconSize=MenuYStoredPreferences.defaultIconSize;prefs.style = .native }
        }.formStyle(.grouped)
    }
}
struct MenuYSortPane: View {
    @EnvironmentObject var prefs: MenuYPreferences
    var body: some View {
        Form {
            Section("排序方式") {
                Picker("默认排序",selection:$prefs.sortMode) { ForEach(MenuYSortMode.allCases,id:\.self) { Text($0.label).tag($0) } }
                Text("优先规则先应用，再按默认方式排列。相同优先级保持稳定顺序。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("优先规则") {
                ForEach($prefs.rules) { $rule in
                    HStack {
                        TextField("应用名称或标识，例如 *Chrome*",text:$rule.pattern)
                        Stepper("优先级 \(rule.priority)",value:$rule.priority,in:-99...999).frame(width:150)
                        Button(role:.destructive) { let id = rule.id; prefs.rules.removeAll { $0.id == id } } label: { Image(systemName:"minus.circle") }.help("删除规则")
                    }
                }
                Button("添加规则",systemImage:"plus") { prefs.rules.append(MenuYSortRule(pattern:"",priority:0)) }.disabled(prefs.rules.count >= 128)
                Text("* 匹配任意文字，? 匹配一个字符。数字越小越靠前。规则只调整收纳栏显示顺序。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
struct MenuYNotificationsPane: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var prefs: MenuYPreferences
    @EnvironmentObject var activity: MenuYActivity
    private var apps: [MenuBarItem] {
        var seen=Set<String>()
        return appState.itemManager.itemCache.allItems.filter {
            $0.info.namespace != .ice && !$0.info.namespace.rawValue.hasPrefix("com.apple.") && seen.insert($0.info.namespace.rawValue).inserted
        }
    }
    var body: some View {
        Form {
            Section("统一提醒") {
                Toggle("入口提示有变化的应用",isOn:$prefs.activityEnabled)
                Text("原图标的红点、徽标与状态会实时镜像。入口按应用提示图标变化；只有应用明确提供未读数时才展示未读数，普通状态变化不会冒充未读消息。")
                    .font(.callout).foregroundStyle(.secondary)
                LabeledContent("图标变化",value: "\(activity.changedAppCount) 个应用")
                LabeledContent("可确认的未读提示",value: activity.unread.isEmpty ? "应用尚未提供" : "\(activity.unreadCount)")
                if !activity.unreadStale.isEmpty {
                    Text("\(activity.unreadStale.count) 项最近读取未完成，显示上次确认值。原图标仍持续镜像。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("清除变化提示") { activity.acknowledgeAll() }
            }
            Section("参与变化提醒的应用") {
                ForEach(apps,id:\.info.namespace) { item in
                    Toggle(item.displayName,isOn:Binding(get:{ !prefs.ignoredApps.contains(item.info.namespace.rawValue) },set:{ value in
                        if value { prefs.ignoredApps.remove(item.info.namespace.rawValue) }
                        else { prefs.ignoredApps.insert(item.info.namespace.rawValue) }
                    }))
                }
                Text("音乐进度、动画图标等可关闭变化提醒，原图标仍会镜像。系统录制/通话指示保持原样。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
struct MenuYItemsPane: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var shelf: ShelfManager
    @EnvironmentObject var cache: MenuBarItemImageCache
    @State private var query=""
    private var items:[MenuBarItem] {
        appState.itemManager.itemCache.allItems.filter { $0.info.namespace != .ice && (query.isEmpty || ($0.displayName+" "+($0.title ?? "")).localizedStandardContains(query)) }
    }
    var body: some View {
        VStack(spacing:12) {
            TextField("检索项目",text:$query).textFieldStyle(.roundedBorder)
            List(items,id:\.windowID) { item in
                HStack(spacing:12) {
                    if let cg=cache.images[item.windowID] { Image(nsImage:NSImage(cgImage:cg,size:CGSize(width:cg.width,height:cg.height))).resizable().aspectRatio(contentMode:.fit).frame(width:30,height:24) }
                    VStack(alignment:.leading,spacing:2) {
                        Text(item.displayName)
                        if let title=item.title,title != item.displayName,title != "Item-0" { Text(title).font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Toggle("常驻菜单栏",isOn:Binding(get:{shelf.isPinned(item)},set:{ value in
                        if value != shelf.isPinned(item) { Task { await shelf.toggle(item) } }
                    })).toggleStyle(.switch).disabled(shelf.isBusy || !item.isMovable || !item.canBeHidden)
                }.padding(.vertical,4)
            }.scrollContentBackground(.hidden)
            if let message=shelf.message { Text(message).font(.caption).foregroundStyle(.orange) }
            Text("无法控制的系统项目保持常驻。可控项目可固定/收回，右键仍打开原应用菜单。").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}
