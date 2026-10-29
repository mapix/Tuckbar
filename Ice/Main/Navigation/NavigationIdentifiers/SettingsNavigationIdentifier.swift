//
//  SettingsNavigationIdentifier.swift
//  Ice
//

/// An identifier used for navigation in the settings interface.
enum SettingsNavigationIdentifier: String, NavigationIdentifier {
    case general = "通用"
    case menuBarLayout = "项目管理"
    case menuBarAppearance = "外观"
    case hotkeys = "排序规则"
    case advanced = "提醒"
    case about = "关于"
}
