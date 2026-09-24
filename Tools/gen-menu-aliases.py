#!/usr/bin/env python3
"""从 Notes.app 的 MainMenu.loctable 生成菜单项标题别名表。

用途：Notes 的 AX 菜单项没有稳定标识（AXIdentifier 是运行时的 `_NS:959` 之类），
所以定位菜单项要靠「快捷键」+「本地化标题」。快捷键与语言无关，优先用它；
少数没有快捷键的项（删除线、粘贴为 Markdown、拷贝为 Markdown）只能靠标题，
这里就从 Notes 自带的 40 多种语言里把它们的标题全捞出来当别名。

运行：python3 Tools/gen-menu-aliases.py
输出：Sources/SugarNoteCore/Resources/menu-aliases.json
"""

import json
import os
import plistlib
import sys

LOCTABLE = "/System/Applications/Notes.app/Contents/Resources/MainMenu.loctable"
OUT = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Sources/SugarNoteCore/Resources/menu-aliases.json",
)

# 菜单项 id -> 我们的语义名。id 取自 MainMenu.loctable 的键（形如 NM1-sI-BQl.title）。
# 这些 id 是 nib 里的稳定标识，跨系统语言不变。
ITEM_IDS = {
    # 段落样式
    "tsr-4S-Glu": "title",
    "5IP-Ek-bcg": "heading",
    "emP-7O-okD": "subheading",
    "fII-oV-esn": "body",
    "REH-G2-7es": "monospaced",
    # 列表
    "5h3-qH-Ju1": "bulletedList",
    "rHH-0v-VPf": "dashedList",
    "Z9N-gZ-asb": "numberedList",
    "0k5-yT-OP8": "checklist",
    "SYb-re-FAl": "blockQuote",
    # 字体
    "NM1-sI-BQl": "bold",
    "W2n-hZ-JWD": "italic",
    "8NR-c7-aM6": "underline",
    "RYE-hr-XlQ": "strikethrough",   # 无快捷键，必须靠标题
    "pXe-i9-USr": "highlight",
    # 其它
    "Zi8-wQ-nUp": "table",
    "lrv-AU-get": "addLink",
    "7P7-t0-ivO": "insertDivider",
    "6Ta-KT-c2V": "pasteAsMarkdown",  # 无快捷键
    "kl7-Hq-zT0": "copyAsMarkdown",   # 无快捷键
    # 文件
    "Was-JA-tGl": "newNote",
    # 对齐（子菜单名 + 四个选项）
    "6Np-fE-QeT": "alignmentMenu",
    "lD1-Ya-q1h": "alignLeft",
    "dRi-1l-P91": "alignRight",
    "nEa-qR-E4M": "alignCenter",
    "JH3-Y8-f2v": "alignJustify",
}


def main() -> int:
    if not os.path.exists(LOCTABLE):
        print(f"找不到 {LOCTABLE}", file=sys.stderr)
        return 1

    with open(LOCTABLE, "rb") as f:
        raw = plistlib.load(f)

    langs = [k for k in raw if k != "LocProvenance"]
    aliases: dict[str, set[str]] = {v: set() for v in ITEM_IDS.values()}
    # 每个语义名对应哪些语言的哪些标题；只收标题，去重后排序输出，运行时做集合匹配
    for lang in langs:
        table = raw[lang]
        for item_id, name in ITEM_IDS.items():
            value = table.get(f"{item_id}.title")
            if isinstance(value, str) and value.strip():
                aliases[name].add(value.strip())

    out = {
        "_comment": "由 Tools/gen-menu-aliases.py 从 Notes.app 的 MainMenu.loctable 生成，不要手改。",
        "_source": LOCTABLE,
        "_languages": len(langs),
        "aliases": {k: sorted(v) for k, v in sorted(aliases.items())},
    }

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"已写入 {OUT}")
    for name, titles in sorted(out["aliases"].items()):
        sample = titles[:6]
        print(f"  {name:18s} {len(titles):3d} 个标题  例: {sample}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
