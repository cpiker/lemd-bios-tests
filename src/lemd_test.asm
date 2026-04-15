; lemd_test.asm
; Leading Edge Model D - Enhanced Monochrome Graphics Mode Test
;
; This code was generated with Claude, which is an Artificial Intelligence
; service provided by Anthropic. Though design and development was
; orchestrated by a human, reviewed by a human and tested by a human,
; most of the actual code was composed by an AI.
;
; It is completely reasonable to forbid AI generated software in some
; contexts.  Please check the contribution guidelines of any projects you
; participate in. If the project has a rule against AI generated software
; then DO NOT INCLUDE THIS FILE, in whole or in part, in your patches
; or pull requests!
;
; Purpose:
;   Reverse-engineering test for the Leading Edge Model D enhanced
;   monochrome graphics mode. This mode produces 720x348 resolution
;   using a 4-bank interleaved framebuffer at segment 0xB000, with
;   each bank offset by 0x2000 bytes.
;
;   Scanline interleave pattern:
;     Bank 0 (0xB000:0x0000) - scanlines 0, 4,  8,  12, ...
;     Bank 1 (0xB000:0x2000) - scanlines 1, 5,  9,  13, ...
;     Bank 2 (0xB000:0x4000) - scanlines 2, 6,  10, 14, ...
;     Bank 3 (0xB000:0x6000) - scanlines 3, 7,  11, 15, ...
;
;   Each scanline is 90 bytes wide (720 pixels / 8 bits per byte).
;   Row stride within a bank is 90 bytes (0x5A).
;
; Build:
;   nasm -f bin -o lemd_test.com lemd_test.asm
;
; Run:
;   On the Leading Edge Model D under DOS: lemd_test
;
; Assembly syntax: NASM
; Indentation: 8-space tabs (assembly convention)

        org     0x100                   ; DOS .COM files load at CS:0100h

; ============================================================
; CONSTANTS
; ============================================================

; Port addresses
PORT_MDA_MODE   equ     0x3B8           ; MDA mode control register
PORT_MDA_CRTC   equ     0x3B4           ; MDA CRTC address register (6845)
PORT_MDA_CRTC_D equ     0x3B5           ; MDA CRTC data register
PORT_CGA_MODE   equ     0x3D8           ; CGA mode control register
PORT_CGA_COLOR  equ     0x3D9           ; CGA color select register
PORT_LE_CTRL    equ     0x3DD           ; Leading Edge proprietary control

; Mode control values (from diagnose.com disassembly)
MDA_MODE_GRAPH  equ     0x0A            ; MDA mode: graphics + video enable
CGA_MODE_ENH    equ     0x1A            ; CGA mode: graphics + 640-wide + enable
LE_CTRL_ENH     equ     0x08            ; Leading Edge enhanced mono enable bit

; Framebuffer
VIDEO_SEG       equ     0xB000          ; Base video segment (MDA space)
BANK0           equ     0x0000          ; Bank 0 offset: scanlines 0,4,8,...
BANK1           equ     0x2000          ; Bank 1 offset: scanlines 1,5,9,...
BANK2           equ     0x4000          ; Bank 2 offset: scanlines 2,6,10,...
BANK3           equ     0x6000          ; Bank 3 offset: scanlines 3,7,11,...

BYTES_PER_LINE  equ     90              ; 720 pixels / 8 = 90 bytes
LINES_PER_BANK  equ     87              ; 348 scanlines / 4 banks
TOTAL_SCANLINES equ     348

; BIOS equipment word bits
EQUIP_SEG       equ     0x40            ; BIOS data area segment
EQUIP_WORD      equ     0x10            ; equipment flags word offset
EQUIP_MDA_BITS  equ     0x30            ; bits [5:4] = 11 means MDA

; CRTC register table (16 registers R0-R15)
; Extracted from diagnose.com binary at offset 0x25BE
; Programs the MC6845 for 720x348 enhanced mono mode
CRTC_REG_COUNT  equ     16

; ============================================================
; CRTC register table
; These values were extracted from diagnose.com and program
; the MC6845 CRTC for the enhanced mono mode timing.
; R0  = 0x35  Horizontal Total      (53 chars)
; R1  = 0x2D  Horizontal Displayed  (45 chars * 16px = 720px)
; R2  = 0x2E  Horizontal Sync Pos
; R3  = 0x07  Sync Widths
; R4  = 0x5B  Vertical Total        (91 char rows)
; R5  = 0x02  Vertical Total Adjust (2 scanlines)
; R6  = 0x57  Vertical Displayed    (87 rows * 4 scanlines = 348)
; R7  = 0x57  Vertical Sync Pos
; R8  = 0x02  Interlace Mode
; R9  = 0x03  Max Scan Line Address (4 scanlines per char row)
; R10 = 0x00  Cursor Start          (cursor off)
; R11 = 0x00  Cursor End
; R12 = 0x00  Start Address High
; R13 = 0x00  Start Address Low
; R14 = 0x00  Cursor Address High
; R15 = 0x00  Cursor Address Low
; ============================================================

