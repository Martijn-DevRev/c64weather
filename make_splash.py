"""
make_splash.py — generate splash.kla for C64U_Weather boot screen

Text uses the real C64 chargen ROM (uppercase, 8x8 per glyph).
The Koala resize uses NEAREST so char pixels stay pure black/white.
The GitHub URL is rendered as a QR code (scale=3 → 3 screen px/module).

Output: splash.kla (10001 bytes, NO 2-byte load-address header)
  [+0]     8000 bytes  bitmap
  [+8000]  1000 bytes  screen RAM colours
  [+9000]  1000 bytes  colour RAM
  [+10000] 1 byte      background colour index (1 = white)
"""

import os
from PIL import Image, ImageDraw
import qrcode

# ── C64 palette ───────────────────────────────────────────────────────────────
PALETTE = [
    (0,   0,   0),    # 0  Black
    (255, 255, 255),  # 1  White
    (136, 0,   0),    # 2  Red
    (170, 255, 238),  # 3  Cyan
    (204, 68,  204),  # 4  Purple
    (0,   204, 85),   # 5  Green
    (0,   0,   170),  # 6  Blue
    (238, 238, 119),  # 7  Yellow
    (221, 136, 85),   # 8  Orange
    (102, 68,  0),    # 9  Brown
    (255, 119, 119),  # 10 Light Red
    (51,  51,  51),   # 11 Dark Grey
    (119, 119, 119),  # 12 Grey
    (170, 255, 102),  # 13 Light Green
    (0,   136, 255),  # 14 Light Blue
    (187, 187, 187),  # 15 Light Grey
]
BG_COLOR = 1   # White

# ── C64 chargen ROM ───────────────────────────────────────────────────────────
CHARGEN_PATH = (
    "/Users/martijn/PLuG64/vice/VICE.app/Contents/Resources/share/vice/C64/"
    "chargen-906143-02.bin"
)

def load_chargen():
    with open(CHARGEN_PATH, "rb") as f:
        return f.read()

def ascii_to_screen_code(ch):
    a = ord(ch.upper())
    if 32 <= a <= 63:    return a
    elif 64 <= a <= 95:  return a - 64
    else:                return 32

def draw_c64_text(canvas, chargen, text, x, y, color=(0, 0, 0), scale=1):
    """Stamp C64 ROM glyphs onto the canvas.

    scale=1 → 8 px wide per char (natural)
    scale=2 → 16 px wide per char (each bit doubled horizontally)

    With NEAREST ÷2 resize, scale=2 ensures every char bit maps to exactly
    one sampled Koala column — no pixels are lost.
    """
    pix = canvas.load()
    W, H = canvas.size
    cx = x
    for ch in text:
        sc = ascii_to_screen_code(ch)
        glyph = chargen[sc * 8 : sc * 8 + 8]
        for row, byte in enumerate(glyph):
            py = y + row
            if py >= H:
                continue
            for bit in range(8):
                if byte & (0x80 >> bit):
                    for dx in range(scale):
                        px = cx + bit * scale + dx
                        if 0 <= px < W:
                            pix[px, py] = color
        cx += 8 * scale

def c64_text_x_centered(text, canvas_w, scale=1):
    return (canvas_w - len(text) * 8 * scale) // 2

# ── QR code ───────────────────────────────────────────────────────────────────
def make_qr_image(url):
    qr = qrcode.QRCode(
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=1,
        border=2,
    )
    qr.add_data(url)
    qr.make(fit=True)
    return qr.make_image(fill_color="black", back_color="white").convert("L")

def paste_qr(canvas, qr_img, x, y, scale):
    """Paste QR onto canvas with integer scaling (purely binary, no blur)."""
    pix_qr  = qr_img.load()
    pix_out = canvas.load()
    W, H = canvas.size
    for qy in range(qr_img.height):
        for qx in range(qr_img.width):
            c = (0, 0, 0) if pix_qr[qx, qy] == 0 else (255, 255, 255)
            for dy in range(scale):
                for dx in range(scale):
                    px, py = x + qx * scale + dx, y + qy * scale + dy
                    if 0 <= px < W and 0 <= py < H:
                        pix_out[px, py] = c

# ── Koala converter ───────────────────────────────────────────────────────────
def nearest_c64(rgb):
    best, best_dist = 0, float('inf')
    for i, c in enumerate(PALETTE):
        d = sum((a - b) ** 2 for a, b in zip(rgb, c))
        if d < best_dist:
            best_dist, best = d, i
    return best

