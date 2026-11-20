#!/usr/bin/env python3
"""Labels symbol candidates cut from a reader's pages, for `train_symbols.py --mine`.

  goodnotes_labels.py <symbols.json> <predictions.tsv> <out.json> [--per-class 250] [--lambda-cap 400]

`symbols.json` is made by goodnotes_symbols.py; `predictions.tsv` is what the pretrained network says of
each candidate (`NOTECRAFT_SYMBOLS_IN=<symbols.json> NOTECRAFT_SYMBOLS_OUT=<predictions.tsv> swift test -c
release -Xswiftc -enable-testing --filter theNetworkReadsEachCutSymbol`). Nobody labels by hand here; what
is labelled is what is certain:

  * a "1" written as a rise from the lower left to the top and a drop ("Λ"): one stroke whose shape says
    so (the network refuses most of them, which is why they are taught);
  * a "5" written as a roof that comes last over a stem with a belly (two strokes, the lowest point of the
    body right of the middle), which the network also refuses. Found by looking at k-means clusters of the
    refused candidates that have a flat top; this rule reproduces the clusters that were taken for fives;
  * every other candidate the network calls a digit with at least 0.97, up to `--per-class` per digit, so
    that nothing but the two new shapes marks a reader's strokes.

Writes `[{"label", "page", "strokes": [[[x, y], ...], ...]}]`, y pointing down, in points.
"""
import argparse, json, random
import numpy as np


def path_length(q):
    return float(np.sum(np.hypot(*np.diff(q, axis=0).T)))


def is_lambda(strokes):
    if len(strokes) != 1:
        return False
    p = np.asarray(strokes[0])
    if len(p) < 4:
        return False
    h = p[:, 1].max() - p[:, 1].min()
    w = p[:, 0].max() - p[:, 0].min()
    if h <= 0 or not 0.3 <= w / h <= 1.0:
        return False
    a = int(p[:, 1].argmin())
    start, apex, end = p[0], p[a], p[-1]
    if not len(p) // 5 < a < len(p) - 2:
        return False
    if start[1] - apex[1] < 0.5 * h or end[1] - apex[1] < 0.6 * h:
        return False
    if start[0] > apex[0] or abs(end[0] - apex[0]) > 0.45 * w:
        return False
    return (path_length(p[: a + 1]) <= 1.3 * float(np.hypot(*(start - apex)))
            and path_length(p[a:]) <= 1.3 * float(np.hypot(*(apex - end))))


def is_roofed_five(strokes):
    if len(strokes) != 2:
        return False
    p = np.concatenate([np.asarray(s) for s in strokes])
    x0, y0 = p.min(axis=0)
    x1, y1 = p.max(axis=0)
    w, h = x1 - x0, y1 - y0
    if h <= 0 or w / h < 0.75 or w / h > 1.3:
        return False
    top = p[p[:, 1] <= y0 + 0.14 * h]
    if top[:, 0].max() - top[:, 0].min() < 0.55 * w:
        return False
    bottom = p[p[:, 1] >= y1 - 0.1 * h]
    return (bottom[:, 0].mean() - x0) / w >= 0.5


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("symbols")
    ap.add_argument("predictions")
    ap.add_argument("out")
    ap.add_argument("--per-class", type=int, default=250)
    ap.add_argument("--lambda-cap", type=int, default=400)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    symbols = {g["id"]: g for g in json.load(open(args.symbols))}
    rows = [line.rstrip("\n").split("\t") for line in open(args.predictions)]
    names = rows[0][1:]
    reject = len(names) - 1
    chosen = {label: [] for label in "0123456789"}
    lam, five = [], []
    for r in rows[1:]:
        g = symbols[int(r[0])]
        p = np.array([float(x) for x in r[1:]])
        item = {"page": g["page"], "strokes": g["pl"]}
        if is_lambda(g["pl"]):
            lam.append({**item, "label": "1"})
        elif p.argmax() == reject and p[names.index("5")] >= 0.03 and is_roofed_five(g["pl"]):
            five.append({**item, "label": "5"})
        elif p.argmax() < reject and names[p.argmax()] in chosen and p.max() >= 0.97:
            chosen[names[p.argmax()]].append({**item, "label": names[p.argmax()]})
    rng = random.Random(args.seed)
    out = []
    for label, items in chosen.items():
        rng.shuffle(items)
        out += items[: args.per_class]
    rng.shuffle(lam)
    out += lam[: args.lambda_cap] + five
    json.dump(out, open(args.out, "w"), separators=(",", ":"))
    print(f"{len(lam)} Λ-shaped ones (took {min(len(lam), args.lambda_cap)}), {len(five)} roofed fives,",
          {k: len(v) for k, v in chosen.items()}, "-> ", len(out), "strokes")


if __name__ == "__main__":
    main()
