// ─────────────────────────────────────────────────────────────────────────────
// C64U_Weather — Weather forecast display for Commodore 64
// Requires: Ultimate II+ or U64 with firmware >= 3.10 (Network target)
//
// Startup: shows device IP + connection test, then fetches weather.
// Keys:  1 = Current conditions
//        2 = 5-day forecast
//        3 = Weather report
//        STOP (RUN/STOP) = Quit to BASIC
// ─────────────────────────────────────────────────────────────────────────────
//
// ═══════════════════════════════════════════════════════════════════════════════
// MEMORY MAP
// ═══════════════════════════════════════════════════════════════════════════════
//
// ── C64 fixed / OS areas ─────────────────────────────────────────────────────
//   $0000–$00FF  Zero page   (our ZP vars at $61–$74, $FB–$FC)
//   $0100–$01FF  Stack
//   $0200–$02FF  OS work area (keyboard buffer at $0277, BUFCNT at $00C6)
//   $0400–$07FF  Text-mode screen RAM  (SCR = $0400, 1000 B)
//   $D800–$DBFF  Colour RAM  (CLR = $D800, 1000 B; always visible at this address)
//
// ── PRG load area  ($0801 … ~$4600) ─────────────────────────────────────────
//   $0801–$0802  BASIC upstart (SYS line)
//   $0803–~$1E94 Code + strings + runtime variables
//                  Includes: srv_host ($1AAE, 32 B), srv_port_str ($1ACD, 6 B)
//   $1E95–$3DD4  koala_data bitmap  (8000 B)
//   $3DD5–$41BC  koala_data screen RAM (1000 B)  ← overlaps VIC bank 1 after startup copy
//   $41BD–$456B  koala_data colour RAM (1000 B)  ← overlaps VIC bank 1 after startup copy
//   $456C        koala_data background colour (1 B)
//
//   NOTE: Because koala_data+8000 = $3DD5 and koala_data+9000 = $41BD both
//   overlap the VIC bank 1 screen RAM destination ($4000–$43E7), we MUST save
//   the screen and colour data to safe buffers BEFORE writing to $4000.
//   See copy_koala_to_ram for the order-of-operations fix.
//
// ── RAM buffers  ($C000–$CFD1) ───────────────────────────────────────────────
//   $C000–$C3FF  RXBUF        (1024 B receive buffer for HTTP body)
//   $C400–$C4FF  STBUF        (256 B  HTTP request assembly / status scratch)
//
//   Radar loop double-buffer — written by do_get_binary phases 2/3/4:
//   $C000–$C3E7  dgb_scr  buf  (1000 B Koala screen colours,  overlaps RXBUF)
//   $C400–$C7E7  dgb_cram buf  (1000 B Koala colour RAM,       overlaps STBUF)
//   $C800        dgb_bg   buf  (1 B    Koala background colour)
//   *** $C000–$C800 are clobbered on every radar frame fetch in loop mode ***
//   *** MAP_SRAM_BUF / MAP_CRAM_BUF MUST start at $C801 or higher ***
//
//   $C802–$CBE9  MAP_SRAM_BUF (1000 B safe copy of Koala screen RAM)
//   $CBEA–$CFD1  MAP_CRAM_BUF (1000 B safe copy of Koala colour RAM)
//   $CFD2–$CFFF  FREE (46 B margin before I/O area)
//   $D000 upward I/O (VIC, SID, CIA) — do not use as data buffers
//
// ── VIC bank 1  ($4000–$7FFF, active during bitmap/map display) ──────────────
//   $4000–$43E7  Screen RAM for multicolour bitmap mode (1000 B)
//   $43E8–$43F7  (gap — unused)
//   $43F8–$43FD  Sprite pointers (6 sprites: $70–$75 → sprite data at $5C00–$5D7F)
//   $4400–$463F  Icon sprite data: 9 × 64 B weather icon sprites (copied at runtime)
//                  Icon 0=$4400($10) sun,  1=$4440($11) partly, 2=$4480($12) cloudy
//                  Icon 3=$44C0($13) fog,  4=$4500($14) rain,   5=$4540($15) snow
//                  Icon 6=$4580($16) thunder, 7=$45C0($17) moon
//                  Icon 8=$4600($18) partly-night (moon + cloud)
//   $4640–$5BFF  (free in VIC bank 1)
//   $5C00–$5D7F  Sprite data: 6 × 64 B temperature sprites
//                  Spr 0=$5C00 (ptr=$70), 1=$5C40 ($71), 2=$5C80 ($72)
//                  Spr 3=$5CC0 ($73),     4=$5D00 ($74), 5=$5D40 ($75)
//   $5D80–$5FFF  (free in VIC bank 1)
//   $6000–$7F3F  Bitmap data (8000 B, multicolour 160×200)
//   $7F40–$7FFF  (free in VIC bank 1)
//
// ── VIC bank 0  ($0000–$3FFF, active during text mode) ───────────────────────
//   $0400–$07FF  Text-mode screen RAM (see above)
//   $1000–$17FF  Character ROM shadow (VIC sees char ROM here)
//
// ── I/O area ─────────────────────────────────────────────────────────────────
//   $D018        VIC-II memory control (screen/bitmap/char base)
//   $D020–$D021  Border / background colour
//   $DD00        CIA2 port A (VIC bank select: bits 0–1)
//   $DF1C–$DF1F  Ultimate II+ UCI registers
//
// ═══════════════════════════════════════════════════════════════════════════════

// UCI Registers
.const UCI_STAT  = $DF1C
.const UCI_CTRL  = $DF1C
.const UCI_ID    = $DF1D
.const UCI_CMD   = $DF1D
.const UCI_DATA  = $DF1E
.const UCI_SDATA = $DF1F

// UCI Control bits
.const PUSH_CMD  = $01
.const DATA_ACC  = $02

// UCI Status masks
.const STATE_MASK = $30
.const STATE_IDLE = $00
.const STATE_BUSY = $10
.const STAT_AV    = $40
.const DATA_AV    = $80

// Network Target ($03) commands
.const NET        = $03
.const NET_IPADDR = $05     // $03 $05 <iface>  → 12 bytes IP+mask+gw
.const NET_TCPCON = $07     // $03 $07 <portlo> <porthi> <host\0>  → socket
.const NET_CLOSE  = $09     // $03 $09 <socket>
.const NET_READ   = $10     // $03 $10 <socket> <lenlo> <lenhi>    → 2+n bytes
.const NET_WRITE  = $11     // $03 $11 <socket> <data until null>

// Server address and port
.const SRV_PORT_LO = $80    // port 8064 = 0x1F80
.const SRV_PORT_HI = $1F

// Hardware
.const SCR  = $0400
.const CLR  = $D800

// Colors
.const BLACK  = 0
.const WHITE  = 1
.const RED    = 2
.const CYAN   = 3
.const GREEN  = 5
.const BLUE   = 6
.const LGREY  = 15
.const LBLUE  = 14
.const LGREEN = 13
.const YELLOW = 7

// Zero page ($61-$6F safe user area)
.const ZP_COL    = $61      // current column (0-39)
.const ZP_ROW    = $62      // current row (0-24)
.const ZP_DCOL   = $63      // current text color
.const ZP_RXPTR  = $64      // receive buffer ptr lo (2B: $64-$65)
.const ZP_RXHI   = $65      //                    hi
.const ZP_TMP    = $66      // scratch ptr for put_char lo (2B: $66-$67)
.const ZP_TMPH   = $67      //                         hi
.const ZP_DECB   = $68      // scratch for decimal conversion
.const IP0       = $69      // IP address bytes from GET_IPADDR
.const IP1       = $6A
.const IP2       = $6B
.const IP3       = $6C
.const ZP_SOCK   = $6D      // TCP socket handle
.const ZP_LFCNT  = $6E      // consecutive LF counter (header-skip)
.const ZP_PHASE  = $6F      // do_get_binary: receive phase (0=headers,1-4=data,5=discard)
.const ZP_CNTLO  = $70      // do_get_binary: remaining bytes in phase (lo)
.const ZP_CNTHI  = $71      //                                          (hi)
.const ZP_CHAR0  = $72      // sprite: first char index  (also sign flag in parse_temp_line)
.const ZP_CHAR1  = $73      // sprite: second char index (units digit)
.const ZP_PGFULL = $74      // page-full flag: set by next_row on row overflow
// ZP_PTR = $FB-$FC: URL path pointer ("host/path\0")
// ZP_PTRH = $FC
.const ZP_PTR    = $FB
.const ZP_PTRH   = $FC

// Buffers
.const RXBUF        = $C000    // 1 KB receive buffer (body)
.const STBUF        = $C400    // 256 B status / HTTP request assembly
.const MAP_SRAM_BUF = $C802    // 1000 B safe copy of Koala screen RAM  ($C802–$CBE9)
.const MAP_CRAM_BUF = $CBEA    // 1000 B safe copy of Koala colour RAM  ($CBEA–$CFD1)

// ─────────────────────────────────────────────────────────────────────────────
BasicUpstart2(main)

main:
        sei
        lda #BLACK
        sta $D020
        sta $D021
        jsr cls
        jsr presave_map_bufs    // save koala screen/color RAM BEFORE splash trashes $41BD ($4000-$5F3F)
        jsr show_splash         // show Buienradar splash, wait for Space
        jsr copy_koala_to_ram   // copy map bitmap + apply saved buffers to VIC RAM
        lda #$16                // switch VIC-II to lowercase/uppercase charset
        sta $D018               // ($D018 $16 = screen@$0400, chars@$1800)

        // ── Title bar row 0 ────────────────────────────────────────────
        lda #CYAN
        ldx #39
tfl:    sta CLR,x
        dex
        bpl tfl
        lda #$A0
        ldx #39
tfr:    sta SCR,x
        dex
        bpl tfr
        lda #0
        sta ZP_ROW
        lda #5
        sta ZP_COL
        lda #CYAN
        sta ZP_DCOL
        lda #<str_title
        sta ZP_PTR
        lda #>str_title
        sta ZP_PTRH
        jsr pstr_rev

        // ── Key hints row 1 ────────────────────────────────────────────
        lda #1
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #LGREY
        sta ZP_DCOL
        lda #<str_keys
        sta ZP_PTR
        lda #>str_keys
        sta ZP_PTRH
        jsr pstr

        cli

        // ── Check UCI presence ─────────────────────────────────────────
        lda UCI_ID
        cmp #$C9
        beq uci_present
        jmp no_uci
uci_present:

        jsr get_ip              // fetch C64 IP once at boot; result cached in IP0-IP3
        jsr startup_diag

main_loop:
main_loop2:
        jsr $FFE4
        bne ml2_key
        lda loop_mode           // no key — check loop timer if active
        beq main_loop2
        jsr check_loop_timer
        bcc main_loop2          // not yet
        jmp loop_advance        // timer fired: advance to next page
ml2_key:
        cmp #$36                // '6' = toggle loop mode
        beq ml_toggle_loop
        pha                     // save key; cancel loop mode on any other key
        lda #0
        sta loop_mode
        pla
        cmp #'1'
        bne ml_k2
        jmp ml_c1
ml_k2:  cmp #'2'
        bne ml_k3
        jmp ml_c2
ml_k3:  cmp #'3'
        bne ml_k4
        jmp ml_c3
ml_k4:  cmp #'4'
        bne ml_k5
        jmp ml_c4
ml_k5:  cmp #'5'
        bne ml_ke
        jmp ml_c5
ml_ke:  cmp #$45                // 'E' = edit server address
        bne ml_kleft
        jsr page_edit_server    // let user edit host:port
        jsr startup_diag        // re-test connection with new server
        jmp main_loop
ml_kleft: cmp #$5F             // ← (back-arrow, left of 1) = return to setup screen
        bne ml_ks
        jsr startup_diag
        jmp main_loop
ml_ks:  cmp #$03
        bne ml_ign
        jmp ml_stop
ml_ign: jmp main_loop2

ml_toggle_loop:
        lda loop_mode
        eor #1
        sta loop_mode
        jsr update_loop_hint
        lda loop_mode           // re-check (update_loop_hint clobbers A)
        beq main_loop2          // turned off: back to waiting
        lda #0                  // turned on: start from page 0 (current)
        sta loop_page
        jsr set_loop_timer
        jsr restore_char_mode
        jsr cls_data
        jsr page_current
        jmp main_loop

loop_advance:
        inc loop_page
        lda loop_page
        cmp #5
        bne la_go
        lda #0
        sta loop_page
la_go:  jsr set_loop_timer
        lda loop_page
        cmp #1
        beq la_forecast
        cmp #2
        beq la_report
        cmp #3
        beq la_map
        cmp #4
        beq la_radar
        jsr restore_char_mode   // page 0 = current
        jsr cls_data
        jsr page_current
        jmp main_loop
la_forecast:
        jsr restore_char_mode
        jsr cls_data
        jsr page_forecast
        jmp main_loop
la_report:
        jsr restore_char_mode
        jsr cls_data
        jsr page_report
        jmp main_loop
la_map: jsr cls_data
        jsr page_map
        jsr cls_data
        jmp main_loop
la_radar:
        jsr cls_data
        jsr page_radar
        jsr cls_data
        jmp main_loop

ml_c1:  jsr restore_char_mode
        jsr cls_data
        jsr page_current
        jmp main_loop
ml_c2:  jsr restore_char_mode
        jsr cls_data
        jsr page_forecast
        jmp main_loop
ml_c3:  jsr restore_char_mode
        jsr cls_data
        jsr page_report
        jmp main_loop
ml_c4:  jsr cls_data
        jsr page_map
        jsr cls_data
        jmp main_loop
ml_c5:  jsr cls_data
        jsr page_radar
        jsr cls_data
        jmp main_loop
ml_stop:
        lda #$14                // restore uppercase/graphics charset for BASIC
        sta $D018
        lda #LBLUE
        sta $D020
        lda #BLUE
        sta $D021
        rts

no_uci:
        lda #4
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #RED
        sta ZP_DCOL
        lda #<str_no_uci
        sta ZP_PTR
        lda #>str_no_uci
        sta ZP_PTRH
        jsr pstr
        jmp *

// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// print_srv_host — print srv_host only (no port)
// print_srv_port — print srv_port_str only
// Uses current ZP_ROW, ZP_COL, ZP_DCOL.
// ─────────────────────────────────────────────────────────────────────────────
print_srv_host:
        lda #<srv_host
        sta ZP_PTR
        lda #>srv_host
        sta ZP_PTRH
        jsr pstr
        rts

print_srv_port:
        lda #<srv_port_str
        sta ZP_PTR
        lda #>srv_port_str
        sta ZP_PTRH
        jsr pstr
        rts

// ─────────────────────────────────────────────────────────────────────────────
// port_str_to_bin — convert ASCII decimal string at srv_port_str to binary
// Stores result in srv_port_lo / srv_port_hi  (little-endian)
// Clobbers A, X, ZP_TMP, ZP_TMPH, ZP_CHAR0, ZP_CHAR1
// ─────────────────────────────────────────────────────────────────────────────
port_str_to_bin:
        lda #0
        sta ZP_TMP
        sta ZP_TMPH
        ldx #0
psb_loop:
        lda srv_port_str,x
        beq psb_done            // null terminator: finished
        sec
        sbc #$30                // '0'-'9' → 0-9
        bmi psb_done            // not a digit
        cmp #10
        bcs psb_done            // not a digit
        pha                     // save digit

        // ZP_TMP:TMPH = result * 10  (= result*8 + result*2)
        asl ZP_TMP
        rol ZP_TMPH             // * 2
        lda ZP_TMP
        sta ZP_CHAR0
        lda ZP_TMPH
        sta ZP_CHAR1            // save result*2
        asl ZP_TMP
        rol ZP_TMPH             // * 4
        asl ZP_TMP
        rol ZP_TMPH             // * 8
        clc
        lda ZP_TMP
        adc ZP_CHAR0
        sta ZP_TMP
        lda ZP_TMPH
        adc ZP_CHAR1
        sta ZP_TMPH             // result*10 in ZP_TMP:TMPH

        pla                     // restore digit
        clc
        adc ZP_TMP
        sta ZP_TMP
        bcc psb_next
        inc ZP_TMPH
