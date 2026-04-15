; =============================================================================
; lemdrtim.asm
; Leading Edge Model D -- Rotating Line Timer Test
;
; Target:    IBM PC compatible, Leading Edge Model D hardware
; Assembler: nasm -f bin -o lemdrtim.com lemdrtim.asm
; Format:    DOS COM (single segment, org 0x100)
; CPU:       8088 / 8086  (no 286+ opcodes, no FPU)
;
; Purpose:
;   Measures how long it takes to draw a full screen "rotation" of lines
;   sweeping from horizontal to diagonal, then erase them the same way.
;   Unlike lemdtime.com (pure horizontal) and lemdvtim.com (pure vertical),
;   this test exercises the full spectrum of line angles in a single timed
;   window, giving a feel for how per-pixel cost varies with line slope.
;
;   The rotation proceeds in two phases:
;
;   Phase 1 -- Y sweeps, X fixed at screen edges:
;     Line 0:   (0, 173) -> (719, 174)   horizontal through middle
;     Line 1:   (0, 172) -> (719, 175)
;     ...
;     Line 173: (0,   0) -> (719, 347)   full diagonal
;     174 lines total.  Bresenham drives X as the major axis (DX=719 > DY).
;
;   Phase 2 -- X sweeps, Y fixed at screen edges:
;     Line 174: (  1, 0) -> (718, 347)
;     Line 175: (  2, 0) -> (717, 347)
;     ...
;     Line 532: (359, 0) -> (360, 347)   nearly vertical
;     359 lines total.  Bresenham drives Y as the major axis (DY=347).
;
;   Then the same sequence is repeated with pixels cleared (AND ~mask).
;   Total timed window: one fill rotation + one erase rotation.
;
; Out-of-range detection:
;   draw_pixel validates both X (0..719) and Y (0..347) before computing
;   the framebuffer address, and also validates the final byte offset
;   against FRAMEBUF_MAX.  If any check fails the program immediately
;   restores text mode and prints a diagnostic:
;
;     OUT OF RANGE: phase=N line=N X=N Y=N offset=0xNNNN
;
;   This is intentional: the first version of this program exhibited a
;   Bresenham runaway that produced offsets in the upper 32KB of the
;   0xB000 segment (0xB000:0x8000+), causing a sudden full-screen flash
;   consistent with a Hercules-style hidden-page flip.  The handler is
;   the diagnostic tool for confirming whether that page truly exists and
;   how the hardware responds to writes there.
;
; Known bugs fixed vs v1:
;   1. ES clobber: reading the BIOS tick counter sets ES = BDA_SEG.
;      draw_pixel now reloads ES = VID_SEG on every call (two instructions,
;      negligible cost against the address arithmetic).  ES is also
;      restored explicitly after the tick read in the main flow.
;   2. Hardcoded Bresenham subtraction constants (-719, -347) replaced
;      with memory reads from bres_dx / bres_dy.
;
; Timing:
;   Uses the full 32-bit BIOS tick counter (0040:006C low, 0040:006E high).
;   1 tick = 54.925 ms; we print ticks * 55 as an approximation (0.14%).
;
; Test sequence:
;   1. Pre-flight: verify monochrome monitor selected (BDA equip word).
;   2. Save equipment word and current video mode.
;   3. Activate enhanced mono mode.
;   4. Clear framebuffer (0x00) -- outside timed window.
;   5. Read 32-bit tick counter -> tick_start.
;   6. FILL pass: draw the rotating line sequence, setting pixels.
;   7. ERASE pass: draw the same sequence, clearing pixels.
;   8. Read 32-bit tick counter -> tick_end.
;   9. Restore text mode.
;  10. Print 32-bit tick delta and millisecond estimate.
; =============================================================================

        cpu     8086
        org     0x0100

; ---------------------------------------------------------------------------
; Constants
; ---------------------------------------------------------------------------

VID_SEG         equ     0xB000

BYTES_PER_ROW   equ     90
SCREEN_W        equ     720
SCREEN_H        equ     348

