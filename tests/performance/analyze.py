"""Compare the old and new samples written by bench.lua (headless) or
emulator/perfemu.lua (real widgets).

Each process wrote metric -> samples. Per (group, metric) take one statistic per
process (the median of its samples), pair old and new by round (they ran back
to back), and bootstrap the median of the paired ratios. A change counts only
when the 95% interval clears the noise floor (5%) and the absolute difference is
above 5 us. Metrics only one version has are listed with their values.

    python3 analyze.py A <results dir> [metric regex]   headless, full table
    python3 analyze.py B <results dir> [metric regex]   emulator, full table
    python3 analyze.py S <results dir> <metric regex>   headless, one line per
                                                        screen setup per metric
"""
import glob, math, os, random, re, statistics as st, sys
from collections import defaultdict

random.seed(1)


def load(path, fmt):
    d = defaultdict(list)
    for line in open(path):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        m, vals = line.split("\t", 1)
        # the page-thumbnail view is the page grid on main and the overview here
        for a, b in (("io.overview", "io.pages_view"), ("io.pagegrid", "io.pages_view"),
                     ("overview(4p)", "pages_view(4p)"), ("pagegrid(4p)", "pages_view(4p)"),
                     ("sheet.overview.", "sheet.pages_view."), ("sheet.pagegrid.", "sheet.pages_view.")):
            m = m.replace(a, b)
        if fmt == "A":
            d[m] += [float(x) for x in vals.split(",")]
        else:
            d[m].append(float(vals))
    return d


def collect(resdir, rx, fmt):
    data = defaultdict(lambda: defaultdict(dict))   # group -> ver -> round -> metrics
    for p in glob.glob(os.path.join(resdir, "*.txt")):
        m = rx.match(os.path.basename(p))
        if m:
            data[m.group("grp")][m.group("ver")][int(m.group("r"))] = load(p, fmt)
    return data


def boot_ci(ratios, n=4000):
    meds, k = [], len(ratios)
    for _ in range(n):
        meds.append(st.median(ratios[random.randrange(k)] for _ in range(k)))
    meds.sort()
    return meds[int(0.025 * n)], meds[int(0.975 * n)]


def pct(xs, p):
    xs = sorted(xs)
    if not xs:
        return float("nan")
    return xs[min(len(xs) - 1, max(0, int(round(p / 100 * (len(xs) - 1)))))]


def per_proc(data, grp, ver, metric):
    out, pooled = {}, []
    for r, ms in data[grp][ver].items():
        if metric in ms and ms[metric]:
            out[r] = st.median(ms[metric])
            pooled += ms[metric]
    return out, pooled


def compare(data, grp, metric):
    o, po = per_proc(data, grp, "old", metric)
    n, pn = per_proc(data, grp, "new", metric)
    rounds = sorted(set(o) & set(n))
    ratios = [n[r] / o[r] for r in rounds if o[r] > 0]
    res = {"old": st.median(o.values()) if o else None, "new": st.median(n.values()) if n else None,
           "p90_old": pct(po, 90), "p90_new": pct(pn, 90), "n_old": len(po), "n_new": len(pn)}
    if len(ratios) >= 3:
        res["ratio"] = st.median(ratios)
        res["lo"], res["hi"] = boot_ci(ratios)
    return res


def verdict(c, floor=0.05, abs_floor=5.0):
    if "ratio" not in c:
        return ""
    diff = abs(c["new"] - c["old"])
    if c["lo"] > 1 + floor and diff > abs_floor:
        return "SLOWER" if not UNITLESS else "HIGHER"
    if c["hi"] < 1 - floor and diff > abs_floor:
        return "faster" if not UNITLESS else "lower"
    return "same"


UNITLESS = False


def unit(metric):
    if metric.startswith("mem."):
        return "KB"
    if metric.startswith("refresh."):
        return "x"
    if metric.endswith("_kb"):
        return "kb"
    if re.search(r"(pages|count|loaded|thumbs|tabs|files|steps|traces|flushes|is_branch|ops_per_page|requests)$", metric):
        return "n"
    return "us"