psb_next:
        inx
        jmp psb_loop
psb_done:
        lda ZP_TMP
        sta srv_port_lo
        lda ZP_TMPH
        sta srv_port_hi
        rts

// ─────────────────────────────────────────────────────────────────────────────
// page_edit_server — interactive server address editor
// Presents a prompt, reads HOST:PORT from keyboard, updates srv_host/port vars.
// Pressing RUN/STOP cancels without changing anything.
// ─────────────────────────────────────────────────────────────────────────────
page_edit_server:
        jsr restore_char_mode
        jsr cls_data

        lda #CYAN
        sta ZP_DCOL
        lda #3
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #<str_edit_hdr
        sta ZP_PTR
        lda #>str_edit_hdr
        sta ZP_PTRH
        jsr pstr

        lda #LGREY
        sta ZP_DCOL
        lda #5
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #<str_edit_cur
        sta ZP_PTR
        lda #>str_edit_cur
        sta ZP_PTRH
        jsr pstr
        jsr print_srv_host      // show current host
        lda #$3A
        jsr put_char
        jsr print_srv_port      // show current port

        lda #LGREY
        sta ZP_DCOL
        lda #7
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #<str_edit_hint
        sta ZP_PTR
        lda #>str_edit_hint
        sta ZP_PTRH
        jsr pstr

        lda #LGREEN
        sta ZP_DCOL
        lda #9
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #<str_edit_prompt
        sta ZP_PTR
        lda #>str_edit_prompt
        sta ZP_PTRH
        jsr pstr
        // cursor is now positioned right after "NEW     : "

        lda #WHITE
        sta ZP_DCOL
        lda #0
        sta ZP_DECB             // ZP_DECB = input char count

pes_key:
        jsr $FFE4
        beq pes_key             // wait for key

        cmp #$0D                // RETURN = accept
        beq pes_accept
        cmp #$03                // RUN/STOP = cancel
        beq pes_cancel
        cmp #$14                // DEL = backspace
        beq pes_del

        // Accept printable ASCII $20-$7E
        cmp #$20
        bcc pes_key             // < $20: control, skip
        cmp #$7F
        bcs pes_key             // $7F+: skip

        // max 35 chars in buffer
        ldy ZP_DECB
        cpy #35
        bcs pes_key

        sta STBUF,y             // store raw ASCII in STBUF
        inc ZP_DECB

        // echo: convert to screen code and write at cursor
        jsr a2s
        jsr put_char
        jmp pes_key

pes_del:
        lda ZP_DECB
        beq pes_key             // nothing to delete
        dec ZP_DECB
        dec ZP_COL              // step cursor back
        lda #$20                // print space (erase)
        jsr put_char
        dec ZP_COL              // step back again to stay at erased position
        jmp pes_key

pes_cancel:
        rts                     // return without updating anything

pes_accept:
        // null-terminate the input buffer
        ldy ZP_DECB
        lda #0
        sta STBUF,y

        // empty input = cancel
        cpy #0
        beq pes_cancel

        // Find ':' separating host from port (scan forward)
        ldx #0
pes_find:
        lda STBUF,x
        beq pes_no_colon        // hit null: no colon
        cmp #$3A                // ':'
        beq pes_has_colon
        inx
        jmp pes_find

pes_no_colon:
        // No colon: treat whole input as hostname, keep existing port
        ldx #0
pes_cp_host_nc:
        lda STBUF,x
        sta srv_host,x
        beq pes_done            // copied null terminator; done
        inx
        cpx #31
        bcc pes_cp_host_nc
        lda #0
        sta srv_host,x          // force null-terminate at max length
        jmp pes_done

pes_has_colon:
        // X = index of ':'; copy STBUF[0..X-1] to srv_host
        stx ZP_DECB             // save colon index
        ldy #0
pes_cp_host:
        lda STBUF,y
        sta srv_host,y
        iny
        cpy ZP_DECB             // stop when we reach the ':'
        bne pes_cp_host
        lda #0
        sta srv_host,y          // null-terminate host

        // Copy port string STBUF[X+1..] to srv_port_str
        inc ZP_DECB             // ZP_DECB now = index of first port digit
        ldy ZP_DECB
        ldx #0
pes_cp_port:
        lda STBUF,y
        beq pes_port_done
        sta srv_port_str,x
        iny
        inx
        cpx #5                  // max 5 port digits
        bcc pes_cp_port
pes_port_done:
        lda #0
        sta srv_port_str,x      // null-terminate port string

        jsr port_str_to_bin     // convert to srv_port_lo / srv_port_hi

pes_done:
        rts

// startup_diag — show IP + test server connection (10-second timeout)
// Help options and credits are rendered BEFORE the test so they are always
// visible.  On success or failure the routine returns immediately — no
// keypress is needed; main_loop handles E / 1-6 straight away.
// ─────────────────────────────────────────────────────────────────────────────
startup_diag:
        jsr restore_char_mode   // ensure text mode/bank 0 regardless of prior screen
        jsr cls                 // clear full screen (rows 0-24 + all color RAM)

        // ── Title bar row 0 ──────────────────────────────────────────────────
        lda #CYAN
        ldx #39
sd_tf:  sta CLR,x
        dex
        bpl sd_tf
        lda #$A0
        ldx #39
sd_tr:  sta SCR,x
        dex
        bpl sd_tr
        lda #0
        sta ZP_ROW
        lda #5
        sta ZP_COL
        lda #CYAN
        sta ZP_DCOL
        lda #<str_title
        sta ZP_PTR
        lda #>str_title
        sta ZP_PTRH
        jsr pstr_rev

        // ── Key hints row 1 ──────────────────────────────────────────────────
        lda #1
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #LGREY
        sta ZP_DCOL
        lda #<str_keys
        sta ZP_PTR
        lda #>str_keys
        sta ZP_PTRH
        jsr pstr

        // ── Static info rows ────────────────────────────────────────────────
        lda #3
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #CYAN
        sta ZP_DCOL
        lda #<str_uci_ok
        sta ZP_PTR
        lda #>str_uci_ok
        sta ZP_PTRH
        jsr pstr

        lda #5
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #CYAN
        sta ZP_DCOL
        lda #<str_ip_lbl
        sta ZP_PTR
        lda #>str_ip_lbl
        sta ZP_PTRH
        jsr pstr
        jsr print_ip            // IP was cached by get_ip at startup; just display it

        lda #7
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #CYAN
        sta ZP_DCOL
        lda #<str_srv_lbl
        sta ZP_PTR
        lda #>str_srv_lbl
        sta ZP_PTRH
        jsr pstr
        jsr print_srv_host

        lda #8
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #CYAN
        sta ZP_DCOL
        lda #<str_port_lbl
        sta ZP_PTR
        lda #>str_port_lbl
        sta ZP_PTRH
        jsr pstr
        jsr print_srv_port

        // ── Key descriptions (always shown, before the blocking test) ────────
        lda #LGREY
        sta ZP_DCOL
        lda #0
        sta ZP_COL
        lda #14
        sta ZP_ROW
        lda #<str_key_mappings
        sta ZP_PTR
        lda #>str_key_mappings
        sta ZP_PTRH
        jsr pstr
        lda #0
        sta ZP_COL
        lda #15
        sta ZP_ROW
        lda #<str_help1
        sta ZP_PTR
        lda #>str_help1
        sta ZP_PTRH
        jsr pstr
        lda #0
        sta ZP_COL
        lda #16
        sta ZP_ROW
        lda #<str_help2
        sta ZP_PTR
        lda #>str_help2
        sta ZP_PTRH
        jsr pstr
        lda #0
        sta ZP_COL
        lda #17
        sta ZP_ROW
        lda #<str_help3
        sta ZP_PTR
        lda #>str_help3
        sta ZP_PTRH
        jsr pstr
        lda #0
        sta ZP_COL
        lda #18
        sta ZP_ROW
        lda #<str_help4
        sta ZP_PTR
        lda #>str_help4
        sta ZP_PTRH
        jsr pstr
        lda #0
        sta ZP_COL
        lda #19
        sta ZP_ROW
        lda #<str_help5
        sta ZP_PTR
        lda #>str_help5
        sta ZP_PTRH
        jsr pstr
        lda #0
        sta ZP_COL
        lda #20
        sta ZP_ROW
        lda #<str_help6
        sta ZP_PTR
        lda #>str_help6
        sta ZP_PTRH
        jsr pstr
        lda #0
        sta ZP_COL
        lda #22
        sta ZP_ROW
        lda #<str_help_e
        sta ZP_PTR
        lda #>str_help_e
        sta ZP_PTRH
        jsr pstr
        lda #0
        sta ZP_COL
        lda #23
        sta ZP_ROW
        lda #<str_help_back
        sta ZP_PTR
        lda #>str_help_back
        sta ZP_PTRH
        jsr pstr

        // ── Connection test with 10-second timeout ───────────────────────────
        lda #YELLOW
        sta ZP_DCOL
        lda #0
        sta ZP_COL
        lda #10
        sta ZP_ROW
        lda #<str_testing
        sta ZP_PTR
        lda #>str_testing
        sta ZP_PTRH
        jsr pstr

        jsr arm_timeout_10s

        lda #<path_test
        sta ZP_PTR
        lda #>path_test
        sta ZP_PTRH
        jsr do_get

        jsr disarm_timeout

        bcc sd_ok
        // ── Fail / timeout ───────────────────────────────────────────────────
        lda #10
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #RED
        sta ZP_DCOL
        lda #<str_fail
        sta ZP_PTR
        lda #>str_fail
        sta ZP_PTRH
        jsr pstr
        rts                 // return immediately — main_loop handles E / 1-6

sd_ok:
        // ── Success ──────────────────────────────────────────────────────────
        lda #10
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #LGREEN
        sta ZP_DCOL
        lda #<str_ok
        sta ZP_PTR
        lda #>str_ok
        sta ZP_PTRH
        jsr pstr

        lda #12
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #LGREEN
        sta ZP_DCOL
        lda #<str_resp_lbl
        sta ZP_PTR
        lda #>str_resp_lbl
        sta ZP_PTRH
        jsr pstr
        lda #<RXBUF
        sta ZP_PTR
        lda #>RXBUF
        sta ZP_PTRH
        jsr pstr_oneline

        rts

// ─────────────────────────────────────────────────────────────────────────────
// get_ip — read device IP via NET_CMD_GET_IPADDR
// Fills IP0..IP3.  On error, leaves them as-is (may be 0).
// ─────────────────────────────────────────────────────────────────────────────
get_ip:
        jsr uci_idle
        lda #NET
        sta UCI_CMD
        lda #NET_IPADDR
        sta UCI_CMD
        lda #$00
        sta UCI_CMD
        lda #PUSH_CMD
        sta UCI_CTRL
        jsr uci_rdy
        jsr uci_wait_dav
        lda UCI_DATA
        sta IP0
        jsr uci_wait_dav
        lda UCI_DATA
        sta IP1
        jsr uci_wait_dav
        lda UCI_DATA
        sta IP2
        jsr uci_wait_dav
        lda UCI_DATA
        sta IP3
        jsr uci_drain_d
        jsr uci_drain_s
        lda #DATA_ACC
        sta UCI_CTRL
        rts

// ─────────────────────────────────────────────────────────────────────────────
// print_ip — display IP0.IP1.IP2.IP3
// ─────────────────────────────────────────────────────────────────────────────
print_ip:
        lda IP0
        jsr print_byte_dec
        lda #$2E
        jsr a2s
        jsr put_char
        lda IP1
        jsr print_byte_dec
        lda #$2E
        jsr a2s
        jsr put_char
        lda IP2
        jsr print_byte_dec
        lda #$2E
        jsr a2s
        jsr put_char
        lda IP3
        jsr print_byte_dec
        rts

// ─────────────────────────────────────────────────────────────────────────────
// print_byte_dec — print A as 3-digit decimal (000-255)
// ─────────────────────────────────────────────────────────────────────────────
print_byte_dec:
        ldy #0
pbd_h:  cmp #100
        bcc pbd_hd
        sec
        sbc #100
        iny
        jmp pbd_h
pbd_hd: sta ZP_DECB
        tya
        clc
        adc #$30
        jsr a2s
        jsr put_char
        lda ZP_DECB
        ldy #0
pbd_t:  cmp #10
        bcc pbd_td
        sec
        sbc #10
        iny
        jmp pbd_t
pbd_td: pha
        tya
        clc
        adc #$30
        jsr a2s
        jsr put_char
        pla
        clc
        adc #$30
        jsr a2s
        jsr put_char
        rts

// ─────────────────────────────────────────────────────────────────────────────
// page_current / page_forecast / page_report
// ─────────────────────────────────────────────────────────────────────────────
page_current:
        lda #<path_curr
        sta ZP_PTR
        lda #>path_curr
        sta ZP_PTRH
        jsr do_get
        bcc pc_ok
        jmp pg_err
pc_ok:  lda #LGREEN
        sta ZP_DCOL
        lda #3
        sta ZP_ROW
        lda #0
        sta ZP_COL
        jsr show_rx
        rts

page_forecast:
        lda #<path_fcst
        sta ZP_PTR
        lda #>path_fcst
        sta ZP_PTRH
        jsr do_get
        bcc pf_ok
        jmp pg_err
pf_ok:  lda #LBLUE
        sta ZP_DCOL
        lda #3
        sta ZP_ROW
        lda #0
        sta ZP_COL
        jsr show_rx
        rts

page_report:
        lda #<path_rpt
        sta ZP_PTR
        lda #>path_rpt
        sta ZP_PTRH
        jsr do_get
        bcc pr_ok
        jmp pg_err
pr_ok:
pr_restart:
        lda #<RXBUF             // reset read pointer to start of buffer
        sta ZP_RXPTR
        lda #>RXBUF
        sta ZP_RXHI
        jsr cls_data
        lda #WHITE
        sta ZP_DCOL
        lda #3
        sta ZP_ROW
        lda #0
        sta ZP_COL
        jsr show_rx_paged
        bcc pr_restart          // C=0: SPACE on last page → restart from page 1
        rts                     // C=1: other key stuffed or timer fired

pg_err:
        jsr cls_data
        lda #RED
        sta ZP_DCOL
        lda #4
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #<str_err
        sta ZP_PTR
        lda #>str_err
        sta ZP_PTRH
        jsr pstr
        rts

// ─────────────────────────────────────────────────────────────────────────────
// page_map — display embedded Koala bitmap, overlay live temperatures via sprites
//
// The blank Netherlands map (green land / blue sea) was copied to VIC bank 1
// at startup by copy_koala_to_ram.  page_map just switches to bitmap mode,
// fetches 5 temperatures from /temps (a tiny ~30-byte HTTP response), and
// uses hardware sprites (single-colour, 24×21 px) to overlay each city.
//
// Sprite data: $5C00-$5D7F in VIC bank 1 (pointers $70-$75 at $43F8+)
// City order:  Groningen / Amsterdam / Utrecht / Rotterdam / Maastricht
// ─────────────────────────────────────────────────────────────────────────────
page_map:
        // ── 0. Restore Koala bitmap, screen RAM and colour RAM ────────────
        jsr restore_koala_bitmap    // radar overwrites $6000; must restore
        jsr restore_koala_sram
        jsr restore_koala_cram

        // ── 1. Switch to multicolour bitmap mode ─────────────────────────
        lda $D011
        and #$EF            // blank display while switching
        sta $D011
        lda $DD00
        and #$FC
        ora #$02            // VIC bank 1 ($4000-$7FFF)
        sta $DD00
        lda $D011
        ora #$20            // bitmap mode
        sta $D011
        lda $D016
        ora #$10            // multicolour
        sta $D016
        lda #$08            // screen@$4000, bitmap@$6000
        sta $D018
        lda #LBLUE
        sta $D021           // map background: light blue
        sta $D020           // border: light blue
        lda #0
        sta $D010           // clear sprite X MSBs
        sta $D015           // all sprites off
        lda $D011
        ora #$10
        sta $D011           // re-enable display

        // ── 2. Fetch /temps ───────────────────────────────────────────────
        lda #<path_temps
        sta ZP_PTR
        lda #>path_temps
        sta ZP_PTRH
        jsr do_get
        bcc pm_fetch_ok
        jmp pm_wait         // error: show blank map, wait for key
