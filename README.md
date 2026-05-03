# C64U Weather

A live weather display program for the **Commodore 64**, built on the **Ultimate II+/U64** cartridge's UCI Network Target. The C64 opens a raw TCP socket through the cartridge firmware, makes a plain HTTP/1.0 GET request to a local Python proxy server, and renders weather data, an interactive Netherlands temperature map, and an animated rain-radar slideshow — all in native C64 graphics.

![Splash screen](splash_preview.png)

---

## Features

- **Splash screen** — Buienradar-branded boot screen with logo, QR code linking to this repo, and credits
- **Current conditions** — live temperature, humidity, wind, precipitation, pressure, visibility
- **5-day forecast** — min/max temp, rain chance, sun hours, wind direction and Beaufort scale
- **Weather report** — full-text bulletin from Buienradar, paginated across screens
- **Temperature map** — Netherlands outline in VIC-II multicolour bitmap mode with hardware sprites showing city temperatures (Groningen, Amsterdam, Utrecht, Rotterdam, Maastricht)
- **Animated radar** — multi-frame rain-radar slideshow fetched from the proxy, shown with frame timestamps as sprites
- **Auto-cycle mode** — hands-free carousel through all screens
- **Server editor** — enter a custom hostname and port from the setup screen

---

## Architecture

```
Commodore 64  (weather.asm — 6502 assembly)
  │
  │  UCI Network Target ($03) — raw TCP socket
  │  Ultimate II+/U64 firmware handles all TCP/IP
  │
  ▼
Python proxy  (server.py — HTTP on configurable port, LAN only)
  │
  │  HTTPS (SSL terminated by Python)
  ▼
data.buienradar.nl  (~32 KB JSON)   +   api.buienradar.nl  (radar PNG frames)
  └─► distilled to plain ASCII / raw Koala frames for the C64
```

The proxy is required for two reasons:

1. **SSL** — the C64 cannot perform TLS; the proxy terminates it.
2. **Format translation** — Buienradar returns large JSON and PNG images. The proxy extracts relevant fields, word-wraps to 38 columns, and converts radar frames to C64 Koala (multicolour bitmap) format.

---

## Repository contents

| File | Purpose |
|------|---------|
| `weather.asm` | Main C64 6502 assembly source (KickAssembler syntax) |
| `weather.prg` | Compiled C64 executable (BASIC loader + machine code) |
| `server.py` | Python proxy server |
| `make_splash.py` | Generates `splash.kla` from `Buienradar.svg.png` + C64 chargen ROM |
| `Buienradar.svg.png` | Buienradar logo used by `make_splash.py` |
| `requirements.txt` | Python dependencies for the proxy server |
| `Dockerfile` | Docker image for running the proxy |
| `KickAss.jar` | KickAssembler v5.25 — assembles `.asm` → `.prg` |
| `V1/` | Original V1 source (reference only) |

> **Note:** `.kla` binary assets (`netherlands_map_blank.kla`, `splash.kla`) are generated locally and excluded from the repository via `.gitignore`. Run `make_splash.py` to regenerate `splash.kla`. The Netherlands map `.kla` was created from `netherlands_map.png` using the included conversion pipeline.

---

## Requirements

### C64 hardware
- Commodore 64 with **Ultimate II+** or **U64** cartridge
- Ultimate firmware **≥ 3.10** (for the Network Target, `$03`)

### Proxy server
- Python **3.10** or newer
- Dependencies: `pip install -r requirements.txt` (Pillow, requests, qrcode)

### Rebuilding the PRG
- Java runtime (for KickAssembler)
- C64 chargen ROM at the path configured in `make_splash.py` (only needed to regenerate the splash screen)

---

## Quick start

### 1. Run the proxy server

```bash
cd C64U_Weather
pip install -r requirements.txt
python3 server.py
```

Default: listens on **port 8064**. Override with `--port`:

```bash
python3 server.py --port 9000
```

