#!/usr/bin/env python3
"""
C64U_Weather intermediary server.

Fetches the Buienradar JSON feed over HTTPS and re-serves it over plain HTTP
so the Commodore 64 (which cannot do SSL) can retrieve weather data.

Endpoints
---------
GET /              - API help text
GET /current       - Current conditions at the selected station (default: De Bilt)
GET /forecast      - 5-day forecast (compact line-delimited text)
GET /report        - Short-term and long-term forecast texts
GET /temps         - City temperatures for map overlay
GET /radar         - Next radar animation frame as Koala bitmap (cycles through frames)

All text responses are plain ASCII, one piece of data per line.
/temps and /radar return raw binary Koala data:
  8000 B bitmap + 1000 B screen colours + 1000 B colour RAM + 1 B background = 10001 B

Usage
-----
    python3 server.py [--port 8888] [--station 6260]
"""

import argparse
import collections
import http.server
import io
import json
import logging
import sys
import time
import urllib.request
from datetime import datetime

BUIENRADAR_URL = "https://data.buienradar.nl/2.0/feed/json"
DEFAULT_PORT = 8888
DEFAULT_STATION_ID = 6260  # De Bilt (central NL reference station)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-7s  %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("c64weather")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_ACCENT_MAP = str.maketrans({
    'à':'a','á':'a','â':'a','ã':'a','ä':'a','å':'a','æ':'ae',
    'ç':'c',
    'è':'e','é':'e','ê':'e','ë':'e',
    'ì':'i','í':'i','î':'i','ï':'i',
    'ð':'d','ñ':'n',
    'ò':'o','ó':'o','ô':'o','õ':'o','ö':'o',
    'ù':'u','ú':'u','û':'u','ü':'u',
    'ý':'y','þ':'th','ÿ':'y',
    'À':'A','Á':'A','Â':'A','Ã':'A','Ä':'A','Å':'A','Æ':'AE',
    'Ç':'C',
    'È':'E','É':'E','Ê':'E','Ë':'E',
    'Ì':'I','Í':'I','Î':'I','Ï':'I',
    'Ð':'D','Ñ':'N',
    'Ò':'O','Ó':'O','Ô':'O','Õ':'O','Ö':'O',
    'Ù':'U','Ú':'U','Û':'U','Ü':'U',
    'Ý':'Y','Þ':'TH',
    'ß':'ss',
})


def to_ascii(text: str) -> str:
    """Strip accents and drop any remaining non-ASCII characters."""
    text = text.translate(_ACCENT_MAP)
    return text.encode("ascii", errors="replace").decode("ascii")


