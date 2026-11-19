"""Goodnotes PDF export (one SVG per page, made with pdftocairo) -> ordered pen strokes with centre lines.

Every ink stroke of the export is one filled <path> made of one small capsule per pair of pen samples,
in the order it was written. The chained end centres of the capsules are the pen's path: one polyline per
stroke, in page points (y down), colour as k/r/b/y/g. Pages are made with
`pdftocairo -svg -f N -l N notes.pdf pN.svg`. Usage: goodnotes_strokes.py <svg dir> <out dir> [page ...]
The output (`pN.json`) is what `RealPageAuditTests` reads. Notes are somebody's own: keep it out of the repository.
"""
import json, math, os, re, sys
from multiprocessing import Pool
import numpy as np

INK = {
    (11.8, 10.6, 10.6): "k",
    (95.3, 24.7, 24.7): "r",
    (32.5, 66.7, 100.0): "b",
    (96.9, 79.2, 11.4): "y",
    (29.8, 77.6, 30.6): "g",
}
PATH = re.compile(r'<path fill-rule="nonzero" fill="rgb\(([\d.]+)%, ([\d.]+)%, ([\d.]+)%\)" fill-opacity="([\d.]+)" d="([^"]*)"')
TOKEN = re.compile(r"[MLCZ]|-?\d+\.?\d*(?:e-?\d+)?")


def colour(rgb):
    for k, v in INK.items():
        if all(abs(a - b) < 0.6 for a, b in zip(rgb, k)):
            return v
    return None


def subpaths(d):
    """Flattened closed polygons of an SVG path with M L C Z only."""
    tokens = TOKEN.findall(d)
    polys, cur, i, pen = [], [], 0, (0.0, 0.0)
    while i < len(tokens):
        t = tokens[i]
        if t == "M":
            if len(cur) > 2:
                polys.append(cur)
            pen = (float(tokens[i + 1]), float(tokens[i + 2]))
            cur = [pen]
            i += 3
        elif t == "L":
            pen = (float(tokens[i + 1]), float(tokens[i + 2]))
            cur.append(pen)
            i += 3
        elif t == "C":
            x1, y1, x2, y2, x3, y3 = (float(v) for v in tokens[i + 1 : i + 7])
            x0, y0 = pen
            for k in range(1, 7):
                u = k / 6
                a, b, c, e = (1 - u) ** 3, 3 * (1 - u) ** 2 * u, 3 * (1 - u) * u * u, u**3
                cur.append((a * x0 + b * x1 + c * x2 + e * x3, a * y0 + b * y1 + c * y2 + e * y3))
            pen = (x3, y3)
            i += 7
        elif t == "Z":
            if len(cur) > 2:
                polys.append(cur)
            cur = []
            i += 1
        else:
            i += 1
    if len(cur) > 2:
        polys.append(cur)
    return polys


def capsule_ends(poly):
    """End centres (a, b) and radius of one capsule polygon: extremes along its main axis, less the cap radius."""
    a = np.asarray(poly)
    c = a.mean(axis=0)
    q = a - c
    w, v = np.linalg.eigh(q.T @ q)
    axis = v[:, 1]
    proj = q @ axis
    perp = q @ v[:, 0]
    r = max(0.05, (perp.max() - perp.min()) / 2)
    lo, hi = proj.min() + r, proj.max() - r
    if hi < lo:
        lo = hi = (lo + hi) / 2
    return c + axis * lo, c + axis * hi, r


def stroke_of(polys):
    """The pen path of one stroke. Goodnotes draws a stroke as one capsule per pair of samples, in order; the
    capsules' end centres, chained, are the trajectory."""
    allx = [x for p in polys for x, _ in p]
    ally = [y for p in polys for _, y in p]
    x0, y0, x1, y1 = min(allx), min(ally), max(allx), max(ally)
    area = 0.0
    caps = []
    for p in polys:
        a = np.asarray(p)
        area += abs(float(np.dot(a[:, 0], np.roll(a[:, 1], -1)) - np.dot(a[:, 1], np.roll(a[:, 0], -1)))) / 2
        caps.append(capsule_ends(p))
    pts = []
    for k, (e0, e1, r) in enumerate(caps):
        if k == 0:
            if len(caps) > 1:
                nxt = np.asarray(polys[1]).mean(axis=0)
                if np.hypot(*(e0 - nxt)) < np.hypot(*(e1 - nxt)):
                    e0, e1 = e1, e0
                # e0 is now the end nearer to the next capsule: swap back so the path starts at the far end
                e0, e1 = e1, e0
            pts.append(e0)
            pts.append(e1)
        else:
            prev = pts[-1]
            if np.hypot(*(e0 - prev)) > np.hypot(*(e1 - prev)):
                e0, e1 = e1, e0
            pts.append(e1)
    # drop repeats
    out = [pts[0]]
    for p in pts[1:]:
        if np.hypot(*(p - out[-1])) > 0.02:
            out.append(p)
    line = [[round(float(x), 3), round(float(y), 3)] for x, y in out]
    length = sum(math.dist(a, b) for a, b in zip(line, line[1:]))
    return {"bbox": [round(x0, 2), round(y0, 2), round(x1, 2), round(y1, 2)], "area": round(area, 3), "len": round(length, 3), "pl": [line]}


def page(args):
    svg, out = args
    text = open(svg).read()
    strokes = []
    for m in PATH.finditer(text):
        rgb = tuple(float(m.group(k)) for k in (1, 2, 3))
        c = colour(rgb)
        if c is None or float(m.group(4)) < 0.9:
            continue
        polys = subpaths(m.group(5))
        if not polys:
            continue
        s = stroke_of(polys)
        s["c"] = c
        s["i"] = len(strokes)
        strokes.append(s)
    json.dump({"strokes": strokes}, open(out, "w"), separators=(",", ":"))
    return len(strokes)


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    only = [int(a) for a in sys.argv[3:]]
    os.makedirs(dst, exist_ok=True)
    jobs = []
    for n in range(1, 134):
        if only and n not in only:
            continue
        jobs.append((f"{src}/p{n}.svg", f"{dst}/p{n}.json"))
    with Pool(8) as pool:
        counts = pool.map(page, jobs)
    print(sum(counts), "strokes in", len(jobs), "pages")
