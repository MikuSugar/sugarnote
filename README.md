# sugarnote

给 macOS 上的 Apple Notes（备忘录）加上 Markdown 快捷输入：正常打字，程序识别到 Markdown
语法就地转成备忘录原生富文本。不是替代备忘录，是挂在它旁边的辅助工具。

ProNotes 的替代品。ProNotes 已停止维护，在 macOS 27 上因为按版本硬编码的菜单表失配而失效。

MIT 协议开源。

> **它是怎么碰到你的笔记的**：靠 macOS 的辅助功能接口读取备忘录正文的光标位置，
> 识别到 Markdown 语法后触发备忘录自己的格式化菜单（AXPress）。它**不注入、不修改备忘录**，
> 也不记录你的按键、不联网。所有逻辑都在本机，正文内容不会离开这台电脑。
> 唯一的写入是：删掉你敲的 Markdown 标记字符、应用对应的备忘录原生样式。

## 现状

已完成并在本机 macOS 27 + 备忘录 4.13 上验证：

- **端到端转换链路跑通**：11 个语法全部通过，且每一项都带**样式复核**（不只验证文本变没变，
  还验证样式真的打上了）。`swift run sugarnote-cli selftest` → 11/11。
- **真实按键场景验证**：`sugarnote-cli e2e-probe` 用真实按键敲入，后台 watcher 自动转换，
  四项全部正确，且**一次 ⌘Z 就能退回 Markdown 原文**。
- **运行时菜单发现**：25 个动作全部解析成功，不需要按 macOS 版本维护翻译表。
- 菜单栏 App 外壳（状态菜单、设置窗口、权限引导）+ 打包脚本可用。

## 触发器最终形态（按实测调整过）

备忘录自带智能替换（`编辑 > 替换`，默认全开），实测确认了它的覆盖范围，据此收窄了我们的触发器：

| 语法 | 备忘录自己会转吗 | sugarnote 的处理 |
| --- | --- | --- |
| `- ` / `* ` / `1. ` | **会**（转成列表，触发字符被消费掉） | 不处理，留着兜底（用户关掉智能列表时才用得上） |
| `- [ ] ` / `- [x] ` | 前半截 `- ` 被吃掉，正文只剩 `[ ] ` | **识别裸的 `[ ] ` / `[x] `** |
| `---` | **会被智能破折号变成 em dash `—`** | 主推 `***` / `___`（不受影响），也认 `---` 和 `—` |
| `# ` `## ` `### ` `> ` ` ``` ` | 不会 | 我们处理 |
| `**粗体**` 等行内 | 不会 | 我们处理 |

两条触发器匹配规则也是按实测定的：

- **段落语法匹配段落开头，不要求光标紧跟其后。** 用户敲完 `# ` 会接着敲标题文字，
  等我们去看时段落已经是 `# 标题` 了；只消费开头那两个字符，内容原样保留。
- **行内语法不要求闭合分隔符紧贴光标。** 用户可能敲完 `**粗体**` 又往下打了几个字。

## 已知行为与限制

**撤销：一次 ⌘Z 退回 Markdown 原文。** 要让这个成立，文本改写必须是**一次原子替换**
（`**粗体**` 是「开分隔符+内容+闭分隔符 → 内容」），不能拆成「先删尾、再删首」——
拆开的话撤销会退到中间状态（正文变成 `**粗体`）。实测拆开时 `**粗体**` 要按两次 ⌘Z、
`` `代码` `` 一次，行为不一致；改成一次替换后四项全部一次到位。

**必须做静默去抖（150ms）。** 不能一有变化就动手：用户敲 `# ` 之后会紧接着敲标题文字，
如果在这中间改文本并回写光标，下一个字符会落到错误位置——实测敲 `# 标题` 会变成 `题标`。
去抖同时把「多余的回写光标」也去掉了（只在光标位置确实不对时才写）。

**「粘贴为 Markdown」可行但暂不采用。** 实测它能正确处理行内和块级语法
（`**粗体**` → 加粗、`# 标题` → 标题样式、多行列表的破折号被正确消费），
语义完全交给 Apple 的解析器。但每次转换都要占用剪贴板（保存-改写-恢复），
崩溃时可能丢失用户剪贴板内容，风险大于收益，暂时不用它做实时转换。
它更适合以后做「整块转换」这类显式命令。

