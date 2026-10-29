//
//  PermissionsView.swift
//  Ice
//

import SwiftUI

struct PermissionsView: View {
    @EnvironmentObject var permissionsManager: PermissionsManager
    @Environment(\.openWindow) private var openWindow

    private var continueButtonText: LocalizedStringKey {
        if case .hasRequiredPermissions = permissionsManager.permissionsState {
            "继续（显示应用图标）"
        } else {
            "开始使用"
        }
    }

    private var continueButtonForegroundStyle: some ShapeStyle {
        if case .hasRequiredPermissions = permissionsManager.permissionsState {
            AnyShapeStyle(.yellow)
        } else {
            AnyShapeStyle(.primary)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.vertical)

            explanationView
            permissionsGroupStack

            footerView
                .padding(.vertical)
        }
        .padding(.horizontal)
        .fixedSize()
        .readWindow { window in
            guard let window else {
                return
            }
            window.styleMask.remove([.closable, .miniaturizable])
            if let contentView = window.contentView {
                with(contentView.safeAreaInsets) { insets in
                    insets.bottom = -insets.bottom
                    insets.left = -insets.left
                    insets.right = -insets.right
                    insets.top = -insets.top
                    contentView.additionalSafeAreaInsets = insets
                }
            }
        }
    }

    @ViewBuilder
    private var headerView: some View {
        Label {
            Text("MacMenuY 权限")
                .font(.system(size: 36))
        } icon: {
            if let nsImage = NSImage(named: NSImage.applicationIconName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 75, height: 75)
            }
        }
    }

    @ViewBuilder
    private var explanationView: some View {
        IceSection {
            VStack {
                Text("MacMenuY 需要辅助功能权限来移动和点击菜单栏图标。")
                Text("屏幕录制仅用于本机显示图标；无联网、无上传。")
                    .bold()
                    .foregroundStyle(.red)
            }
            .padding()
        }
        .font(.title3)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var permissionsGroupStack: some View {
        VStack(spacing: 7.5) {
            ForEach(permissionsManager.allPermissions) { permission in
                permissionBox(permission)
            }
        }
    }

    @ViewBuilder
    private var footerView: some View {
        HStack {
            quitButton
            continueButton
        }
        .controlSize(.large)
    }

    @ViewBuilder
    private var quitButton: some View {
        Button {
            NSApp.terminate(nil)
        } label: {
            Text("Quit")
                .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var continueButton: some View {
        Button {
            guard let appState = permissionsManager.appState else {
                return
            }
            appState.performSetup()
            appState.permissionsWindow?.close()

        } label: {
            Text(continueButtonText)
                .frame(maxWidth: .infinity)
                .foregroundStyle(continueButtonForegroundStyle)
        }
        .disabled(permissionsManager.permissionsState == .missingPermissions)
    }

    @ViewBuilder
    private func permissionBox(_ permission: Permission) -> some View {
        IceSection {
            VStack(spacing: 10) {
                Text(permission.title)
                    .font(.title)
                    .underline()

                VStack(spacing: 0) {
                    Text("用途：")
                        .font(.title3)
                        .bold()

                    VStack(alignment: .leading) {
                        ForEach(permission.details, id: \.self) { detail in
                            HStack {
                                Text("•").bold()
                                Text(detail)
                            }
                        }
                    }
                }

                Button {
                    guard let appState = permissionsManager.appState else {
                        return
                    }
                    permission.performRequest()
                    Task {
                        await permission.waitForPermission()
                        appState.activate(withPolicy: .regular)
                        openWindow(id: Constants.permissionsWindowID)
                    }
                } label: {
                    if permission.hasPermission {
                        Text("已授权")
                            .foregroundStyle(.green)
                    } else {
                        Text("授权")
                    }
                }
                .allowsHitTesting(!permission.hasPermission)

                if !permission.isRequired {
                    IceGroupBox {
                        AnnotationView(
                            alignment: .center,
                            font: .callout.bold()
                        ) {
                            Label {
                                Text("未授权屏幕录制时，列表将显示应用图标。")
                            } icon: {
                                Image(systemName: "checkmark.shield")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
        }
    }
}