; First byte offset beyond active pixel data.
; 4 banks * 87 rows * 90 bytes = 31,320 = 0x7A78.
; Offsets 0x7A78..0x7FFF: unused trailing region in bank 3.
; Offsets 0x8000..0xFFFF: suspected Hercules-style hidden page.
; Any computed offset >= FRAMEBUF_MAX triggers the error handler.
FRAMEBUF_MAX    equ     0x7E96; 0x6000 + 87*90 = first invalid offset

; Phase 1 geometry
Y_BEG_START     equ     173             ; center scanline, counts down to 0
Y_END_START     equ     174             ; center+1, counts up to 347
PHASE1_LINES    equ     174

; Phase 2 geometry
PHASE2_LINES    equ     359

; BIOS Data Area
BDA_SEG         equ     0x0040
BDA_EQUIP       equ     0x0010
BDA_TICKS_LO    equ     0x006C
BDA_TICKS_HI    equ     0x006E

; Hardware ports
PORT_CRTC_ADDR  equ     0x3B4
PORT_CRTC_DATA  equ     0x3B5
PORT_MDA_MODE   equ     0x3B8
PORT_CGA_MODE   equ     0x3D8
PORT_CGA_COLOR  equ     0x3D9
PORT_LE_CTRL    equ     0x3DD

; ---------------------------------------------------------------------------
; Entry point
; ---------------------------------------------------------------------------
start:
        ; ----- Pre-flight: monochrome monitor must be selected -----
        ; BDA equipment word bits [5:4] = 0x30 means MDA/monochrome.
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [es:BDA_EQUIP]
        and     ax, 0x0030
        cmp     ax, 0x0030
        je      .mono_ok
        mov     dx, msg_wrong_monitor
        mov     ah, 0x09
        int     0x21
        mov     ax, 0x4C01
        int     0x21
.mono_ok:

        ; ----- Save state for clean exit -----
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [es:BDA_EQUIP]
        mov     [orig_equip], ax

        mov     ah, 0x0F
        int     0x10
        mov     [orig_mode], al

        ; ----- Activate enhanced mono mode -----
        ; Leaves ES = VID_SEG.
        call    set_lemd_mode

        ; ----- Clear framebuffer to known black (outside timed window) -----
        ; Leaves ES = VID_SEG.
        call    hfill_screen
        db      0x00

        ; ----- Read 32-bit start tick -----
        ; Reading the tick counter requires ES = BDA_SEG, which clobbers the
        ; framebuffer pointer.  Restore ES = VID_SEG immediately after.
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [es:BDA_TICKS_LO]
        mov     [tick_start_lo], ax
        mov     ax, [es:BDA_TICKS_HI]
        mov     [tick_start_hi], ax
        mov     ax, VID_SEG             ; restore ES before entering draw loop
        mov     es, ax

        ; ----- FILL PASS -----
        mov     byte [op_flag], 0       ; 0 = OR mask (set pixel)
        call    draw_rotation

        ; ----- ERASE PASS -----
        mov     byte [op_flag], 1       ; 1 = AND ~mask (clear pixel)
        call    draw_rotation

        ; ----- Read 32-bit end tick -----
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [es:BDA_TICKS_LO]
        mov     [tick_end_lo], ax
        mov     ax, [es:BDA_TICKS_HI]
        mov     [tick_end_hi], ax

        ; ----- Restore text mode -----
        call    restore_text

        ; ----- Compute 32-bit tick delta -----
        ; SBB propagates borrow from low word subtraction into high word.
        mov     ax, [tick_end_lo]
        mov     dx, [tick_end_hi]
        sub     ax, [tick_start_lo]
        sbb     dx, [tick_start_hi]
        mov     [tick_delta_lo], ax
        mov     [tick_delta_hi], dx

        ; ----- Print tick delta -----
        mov     si, msg_ticks
        call    print_str
        mov     ax, [tick_delta_hi]
        mov     dx, [tick_delta_lo]
        call    print_dword_decimal
        mov     si, msg_crlf
        call    print_str

        ; ----- Print milliseconds -----
        ; ms = ticks * 55.  Split into (tick_hi * 55 * 65536) + (tick_lo * 55).
        mov     ax, [tick_delta_lo]
        mov     bx, 55
        mul     bx                      ; DX:AX = tick_lo * 55
        mov     [ms_lo], ax
        mov     [ms_carry], dx

        mov     ax, [tick_delta_hi]
        mul     bx                      ; DX:AX = tick_hi * 55
        add     ax, [ms_carry]
        mov     [ms_hi], ax

        mov     si, msg_ms
        call    print_str
        mov     ax, [ms_hi]
        mov     dx, [ms_lo]
        call    print_dword_decimal
        mov     si, msg_ms_unit
        call    print_str

        mov     ax, 0x4C00
        int     0x21