; ============================================================
; ENTRY POINT
; ============================================================
start:
        ; Save the current video mode so we can restore it on exit.
        ; INT 10h AH=0Fh returns current mode in AL, active page in BH.
        mov     ah, 0x0F
        int     0x10
        push    ax                      ; save mode (AL) and page (BH)

        call    set_enhanced_mono       ; activate the LE enhanced mono mode

; ------------------------------------------------------------
; STEP 1: Fill each bank with a distinct pattern.
;
;   Bank 0 = 0x55 (alternating bits: 01010101) - sparse dots
;   Bank 1 = 0xAA (alternating bits: 10101010) - complementary dots
;   Bank 2 = 0xFF (all ones)                   - solid white
;   Bank 3 = 0x00 (all zeros)                  - solid black
;
; If our bank map is correct you should see horizontal stripes
; cycling through the four patterns every 4 scanlines.
; The solid-black bank 3 will appear as dark gaps.
; ------------------------------------------------------------
        call    fill_banks_distinct

        call    wait_key                ; photograph this, then press a key

; ------------------------------------------------------------
; STEP 2: Draw one bright horizontal line at the TOP of each
; bank (offset 0 within the bank = first row in that bank).
;
;   Bank 0 row 0 = screen scanline 0   (very top)
;   Bank 1 row 0 = screen scanline 1   (one below top)
;   Bank 2 row 0 = screen scanline 2
;   Bank 3 row 0 = screen scanline 3
;
; Then draw a line at the BOTTOM of each bank:
;   Bank 0 last row = scanline 344
;   Bank 1 last row = scanline 345
;   Bank 2 last row = scanline 346
;   Bank 3 last row = scanline 347
;
; This should show 4 lines packed at the very top and 4 at the
; very bottom, confirming the scanline-to-bank mapping.
; ------------------------------------------------------------
        call    clear_screen
        call    draw_bank_lines

        call    wait_key

; ------------------------------------------------------------
; STEP 3: Draw a vertical gradient - fill each group of 4
; scanlines with increasing brightness (byte value) stepping
; from 0x00 at the top to 0xFF at the bottom.
;
; This confirms that the row stride (90 bytes) is correct and
; that scanlines are in the right vertical order.
; ------------------------------------------------------------
        call    clear_screen
        call    draw_gradient

        call    wait_key

; ------------------------------------------------------------
; Restore original video mode and exit to DOS.
; ------------------------------------------------------------
        pop     ax                      ; restore saved mode/page
        xor     ah, ah                  ; AH=0 = set video mode
        int     0x10                    ; restore original mode

        mov     ax, 0x4C00              ; DOS exit, return code 0
        int     0x21


; ============================================================
; set_enhanced_mono
;
; Activates the Leading Edge Model D enhanced monochrome
; graphics mode. This sequence was reverse engineered from
; diagnose.com.
;
; The mode uses MDA-space video RAM (0xB000) but is activated
; through a combination of CGA-style port writes plus a
; proprietary Leading Edge control port (0x3DD).
;
; Trashes: AX, BX, CX, DX, ES
; ============================================================
set_enhanced_mono:
        ; Tell the BIOS this is a monochrome adapter by setting
        ; bits [5:4] of the equipment word to 11b (= MDA).
        ; diagnose.com does this before programming the CRTC.
        mov     ax, EQUIP_SEG
        mov     es, ax
        or      word [es:EQUIP_WORD], EQUIP_MDA_BITS

        ; Program the MC6845 CRTC with the 16 timing registers.
        ; The CRTC address port (0x3B4) selects the register,
        ; then the data port (0x3B5) receives the value.
        mov     cx, CRTC_REG_COUNT
        mov     si, crtc_table
        xor     bl, bl                  ; BL = register index, start at 0