Or run in Docker:

```bash
docker build -t c64weather .
docker run -p 8064:8064 c64weather
```

### 2. Load the PRG on the C64

Copy `weather.prg` to a USB stick, mount via the Ultimate menu, and `LOAD`/`RUN` it, or use the Ultimate's built-in file browser to run it directly.

### 3. Configure the server address

On the setup screen press **E** to edit the default server address and port. Enter the LAN IP of the machine running `server.py` followed by `:port`.

---

## User interface

### Splash screen

Shown at boot. Displays the Buienradar logo, credits, a scannable QR code for this GitHub repository, and the author's email. **Press Space** to continue.

### Setup screen

Shown after the splash while the program verifies connectivity.

| Line | Content |
|------|---------|
| UCI INTERFACE | `OK ($C9)` when the cartridge is detected |
| C64U IP | LAN IP of the cartridge as reported by firmware |
| SERVER | Hostname of the proxy server |
| PORT | Port of the proxy server |
| STATUS | `TESTING CONNECTION…` → `OK – SERVER READY` or `FAIL – NO RESPONSE` |
| SERVER SAYS | First line returned by the server's `/` endpoint |

### Key mappings

| Key | Action |
|-----|--------|
| `1` | Current weather conditions |
| `2` | 5-day weather forecast |
| `3` | Detailed weather report (paginated, Space to advance) |
| `4` | Temperature map (Netherlands with city sprites) |
| `5` | Animated rain radar |
| `6` | Auto-cycle all screens (toggle ON/OFF) |
| `E` | Edit the default server address |
| `←` (back-arrow) | Return to setup screen |
| `RUN/STOP` | Quit to BASIC |

---

## Proxy server API

All responses are plain ASCII, max 38 characters wide. Every successful response ends with `OK` on its own line.

| Endpoint | Description |
|----------|-------------|
| `GET /` | Help text |
| `GET /current` | Current conditions |
| `GET /forecast` | 5-day forecast |
| `GET /report` | Full weather report text |
| `GET /temps` | Five city temperatures as `CITY:XX\n` lines |
| `GET /radar` | Rain-radar frames as a sequence of raw Koala blocks |

### Example — `/current`

```
CURRENT CONDITIONS
--------------------------------------
STATION : MEETSTATION DE BILT
REGION  : UTRECHT
TIME    : 14:20
WEATHER : GEDEELTELIJK BEWOLKT
TEMP    : 16.0 C
FEELS   : 15.0 C
HUMID   : 55.0 %
WIND    : ZW
WIND BFT: 3 (GENTLE BREEZE)
GUSTS   : 7.2 M/S
PRECIP  : 0.0 MM
PRESSUR : 1018.4 HPA
VISIBIL : 35000.0 M
--------------------------------------
OK
```

### Example — `/temps`

```
GRONINGEN:14
AMSTERDAM:15
UTRECHT:16
ROTTERDAM:14
MAASTRICHT:16
OK
```

---

## Building from source

### Compile the PRG

```bash
cd C64U_Weather
java -jar KickAss.jar weather.asm
# Produces: weather.prg
```

### Regenerate the splash screen

`make_splash.py` reads `Buienradar.svg.png`, renders text using the real C64 chargen ROM, generates a QR code for the GitHub URL, and converts everything to Koala format:

```bash
pip install pillow qrcode
python3 make_splash.py
# Produces: splash.kla, splash_preview.png
```

Edit `CHARGEN_PATH` near the top of `make_splash.py` to point to your C64 chargen ROM (e.g. from a VICE installation).

---

## C64 program — technical reference

### Memory map