## 架构

```
Sources/
  SugarNoteCore/          纯逻辑库，可单测
    AXSupport.swift       AX API 的 CF 桥接（把 unsafeBitCast 噪音收在一处）
    NotesApp.swift        备忘录进程句柄、定位正文元素、菜单栏快照
    NoteTextElement.swift 正文的文本读写原语（UTF-16 码元坐标）
    MenuSnapshot.swift    菜单快照模型 + 遍历（含 AXMenu 容器的坑）
    MenuIndex.swift       动作 → 真实菜单项的解析
    NotesAction.swift     动作目录 + 快捷键 + 标题别名
    MarkdownRecognizer.swift  文本 + 光标 → 转换计划（纯函数）
    CharacterStylePolicy.swift 字符样式「切换语义」的防呆策略
    NotesEngine.swift     读文本 → 识别 → 改写 → 应用样式
    NotesWatcher.swift    AXObserver 订阅正文变化
    MenuInvoker.swift     触发菜单项（AXPress 优先，合成快捷键兜底）
  SugarNoteApp/           菜单栏 App（SwiftUI + MenuBarExtra）
  SugarNoteCLI/           开发调试外壳
Tools/                    一次性探测工具（axprobe / menudump / gen-menu-aliases）
Tests/                    44 个单测，不依赖 AX 和备忘录
```

### 备忘录 AX 接口的几个坑（都踩过）

- **`AXAttributedStringForRange` 只认 `location == 0` 的范围。** `{0,4}` 成功，
  `{1,3}` / `{2,2}` / `{4,1}` 一律返回 nil，而同样参数的 `AXStringForRange` 正常。
  所以读样式统一「从 0 读到目标末尾，再在本地切」。参数类型必须是 `AXValue`(CFRange)，
  传 `NSValue`(NSRange) 一次都读不到。
- **读属性只取范围起点那一段。** 一个范围可能横跨多个属性段（正文 + 末尾换行），
  换行带的是段落属性、没有字符样式；让后面的段覆盖前面，就会把「这段是不是粗体」
  读到换行上去。
- **空笔记的 `AXValue` 是「属性存在但读不出值」**，不是空串。
- **菜单勾选状态是懒验证的**，紧跟应用之后读到的是**上一个**样式
  （`dashedList` 读成 `bulletedList`、`checklist` 读成 `numberedList`）。隔 250ms 读第二次才对。
- **`AXHeadingLevel` / `AXBlockQuoteLevel` 在备忘录里恒为 nil**，不能用。
- **菜单项元素会失活**，表现是 `AXPress` 返回成功但什么都没发生。所以每次样式应用后都复核，
  失败就重扫菜单拿新元素再试一次——这条自愈逻辑在实测里真的救回过几次。
- **菜单项装在 `AXMenu` 容器里**（`AXMenuBarItem → AXMenu → AXMenuItem`），遍历时必须展开。

### 几个关键决定

**为什么用辅助功能而不是别的路子。** 备忘录不开放插件，也没有公开的格式化 API。
macOS 27 的备忘录内部有 `ApplyFormattingLinkAction` 这类 App Intents，但它们是
`LinkAction`（`com.apple.link.systemProtocol.*`），协议不在公开的 AppIntents SDK 里，
实现在私有的 `LinkServices.framework`，是留给系统自己（Apple Intelligence / Writing Tools）
用的，第三方调不到。所以只能走 ProNotes 那条路：辅助功能读正文 + 触发备忘录自己的菜单项。

**为什么不记录按键。** ProNotes 用 `CGEventTap` 抓全局按键。sugarnote 改用
`AXObserver` 订阅正文的 `AXValueChanged` / `AXSelectedTextChanged`，通知来了再看光标前面
是什么。好处有三个：不需要键盘监听权限，隐私面小得多；天然兼容输入法（拼字阶段正文没变，
不会被触发）；少一个「键盘监听」的敏感叙事。

