; =============================================================================
; lemd_test.asm
; Leading Edge Model D -- Enhanced Monochrome Graphics Mode Test Program
;
; Target:    IBM PC compatible, Leading Edge Model D hardware
; Assembler: NASM (nasm -f bin -o lemd_test.com lemd_test.asm)
; Format:    DOS COM (single segment, org 0x100)
; CPU:       8088 / 8086
;
; Purpose:
;   Exercises the 720x348 enhanced monochrome graphics mode by cycling
;   through a series of visual tests, each designed to verify that pixel
;   addresses are being computed correctly for the hardware's unusual
;   four-bank interleaved framebuffer.
;
;   Press any key to advance through the test sequence.
;   ESC at any prompt exits and restores text mode.
;
; Test sequence:
;   1. Clear screen (all dark) -- baseline
;   2. Border + grid           -- verifies pixel address formula
;   3. Bank isolation          -- fills each bank with distinct pattern
;   4. Scanline stripes        -- one lit row per bank, confirms interleave
;   5. Restore text mode and exit
;
; Framebuffer quick reference (from lemd_enhanced_mono_spec.md):
;   Segment:      0xB000
;   Banks:        4, at offsets 0x0000 / 0x2000 / 0x4000 / 0x6000
;   Scanlines:    348 total, 87 per bank
;   Bytes/line:   90 (720 pixels / 8 bits per byte)
;   Interleave:   scanline Y goes to bank (Y AND 3), row (Y SHR 2)
;   Byte offset:  (bank * 0x2000) + (row * 90) + (x / 8)
;   Bit mask:     0x80 SHR (x AND 7)   -- bit 7 is leftmost pixel
; =============================================================================

	org	0x100

; -----------------------------------------------------------------------------
; Constants
; -----------------------------------------------------------------------------

; Screen geometry
SCREEN_W	equ	720		; pixels wide
SCREEN_H	equ	348		; pixels tall
BYTES_PER_ROW	equ	90		; 720 / 8
ROWS_PER_BANK	equ	87		; 348 / 4
BANK_STRIDE	equ	0x2000		; bytes between bank base addresses

; Framebuffer
VID_SEG		equ	0xB000

; Hardware ports
PORT_CRTC_ADDR	equ	0x3B4		; MC6845 register index
PORT_CRTC_DATA	equ	0x3B5		; MC6845 register value
PORT_MDA_MODE	equ	0x3B8		; MDA mode control
PORT_CGA_MODE	equ	0x3D8		; CGA mode control
PORT_CGA_COLOR	equ	0x3D9		; CGA color select
PORT_LE_CTRL	equ	0x3DD		; Leading Edge proprietary enable

; BIOS
BIOS_DATA_SEG	equ	0x40
BIOS_EQUIP_OFF	equ	0x10		; equipment word offset in BDA

; Grid parameters for test 2
; Vertical lines every 90 pixels: x = 0, 90, 180, 270, 360, 450, 540, 630, 719
; Horizontal lines every 58 scanlines: y = 0, 58, 116, 174, 232, 290, 347
GRID_X_STEP	equ	90
GRID_Y_STEP	equ	58

; =============================================================================
; Entry point
; =============================================================================