```
$0801–$0808   8 B     BASIC upstart (SYS 2062)
$080E–$1E94   ~6 KB   Machine code (main + subroutines + data tables)
$1E95–$3DD4   8000 B  koala_data bitmap (Netherlands map, embedded)
$3DD5–$41BC   1000 B  koala_data screen RAM
$41BD–$456B   1000 B  koala_data colour RAM
$456C         1 B     koala_data background colour
$456D–$6C7D   10001 B splash_data (Koala splash screen, embedded)

── VIC bank 1 ($4000–$7FFF, active during bitmap/map/radar/splash) ──
$4000–$43E7   1000 B  Screen RAM for multicolour bitmap mode
$43F8–$43FD   6 B     Sprite pointers (sprites 0–5, values $70–$75)
$5C00–$5D7F   384 B   Sprite data (6 × 64 B temperature sprites)
$6000–$7F3F   8000 B  Bitmap data (multicolour 160×200)

── VIC bank 0 ($0000–$3FFF, active during text mode) ──
$0400–$07FF   1000 B  Text-mode screen RAM
$1000–$17FF          Character ROM shadow (VIC sees chargen here)

── RAM buffers ($C000–$CFD1) ──
$C000–$C3FF   1024 B  RXBUF  (HTTP receive buffer)
$C400–$C7FF   1024 B  STBUF  (HTTP request assembly / scratch)
$C800–$C801   2 B     (margin)
$C802–$CBE9   1000 B  MAP_SRAM_BUF (safe copy of Koala screen RAM)
$CBEA–$CFD1   1000 B  MAP_CRAM_BUF (safe copy of Koala colour RAM)
```

### Zero-page variables

| Label | Address | Purpose |
|-------|---------|---------|
| `ZP_COL` | `$61` | Current display column (0–39) |
| `ZP_ROW` | `$62` | Current display row (0–24) |
| `ZP_DCOL` | `$63` | Current text colour |
| `ZP_RXPTR` | `$64` | Receive buffer pointer low |
| `ZP_RXHI` | `$65` | Receive buffer pointer high |
| `ZP_TMP` | `$66` | Scratch pointer low |
| `ZP_TMPH` | `$67` | Scratch pointer high |
| `ZP_DECB` | `$68` | Decimal conversion scratch |
| `IP0–IP3` | `$69–$6C` | Device IP address (from `get_ip`) |
| `ZP_SOCK` | `$6D` | Active TCP socket handle |
| `ZP_LFCNT` | `$6E` | Consecutive LF counter (header stripping) |
| `ZP_PHASE` | `$6F` | `do_get_binary` receive phase |
| `ZP_CNTLO/HI` | `$70–$71` | `do_get_binary` remaining byte count |
| `ZP_CHAR0/1` | `$72–$73` | Temperature sprite digit indices |
| `ZP_PGFULL` | `$74` | Page-full flag (set by `next_row` on overflow) |
| `ZP_PTR/PTRH` | `$FB–$FC` | URL path / string pointer |

### UCI register map

Registers live in the cartridge I/O area at `$DF1C–$DF1F`:

| Label | Address | Dir | Purpose |
|-------|---------|-----|---------|
| `UCI_STAT` / `UCI_CTRL` | `$DF1C` | R/W | Status flags / control commands |
| `UCI_ID` / `UCI_CMD` | `$DF1D` | R/W | Cartridge ID (`$C9`) / command bytes |
| `UCI_DATA` | `$DF1E` | R | Response data FIFO |
| `UCI_SDATA` | `$DF1F` | R | Status string FIFO |

**Control bits (write to `UCI_CTRL`):**

| Constant | Value | Meaning |
|----------|-------|---------|
| `PUSH_CMD` | `$01` | Dispatch assembled command to firmware |
| `DATA_ACC` | `$02` | Acknowledge / release data FIFOs |

**Status bits (read from `UCI_STAT`):**

| Mask | Constant | Meaning |
|------|----------|---------|
| `$30` | `STATE_MASK` | Isolate state field |
| `$00` | `STATE_IDLE` | Ready for new command |
| `$10` | `STATE_BUSY` | Still processing |
| `$40` | `STAT_AV` | Status FIFO has data |
| `$80` | `DATA_AV` | Data FIFO has data |