def fmt(x, u):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "-"
    if u == "us":
        if x >= 10000:
            return f"{x / 1000:.1f} ms"
        if x >= 1000:
            return f"{x / 1000:.2f} ms"
        return f"{x:.0f} us" if x >= 10 else f"{x:.1f} us"
    if u == "KB":
        return f"{x / 1024:.2f} MB"
    if u == "kb":
        return f"{x:.0f} KB" if x < 2048 else f"{x / 1024:.1f} MB"
    if u == "x":
        return f"{x:.2f}"
    return f"{x:.0f}"


def metrics(data, grp):
    seen = []
    for ver in ("old", "new"):
        for r in sorted(data[grp][ver]):
            for m in data[grp][ver][r]:
                if m not in seen:
                    seen.append(m)
    return seen


def report(data, title, pick=None):
    global UNITLESS
    print(f"\n## {title}")
    for grp in sorted(data):
        print(f"\n[{grp}]  rounds old={len(data[grp]['old'])} new={len(data[grp]['new'])}")
        print(f"{'metric':44s} {'old':>10s} {'new':>10s} {'change':>8s} {'95% CI':>13s}  {'p90 old':>10s} {'p90 new':>10s}  verdict")
        for m in metrics(data, grp):
            if pick and not pick(m):
                continue
            c = compare(data, grp, m)
            u = unit(m)
            UNITLESS = u != "us"
            if "ratio" in c:
                ch = f"{(c['ratio'] - 1) * 100:+.1f}%"
                ci = f"[{(c['lo'] - 1) * 100:+.0f},{(c['hi'] - 1) * 100:+.0f}]%"
            else:
                ch, ci = "", ("old only" if c["new"] is None else ("new only" if c["old"] is None else ""))
            print(f"{m:44s} {fmt(c['old'], u):>10s} {fmt(c['new'], u):>10s} {ch:>8s} {ci:>13s}  "
                  f"{fmt(c['p90_old'], u):>10s} {fmt(c['p90_new'], u):>10s}  {verdict(c)}")


def summary(data, metrics_list):
    """Per metric: main and branch medians in each group, the change, and how
    many groups call it slower / faster / same."""
    global UNITLESS
    for m in metrics_list:
        cells, verds = [], []
        for grp in sorted(data):
            c = compare(data, grp, m)
            if c["old"] is None and c["new"] is None:
                continue
            u = unit(m)
            UNITLESS = u != "us"
            ch = f"{(c['ratio'] - 1) * 100:+.0f}%" if "ratio" in c else ""
            cells.append(f"{grp.split('_', 1)[1]}: {fmt(c['old'], u)} -> {fmt(c['new'], u)} {ch}")
            verds.append(verdict(c))
        if cells:
            tally = {v: verds.count(v) for v in set(verds) if v}
            print(f"{m:34s} {tally}\n    " + "\n    ".join(cells))


if __name__ == "__main__":
    which, resdir = sys.argv[1], sys.argv[2]
    flt = sys.argv[3] if len(sys.argv) > 3 else None
    if which in ("A", "S"):
        rx = re.compile(r"(?P<ver>old|new)_(?P<grp>(ui|io)_.+)_r(?P<r>\d+)\.txt$")
        data = collect(resdir, rx, "A")
    else:
        rx = re.compile(r"(?P<ver>old|new)_(?P<grp>.+)_r(?P<r>\d+)\.txt$")
        data = collect(resdir, rx, "B")
    if which == "S":
        names = []
        for grp in data:
            for ver in data[grp]:
                for ms in data[grp][ver].values():
                    names += [m for m in ms if re.search(flt or ".", m) and m not in names]
        for part in ("ui_", "io_"):
            summary({g: d for g, d in data.items() if g.startswith(part)},
                    [m for m in names if any(m in ms for g, d in data.items() if g.startswith(part)
                                             for v in d.values() for ms in v.values())])
    else:
        report(data, os.path.basename(resdir), (lambda m: re.search(flt, m)) if flt else None)