start:
	; Save the original equipment word so we can restore it on exit.
	; We store it in our own data area (orig_equip) for safekeeping.
	mov	ax, BIOS_DATA_SEG
	mov	es, ax
	mov	ax, [es:BIOS_EQUIP_OFF]
	mov	[orig_equip], ax

	; Activate the enhanced monochrome graphics mode.
	call	set_lemd_mode

	; ---- Test 1: Clear screen ----
	; Writing all zeros makes every pixel dark.  This is the baseline --
	; if the screen is not completely dark, something wrote to video RAM
	; before us (e.g. the BIOS left text-mode data in the MDA region).
	call	clear_screen
	call	wait_key
	jz	.exit			; ESC -> exit

	; ---- Test 2: Border + grid ----
	; Draws a single-pixel border around the screen perimeter, then
	; adds interior vertical and horizontal grid lines at fixed intervals.
	;
	; What to look for:
	;   - The border should form a clean rectangle touching all four edges.
	;     If a side is missing or misplaced, the bank/row calculation is
	;     wrong for that range of Y values.
	;   - Interior lines should be evenly spaced.  A line that appears at
	;     the wrong position means the multiply-by-90 is accumulating error,
	;     or the bank selection is incorrect for some Y.
	call	clear_screen
	call	draw_grid
	call	wait_key
	jz	.exit

	; ---- Test 3: Bank isolation ----
	; Fills each of the four banks with a distinct solid byte pattern:
	;   Bank 0 (scanlines 0,4,8,...):  0xFF (all pixels on)
	;   Bank 1 (scanlines 1,5,9,...):  0x55 (alternating, leftmost ON)
	;   Bank 2 (scanlines 2,6,10,...): 0xAA (alternating, leftmost OFF)
	;   Bank 3 (scanlines 3,7,11,...): 0x00 (all pixels off)
	;
	; What to look for:
	;   - You should see horizontal stripes cycling across the full height
	;     of the screen in groups of 4 scanlines.
	;   - The stripe sequence top-to-bottom repeats: solid / dashed / dashed
	;     (opposite phase) / dark, then repeats.
	;   - If you see large solid blocks rather than 4-line stripes, the
	;     interleave is not working -- the hardware may be treating banks
	;     differently than expected, or we have the wrong CRTC values.
	call	fill_banks
	call	wait_key
	jz	.exit

	; ---- Test 4: Scanline stripes ----
	; Lights exactly ONE row within each bank (the first row of each bank,
	; i.e., scanlines 0, 1, 2, 3), leaving all other rows dark.
	;
	; The result should be four thin bright lines near the top of the
	; screen (scanlines 0-3 are the first four physical lines), followed
	; by darkness.  This is a quick sanity check that "row 0 of each bank"
	; really does correspond to the topmost four scanlines.
	;
	; If the lines appear somewhere other than the very top, the start
	; address registers (R12/R13) may be non-zero, or the bank offsets
	; are wrong.
	call	clear_screen
	call	draw_scanline_stripes
	call	wait_key
	; fall through to exit regardless of key

.exit:
	call	restore_text_mode
	; DOS terminate
	mov	ax, 0x4C00
	int	0x21

; =============================================================================
; set_lemd_mode
; Activate the Leading Edge enhanced 720x348 monochrome graphics mode.
; Sequence sourced from diagnose.com disassembly (lemd_enhanced_mono_spec.md).
; Caller must have saved the original equipment word before calling.
; =============================================================================
set_lemd_mode:
	; -- Step 1: BIOS equipment word --
	; Bits [5:4] = 11b tells the BIOS this machine has an MDA adapter.
	; We OR rather than assign to preserve any other bits the BIOS uses.
	; (Ambiguity A1: may not be strictly required, but matches diagnose.com.)
	mov	ax, BIOS_DATA_SEG
	mov	es, ax
	or	word [es:BIOS_EQUIP_OFF], 0x0030

	; -- Step 2: Program the MC6845 CRTC --
	; The MC6845 is the display timing chip.  It controls horizontal and
	; vertical sync frequencies, the number of displayed rows, and how many
	; scan lines make up each character row (which we repurpose as 4 scan
	; lines per "row" in graphics mode).
	;
	; We write 16 registers (R0-R15) by sending the register index to the
	; address port (0x3B4), then the value to the data port (0x3B5).
	mov	si, crtc_table		; SI -> table of (index, value) pairs
	mov	cx, 16			; 16 registers to program
.crtc_loop:
	mov	dx, PORT_CRTC_ADDR
	mov	al, [si]		; register index
	out	dx, al
	inc	dx			; dx = PORT_CRTC_DATA (0x3B5)
	mov	al, [si+1]		; register value
	out	dx, al
	add	si, 2			; advance to next pair
	loop	.crtc_loop

	; -- Step 3: MDA Mode Control (0x3B8) --
	; 0x0A = 0000 1010b
	;   bit 1 = 1: graphics mode (not text)
	;   bit 3 = 1: video signal enabled
	mov	dx, PORT_MDA_MODE
	mov	al, 0x0A
	out	dx, al

	; -- Step 4: CGA Mode Control (0x3D8) --
	; 0x1A = 0001 1010b
	;   bit 1 = 1: graphics mode
	;   bit 3 = 1: video enable
	;   bit 4 = 1: 640-pixel wide mode
	; (Ambiguity A2: reason for writing both MDA and CGA ports is unknown.)
	mov	dx, PORT_CGA_MODE
	mov	al, 0x1A
	out	dx, al

	; -- Step 5: CGA Color Select (0x3D9) --
	; Zero it out; we're in mono mode, color selection is irrelevant.
	mov	dx, PORT_CGA_COLOR
	xor	al, al
	out	dx, al

	; -- Step 6: Leading Edge proprietary enable (0x3DD) --
	; This register does not exist on standard CGA or MDA hardware.
	; Bit 3 = 1 is the magic bit that actually enables enhanced mono mode.
	; Without this write the CRTC programming above has no visible effect.
	; (Ambiguity A3: other bits unknown; A4: readability unknown.)
	mov	dx, PORT_LE_CTRL
	mov	al, 0x08
	out	dx, al

	ret

