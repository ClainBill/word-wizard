"""Render the Lexery app icon set from the Fraunces variable font.

Writes:
  assets/icon/icon.png                                   1024x1024, full-bleed (iOS + flutter_launcher_icons source)
  assets/icon/icon_foreground.png                        1024x1024, transparent, glyph inside the adaptive safe zone
  android/app/src/main/res/drawable/ic_notification.png  256x256, white silhouette for the status bar

Then regenerate the platform launcher icons:

    python3 -m pip install pillow
    curl -L -o /tmp/Fraunces.ttf \\
      "https://github.com/undercasetype/Fraunces/raw/master/fonts/variable/Fraunces%5BSOFT%2CWONK%2Copsz%2Cwght%5D.ttf"
    python3 tool/render_icon.py /tmp/Fraunces.ttf
    dart run flutter_launcher_icons

The mark: a cream "L" (Fraunces, opsz 144, SOFT 30, WONK on, weight 600) set
left of centre, and a bookmark ribbon hanging from the top edge at the right —
the "library" half of the name — on the `#8A5A22` field the app has always used.
"""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
OCHRE = (0x8A, 0x5A, 0x22, 255)
CREAM = (0xF4, 0xF1, 0xE6, 255)
WHITE = (255, 255, 255, 255)


def glyph_font(path: str, size: int) -> ImageFont.FreeTypeFont:
    f = ImageFont.truetype(path, size)
    # Axis order in the file: Optical Size, Softness, Weight, Wonky.
    f.set_variation_by_axes([144, 30, 600, 1])
    return f


def draw_mark(canvas: Image.Image, scale: float, color, font_path: str) -> None:
    """Draw the monogram onto a square canvas. `scale` = 1 is full-bleed; less shrinks it toward the centre."""
    w = canvas.size[0]
    d = ImageDraw.Draw(canvas)
    s = w / 1024 * scale
    f = glyph_font(font_path, int(600 * s))
    bbox = d.textbbox((0, 0), 'L', font=f)
    gw, gh = bbox[2] - bbox[0], bbox[3] - bbox[1]
    cx, cy = w / 2 - 70 * s, w / 2 + 30 * s
    d.text((cx - gw / 2 - bbox[0], cy - gh / 2 - bbox[1]), 'L', font=f, fill=color)
    # Ribbon: from the top edge when full-bleed, otherwise from just above the glyph.
    x0, x1 = w / 2 + 170 * s, w / 2 + 350 * s
    top = w / 2 - 512 * s if scale >= 1 else cy - gh / 2 - 30 * s
    y1 = top + 290 * s
    notch = 90 * s
    d.polygon([(x0, top), (x1, top), (x1, y1), ((x0 + x1) / 2, y1 - notch), (x0, y1)], fill=color)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit('usage: render_icon.py <path to Fraunces variable .ttf>')
    font = sys.argv[1]

    icon = Image.new('RGBA', (1024, 1024), OCHRE)
    draw_mark(icon, 1.0, CREAM, font)
    icon.convert('RGB').save(ROOT / 'assets/icon/icon.png')

    fg = Image.new('RGBA', (1024, 1024), (0, 0, 0, 0))
    draw_mark(fg, 0.62, CREAM, font)
    fg.save(ROOT / 'assets/icon/icon_foreground.png')

    notif = Image.new('RGBA', (256, 256), (0, 0, 0, 0))
    draw_mark(notif, 0.9, WHITE, font)
    notif.save(ROOT / 'android/app/src/main/res/drawable/ic_notification.png')
    print('wrote icon.png, icon_foreground.png, ic_notification.png')


if __name__ == '__main__':
    main()