pm_fetch_ok:

        // ── 3. Parse 6 temperatures from RXBUF ───────────────────────────
        lda #<RXBUF
        sta ZP_PTR
        lda #>RXBUF
        sta ZP_PTRH
        ldx #0
pm_parse:
        jsr parse_temp_line
        sta temp_values,x
        inx
        cpx #6
        bne pm_parse

        // ── 3b. Parse 6 icon indices (lines 7-12 of /temps response) ─────────
        ldx #0
pm_icon_parse:
        ldy #0
        lda (ZP_PTR),y
        cmp #$30            // must be '0'..'8'
        bcc pmi_default
        cmp #$39
        bcs pmi_default
        sec
        sbc #$30
        jmp pmi_store
pmi_default:
        lda #2              // fallback: cloudy
pmi_store:
        sta city_icons,x
        jsr ptl_adv         // advance past digit
        jsr ptl_adv         // advance past newline
        inx
        cpx #6
        bne pm_icon_parse

        // ── 4. Install temperature sprite pointers ────────────────────────────
        lda #$70
        sta $43F8
        lda #$71
        sta $43F9
        lda #$72
        sta $43FA
        lda #$73
        sta $43FB
        lda #$74
        sta $43FC
        lda #$75
        sta $43FD

        // ── 4b. Initialise alternating display state ─────────────────────────
        // (icon sprites already copied to $4400 by copy_koala_to_ram at startup)
        lda #0
        sta pm_show_icons   // start with temperatures visible
        jsr pm_set_alt_timer

        // ── 5. Render sprites ─────────────────────────────────────────────
        ldx #5
pm_spr_render:
        lda temp_values,x
        cmp #99             // sentinel: no station data → leave sprite blank
        beq pm_spr_skip
        sta ZP_CHAR0
        jsr render_temp_sprite
pm_spr_skip:
        dex
        bpl pm_spr_render

        // ── 6. Re-apply Koala screen RAM (do_get may clobber ZP_TMP/TMPH) ──
        jsr restore_koala_sram
        jsr patch_screen_sram   // fix known-bad cells in Limburg area

        // ── 7. Position, colour, enable sprites ──────────────────────────
        ldx #0
        ldy #0
pm_pos_loop:
        lda spr_x_tab,x
        sta $D000,y
        lda spr_y_tab,x
        sta $D001,y
        lda #WHITE
        sta $D027,x
        inx
        iny
        iny
        cpx #6
        bne pm_pos_loop
        lda #%00111111
        sta $D015

pm_wait:
        jsr pm_check_alt_timer  // 3-second flip: swap temp/icon sprites
        bcc pmw_no_flip
        jsr pm_swap_sprites
pmw_no_flip:
        jsr $FFE4
        bne pmw_key
        lda loop_mode           // no key — check loop timer
        beq pm_wait
        jsr check_loop_timer
        bcc pm_wait
        jmp pmw_done            // timer fired: exit without key injection
pmw_key:
        sta $0277               // put key back so main_loop can act on it
        lda #1
        sta $00C6
pmw_done:

        // ── 7. Tear down ─────────────────────────────────────────────────
        lda #BLACK
        sta $D020           // restore border to black
        lda #0
        sta $D015
        lda $D011
        and #$EF
        sta $D011
        jsr restore_char_mode
        rts

// ─────────────────────────────────────────────────────────────────────────────
// render_temp_sprite — build 63-byte sprite bitmap for one temperature label
//
// Input:  X = sprite index (0-4)
//         ZP_CHAR0 = signed temperature as byte (e.g. 13 or -5)
// Uses:   ZP_TMP/TMPH (sprite buffer ptr), ZP_CHAR0/ZP_CHAR1 (char indices)
//         ZP_DECB (font row / scratch)
// ─────────────────────────────────────────────────────────────────────────────
render_temp_sprite:
        txa
        pha                 // save sprite index on stack
        lda spr_ptr_lo,x
        sta ZP_TMP
        lda spr_ptr_hi,x
        sta ZP_TMPH

        lda #0
        ldy #62
rts_clr:
        sta (ZP_TMP),y
        dey
        bpl rts_clr

        // Convert temperature to two font character indices
        lda ZP_CHAR0
        bmi rts_neg

        cmp #10
        bcc rts_single

        // 10-39: tens in ZP_CHAR0, units in ZP_CHAR1
        ldx #0
rts_div10:
        cmp #10
        bcc rts_div_done
        sbc #10
        inx
        jmp rts_div10
rts_div_done:
        sta ZP_CHAR1
        stx ZP_CHAR0
        jmp rts_draw

rts_single:
        tax
        lda #12             // space
        sta ZP_CHAR0
        stx ZP_CHAR1
        jmp rts_draw

rts_neg:
        eor #$FF
        clc
        adc #1
        cmp #10
        bcc rts_neg_ok
        lda #9
rts_neg_ok:
        tax
        lda #11             // minus sign
        sta ZP_CHAR0
        stx ZP_CHAR1

        // Render 8 font rows into sprite rows 7-14 (byte offset 21)
rts_draw:
        ldy #21
        ldx #0
rts_row:
        stx ZP_DECB

        lda ZP_CHAR0
        asl
        asl
        asl
        clc
        adc ZP_DECB
        tax
        lda digit_font,x
        sta (ZP_TMP),y
        iny

        lda ZP_CHAR1
        asl
        asl
        asl
        clc
        adc ZP_DECB
        tax
        lda digit_font,x
        sta (ZP_TMP),y
        iny

        iny                 // third byte stays 0 (no °C suffix)

        ldx ZP_DECB
        inx
        cpx #8
        bne rts_row
        pla
        tax                 // restore sprite index
        rts

// ─────────────────────────────────────────────────────────────────────────────
// parse_temp_line — parse one signed integer from (ZP_PTR), advance past \n
// Output: A = signed byte  (e.g. "13\n" → 13, "-5\n" → -5)
// Uses: ZP_PTR/ZP_PTRH, ZP_CHAR0 (sign flag), ZP_DECB (accumulator), Y
// ─────────────────────────────────────────────────────────────────────────────
parse_temp_line:
        ldy #0
        lda #0
        sta ZP_CHAR0        // sign: 0=positive

        lda (ZP_PTR),y
        cmp #$2D            // '-'
        bne ptl_digit1
        lda #1
        sta ZP_CHAR0
        jsr ptl_adv

ptl_digit1:
        lda (ZP_PTR),y
        sec
        sbc #$30
        sta ZP_DECB

        jsr ptl_adv
        lda (ZP_PTR),y
        cmp #$30
        bcc ptl_eol
        cmp #$3A
        bcs ptl_eol

        // Second digit: ZP_DECB = ZP_DECB * 10 + new_digit
        lda ZP_DECB
        asl                 // A = ×2
        sta ZP_CHAR1        // save ×2 (ZP_CHAR1 free during parse)
        asl                 // A = ×4
        asl                 // A = ×8
        clc
        adc ZP_CHAR1        // ×8 + ×2 = ×10 (X never touched)
        sta ZP_DECB
        lda (ZP_PTR),y
        sec
        sbc #$30
        clc
        adc ZP_DECB
        sta ZP_DECB
        jsr ptl_adv

ptl_eol:
ptl_skip:
        lda (ZP_PTR),y
        cmp #$0A
        beq ptl_done
        jsr ptl_adv
        jmp ptl_skip
ptl_done:
        jsr ptl_adv         // skip \n

        lda ZP_DECB
        ldy ZP_CHAR0
        beq ptl_ret
        eor #$FF
        clc
        adc #1
ptl_ret:
        ldy #0
        rts

ptl_adv:
        inc ZP_PTR
        bne ptl_adv_done
        inc ZP_PTRH
ptl_adv_done:
        rts

// ─────────────────────────────────────────────────────────────────────────────
// copy_koala_to_ram — copy embedded map Koala data to VIC bank 1 + colour RAM
//
// Called once at startup.  Source = koala_data (in PRG load area).
//
// MEMORY OVERLAP WARNING: koala_data is at $1E95, so:
//   koala_data+8000 (screen RAM src) = $3DD5 — overlaps dest $4000 after byte 555
//   koala_data+9000 (colour RAM src) = $41BD — lands INSIDE dest $4000-$43E7
//
// Fix: save both blocks to safe buffers in RAM before touching any destination.
// Safe buffers are outside both the PRG area and the VIC bank 1 area.
//
// Steps:
//   1. koala screen RAM ($3DD5, 1000 B) → MAP_SRAM_BUF ($C500)   [no overlap]
//   2. koala colour RAM ($41BD, 1000 B) → MAP_CRAM_BUF ($C8E8)   [no overlap, before $41BD overwritten]
//   3. MAP_SRAM_BUF ($C500) → $4000                               [safe: src > dst+1000]
//   4. MAP_CRAM_BUF ($C8E8) → $D800                               [safe]
//   5. koala bitmap  ($1E95, 8000 B) → $6000                      [no overlap]
// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// presave_map_bufs — save Koala screen/colour RAM to safe buffers
//
// MUST be called BEFORE show_splash, which writes its bitmap to $4000-$5F3F
// and would destroy koala_data+8000 ($3DD5-$41BC) and koala_data+9000
// ($41BD-$456B) — both of which live inside that range.
//
// Safe buffers (MAP_SRAM_BUF at $C802, MAP_CRAM_BUF at $CBEA) are never
// touched by show_splash, so they survive intact for copy_koala_to_ram.
// ─────────────────────────────────────────────────────────────────────────────
presave_map_bufs:
        lda #<(koala_data + 8000)
        sta ZP_PTR
        lda #>(koala_data + 8000)
        sta ZP_PTRH
        lda #<MAP_SRAM_BUF
        sta ZP_TMP
        lda #>MAP_SRAM_BUF
        sta ZP_TMPH
        jsr ckr_1000

        lda #<(koala_data + 9000)
        sta ZP_PTR
        lda #>(koala_data + 9000)
        sta ZP_PTRH
        lda #<MAP_CRAM_BUF
        sta ZP_TMP
        lda #>MAP_CRAM_BUF
        sta ZP_TMPH
        jsr ckr_1000
        rts

copy_koala_to_ram:
        // Steps 1 & 2 (buffer save) are done by presave_map_bufs before show_splash.
        // ── Step 3: safe buffer → VIC bank 1 screen RAM ($4000) ──────────
        lda #<MAP_SRAM_BUF
        sta ZP_PTR
        lda #>MAP_SRAM_BUF
        sta ZP_PTRH
        lda #$00
        sta ZP_TMP
        lda #$40
        sta ZP_TMPH
        jsr ckr_1000

        // ── Step 4: safe buffer → colour RAM ($D800) ──────────────────────
        lda #<MAP_CRAM_BUF
        sta ZP_PTR
        lda #>MAP_CRAM_BUF
        sta ZP_PTRH
        lda #$00
        sta ZP_TMP
        lda #$D8
        sta ZP_TMPH
        jsr ckr_1000

        // ── Step 4c: icon sprites → $4400 BEFORE bitmap overwrites $6000–$7FFF ─
        // icon_sprite_data lives in PRG RAM inside $6000–$7FFF; bitmap copy
        // (step 5) would clobber it, so we must copy the icons first.
        // 9 sprites × 64 bytes = 576 bytes = 2 full pages + 64-byte tail.
        lda #<icon_sprite_data
        sta ZP_PTR
        lda #>icon_sprite_data
        sta ZP_PTRH
        lda #$00
        sta ZP_TMP
        lda #$44
        sta ZP_TMPH
        ldy #0
ckisp0: lda (ZP_PTR),y
        sta (ZP_TMP),y
        iny
        bne ckisp0
        inc ZP_PTRH
        inc ZP_TMPH
        ldy #0
ckisp1: lda (ZP_PTR),y
        sta (ZP_TMP),y
        iny
        bne ckisp1
        inc ZP_PTRH
        inc ZP_TMPH
        ldy #0
ckisp2: lda (ZP_PTR),y          // 64-byte tail for sprite 8 ($4600-$463F)
        sta (ZP_TMP),y
        iny
        cpy #64
        bne ckisp2

        // ── Step 5: bitmap → $6000 ────────────────────────────────────────
        // Use restore_koala_bitmap so the splash-overlap fix (blanking of
        // bottom rows 22-24) is applied here too.
        jsr restore_koala_bitmap

        lda koala_data + 10000
        sta map_bgcolor
        rts

// ─────────────────────────────────────────────────────────────────────────────
// Loop-mode timer helpers
// C64 jiffy clock: $A0 (hi), $A1 (mid), $A2 (lo) — increments 60×/sec.
// 12 seconds = 720 jiffies = $02D0.
// ─────────────────────────────────────────────────────────────────────────────

// patch_screen_sram — hardcode known-bad screen RAM cells in bottom-right
// Cells $430D-$430F, $4335-$4337, $435D-$435F must be $50 (green land).
// The Koala source bytes at these offsets get corrupted after PRG load,
// so restore_koala_sram copies $00 instead. Write $50 unconditionally.
patch_screen_sram:
        lda #$55            // c1=green, c2=green — prevents black artefact
        sta $430D
        sta $430E
        sta $430F
        sta $4335
        sta $4336
        sta $4337
        sta $435D
        sta $435E
        sta $435F
        rts

// ─────────────────────────────────────────────────────────────────────────────
// page_radar — animated precipitation radar.
//
// Calls do_get_binary("/radar") in a loop; the server returns the next
// pre-converted Koala frame each time.  Each frame overwrites $6000/$4000/$D800
// while the previous frame is still on screen (scan effect), then the display
// updates instantly.  Any key press exits; loop timer also exits.
// Border is red while radar is active.
// ─────────────────────────────────────────────────────────────────────────────
page_radar:
        // ── 1. Blank display; switch to text mode (bank 0) for loading screen ──
        lda $D011
        and #$CF                // clear DEN (bit4) + bitmap (bit5)
        sta $D011
        lda $D016
        and #$EF                // clear multicolour
        sta $D016
        lda $DD00
        and #$FC
        ora #$03                // VIC bank 0
        sta $DD00
        lda #$16                // screen@$0400, ROM charset
        sta $D018
        lda #RED
        sta $D020               // red border = radar active
        lda #0
        sta $D010
        sta $D015               // sprites off

        // Clear text screen rows 2-24 ($0450-$07E7) without touching the
        // title/menu bar (rows 0-1, $0400-$044F) or color RAM.
        lda #$20
        ldx #$50
pr_cls_lp1:
        sta $0400,x         // $0450-$04FF (176 bytes: X=$50..$FF)
        inx
        bne pr_cls_lp1
        ldx #0
pr_cls_lp2:
        sta $0500,x         // $0500-$05FF (256 bytes)
        sta $0600,x         // $0600-$06FF (256 bytes)
        inx
        bne pr_cls_lp2
        ldx #0