.crtc_loop:
        mov     dx, PORT_MDA_CRTC       ; address port
        mov     al, bl
        out     dx, al                  ; select register
        inc     dx                      ; now points to data port (0x3B5)
        mov     al, [cs:si]             ; load register value from table
        out     dx, al                  ; write value
        inc     si
        inc     bl
        loop    .crtc_loop

        ; Set MDA mode control: graphics enable + video enable.
        ; Bit 1 = graphics mode, Bit 3 = video signal enable.
        mov     dx, PORT_MDA_MODE
        mov     al, MDA_MODE_GRAPH      ; 0x0A
        out     dx, al

        ; Set CGA mode control: graphics + 640-wide + enable.
        ; Bit 1 = graphics, Bit 3 = enable, Bit 4 = 640px wide.
        mov     dx, PORT_CGA_MODE
        mov     al, CGA_MODE_ENH        ; 0x1A
        out     dx, al

        ; Clear CGA color select register.
        mov     dx, PORT_CGA_COLOR
        xor     al, al
        out     dx, al

        ; Assert the Leading Edge proprietary enhanced mode bit.
        ; Port 0x3DD is not present on standard CGA or MDA cards.
        ; Bit 3 (0x08) enables the enhanced mono graphics mode.
        ;
        ; We write 0x08 directly rather than doing a read-modify-write
        ; because it is not known whether port 0x3DD supports reads.
        ; Reading an output-only port returns unpredictable values on
        ; XT-era hardware; ORing garbage back in could set unknown bits.
        ; diagnose.com writes a known value here too, so we follow suit.
        mov     dx, PORT_LE_CTRL
        mov     al, LE_CTRL_ENH         ; 0x08 - enhanced mono enable only
        out     dx, al

        ret


; ============================================================
; clear_screen
;
; Zeroes the entire framebuffer: all 4 banks, 87 rows each,
; 90 bytes per row = 32,670 bytes total across 0xB000:0000
; through 0xB000:7FFF (technically only ~0x7D20 bytes used
; but we zero the full 0x8000 for safety).
;
; Trashes: AX, CX, DI, ES
; ============================================================
clear_screen:
        mov     ax, VIDEO_SEG
        mov     es, ax
        xor     di, di
        xor     ax, ax
        mov     cx, 0x4000              ; 0x8000 bytes / 2 (stosw is word)
        cld
        rep     stosw
        ret


; ============================================================
; fill_banks_distinct
;
; Fills each bank with a different byte pattern so the 4-bank
; interleave is visually apparent. Clears first, then fills.
;
; Bank 0 -> 0x55, Bank 1 -> 0xAA, Bank 2 -> 0xFF, Bank 3 -> 0x00
;
; Trashes: AX, BX, CX, DI, ES
; ============================================================
fill_banks_distinct:
        mov     ax, VIDEO_SEG
        mov     es, ax

        ; Bank 0 = 0x5555
        mov     di, BANK0
        mov     ax, 0x5555
        mov     cx, 0x0FA0              ; 87 rows * 90 bytes / 2 words
        cld
        rep     stosw

        ; Bank 1 = 0xAAAA
        mov     di, BANK1
        mov     ax, 0xAAAA
        mov     cx, 0x0FA0
        rep     stosw

        ; Bank 2 = 0xFFFF
        mov     di, BANK2
        mov     ax, 0xFFFF
        mov     cx, 0x0FA0
        rep     stosw

        ; Bank 3 = 0x0000 (already zeroed but be explicit)
        mov     di, BANK3
        xor     ax, ax
        mov     cx, 0x0FA0
        rep     stosw

        ret


