import SwiftUI
struct AboutSettingsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    MenuYDuskDot(size: 14)
                    Text("Tuckbar")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(MenuYDuskPalette.ink)
                }
                Text("菜单栏，归于暮色。")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(MenuYDuskPalette.periwinkle)
                Text("采用 Hallmark Dusk 暮色主题设计：深岩底色、烟熏毛玻璃与 1px 顶光边缘。长春花蓝标示常驻与就绪，暖杏色标示未读与整理锁定。")
                    .font(.system(size: 13))
                    .foregroundStyle(MenuYDuskPalette.ink2)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [MenuYDuskPalette.paper2, MenuYDuskPalette.paper],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )

            Text("鼠标悬浮入口，在系统菜单栏下方展开二级横向收纳栏，离开自动收起。支持直接左键、右键打开原应用菜单；开启图钉整理模式时锁定面板不隐藏，从容固定或收回每个项目。")
                .foregroundStyle(.secondary)
            Text("无法移动的系统固定项目保留原样。收纳栏支持实时检索、智能排序和滚动，不受刘海或左侧应用菜单遮挡。")
                .foregroundStyle(.secondary)
            Divider()
            Text("版本 \(Constants.versionString)，基于 GPL-3.0 开源协议发布\n菜单栏底层源自 Ice / Jordan Baird。Tuckbar 完全在本地运行，无数据上传。")
                .font(.caption).foregroundStyle(.secondary)
            Button("退出 Tuckbar") { NSApp.terminate(nil) }
            Spacer()
        }.padding(28)
    }
}
