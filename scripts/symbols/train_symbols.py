#!/usr/bin/env python3
"""Trains the pretrained symbol network of the calculator pen and writes it as Swift source.

  python3 scripts/symbols/train_symbols.py --data <dir> [--out Sources/NoteCraftCore/Calculator/SymbolNetWeights.swift]
      [--mine <reader.json> --european 0.05]

The weights in the repository were made with `--mine` (strokes of one reader, from goodnotes_labels.py) and
`--european 0.05`; without them the script makes the network the app shipped before.

`<dir>` holds the two public data sets the network learns digits from (the script downloads them
when they are missing; nothing else is fetched):

  MNIST        handwritten digits as 28x28 images (Y. LeCun et al.; made from NIST Special Databases 1 and 3)
  pendigits    digits written on a tablet, 44 writers, as pen strokes (E. Alpaydin, F. Alimoglu, UCI, CC BY 4.0)

The classes are the 16 symbols of the pen (0-9 + - * ÷ ( )) and one more, "not a symbol" (two symbols
that were cut as one, a scribble, a slanted slash), which is what lets the reader tell a good cut of
the strokes from a bad one. Operators and the "not a symbol" class are drawn here, procedurally, as
strokes; every stroke sample goes through `render` below, which is the same algorithm as
`SymbolRaster` in Sources/NoteCraftCore/Calculator/SymbolRaster.swift (a test compares the two).

Two shapes taught in Switzerland and Germany are not in those sets: a "1" written as a rise from the lower
left to the top and a straight drop ("Λ"), and a "5" with a flat roof written last. `european_one` draws the
first; for both, `--mine` takes strokes cut from a reader's own pages (see goodnotes_labels.py), which are
mixed in with the pendigits strokes (pages whose number divides by `--hold-out-mod` are kept back and only
used to evaluate).

What is evaluated on data the network never saw: the MNIST test set, the 14 writers of pendigits that
are not in training, operators from other random seeds, and pairs of symbols (must be "not a symbol").
Training is deterministic for a seed on the same machine; the weights are stored as float16.
"""
import argparse, base64, gzip, io, math, os, re, sys, urllib.request, zipfile
import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

SYMBOLS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "-", "*", "÷", "(", ")"]
REJECT = len(SYMBOLS)
CLASSES = REJECT + 1
SIZE, BOX = 28, 20
# How thick a stroke is drawn, in pixels of the 28x28 picture; MNIST's strokes are 2 to 3 wide.
WIDTH = 2.2

MNIST_URL = "https://ossci-datasets.s3.amazonaws.com/mnist/"
PENDIGITS_URL = "https://archive.ics.uci.edu/static/public/81/pen+based+recognition+of+handwritten+digits.zip"

_cy, _cx = np.mgrid[0:SIZE, 0:SIZE]
PIXELS = np.stack([_cx.ravel() + 0.5, _cy.ravel() + 0.5], axis=1).astype(np.float64)  # (784, 2) centres


# MARK: rendering (mirror of SymbolRaster.swift)

def _coverage(points_by_stroke, width):
    a_list, b_list = [], []
    for s in points_by_stroke:
        if len(s) == 1:
            a_list.append(s[:1]); b_list.append(s[:1])
        else:
            a_list.append(s[:-1]); b_list.append(s[1:])
    if not a_list:
        return np.zeros(SIZE * SIZE)
    a = np.concatenate(a_list).astype(np.float32)
    b = np.concatenate(b_list).astype(np.float32)
    px = PIXELS.astype(np.float32)
    ab = b - a
    len2 = (ab * ab).sum(axis=1)
    # The distance of every pixel centre to every segment, then to the nearest one.
    ap = px[None, :, :] - a[:, None, :]
    dot = (ap * ab[:, None, :]).sum(axis=2)
    t = np.clip(dot / np.maximum(len2[:, None], 1e-12), 0.0, 1.0)
    closest = a[:, None, :] + t[:, :, None] * ab[:, None, :]
    diff = px[None, :, :] - closest
    d = np.sqrt((diff * diff).sum(axis=2)).min(axis=0)
    return np.clip(width / 2 + 0.5 - d, 0.0, 1.0)