; =============================================================================
; restore_text_mode
; Return to MDA 80x25 text mode via INT 10h.
; The BIOS equipment word is restored first so INT 10h picks the right mode.
; =============================================================================
restore_text_mode:
	; Restore the equipment word we saved at startup.
	mov	ax, BIOS_DATA_SEG
	mov	es, ax
	mov	ax, [orig_equip]
	mov	[es:BIOS_EQUIP_OFF], ax

	; INT 10h AH=0, AL=7: set video mode 7 (MDA 80x25 mono text).
	; This also re-initializes the CRTC to standard MDA timing, which
	; un-does our custom register programming above.
	xor	ah, ah
	mov	al, 0x07
	int	0x10
	ret

; =============================================================================
; clear_screen
; Fill the entire 32KB framebuffer region with 0x00 (all pixels off).
; We clear all 0x8000 bytes including the unused tail region beyond the
; active pixel data -- easier and harmless.
; On 8088, REP STOSW is the fastest way to fill memory.
; =============================================================================
clear_screen:
	push	es
	mov	ax, VID_SEG
	mov	es, ax
	xor	di, di			; ES:DI = 0xB000:0x0000
	xor	ax, ax			; fill value = 0x0000
	mov	cx, 0x4000		; 0x8000 bytes / 2 = 0x4000 words
	cld
	rep	stosw
	pop	es
	ret

; =============================================================================
; draw_grid
; Draws a border (first/last row, first/last column of pixels) and interior
; grid lines at fixed pixel intervals.
;
; Horizontal lines at y = 0, GRID_Y_STEP, 2*GRID_Y_STEP, ..., SCREEN_H-1
; Vertical lines   at x = 0, GRID_X_STEP, 2*GRID_X_STEP, ..., SCREEN_W-1
;
; The interior lines cross at predictable coordinates, making it easy to
; verify that the address formula is correct across all four banks.
; =============================================================================
draw_grid:
	; ---- Draw horizontal lines ----
	; For a horizontal line, all bytes in that row's 90-byte span are 0xFF.
	; We can write a full row efficiently without per-pixel plotting.
	;
	; We iterate Y values at GRID_Y_STEP intervals, plus the last row.

	xor	bx, bx			; BX = current Y
.hline_loop:
	call	fill_hline		; fill row BX with 0xFF
	cmp	bx, SCREEN_H-1
	je	.hlines_done
	add	bx, GRID_Y_STEP
	cmp	bx, SCREEN_H-1
	jle	.hline_loop
	mov	bx, SCREEN_H-1		; ensure we always draw the last row
	jmp	.hline_loop
.hlines_done:

	; ---- Draw vertical lines ----
	; A vertical line means setting one specific bit in each of the 348
	; rows.  We step through all Y values and call plot_pixel for each.

	xor	si, si			; SI = current X
.vline_loop:
	xor	bx, bx			; BX = Y, iterate all rows
.vline_y:
	mov	ax, si			; AX = X
	call	plot_pixel
	inc	bx
	cmp	bx, SCREEN_H
	jl	.vline_y

	cmp	si, SCREEN_W-1
	je	.vlines_done
	add	si, GRID_X_STEP
	cmp	si, SCREEN_W-1
	jle	.vline_loop
	mov	si, SCREEN_W-1		; ensure we always draw the last column
	jmp	.vline_loop
.vlines_done:
	ret

