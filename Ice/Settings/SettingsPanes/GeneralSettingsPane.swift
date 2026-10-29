import LaunchAtLogin
import SwiftUI
struct GeneralSettingsPane: View {
    @EnvironmentObject var appState: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("菜单栏，收进一个入口。").font(.title2.weight(.semibold))
            Text("点击右上角的托盘图标，打开纵向列表。项目再多也能向下滚动，不会被刘海或应用菜单挡住。")
            Button("打开收纳面板") {
                appState.menuBarManager.section(withName: .visible)?.controlItem.openDrawer()
            }.buttonStyle(.borderedProminent)
            Divider()
            LaunchAtLogin.Toggle("登录时启动 MacMenuY")
            HStack {
                Image(systemName: "cursorarrow.click")
                Text("点击一行打开原应用；右键打开它的原右键菜单。")
            }
            HStack {
                Image(systemName: "pin")
                Text("图钉：固定回菜单栏 / 收回列表，退出重开后保留选择。")
            }
            HStack {
                Image(systemName: "escape")
                Text("Esc 或点击面板外关闭；底部可暂时恢复整个菜单栏。")
            }
            Divider()
            Text("系统权限").font(.headline)
            HStack {
                Button("辅助功能") { appState.permissionsManager.accessibilityPermission.performRequest() }
                Button("屏幕录制") { appState.permissionsManager.screenRecordingPermission.performRequest() }
            }
            Text("辅助功能用于移动和点击图标。屏幕录制仅用于本机显示菜单栏图标。所有处理在本机完成。")
                .font(.caption).foregroundStyle(.secondary)
            Text("macOS 强制保留时钟、控制中心和隐私指示器。退出 MacMenuY 会自动释放折叠区域。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }.padding(28)
    }
}
