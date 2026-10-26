# Draws the 录课 app icon: a clay squircle with a handwritten formula, a pen and a record dot.
import math, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont
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

white = (0xFA, 0xF9, 0xF5, 255)
# Times New Roman Italic on a Mac; Liberation Serif Italic (same metrics) elsewhere.
font = sys.argv[2] if len(sys.argv) > 2 else '/System/Library/Fonts/Supplemental/Times New Roman Italic.ttf'

# The formula, written large: x²
layer = Image.new('RGBA', (N, N), (0, 0, 0, 0))
ld = ImageDraw.Draw(layer)
ld.text((p(196), p(150)), 'x', font=ImageFont.truetype(font, p(400)), fill=white)
ld.text((p(440), p(150)), '2', font=ImageFont.truetype(font, p(210)), fill=white)
img.alpha_composite(layer)

# A pen held as if writing: tip at the lower left, barrel rising to the upper right.
pen = Image.new('RGBA', (N, N), (0, 0, 0, 0))
pd = ImageDraw.Draw(pen)
L, W = 420, 96            # barrel length and width, drawn horizontal with the tip on the left
cx0, cy0 = 512, 512
left = cx0 - L / 2
pd.rounded_rectangle([p(left), p(cy0 - W / 2), p(cx0 + L / 2), p(cy0 + W / 2)], radius=p(26), fill=white)
pd.polygon([(p(left + 4), p(cy0 - W / 2)), (p(left - 112), p(cy0)), (p(left + 4), p(cy0 + W / 2))], fill=white)
pd.rectangle([p(left + 8), p(cy0 - W / 2), p(left + 34), p(cy0 + W / 2)], fill=(0xCE, 0x6C, 0x4A, 255))
pd.polygon([(p(left - 68), p(cy0 - 18)), (p(left - 112), p(cy0)), (p(left - 68), p(cy0 + 18))], fill=(0x3A, 0x2A, 0x24, 255))
pen = pen.rotate(40, center=(p(cx0), p(cy0)), resample=Image.BICUBIC)
pen = pen.transform(pen.size, Image.AFFINE, (1, 0, p(-90), 0, 1, p(-60)))
img.alpha_composite(pen)

# Record badge at the lower right, set off from the pen with a clay ring.
cx, cy = 740, 736
ring = Image.new('L', (N, N), 0)
ImageDraw.Draw(ring).ellipse([p(cx - 150), p(cy - 150), p(cx + 150), p(cy + 150)], fill=255)
img.paste(grad, (0, 0), Image.composite(ring, Image.new('L', (N, N), 0), mask))
d = ImageDraw.Draw(img)
d.ellipse([p(cx - 120), p(cy - 120), p(cx + 120), p(cy + 120)], fill=white)
red = (0xE5, 0x48, 0x3B, 255)
d.ellipse([p(cx - 74), p(cy - 74), p(cx + 74), p(cy + 74)], fill=red)

img.resize((1024, 1024), Image.LANCZOS).save(sys.argv[1])
