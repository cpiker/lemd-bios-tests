; =============================================================================
; lemdvtim.asm
; Leading Edge Model D -- Vertical Line Fill/Erase Timer Test
;
; Target:    IBM PC compatible, Leading Edge Model D hardware
; Assembler: nasm -f bin -o lemdvtim.com lemdvtim.asm
; Format:    DOS COM (single segment, org 0x100)
; CPU:       8088 / 8086  (no 286+ opcodes, no FPU)
;
; Purpose:
;   Measures how long it takes to fill the screen with 720 vertical lines
;   (one per column, lighting every pixel), then erase them.  Compare
;   against lemdtime.com (horizontal lines) to see the cost of the
;   read-modify-write penalty and non-contiguous access pattern.
;
;   Both tests cover exactly 720 * 348 = 250,560 pixels per pass, so the
;   elapsed times are directly comparable.
;
; Why vertical lines are expensive on this hardware:
;   A horizontal line is 90 contiguous bytes in one bank -- REP STOSB.
;   A vertical line at column X touches one BIT in one BYTE per scanline.
;   For each of 348 scanlines we must:
;     1. Calculate the byte address  (bank, row, byte-within-row)
;     2. Recall the bit mask         (0x80 >> (X AND 7))
;     3. READ the byte from video RAM
;     4. OR or AND the mask into it
;     5. WRITE the byte back
;   Three memory cycles instead of one, plus the address sawtooth
;   pattern jumps across all four banks (~24KB range) per line drawn.
;
; Test sequence:
;   1. Pre-flight: verify monochrome monitor selected.
;   2. Save equipment word and video mode.
;   3. Activate enhanced mono mode.
;   4. Clear framebuffer (0x00) -- outside timed window.
;   5. Read tick counter -> tick_start.
;   6. Fill pass: draw 720 vertical lines, setting bits (OR mask).
;   7. Erase pass: draw 720 vertical lines, clearing bits (AND ~mask).
;   8. Read tick counter -> tick_end.
;   9. Restore text mode.
;  10. Print tick delta and millisecond estimate.
; =============================================================================

        cpu     8086
        org     0x0100

; ---------------------------------------------------------------------------
; Constants
; ---------------------------------------------------------------------------

VID_SEG         equ     0xB000

BYTES_PER_ROW   equ     90              ; 720 / 8
SCREEN_W        equ     720
SCREEN_H        equ     348

BDA_SEG         equ     0x0040
BDA_EQUIP       equ     0x0010
BDA_TICKS_LO    equ     0x006C

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
        ; ----- Pre-flight: monochrome monitor? -----
        ; BDA equipment word bits [5:4] must be 11b (0x30) for MDA/mono.
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

        mov     ah, 0x0F                ; BIOS get current video mode
        int     0x10
        mov     [orig_mode], al

        ; ----- Activate enhanced mono mode -----
        call    set_lemd_mode

        ; ----- Clear to known black state (outside timed window) -----
        call    hfill_screen
        db      0x00

        ; ----- Snapshot start tick -----
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [es:BDA_TICKS_LO]
        mov     [tick_start], ax

        ; ----- FILL PASS: 720 vertical lines, set bits -----
        mov     byte [op_flag], 0       ; 0 = OR mask (set pixel)
        call    draw_vlines

        ; ----- ERASE PASS: 720 vertical lines, clear bits -----
        mov     byte [op_flag], 1       ; 1 = AND ~mask (clear pixel)
        call    draw_vlines

        ; ----- Snapshot end tick -----
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [es:BDA_TICKS_LO]
        mov     [tick_end], ax

        ; ----- Restore text mode -----
        ; Must restore equipment word before INT 10h, which reads it to
        ; determine what kind of adapter to initialize.
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [orig_equip]
        mov     [es:BDA_EQUIP], ax

        xor     ah, ah
        mov     al, [orig_mode]
        int     0x10

        ; ----- Compute and print results -----
        mov     ax, [tick_end]
        sub     ax, [tick_start]
        mov     [tick_delta], ax

        mov     dx, msg_ticks
        mov     ah, 0x09
        int     0x21
        mov     ax, [tick_delta]
        call    print_decimal
        mov     dx, msg_crlf
        mov     ah, 0x09
        int     0x21

        ; ms = ticks * 55  (true factor 54.925ms/tick; 0.14% error)
        ; MUL AX * BX -> DX:AX.  Low word AX = ms for runs under ~65 sec.
        mov     ax, [tick_delta]
        mov     bx, 55
        mul     bx
        push    ax
        mov     dx, msg_ms
        mov     ah, 0x09
        int     0x21
        pop     ax
        call    print_decimal
        mov     dx, msg_ms_unit
        mov     ah, 0x09
        int     0x21

        mov     ax, 0x4C00
        int     0x21

; ---------------------------------------------------------------------------
; draw_vlines
;
; Draws SCREEN_W vertical lines, one per column X = 0..719.
; Each line spans all SCREEN_H scanlines (Y = 0..347).
;
; For each pixel (X, Y):
;   bank     = Y AND 3
;   row      = Y SHR 2
;   byte_off = (bank SHL 13) + (row * 90) + (X SHR 3)
;   mask     = 0x80 SHR (X AND 7)
;
;   op_flag == 0:  [0xB000:byte_off] |= mask
;   op_flag == 1:  [0xB000:byte_off] &= ~mask
;
; Register allocation:
;   BP = current X (column counter, 0..719)
;   BX = current Y (scanline counter, 0..347)
;   DI = byte offset being computed
;   DX = row (Y SHR 2), held across multiply-by-90 sequence
;   CX = accumulator for row*90 (also used for shift count via CL)
;   AL = framebuffer byte being read/modified/written
;   ES = VID_SEG  (constant throughout)
;
; IMPORTANT -- why col_mask is in memory, not a register:
;   The mask is constant for all 348 rows of the same column, so it is
;   computed once at the top of .col_loop and saved to col_mask.
;   It cannot be held in AH across the inner loop because the address
;   arithmetic begins with "mov ax, bx" (loading Y into the full AX word),
;   which immediately overwrites AH.  Every register is spoken for by the
;   address math, so the single extra memory read per pixel is unavoidable
;   without a deeper restructure.
;
; Destroys: AX, BX, CX, DX, DI, BP, ES
; ---------------------------------------------------------------------------
draw_vlines:
        mov     ax, VID_SEG
        mov     es, ax                  ; ES = framebuffer segment (stays fixed)

        xor     bp, bp                  ; BP = X = 0