def render(strokes, width=WIDTH):
    """Strokes (lists of (x, y)) as the 28x28 picture the network reads, or None for a dot."""
    pts = [p for s in strokes for p in s]
    if not pts:
        return None
    arr = np.asarray(pts, dtype=np.float64)
    lo, hi = arr.min(axis=0), arr.max(axis=0)
    extent = float((hi - lo).max())
    if extent < 1e-9:
        return None
    centre = (lo + hi) / 2
    scale = BOX / extent
    placed = [(np.asarray(s, dtype=np.float64) - centre) * scale + 14.0 for s in strokes if len(s) > 0]
    first = _coverage(placed, width)
    total = first.sum()
    if total <= 0:
        return None
    cx = (first * PIXELS[:, 0]).sum() / total
    cy = (first * PIXELS[:, 1]).sum() / total
    dx, dy = 14.0 - cx, 14.0 - cy
    shifted = [s + [dx, dy] for s in placed]
    return _coverage(shifted, width).reshape(SIZE, SIZE).astype(np.float32)


# MARK: data

def fetch(url, path):
    if not os.path.exists(path):
        print("downloading", url)
        urllib.request.urlretrieve(url, path)


def load_mnist(directory):
    def images(name):
        raw = gzip.open(os.path.join(directory, name)).read()
        n = int.from_bytes(raw[4:8], "big")
        return np.frombuffer(raw, np.uint8, offset=16).reshape(n, SIZE, SIZE).astype(np.float32) / 255.0

    def labels(name):
        return np.frombuffer(gzip.open(os.path.join(directory, name)).read(), np.uint8, offset=8).astype(np.int64)

    out = {}
    for split, prefix in (("train", "train"), ("test", "t10k")):
        for kind in ("images-idx3", "labels-idx1"):
            name = f"{prefix}-{kind}-ubyte.gz"
            fetch(MNIST_URL + name, os.path.join(directory, name))
        out[split] = (images(f"{prefix}-images-idx3-ubyte.gz"), labels(f"{prefix}-labels-idx1-ubyte.gz"))
    return out


def load_pendigits(directory):
    """The original pen traces: {split: [(label, [stroke, ...])]}, y pointing down."""
    import subprocess
    archive = os.path.join(directory, "pendigits.zip")
    fetch(PENDIGITS_URL, archive)
    result = {}
    with zipfile.ZipFile(archive) as z:
        for split, name in (("train", "pendigits-orig.tra.Z"), ("test", "pendigits-orig.tes.Z")):
            target = os.path.join(directory, name)
            if not os.path.exists(target):
                z.extract(name, directory)
            # `.Z` is Unix compress; gzip reads it.
            text = subprocess.run(["gzip", "-dc", target], capture_output=True, check=True).stdout.decode("latin-1")
            samples, cur, stroke = [], None, None
            for line in text.splitlines():
                line = line.strip()
                if line.startswith(".SEGMENT"):
                    cur = (int(re.search(r'"(\d)"\s*$', line).group(1)), [])
                    samples.append(cur)
                elif line == ".PEN_DOWN":
                    stroke = []
                    cur[1].append(stroke)
                elif line == ".PEN_UP":
                    stroke = None
                elif line and not line.startswith(".") and stroke is not None:
                    x, y = line.split()
                    stroke.append((float(x), -float(y)))
            result[split] = [(label, [s for s in strokes if s]) for label, strokes in samples if strokes]
    return result


# MARK: stroke-level augmentation and procedural symbols

def resample(stroke, step):
    """Points at an even spacing along a stroke, like the dense samples a Pencil produces."""
    arr = np.asarray(stroke, dtype=np.float64)
    if len(arr) < 2:
        return arr
    seg = np.sqrt(((arr[1:] - arr[:-1]) ** 2).sum(axis=1))
    cum = np.concatenate([[0], np.cumsum(seg)])
    if cum[-1] <= 0:
        return arr[:1]
    n = max(2, int(cum[-1] / step) + 1)
    t = np.linspace(0, cum[-1], n)
    return np.stack([np.interp(t, cum, arr[:, 0]), np.interp(t, cum, arr[:, 1])], axis=1)