### UCI Network Target commands

All networking uses **target `$03`**:

| Constant | Opcode | Command bytes | Response |
|----------|--------|---------------|----------|
| `NET_IPADDR` | `$05` | `$03 $05 <iface>` | 12 B: IP + netmask + gateway |
| `NET_TCPCON` | `$07` | `$03 $07 <portlo> <porthi> <host\0>` | 1-byte socket + status string |
| `NET_CLOSE` | `$09` | `$03 $09 <socket>` | Status string |
| `NET_READ` | `$10` | `$03 $10 <socket> <lenlo> <lenhi>` | 2-byte count + data |
| `NET_WRITE` | `$11` | `$03 $11 <socket> <data…\0>` | Status string |

`NET_READ` returns `$FF $FF` (65535) when no data is available yet; `$00 $00` signals connection closed.

### Key routines

#### Startup

| Routine | Description |
|---------|-------------|
| `presave_map_bufs` | Saves `koala_data+8000` → `MAP_SRAM_BUF` and `koala_data+9000` → `MAP_CRAM_BUF`. **Must** run before `show_splash` because the splash bitmap write to `$4000–$5F3F` would otherwise destroy the Koala screen/colour RAM stored at `$3DD5–$456B`. |
| `show_splash` | Copies `splash_data` to VIC bank 1, switches to multicolour bitmap mode, waits for Space, then calls `restore_char_mode`. |
| `copy_koala_to_ram` | Applies the pre-saved map buffers to `$4000` (screen RAM) and `$D800` (colour RAM), then copies the Koala bitmap from `koala_data` to `$6000`. Saves `map_bgcolor`. |
| `startup_diag` | Verifies UCI, reads device IP, shows server details, tests connection to `/`. On success returns immediately; on failure waits for a keypress. |

#### Screen output

| Routine | Description |
|---------|-------------|
| `cls` | Clears all 1000 screen + 1000 colour RAM cells. |
| `cls_data` | Clears rows 2–24 only (preserves title/menu bars). |
| `put_char` | Writes screen code A at (`ZP_ROW`, `ZP_COL`) with colour `ZP_DCOL`. Auto-advances column; wraps via `next_row`. |
| `pstr` | Prints a null-terminated ASCII string through `a2s` + `put_char`. |
| `pstr_rev` | Like `pstr` but each screen code is ORed with `$80` (reverse video). |
| `show_rx` | Walks `RXBUF`, printing each character; CR skipped, LF → `next_row`. |
| `show_rx_paged` | Like `show_rx` but pauses every 23 rows for Space to advance. |
| `a2s` | Converts ASCII to C64 screen code: `$40–$5F` → subtract `$40`; `$61–$7A` → subtract `$60`; `$00–$3F` → unchanged; others → `?`. |
| `restore_char_mode` | Clears bitmap mode, clears multicolour, switches VIC back to bank 0, restores `$D018 = $16`. |

#### Networking

| Routine | Description |
|---------|-------------|
| `do_get` | Complete HTTP/1.0 GET cycle: open TCP socket, send request, receive body into `RXBUF`, strip headers, close socket. Carry set on error. |
| `do_get_binary` | Like `do_get` but receives a fixed-length binary payload (e.g. a Koala frame) directly into a specified RAM buffer rather than `RXBUF`. |
| `get_ip` | Issues `NET_IPADDR`; stores first four response bytes into `IP0–IP3`. |
| `strip_headers` | Scans `RXBUF` for `\n\n`; copies body to start of `RXBUF` and null-terminates. |

#### Page display

| Routine | Description |
|---------|-------------|
| `page_current` | `do_get("/current")` → `show_rx` in light green |
| `page_forecast` | `do_get("/forecast")` → `show_rx` in light blue |
| `page_report` | `do_get("/report")` → `show_rx_paged` in white |
| `page_map` | Restores Koala bitmap/screen/colour RAM, switches to multicolour bitmap mode, fetches `/temps`, parses five temperatures, renders sprite overlays for each city. |
| `page_radar` | Fetches successive Koala frames from `/radar`, copies each to `$6000`, and displays it with a frame-timestamp sprite. Loops until a key is pressed. |

