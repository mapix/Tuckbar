import SwiftUI
struct AboutSettingsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Tuckbar").font(.system(size: 42, weight: .semibold))
            Text("菜单栏，优雅收进二级抽屉。").font(.title2)
            Text("鼠标悬浮入口，在系统菜单栏下方展开二级横向收纳栏，离开自动收起。支持直接左键、右键打开原应用菜单；开启图钉整理模式时锁定面板不隐藏，轻松固定或收回每个项目。")
            Text("无法移动的系统固定项目保留原样。收纳栏支持实时检索、智能排序和滚动，不受刘海或左侧应用菜单遮挡。")
            Divider()
            Text("版本 \(Constants.versionString) · GPL-3.0\n菜单栏底层源自 Ice / Jordan Baird。Tuckbar 完全在本地运行，无数据上传。")
                .font(.caption).foregroundStyle(.secondary)
            Button("退出 Tuckbar") { NSApp.terminate(nil) }
            Spacer()
        }.padding(32)
    }
}
