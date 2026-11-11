import Foundation

enum StudioSection: String, CaseIterable, Identifiable {
    case resolution, daily, automation, virtual, layouts, shortcuts, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .resolution: return "显示模式"
        case .daily: return "日常控制"
        case .automation: return "联动与恢复"
        case .virtual: return "虚拟屏幕与预览"
        case .layouts: return "布局与预设"
        case .shortcuts: return "快捷键"
        case .settings: return "软件设置"
        }
    }
    var symbol: String {
        switch self {
        case .resolution: return "display"
        case .daily: return "sun.max"
        case .automation: return "arrow.triangle.2.circlepath"
        case .virtual: return "rectangle.on.rectangle"
        case .layouts: return "rectangle.3.group"
        case .shortcuts: return "keyboard"
        case .settings: return "gearshape"
        }
    }
    var subtitle: String {
        switch self {
        case .resolution: return "选择清晰的桌面尺寸与刷新率。"
        case .daily: return "调节系统亮度、添加软件滤镜，收藏常用分辨率。"
        case .automation: return "让外接屏跟随亮度，唤醒或重连后恢复预设。"
        case .virtual: return "创建独立桌面，或在浮动窗口中预览屏幕。"
        case .layouts: return "安排屏幕位置，保存并切换显示配置。"
        case .shortcuts: return "用组合键打开工具、切换收藏和配置。"
        case .settings: return "配置应用行为、快捷键与自动恢复。"
        }
    }
}