; ---------------------------------------------------------------------------
; restore_text
;
; Restore equipment word and original video mode via INT 10h.
; Factored out because both the normal exit and the error handler need it.
; Destroys: AX, ES
; ---------------------------------------------------------------------------
restore_text:
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [orig_equip]
        mov     [es:BDA_EQUIP], ax      ; must precede INT 10h
        xor     ah, ah
        mov     al, [orig_mode]
        int     0x10
        ret

; ---------------------------------------------------------------------------
; draw_rotation
;
; Draws the two-phase rotating line sequence.
;
; Phase 1: (0, Y_beg)->(719, Y_end), Y sweeps from center to edges.
;          174 lines.  Major axis = X (DX=719 >= DY throughout).
;
; Phase 2: (X_beg, 0)->(X_end, 347), X converges from edges to center.
;          359 lines.  Major axis = Y (DY=347).
;
; op_flag selects set vs clear for all pixels.
; phase_num and line_num are kept current for the error handler.
;
; Destroys: AX, BX, CX, DX, SI, DI, BP, ES
; ---------------------------------------------------------------------------
draw_rotation:
        ; ==== Phase 1 ====
        mov     word [p1_ybeg], Y_BEG_START
        mov     word [p1_yend], Y_END_START
        mov     word [p1_count], PHASE1_LINES
        mov     word [phase_num], 1

.phase1_loop:
        ; Compute DY for this line and set up Bresenham state.
        ; DX = 719 (constant), DY = Y_end - Y_beg (grows from 1 to 347).
        ; Initial error = DX/2 = 359 (standard midpoint initialisation).
        mov     ax, [p1_yend]
        sub     ax, [p1_ybeg]
        mov     [bres_dy], ax
        mov     word [bres_dx], 719
        mov     word [bres_err], 359
        mov     word [bres_x], 0
        mov     ax, [p1_ybeg]
        mov     [bres_y], ax

        ; Track current line index for error reporting.
        mov     ax, PHASE1_LINES
        sub     ax, [p1_count]
        mov     [line_num], ax

.phase1_pixel:
        mov     bx, [bres_x]
        mov     bp, [bres_y]
        call    draw_pixel

        ; Bresenham: X always steps.  Y steps when accumulated error >= DX.
        mov     ax, [bres_err]
        add     ax, [bres_dy]
        cmp     ax, [bres_dx]
        jl      .p1_no_ystep
        sub     ax, [bres_dx]           ; error -= DX  (v1 bug: was hardcoded -719)
        inc     word [bres_y]
.p1_no_ystep:
        mov     [bres_err], ax
        inc     word [bres_x]
        cmp     word [bres_x], SCREEN_W
        jl      .phase1_pixel

        ; Advance to next line.
        dec     word [p1_ybeg]
        inc     word [p1_yend]
        dec     word [p1_count]
        jnz     .phase1_loop

        ; ==== Phase 2 ====
        mov     word [p2_xbeg], 1
        mov     word [p2_xend], 718
        mov     word [p2_count], PHASE2_LINES
        mov     word [phase_num], 2

.phase2_loop:
        ; DY = 347 (constant), DX = X_end - X_beg (shrinks toward 0).
        ; Initial error = DY/2 = 173.
        mov     ax, [p2_xend]
        sub     ax, [p2_xbeg]
        mov     [bres_dx], ax
        mov     word [bres_dy], 347
        mov     word [bres_err], 173
        mov     word [bres_y], 0
        mov     ax, [p2_xbeg]
        mov     [bres_x], ax

        mov     ax, PHASE2_LINES
        sub     ax, [p2_count]
        mov     [line_num], ax