def to_koala(img_320x200):
    """Convert 320x200 RGB image to raw Koala bytes (no load-address header).

    Uses NEAREST resize so that binary (chargen + QR) pixels are not blurred.
    """
    mc = img_320x200.resize((160, 200), Image.NEAREST)

    pixels  = [mc.getpixel((x, y)) for y in range(200) for x in range(160)]
    indices = [nearest_c64(p) for p in pixels]

    bitmap     = bytearray(8000)
    screen_ram = bytearray(1000)
    color_ram  = bytearray(1000)

    for ry in range(0, 200, 8):
        for rx in range(0, 160, 4):
            block  = [indices[(ry + y) * 160 + (rx + x)]
                      for y in range(8) for x in range(4)]
            unique = [c for c in dict.fromkeys(block) if c != BG_COLOR]
            c1 = unique[0] if len(unique) > 0 else 0
            c2 = unique[1] if len(unique) > 1 else 0
            c3 = unique[2] if len(unique) > 2 else 0

            idx = (ry // 8) * 40 + (rx // 4)
            screen_ram[idx] = (c1 << 4) | c2
            color_ram[idx]  = c3

            for y in range(8):
                byte = 0
                for x in range(4):
                    col = indices[(ry + y) * 160 + (rx + x)]
                    if   col == c1:       bits = 1
                    elif col == c2:       bits = 2
                    elif col == c3:       bits = 3
                    elif col == BG_COLOR: bits = 0
                    else:                 bits = 0
                    byte = (byte << 2) | bits
                bitmap[idx * 8 + y] = byte

    return bytes(bitmap) + bytes(screen_ram) + bytes(color_ram) + bytes([BG_COLOR])


# ── Main ──────────────────────────────────────────────────────────────────────
def make_splash(logo_path, out_path):
    W, H   = 320, 200
    WHITE  = (255, 255, 255)

    canvas  = Image.new("RGB", (W, H), WHITE)
    chargen = load_chargen()

    # ── Logo ─────────────────────────────────────────────────────────────────
    logo_raw = Image.open(logo_path).convert("RGBA")
    logo_raw.thumbnail((W - 20, 60), Image.LANCZOS)
    bg = Image.new("RGB", logo_raw.size, WHITE)
    bg.paste(logo_raw, mask=logo_raw.split()[3])
    canvas.paste(bg, ((W - bg.width) // 2, 4))
    logo_bottom = 4 + bg.height + 6

    # ── Credit text (scale=2) ─────────────────────────────────────────────────
    draw_c64_text(canvas, chargen, "CODE BY MARTIJN",
                  c64_text_x_centered("CODE BY MARTIJN", W, scale=2),
                  logo_bottom, scale=2)
    draw_c64_text(canvas, chargen, "(AND CLAUDE)",
                  c64_text_x_centered("(AND CLAUDE)", W, scale=2),
                  logo_bottom + 10, scale=2)

    text_bottom = logo_bottom + 10 + 8 + 2   # tight gap to preserve room below

    # ── QR code (centred, scale=3, border=2) ─────────────────────────────────
    github_url  = "https://github.com/Martijn-DevRev/c64weather"
    qr_img      = make_qr_image(github_url)
    qr_scale    = 3
    qr_canvas_w = qr_img.width  * qr_scale
    qr_canvas_h = qr_img.height * qr_scale
    qr_x = (W - qr_canvas_w) // 2
    qr_y = text_bottom
    paste_qr(canvas, qr_img, qr_x, qr_y, scale=qr_scale)

    # Remaining vertical space below QR
    below_qr   = H - (qr_y + qr_canvas_h)   # pixels left
    # Layout: email1(8) + gap(2) + email2(8) + gap(2) + press(8) = 28px needed
    email1_y   = qr_y + qr_canvas_h + max(1, (below_qr - 28) // 4)
    email2_y   = email1_y + 10
    press_y    = email2_y + 10

    # ── Email (scale=2, split across two lines) ───────────────────────────────
    draw_c64_text(canvas, chargen, "MARTIJN@",
                  c64_text_x_centered("MARTIJN@", W, scale=2),
                  email1_y, scale=2)
    draw_c64_text(canvas, chargen, "RUNSTOPRESTORE.NL",
                  c64_text_x_centered("RUNSTOPRESTORE.NL", W, scale=2),
                  email2_y, scale=2)

    # ── PRESS SPACE ───────────────────────────────────────────────────────────
    press = "PRESS SPACE"
    draw_c64_text(canvas, chargen, press,
                  c64_text_x_centered(press, W, scale=2),
                  press_y, scale=2)

    # ── Save preview ──────────────────────────────────────────────────────────
    preview = out_path.replace(".kla", "_preview.png")
    canvas.save(preview)
    print(f"Preview: logo_bottom={logo_bottom} text_bottom={text_bottom} "
          f"qr=({qr_x},{qr_y}) {qr_canvas_w}x{qr_canvas_h} "
          f"email1_y={email1_y} press_y={press_y}")

    # ── Convert to Koala ──────────────────────────────────────────────────────
    koala_bytes = to_koala(canvas)
    with open(out_path, "wb") as f:
        f.write(koala_bytes)
    print(f"Koala saved:  {out_path}  ({len(koala_bytes)} bytes)")


if __name__ == "__main__":
    script_dir = os.path.dirname(os.path.abspath(__file__))
    make_splash(
        os.path.join(script_dir, "Buienradar.svg.png"),
        os.path.join(script_dir, "splash.kla"),
    )
