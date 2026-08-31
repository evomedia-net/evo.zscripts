# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

"""Render README.md to README.txt with the markdown markup removed.

README.txt exists for terminals, pagers and anywhere markdown doesn't
render. It is generated - never edit it by hand:

    python scripts/readme_txt.py          # rewrite README.txt
    python scripts/readme_txt.py --check  # exit 1 if it is out of sync

The test suite runs --check, so a README.md edit that forgets to
regenerate fails CI rather than shipping a stale mirror.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


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
    source = (ROOT / "README.md").read_text(encoding="utf-8")
    rendered = render(source)
    target = ROOT / "README.txt"
    if "--check" in sys.argv:
        current = target.read_text(encoding="utf-8") if target.exists() else ""
        if current != rendered:
            print("README.txt is out of sync - run: python scripts/readme_txt.py")
            return 1
        print("README.txt is in sync")
        return 0
    target.write_text(rendered, encoding="utf-8", newline="\n")
    print(f"Wrote {target} ({len(rendered.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