pr_cls_tail:
        sta $0700,x         // $0700-$07E7 (232 bytes)
        inx
        cpx #$E8
        bne pr_cls_tail
        lda #12
        sta ZP_ROW
        lda #8
        sta ZP_COL
        lda #CYAN
        sta ZP_DCOL
        lda #<str_loading_radar
        sta ZP_PTR
        lda #>str_loading_radar
        sta ZP_PTRH
        jsr pstr
        // Re-enable display — user sees "LOADING RADAR IMAGES...."
        lda $D011
        ora #$10
        sta $D011
        // Signal pr_flip_frame to do the one-time VIC mode switch on the first frame
        lda #1
        sta pr_first_frame

        // ── 2. Frame loop ─────────────────────────────────────────────────
pr_frame:
        // Redirect ALL phases to off-screen buffers so live display is untouched
        lda #$80
        sta dgb_bmp_hi      // bitmap  → $8000
        lda #$C0
        sta dgb_scr_hi      // screen  → $C000
        lda #$C4
        sta dgb_cram_hi     // cram    → $C400
        lda #$00
        sta dgb_bg_lo       // bg      → $C800
        lda #$C8
        sta dgb_bg_hi

        lda #<path_radar
        sta ZP_PTR
        lda #>path_radar
        sta ZP_PTRH
        // Arm a 10-second UCI timeout so a hung TCP/uci_wait_dav can't lock the
        // radar forever (root cause of "stuck on loading radar images" hang).
        // The radar's own loop_timer is also 10s so a single timed-out fetch
        // simply consumes one radar slot — cycling continues normally.
        jsr arm_timeout_10s
        jsr do_get_binary   // all data → buffers, display unchanged
        php                 // preserve carry across disarm + restore-defaults
        jsr disarm_timeout

        // Restore defaults for other pages — must run on every iteration so
        // the next page (map/etc.) writes its data to the correct addresses.
        lda #$60
        sta dgb_bmp_hi
        lda #$40
        sta dgb_scr_hi
        lda #$D8
        sta dgb_cram_hi
        lda #$21
        sta dgb_bg_lo
        lda #$D0
        sta dgb_bg_hi

        plp                 // restore carry from do_get_binary
        bcs pr_fetch_failed

        // Flip: copy colors then bitmap — no blank, wipe is artifact-free
        jsr pr_flip_frame
        // Build and enable timestamp sprites from the freshly received HH/MM bytes
        jsr pr_setup_ts_sprites
        jmp pr_after_flip

pr_fetch_failed:
        // Failed/timed-out fetch: keep showing the previous frame.  Fall
        // through to the key/timer check so cycling and key handling still work.

pr_after_flip:
        jsr $FFE4               // key pressed?
        bne pr_key
        lda loop_mode           // check loop timer
        beq pr_frame
        jsr check_loop_timer
        bcc pr_frame
        jmp pr_done             // timer fired: exit silently

pr_key:
        sta $0277               // stuff key back for main_loop
        lda #1
        sta $00C6
        jmp pr_done             // disable sprites + restore before returning

// ─────────────────────────────────────────────────────────────────────────────
// render_ts_sprite — like render_temp_sprite but ZP_CHAR0/ZP_CHAR1 are used
// directly as digit_font indices (no temperature decomposition).
// Input:  X = sprite index (0-2), ZP_CHAR0/ZP_CHAR1 = font indices (0-13)
// ─────────────────────────────────────────────────────────────────────────────
render_ts_sprite:
        lda spr_ptr_lo,x
        sta ZP_TMP
        lda spr_ptr_hi,x
        sta ZP_TMPH
        txa
        pha                         // save sprite index
        // Clear all 63 bytes of sprite buffer
        lda #0
        ldy #62
rtss_clr:
        sta (ZP_TMP),y
        dey
        bpl rtss_clr
        // Render 8 font rows at sprite byte offset 21 (sprite rows 7-14)
        ldy #21
        ldx #0
rtss_row:
        stx ZP_DECB
        lda ZP_CHAR0
        asl
        asl
        asl
        clc
        adc ZP_DECB
        tax
        lda digit_font,x
        sta (ZP_TMP),y
        iny
        lda ZP_CHAR1
        asl
        asl
        asl
        clc
        adc ZP_DECB
        tax
        lda digit_font,x
        sta (ZP_TMP),y
        iny
        iny                         // third byte stays 0
        ldx ZP_DECB
        inx
        cpx #8
        bne rtss_row
        pla
        tax                         // restore sprite index
        rts

// ─────────────────────────────────────────────────────────────────────────────
// pr_setup_ts_sprites — decompose radar_ts (HH,MM) into 4 digits, build
// sprites 0-2 ("HH" | ":M" | "M_"), position them bottom-right, enable.
// ─────────────────────────────────────────────────────────────────────────────
pr_setup_ts_sprites:
        // ── Decompose HH into tens (ts_d1) and units (ts_d2) ────────────────
        lda radar_ts                // HH (0-23)
        ldx #0
pts_div_hh:
        cmp #10
        bcc pts_hh_done
        sec
        sbc #10
        inx
        jmp pts_div_hh
pts_hh_done:
        sta ts_d2
        stx ts_d1
        // ── Decompose MM into tens (ts_d3) and units (ts_d4) ────────────────
        lda radar_ts+1              // MM (0-59)
        ldx #0
pts_div_mm:
        cmp #10
        bcc pts_mm_done
        sec
        sbc #10
        inx
        jmp pts_div_mm
pts_mm_done:
        sta ts_d4
        stx ts_d3
        // ── Set sprite pointers: $43F8=$70, $43F9=$71, $43FA=$72 ────────────
        lda #$70                    // ($5C00-$4000)/64 = $70
        sta $43F8
        lda #$71
        sta $43F9
        lda #$72
        sta $43FA
        // ── Build sprite 0: H1 (tens) + H2 (units) ──────────────────────────
        lda ts_d1
        sta ZP_CHAR0
        lda ts_d2
        sta ZP_CHAR1
        ldx #0
        jsr render_ts_sprite
        // ── Build sprite 1: colon(13) + M1 (tens) ───────────────────────────
        lda #13                     // colon
        sta ZP_CHAR0
        lda ts_d3
        sta ZP_CHAR1
        ldx #1
        jsr render_ts_sprite
        // ── Build sprite 2: M2 (units) + space(12) ──────────────────────────
        lda ts_d4
        sta ZP_CHAR0
        lda #12                     // space
        sta ZP_CHAR1
        ldx #2
        jsr render_ts_sprite
        // ── Y position: near bottom of screen (VIC Y ≈ 228) ─────────────────
        lda #228
        sta $D001
        sta $D003
        sta $D005
        // ── X positions: sprites 0,1,2 right-aligned (all need MSB bit) ──────
        lda #16                     // sprite 0: VIC X = 256+16 = 272
        sta $D000
        lda #32                     // sprite 1: VIC X = 256+32 = 288  (16px step, no gap)
        sta $D002
        lda #48                     // sprite 2: VIC X = 256+48 = 304
        sta $D004
        lda #$07                    // set X MSB for sprites 0,1,2
        sta $D010
        // ── Colors: white (1) for all 3 sprites ──────────────────────────────
        lda #1
        sta $D027
        sta $D028
        sta $D029
        // ── Enable sprites 0,1,2 ─────────────────────────────────────────────
        lda #$07
        sta $D015
        rts

// pr_flip_frame — copy all buffered frame data to display memory.
// Order: bitmap (wipe) → screen colors → color RAM → background.
// Bitmap is copied first so that bottom blocks still show the previous clean
// frame while being overwritten top-to-bottom.  Colors are applied afterwards
// in a single fast pass (~6ms) so the brief new-bitmap/old-palette overlap is
// barely visible and far less jarring than the old-bitmap/new-palette artifact.
// Uses self-modifying hi-bytes; resets them on each call.
pr_flip_frame:
        // ── First frame only: switch to multicolour bitmap mode in VIC bank 1 ──
        // Replaces the "LOADING RADAR IMAGES...." message with the first frame.
        // On frames 2+ this block is skipped to avoid the blank-flash from DEN=0.
        lda pr_first_frame
        beq pr_ff_skip_init
        lda #0
        sta pr_first_frame
        lda $D011
        and #$EF                // blank briefly during one-time switch
        sta $D011
        lda $DD00
        and #$FC
        ora #$02                // VIC bank 1 ($4000-$7FFF)
        sta $DD00
        lda $D011
        ora #$20                // bitmap mode
        sta $D011
        lda $D016
        ora #$10                // multicolour
        sta $D016
        lda #$08                // screen@$4000, bitmap@$6000
        sta $D018
pr_ff_skip_init:

        // ── Bitmap: $8000→$6000 (8000 bytes = 31 pages + 64 bytes) ──
        lda #$80
        sta pr_bs+2
        lda #$60
        sta pr_bd+2
        ldy #31
pr_bpage:
        ldx #0
pr_blp:
pr_bs:  lda $8000,x
pr_bd:  sta $6000,x
        inx
        bne pr_blp
        inc pr_bs+2
        inc pr_bd+2
        dey
        bne pr_bpage
        ldx #63             // remaining 64 bytes ($9F00-$9F3F → $7F00-$7F3F)
pr_btail:
        lda $9F00,x
        sta $7F00,x
        dex
        bpl pr_btail

        // ── Screen colors: $C000→$4000 (exactly 1000 bytes) ─────────────────────
        // 3 full pages (768 bytes) via main loop + 232-byte forward-count tail.
        // Stops at $43E7 so the sprite-pointer area ($43E8-$43FF) is never touched.
        lda #$C0
        sta pr_ss+2
        lda #$40
        sta pr_sd+2
        ldy #3
pr_spage:
        ldx #0
pr_slp:
pr_ss:  lda $C000,x
pr_sd:  sta $4000,x
        inx
        bne pr_slp
        inc pr_ss+2
        inc pr_sd+2
        dey
        bne pr_spage
        // Tail: remaining 232 bytes ($C300-$C3E7 → $4300-$43E7), forward-counting
        ldx #0
pr_stail:
        lda $C300,x
        sta $4300,x
        inx
        cpx #232
        bne pr_stail

        // ── Color RAM: $C400→$D800 (1000 bytes; copy 4 full pages = 1024 bytes,
        //    extra 24 bytes land in $DBE8-$DBFF which is unused color RAM) ────────
        lda #$C4
        sta pr_cs+2
        lda #$D8
        sta pr_cd+2
        ldy #4
pr_cpage:
        ldx #0
pr_clp:
pr_cs:  lda $C400,x
pr_cd:  sta $D800,x
        inx
        bne pr_clp
        inc pr_cs+2
        inc pr_cd+2
        dey
        bne pr_cpage

        // ── Background: $C800[0] → $D021 ──
        lda $C800
        sta $D021
        // Re-enable display (no-op on frames 2+; blanked until now on frame 1)
        lda $D011
        ora #$10
        sta $D011
        rts

pr_done:
        // ── 3. Tear down ──────────────────────────────────────────────────
        lda #0
        sta $D015
        lda $D011
        and #$EF
        sta $D011
        lda #BLACK
        sta $D020               // restore border
        jsr restore_char_mode
        rts

// set_loop_timer — record target time = now + 720 jiffies (12 seconds)
set_loop_timer:
        clc
        lda $A2
        adc #$D0                // 720 & $FF
        sta loop_end_a2
        lda $A1
        adc #$02                // 720 >> 8
        sta loop_end_a1
        lda $A0
        adc #$00
        sta loop_end_a0
        rts

// check_loop_timer — C=1 if current jiffy time >= target; C=0 if not yet
check_loop_timer:
        lda $A0
        cmp loop_end_a0
        bcc clt_no
        bne clt_yes
        lda $A1
        cmp loop_end_a1
        bcc clt_no
        bne clt_yes
        lda $A2
        cmp loop_end_a2
        bcc clt_no
clt_yes:
        sec
        rts
clt_no:
        clc
        rts

// pm_set_alt_timer — set alternating display timer to now + 180 jiffies (3 s)
pm_set_alt_timer:
        clc
        lda $A2
        adc #$B4            // 180 = $B4
        sta pm_alt_a2
        lda $A1
        adc #$00
        sta pm_alt_a1
        lda $A0
        adc #$00
        sta pm_alt_a0
        rts

// pm_check_alt_timer — C=1 if 3-second deadline reached (auto-resets); C=0 if not yet
pm_check_alt_timer:
        lda $A0
        cmp pm_alt_a0
        bcc pcat_no
        bne pcat_yes
        lda $A1
        cmp pm_alt_a1
        bcc pcat_no
        bne pcat_yes
        lda $A2
        cmp pm_alt_a2
        bcc pcat_no
pcat_yes:
        jsr pm_set_alt_timer    // reset for next 3-second cycle
        sec
        rts
pcat_no:
        clc
        rts

// pm_swap_sprites — toggle between temperature labels and weather icon sprites
pm_swap_sprites:
        lda pm_show_icons
        eor #1
        sta pm_show_icons
        bne pss_icons
        // restore temperature sprite pointers ($70–$75) and white colors
        lda #$70
        sta $43F8
        lda #$71
        sta $43F9
        lda #$72
        sta $43FA
        lda #$73
        sta $43FB
        lda #$74
        sta $43FC
        lda #$75
        sta $43FD
        lda #WHITE
        sta $D027
        sta $D028
        sta $D029
        sta $D02A
        sta $D02B
        sta $D02C
        rts
pss_icons:
        // set per-city icon pointers + per-icon colours
        ldx #5
pss_icon_loop:
        lda city_icons,x
        tay
        lda icon_ptrs,y
        sta $43F8,x
        lda icon_colors,y
        sta $D027,x
        dex
        bpl pss_icon_loop
        rts

// update_loop_hint — rewrite "ON "/"OFF" at row 1, col 32 ($0448-$044A)
// "1=CUR 2=FCST 3=RPT 4=MAP 5=RDR 6=LP ON  "
//  col 0                                 ^36
// update_loop_hint — shows what pressing 6 WILL DO:
//   loop off (mode=0) → "ON " (pressing 6 turns it on)
//   loop on  (mode=1) → "OFF" (pressing 6 turns it off)
// Writes 3 bytes at row 1, col 36 = screen RAM $044C-$044E
update_loop_hint:
        lda loop_mode
        bne ulh_running         // loop is on → show "OFF"
        lda #$4F                // loop is off → show "ON "
        sta $044C               // 'O'
        lda #$4E                // 'N'
        sta $044D
        lda #$20                // ' '
        sta $044E
        rts
ulh_running:
        lda #$4F                // 'O'
        sta $044C
        lda #$46                // 'F'
        sta $044D
        lda #$46                // 'F'
        sta $044E
        rts

// restore_koala_sram — re-copy Koala screen RAM to $4000
// Uses MAP_SRAM_BUF ($C500) — the safe copy saved at startup.
restore_koala_sram:
        lda #<MAP_SRAM_BUF
        sta ZP_PTR
        lda #>MAP_SRAM_BUF
        sta ZP_PTRH
        lda #$00
        sta ZP_TMP
        lda #$40
        sta ZP_TMPH
        jsr ckr_1000
        rts

// restore_koala_cram — re-copy Koala colour RAM to $D800 (undoes cls_data)
// Uses MAP_CRAM_BUF ($C8E8) — the safe copy saved at startup.
restore_koala_cram:
        lda #<MAP_CRAM_BUF
        sta ZP_PTR
        lda #>MAP_CRAM_BUF
        sta ZP_PTRH
        lda #$00
        sta ZP_TMP
        lda #$D8
        sta ZP_TMPH
        jsr ckr_1000
        rts

