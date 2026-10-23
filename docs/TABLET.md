# 数位板（XPPen）适配说明

## XPPen 驱动是怎么工作的

分析对象：`XPPenTablet.app` 4.0.21（`com.ugee.PenTablet`，Qt 5.12，x86_64 + arm64 通用二进制）。
只做了静态分析（字符串、导入符号、反汇编），没有复制或改写其中的代码。

- **这个包只是设置面板**，不是出笔事件的驱动。它在代码里引用了真正的驱动
  `/Library/Application Support/PenDriver/XPPenDriver.app`（另有触控用的 `XTouchDriver.app`），
  那个程序不在这个压缩包里。
- 面板用开源的 hidapi（`hid_open_path`、`hid_send_feature_report` 等）直接和数位板的厂商 HID 接口通信：
  读写固件配置、快捷键、LED、屏幕校准。设置改动通过 XML 配置和 `CFNotificationCenter` 分布式通知
  （`PenTabletDriverUX`）交给后台驱动。
- 面板自己只用 `CGEventPost` 发键盘和媒体键（快捷键、侧键映射到按键时），不发笔事件。
- `hid_init` 里打开了 `IOHIDSystem` 服务，这是 macOS 传统的注入鼠标/数位板事件的通道。
- 配置（`config.xml`）里每支笔有：压感曲线 `P0 / P1X / P1Y / P2`（默认线性）、`DisablePressure`、
  `DisableSlope`（倾斜）、`TablePC`、相对/绝对坐标、三个笔键的动作，还支持按应用路径单独配置（`<Apps><app path>`）。
- 没有 DriverKit / kext，也没有给第三方应用的 SDK 或私有通道。应用能拿到的就是系统事件：
  带 `tabletPoint` 子类型的鼠标事件（压感、倾斜）和 `tabletProximity` 事件（笔尖/笔尾）。

结论：XiwoBoard 和 XPPen 之间唯一的接口是 AppKit 的数位板事件，优化应当做在 XiwoBoard 这一侧。

## 为什么会觉得写字不够顺

1. **事件合并**：AppKit 默认把连续的拖动事件合并成一个，数位板一秒上报 200 次以上，应用只拿到一部分点，曲线变成折线。
   （由「书写流畅度」那条改动处理：落笔期间关闭 `NSEvent.isMouseCoalescingEnabled`。）
2. **抬笔前的零压力**：笔离开板面前的最后一两个采样压感接近 0，毛笔会拖出一个细尖尾巴；偶发的掉点也会让线条突然变细。
3. **压感抖动**：相邻采样压感差几个百分点，不合并之后每个点都用上，毛笔边缘会发毛。
4. **整页重绘**：每次移动都重画整个画面（同样由流畅度改动处理）。

## XiwoBoard 里做了什么

- `PenPressureFilter`（XiwoCore）：压感低于 0.02 视为抬笔，沿用上一个值；其余做轻度指数平滑；结果限制在 0.05…1。
- `TabletInput`：全局监听 `tabletProximity`，知道当前靠近板面的是笔尖还是橡皮。
  - 选着画笔时，把笔翻过来用笔尾（或把笔侧键在 XPPen 设置里设成「橡皮擦」）就直接擦除，工具栏选择不变。
  - XPPen 默认把一个笔侧键映射成右键。选着画笔时，按住这个侧键划过就是擦除；用鼠标右键仍然弹出菜单。

## 推荐的 XPPen 设置

- 在 XPPen 设置里为 XiwoBoard 单独添加一个应用配置，压感曲线保持默认线性，压感平滑交给 XiwoBoard。
- 上课用屏幕映射到投影/一体机所在的显示器，避免笔和光标错位。
- 如果想用笔侧键擦除，保持其中一个键为「右键」，或设成「橡皮擦」。

## 要不要自己写驱动

现在不需要。理由：

- 笔事件本身已经带完整的压感和倾斜，延迟和不顺主要来自应用侧，修好后差别最大。
- 自己的用户态 HID 驱动要独占设备（和官方驱动冲突，需要先卸载）、需要「输入监控」和「辅助功能」权限，
  还要逐个型号适配报告格式，换来的只是少一层转发。DriverKit 驱动还需要 Apple 签发的权限。
- 已有开源的跨平台方案 OpenTabletDriver 支持 macOS 和多数 XPPen 型号，真要替换官方驱动时优先试它。

如果以后发现某个型号上报率被官方驱动限制，可以在 XiwoBoard 里加一个可选的「直读数位板」模式
（IOHIDManager 只读，不独占设备），那时再按具体型号的报告格式做。
