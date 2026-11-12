"""Draws Resources/AppIcon.png: the light Margin icon, flat.

A light tile on the macOS 1024 grid (824 pt body, 100 pt margin), the dark
bracket and dot in solid ink. No highlights. Only a hairline edge and a faint
shadow, so the tile holds its shape on a light Dock.
Run: python3 scripts/make-icon.py [out.png]
"""
import math
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 4                      # supersampling
N = 1024 * S
BODY = 824 * S
M = (N - BODY) // 2
PAPER = (245, 245, 243, 255)
INK = (22, 22, 24, 255)


def squircle(size, n=4.6):
    """Superellipse mask, the shape of macOS icons."""
    mask = Image.new("L", (N, N), 0)
    a = size / 2
    pts = []
    for i in range(720):
        t = i / 720 * 2 * math.pi
        c, s = math.cos(t), math.sin(t)
        pts.append((N / 2 + a * math.copysign(abs(c) ** (2 / n), c),
                    N / 2 + a * math.copysign(abs(s) ** (2 / n), s)))
    ImageDraw.Draw(mask).polygon(pts, fill=255)
    return mask


def solid(color, mask):
    layer = Image.new("RGBA", (N, N), color[:3] + (0,))
    layer.putalpha(mask.point(lambda v: v * color[3] // 255))
    return layer


body = squircle(BODY)
canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

# Faint shadow.
shadow = solid((0, 0, 0, 38), body)
canvas.alpha_composite(ImageChops.offset(shadow, 0, 6 * S).filter(ImageFilter.GaussianBlur(14 * S)))

# Tile and hairline edge.
canvas.alpha_composite(solid(PAPER, body))
edge = ImageChops.subtract(body, squircle(BODY - 3 * S))
canvas.alpha_composite(solid((0, 0, 0, 22), edge))

# The mark, on the BracketMark 300 grid.
k = BODY / 300 * 0.9
ox = oy = N / 2 - 150 * k


def r(x, y, w, h):
    return (ox + x * k, oy + y * k, ox + (x + w) * k, oy + (y + h) * k)


mark = Image.new("L", (N, N), 0)
d = ImageDraw.Draw(mark)
for box in (r(72, 70, 22, 160), r(72, 70, 58, 22), r(72, 208, 58, 22)):
    d.rectangle(box, fill=255)
d.ellipse(r(198 - 23, 150 - 23, 46, 46), fill=255)
canvas.alpha_composite(solid(INK, mark))

out = sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.png"
canvas.resize((1024, 1024), Image.LANCZOS).save(out)
print("wrote", out)