// restore_koala_bitmap — re-copy Koala bitmap to $6000 (undoes radar overwrite)
restore_koala_bitmap:
        lda #<koala_data
        sta ZP_PTR
        lda #>koala_data
        sta ZP_PTRH
        lda #$00
        sta ZP_TMP
        lda #$60
        sta ZP_TMPH
        jsr ckr_8000
        // Falls through into blank_map_bottom_rows.
// blank_map_bottom_rows — zero out bitmap rows 22-24 ($7B80-$7F3F).
//
// Why: koala_data lives at PRG $21BB-$48CB.  show_splash copies the splash
// bitmap to $4000-$5F3F, which clobbers koala_data bytes at PRG $4000-$48CB
// (i.e. bitmap offsets 7749-7999 plus the screen/colour RAM tail).  After
// show_splash returns, ckr_8000 still reads from those clobbered addresses
// and writes garbage (e.g. screen-RAM remnants $50/$6F) to bitmap memory at
// $7E45-$7F3F.  The KLA file has all zeros for bitmap rows 22-24, so it is
// safe to unconditionally blank those rows after every bitmap restore.
blank_map_bottom_rows:
        lda #0
        ldx #0
bmbr_lp:
        sta $7B80,x
        sta $7C80,x
        sta $7D80,x
        sta $7E80,x         // last loop ends at $7F7F (in free VIC-bank-1 area)
        inx
        bne bmbr_lp
        rts

ckr_8000:
        ldx #$1F            // 31 full pages
ckr8_pg:
        ldy #0
ckr8_inner:
        lda (ZP_PTR),y
        sta (ZP_TMP),y
        iny
        bne ckr8_inner
        inc ZP_PTRH
        inc ZP_TMPH
        dex
        bne ckr8_pg
        ldy #0              // 64-byte tail, forward-counting
ckr8_tail:
        lda (ZP_PTR),y
        sta (ZP_TMP),y
        iny
        cpy #64
        bne ckr8_tail
        rts

ckr_1000:
        ldx #3              // 3 full pages
ckr1_pg:
        ldy #0
ckr1_inner:
        lda (ZP_PTR),y
        sta (ZP_TMP),y
        iny
        bne ckr1_inner
        inc ZP_PTRH
        inc ZP_TMPH
        dex
        bne ckr1_pg
        ldy #0              // 232-byte tail, forward-counting
ckr1_tail:
        lda (ZP_PTR),y
        sta (ZP_TMP),y
        iny
        cpy #232
        bne ckr1_tail
        rts

// ─────────────────────────────────────────────────────────────────────────────
// show_splash — display the Buienradar splash screen and wait for Space
//
// Reads splash_data (10001 bytes, no load-address header):
//   [+0]     8000 B  bitmap    → $6000
//   [+8000]  1000 B  screen RAM → $4000
//   [+9000]  1000 B  colour RAM → $D800
//   [+10000] 1 B     bg colour  → $D021/$D020
//
// Called ONCE at boot before copy_koala_to_ram overwrites the same area.
// ─────────────────────────────────────────────────────────────────────────────
show_splash:
        // Use VIC bank 1 ($4000-$7FFF) — no character ROM shadow (only banks 0&2
        // have char ROM at offset $1000 in VIC space).
        //
        // Source bitmap is at ~$45A6; since destination ($4000) < source ($45A6),
        // a forward copy is safe: source pointer always leads destination pointer
        // so we never read a byte that has already been overwritten.
        //
        // Layout:  bitmap@$4000  ($D018 bit3=0)
        //          screen@$6000  (bits7-4=8 → bank_base+$2000)
        //          $D018 = $80

        // ── Copy bitmap → $4000 ──────────────────────────────────────────────
        lda #<splash_data
        sta ZP_PTR
        lda #>splash_data
        sta ZP_PTRH
        lda #$00
        sta ZP_TMP
        lda #$40
        sta ZP_TMPH
        jsr ckr_8000

        // ── Copy screen RAM → $6000 ──────────────────────────────────────────
        // src $64E6 > dst $6000: forward copy safe
        lda #<(splash_data + 8000)
        sta ZP_PTR
        lda #>(splash_data + 8000)
        sta ZP_PTRH
        lda #$00
        sta ZP_TMP
        lda #$60
        sta ZP_TMPH
        jsr ckr_1000

        // ── Copy colour RAM → $D800 ──────────────────────────────────────────
        lda #<(splash_data + 9000)
        sta ZP_PTR
        lda #>(splash_data + 9000)
        sta ZP_PTRH
        lda #$00
        sta ZP_TMP
        lda #$D8
        sta ZP_TMPH
        jsr ckr_1000

        // ── Set background & border colour ───────────────────────────────────
        lda splash_data + 10000
        sta $D021
        sta $D020

        // ── Switch VIC to bank 1, multicolour bitmap mode ────────────────────
        lda $D011
        and #$EF                // blank display while switching
        sta $D011
        lda $DD00
        and #$FC
        ora #$02                // VIC bank 1 ($4000-$7FFF)
        sta $DD00
        lda $D011
        ora #$20                // bitmap mode
        sta $D011
        lda $D016
        ora #$10                // multicolour
        sta $D016
        lda #$80                // screen@$6000, bitmap@$4000
        sta $D018
        lda #$00
        sta $D015               // sprites off
        lda $D011
        ora #$10                // enable display
        sta $D011

        // ── Enable interrupts so keyboard scan works, wait for Space ─────────
        cli
ss_wait:
        jsr $FFE4
        cmp #$20
        bne ss_wait

        // ── Restore text mode ────────────────────────────────────────────────
        jsr restore_char_mode
        rts

// ─────────────────────────────────────────────────────────────────────────────
// restore_char_mode — reverse multicolour bitmap mode, restore text display
// Safe to call even when already in text mode (all operations are idempotent).
// ─────────────────────────────────────────────────────────────────────────────
restore_char_mode:
        // Clear bitmap mode
        lda $D011
        and #$DF
        sta $D011
        // Clear multicolour
        lda $D016
        and #$EF
        sta $D016
        // Switch back to VIC bank 0 ($0000-$3FFF)
        lda $DD00
        and #$FC
        ora #$03
        sta $DD00
        // Restore lowercase/uppercase charset ($D018 = $16)
        lda #$16
        sta $D018
        // Re-enable screen display
        lda $D011
        ora #$10
        sta $D011
        // Restore title bar colours overwritten by Koala colour RAM
        // Row 0 ($D800-$D827, 40 bytes) → CYAN
        lda #CYAN
        ldx #39
rcm_r0: sta $D800,x
        dex
        bpl rcm_r0
        // Row 1 ($D828-$D84F, 40 bytes) → LGREY
        lda #LGREY
        ldx #39
rcm_r1: sta $D828,x
        dex
        bpl rcm_r1
        // Restore border and background to black
        lda #BLACK
        sta $D020
        sta $D021
        rts

// ─────────────────────────────────────────────────────────────────────────────
// do_get — HTTP GET via Network Target raw TCP socket
// Input:  ZP_PTR → null-terminated URL path like "/current\0"
// Output: RXBUF = null-terminated body text
//         Carry clear = got data;  Carry set = empty/error
// Uses STBUF as a temp buffer to assemble the HTTP request
// ─────────────────────────────────────────────────────────────────────────────
do_get:
        // ── Step 1: TCP connect to sqriq1vq6nat10u0.myfritz.net port 8064 ──
        jsr uci_idle
        lda #NET
        sta UCI_CMD
        lda #NET_TCPCON
        sta UCI_CMD
        lda srv_port_lo     // port little-endian (runtime variable)
        sta UCI_CMD
        lda srv_port_hi
        sta UCI_CMD
        // hostname
        ldx #0
dg_host:
        lda srv_host,x
        sta UCI_CMD
        beq dg_host_done
        inx
        bne dg_host
dg_host_done:
        lda #PUSH_CMD
        sta UCI_CTRL
        jsr uci_rdy
        jsr uci_wait_dav
        lda UCI_DATA        // socket handle
        sta ZP_SOCK
        jsr uci_drain_d
        // Read status string into STBUF to check for "00,OK"
        ldy #0
dg_st1: lda UCI_STAT
        and #STAT_AV
        beq dg_st1_done
        lda UCI_SDATA
        cpy #254
        beq dg_st1_skip
        sta STBUF,y
        iny
        jmp dg_st1
dg_st1_skip:
        lda UCI_SDATA
        jmp dg_st1
dg_st1_done:
        lda #0
        sta STBUF,y
        lda #DATA_ACC
        sta UCI_CTRL

        // Check for success: status "00,OK"
        lda STBUF
        cmp #'0'
        beq dg_connect_ok
        jmp dg_fail
dg_connect_ok:

        // ── Step 2: Send HTTP request ─────────────────────────────────────
        // Assemble into STBUF: "GET <path> HTTP/1.0\r\nHost: <host>\r\nConnection: close\r\n\r\n"
        lda #<STBUF
        sta ZP_TMP
        lda #>STBUF
        sta ZP_TMPH

        // Copy "GET "
        lda #<req_get
        sta ZP_RXPTR
        lda #>req_get
        sta ZP_RXHI
        jsr buf_append

        // Copy path from ZP_PTR
        jsr buf_append_ptr

        // Copy " HTTP/1.0\r\nHost: " + srv_host + "\r\nConnection: close\r\n\r\n"
        lda #<req_mid
        sta ZP_RXPTR
        lda #>req_mid
        sta ZP_RXHI
        jsr buf_append
        lda #<srv_host
        sta ZP_RXPTR
        lda #>srv_host
        sta ZP_RXHI
        jsr buf_append
        lda #<req_end
        sta ZP_RXPTR
        lda #>req_end
        sta ZP_RXHI
        jsr buf_append

        // Now send via NET_WRITE
        jsr uci_idle
        lda #NET
        sta UCI_CMD
        lda #NET_WRITE
        sta UCI_CMD
        lda ZP_SOCK
        sta UCI_CMD
        // Send STBUF bytes until null
        lda #<STBUF
        sta ZP_RXPTR
        lda #>STBUF
        sta ZP_RXHI
dg_wr:
        ldy #0
        lda (ZP_RXPTR),y
        beq dg_wr_done
        sta UCI_CMD
        inc ZP_RXPTR
        bne dg_wr
        inc ZP_RXHI
        jmp dg_wr
dg_wr_done:
        lda #PUSH_CMD
        sta UCI_CTRL
        jsr uci_rdy
        jsr uci_drain_d
        jsr uci_drain_s
        lda #DATA_ACC
        sta UCI_CTRL

        // ── Step 3: Read response into RXBUF ─────────────────────────────
        lda #<RXBUF
        sta ZP_RXPTR
        lda #>RXBUF
        sta ZP_RXHI

dg_rd_loop:
        jsr uci_idle
        lda #NET
        sta UCI_CMD
        lda #NET_READ
        sta UCI_CMD
        lda ZP_SOCK
        sta UCI_CMD
        lda #$00            // request 512 bytes ($0200)
        sta UCI_CMD
        lda #$02
        sta UCI_CMD
        lda #PUSH_CMD
        sta UCI_CTRL
        jsr uci_rdy

        // First 2 bytes of data = actual count LSB/MSB
        jsr uci_wait_dav
        lda UCI_DATA
        sta ZP_TMP          // actual_count lo
        jsr uci_wait_dav
        lda UCI_DATA
        sta ZP_TMPH         // actual_count hi

        // $FFFF = UCI "no data yet" signal (same as -1) — drain and retry
        lda ZP_TMP
        cmp #$FF
        bne dg_rd_count_ok
        lda ZP_TMPH
        cmp #$FF
        bne dg_rd_count_ok
        jsr uci_drain_d
        jsr uci_drain_s
        lda #DATA_ACC
        sta UCI_CTRL
        jmp dg_rd_loop      // retry

dg_rd_count_ok:
        // Check for 0 bytes = connection closed
        lda ZP_TMP
        ora ZP_TMPH
        beq dg_rd_done

        // Read that many bytes into RXBUF
        // We track count in ZP_TMP/ZP_TMPH
dg_rd_byte:
        lda ZP_TMP
        ora ZP_TMPH
        beq dg_rd_chunk_done
        jsr uci_wait_dav
        lda UCI_DATA
        ldy #0
        sta (ZP_RXPTR),y
        inc ZP_RXPTR
        bne dg_rd_dec
        inc ZP_RXHI
dg_rd_dec:
        lda ZP_TMP
        bne dg_rd_dec2
        dec ZP_TMPH
dg_rd_dec2:
        dec ZP_TMP
        jmp dg_rd_byte

dg_rd_chunk_done:
        jsr uci_drain_d
        jsr uci_drain_s
        lda #DATA_ACC
        sta UCI_CTRL
        jmp dg_rd_loop      // try to read more

dg_rd_done:
        jsr uci_drain_d
        jsr uci_drain_s
        lda #DATA_ACC
        sta UCI_CTRL

        // ── Step 4: Close socket ──────────────────────────────────────────
        jsr uci_idle
        lda #NET
        sta UCI_CMD
        lda #NET_CLOSE
        sta UCI_CMD
        lda ZP_SOCK
        sta UCI_CMD
        lda #PUSH_CMD
        sta UCI_CTRL
        jsr uci_rdy
        jsr uci_drain_d
        jsr uci_drain_s
        lda #DATA_ACC
        sta UCI_CTRL

        // Null-terminate whatever is in RXBUF at current write pos
        lda #0
        ldy #0
        sta (ZP_RXPTR),y

        // ── Step 5: Strip HTTP headers — copy body to start of RXBUF ─────
        jsr strip_headers

        // ── Step 6: Success check ─────────────────────────────────────────
        lda RXBUF
        bne dg_ok
        sec
        rts
dg_ok:
        clc
        rts

dg_fail:
        // If we timed out, the UCI is in an undefined state — sending a close
        // command would corrupt it further.  Just acknowledge the data channel
        // and return; the firmware will eventually clean up the connection.
        lda timed_out
        bne dg_fail_quick
        jsr uci_idle
        lda #NET
        sta UCI_CMD
        lda #NET_CLOSE
        sta UCI_CMD
        lda ZP_SOCK
        sta UCI_CMD
        lda #PUSH_CMD
        sta UCI_CTRL
        jsr uci_rdy
        jsr uci_drain_d
        jsr uci_drain_s
dg_fail_quick:
        lda #DATA_ACC
        sta UCI_CTRL
        sec
        rts

// ─────────────────────────────────────────────────────────────────────────────
// do_get_binary — HTTP GET, receive 10001-byte raw Koala data
// Input:  ZP_PTR → null-terminated URL path (e.g. "/map\0")
// Output: Koala data written in phases:
//           Phase 1: 8000 bytes → $6000 (bitmap)
//           Phase 2: 1000 bytes → $4000 (VIC screen colours for bank 1)
//           Phase 3: 1000 bytes → $D800 (colour RAM)
//           Phase 4:    1 byte  → $D021 (background colour)
//         Carry clear = success;  Carry set = error
// Uses:   ZP_TMP/ZP_TMPH  (UCI chunk byte count)
//         ZP_RXPTR/ZP_RXHI (destination write pointer)
//         ZP_LFCNT         (consecutive-LF counter for header detection)
//         ZP_PHASE         (phase index: 0=header scan, 1-4=data phases, 5=discard)
//         ZP_CNTLO/ZP_CNTHI (remaining bytes in current phase)
// ─────────────────────────────────────────────────────────────────────────────
do_get_binary:
        // ── Step 1: TCP connect (identical to do_get) ─────────────────────
        jsr uci_idle
        lda #NET
        sta UCI_CMD
        lda #NET_TCPCON
        sta UCI_CMD
        lda srv_port_lo
        sta UCI_CMD
        lda srv_port_hi
        sta UCI_CMD
        ldx #0
dgb_host:
        lda srv_host,x
        sta UCI_CMD
        beq dgb_host_done
        inx
        bne dgb_host