def fetch_buienradar() -> dict:
    req = urllib.request.Request(
        BUIENRADAR_URL,
        headers={"User-Agent": "C64U_Weather/1.0"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def find_station(measurements: list, station_id: int) -> dict | None:
    for s in measurements:
        if s.get("stationid") == station_id:
            return s
    return None


def format_date(iso: str) -> str:
    """2026-05-01T00:00:00  ->  01-05-2026"""
    try:
        dt = datetime.fromisoformat(iso)
        return dt.strftime("%d-%m-%Y")
    except ValueError:
        return iso[:10]


def format_time(iso: str) -> str:
    """2026-05-01T00:40:00  ->  00:40"""
    try:
        dt = datetime.fromisoformat(iso)
        return dt.strftime("%H:%M")
    except ValueError:
        return iso[11:16]


def wind_bft_label(bft: int) -> str:
    labels = {
        0: "Calm", 1: "Light air", 2: "Light breeze", 3: "Gentle breeze",
        4: "Moderate breeze", 5: "Fresh breeze", 6: "Strong breeze",
        7: "Near gale", 8: "Gale", 9: "Severe gale",
        10: "Storm", 11: "Violent storm", 12: "Hurricane",
    }
    return labels.get(bft, f"Bft {bft}")


# ---------------------------------------------------------------------------
# Response builders
# ---------------------------------------------------------------------------

def build_current(data: dict, station_id: int) -> str:
    measurements = data.get("actual", {}).get("stationmeasurements", [])
    station = find_station(measurements, station_id)

    if station is None:
        return f"ERROR: STATION {station_id} NOT FOUND\n"

    lines = [
        "CURRENT CONDITIONS",
        "-" * 38,
        f"STATION : {to_ascii(station.get('stationname', '?'))}",
        f"REGION  : {to_ascii(station.get('regio', '?'))}",
        f"TIME    : {format_time(station.get('timestamp', ''))}",
        f"WEATHER : {to_ascii(station.get('weatherdescription', '?'))}",
    ]

    def add(label: str, key: str, unit: str = "") -> None:
        val = station.get(key)
        if val is not None:
            lines.append(f"{label:<8}: {val}{unit}")

    add("TEMP   ", "temperature", " C")
    add("FEELS  ", "feeltemperature", " C")
    add("HUMID  ", "humidity", " %")
    add("WIND   ", "winddirection")
    bft = station.get("windspeedBft")
    if bft is not None:
        lines.append(f"WIND BFT: {bft} ({wind_bft_label(bft)})")
    add("GUSTS  ", "windgusts", " m/s")
    add("PRECIP ", "precipitation", " mm")
    add("PRESSUR", "airpressure", " hPa")
    add("VISIBIL", "visibility", " m")

    lines.append("-" * 38)
    return "\n".join(lines) + "\n"


def build_forecast(data: dict) -> str:
    days = data.get("forecast", {}).get("fivedayforecast", [])

    if not days:
        return "ERROR: NO FORECAST DATA\n"

    lines = [
        "5-DAY FORECAST",
        "-" * 38,
        f"{'DATE':<10}{'MIN':>5}  {'MAX':>5}  {'RAIN':>4}  {'SUN':>4}  {'WIND'}",
    ]

    for d in days:
        date_str  = format_date(d.get("day", ""))
        min_t     = str(d.get("mintemperature", "?"))
        max_t     = str(d.get("maxtemperature", "?"))
        rain_str  = f"{d.get('rainChance', '?')}%"
        sun_str   = f"{d.get('sunChance',  '?')}%"
        wind_bft  = d.get("wind", "?")
        wind_dir  = d.get("windDirection", "?").upper()
        lines.append(
            f"{date_str:<10}{min_t:>5}  {max_t:>5}  {rain_str:>4}  {sun_str:>4}"
            f"  {wind_dir}{wind_bft}"
        )

    lines.append("")
    for d in days:
        date_str = format_date(d.get("day", ""))
        desc     = to_ascii(d.get("weatherdescription", ""))
        lines.append(f"{date_str}: {desc}")

    lines.append("-" * 38)
    return "\n".join(lines) + "\n"


def build_report(data: dict) -> str:
    forecast = data.get("forecast", {})
    report   = forecast.get("weatherreport", {})
    short    = forecast.get("shortterm", {})
    long_    = forecast.get("longterm", {})

    def wrap(text: str, width: int = 38) -> list[str]:
        """Word-wrap plain-ASCII text to `width` columns."""
        text  = to_ascii(text).strip()
        words = text.split()
        out, line = [], ""
        for w in words:
            if len(line) + len(w) + (1 if line else 0) <= width:
                line = (line + " " + w).lstrip()
            else:
                if line:
                    out.append(line)
                line = w
        if line:
            out.append(line)
        return out

    lines = [
        "WEATHER REPORT",
        "-" * 38,
        f"TITLE: {to_ascii(report.get('title', '')).strip()}",
        f"BY   : {to_ascii(report.get('author', ''))}",
        "",
        "SUMMARY:",
        *wrap(report.get("summary", "")),
        "",
        "SHORT TERM FORECAST:",
        f"({format_date(short.get('startdate',''))} - {format_date(short.get('enddate',''))})",
        *wrap(short.get("forecast", "")),
        "",
        "LONG TERM FORECAST:",
        f"({format_date(long_.get('startdate',''))} - {format_date(long_.get('enddate',''))})",
        *wrap(long_.get("forecast", "")),
        "-" * 38,
    ]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Koala bitmap conversion helpers (used by /radar)
# ---------------------------------------------------------------------------

_C64_PALETTE = [
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


def _nearest_c64(rgb: tuple) -> int:
    best_idx, best_dist = 0, float('inf')
    for i, c in enumerate(_C64_PALETTE):
        d = sum((a - b) ** 2 for a, b in zip(rgb, c))
        if d < best_dist:
            best_idx, best_dist = i, d
    return best_idx


def _boost_sat(img, factor: float = 1.3):
    """Boost saturation so dark green land snaps to C64 green instead of grey."""
    from PIL import Image
    pixels = []
    for r, g, b in img.getdata():
        lum = 0.299 * r + 0.587 * g + 0.114 * b
        nr = max(0, min(255, int(lum + factor * (r - lum))))
        ng = max(0, min(255, int(lum + factor * (g - lum))))
        nb = max(0, min(255, int(lum + factor * (b - lum))))
        pixels.append((nr, ng, nb))
    out = Image.new('RGB', img.size)
    out.putdata(pixels)
    return out


def _letterbox(img, target_w: int = 320, target_h: int = 200):
    """Resize img to fit within target_w×target_h, paste on bg-colour canvas."""
    from PIL import Image
    corners = [img.getpixel((0, 0)), img.getpixel((img.width - 1, 0)),
               img.getpixel((0, img.height - 1)), img.getpixel((img.width - 1, img.height - 1))]
    bg_rgb = collections.Counter(corners).most_common(1)[0][0]
    canvas = Image.new('RGB', (target_w, target_h), bg_rgb)
    thumb = img.copy()
    thumb.thumbnail((target_w, target_h), Image.LANCZOS)
    canvas.paste(thumb, ((target_w - thumb.width) // 2, (target_h - thumb.height) // 2))
    return canvas, bg_rgb


# Allowed C64 colours for the rain/cloud palette search.
# Land (green=5, lt-green=13), sea (blue=6), borders (yellow=7) are handled by
# explicit rules before this list is ever consulted.
_RADAR_PALETTE_IDX = [2, 5, 6, 8, 12, 14, 15]   # red, green, blue, orange, grey, lt-blue, lt-grey
_RADAR_PALETTE_RGB = [_C64_PALETTE[i] for i in _RADAR_PALETTE_IDX]

# Rain-intensity priority for the c3 slot in rain blocks (higher = gets own slot first)
_RAIN_INTENSITY = {2: 5, 8: 4, 14: 3, 12: 2, 15: 1}  # red > orange > lt-blue > grey > lt-grey


def _nearest_radar_c64(rgb: tuple) -> int:
    """Map an RGB colour to the correct C64 radar colour.

    Landmark / background colours are forced FIRST (no nearest-search needed):
      1. Lt-green (13) – bright NL-type land: G > 200, green-dominant, B < 130.
      2. Green   (5)  – all other land:       G dominant over R and B, B < 130.
         The B < 130 guard prevents cloud halos (which have high B) being
         misclassified as land.
      3. Yellow  (7)  – country border lines: R>160, G>160, B<60.
      4. Lt-grey (15) – other warm map overlay (OSM roads): R>150, G>120, B<100.
         These must NOT reach rain detection (orange/red slots).

    Rain / cloud colours are then found by nearest-neighbour search:
      5. Red (2) is restricted to pure-red hues (G < 40) so that dark-orange
         moderate rain doesn't appear as intense red.
    """
    r, g, b = rgb
    # 1. All land → green (single shade, avoids checkerboard between blocks)
    if g > r + 20 and g > b + 20 and g > 80 and b < 130:
        return 5   # green
    # 3. Country border lines: balanced high R+G, very low B (true yellow)
    #    Require |R-G| < 50 to avoid orange roads (which have R >> G) firing here.
    if r > 160 and g > 160 and b < 60 and abs(r - g) < 50:
        return 7   # yellow
    # 4. Other warm map overlay (OSM roads, etc.) → lt-grey, no rain trigger
    if r > 150 and g > 120 and b < 100:
        return 15  # lt-grey
    # 5. Rain / cloud: nearest search, red only for pure hues
    candidates = [i for i in _RADAR_PALETTE_IDX if i != 2] if g >= 40 else _RADAR_PALETTE_IDX
    best_idx, best_dist = candidates[0], float('inf')
    for i in candidates:
        c = _C64_PALETTE[i]
        d = sum((a - b_) ** 2 for a, b_ in zip(rgb, c))
        if d < best_dist:
            best_dist, best_idx = d, i
    return best_idx



def _png_to_koala_bytes(canvas, fixed_bg=None, fixed_c1=None, fixed_c2=None, fixed_c3=None) -> bytes:
    """Convert a 320×200 PIL RGB image to 10001 raw Koala bytes (no load header).

    When fixed_bg/c1/c2/c3 are provided (radar mode):
    - Background blocks (no rain colours): use all four fixed slots → perfectly stable.
    - Rain blocks (any pixel in _RAIN_COLORS): c1 stays fixed (sea), but c2 AND c3 are
      chosen dynamically from the most frequent variable colours in the block.
      This gives two independent rain-intensity slots per block instead of one.
    """
    from PIL import Image
    c64_rgb_map = {i: _C64_PALETTE[i] for i in range(16)}

    # Use restricted radar palette when fixed_bg is set, full palette otherwise.
    nearest_fn = _nearest_radar_c64 if fixed_bg is not None else _nearest_c64
    quantized = Image.new('RGB', canvas.size)
    quantized.putdata([_C64_PALETTE[nearest_fn(p)] for p in canvas.getdata()])
    mc = quantized.resize((160, 200), Image.NEAREST)
    rgb_to_idx = {v: k for k, v in c64_rgb_map.items()}
    indices = [rgb_to_idx.get(p, nearest_fn(p)) for p in mc.getdata()]

    if fixed_bg is None:
        corners = [canvas.getpixel((0, 0)), canvas.getpixel((canvas.width - 1, 0)),
                   canvas.getpixel((0, canvas.height - 1)), canvas.getpixel((canvas.width - 1, canvas.height - 1))]
        fixed_bg = _nearest_c64(collections.Counter(corners).most_common(1)[0][0])

    bg = fixed_bg
    bitmap, screen_ram, color_ram = bytearray(8000), bytearray(1000), bytearray(1000)
    c64_rgb = _C64_PALETTE

    for ry in range(0, 200, 8):
        for rx in range(0, 160, 4):
            block = [indices[(ry + y) * 160 + (rx + x)]
                     if ry + y < 200 and rx + x < 160 else bg
                     for y in range(8) for x in range(4)]

            freq = collections.Counter(block)

            if fixed_c1 is not None:
                # Radar mode.
                # Rain block  = contains orange(8) or red(2) → dynamic c2/c3.
                # Background block → conditional palette based on block content:
                #   yellow(7) present  → {bg, blue, yellow, lt-grey}   (border block)
                #   lt-green(13)       → {bg, blue, lt-green, lt-grey}  (NL land block)
                #   otherwise          → {bg, blue, lt-grey, grey}      (cloud/sea block)
                c1 = fixed_c1  # always blue (sea / cloud-body anchor)
                has_rain = any(c in (2, 8) for c in block)
                if has_rain:
                    variable = [c for c, _ in freq.most_common() if c not in (bg, c1)]
                    c3 = max(set(variable), key=lambda c: _RAIN_INTENSITY.get(c, 0))
                    c2_cands = [c for c in variable if c != c3]
                    c2 = c2_cands[0] if c2_cands else c3
                elif 7 in block:   # country border (yellow)
                    c2, c3 = 7, 15  # yellow, lt-grey
                else:
                    c2 = fixed_c2   # lt-grey  (cloud halo / default)
                    c3 = fixed_c3   # grey     (cloud body / default)
            else:
                top = [c for c, _ in freq.most_common() if c != bg]
                c1 = top[0] if len(top) > 0 else bg
                c2 = top[1] if len(top) > 1 else c1
                c3 = top[2] if len(top) > 2 else c2

            bi = (ry // 8) * 40 + (rx // 4)
            screen_ram[bi] = (c1 << 4) | c2
            color_ram[bi] = c3 & 0x0F

            avail = [bg, c1, c2, c3]
            avail_rgb = [c64_rgb[i] for i in avail]

            for y in range(8):
                byte = 0
                for x in range(4):
                    col = block[y * 4 + x]
                    if col == c1:
                        bits = 1
                    elif col == c2:
                        bits = 2
                    elif col == c3:
                        bits = 3
                    elif col == bg:
                        bits = 0
                    else:
                        rgb = c64_rgb[col]
                        bits = min(range(4), key=lambda i: sum((a - b) ** 2 for a, b in zip(rgb, avail_rgb[i])))
                    byte = (byte << 2) | bits
                bitmap[bi * 8 + y] = byte

    return bytes(bitmap) + bytes(screen_ram) + bytes(color_ram) + bytes([bg])


# ---------------------------------------------------------------------------
# Radar frame cache
# ---------------------------------------------------------------------------

RADAR_URL   = 'https://api.buienradar.nl/image/1.0/RadarMapNL?w=500&h=512'
RADAR_TTL   = 15 * 60   # re-fetch GIF every 15 minutes


class _RadarCache:
    def __init__(self):
        self._frames: list[bytes] = []
        self._idx: int = 0
        self._expires: float = 0.0

    def _load(self) -> None:
        import re as _re
        from PIL import Image
        try:
            req = urllib.request.Request(RADAR_URL, headers={'User-Agent': 'C64U_Weather/1.0'})
            with urllib.request.urlopen(req, timeout=15) as r:
                gif_data = r.read()
                final_url = r.url  # after redirects
            gif = Image.open(io.BytesIO(gif_data))
            # Crop to NL region — 510×319 = 1.6:1 aspect, matches C64 320×200 perfectly
            NL_CROP = (20, 78, 530, 397)

            # ── Pass 1: collect all canvases and their C64 index arrays ──────────
            canvases = []
            all_indices = []
            rgb_to_idx = {v: k for k, v in enumerate(_C64_PALETTE)}
            try:
                while True:
                    frame_rgb = gif.convert('RGB').crop(NL_CROP)
                    frame_rgb = _boost_sat(frame_rgb, factor=1.3)
                    snapped = Image.new('RGB', frame_rgb.size)
                    # Restrict to radar-allowed colours: no brown/yellow/purple ever
                    snapped.putdata([_C64_PALETTE[_nearest_radar_c64(p)] for p in frame_rgb.getdata()])
                    canvas = snapped.resize((320, 200), Image.NEAREST)
                    canvases.append(canvas)
                    idxs = [rgb_to_idx.get(p, _nearest_radar_c64(p)) for p in canvas.getdata()]
                    all_indices.extend(idxs)
                    gif.seek(gif.tell() + 1)
            except EOFError:
                pass

            # ── Fixed global palette (hard-coded for stability) ───────────────────
            # bg   = green (5)   – land background, global for entire screen.
            # c1   = blue  (6)   – sea / rivers / dark cloud body (fixed in rain blocks).
            # c2   = lt-grey(15) – cloud halos / fallback for non-special bg blocks.
            # c3   = grey  (12)  – intermediate cloud / fallback.
            # Border blocks  override c2→yellow(7),   c3→lt-grey(15).
            # Rain blocks use c1 fixed + dynamic c2/c3 for intensity slots.
            fixed_bg, fixed_c1, fixed_c2, fixed_c3 = 5, 6, 15, 12
            log.info("Radar palette: bg=%d(green) c1=%d(blue) c2=%d(lt-grey) c3=%d(grey)",
                     fixed_bg, fixed_c1, fixed_c2, fixed_c3)

            # ── Frame timestamps ──────────────────────────────────────────────────
            # Extract the actual run time from the CDN redirect URL which contains
            # "run<YYYYMMDDhhmm>" — this is the time of the LAST (most recent) frame.
            # Fall back to rounding now() if the pattern is not found.
            import datetime as _dt
            _m = _re.search(r'run(\d{12})', final_url)
            if _m:
                _last = _dt.datetime.strptime(_m.group(1), '%Y%m%d%H%M')
                # CDN timestamp is UTC; convert to local time using the actual
                # current offset (accounts for DST correctly)
                _utc_offset = _dt.datetime.now() - _dt.datetime.utcnow()
                _last = _last + _utc_offset
                # Snap to the nearest 5-minute boundary (frames are always on :00/:05/:10 etc.)
                _last = _last.replace(minute=(_last.minute // 5) * 5, second=0, microsecond=0)
                log.info("Radar run time from CDN URL: %s (local)", _last.strftime('%H:%M'))
            else:
                _now = _dt.datetime.now()
                _last = _now.replace(minute=(_now.minute // 5) * 5,
                                     second=0, microsecond=0)
                log.info("Radar run time estimated from now: %s", _last.strftime('%H:%M'))
            n_frames = len(canvases)
            timestamps = [
                _last - _dt.timedelta(minutes=5 * (n_frames - 1 - i))
                for i in range(n_frames)
            ]

            # ── Pass 2: convert each canvas, append 2-byte timestamp (HH, MM) ──────
            # The C64 reads these 2 extra bytes and renders them as hardware sprites,
            # giving a clean white timestamp overlay independent of the bitmap palette.
            frames = []
            for canvas, ts in zip(canvases, timestamps):
                koala = _png_to_koala_bytes(canvas, fixed_bg, fixed_c1, fixed_c2, fixed_c3)
                frames.append(koala + bytes([ts.hour, ts.minute]))

            self._frames = frames
            self._idx = 0
            self._expires = time.time() + RADAR_TTL
            log.info("Radar cache loaded: %d frames", len(frames))
        except Exception as exc:
            log.error("Radar load failed: %s", exc)

    def next_frame(self) -> bytes:
        if time.time() > self._expires:
            self._load()
        if not self._frames:
            return bytes(10003)
        frame = self._frames[self._idx]
        self._idx = (self._idx + 1) % len(self._frames)
        return frame


_radar = _RadarCache()


# Cities served by /temps — must match _MAP_CITIES order in weather.asm
# (name, buienradar_station_id)
_TEMPS_CITIES = [
    ("Utrecht",    6260),
    ("Maastricht", 6380),
    ("Den Helder", 6235),
    ("Groningen",  6280),
    ("Vlissingen", 6310),
    ("Twente",     6290),
]

# Map Dutch weatherdescription → icon index (0–7).
# Indices match the 8 icon sprites in weather.asm:
#   0=sun  1=partlycloudy  2=cloudy  3=fog  4=rainy  5=snowy  6=thunder  7=moon
_DESC_TO_ICON: dict[str, int] = {
    # clear
    "Vrijwel onbewolkt (zonnig/helder)":                              0,
    # partly cloudy
    "Mix van opklaringen en middelbare of lage bewolking":            1,
    "Mix van opklaringen en hoge bewolking":                          1,
    "Half bewolkt":                                                   1,
    # cloudy
    "Zwaar bewolkt":                                                  2,
    # fog
    "Afwisselend bewolkt met lokaal mist(banken)":                    3,
    "Opklaring en lokaal nevel of mist":                              3,
    # rainy
    "Afwisselend bewolkt met (mogelijk) wat lichte regen":            4,
    "Zwaar bewolkt en regen":                                         4,
    "Zwaar bewolkt met regen en winterse neerslag":                   4,
    "Zwaar bewolkt met wat lichte regen":                             4,
    # snowy
    "Afwisselend bewolkt met lichte sneeuwval":                       5,
    "Zwaar bewolkt met lichte sneeuwval":                             5,
    "Zware sneeuwval":                                                5,
    # thunder
    "Opklaringen en kans op enkele pittige (onweers)buien":           6,
    "Bewolkt en kans op enkele pittige (onweers)buien":               6,
}


def _is_night() -> bool:
    """Return True if it's currently night (22:00–06:00 local time)."""
    import time as _t
    h = _t.localtime().tm_hour
    return h >= 22 or h < 6


def _desc_to_icon(desc: str, night: bool = False) -> int:
    """Map a Dutch weatherdescription string to an icon index (0–7).

    Falls back to cloudy (2) for unknown descriptions.
    Clear sky at night returns 7 (moon) instead of 0 (sun).
    """
    idx = _DESC_TO_ICON.get(desc.strip(), 2)
    if idx == 0 and night:
        return 7
    return idx


def build_temps(data: dict) -> str:
    """Return temperatures then icon indices for each city, in _MAP_CITIES order.

    Format: 6 temperature lines (signed integers) followed by 6 icon-index
    lines (0–7).  The C64 reads the first 6 as temperatures and the next 6 as
    weather icon indices for the alternating sprite display.
    """
    measurements = data.get("actual", {}).get("stationmeasurements", [])
    temp_lines = []
    icon_lines = []
    night = _is_night()
    for name, station_id in _TEMPS_CITIES:
        station = find_station(measurements, station_id)
        temp = station.get("temperature") if station else None
        if temp is None:
            temp_lines.append("99")
        else:
            temp_lines.append(str(int(round(float(temp)))))
        desc = station.get("weatherdescription", "") if station else ""
        icon_lines.append(str(_desc_to_icon(desc, night)))
    return "\n".join(temp_lines + icon_lines) + "\n"


def build_help() -> str:
    lines = [
        "C64U WEATHER SERVER",
        "-" * 38,
        "ENDPOINTS:",
        " GET /current   - CURRENT CONDITIONS",
        " GET /forecast  - 5-DAY FORECAST",
        " GET /report    - WEATHER REPORT",
        " GET /temps     - CITY TEMPERATURES (MAP OVERLAY)",
        " GET /radar     - RADAR FRAME (KOALA BINARY, CYCLES)",
        "-" * 38,
    ]
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

class WeatherHandler(http.server.BaseHTTPRequestHandler):

    station_id: int = DEFAULT_STATION_ID

    def log_message(self, fmt, *args):  # silence default request log
        log.info("%-15s  %s", self.client_address[0], fmt % args)

    def send_text(self, body: str, status: int = 200) -> None:
        encoded = body.encode("ascii", errors="replace")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=ascii")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def send_binary(self, data: bytes, status: int = 200) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0].rstrip("/") or "/"

        if path == "/radar":
            self.send_binary(_radar.next_frame())
            return

        if path in ("/current", "/forecast", "/report", "/temps"):
            try:
                log.info("Fetching Buienradar…")
                data = fetch_buienradar()
                log.info("Buienradar fetch OK")
            except Exception as exc:
                log.error("Buienradar fetch failed: %s", exc)
                self.send_text(f"ERROR: FETCH FAILED: {exc}\n", 502)
                return

            if path == "/current":
                body = build_current(data, self.station_id)
                self.send_text(body)
            elif path == "/forecast":
                body = build_forecast(data)
                self.send_text(body)
            elif path == "/report":
                body = build_report(data)
                self.send_text(body)
            elif path == "/temps":
                body = build_temps(data)
                self.send_text(body)
            return

        elif path == "/":
            body = build_help()
        else:
            body = "ERROR: UNKNOWN ENDPOINT\n"
            self.send_text(body, 404)
            return

        self.send_text(body)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description="C64U Weather intermediary server")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT,
                        help=f"TCP port to listen on (default: {DEFAULT_PORT})")
    parser.add_argument("--station", type=int, default=DEFAULT_STATION_ID,
                        help=f"Buienradar station ID for /current (default: {DEFAULT_STATION_ID} = De Bilt)")
    args = parser.parse_args()

    WeatherHandler.station_id = args.station

    server = http.server.HTTPServer(("", args.port), WeatherHandler)
    log.info("C64U Weather server listening on http://0.0.0.0:%d", args.port)
    log.info("Station: %d  |  Buienradar source: %s", args.station, BUIENRADAR_URL)
    log.info("Press Ctrl-C to stop.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log.info("Shutting down.")
        server.server_close()
        sys.exit(0)


if __name__ == "__main__":
    main()
