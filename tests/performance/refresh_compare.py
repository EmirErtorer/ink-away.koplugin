"""Table of the refresh audit (emulator/refreshaudit.lua) for the versions named
on the command line: per action, flashes, the screen share refreshed and the
median CPU ms over the rounds.

    python3 refresh_compare.py <results dir> label [label ...]
"""
import glob, os, re, statistics as st, sys
from collections import defaultdict

resdir, labels = sys.argv[1], sys.argv[2:]
data = defaultdict(lambda: defaultdict(list))   # (label, panel) -> action -> rows
order = []
for p in sorted(glob.glob(os.path.join(resdir, "*.txt"))):
    m = re.match(r"(.+)_(grey|colour)_r\d+\.txt$", os.path.basename(p))
    if not m or m.group(1) not in labels:
        continue
    seen = defaultdict(int)
    for line in open(p):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 5 or parts[0].startswith("#"):
            continue
        name = parts[0]
        seen[name] += 1
        if seen[name] > 1:
            name = f"{name} #{seen[name]}"
        if name not in order:
            order.append(name)
        data[(m.group(1), m.group(2))][name].append(
            {"flash": int(parts[2]), "area": float(parts[3]), "cpu": float(parts[4])})

def cell(rows):
    if not rows:
        return "-"
    cpu = st.median(x["cpu"] for x in rows)
    fl = f"{rows[0]['flash']} flash" if rows[0]["flash"] else "no flash"
    return f"{fl}, {rows[0]['area']:.2f} scr, {cpu:.1f} ms"

for panel in ("grey", "colour"):
    print(f"\n## {panel}\n")
    print("| action | " + " | ".join(labels) + " |")
    print("|---" * (len(labels) + 1) + "|")
    for name in order:
        cells = [cell(data[(l, panel)].get(name)) for l in labels]
        if all(c == "-" for c in cells):
            continue
        print(f"| {name} | " + " | ".join(cells) + " |")