dgb_host_done:
        lda #PUSH_CMD
        sta UCI_CTRL
        jsr uci_rdy
        jsr uci_wait_dav
        lda UCI_DATA
        sta ZP_SOCK
        jsr uci_drain_d
        ldy #0
dgb_st1:
        lda UCI_STAT
        and #STAT_AV
        beq dgb_st1_done
        lda UCI_SDATA
        cpy #254
        beq dgb_st1_skip
        sta STBUF,y
        iny
        jmp dgb_st1
dgb_st1_skip:
        lda UCI_SDATA
        jmp dgb_st1
dgb_st1_done:
        lda #0
        sta STBUF,y
        lda #DATA_ACC
        sta UCI_CTRL
        lda STBUF
        cmp #'0'
        beq dgb_connect_ok
        jmp dgb_fail
dgb_connect_ok:

        // ── Step 2: Assemble and send HTTP GET (identical to do_get) ──────
        lda #<STBUF
        sta ZP_TMP
        lda #>STBUF
        sta ZP_TMPH
        lda #<req_get
        sta ZP_RXPTR
        lda #>req_get
        sta ZP_RXHI
        jsr buf_append
        jsr buf_append_ptr
        lda #<req_mid
        sta ZP_RXPTR
        lda #>req_mid
        sta ZP_RXHI
        jsr buf_append
        lda #<srv_host
        sta ZP_RXPTR
        lda #>srv_host
        sta ZP_RXHI
        jsr buf_append
        lda #<req_end
        sta ZP_RXPTR
        lda #>req_end
        sta ZP_RXHI
        jsr buf_append
        jsr uci_idle
        lda #NET
        sta UCI_CMD
        lda #NET_WRITE
        sta UCI_CMD
        lda ZP_SOCK
        sta UCI_CMD
        lda #<STBUF
        sta ZP_RXPTR
        lda #>STBUF
        sta ZP_RXHI
dgb_wr:
        ldy #0
        lda (ZP_RXPTR),y
        beq dgb_wr_done
        sta UCI_CMD
        inc ZP_RXPTR
        bne dgb_wr
        inc ZP_RXHI
        jmp dgb_wr
dgb_wr_done:
        lda #PUSH_CMD
        sta UCI_CTRL
        jsr uci_rdy
        jsr uci_drain_d
        jsr uci_drain_s
        lda #DATA_ACC
        sta UCI_CTRL

        // ── Step 3: Read response — skip headers, then write binary phases ─
        lda #0
        sta ZP_LFCNT        // reset consecutive-LF counter
        sta ZP_PHASE        // start in phase 0 (header scanning)

dgb_rd_loop:
        jsr uci_idle
        lda #NET
        sta UCI_CMD
        lda #NET_READ
        sta UCI_CMD
        lda ZP_SOCK
        sta UCI_CMD
        lda #$00            // request 256 bytes
        sta UCI_CMD
        lda #$01
        sta UCI_CMD
        lda #PUSH_CMD
        sta UCI_CTRL
        jsr uci_rdy

        // First 2 bytes = actual byte count (lo/hi)
        jsr uci_wait_dav
        lda UCI_DATA
        sta ZP_TMP
        jsr uci_wait_dav
        lda UCI_DATA
        sta ZP_TMPH

        // $FFFF = no data yet → drain and retry
        lda ZP_TMP
        cmp #$FF
        bne dgb_cnt_ok
        lda ZP_TMPH
        cmp #$FF
        bne dgb_cnt_ok
        jsr uci_drain_d
        jsr uci_drain_s
        lda #DATA_ACC
        sta UCI_CTRL
        jmp dgb_rd_loop

dgb_cnt_ok:
        // 0 bytes = connection closed → done
        lda ZP_TMP
        ora ZP_TMPH
        beq dgb_rd_done

dgb_byte:
        lda ZP_TMP
        ora ZP_TMPH
        beq dgb_chunk_done
        jsr uci_wait_dav
        lda UCI_DATA

        // Dispatch on current phase
        ldx ZP_PHASE
        beq dgb_scan_hdr        // phase 0: scan for end of HTTP headers
        cpx #6
        bcs dgb_discard_byte    // phase 6+: discard (all data received)

        // Phases 1-4: write byte to destination
        ldy #0
        sta (ZP_RXPTR),y
        // Advance destination pointer (16-bit)
        inc ZP_RXPTR
        bne dgb_dec_phase_cnt
        inc ZP_RXHI

dgb_dec_phase_cnt:
        // 16-bit decrement of ZP_CNTHI:ZP_CNTLO
        lda ZP_CNTLO
        bne dgb_dpc2
        dec ZP_CNTHI
dgb_dpc2:
        dec ZP_CNTLO
        // Phase complete when both bytes reach zero
        lda ZP_CNTLO
        ora ZP_CNTHI
        bne dgb_dec_chunk       // still bytes remaining
        // Advance to next phase
        inc ZP_PHASE
        lda ZP_PHASE
        cmp #6
        bcs dgb_dec_chunk       // phase 6 = done, no setup needed
        jsr dgb_setup_phase
        jmp dgb_dec_chunk

dgb_scan_hdr:
        // Scan for \r\n\r\n: ignore \r, count consecutive \n
        cmp #$0D
        beq dgb_dec_chunk       // CR: skip
        cmp #$0A
        beq dgb_hdr_lf          // LF: check count
        lda #0
        sta ZP_LFCNT            // any other char: reset LF count
        jmp dgb_dec_chunk

dgb_hdr_lf:
        inc ZP_LFCNT
        lda ZP_LFCNT
        cmp #2
        bcc dgb_dec_chunk       // < 2 LFs: keep scanning
        // Two consecutive LFs found: headers done, begin phase 1
        lda #1
        sta ZP_PHASE
        jsr dgb_setup_phase
        jmp dgb_dec_chunk

dgb_discard_byte:
        // Fall through to chunk-count decrement

dgb_dec_chunk:
        // Decrement actual_count (ZP_TMPH:ZP_TMP)
        lda ZP_TMP
        bne dgb_dct2
        dec ZP_TMPH
dgb_dct2:
        dec ZP_TMP
        jmp dgb_byte

dgb_chunk_done:
        jsr uci_drain_d
        jsr uci_drain_s
        lda #DATA_ACC
        sta UCI_CTRL
        jmp dgb_rd_loop

dgb_rd_done:
        jsr uci_drain_d
        jsr uci_drain_s
        lda #DATA_ACC
        sta UCI_CTRL

        // ── Step 4: Close socket (identical to do_get) ────────────────────
        jsr uci_idle
        lda #NET
        sta UCI_CMD
        lda #NET_CLOSE
        sta UCI_CMD
        lda ZP_SOCK
        sta UCI_CMD
        lda #PUSH_CMD
        sta UCI_CTRL
        jsr uci_rdy
        jsr uci_drain_d
        jsr uci_drain_s
        lda #DATA_ACC
        sta UCI_CTRL
        clc
        rts

dgb_fail:
        lda timed_out
        bne dgb_fail_quick
        jsr uci_idle
        lda #NET
        sta UCI_CMD
        lda #NET_CLOSE
        sta UCI_CMD
        lda ZP_SOCK
        sta UCI_CMD
        lda #PUSH_CMD
        sta UCI_CTRL
        jsr uci_rdy
        jsr uci_drain_d
        jsr uci_drain_s
dgb_fail_quick:
        lda #DATA_ACC
        sta UCI_CTRL
        sec
        rts

// ─────────────────────────────────────────────────────────────────────────────
// dgb_setup_phase — set ZP_RXPTR/ZP_RXHI and ZP_CNTLO/ZP_CNTHI for current phase
// Called when ZP_PHASE transitions to 1, 2, 3, or 4.
// ─────────────────────────────────────────────────────────────────────────────
dgb_setup_phase:
        lda ZP_PHASE
        cmp #2
        beq dgb_sp2
        cmp #3
        beq dgb_sp3
        cmp #4
        beq dgb_sp4
        cmp #5
        beq dgb_sp5
        // Phase 1: bitmap data → 8000 bytes ($1F40) to dgb_bmp_hi:$00
        lda #$40
        sta ZP_CNTLO
        lda #$1F
        sta ZP_CNTHI
        lda #$00
        sta ZP_RXPTR
        lda dgb_bmp_hi      // $60 normally, $80 when radar buffering
        sta ZP_RXHI
        rts
dgb_sp2:
        // Phase 2: screen colour data → 1000 bytes; dgb_scr_hi:$00 ($40=live, $C0=buffer)
        lda #$E8
        sta ZP_CNTLO
        lda #$03
        sta ZP_CNTHI
        lda #$00
        sta ZP_RXPTR
        lda dgb_scr_hi
        sta ZP_RXHI
        rts
dgb_sp3:
        // Phase 3: colour RAM → 1000 bytes; dgb_cram_hi:$00 ($D8=live, $C4=buffer)
        lda #$E8
        sta ZP_CNTLO
        lda #$03
        sta ZP_CNTHI
        lda #$00
        sta ZP_RXPTR
        lda dgb_cram_hi
        sta ZP_RXHI
        rts
dgb_sp4:
        // Phase 4: background colour → 1 byte; dgb_bg_hi:dgb_bg_lo ($D021 or $C800)
        lda #$01
        sta ZP_CNTLO
        lda #$00
        sta ZP_CNTHI
        lda dgb_bg_lo
        sta ZP_RXPTR
        lda dgb_bg_hi
        sta ZP_RXHI
        rts
dgb_sp5:
        // Phase 5: timestamp → 2 bytes (HH, MM) into radar_ts[0..1]
        lda #$02
        sta ZP_CNTLO
        lda #$00
        sta ZP_CNTHI
        lda #<radar_ts
        sta ZP_RXPTR
        lda #>radar_ts
        sta ZP_RXHI
        rts

// ─────────────────────────────────────────────────────────────────────────────
// buf_append — append null-terminated string at ZP_RXPTR/ZP_RXHI
//              to the buffer at ZP_TMP/ZP_TMPH.  Updates ZP_TMP/ZP_TMPH.
// ─────────────────────────────────────────────────────────────────────────────
buf_append:
        ldy #0
        lda (ZP_RXPTR),y
        beq ba_done
        sta (ZP_TMP),y
        inc ZP_RXPTR
        bne ba_p2
        inc ZP_RXHI
ba_p2:  inc ZP_TMP
        bne buf_append
        inc ZP_TMPH
        jmp buf_append
ba_done:
        rts

// buf_append_ptr — append path pointed to by ZP_PTR/ZP_PTRH
buf_append_ptr:
        ldy #0
        lda (ZP_PTR),y
        beq bap_done
        sta (ZP_TMP),y
        inc ZP_PTR
        bne bap_p2
        inc ZP_PTRH
bap_p2: inc ZP_TMP
        bne buf_append_ptr
        inc ZP_TMPH
        jmp buf_append_ptr
bap_done:
        // null-terminate
        lda #0
        sta (ZP_TMP),y
        rts

// ─────────────────────────────────────────────────────────────────────────────
// strip_headers — find \n\n in RXBUF; copy body to start of RXBUF
// After this routine, RXBUF contains only the HTTP body, null-terminated.
// ─────────────────────────────────────────────────────────────────────────────
strip_headers:
        // Scan for \n\n (ignore \r)
        lda #<RXBUF
        sta ZP_RXPTR
        lda #>RXBUF
        sta ZP_RXHI
        lda #0
        sta ZP_LFCNT        // consecutive LF count

sh_scan:
        ldy #0
        lda (ZP_RXPTR),y
        beq sh_notfound     // hit null before headers ended
        cmp #$0D
        beq sh_adv          // CR: skip, don't touch LF count
        cmp #$0A
        bne sh_other
        inc ZP_LFCNT
        lda ZP_LFCNT
        cmp #2
        beq sh_found
        jmp sh_adv

sh_other:
        lda #0
        sta ZP_LFCNT

sh_adv:
        inc ZP_RXPTR
        bne sh_scan
        inc ZP_RXHI
        jmp sh_scan

sh_found:
        // Advance past the second \n
        inc ZP_RXPTR
        bne sh_copy
        inc ZP_RXHI

sh_copy:
        // Copy from ZP_RXPTR to start of RXBUF
        lda #<RXBUF
        sta ZP_TMP
        lda #>RXBUF
        sta ZP_TMPH
sh_cp:
        ldy #0
        lda (ZP_RXPTR),y
        sta (ZP_TMP),y
        beq sh_done
        inc ZP_RXPTR
        bne sh_cp2
        inc ZP_RXHI
sh_cp2:
        inc ZP_TMP
        bne sh_cp
        inc ZP_TMPH
        jmp sh_cp

sh_notfound:
        // No headers found — clear RXBUF (return empty = error)
        lda #0
        sta RXBUF
sh_done:
        rts

// ─────────────────────────────────────────────────────────────────────────────
// UCI helpers
// ─────────────────────────────────────────────────────────────────────────────
// ─────────────────────────────────────────────────────────────────────────────
// arm_timeout_10s — start a 10-second jiffy-clock timeout
// disarm_timeout  — cancel the armed timeout
// Timeout is checked inside uci_idle / uci_rdy / uci_wait_dav.
// 10 s = 600 jiffies = $0258. Uses $A1:$A2 (jiffy mid:lo bytes).
// ─────────────────────────────────────────────────────────────────────────────
arm_timeout_10s:
        lda #0
        sta timed_out       // clear stale timeout flag for this new session
        lda $A2             // jiffy lo
        clc
        adc #$58            // add 600 ($0258) lo byte
        sta to_lo
        lda $A1             // jiffy hi
        adc #$02            // add hi byte + carry
        sta to_hi
        lda #1
        sta to_active
        rts

disarm_timeout:
        lda #0
        sta to_active
        rts

// ─────────────────────────────────────────────────────────────────────────────
// UCI helper routines — all spin-wait loops include a timeout bail-out.
// When to_active=1 and the jiffy deadline has passed, the loop exits.
// Callers (do_get / do_get_binary) will naturally detect the resulting
// garbage state and return carry set.
// ─────────────────────────────────────────────────────────────────────────────
uci_idle:
        lda UCI_STAT
        and #STATE_MASK
        beq ui_done             // STATE_IDLE ($00): UCI is free
        lda timed_out           // timeout already fired this session?
        bne ui_done             //   yes: bail out immediately
        lda to_active
        beq uci_idle            // no timeout armed: keep spinning
        lda $A2                 // check deadline
        sec
        sbc to_lo
        lda $A1
        sbc to_hi
        bcc uci_idle            // deadline not reached: keep spinning
        lda #1                  // deadline reached: mark timed out
        sta timed_out
        lda #0
        sta to_active
ui_done:
        rts

uci_rdy:
        lda UCI_STAT
        and #STATE_MASK
        cmp #STATE_IDLE
        beq ur_chk              // still IDLE: check timeout
        cmp #STATE_BUSY
        bne ur_done             // not IDLE, not BUSY: command accepted
ur_chk:
        lda timed_out
        bne ur_done             // already timed out: bail
        lda to_active
        beq uci_rdy             // no timeout: keep spinning
        lda $A2
        sec
        sbc to_lo
        lda $A1
        sbc to_hi
        bcc uci_rdy             // deadline not reached: keep spinning
        lda #1
        sta timed_out
        lda #0
        sta to_active
ur_done:
        rts

uci_wait_dav:
        lda UCI_STAT
        and #DATA_AV
        bne uwdav_ok            // data available
        lda timed_out           // timeout already fired?
        bne uwdav_to            //   yes: return immediately
        lda to_active
        beq uci_wait_dav        // no timeout armed: keep spinning
        lda $A2
        sec
        sbc to_lo
        lda $A1
        sbc to_hi
        bcc uci_wait_dav        // deadline not reached: keep spinning
        lda #1                  // deadline reached: mark timed out, disarm
        sta timed_out
        lda #0
        sta to_active
