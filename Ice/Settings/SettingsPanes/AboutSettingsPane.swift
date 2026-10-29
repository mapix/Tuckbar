import SwiftUI
struct AboutSettingsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("MacMenuY").font(.system(size: 42, weight: .semibold))
            Text("菜单栏，收进一个入口。").font(.title2)
            Text("悬浮入口展开整屏横向收纳栏，离开自动收起。点击图标打开原应用菜单；图钉整理模式或项目管理页可固定/收回项目。")
            Text("无法控制的系统项目保留原样。收纳栏支持检索和滚动，不受刘海或左侧应用菜单遮挡。")
            Divider()
            Text("版本 \(Constants.versionString) · GPL-3.0\n菜单栏引擎源自 Ice / Jordan Baird。MacMenuY 没有远程更新或数据上传。")
                .font(.caption).foregroundStyle(.secondary)
            Button("退出 MacMenuY") { NSApp.terminate(nil) }
            Spacer()
        }.padding(32)
    }
}