.phase2_pixel:
        mov     bx, [bres_x]
        mov     bp, [bres_y]
        call    draw_pixel

        ; Bresenham: Y always steps.  X steps when accumulated error >= DY.
        mov     ax, [bres_err]
        add     ax, [bres_dx]
        cmp     ax, [bres_dy]
        jl      .p2_no_xstep
        sub     ax, [bres_dy]           ; error -= DY  (v1 bug: was hardcoded -347)
        inc     word [bres_x]
.p2_no_xstep:
        mov     [bres_err], ax
        inc     word [bres_y]
        cmp     word [bres_y], SCREEN_H
        jl      .phase2_pixel

        inc     word [p2_xbeg]
        dec     word [p2_xend]
        dec     word [p2_count]
        jnz     .phase2_loop

        ret

; ---------------------------------------------------------------------------
; draw_pixel
;
; Set or clear one pixel at (BX=X, BP=Y).
; op_flag: 0 = OR mask (set), 1 = AND ~mask (clear).
;
; Bounds checks:
;   X must be < SCREEN_W (720).  Unsigned compare catches negatives too.
;   Y must be < SCREEN_H (348).  Same.
;   Final byte offset must be < FRAMEBUF_MAX (0x7A78).  This is a second
;   safety net that catches any arithmetic overflow that slipped past the
;   coordinate checks -- e.g. a Bresenham accumulator that wraps to a
;   value which looks valid as coordinates but produces a bad offset.
;
; If any check fails: saves X, Y, DI, then jumps to err_out_of_range
; (does not return).
;
; ES is reloaded to VID_SEG on every entry.  This costs two instructions
; per pixel but prevents silent corruption if ES was left pointing at
; BDA_SEG by a tick counter read between calls.
;
; Destroys: AX, CX, DX, DI, ES  (BX, BP preserved)
; ---------------------------------------------------------------------------
draw_pixel:
        ; Reload ES defensively on every call.
        mov     ax, VID_SEG
        mov     es, ax

        ; ---- Bounds check X (unsigned: catches X >= 720 and X = 0xFFFF) ----
        cmp     bx, SCREEN_W
        jae     err_out_of_range

        ; ---- Bounds check Y ----
        cmp     bp, SCREEN_H
        jae     err_out_of_range

        ; ---- Compute and save bitmask ----
        ; mask = 0x80 >> (X AND 7).  Bit 7 = leftmost pixel in byte.
        ; Must be saved before AX is destroyed by address arithmetic.
        mov     ax, bx
        and     al, 0x07
        mov     cl, al
        mov     al, 0x80
        shr     al, cl
        mov     [pix_mask], al

        ; ---- bank_base = (Y AND 3) * 0x2000 ----
        mov     ax, bp
        and     ax, 0x0003
        mov     cl, 13
        shl     ax, cl
        mov     di, ax

        ; ---- row = Y SHR 2;  row * 90 = row*64 + row*16 + row*8 + row*2 ----
        mov     ax, bp
        shr     ax, 1
        shr     ax, 1
        mov     dx, ax                  ; DX = row

        mov     cx, dx
        shl     cx, 1
        shl     cx, 1
        shl     cx, 1
        shl     cx, 1
        shl     cx, 1
        shl     cx, 1                   ; CX = row * 64

        mov     ax, dx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        add     cx, ax                  ; CX += row * 16

        mov     ax, dx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        add     cx, ax                  ; CX += row * 8

        mov     ax, dx
        shl     ax, 1
        add     cx, ax                  ; CX += row * 2  =>  CX = row * 90

        add     di, cx                  ; DI = bank_base + row*90

        ; ---- byte_col = X SHR 3 ----
        mov     ax, bx
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1
        add     di, ax                  ; DI = final byte offset

        ; ---- Secondary safety: offset must be within active pixel data ----
        ; Catches arithmetic overflow that slipped past the X/Y checks.
        ; Offsets >= 0x7A78 are either the unused trailing region of bank 3
        ; or the suspected hidden page at 0x8000+.
        cmp     di, FRAMEBUF_MAX
        jae     err_out_of_range

        ; ---- Read-modify-write ----
        mov     al, [es:di]
        mov     ah, [pix_mask]

        cmp     byte [op_flag], 0
        jne     .clear
        or      al, ah
        jmp     short .write