uwdav_to:
        rts                     // return without data — caller detects error naturally
uwdav_ok:
        rts

uci_drain_d:
        lda UCI_STAT
        and #DATA_AV
        beq uci_dd_done
        lda UCI_DATA
        jmp uci_drain_d
uci_dd_done:
        rts

uci_drain_s:
        lda UCI_STAT
        and #STAT_AV
        beq uci_ds_done
        lda UCI_SDATA
        jmp uci_drain_s
uci_ds_done:
        rts

// ─────────────────────────────────────────────────────────────────────────────
// show_rx — display null-terminated RXBUF on screen
// ─────────────────────────────────────────────────────────────────────────────
show_rx:
        lda #<RXBUF
        sta ZP_RXPTR
        lda #>RXBUF
        sta ZP_RXHI
srx_nxt:
        ldy #0
        lda (ZP_RXPTR),y
        beq srx_done
        cmp #$0D
        beq srx_skip
        cmp #$0A
        bne srx_print
        lda #0              // reset column to 0 on newline
        sta ZP_COL
        jsr next_row
        jmp srx_skip
srx_print:
        jsr a2s
        jsr put_char
srx_skip:
        inc ZP_RXPTR
        bne srx_nxt
        inc ZP_RXHI
        jmp srx_nxt
srx_done:
        rts

// ─────────────────────────────────────────────────────────────────────────────
// show_rx_paged — like show_rx but pauses every 23 rows for SPACE to continue.
// Uses ZP_PGFULL (set by next_row on overflow) to detect a full screen.
// SPACE advances to next page; any other key stuffs it back for main_loop.
// Also honours loop_mode timer so the carousel isn't stuck waiting.
// ─────────────────────────────────────────────────────────────────────────────
// show_rx_paged — paginated text renderer for page_report.
// Entry: ZP_RXPTR/ZP_RXHI = start of text, ZP_ROW/ZP_COL/ZP_DCOL set by caller.
// Returns C=0 if SPACE was pressed on the last page (caller should restart).
//         C=1 if another key was pressed (stuffed back) or loop timer fired.
// Content is limited to rows 3-23; row 24 is reserved for the prompt.
show_rx_paged:
srxpg_nxt:
        // Pre-check: if ZP_ROW has reached 24, show mid-page prompt before rendering
        lda ZP_ROW
        cmp #24
        bcc srxpg_render        // row < 24: safe to render
        // ── mid-page break: row 24 reached ────────────────────────────────
        lda #0
        sta ZP_COL
        lda #LGREY
        sta ZP_DCOL
        lda #<str_more
        sta ZP_PTR
        lda #>str_more
        sta ZP_PTRH
        jsr pstr
srxpg_wait:
        jsr $FFE4
        bne srxpg_key
        lda loop_mode
        beq srxpg_wait
        jsr check_loop_timer
        bcc srxpg_wait
        sec                     // timer fired
        rts
srxpg_key:
        cmp #$20
        bne srxpg_other
        jsr cls_data            // SPACE: clear and continue
        lda #WHITE
        sta ZP_DCOL
        lda #3
        sta ZP_ROW
        lda #0
        sta ZP_COL
        jmp srxpg_nxt
srxpg_other:
        sta $0277
        lda #1
        sta $00C6
        sec
        rts

srxpg_render:
        lda #0
        sta ZP_PGFULL
        ldy #0
        lda (ZP_RXPTR),y
        beq srxpg_done          // null: end of buffer
        cmp #$0D
        beq srxpg_adv
        cmp #$0A
        bne srxpg_char
        lda #0
        sta ZP_COL
        jsr next_row            // may set ZP_PGFULL
        jmp srxpg_adv
srxpg_char:
        jsr a2s
        jsr put_char            // may set ZP_PGFULL via next_row
srxpg_adv:
        inc ZP_RXPTR
        bne srxpg_nxt
        inc ZP_RXHI
        jmp srxpg_nxt

srxpg_done:
        // Last page shown — display restart prompt
        lda #24
        sta ZP_ROW
        lda #0
        sta ZP_COL
        lda #LGREY
        sta ZP_DCOL
        lda #<str_more_last
        sta ZP_PTR
        lda #>str_more_last
        sta ZP_PTRH
        jsr pstr
srxpg_end_wait:
        jsr $FFE4
        bne srxpg_end_key
        lda loop_mode
        beq srxpg_end_wait
        jsr check_loop_timer
        bcc srxpg_end_wait
        sec                     // timer fired
        rts
srxpg_end_key:
        cmp #$20
        bne srxpg_end_other
        clc                     // SPACE: caller should restart
        rts
srxpg_end_other:
        sta $0277
        lda #1
        sta $00C6
        sec
        rts

str_loading_radar: .text "LOADING RADAR IMAGES...."
                   .byte 0

str_more:      .text " -- SPACE=NEXT PAGE -- "
               .byte 0
str_more_last: .text " -- SPACE=PAGE 1 --    "
               .byte 0

// pstr_oneline — print ZP_PTR string until CR, LF, or null
pstr_oneline:
        ldy #0
        lda (ZP_PTR),y
        beq pol_done
        cmp #$0D
        beq pol_done
        cmp #$0A
        beq pol_done
        jsr a2s
        jsr put_char
        inc ZP_PTR
        bne pstr_oneline
        inc ZP_PTRH
        jmp pstr_oneline
pol_done:
        rts

// ─────────────────────────────────────────────────────────────────────────────
// a2s — ASCII → C64 screen code (lowercase/uppercase charset, $D018=$16)
//
// In the lowercase charset the screen code layout is:
//   $00        '@'
//   $01-$1A    'a'-'z'  (lowercase glyphs)
//   $20-$3F    space and symbols (same as uppercase charset)
//   $41-$5A    'A'-'Z'  (uppercase glyphs)
//
// Mapping applied here:
//   $00-$3F  digits, symbols, space → pass through unchanged
//   $40-$60  '@' and 'A'-'Z'       → pass through unchanged ($41-$5A → uppercase glyphs)
//   $61-$7A  'a'-'z'               → subtract $60 → screen codes $01-$1A (lowercase glyphs)
//   > $7A                          → '?' ($3F)
// ─────────────────────────────────────────────────────────────────────────────
a2s:
        cmp #$40
        bcc a2s_lo          // < $40: digits/symbols → pass through
        beq a2s_at          // == $40: '@' → screen code $00
        cmp #$61
        bcc a2s_up          // $41-$60: uppercase A-Z → pass through
        cmp #$7B
        bcs a2s_hi          // > $7A: map to '?'
        sec
        sbc #$60            // $61-$7A: lowercase a-z → screen codes $01-$1A
        rts
a2s_at: lda #$00            // '@' → screen code $00 (C64 charset '@')
        rts
a2s_lo:
a2s_up: rts
a2s_hi: lda #$3F            // unknown → '?'
        rts

// ─────────────────────────────────────────────────────────────────────────────
// put_char — write screen code A at (ZP_ROW, ZP_COL) with color ZP_DCOL
// ─────────────────────────────────────────────────────────────────────────────
put_char:
        pha
        ldx ZP_ROW
        lda rowlo,x
        clc
        adc ZP_COL
        sta ZP_TMP
        lda rowhi,x
        adc #0
        sta ZP_TMPH
        pla
        ldy #0
        sta (ZP_TMP),y
        lda ZP_TMPH
        clc
        adc #$D4
        sta ZP_TMPH
        lda ZP_DCOL
        sta (ZP_TMP),y
        inc ZP_COL
        lda ZP_COL
        cmp #40
        bcc pch_done
        lda #0
        sta ZP_COL
        jsr next_row
pch_done:
        rts

next_row:
        inc ZP_ROW
        lda ZP_ROW
        cmp #25
        bcc nxr_ok
        lda #24
        sta ZP_ROW
        lda #1                  // signal page overflow to show_rx_paged
        sta ZP_PGFULL
nxr_ok:
        rts

pstr:
        ldy #0
        lda (ZP_PTR),y
        beq pstr_done
        jsr a2s
        jsr put_char
        inc ZP_PTR
        bne pstr
        inc ZP_PTRH
        jmp pstr
pstr_done:
        rts

pstr_rev:
        ldy #0
        lda (ZP_PTR),y
        beq prvr_done
        jsr a2s
        ora #$80
        jsr put_char
        inc ZP_PTR
        bne pstr_rev
        inc ZP_PTRH
        jmp pstr_rev
prvr_done:
        rts

// ─────────────────────────────────────────────────────────────────────────────
// cls — clear entire screen + color RAM
// ─────────────────────────────────────────────────────────────────────────────
cls:
        ldx #0
cls_lp:
        lda #$20
        sta SCR+$000,x
        sta SCR+$100,x
        sta SCR+$200,x
        sta SCR+$2E8,x
        lda #LGREY
        sta CLR+$000,x
        sta CLR+$100,x
        sta CLR+$200,x
        sta CLR+$2E8,x
        inx
        bne cls_lp
        rts

// cls_data — clear rows 2-24 (screen RAM $0450-$07E7, color RAM $D850-$DBE7)
// Each loop uses INX+BNE (or INX+CPX+BNE for non-256-byte ranges) going up
// from X=0, so the N flag is never set prematurely as it would be with DEX+BPL
// when starting from values >= $80.
cls_data:
        lda #$20
        ldx #$00
cds1:   sta $0450,x         // $0450-$04FF (176 bytes: X=0..$AF)
        inx
        cpx #$B0
        bne cds1
        ldx #$00
cds2:   sta $0500,x         // $0500-$05FF (256 bytes)
        inx
        bne cds2
        ldx #$00
cds3:   sta $0600,x         // $0600-$06FF (256 bytes)
        inx
        bne cds3
        ldx #$00
cds4:   sta $0700,x         // $0700-$07E7 (232 bytes: X=0..$E7)
        inx
        cpx #$E8
        bne cds4
        lda #LGREY
        ldx #$00
cdc1:   sta $D850,x         // $D850-$D8FF (176 bytes)
        inx
        cpx #$B0
        bne cdc1
        ldx #$00
cdc2:   sta $D900,x         // $D900-$D9FF (256 bytes)
        inx
        bne cdc2
        ldx #$00
cdc3:   sta $DA00,x         // $DA00-$DAFF (256 bytes)
        inx
        bne cdc3
        ldx #$00
cdc4:   sta $DB00,x         // $DB00-$DBE7 (232 bytes)
        inx
        cpx #$E8
        bne cdc4
        rts

// ─────────────────────────────────────────────────────────────────────────────
// URL paths — stored as raw ASCII bytes (KickAssembler .text converts lowercase
// to PETSCII screen codes, which would break HTTP requests).
// ─────────────────────────────────────────────────────────────────────────────
path_test:  .byte $2F, $00                                        // "/"
path_curr:  .byte $2F,$63,$75,$72,$72,$65,$6E,$74,$00             // "/current"
path_fcst:  .byte $2F,$66,$6F,$72,$65,$63,$61,$73,$74,$00         // "/forecast"
path_rpt:   .byte $2F,$72,$65,$70,$6F,$72,$74,$00                 // "/report"
path_map:   .byte $2F,$6D,$61,$70,$00                             // "/map"
path_temps: .byte $2F,$74,$65,$6D,$70,$73,$00                     // "/temps"
path_radar: .byte $2F,$72,$61,$64,$61,$72,$00                     // "/radar"

// Server hostname — 32-byte mutable buffer (digits, dots, letters, hyphens)
srv_host:   .text "C64.RUNSTOPRESTORE.NL"
            .byte 0,0,0,0,0,0,0,0,0,0  // pad to 32 bytes

// Port as decimal string and binary little-endian (runtime mutable)
srv_port_str:
            .text "8064"
            .byte 0,0                  // 6-byte buffer (max 5 digits + null)
srv_port_lo:
            .byte $80                  // port 8064 = $1F80, lo byte
srv_port_hi:
            .byte $1F                  // hi byte

// HTTP request fragments — all stored as raw ASCII bytes
req_get:    .byte $47,$45,$54,$20,$00      // "GET "
req_mid:
        // " HTTP/1.0\r\nHost: "
        .byte $20,$48,$54,$54,$50,$2F,$31,$2E,$30,$0D,$0A
        .byte $48,$6F,$73,$74,$3A,$20
        .byte $00
req_end:
        // "\r\nConnection: close\r\n\r\n"
        .byte $0D,$0A
        .byte $43,$6F,$6E,$6E,$65,$63,$74,$69,$6F,$6E,$3A,$20
        .byte $63,$6C,$6F,$73,$65
        .byte $0D,$0A
        .byte $0D,$0A
        .byte $00

// ─────────────────────────────────────────────────────────────────────────────
// UI strings
// ─────────────────────────────────────────────────────────────────────────────
str_title:
        .text "C64U WEATHER  BY BUIENRADAR.NL"
        .byte 0
str_help1:
        .text "  1  CURRENT WEATHER CONDITIONS"
        .byte 0
str_help2:
        .text "  2  5-DAY WEATHER FORECAST"
        .byte 0
str_help3:
        .text "  3  DETAILED WEATHER REPORT"
        .byte 0
str_help4:
        .text "  4  MAP WITH CURRENT TEMPERATURES"
        .byte 0
str_help5:
        .text "  5  ANIMATED RAIN RADAR"
        .byte 0
str_help6:
        .text "  6  AUTO-CYCLE ALL SCREENS"
        .byte 0
str_help_e:
        .text "  E  EDIT THE DEFAULT SERVER"
        .byte 0
str_help_back:
        .text "  "
        .byte $1F               // ← back-arrow screen code ($1F in C64 charset)
        .text "  RETURN TO SETUP"
        .byte 0
str_key_mappings:
        .text "KEY MAPPINGS:"
        .byte 0
str_keys:
        .text "1=CUR 2=FCST 3=RPT 4=MAP 5=RDR 6=LP ON  "
        .byte 0
str_uci_ok:
        .text "UCI INTERFACE : OK ($C9)"
        .byte 0
str_ip_lbl:
        .text "C64U IP       : "
        .byte 0
str_srv_lbl:
        .text "SERVER        : "
        .byte 0
str_port_lbl:
        .text "PORT          : "
        .byte 0
str_testing:
        .text "STATUS        : TESTING CONNECTION..."
        .byte 0
str_ok:
        .text "STATUS        : OK - SERVER READY    "
        .byte 0
str_fail:
        .text "STATUS        : FAIL - NO RESPONSE"
        .byte 0
str_resp_lbl:
        .text "SERVER SAYS   : "
        .byte 0
str_anykey:
        .text "PRESS ANY KEY TO LOAD WEATHER DATA"
        .byte 0
str_load:
        .text "FETCHING WEATHER DATA..."
        .byte 0
str_err:
        .text "ERROR - CANNOT REACH WEATHER SERVER"
        .byte 0
str_no_uci:
        .text "NO UCI - NEED UII+ FW 3.10+"
        .byte 0
str_edit_hdr:
        .text "EDIT SERVER ADDRESS"
        .byte 0
str_edit_cur:
        .text "CURRENT : "
        .byte 0
str_edit_prompt:
        .text "NEW     : "
        .byte 0
str_edit_hint:
        .text "FORMAT: HOST:PORT  (RUN/STOP=CANCEL)"
        .byte 0
str_colon:
        .byte $3A,$00           // ":" (raw ASCII, not .text to avoid encoding)

