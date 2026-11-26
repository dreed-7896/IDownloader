"""Drift app icon: a mint globe ring with a white arrow dropping through it, on near-black."""
from PIL import Image, ImageDraw

S = 4
W = 1024 * S
BG = (11, 11, 15)
MINT = (61, 214, 163)
MINT_DARK = (34, 128, 98)
WHITE = (244, 244, 246)


def p(*pts):
    return [(x * S, y * S) for x, y in pts]


img = Image.new('RGB', (W, W), BG)
d = ImageDraw.Draw(img)
cx, cy = 512, 476

# Globe: a thick ring with one meridian and one parallel, the lower part a darker mint.
R, r = 300, 236
d.ellipse([(cx - R) * S, (cy - R) * S, (cx + R) * S, (cy + R) * S], fill=MINT)
d.ellipse([(cx - r) * S, (cy - r) * S, (cx + r) * S, (cy + r) * S], fill=BG)
lw = 40
d.ellipse([(cx - 112) * S, (cy - r) * S, (cx + 112) * S, (cy + r) * S], outline=MINT_DARK, width=lw * S)
d.rectangle([(cx - r) * S, (cy - lw / 2) * S, (cx + r) * S, (cy + lw / 2) * S], fill=MINT_DARK)

# Arrow: shaft from above the ring, head below it, cut out from the globe by a background gap.
gap = 34
shaft_w, head_w = 104, 300
top, head_y, tip = 318, 628, 848


def arrow(grow, color):
    sw, hw = shaft_w / 2 + grow, head_w / 2 + grow
    d.polygon(p((cx - sw, top - grow), (cx + sw, top - grow), (cx + sw, head_y), (cx + hw, head_y),
                (cx, tip + grow * 1.4), (cx - hw, head_y), (cx - sw, head_y)), fill=color)


arrow(gap, BG)
arrow(0, WHITE)

img.resize((1024, 1024), Image.LANCZOS).save('icon.png')