; ============================================================
; draw_bank_lines
;
; Draws a solid white line (0xFF) at the first and last row
; of each bank, to confirm scanline-to-bank assignment.
;
; First row of each bank:
;   Bank 0 offset 0x0000 = screen scanline 0
;   Bank 1 offset 0x2000 = screen scanline 1
;   Bank 2 offset 0x4000 = screen scanline 2
;   Bank 3 offset 0x6000 = screen scanline 3
;
; Last row of each bank:
;   Bank 0 offset 0x0000 + 86*90 = 0x1E6C = scanline 344
;   Bank 1 offset 0x2000 + 86*90 = 0x3E6C = scanline 345
;   Bank 2 offset 0x4000 + 86*90 = 0x5E6C = scanline 346
;   Bank 3 offset 0x6000 + 86*90 = 0x7E6C = scanline 347
;
; Trashes: AX, CX, DI, ES
; ============================================================
draw_bank_lines:
        mov     ax, VIDEO_SEG
        mov     es, ax
        mov     ax, 0xFFFF              ; all pixels on

        ; Bank 0, first row (scanline 0)
        mov     di, BANK0
        mov     cx, BYTES_PER_LINE / 2
        rep     stosw

        ; Bank 1, first row (scanline 1)
        mov     di, BANK1
        mov     cx, BYTES_PER_LINE / 2
        rep     stosw

        ; Bank 2, first row (scanline 2)
        mov     di, BANK2
        mov     cx, BYTES_PER_LINE / 2
        rep     stosw

        ; Bank 3, first row (scanline 3)
        mov     di, BANK3
        mov     cx, BYTES_PER_LINE / 2
        rep     stosw

        ; Last row offset within a bank = (LINES_PER_BANK - 1) * BYTES_PER_LINE
        ;                                = 86 * 90 = 7740 = 0x1E3C
        ; (We store this as a constant to avoid runtime multiply on 8088.)
        ; Bank 0, last row (scanline 344)
        mov     di, BANK0 + (LINES_PER_BANK - 1) * BYTES_PER_LINE
        mov     cx, BYTES_PER_LINE / 2
        rep     stosw

        ; Bank 1, last row (scanline 345)
        mov     di, BANK1 + (LINES_PER_BANK - 1) * BYTES_PER_LINE
        mov     cx, BYTES_PER_LINE / 2
        rep     stosw

        ; Bank 2, last row (scanline 346)
        mov     di, BANK2 + (LINES_PER_BANK - 1) * BYTES_PER_LINE
        mov     cx, BYTES_PER_LINE / 2
        rep     stosw

        ; Bank 3, last row (scanline 347)
        mov     di, BANK3 + (LINES_PER_BANK - 1) * BYTES_PER_LINE
        mov     cx, BYTES_PER_LINE / 2
        rep     stosw

        ret


; ============================================================
; draw_gradient
;
; Fills the screen with a vertical gradient. Each group of 4
; scanlines (one row per bank) gets the same fill byte, which
; increases from 0x00 at the top to 0xFF at the bottom.
;
; With 87 rows and a 0-255 range we step by ~3 per row.
; We use a simple approach: row_value = (row_index * 3) & 0xFF
;
; Trashes: AX, BX, CX, DX, DI, SI, ES
; ============================================================
draw_gradient:
        mov     ax, VIDEO_SEG
        mov     es, ax

        xor     bx, bx                  ; BX = row index (0..86)
        xor     si, si                  ; SI = byte offset into each bank

.row_loop:
        ; Compute fill value: BX * 3, truncated to 8 bits.
        mov     ax, bx
        mov     dx, 3
        mul     dx                      ; AX = row * 3
        mov     ah, al                  ; replicate byte into both halves of AX
                                        ; so stosw fills both bytes identically

        mov     cx, BYTES_PER_LINE / 2  ; 45 words per scanline

        ; Write same value into all 4 banks at this row offset.
        mov     di, si
        add     di, BANK0
        rep     stosw

        mov     di, si
        add     di, BANK1
        mov     cx, BYTES_PER_LINE / 2
        rep     stosw

        mov     di, si
        add     di, BANK2
        mov     cx, BYTES_PER_LINE / 2
        rep     stosw

        mov     di, si
        add     di, BANK3
        mov     cx, BYTES_PER_LINE / 2
        rep     stosw

        add     si, BYTES_PER_LINE      ; advance to next row within banks
        inc     bx
        cmp     bx, LINES_PER_BANK
        jl      .row_loop

        ret


; ============================================================
; wait_key
;
; Waits for a keystroke using BIOS INT 16h.
; Trashes: AX
; ============================================================
wait_key:
        xor     ah, ah                  ; AH=0 = wait for keypress
        int     0x16
        ret


; ============================================================
; Data
; ============================================================

; MC6845 CRTC register values for 720x348 enhanced mono mode.
; Extracted from diagnose.com, file offset 0x25BE.
crtc_table:
        db      0x35    ; R0  Horizontal Total
        db      0x2D    ; R1  Horizontal Displayed (45 chars)
        db      0x2E    ; R2  Horizontal Sync Position
        db      0x07    ; R3  Sync Widths
        db      0x5B    ; R4  Vertical Total
        db      0x02    ; R5  Vertical Total Adjust
        db      0x57    ; R6  Vertical Displayed (87 rows)
        db      0x57    ; R7  Vertical Sync Position
        db      0x02    ; R8  Interlace Mode
        db      0x03    ; R9  Max Scan Line Address (4 lines/row)
        db      0x00    ; R10 Cursor Start (off)
        db      0x00    ; R11 Cursor End
        db      0x00    ; R12 Start Address High
        db      0x00    ; R13 Start Address Low
        db      0x00    ; R14 Cursor Address High
        db      0x00    ; R15 Cursor Address Low