def smooth(arr, passes=2):
    """Pen traces sampled every 100 ms are angular; a light average takes the corners off."""
    for _ in range(passes):
        if len(arr) < 3:
            break
        inner = (arr[:-2] + 2 * arr[1:-1] + arr[2:]) / 4
        arr = np.concatenate([arr[:1], inner, arr[-1:]])
    return arr


def extent_of(strokes):
    pts = np.concatenate([np.asarray(s) for s in strokes])
    return float((pts.max(axis=0) - pts.min(axis=0)).max()) or 1.0


def distort(strokes, rng, strength=1.0, max_rotation=0.3):
    """A hand's variation: slant, aspect, tilt, a slow wobble and jitter, applied to the whole symbol.

    `max_rotation` (radians) bounds the tilt: a minus may lean 20 degrees and still be a minus, while
    a stroke at 30 to 50 degrees is a slash that is no symbol, so the two must not be tilted into each other."""
    ext = extent_of(strokes)
    pts = np.concatenate([np.asarray(s) for s in strokes])
    c = (pts.min(axis=0) + pts.max(axis=0)) / 2
    sx = 1 + rng.uniform(-0.22, 0.22) * strength
    sy = 1 + rng.uniform(-0.12, 0.12) * strength
    shear = rng.uniform(-0.3, 0.3) * strength
    theta = np.clip(rng.normal(0, 0.1), -max_rotation, max_rotation) * strength
    wobble = rng.uniform(0, 0.03) * strength * ext
    phase = rng.uniform(0, 2 * math.pi)
    jitter = rng.uniform(0, 0.012) * strength * ext
    out = []
    for s in strokes:
        p = np.asarray(s, dtype=np.float64) - c
        x = p[:, 0] * sx + shear * p[:, 1]
        y = p[:, 1] * sy
        x = x + wobble * np.sin(y / ext * 4 + phase)
        y = y + wobble * np.sin(x / ext * 4 + phase)
        xr = x * math.cos(theta) - y * math.sin(theta)
        yr = x * math.sin(theta) + y * math.cos(theta)
        q = np.stack([xr, yr], axis=1) + rng.normal(0, jitter, size=p.shape) + c
        out.append(q)
    return out


def line(a, b, bow=0.0, n=14):
    a, b = np.asarray(a, float), np.asarray(b, float)
    t = np.linspace(0, 1, n)[:, None]
    d = b - a
    normal = np.array([-d[1], d[0]])
    return a + t * d + (4 * t * (1 - t)) * bow * normal


def bezier(p0, p1, p2, p3, n=24):
    p0, p1, p2, p3 = (np.asarray(p, float) for p in (p0, p1, p2, p3))
    t = np.linspace(0, 1, n)[:, None]
    u = 1 - t
    return u ** 3 * p0 + 3 * u ** 2 * t * p1 + 3 * u * t ** 2 * p2 + t ** 3 * p3


def operator_strokes(symbol, rng):
    """One writing of an operator, in a box about one unit tall. Variation of a hand, not of the shape."""
    r = rng.uniform
    if symbol == "+":
        h, v = r(0.35, 0.85), r(0.35, 0.85)
        cx, cy = r(-0.1, 0.1) * h, r(-0.1, 0.1) * v
        strokes = [line((-h / 2, cy), (h / 2, cy), r(-0.06, 0.06)), line((cx, -v / 2), (cx, v / 2), r(-0.06, 0.06))]
        if rng.random() < 0.5:
            strokes.reverse()
        if rng.random() < 0.5:
            strokes = [s[::-1] for s in strokes]
        return strokes
    if symbol == "-":
        tilt = r(-0.14, 0.14)  # up to 8 degrees of its own, on top of what `distort` adds
        return [line((-0.5, -0.5 * math.tan(tilt)), (0.5, 0.5 * math.tan(tilt)), r(-0.12, 0.12))]
    if symbol == "*":
        a, b = r(0.45, 0.75), r(0.45, 0.75)
        c1, c2 = r(-0.08, 0.08), r(-0.08, 0.08)
        s1 = line((-a / 2 + c1, -b / 2), (a / 2 + c1, b / 2), r(-0.08, 0.08))
        s2 = line((a / 2 + c2, -b / 2), (-a / 2 + c2, b / 2), r(-0.08, 0.08))
        strokes = [s1, s2]
        if rng.random() < 0.5:
            strokes.reverse()
        return strokes
    if symbol == "÷":
        w = r(0.4, 0.85)
        gap_top, gap_bottom = r(0.16, 0.34), r(0.16, 0.34)
        dx1, dx2 = r(-0.06, 0.06), r(-0.06, 0.06)
        dot = lambda x, y: np.array([[x, y], [x + r(0, 0.03), y + r(0, 0.03)]])
        strokes = [line((-w / 2, 0), (w / 2, 0), r(-0.05, 0.05)), dot(dx1, -gap_top), dot(dx2, gap_bottom)]
        rng.shuffle(strokes)
        return strokes
    if symbol in ("(", ")"):
        bulge = r(0.14, 0.55)
        skew = r(-0.18, 0.18)
        top, bottom = np.array([0.0 + skew, -0.5]), np.array([0.0 - skew, 0.5])
        k = 1 if symbol == "(" else -1
        stroke = bezier(top, top + [-k * bulge * 1.3, 0.2], bottom + [-k * bulge * 1.3, -0.2], bottom)
        return [stroke if rng.random() < 0.8 else stroke[::-1]]
    raise ValueError(symbol)