#### Temperature map sprites

Each temperature label is a single-colour 24×21 pixel hardware sprite built at runtime by `render_temp_sprite`:

- Digits are read from a built-in 5×7 pixel font table
- A negative-sign prefix is rendered for sub-zero values
- Sprite data is written to `$5C00–$5D7F` (VIC bank 1); sprite pointers at `$43F8–$43FD`
- Five cities are mapped to fixed screen positions and sprite slots 0–4

---

## Implementation notes

### VIC bank management

The program uses two VIC banks:

- **Bank 0** (`$0000–$3FFF`, `$DD00` bits `= $03`): text mode. Screen RAM at `$0400`, character ROM shadow at `$1000`.
- **Bank 1** (`$4000–$7FFF`, `$DD00` bits `= $02`): bitmap/map/radar/splash. Bitmap at `$6000` (`$D018` offset `$2000`), screen RAM at `$4000` (`$D018` offset `$0000`). Banks 0 and 2 have a chargen ROM shadow at offset `$1000`; bank 1 does not, which is why it is used for bitmap mode.

`restore_char_mode` is always safe to call even from text mode (all operations are idempotent).

### Splash screen memory overlap

`splash_data` is embedded in the PRG at `$456D–$6C7D`. The splash bitmap write destination is `$4000–$5F3F`, which overlaps the Koala map's screen and colour RAM source at `$3DD5–$456B`. `presave_map_bufs` saves both 1 KB blocks to safe buffers at `$C802` and `$CBEA` before the splash runs, so the buffers survive intact for `copy_koala_to_ram`.

Similarly, the Koala bitmap copy to `$6000–$7F3F` would overwrite the screen/colour RAM portion of `splash_data` (`$64AD–$6C7D`) if run before the splash. The correct startup order is therefore:

```
presave_map_bufs   → save map screen/colour RAM to safe buffers
show_splash        → write splash to $4000–$7FFF, wait for Space
copy_koala_to_ram  → apply saved buffers to $4000/$D800, copy bitmap to $6000
```

### HTTP/1.0 with `Connection: close`

Using HTTP/1.0 guarantees the server closes the socket after the response, giving the C64 a reliable end-of-data signal (a `NET_READ` count of `$0000`) without having to parse `Content-Length` or chunked transfer encoding.

### Splash screen generation

`make_splash.py` renders text using actual C64 chargen ROM glyphs (loaded from a VICE installation) at `scale=2` so each character bit occupies exactly 2 canvas pixels horizontally. The canvas is then downsampled with `Image.NEAREST` (not LANCZOS) so binary pixels are preserved without antialiasing blur. The GitHub URL is rendered as a QR code at `scale=3` (3 canvas pixels per QR module).

### `a2s` — ASCII to C64 screen code mapping

The C64 lowercase/uppercase charset used by this program maps screen codes as:

| Screen code | Glyph |
|------------|-------|
| `$00` | `@` |
| `$01–$1A` | `A–Z` |
| `$1B–$1F` | `[ \ ] ↑ ←` |
| `$20–$3F` | space and punctuation (same as ASCII) |
| `$41–$5A` | uppercase A–Z (alternate set) |

The back-arrow key (PETSCII `$5F`) maps to screen code `$1F` (not `$5F`). The `str_help_back` string uses `.byte $1F` directly to bypass `a2s` translation.

---

## Credits

Code by **Martijn Bosschaart** (martijn@runstoprestore.nl) — and Claude.  
Weather data by [Buienradar.nl](https://www.buienradar.nl).  
QR code links to: [https://github.com/Martijn-DevRev/c64weather](https://github.com/Martijn-DevRev/c64weather)

Licensed under GPL-3.0.