.clear:
        not     ah
        and     al, ah
.write:
        mov     [es:di], al
        ret

; ---------------------------------------------------------------------------
; err_out_of_range
;
; Entered via JMP from draw_pixel when a bounds check fails.
; Saves the offending coordinates, restores text mode, prints diagnostic,
; exits with code 2.  Does not return.
;
; At entry: BX=X, BP=Y, DI=partial or full byte offset.
; ---------------------------------------------------------------------------
err_out_of_range:
        mov     [err_x], bx
        mov     [err_y], bp
        mov     [err_offset], di

        call    restore_text

        mov     si, msg_err_hdr
        call    print_str

        mov     si, msg_err_phase
        call    print_str
        xor     dx, dx
        mov     ax, [phase_num]
        call    print_dword_decimal

        mov     si, msg_err_line
        call    print_str
        xor     dx, dx
        mov     ax, [line_num]
        call    print_dword_decimal

        mov     si, msg_err_x
        call    print_str
        xor     dx, dx
        mov     ax, [err_x]
        call    print_dword_decimal

        mov     si, msg_err_y
        call    print_str
        xor     dx, dx
        mov     ax, [err_y]
        call    print_dword_decimal

        mov     si, msg_err_offset
        call    print_str
        mov     ax, [err_offset]
        call    print_word_hex

        mov     si, msg_crlf
        call    print_str

        mov     ax, 0x4C02              ; exit code 2 = out-of-range fault
        int     0x21

; ---------------------------------------------------------------------------
; hfill_screen
;
; Fill every scanline with the byte immediately following the CALL.
; Inline-byte argument trick (see lemdtime.asm for full explanation).
; Leaves ES = VID_SEG.
; Destroys: AX, BX, CX, DX, DI, SI, ES
; ---------------------------------------------------------------------------
hfill_screen:
        pop     si
        mov     al, [si]
        inc     si
        push    si
        mov     [hfill_val], al

        mov     ax, VID_SEG
        mov     es, ax
        xor     bx, bx

.scan:
        mov     ax, bx
        and     ax, 0x0003
        mov     cl, 13
        shl     ax, cl
        mov     di, ax

        mov     ax, bx
        shr     ax, 1
        shr     ax, 1
        mov     dx, ax

        mov     cx, dx
        shl     cx, 1
        shl     cx, 1
        shl     cx, 1
        shl     cx, 1
        shl     cx, 1
        shl     cx, 1
        mov     ax, dx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        add     cx, ax
        mov     ax, dx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        add     cx, ax
        mov     ax, dx
        shl     ax, 1
        add     cx, ax
        add     di, cx

        mov     al, [hfill_val]
        mov     cx, BYTES_PER_ROW
        rep     stosb

        inc     bx
        cmp     bx, SCREEN_H
        jl      .scan
        ret

; ---------------------------------------------------------------------------
; set_lemd_mode
;
; Activate the Leading Edge 720x348 enhanced monochrome graphics mode.
; Sequence from diagnose.com disassembly; confirmed on hardware.
; See lemd_enhanced_mono_spec.md section 2 for full explanation.
; Leaves ES = VID_SEG.
; Destroys: AX, CX, DX, SI, ES
; ---------------------------------------------------------------------------
set_lemd_mode:
        mov     ax, BDA_SEG
        mov     es, ax
        or      word [es:BDA_EQUIP], 0x0030

        mov     si, crtc_vals
        xor     ah, ah
        mov     cx, 16
.crtc:
        mov     dx, PORT_CRTC_ADDR
        mov     al, ah
        out     dx, al
        mov     dx, PORT_CRTC_DATA
        lodsb
        out     dx, al
        inc     ah
        loop    .crtc

        mov     dx, PORT_MDA_MODE
        mov     al, 0x0A
        out     dx, al

        mov     dx, PORT_CGA_MODE
        mov     al, 0x1A
        out     dx, al

        mov     dx, PORT_CGA_COLOR
        xor     al, al
        out     dx, al

        mov     dx, PORT_LE_CTRL
        mov     al, 0x08
        out     dx, al

        mov     ax, VID_SEG
        mov     es, ax
        ret