def scribble(rng):
    k = int(rng.integers(4, 9))
    pts = rng.uniform(-0.5, 0.5, size=(k, 2))
    t = np.linspace(0, k - 1, 40)
    xs = np.interp(t, np.arange(k), pts[:, 0])
    ys = np.interp(t, np.arange(k), pts[:, 1])
    return [smooth(np.stack([xs, ys], axis=1), 3)]


def slash(rng):
    """A straight stroke that is neither a 1 (up to ~35 degrees off vertical) nor a minus (up to ~25 off horizontal)."""
    angle = math.radians(rng.uniform(40, 60)) * rng.choice([-1, 1])
    length = rng.uniform(0.6, 1.0)
    d = np.array([math.sin(angle), -math.cos(angle)]) * length / 2
    return [line(-d, d, rng.uniform(-0.04, 0.04))]


def european_one(rng):
    """A "1" written as a rise from the lower left to the top and a straight drop: one stroke, two legs."""
    r = rng.uniform
    ax = r(-0.05, 0.15)
    start = np.array([ax - r(0.2, 0.6), r(0.0, 0.5)])
    apex = np.array([ax, -0.5])
    end = np.array([ax + r(-0.06, 0.12), 0.5])
    first = line(start, apex, r(-0.1, 0.1), n=16)
    second = line(apex, end, r(-0.06, 0.06), n=16)
    return [np.concatenate([first, second[1:]])]


def place(strokes, x, y, height):
    """`strokes` (about one unit tall, centred on the origin) scaled to `height` with its centre at (x, y)."""
    ext_y = (lambda pts: pts[:, 1].max() - pts[:, 1].min())(np.concatenate([np.asarray(s) for s in strokes]))
    scale = height / max(ext_y, 1e-6) if ext_y > 1e-6 else height
    return [np.asarray(s) * scale + [x, y] for s in strokes]