// ─────────────────────────────────────────────────────────────────────────────
// Sprite infrastructure tables
//
// 5 sprites (one per city), single-colour, 24×21 pixels.
// Sprite data lives in VIC bank 1 at:
//   Sprite 0: $5C00  (pointer = ($5C00-$4000)/64 = $70)
//   Sprite 1: $5C40  (pointer = $71)
//   Sprite 2: $5C80  (pointer = $72)
//   Sprite 3: $5CC0  (pointer = $73)
//   Sprite 4: $5D00  (pointer = $74)
// Sprite pointer registers: $43F8-$43FC (screen_ram + $3F8, past Koala screen data)
//
// City order: Groningen, Amsterdam, Utrecht, Rotterdam, Maastricht
// Sprite X/Y are in sprite coordinate units (display area: X=24..343, Y=50..249)
// Label positions derived from canvas coords + border offsets (canvas_x+24, canvas_y+50)
// ─────────────────────────────────────────────────────────────────────────────
spr_ptr_lo: .byte <$5C00, <$5C40, <$5C80, <$5CC0, <$5D00, <$5D40
spr_ptr_hi: .byte >$5C00, >$5C40, >$5C80, >$5CC0, >$5D00, >$5D40

// Icon sprite VIC bank 1 pointers: icon N at $4400+N*$40, ptr = ($4400-$4000+N*$40)/64
icon_ptrs:  .byte $10, $11, $12, $13, $14, $15, $16, $17, $18

// Sprite colour per icon index (0=sun..7=moon, 8=partly-night)
icon_colors: .byte YELLOW, WHITE, WHITE, LGREY, WHITE, WHITE, WHITE, WHITE, WHITE

// Sprite top-left positions
spr_x_tab:  .byte 172, 198, 161, 209, 123, 221  // Utrecht, Maastricht, Den Helder, Groningen, Middelburg, Enschede
spr_y_tab:  .byte 142, 206,  89,  69, 176, 131

temp_values: .byte 0, 0, 0, 0, 0, 0         // fetched temperatures (signed, one per city)
city_icons:  .byte 2, 2, 2, 2, 2, 2         // icon index per city (0-6), from server
pm_show_icons: .byte 0                       // 0=showing temp sprites, 1=showing icon sprites
pr_first_frame: .byte 0                      // 1=first radar frame pending (do VIC mode switch)
pm_alt_a0:   .byte 0                         // alternating timer target (24-bit jiffy, hi)
pm_alt_a1:   .byte 0                         //                                           mid
pm_alt_a2:   .byte 0                         //                                           lo
map_bgcolor: .byte 0                         // Koala background colour, set by copy_koala_to_ram
loop_mode:   .byte 0                         // 0=off, 1=on
to_active:   .byte 0                         // 1 = timeout is armed
to_hi:       .byte 0                         // jiffy deadline high byte ($A1 target)
to_lo:       .byte 0                         // jiffy deadline low byte  ($A2 target)
timed_out:   .byte 0                         // 1 = timeout has already fired this session
loop_page:   .byte 0                         // current loop page: 0=current,1=fcst,2=rpt,3=map
dgb_bmp_hi:  .byte $60    // bitmap dest hi: $60=display $6000, $80=radar buffer $8000
dgb_scr_hi:  .byte $40    // screen colors hi: $40=live $4000, $C0=radar buffer $C000
dgb_cram_hi: .byte $D8    // color RAM hi: $D8=live $D800, $C4=radar buffer $C400
dgb_bg_lo:   .byte $21    // background dest lo: $21 (→$D021 live), $00 (→$C800 buffer)
dgb_bg_hi:   .byte $D0    // background dest hi: $D0 (→$D021 live), $C8 (→$C800 buffer)
radar_ts:    .byte 0, 0  // Phase 5: HH at offset 0, MM at offset 1
ts_d1:       .byte 0     // hours tens digit
ts_d2:       .byte 0     // hours units digit
ts_d3:       .byte 0     // minutes tens digit
ts_d4:       .byte 0     // minutes units digit
loop_end_a0: .byte 0                         // target jiffy clock hi
loop_end_a1: .byte 0                         //                   mid
loop_end_a2: .byte 0                         //                   lo

// ─────────────────────────────────────────────────────────────────────────────
// 8×8 pixel font — indices 0-9 = digits, 10 = 'C', 11 = '-', 12 = ' '
// Each entry is 8 bytes (one byte per row, MSB = leftmost pixel)
// ─────────────────────────────────────────────────────────────────────────────
digit_font:
    .byte $3C,$66,$6E,$76,$66,$66,$3C,$00   // 0
    .byte $18,$38,$18,$18,$18,$18,$7E,$00   // 1
    .byte $3C,$66,$06,$1C,$30,$62,$7E,$00   // 2
    .byte $3C,$66,$06,$1C,$06,$66,$3C,$00   // 3
    .byte $0E,$1E,$36,$66,$7F,$06,$06,$00   // 4
    .byte $7E,$60,$7C,$06,$06,$66,$3C,$00   // 5
    .byte $3C,$60,$7C,$66,$66,$66,$3C,$00   // 6
    .byte $7E,$66,$0C,$18,$18,$18,$18,$00   // 7
    .byte $3C,$66,$66,$3C,$66,$66,$3C,$00   // 8
    .byte $3C,$66,$66,$3E,$06,$66,$3C,$00   // 9
    .byte $3C,$66,$60,$60,$60,$66,$3C,$00   // C  (index 10)
    .byte $00,$00,$00,$7E,$00,$00,$00,$00   // -  (index 11)
    .byte $00,$00,$00,$00,$00,$00,$00,$00   // ' '(index 12)
    .byte $00,$18,$18,$00,$00,$18,$18,$00   // ':' (index 13)

// ─────────────────────────────────────────────────────────────────────────────
// Row base address lookup tables (25 rows)
// ─────────────────────────────────────────────────────────────────────────────
rowlo:
        .byte $00,$28,$50,$78,$A0,$C8,$F0
        .byte $18,$40,$68,$90,$B8,$E0
        .byte $08,$30,$58,$80,$A8,$D0,$F8
        .byte $20,$48,$70,$98,$C0
rowhi:
        .byte $04,$04,$04,$04,$04,$04,$04
        .byte $05,$05,$05,$05,$05,$05
        .byte $06,$06,$06,$06,$06,$06,$06
        .byte $07,$07,$07,$07,$07

// ─────────────────────────────────────────────────────────────────────────────
// Embedded Koala bitmap (blank Netherlands map — no temperature labels)
// Layout: bitmap(8000) + screen_colours(1000) + colour_RAM(1000) + bg_colour(1)
// Generated from netherlands_map.png (green land, blue sea) via server.py
// ─────────────────────────────────────────────────────────────────────────────
koala_data:
    .import binary "netherlands_map_blank.kla"

// ─────────────────────────────────────────────────────────────────────────────
// Splash screen Koala bitmap (Buienradar logo, white background)
// Layout: bitmap(8000) + screen_colours(1000) + colour_RAM(1000) + bg_colour(1)
// Generated by make_splash.py — sits in $45A6-$6CBx, overwritten at runtime.
// ─────────────────────────────────────────────────────────────────────────────
splash_data:
    .import binary "splash.kla"

// ─────────────────────────────────────────────────────────────────────────────
// Weather icon sprite bitmaps — 9 × 64 bytes (24×21 hires, single-colour)
// Copied to VIC bank 1 $4400–$463F at page_map init time.
// Index: 0=sun  1=partly  2=cloudy  3=fog  4=rain  5=snow  6=thunder
//        7=moon  8=partly-night
// ─────────────────────────────────────────────────────────────────────────────
icon_sprite_data:
// ── 0 SUN ────────────────────────────────────────────────────────────────────────────
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$18,$00
        .byte $00,$18,$00
        .byte $02,$00,$40
        .byte $01,$81,$80
        .byte $00,$3C,$00
        .byte $00,$7E,$00
        .byte $00,$FF,$00
        .byte $1E,$FF,$78
        .byte $00,$FF,$00
        .byte $00,$7E,$00
        .byte $00,$BD,$80
        .byte $03,$00,$C0
        .byte $02,$18,$40
        .byte $00,$18,$00
        .byte $00,$18,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00  // padding
// ── 1 PARTLY CLOUDY ────────────────────────────────────────────────────────────
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$80,$00
        .byte $04,$10,$00
        .byte $01,$C0,$00
        .byte $0A,$20,$00
        .byte $02,$6E,$00
        .byte $01,$D1,$00
        .byte $04,$20,$80
        .byte $01,$C0,$C0
        .byte $03,$00,$30
        .byte $02,$00,$10
        .byte $02,$00,$10
        .byte $01,$00,$30
        .byte $00,$7F,$C0
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00  // padding
// ── 2 CLOUDY ────────────────────────────────────────────────────────────────────────────────
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$18,$00
        .byte $00,$7E,$00
        .byte $00,$FF,$00
        .byte $01,$FF,$C0
        .byte $07,$FF,$E0
        .byte $0F,$FF,$F0
        .byte $0F,$FF,$F8
        .byte $0F,$FF,$F8
        .byte $07,$FF,$F0
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00  // padding
// ── 3 FOG ─────────────────────────────────────────────────────────────────────────────
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $03,$FF,$C0
        .byte $00,$00,$00
        .byte $0F,$FF,$F0
        .byte $00,$00,$00
        .byte $01,$FF,$A0
        .byte $07,$FF,$E0
        .byte $00,$00,$00
        .byte $0F,$FF,$F0
        .byte $00,$00,$00
        .byte $03,$FF,$C0
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00  // padding
// ── 4 RAIN ─────────────────────────────────────────────────────────────────────────────
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$18,$00
        .byte $00,$7E,$00
        .byte $00,$FF,$00
        .byte $01,$FF,$C0
        .byte $07,$FF,$E0
        .byte $0F,$FF,$F0
        .byte $0F,$FF,$F8
        .byte $0F,$FF,$F8
        .byte $07,$FF,$F0
        .byte $00,$00,$00
        .byte $01,$11,$00
        .byte $00,$88,$80
        .byte $00,$44,$40
        .byte $00,$22,$20
        .byte $00,$11,$10
        .byte $00,$08,$88
        .byte $00  // padding
// ── 5 SNOW ─────────────────────────────────────────────────────────────────────────────
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$18,$00
        .byte $00,$7E,$00
        .byte $00,$FF,$00
        .byte $01,$FF,$C0
        .byte $07,$FF,$E0
        .byte $0F,$FF,$F0
        .byte $0F,$FF,$F8
        .byte $0F,$FF,$F8
        .byte $07,$FF,$F0
        .byte $01,$01,$00
        .byte $03,$83,$80
        .byte $01,$01,$00
        .byte $00,$00,$00
        .byte $00,$10,$00
        .byte $00,$38,$00
        .byte $00,$10,$00
        .byte $00  // padding
// ── 6 THUNDER ───────────────────────────────────────────────────────────────────────
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$18,$00
        .byte $00,$7E,$00
        .byte $00,$FF,$00
        .byte $01,$FF,$C0
        .byte $07,$FF,$E0
        .byte $07,$FF,$E0
        .byte $03,$FF,$C0
        .byte $00,$00,$00
        .byte $00,$04,$00
        .byte $00,$08,$00
        .byte $00,$10,$00
        .byte $00,$3C,$00
        .byte $00,$02,$00
        .byte $00,$04,$00
        .byte $00,$08,$00
        .byte $00,$00,$00
        .byte $00  // padding
// ── 7 MOON ─────────────────────────────────────────────────────────────────────────────
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$08,$00
        .byte $00,$3F,$80
        .byte $00,$7F,$00
        .byte $00,$F8,$00
        .byte $01,$F0,$00
        .byte $03,$C0,$00
        .byte $03,$C0,$00
        .byte $03,$C0,$00
        .byte $03,$E0,$00
        .byte $03,$C0,$00
        .byte $03,$C0,$00
        .byte $01,$F0,$00
        .byte $00,$F8,$00
        .byte $00,$7F,$00
        .byte $00,$3F,$80
        .byte $00,$08,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00  // padding
// ── 8 PARTLY CLOUDY NIGHT — chunky crescent moon (upper-left) + overlapping cloud
        .byte $00,$00,$00
        .byte $0F,$00,$00
        .byte $1F,$80,$00
        .byte $38,$00,$00
        .byte $30,$00,$00
        .byte $30,$00,$00
        .byte $30,$04,$00
        .byte $30,$0F,$80
        .byte $38,$1F,$E0
        .byte $1F,$3F,$F0
        .byte $0F,$FF,$F8
        .byte $00,$FF,$F8
        .byte $00,$FF,$F8
        .byte $00,$7F,$F0
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00  // padding
// ── 1 Partly Cloudy — asterisk sun (upper-left) + cloud (lower-right) ────
        .byte $00,$00,$00
        .byte $14,$00,$00
        .byte $08,$00,$00
        .byte $14,$00,$00
        .byte $0F,$8F,$00
        .byte $14,$DF,$80
        .byte $08,$FF,$C0
        .byte $14,$FF,$C0
        .byte $0F,$BF,$E0
        .byte $00,$7F,$E0
        .byte $00,$7F,$E0
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00  // padding
// ── 2 Cloudy — three-bump cloud shape ────────────────────────────────────
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $38,$E0,$00
        .byte $7D,$F0,$00
        .byte $FF,$FE,$00
        .byte $FF,$FF,$00
        .byte $FF,$FF,$80
        .byte $7F,$FF,$80
        .byte $3F,$FF,$80
        .byte $1F,$FF,$80
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00  // padding
// ── 3 Fog — four alternating-width horizontal stripes ────────────────────
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $7F,$FF,$E0
        .byte $7F,$FF,$E0
        .byte $00,$00,$00
        .byte $3F,$FF,$E0
        .byte $3F,$FF,$E0
        .byte $00,$00,$00
        .byte $7F,$FF,$E0
        .byte $7F,$FF,$E0
        .byte $00,$00,$00
        .byte $3F,$FF,$E0
        .byte $3F,$FF,$E0
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00  // padding
// ── 4 Rainy — compact cloud + two rows of diagonal streaks ───────────────
        .byte $00,$00,$00
        .byte $03,$C0,$00
        .byte $07,$F8,$00
        .byte $0F,$FC,$00
        .byte $0F,$FC,$00
        .byte $1F,$FE,$00
        .byte $0F,$FC,$00
        .byte $07,$F8,$00
        .byte $00,$00,$00
        .byte $10,$00,$00
        .byte $08,$20,$80
        .byte $04,$10,$40
        .byte $02,$08,$20
        .byte $01,$04,$10
        .byte $00,$00,$00
        .byte $08,$20,$80
        .byte $04,$10,$40
        .byte $02,$08,$20
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00  // padding
// ── 5 Snowy — compact cloud + two rows of asterisk snowflakes ────────────
        .byte $00,$00,$00
        .byte $03,$C0,$00
        .byte $07,$F8,$00
        .byte $0F,$FC,$00
        .byte $0F,$FC,$00
        .byte $1F,$FE,$00
        .byte $0F,$FC,$00
        .byte $07,$F8,$00
        .byte $00,$00,$00
        .byte $11,$10,$00
        .byte $3B,$B8,$00
        .byte $11,$10,$00
        .byte $00,$00,$00
        .byte $08,$88,$00
        .byte $1D,$DC,$00
        .byte $08,$88,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00  // padding
// ── 6 Thunder — compact cloud + prominent zigzag lightning bolt ──────────
        .byte $00,$00,$00
        .byte $03,$C0,$00
        .byte $07,$F8,$00
        .byte $0F,$FC,$00
        .byte $0F,$FC,$00
        .byte $1F,$FE,$00
        .byte $0F,$FC,$00
        .byte $07,$F8,$00
        .byte $00,$00,$00
        .byte $00,$3E,$00
        .byte $00,$7C,$00
        .byte $00,$F8,$00
        .byte $01,$FF,$80
        .byte $00,$F8,$00
        .byte $01,$F0,$00
        .byte $03,$E0,$00
        .byte $07,$C0,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00,$00,$00
        .byte $00  // padding