; =============================================================================
; fill_hline  (helper for draw_grid)
; Fill all 90 bytes of scanline BX with 0xFF (all pixels on).
;
; Offset formula:
;   bank   = BX AND 3
;   row    = BX SHR 2
;   offset = (bank * 0x2000) + (row * 90)
;
; row * 90 is computed as row*64 + row*16 + row*8 + row*2, using only
; left-shifts and adds.  This avoids MUL, which is slow on the 8088 and
; would clobber DX.
;
; Trashes: AX, CX, DX, DI, ES
; =============================================================================
fill_hline:
	push	bx

	; ---- bank * 0x2000 ----
	mov	ax, bx
	and	ax, 3			; AX = bank (0-3)
	mov	cl, 13
	shl	ax, cl			; AX = bank << 13 = bank * 0x2000
	mov	di, ax			; DI = bank base offset

	; ---- row = Y / 4 ----
	mov	ax, bx
	shr	ax, 1
	shr	ax, 1			; AX = row
	mov	dx, ax			; DX = row (working copy)

	; ---- row * 90 = row*64 + row*16 + row*8 + row*2 ----
	mov	cx, dx
	shl	cx, 1
	shl	cx, 1
	shl	cx, 1
	shl	cx, 1
	shl	cx, 1
	shl	cx, 1			; CX = row * 64

	mov	ax, dx
	shl	ax, 1
	shl	ax, 1
	shl	ax, 1
	shl	ax, 1			; AX = row * 16
	add	cx, ax			; CX = row * 80

	mov	ax, dx
	shl	ax, 1
	shl	ax, 1
	shl	ax, 1			; AX = row * 8
	add	cx, ax			; CX = row * 88

	mov	ax, dx
	shl	ax, 1			; AX = row * 2
	add	cx, ax			; CX = row * 90

	; ---- Final byte offset ----
	add	di, cx			; DI = bank_base + row*90

	; ---- Write 90 bytes of 0xFF ----
	mov	ax, VID_SEG
	mov	es, ax
	mov	ax, 0xFFFF
	mov	cx, BYTES_PER_ROW / 2	; 45 words = 90 bytes
	cld
	rep	stosw

	pop	bx
	ret

; =============================================================================
; plot_pixel
; Set one pixel at coordinates (AX=X, BX=Y) in the framebuffer.
; Formula:
;   bank       = BX AND 3
;   row        = BX SHR 2
;   byte_off   = (bank SHL 13) + (row * 90) + (AX SHR 3)
;   bit_mask   = 0x80 SHR (AX AND 7)
;   [0xB000:byte_off] |= bit_mask
;
; Trashes: AX, CX, DX, DI, ES  (preserves BX)
; =============================================================================
plot_pixel:
	push	bx
	push	ax			; save X

	; ---- Compute bank * 0x2000 ----
	mov	ax, bx			; AX = Y
	and	ax, 3			; AX = bank (0-3)
	mov	cl, 13
	shl	ax, cl			; AX = bank * 0x2000
	mov	di, ax			; DI = bank base

	; ---- Compute row * 90 ----
	mov	ax, bx			; AX = Y
	shr	ax, 1
	shr	ax, 1			; AX = row = Y / 4
	mov	dx, ax			; DX = row (saved for repeated use)

	; row * 90 = row*64 + row*16 + row*8 + row*2
	mov	cx, dx
	shl	cx, 1
	shl	cx, 1
	shl	cx, 1
	shl	cx, 1
	shl	cx, 1
	shl	cx, 1			; CX = row * 64

	mov	ax, dx
	shl	ax, 1
	shl	ax, 1
	shl	ax, 1
	shl	ax, 1			; AX = row * 16
	add	cx, ax

	mov	ax, dx
	shl	ax, 1
	shl	ax, 1
	shl	ax, 1			; AX = row * 8
	add	cx, ax

	mov	ax, dx
	shl	ax, 1			; AX = row * 2
	add	cx, ax			; CX = row * 90

	add	di, cx			; DI = bank base + row*90

	; ---- Add column byte offset (X / 8) ----
	pop	ax			; AX = X (restored)
	push	ax			; save X again for bit calculation
	shr	ax, 1
	shr	ax, 1
	shr	ax, 1			; AX = X / 8 = byte column
	add	di, ax			; DI = final byte offset

	; ---- Compute bit mask (0x80 >> (X AND 7)) ----
	pop	ax			; AX = X
	and	ax, 7			; AX = bit index within byte (0=left)
	mov	cx, ax			; CX = shift count
	mov	al, 0x80		; start with leftmost bit
	shr	al, cl			; shift right by bit index

	; ---- OR the bit into the framebuffer byte ----
	mov	dx, VID_SEG
	mov	es, dx
	or	[es:di], al

	pop	bx
	ret