class Symbols:
    """Everything that can be written as strokes: real digits (pendigits) and drawn operators."""

    def __init__(self, digits, rng, european=0.0):
        self.digits = digits  # list of (label, strokes) already smoothed and centred
        self.rng = rng
        self.european = european  # share of the digits that are drawn Λ-shaped ones

    def digit(self):
        if self.european and self.rng.random() < self.european:
            return 1, prepare_digit(european_one(self.rng))
        label, strokes = self.digits[int(self.rng.integers(len(self.digits)))]
        return label, [np.array(s) for s in strokes]

    def operator(self):
        symbol = ["+", "-", "*", "÷", "(", ")"][int(self.rng.integers(6))]
        return symbol, operator_strokes(symbol, self.rng)

    def any_symbol(self):
        return self.digit() if self.rng.random() < 0.6 else self.operator()

    def pair(self):
        """Two symbols that were cut as one: side by side, stacked, or a bar with one dot."""
        rng = self.rng
        kind = rng.random()
        if kind < 0.18:  # an equals sign, or a bar with one dot (the half of a ÷)
            w = rng.uniform(0.4, 0.85)
            first = line((-w / 2, 0), (w / 2, 0), rng.uniform(-0.05, 0.05))
            if rng.random() < 0.5:
                second = line((-w / 2, rng.uniform(0.18, 0.5)), (w / 2, rng.uniform(0.18, 0.5)), rng.uniform(-0.05, 0.05))
            else:
                y = rng.choice([-1, 1]) * rng.uniform(0.18, 0.34)
                second = np.array([[rng.uniform(-0.06, 0.06), y], [rng.uniform(-0.06, 0.06) + 0.02, y + 0.02]])
            return [first, second]
        a_label, a = self.any_symbol()
        b_label, b = self.any_symbol()

        # Each symbol is as big as it is written next to a digit one unit tall: digits and brackets are
        # that tall, the operators about half of it across, a minus about half as long.
        def fit(label, strokes):
            strokes = [np.asarray(s, dtype=float) for s in strokes]
            pts = np.concatenate(strokes)
            lo, hi = pts.min(axis=0), pts.max(axis=0)
            w, h = hi[0] - lo[0], hi[1] - lo[1]
            if label in ("+", "*", "÷"):
                scale = rng.uniform(0.45, 0.7) / max(w, h, 1e-6)
            elif label == "-":
                scale = rng.uniform(0.4, 0.65) / max(w, 1e-6)
            else:
                scale = rng.uniform(0.85, 1.2) / max(h, 1e-6)
            c = (lo + hi) / 2
            return [(s - c) * scale for s in strokes], w * scale, h * scale

        a, wa, ta = fit(a_label, a)
        b, wb, tb = fit(b_label, b)
        if kind < 0.8:  # side by side, never overlapping
            gap = rng.uniform(0.0, 0.55)
            xb = wa / 2 + gap + wb / 2
            dy = rng.uniform(-0.12, 0.12)
            b = [s + [xb, dy] for s in b]
        else:  # stacked, as the two halves of a fraction written without its bar
            gap = rng.uniform(0.05, 0.5)
            yb = ta / 2 + gap + tb / 2
            dx = rng.uniform(-0.15, 0.15)
            b = [s + [dx, yb] for s in b]
        return a + b

    def reject(self):
        """Strokes that are no symbol, and the kind of them (a slash is not tilted like the rest)."""
        r = self.rng.random()
        if r < 0.62:
            return self.pair(), "pair"
        if r < 0.82:
            return scribble(self.rng), "scribble"
        if r < 0.92:
            return slash(self.rng), "slash"
        # three in a row
        first = self.pair()
        label, c = self.any_symbol()
        ext = np.concatenate([np.asarray(s) for s in first])
        c = [np.asarray(s, dtype=float) for s in c]
        ec = np.concatenate(c)
        scale = (ext[:, 1].max() - ext[:, 1].min()) / max(ec[:, 1].max() - ec[:, 1].min(), 1e-6)
        scale = min(scale, 1.2 / max(ec[:, 0].max() - ec[:, 0].min(), 1e-6))
        shift = ext[:, 0].max() + self.rng.uniform(0.05, 0.5) - (ec[:, 0].min() * scale)
        return first + [s * scale + [shift, 0] for s in c], "triple"


def prepare_digit(strokes):
    out = []
    for s in strokes:
        dense = resample(s, step=max(extent_of(strokes) / 60, 1e-3))
        out.append(smooth(dense, 2))
    return out


def draw(strokes, rng, strength=1.0, width_range=(1.7, 3.0), max_rotation=0.3):
    return render(distort(strokes, rng, strength, max_rotation), width=rng.uniform(*width_range))


def build_stroke_set(symbols, rng, counts):
    """Rendered samples of the classes that come as strokes."""
    xs, ys = [], []

    def add(strokes, label, **kwargs):
        img = draw(strokes, rng, **kwargs)
        if img is not None:
            xs.append(img)
            ys.append(label)

    for _ in range(counts["digits"]):
        label, strokes = symbols.digit()
        add(strokes, label)
    for _ in range(counts["operators"]):
        symbol, strokes = symbols.operator()
        add(strokes, SYMBOLS.index(symbol), max_rotation=0.2 if symbol == "-" else 0.3)
    for _ in range(counts["reject"]):
        strokes, kind = symbols.reject()
        # A slash keeps the angle it was drawn at: that angle is what makes it no symbol.
        add(strokes, REJECT, **({"max_rotation": 0.0, "strength": 0.3} if kind == "slash" else {}))
    return np.stack(xs), np.asarray(ys, dtype=np.int64)