**为什么不做按版本的菜单表。** ProNotes 维护了 4 个按 macOS 版本命名的 JSON，
存着 22 个菜单项在 40 种语言下的标题路径，Notes 一改名就废——它在 macOS 27 上就是因为
`格式 > 文本` 被改名成 `格式 > 对齐` 而挂掉的。sugarnote 改成运行时遍历菜单栏现学：
先用**快捷键**认（与语言无关），再用**标题别名**兜底（别名表由
`Tools/gen-menu-aliases.py` 从备忘录自带的 `MainMenu.loctable` 里把 40 多种语言的标题
全捞出来生成），最后用「父菜单锚点」消歧。

**为什么应用样式用 AXPress 而不是合成按键。** 实测
`CGEventKeyboardSetUnicodeString` + `CGEventPostToPid` 合成的按键**触发不了**备忘录的
菜单快捷键（早期版本的 ⌘N 就是这么失效的）。`AXPress` 稳定，而且对没有快捷键的项
（删除线、粘贴为 Markdown）同样有效。

**字符样式是切换语义，必须先读状态。** 备忘录的字体菜单项（粗体 ⌘B、斜体 ⌘I、下划线、
删除线、高亮）都是**切换**：目标已经是该样式时再触发一次会把它切掉。而刚敲进来的
Markdown 文本会继承光标处的打字属性——用户正在粗体里打字时，`**x**` 里的 x 本来就是粗的，
无脑按一次 ⌘B 反而取消了粗体。ProNotes 二进制里那两句 `Style was not applied properly.`
就是这个坑。所以 `CharacterStylePolicy` 先读状态再决定，按完还复核一次，判断错了补按。

## 安全规则

这个程序会写备忘录，所以下面几条是硬性的：

1. **绝不做破坏性操作。** 不删除笔记、不清空正文、不移动笔记。任何写操作只针对本次自己
   插入的那一段，且删之前校验内容确实是自己的。
2. **测试只在空白笔记里跑。** 进去先断言正文长度为 0；不空就新建一条草稿（用 AXPress 打
   「文件 > 新建备忘录」），新建后仍非空就直接退出，绝不"清理"用户已有内容。
3. **测试跑完把正文长度恢复到测试前的值**，并打印出来。

这条规则的来由见 `Sources/SugarNoteCLI/SelfTest.swift` 顶部的注释：第一版自检假设
`⌘N` 会新建笔记，但合成的按键没生效，结果跑进了用户的真实笔记，清理时又整篇清空。

## 构建与运行

```bash
swift build                        # 构建全部
swift test                         # 51 个单测（不碰备忘录）

./scripts/setup-dev-signing.sh     # 建稳定的开发签名身份（只需跑一次）
./scripts/build-app.sh             # 组装 build/sugarnote.app
open build/sugarnote.app           # 启动

./scripts/make-dmg.sh              # 打成可分发的 DMG（内含安装说明）
```

`make-dmg.sh` 刻意**不重新构建**：当前 App 的辅助功能授权绑定 cdhash，重建会让它失效，
所以它发现 App 相关源码比二进制新时会直接拒绝，让你先决定要不要重建。

⚠️ **不要同时运行两个 sugarnote 实例**——两个引擎都在监听同一篇笔记，会重复转换。
装到 Applications 后先把 `build/` 里那个退出。

首次运行需要在「系统设置 > 隐私与安全性 > 辅助功能」里把 sugarnote 打开。

### 授权失效了怎么办（重要）

**症状**：系统设置里 sugarnote 的开关明明是打开的，App 却一直显示「需要辅助功能权限」。

**原因**：TCC 记录的授权要绑定代码身份。签名不受信任时（ad-hoc、或者自签证书没被标记为受信任），
TCC 记的是 **cdhash**——而 cdhash 每次重新构建都会变。于是「开关是开的，但对不上当前二进制」。

**处理**：
```bash
tccutil reset Accessibility com.mikusugar.sugarnote   # 只清掉我们这条失效记录
open build/sugarnote.app                              # 重启 App
# 到「系统设置 > 隐私与安全性 > 辅助功能」重新打开 sugarnote 的开关
```
App 每 2 秒会重查一次权限，开关打开后**不用重启**就会自动开始工作（状态栏图标从 ✗ 变 ✓）。

