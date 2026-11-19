"""Usage: goodnotes_symbols.py <dir of pN.json> <symbols.json>. Cut the strokes of each page (strokes/pN.json) into symbol candidates: consecutive strokes that sit on top of
each other. Writes symbols.json: [{"id", "page", "idx": [stroke indices], "pl": [[[x, y], ...], ...], "box"}]"""
import json, sys

SRC = sys.argv[1]
OUT = sys.argv[2]
MAX_STROKES = 4

out = []
for n in range(1, 134):
    try:
        strokes = json.load(open(f"{SRC}/p{n}.json"))["strokes"]
    except FileNotFoundError:
        continue
    ink = [s for s in strokes if s["c"] == "k"]
    groups = []
    cur = None
    for s in ink:
        x0, y0, x1, y1 = s["bbox"]
        w, h = x1 - x0, y1 - y0
        if max(w, h) > 30:  # lines, arrows, fraction bars of whole terms: not a symbol
            cur = None
            continue
        if cur is not None:
            gx0, gy0, gx1, gy1 = cur["box"]
            m = 1.5
            overlap_x = min(gx1, x1) - max(gx0, x0) > -m
            overlap_y = min(gy1, y1) - max(gy0, y0) > -m
            nx0, ny0, nx1, ny1 = min(gx0, x0), min(gy0, y0), max(gx1, x1), max(gy1, y1)
            if overlap_x and overlap_y and len(cur["idx"]) < MAX_STROKES and nx1 - nx0 < 14 and ny1 - ny0 < 16:
                cur["idx"].append(s["i"])
                cur["pl"].append(s["pl"][0])
                cur["box"] = [nx0, ny0, nx1, ny1]
                continue
        cur = {"page": n, "idx": [s["i"]], "pl": [s["pl"][0]], "box": [x0, y0, x1, y1]}
        groups.append(cur)
    out.extend(groups)
for k, g in enumerate(out):
    g["id"] = k
json.dump(out, open(OUT, "w"), separators=(",", ":"))
print(len(out), "symbol candidates")