; ---------------------------------------------------------------------------
; print_str -- print '$'-terminated string; SI = pointer in DS
; Destroys: AX, DX
; ---------------------------------------------------------------------------
print_str:
        mov     dx, si
        mov     ah, 0x09
        int     0x21
        ret

; ---------------------------------------------------------------------------
; print_dword_decimal -- print DX:AX (DX=high) as unsigned decimal
; Two-stage 32-bit division by 10; digits collected on stack.
; Destroys: AX, BX, CX, DX
; ---------------------------------------------------------------------------
print_dword_decimal:
        mov     bx, 10
        xor     cx, cx
        mov     [ddec_hi], dx
        mov     [ddec_lo], ax
.loop:
        xor     dx, dx
        mov     ax, [ddec_hi]
        div     bx                      ; AX = high quotient, DX = carry
        mov     [ddec_hi], ax
        mov     ax, [ddec_lo]
        div     bx                      ; AX = low quotient, DX = digit
        mov     [ddec_lo], ax
        push    dx
        inc     cx
        mov     ax, [ddec_hi]
        or      ax, [ddec_lo]
        jnz     .loop
.print:
        pop     dx
        add     dl, '0'
        mov     ah, 0x02
        int     0x21
        loop    .print
        ret

; ---------------------------------------------------------------------------
; print_word_hex -- print AX as four uppercase hex digits (no prefix)
; Destroys: AX, BX, CX, DX
; ---------------------------------------------------------------------------
print_word_hex:
        mov     cx, 4
        mov     bx, ax
.nibble:
        rol     bx, 1
        rol     bx, 1
        rol     bx, 1
        rol     bx, 1
        mov     al, bl
        and     al, 0x0F
        cmp     al, 10
        jl      .digit
        add     al, 'A' - 10
        jmp     short .emit
.digit:
        add     al, '0'
.emit:
        mov     dl, al
        mov     ah, 0x02
        int     0x21
        loop    .nibble
        ret

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------

crtc_vals:
        db      0x35, 0x2D, 0x2E, 0x07  ; R0-R3
        db      0x5B, 0x02, 0x57, 0x57  ; R4-R7
        db      0x02, 0x03, 0x00, 0x00  ; R8-R11
        db      0x00, 0x00, 0x00, 0x00  ; R12-R15

orig_equip:     dw      0
orig_mode:      db      0

tick_start_lo:  dw      0
tick_start_hi:  dw      0
tick_end_lo:    dw      0
tick_end_hi:    dw      0
tick_delta_lo:  dw      0
tick_delta_hi:  dw      0

ms_lo:          dw      0
ms_hi:          dw      0
ms_carry:       dw      0

pix_mask:       db      0
op_flag:        db      0
hfill_val:      db      0

p1_ybeg:        dw      0
p1_yend:        dw      0
p1_count:       dw      0

p2_xbeg:        dw      0
p2_xend:        dw      0
p2_count:       dw      0

bres_x:         dw      0
bres_y:         dw      0
bres_dx:        dw      0
bres_dy:        dw      0
bres_err:       dw      0

phase_num:      dw      0
line_num:       dw      0
err_x:          dw      0
err_y:          dw      0
err_offset:     dw      0

ddec_lo:        dw      0
ddec_hi:        dw      0

msg_wrong_monitor:
        db      'ERROR: Monochrome monitor not selected (rear switch).', 0x0D, 0x0A, '$'
msg_ticks:
        db      'Ticks elapsed : $'
msg_ms:
        db      'Approx ms     : $'
msg_ms_unit:
        db      ' ms  (fill+erase, ticks * 55)', 0x0D, 0x0A, '$'
msg_crlf:
        db      0x0D, 0x0A, '$'
msg_err_hdr:
        db      'OUT OF RANGE: $'
msg_err_phase:
        db      'phase=$'
msg_err_line:
        db      ' line=$'
msg_err_x:
        db      ' X=$'
msg_err_y:
        db      ' Y=$'
msg_err_offset:
        db      ' offset=0x$'
