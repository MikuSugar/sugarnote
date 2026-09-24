#!/bin/bash
#
# 把 build/sugarnote.app 打成一个能直接装的 DMG。
#
# 刻意**不重新构建**：当前 App 的辅助功能授权是绑定 cdhash 的，重新构建会让它失效。
# 所以这个脚本只做打包——如果源码比二进制新，它会直接拒绝，让你先去 build-app.sh。
#
# 用法：scripts/make-dmg.sh

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/sugarnote.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
DMG="$ROOT/build/sugarnote-$VERSION.dmg"
VOLUME="sugarnote"

[ -d "$APP" ] || { echo "找不到 $APP，先跑 scripts/build-app.sh" >&2; exit 1; }

# 源码比二进制新就拒绝打包：那样打出来的是旧代码。
# 只检查会进 App 包的那两部分——SugarNoteCLI 是独立的调试工具，改它不影响 App。
if [ -n "$(find Sources/SugarNoteApp Sources/SugarNoteCore Resources \
           -newer "$APP/Contents/MacOS/sugarnote" 2>/dev/null)" ]; then
  echo "⚠️ App 相关源码比二进制新，需要先重新构建：" >&2
  find Sources/SugarNoteApp Sources/SugarNoteCore Resources \
    -newer "$APP/Contents/MacOS/sugarnote" 2>/dev/null | sed 's/^/    /' >&2
  echo "  跑 scripts/build-app.sh（注意：重建后辅助功能授权会失效，需要重新授权）" >&2
  exit 1
fi

echo "==> 准备打包目录"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

cat > "$STAGE/安装说明.txt" <<'EOF'
sugarnote —— 给 Apple Notes 加 Markdown 快捷输入
================================================

是什么
------
在备忘录里正常打字，sugarnote 识别到 Markdown 语法就地转成备忘录原生富文本。
它不是新的笔记软件，是挂在备忘录旁边的辅助工具。

支持的语法
----------
  粗体      **文字**
  斜体      *文字* 或 _文字_
  下划线    __文字__
  删除线    ~~文字~~
  行内代码  `文字`
  高亮      ==文字==
  标题      # 空格
  小标题    ## 空格
  副标题    ### 空格
  块引用    > 空格
  核对清单  [ ] 空格 或 [x] 空格
  等宽段落  ``` （三个反引号）
  分隔线    *** 或 ___

  加粗、斜体之类的行内语法，敲完闭合的那一半就会自动转换。
  想撤销就按 ⌘Z。

安装
----
1. 把 sugarnote.app 拖进左边的 Applications
2. 打开它（它是个菜单栏应用，没有 Dock 图标，看屏幕右上角）
3. 第一次会弹窗要辅助功能权限，点「打开系统设置」，
   在「隐私与安全性 > 辅助功能」里把 sugarnote 打开

   ⚠️ 如果系统设置里 sugarnote 的开关已经是打开的，但状态栏菜单
      仍显示「需要辅助功能权限」，说明那条记录和当前程序对不上。
      终端里跑一次下面两行，再重新打开开关：
         tccutil reset Accessibility com.mikusugar.sugarnote
         open /Applications/sugarnote.app

怎么确认在正常工作
------------------
点菜单栏图标，看第一行：
  「正在工作 · 备忘录 4.13 (3195)」= 正常
  「需要辅助功能权限」            = 去授权
  「备忘录未运行」                = 先打开备忘录

出问题看日志：~/Library/Logs/sugarnote.log
菜单里有「诊断（结果写进日志）」，点一下会把完整状态写进去并复制到剪贴板。

它会不会动我的笔记
------------------
sugarnote 只在记事本里应用样式和删掉 Markdown 标记字符，不会删除或移动笔记。
它不记录你的按键、不联网、不把内容发到任何地方——正文的读取全靠辅助功能，
而且只在光标所在段落附近做识别。
EOF

echo "==> 生成 DMG"
rm -f "$DMG"
hdiutil create -volname "$VOLUME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> 完成后校验"
hdiutil verify "$DMG" >/dev/null && echo "    DMG 校验通过"
codesign --verify --deep --strict "$APP" && echo "    App 签名校验通过"
ls -lh "$DMG" | awk '{print "    大小：" $5}'

cat <<EOF

完成：$DMG

安装：双击打开，把 sugarnote.app 拖进 Applications。
注意：装到新位置后，辅助功能授权可能需要重新打开一次（开关或 tccutil 重置，见包内说明）。
EOF