; =============================================================================
; fill_banks
; Test 3: fill each bank with a distinct solid byte pattern so the four-line
; interleave is visually apparent as horizontal stripes.
;
;   Bank 0: 0xFF  (all pixels on -- solid bright stripe)
;   Bank 1: 0x55  (alternating on/off -- fine vertical dashes)
;   Bank 2: 0xAA  (alternating off/on -- complement of bank 1)
;   Bank 3: 0x00  (all pixels off -- dark stripe)
;
; Each bank is ROWS_PER_BANK * BYTES_PER_ROW = 87 * 90 = 7830 bytes.
; =============================================================================
fill_banks:
	push	es
	mov	ax, VID_SEG
	mov	es, ax

	; Bank 0 at offset 0x0000, fill with 0xFF
	xor	di, di
	mov	ax, 0xFFFF
	mov	cx, (ROWS_PER_BANK * BYTES_PER_ROW) / 2
	cld
	rep	stosw

	; Bank 1 at offset 0x2000, fill with 0x55
	mov	di, 0x2000
	mov	ax, 0x5555
	mov	cx, (ROWS_PER_BANK * BYTES_PER_ROW) / 2
	rep	stosw

	; Bank 2 at offset 0x4000, fill with 0xAA
	mov	di, 0x4000
	mov	ax, 0xAAAA
	mov	cx, (ROWS_PER_BANK * BYTES_PER_ROW) / 2
	rep	stosw

	; Bank 3 at offset 0x6000, fill with 0x00
	; (already zeroed by clear_screen, but explicit is better)
	mov	di, 0x6000
	xor	ax, ax
	mov	cx, (ROWS_PER_BANK * BYTES_PER_ROW) / 2
	rep	stosw

	pop	es
	ret

; =============================================================================
; draw_scanline_stripes
; Test 4: light only the first row within each bank.
; Bank 0 row 0 = scanline 0, Bank 1 row 0 = scanline 1,
; Bank 2 row 0 = scanline 2, Bank 3 row 0 = scanline 3.
;
; Result: four thin bright lines at the very top of the screen (scanlines 0-3),
; everything else dark.  Verifies that bank-0-row-0 really is the topmost line.
; =============================================================================
draw_scanline_stripes:
	push	es
	mov	ax, VID_SEG
	mov	es, ax
	cld

	; Bank 0, row 0: offset = 0x0000, length = 90 bytes
	mov	di, 0x0000
	mov	ax, 0xFFFF
	mov	cx, BYTES_PER_ROW / 2
	rep	stosw

	; Bank 1, row 0: offset = 0x2000
	mov	di, 0x2000
	mov	cx, BYTES_PER_ROW / 2
	rep	stosw

	; Bank 2, row 0: offset = 0x4000
	mov	di, 0x4000
	mov	cx, BYTES_PER_ROW / 2
	rep	stosw

	; Bank 3, row 0: offset = 0x6000
	mov	di, 0x6000
	mov	cx, BYTES_PER_ROW / 2
	rep	stosw

	pop	es
	ret

; =============================================================================
; wait_key
; Wait for a keypress via BIOS INT 16h.
; Returns: ZF set if ESC was pressed, ZF clear otherwise.
; Trashes: AX
; =============================================================================
wait_key:
	xor	ah, ah			; AH=0: wait for keypress
	int	0x16			; AH = scan code, AL = ASCII
	cmp	al, 0x1B		; ESC?
	ret				; ZF set if ESC, clear if anything else

; =============================================================================
; Data
; =============================================================================

; MC6845 CRTC register table: pairs of (register_index, register_value).
; Values extracted from diagnose.com at file offset 0x25BE.
; See lemd_enhanced_mono_spec.md Section 2.2 for full explanation.
crtc_table:
	db	0,  0x35	; R0  Horizontal Total      (53 char clocks)
	db	1,  0x2D	; R1  Horizontal Displayed   (45 chars = 720px)
	db	2,  0x2E	; R2  H Sync Position
	db	3,  0x07	; R3  Sync Widths            (HSync=7)
	db	4,  0x5B	; R4  Vertical Total         (91 char rows)
	db	5,  0x02	; R5  Vertical Total Adjust  (+2 scanlines)
	db	6,  0x57	; R6  Vertical Displayed     (87 rows * 4 = 348)
	db	7,  0x57	; R7  Vertical Sync Position
	db	8,  0x02	; R8  Interlace Mode         (sync+video)
	db	9,  0x03	; R9  Max Scan Line Addr     (4 lines/row)
	db	10, 0x00	; R10 Cursor Start           (disabled)
	db	11, 0x00	; R11 Cursor End
	db	12, 0x00	; R12 Start Address High     (frame at 0x0000)
	db	13, 0x00	; R13 Start Address Low
	db	14, 0x00	; R14 Cursor Address High
	db	15, 0x00	; R15 Cursor Address Low

; Storage for the original BIOS equipment word, saved at startup and
; restored before we call INT 10h to return to text mode.
orig_equip:	dw	0
