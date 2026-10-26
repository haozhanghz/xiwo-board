# Draws the 录课 app icon: a clay squircle with a white board, a written stroke and a record dot.
import math, sys
from PIL import Image, ImageDraw, ImageFilter
S = 4  # supersampling
N = 1024 * S
def p(v): return int(v * S)

img = Image.new('RGBA', (N, N), (0, 0, 0, 0))

# Squircle mask (superellipse, n=5) on Apple's 824 grid.
def squircle(cx, cy, r, n=5.0, steps=2000):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = abs(c) ** (2 / n) * r * (1 if c >= 0 else -1)
        y = abs(s) ** (2 / n) * r * (1 if s >= 0 else -1)
        pts.append((p(cx + x), p(cy + y)))
    return pts

# Soft shadow.
sh = Image.new('L', (N, N), 0)
ImageDraw.Draw(sh).polygon(squircle(512, 524, 412), fill=90)
sh = sh.filter(ImageFilter.GaussianBlur(p(14)))
img.paste((0, 0, 0, 255), (0, 0), sh)

# Clay background with a gentle top-to-bottom gradient.
mask = Image.new('L', (N, N), 0)
ImageDraw.Draw(mask).polygon(squircle(512, 512, 412), fill=255)
top, bot = (0xE0, 0x86, 0x66), (0xC9, 0x64, 0x42)
grad = Image.new('RGBA', (N, N))
gd = ImageDraw.Draw(grad)
for y in range(N):
    f = y / (N - 1)
    gd.line([(0, y), (N, y)], fill=tuple(int(top[i] + (bot[i] - top[i]) * f) for i in range(3)) + (255,))
img.paste(grad, (0, 0), mask)

d = ImageDraw.Draw(img)
white = (0xFA, 0xF9, 0xF5, 255)
# Board outline.
d.rounded_rectangle([p(212), p(282), p(772), p(670)], radius=p(58), outline=white, width=p(40))
# Handwriting on the board: a cursive loop, like a teacher's stroke.
def stroke(pts, w):
    for (x, y) in pts:
        d.ellipse([p(x - w / 2), p(y - w / 2), p(x + w / 2), p(y + w / 2)], fill=white)
# A loose, hand-drawn tick: short leg down, long leg up, slightly curved.
def bez(p0, p1, p2, n=400):
    return [((1-t)**2*p0[0] + 2*(1-t)*t*p1[0] + t*t*p2[0], (1-t)**2*p0[1] + 2*(1-t)*t*p1[1] + t*t*p2[1])
            for t in (i / (n - 1) for i in range(n))]
pts = bez((330, 470), (370, 505), (418, 556)) + bez((418, 556), (500, 430), (640, 380))
stroke(pts, 46)
# Record badge over the board's lower-right corner, cut out of the board with a clay ring.
cx, cy = 752, 650
ring = Image.new('L', (N, N), 0)
ImageDraw.Draw(ring).ellipse([p(cx - 150), p(cy - 150), p(cx + 150), p(cy + 150)], fill=255)
img.paste(grad, (0, 0), Image.composite(ring, Image.new('L', (N, N), 0), mask))
d.ellipse([p(cx - 118), p(cy - 118), p(cx + 118), p(cy + 118)], fill=white)
red = (0xC9, 0x3F, 0x2F, 255)
d.ellipse([p(cx - 58), p(cy - 58), p(cx + 58), p(cy + 58)], fill=red)

img.resize((1024, 1024), Image.LANCZOS).save(sys.argv[1])
