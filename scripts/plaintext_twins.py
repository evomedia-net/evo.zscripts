# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

"""Render this repo's markdown to plain-text twins with the markup removed.

The .txt files exist for terminals, pagers and anywhere markdown doesn't
render. They are generated - never edit one by hand:

    python scripts/plaintext_twins.py          # rewrite every .txt twin
    python scripts/plaintext_twins.py --check  # exit 1 if any is out of sync

tests/PlainTextTwins.Tests.ps1 runs --check, so a markdown edit that forgets
to regenerate fails the suite instead of shipping a twin that disagrees with
the file it mirrors.

Was readme_txt.py, which did README only. CHANGELOG.txt was kept by hand and
drifted the moment CHANGELOG.md was reorganised - and its docstring claimed a
--check the suite never actually ran. Both are fixed here: one renderer, every
pair, and a test that invokes it.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Every markdown file that owes the repo a plain-text twin.
PAIRS = (
    ("README.md", "README.txt"),
    ("CHANGELOG.md", "CHANGELOG.txt"),
)


def _inline(text: str) -> str:
    text = re.sub(r"!\[([^\]]*)\]\([^)]*\)", r"\1", text)  # images -> alt text
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (\2)", text)  # links -> text (url)
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)  # bold
    text = re.sub(r"(?<!\*)\*([^*\n]+)\*(?!\*)", r"\1", text)  # italic
    text = re.sub(r"`([^`]+)`", r"\1", text)  # inline code
    return text


def render(md: str) -> str:
    out: list[str] = []
    in_fence = False
    for line in md.splitlines():
        if line.lstrip().startswith("```"):
            # Drop the fence markers; the code itself stays, indented so it
            # still reads as a block without the backticks.
            in_fence = not in_fence
            continue
        if in_fence:
            out.append(("    " + line) if line else "")
            continue
        # An HTML comment is invisible in rendered markdown, but its markers
        # are not invisible in a text file - they read as stray punctuation.
        # Keep what the comment says, drop the <!-- --> around it.
        if line.strip() in ("<!--", "-->"):
            continue
        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        if heading:
            text = _inline(heading.group(2))
            out.append(text)
            out.append(("=" if len(heading.group(1)) == 1 else "-") * len(text))
            continue
        out.append(_inline(line))
    text = "\n".join(out)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip() + "\n"


def main() -> int:
    check = "--check" in sys.argv
    stale: list[str] = []
    for md_name, txt_name in PAIRS:
        source = ROOT / md_name
        if not source.exists():
            print(f"{md_name} is missing - nothing to render")
            return 1
        rendered = render(source.read_text(encoding="utf-8"))
        target = ROOT / txt_name
        if check:
            current = target.read_text(encoding="utf-8") if target.exists() else ""
            if current != rendered:
                stale.append(txt_name)
            continue
        target.write_text(rendered, encoding="utf-8", newline="\n")
        print(f"Wrote {target} ({len(rendered.splitlines())} lines)")

    if check:
        if stale:
            print(f"out of sync: {', '.join(stale)}"
                  f" - run: python scripts/plaintext_twins.py")
            return 1
        print(f"in sync: {', '.join(t for _, t in PAIRS)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