_SHARED = {}


def _chunk(job):
    seed, counts = job
    rng = np.random.default_rng(seed)
    return build_stroke_set(Symbols(_SHARED["digits"], rng, _SHARED.get("european", 0.0)), rng, counts)


def build_stroke_set_parallel(digits, seed, counts, european=0.0):
    """The same, spread over the cores: rendering is the slow part of the whole script."""
    import multiprocessing
    cores = os.cpu_count() or 1
    parts = cores * 3
    jobs = []
    for k in range(parts):
        jobs.append((seed * 1000 + k, {name: (count // parts) + (1 if k < count % parts else 0) for name, count in counts.items()}))
    _SHARED["digits"] = digits
    _SHARED["european"] = european
    with multiprocessing.get_context("fork").Pool(cores) as pool:
        results = pool.map(_chunk, jobs)
    return np.concatenate([r[0] for r in results]), np.concatenate([r[1] for r in results])


# MARK: the network

class Net(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv2d(1, 16, 3, padding=1)
        self.conv2 = nn.Conv2d(16, 32, 3, padding=1)
        self.fc1 = nn.Linear(32 * 7 * 7, 64)
        self.fc2 = nn.Linear(64, CLASSES)
        self.drop = nn.Dropout(0.25)

    def forward(self, x):
        x = F.max_pool2d(F.relu(self.conv1(x)), 2)
        x = F.max_pool2d(F.relu(self.conv2(x)), 2)
        x = self.drop(F.relu(self.fc1(x.flatten(1))))
        return self.fc2(x)


def augment_images(x):
    """Small affine changes and thicker or thinner strokes, on a batch of pictures."""
    n = x.shape[0]
    angle = (torch.rand(n, device=x.device) - 0.5) * 2 * math.radians(6)
    shear = (torch.rand(n, device=x.device) - 0.5) * 0.25
    sx = 1 + (torch.rand(n, device=x.device) - 0.5) * 0.3
    sy = 1 + (torch.rand(n, device=x.device) - 0.5) * 0.2
    tx = (torch.rand(n, device=x.device) - 0.5) * 2 * (2.0 / 14)
    ty = (torch.rand(n, device=x.device) - 0.5) * 2 * (2.0 / 14)
    cos, sin = torch.cos(angle), torch.sin(angle)
    theta = torch.zeros(n, 2, 3, device=x.device)
    theta[:, 0, 0] = cos / sx
    theta[:, 0, 1] = (-sin + shear) / sx
    theta[:, 1, 0] = sin / sy
    theta[:, 1, 1] = cos / sy
    theta[:, 0, 2] = tx
    theta[:, 1, 2] = ty
    grid = F.affine_grid(theta, x.shape, align_corners=False)
    out = F.grid_sample(x, grid, padding_mode="zeros", align_corners=False)
    pick = torch.rand(n, device=x.device)
    thick = F.max_pool2d(out, 3, 1, 1)
    thin = -F.max_pool2d(-out, 3, 1, 1)
    out = torch.where((pick < 0.2).view(-1, 1, 1, 1), thick, out)
    out = torch.where(((pick >= 0.2) & (pick < 0.32)).view(-1, 1, 1, 1), thin, out)
    return out.clamp(0, 1)


def accuracy(model, x, y, batch=2000):
    model.eval()
    dev = next(model.parameters()).device
    pred = []
    with torch.no_grad():
        for i in range(0, len(x), batch):
            pred.append(model(torch.from_numpy(x[i:i + batch])[:, None].to(dev)).argmax(1).cpu())
    pred = torch.cat(pred).numpy()
    return float((pred == y).mean()), pred


def export_swift(model, path, notes):
    sd = {k: v.detach().cpu().numpy().astype(np.float16) for k, v in model.state_dict().items()}
    order = ["conv1.weight", "conv1.bias", "conv2.weight", "conv2.bias", "fc1.weight", "fc1.bias", "fc2.weight", "fc2.bias"]
    blob = b"".join(sd[k].astype("<f2").tobytes() for k in order)
    text = base64.b64encode(blob).decode()
    lines = [text[i:i + 100] for i in range(0, len(text), 100)]
    body = "\n".join(lines)
    with open(path, "w") as f:
        f.write(
            "// Generated by scripts/symbols/train_symbols.py; do not edit by hand.\n"
            + "".join(f"// {n}\n" for n in notes)
            + "\n"
            "import Foundation\n\n"
            "extension SymbolNet {\n"
            "  // float16, little endian: conv1 (16x1x3x3, 16), conv2 (32x16x3x3, 32), fc1 (64x1568, 64), fc2 (17x64, 17).\n"
            '  // The closing delimiter sits in the first column so the lines need no indentation.\n'
            '  static let bundledWeights = """\n' + body + '\n"""\n}\n'
        )
    return len(blob)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", required=True)
    ap.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "../../Sources/NoteCraftCore/Calculator/SymbolNetWeights.swift"))
    ap.add_argument("--epochs", type=int, default=14)
    ap.add_argument("--seed", type=int, default=20261114)
    ap.add_argument("--quick", action="store_true", help="few samples, for trying the script")
    ap.add_argument("--mine", help="JSON of strokes cut from a reader's pages: [{label, page, strokes}], see goodnotes_labels.py")
    ap.add_argument("--hold-out-mod", type=int, default=4, help="pages whose number divides by this are only evaluated on")
    ap.add_argument("--european", type=float, default=0.0, help="share of the training digits drawn as Λ-shaped ones")
    ap.add_argument("--mine-repeat", type=int, default=1, help="how often each of the reader's strokes is in the digit pool")
    args = ap.parse_args()
    os.makedirs(args.data, exist_ok=True)
    rng = np.random.default_rng(args.seed)
    torch.manual_seed(args.seed)
    g = torch.Generator().manual_seed(args.seed)

    mnist = load_mnist(args.data)
    pen = load_pendigits(args.data)
    print("mnist", mnist["train"][0].shape, "pendigits", len(pen["train"]), len(pen["test"]))

    train_digits = [(l, prepare_digit(s)) for l, s in pen["train"]]
    test_digits = [(l, prepare_digit(s)) for l, s in pen["test"]]
    mine_train, mine_test = [], []
    if args.mine:
        import json
        for item in json.load(open(args.mine)):
            strokes = [np.asarray(st, dtype=np.float64) for st in item["strokes"] if len(st) > 0]
            if not strokes:
                continue
            sample = (int(item["label"]), prepare_digit(strokes))
            (mine_test if item["page"] % args.hold_out_mod == 0 else mine_train).append(sample)
        train_digits = train_digits + mine_train * args.mine_repeat
        print("reader's strokes: training", len(mine_train), np.bincount([l for l, _ in mine_train], minlength=10), "held out", len(mine_test))
    scale = 0.05 if args.quick else 1.0
    n = lambda v: max(50, int(v * scale))
    # Rendering is the slow part; the pictures are kept next to the data for the next run.
    tag = f"_mine{len(mine_train)}x{args.mine_repeat}_eu{args.european}" if (args.mine or args.european) else ""
    cache = os.path.join(args.data, f"rendered_{args.seed}_{'quick' if args.quick else 'full'}{tag}.npz")
    if os.path.exists(cache):
        cached = np.load(cache)
        xs, ys = cached["xs"], cached["ys"]
    else:
        xs, ys = build_stroke_set_parallel(
            train_digits, args.seed, {"digits": n(60000), "operators": n(48000), "reject": n(50000)},
            european=args.european)
        np.savez(cache, xs=xs, ys=ys)
    mx, my = mnist["train"]
    if args.quick:
        mx, my = mx[:3000], my[:3000]
    # The network sees MNIST pictures as they are and everything else rendered; both are digits.
    x_all = np.concatenate([mx, xs]).astype(np.float32)
    y_all = np.concatenate([my, ys])
    print("train", x_all.shape, np.bincount(y_all, minlength=CLASSES))

    # Held-out sets.
    eval_rng = np.random.default_rng(args.seed + 1)
    pen_x, pen_y = [], []
    for label, strokes in test_digits:
        img = render(strokes)  # as written, no distortion: what the app will feed it
        if img is not None:
            pen_x.append(img); pen_y.append(label)
    pen_x, pen_y = np.stack(pen_x), np.asarray(pen_y)
    # Other seeds than any training chunk uses; the pairs are of digits that were written by other people.
    op_x, op_y = build_stroke_set_parallel(test_digits, args.seed + 7, {"digits": 0, "operators": n(3000), "reject": 0})
    rej_x, rej_y = build_stroke_set_parallel(test_digits, args.seed + 9, {"digits": 0, "operators": 0, "reject": n(3000)})
    plain_ops = []
    for symbol in ["+", "-", "*", "÷", "(", ")"]:
        for _ in range(100 if not args.quick else 5):
            img = render(operator_strokes(symbol, eval_rng))
            plain_ops.append((img, SYMBOLS.index(symbol)))

    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    print("training on", dev)
    model = Net().to(dev)
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    steps_per_epoch = math.ceil(len(x_all) / 256)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=3e-3, total_steps=args.epochs * steps_per_epoch)
    xt = torch.from_numpy(x_all)[:, None].to(dev)
    yt = torch.from_numpy(y_all).to(dev)
    for epoch in range(args.epochs):
        model.train()
        perm = torch.randperm(len(xt), generator=g).to(dev)
        total = 0.0
        for i in range(0, len(perm), 256):
            idx = perm[i:i + 256]
            xb = augment_images(xt[idx])
            loss = F.cross_entropy(model(xb), yt[idx], label_smoothing=0.02)
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
            total += float(loss.detach()) * len(idx)
        mn, _ = accuracy(model, mnist["test"][0], mnist["test"][1])
        pn, _ = accuracy(model, pen_x, pen_y)
        print(f"epoch {epoch + 1:2d} loss {total / len(perm):.4f}  mnist test {mn:.4f}  pendigits (new writers) {pn:.4f}")

    # Round the weights to float16 as they will be stored, and measure again.
    with torch.no_grad():
        for p in model.parameters():
            p.copy_(p.half().float())
    model.eval()
    mn, _ = accuracy(model, mnist["test"][0], mnist["test"][1])
    pn, ppred = accuracy(model, pen_x, pen_y)
    on, _ = accuracy(model, op_x, op_y)
    rn, _ = accuracy(model, rej_x, rej_y)
    pox = np.stack([p[0] for p in plain_ops]); poy = np.asarray([p[1] for p in plain_ops])
    po, _ = accuracy(model, pox, poy)
    print(f"float16: mnist {mn:.4f}  pendigits new writers {pn:.4f}  operators {on:.4f} (distorted) {po:.4f} (plain)  pairs rejected {rn:.4f}")
    # How often a real digit is thrown out, and how often a digit is read as another one.
    thrown = float((ppred == REJECT).mean())
    print(f"real digits called 'not a symbol': {thrown:.4f}")

    if mine_test:
        for digit in sorted({l for l, _ in mine_test}):
            imgs = [render(st) for l, st in mine_test if l == digit]
            imgs = np.stack([i for i in imgs if i is not None])
            acc, pred = accuracy(model, imgs, np.full(len(imgs), digit))
            print(f"reader's held-out {digit}: {acc:.4f} of {len(imgs)} right, {float((pred == REJECT).mean()):.4f} called 'not a symbol'")

    notes = [
        f"MNIST test {mn:.4f}; pendigits, 14 writers not in training, {pn:.4f}; drawn operators {on:.4f}; pairs and scribbles refused {rn:.4f}.",
        f"seed {args.seed}, {args.epochs} epochs, stroke width {WIDTH} px.",
    ]
    if args.mine or args.european:
        notes.append(
            f"also taught: Λ-shaped ones ({args.european:.0%} of the drawn digits) and {len(mine_train)} strokes of one "
            "reader's digits (their Λ-shaped 1 and roofed 5 among them).")
    size = export_swift(model, args.out, notes)
    print("wrote", args.out, size, "bytes of weights")
    torch.save({k: v.cpu() for k, v in model.state_dict().items()}, os.path.join(args.data, "symbols.pt"))
    np.savez(os.path.join(args.data, "eval_sets.npz"), pen_x=pen_x, pen_y=pen_y)


if __name__ == "__main__":
    main()