**根治**：把这个自签证书标记为受信任，TCC 就会按证书而不是 cdhash 记授权，之后重建不再失效。
需要你的登录 keychain 密码：
```bash
security add-trusted-cert -d -r trustRoot \
  -k ~/Library/Keychains/login.keychain-db <导出的证书>
```
（不做也行，代价就是每次重建后跑一遍上面的 `tccutil reset` + 重新授权。）

### 为什么必须先建签名身份

**ad-hoc 签名的 App 每次重新构建都会换 cdhash，而辅助功能授权是按 cdhash 记的——
等于每改一行代码就要去系统设置里重新授权一次。** 这个坑我实际踩过：给 App 加了个图标、
重建两次，用户刚授的权限就失效了，App 表现得像「完全不能用」。

`scripts/setup-dev-signing.sh` 在独立的 keychain 里自签一张代码签名证书（不动你登录
keychain 里的任何东西），之后 `build-app.sh` 自动用它。这样签出来的 designated requirement
锚定的是**证书哈希**而不是 cdhash，重新构建后授权依然有效：

```
designated => identifier "com.mikusugar.sugarnote" and certificate leaf = H"d0b16474…"
```

要完全清理：`security delete-keychain ~/Library/Keychains/sugarnote-dev.keychain`

要正式分发给别人，还是得 Developer ID + 公证：
`SIGN_IDENTITY="Developer ID Application: 你的名字 (TEAMID)" ./scripts/build-app.sh`

### 出问题看哪里

App 的状态栏菜单第一行就是当前状态（「正在工作」/「需要辅助功能权限」/「备忘录未运行」）。

日志在 `~/Library/Logs/sugarnote.log`。**不要用 `log show` 查**——实测这个 App 的 NSLog
输出进不了统一日志，一直是空的，所以额外写了文件日志。

### 应用图标

`Resources/AppIcon-source.png` 是设计稿，`Tools/make-icon.swift` 生成
`Resources/AppIcon.icns`（构建时自动跑）。中间那步不能省：设计稿的内容通常占满画布
（这张是 85.6%），而 macOS Big Sur 起的图标网格要求内容占 824/1024 ≈ 80.5%，
直接打包出来会比 Dock 里其它图标大一圈。脚本还会给 ≤32px 的尺寸画一个**简化版**
（金色圆角方块 + 放大的 `#`），因为完整设计稿在 16px 下会糊成一团、`#` 认不出来。
```

## 调试工具

`swift run sugarnote-cli <子命令>`。为什么单独做个 CLI：TCC 的辅助功能权限归因到最外层的
「负责进程」，从终端跑 CLI 直接继承终端的权限，改完代码 `swift run` 就能试，
不用反复重新授权。

| 子命令 | 作用 |
| --- | --- |
| `read` | 读当前笔记状态（id、光标、段落、输入法组字状态、可写性） |
| `menus` | 打印 25 个动作各自解析到哪个菜单项、用什么方式触发 |
| `watch` | 订阅正文变化，实时打印识别结果（只读） |
| `expand <文本>` | 离线跑识别器，`\|` 标记光标位置 |
| `selftest` | 端到端自检（只在空白笔记里跑） |
| `selftest --undo` | 额外验证撤销行为（会扫描式连按 ⌘Z，会动撤销栈） |
| `e2e-probe` | **真实按键**端到端（需另开终端跑 `watch`）+ 撤销行为 |
| `type-probe` | 用真实按键打字，测备忘录自带的输入期行为（智能列表/破折号） |
| `style-probe` | 隔离实验：逐个样式单独应用，对比多个样式信号 |
| `paste-probe` | 实验：用备忘录自己的「粘贴为 Markdown」做转换 |
| `inline-probe` | 聚焦探测：转换后在不同时机/引用下读富文本属性 |
| `clear-scratch` | 清理草稿笔记里的测试残留（正文只含指定字符时才清，`--allow "*"` 无条件清） |
| `dump-menus` | 导出完整菜单树 JSON |

## 依赖

无第三方运行时依赖。只用了系统框架：ApplicationServices（AX）、AppKit、SwiftUI、CoreGraphics。