.col_loop:
        ; ---- Compute and save the bitmask for this column ----
        ; mask = 0x80 >> (X AND 7)
        ; Bit 7 is the leftmost pixel in a byte.  Within a group of 8
        ; columns that share the same byte address, column X AND 7 tells
        ; us which bit position to target.
        ;
        ; On 8088, variable shifts require CL.
        mov     ax, bp                  ; AX = X
        and     al, 0x07                ; AL = X AND 7
        mov     cl, al
        mov     al, 0x80
        shr     al, cl                  ; AL = column bitmask
        mov     [col_mask], al          ; save -- AX will be clobbered below

        xor     bx, bx                  ; BX = Y = 0

.row_loop:
        ; ---- Compute byte offset: bank_base + row*90 + byte_col ----

        ; bank_base = (Y AND 3) * 0x2000
        ; Scanlines are interleaved across 4 banks spaced 0x2000 bytes apart.
        ; Bank = low 2 bits of Y.  Multiply by 0x2000 = shift left 13.
        mov     ax, bx                  ; AX = Y  (*** overwrites AH ***)
        and     ax, 0x0003              ; AX = bank (0..3)
        mov     cl, 13
        shl     ax, cl                  ; AX = bank * 0x2000
        mov     di, ax                  ; DI = bank base offset

        ; row = Y SHR 2.  Multiply row by 90 using shifts (no MUL/IMUL).
        ; 90 = 64 + 16 + 8 + 2
        mov     ax, bx                  ; AX = Y
        shr     ax, 1
        shr     ax, 1                   ; AX = row
        mov     dx, ax                  ; DX = row (preserved across additions)

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

        ; byte_col = X / 8
        mov     ax, bp                  ; AX = X
        shr     ax, 1
        shr     ax, 1
        shr     ax, 1                   ; AX = X / 8
        add     di, ax                  ; DI = final byte offset

        ; ---- Read-modify-write ----
        mov     al, [es:di]             ; read current framebuffer byte
        mov     ah, [col_mask]          ; reload mask (computed before address math)

        cmp     byte [op_flag], 0
        jne     .clear_bit
        or      al, ah                  ; SET pixel: OR the mask bit in
        jmp     short .write_back
.clear_bit:
        not     ah                      ; invert mask: target bit position = 0
        and     al, ah                  ; CLEAR pixel: zero that bit
.write_back:
        mov     [es:di], al             ; write modified byte back

        ; ---- Advance scanline ----
        inc     bx                      ; Y++
        cmp     bx, SCREEN_H
        jl      .row_loop

        ; ---- Advance column ----
        inc     bp                      ; X++
        cmp     bp, SCREEN_W
        jl      .col_loop

        ret

; ---------------------------------------------------------------------------
; hfill_screen
;
; Fill every scanline with the byte value immediately following the CALL.
; (Inline-byte argument trick -- see lemdtime.asm for explanation.)
; Used here to clear the framebuffer before timing begins.
;
; Destroys: AX, BX, CX, DX, DI, SI, ES
; ---------------------------------------------------------------------------
hfill_screen:
        pop     si                      ; SI = address of the inline fill byte
        mov     al, [si]                ; AL = fill value
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
; Sequence from diagnose.com disassembly.  See lemd_enhanced_mono_spec.md.
;
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
        ret

; ---------------------------------------------------------------------------
; print_decimal  -- print AX as unsigned decimal via INT 21h AH=02h
; ---------------------------------------------------------------------------
print_decimal:
        mov     bx, 10
        xor     cx, cx
.div:
        xor     dx, dx
        div     bx
        push    dx
        inc     cx
        test    ax, ax
        jnz     .div
.print:
        pop     dx
        add     dl, '0'
        mov     ah, 0x02
        int     0x21
        loop    .print
        ret

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------

; MC6845 register values R0..R15.
; Source: diagnose.com offset 0x25BE, confirmed by hardware testing.
crtc_vals:
        db      0x35, 0x2D, 0x2E, 0x07  ; R0-R3
        db      0x5B, 0x02, 0x57, 0x57  ; R4-R7
        db      0x02, 0x03, 0x00, 0x00  ; R8-R11
        db      0x00, 0x00, 0x00, 0x00  ; R12-R15

orig_equip:     dw      0
orig_mode:      db      0
tick_start:     dw      0
tick_end:       dw      0
tick_delta:     dw      0
op_flag:        db      0       ; 0 = set pixels, 1 = clear pixels
col_mask:       db      0       ; bitmask for current column, saved across inner loop
hfill_val:      db      0

msg_wrong_monitor:
        db      'ERROR: Monochrome monitor not selected (rear switch).', 0x0D, 0x0A, '$'
msg_ticks:
        db      'Ticks elapsed : $'
msg_ms:
        db      'Approx ms     : $'
msg_ms_unit:
        db      ' ms  (ticks * 55)', 0x0D, 0x0A, '$'
msg_crlf:
        db      0x0D, 0x0A, '$'
