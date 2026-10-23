# 功能与界面清单

本清单来自对 EasiNote（希沃白板）Mac 版 5.2.2.4 安装包的静态分析，用于规划 XiwoBoard 的功能范围。
XiwoBoard 是独立的原生重写：没有复用对方的任何代码、图片、字体或其他资源，界面图标使用 SF Symbols，
应用图标、形状几何、渲染与文件读写全部为本项目原创实现。

## 分析方法

| 步骤 | 工具 | 结论 |
| --- | --- | --- |
| 解包 `.dmg` | `7z` | 应用为通用二进制（x86_64 + arm64）Electron 壳，界面是 `Resources/public/statics` 下的 Vite 前端 |
| 主进程 `app.asar` | [rea](https://github.com/morluto/rea) `analyze-javascript-application` | 11 个 BrowserWindow、145 个 IPC 通道、1 个 preload |
| 前端包 | 字符串与结构检索 | 工具栏/菜单文案、元素类型、`.enbx` 解析器字段 |

### 主进程窗口（rea 结果）

主窗口、课件窗口、编辑（board）、授课（displaying）、加载、窗口模式、打印、截图、副屏、投屏（share）、关于。

### 主要 IPC 能力（节选）

`startDisplay` / `endDisplay`（进入/退出授课）、`slide.goto`、`openRecordBoard` / `startRecordBoardFirst`（板书记录）、
`openScreenshotWindow`（截图）、`openScreenShareWindow`（投屏）、`openPrintWindow` / `getPrinterAsync`（打印）、
`moveSecondaryWindow`（副屏）、`startWritingAccelerator`（书写加速）、`switchPaintBeautification`（笔迹美化）、
`getFontList`、`showOpenDialog` / `openSaveDialogSync`、`setDrawBoardIgnoreMouseEvents`（桌面批注穿透）。

## `.enbx` 课件格式

ZIP 压缩包：

```
Document.xml        课件名称、作者、创建/修改时间、版本
Board.xml           页面顺序 <Slides><Item>页面Id</Item>…，可选 SlideWidth/SlideHeight
Reference.xml       <Relationships><Relationship><Id/><Target>Resources\<md5></Target><Hash/></Relationship>
Slides/Slide_N.xml  每页一个文件
Resources/<md5>     图片、音视频等资源
```

字段一律写成子元素（不用属性）；多态值用类型名包一层，如
`<Background><ColorBrush>#FFFFFFFF</ColorBrush></Background>`，颜色为 `#AARRGGBB`，资源引用为 `id://<Relationship Id>`。

页面：`Id、Width(1280)、Height(720)、Background、Elements、SlideNote、AnimationOrders、TransitionKey、Duration`。
元素公共字段：`Id、X、Y、Width、Height、Rotation、IsLocked、CanClone、HasMask、Hyperlink、Animations、ElementBehavior`。

已识别 194 种可存储类型，课件中常见的有：`Shape`（`Foreground`/`Background`/`Thickness`/`Geometry`→`PresetGeometry.GeometryType` 或 `Path`）、
`Text`（`RichText > TextLines > TextLine > TextRuns > TextRun{Text, FontSize, FontFamily.Source, Foreground…}`）、
`Picture`（`Source`）、`Video`/`Audio`（`Source、MediaName、Duration、Volume`）、`Group`（嵌套 `Elements`）、
以及表格、思维导图、汉字卡、拼音卡、几何、函数、公式、化学方程式、统计图表、课堂活动等学科元素。

形状库共 39 种：直线、虚线、单/双箭头线、矩形、圆角矩形、圆、扇形、三角形、直角三角形、平行四边形、菱形、梯形、
多边形、五角星、爱心、四角星、大括号、中括号、闪电、火焰、月亮、太阳、云朵、笑脸、爆炸、卷轴、横幅、奖牌、
右箭头、双向箭头、燕尾箭头、弧形箭头、环形箭头、旗帜、标签、圆形气泡、矩形气泡、思考气泡。

## 实现状态

✅ 已实现　🟡 部分实现　⬜ 计划中　➖ 不做（依赖对方云服务或账号）

### 首页与文件

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 新建课件（白板/绿板/黑板/方格/四线三格/田字格模板） | ✅ | |
| 打开、保存、另存为 | ✅ | 原生格式 `.xwb`（ZIP + JSON + 资源） |
| 打开 `.enbx` | 🟡 | 形状、文本、图片、音视频、组合、背景、备注；学科元素和课堂活动跳过并提示 |
| 导出 `.enbx` | 🟡 | 同上子集，笔迹写成路径形状 |
| 导出 PDF、导出每页图片 | ✅ | |
| 最近打开、示例课件 | ✅ | |
| 云课件、登录、班级空间、资源库 | ➖ | 需要希沃账号与服务器 |
| 打印（讲义版式） | ⬜ | 可先用导出 PDF 打印 |

### 编辑

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 页面缩略图栏：新建、复制、删除、拖动排序 | ✅ | |
| 画笔：硬笔、毛笔（压感/速度）、荧光笔；颜色、粗细 | ✅ | 支持数位板压感 |
| 橡皮：点擦、笔画擦、清除本页笔迹 | ✅ | |
| 选择：点选、框选、Shift 多选、移动、8 向缩放、旋转（15° 吸附） | ✅ | |
| 形状：39 种 | ✅ | 线条/填充/线宽/虚线，形状内文字 |
| 文本：就地编辑、字体、字号、粗斜体、下划线、对齐、颜色 | ✅ | |
| 图片、音频、视频插入与播放 | ✅ | 视频在画布上就地播放 |
| 表格：插入、增删行列、单元格编辑 | ✅ | |
| 剪切/复制/粘贴/创建副本、组合/取消组合、层级、对齐 | ✅ | 可粘贴外部图片和文字 |
| 锁定、蒙层、授课克隆、超链接（网址或「页面:N」） | ✅ | |
| 背景色、背景图、书写格、应用到全部页面 | ✅ | |
| 页面切换动画（淡入/推入/揭开） | ✅ | |
| 备注 | ✅ | |
| 撤销/恢复 | ✅ | |
| 学科工具：书写格、坐标轴、数轴 | 🟡 | |
| 学科工具：汉字/拼音卡、英汉字典、古诗词、听写、几何画板、函数、公式、化学方程式、仿真实验、星球 | ⬜ | |
| 思维导图、统计图表、地图 | ⬜ | |
| 课堂活动（选择、判断、分类、填空、分组竞争、配对） | ⬜ | |
| 元素动画（出现/强调/退出、触发器） | ⬜ | |
| 笔迹美化、形状/手写识别 | ⬜ | |

### 授课

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 全屏授课、从当前页/第一页开始 | ✅ | `⌘↩` / `⇧⌘↩` |
| 底部工具栏：选择、笔、橡皮、撤消、恢复、翻页、页码 | ✅ | |
| 普通工具栏 / 简单工具栏 | ✅ | |
| 页面列表 | ✅ | 点页码打开 |
| 激光笔、聚光灯、放大镜 | ✅ | 滚轮调聚光灯大小、放大倍数 |
| 计时器（倒计时/正计时） | ✅ | |
| 板中板（插入空白板） | ✅ | |
| 点击揭开蒙层、拖动克隆、超链接跳转、自动播放音视频 | ✅ | 橡皮擦过蒙层也会揭开 |
| 结束授课时选择是否保留板书 | ✅ | |
| **录屏讲课**：屏幕 + 麦克风（+ 可选电脑声音），MP4 | ✅ | ScreenCaptureKit `SCRecordingOutput` |
| **讲课时隐藏功能页面，只露课件** | ✅ | 「隐藏工具」一键隐藏全部面板（H 键恢复）；录制时「只录课件」把工具栏、页面列表、计时器排除在视频外 |
| 键盘：←→/空格/PageUp/PageDown 翻页，Esc 退出，P/E/L/V 切换工具 | ✅ | |
| 截图、桌面批注、投屏、副屏、展台 | ⬜ | |
| 板书记录（逐笔回放） | ⬜ | |
