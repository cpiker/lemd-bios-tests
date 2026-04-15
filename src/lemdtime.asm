; =============================================================================
; lemdtime.asm
; Leading Edge Model D -- Horizontal Line Fill/Erase Timer Test
;
; Target:    IBM PC compatible, Leading Edge Model D hardware
; Assembler: nasm -f bin -o lemdtime.com lemdtime.asm
; Format:    DOS COM (single segment, org 0x100)
; CPU:       8088 / 8086  (no 286+ opcodes, no FPU)
;
; Purpose:
;   Measures how long it takes to fill the entire 720x348 framebuffer
;   scanline by scanline with 0xFF (all pixels on), then erase it with
;   0x00 (all pixels off).  Uses the BIOS tick counter at 0040:006C for
;   timing.  Results are displayed in text mode after the test.
;
;   One BIOS tick = 1/18.2065 seconds = ~54.93 ms.
;   We multiply tick delta by 55 for a "good enough" millisecond figure.
;   (True value is 54.925ms/tick; the 0.1% error is irrelevant here.)
;
; Framebuffer quick reference:
;   Segment  : 0xB000
;   Banks    : 4, at offsets 0x0000 / 0x2000 / 0x4000 / 0x6000
;   Interleave: scanline Y -> bank (Y AND 3), row (Y SHR 2)
;   Row stride: 90 bytes   (720 pixels / 8 bits per byte)
;   Rows/bank : 87         (348 scanlines / 4 banks)
;
;   Given scanline Y, the offset of its first byte in the framebuffer is:
;     bank_base = (Y AND 3) * 0x2000
;     row       = Y SHR 2
;     offset    = bank_base + row * 90
;
;   A horizontal line is therefore 90 contiguous bytes -- perfect for
;   REP STOSB.  No per-pixel address math is needed at all.
;
; Test sequence:
;   1. Pre-flight: verify monochrome monitor is selected (BDA equip word).
;   2. Save original equipment word and current video mode.
;   3. Activate enhanced mono mode.
;   4. Clear framebuffer to known state (0x00).
;   5. Read BIOS tick counter -> tick_start.
;   6. Fill pass: write 0xFF to every scanline (Y = 0..347).
;   7. Erase pass: write 0x00 to every scanline (Y = 0..347).
;   8. Read BIOS tick counter -> tick_end.
;   9. Restore text mode.
;  10. Print tick delta and millisecond estimate.
; =============================================================================

        cpu     8086
        org     0x0100

; ---------------------------------------------------------------------------
; Constants
; ---------------------------------------------------------------------------

VID_SEG         equ     0xB000          ; framebuffer base segment

BYTES_PER_ROW   equ     90              ; 720 pixels / 8 = 90 bytes per scanline
ROWS_PER_BANK   equ     87              ; 348 scanlines / 4 banks
SCREEN_H        equ     348             ; total scanlines

; BIOS Data Area
BDA_SEG         equ     0x0040
BDA_EQUIP       equ     0x0010          ; equipment word (16-bit)
BDA_TICKS_LO    equ     0x006C          ; low word of tick counter (32-bit)
BDA_TICKS_HI    equ     0x006E          ; high word of tick counter

; Hardware ports (see lemd_enhanced_mono_spec.md section 7)
PORT_CRTC_ADDR  equ     0x3B4           ; MC6845 register index
PORT_CRTC_DATA  equ     0x3B5           ; MC6845 register value
PORT_MDA_MODE   equ     0x3B8           ; MDA mode control
PORT_CGA_MODE   equ     0x3D8           ; CGA mode control
PORT_CGA_COLOR  equ     0x3D9           ; CGA color select
PORT_LE_CTRL    equ     0x3DD           ; Leading Edge proprietary enable

; ---------------------------------------------------------------------------
; Entry point
; ---------------------------------------------------------------------------
start:
        ; COM programs load with CS=DS=ES=SS and SP near 0xFFFE.
        ; We use DS for our data segment throughout.

        ; ----- Pre-flight: monochrome monitor must be selected -----
        ; The BIOS equipment word at 0040:0010 encodes the display type in
        ; bits [5:4].  0x30 means MDA / monochrome.  Any other value means
        ; the rear switch is in a CGA position and this mode will produce
        ; no visible output on the mono connector.
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [es:BDA_EQUIP]
        and     ax, 0x0030
        cmp     ax, 0x0030
        je      .mono_ok
        mov     dx, msg_wrong_monitor
        mov     ah, 0x09
        int     0x21
        mov     ax, 0x4C01              ; exit with error code 1
        int     0x21
.mono_ok:

        ; ----- Save state -----
        ; We need to restore the equipment word before calling INT 10h
        ; to return to text mode, because INT 10h reads it to decide what
        ; to initialize.
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [es:BDA_EQUIP]
        mov     [orig_equip], ax        ; save for restore later

        mov     ah, 0x0F                ; BIOS: get current video mode
        int     0x10
        mov     [orig_mode], al         ; AL = mode number

        ; ----- Activate enhanced mono mode -----
        call    set_lemd_mode

        ; ----- Clear framebuffer to a known black state -----
        ; This also confirms the mode is active before we start timing.
        call    fill_screen
        db      0x00                    ; fill value: all pixels off

        ; ----- Read start tick count -----
        ; The BIOS tick counter at 0040:006C is a 32-bit value incremented
        ; ~18.2 times per second by the IRQ0 timer interrupt.  We only read
        ; the low 16-bit word; this wraps every ~3600 seconds (once/hour),
        ; which is fine for our purposes.
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [es:BDA_TICKS_LO]
        mov     [tick_start], ax

        ; ----- FILL PASS: light up every scanline -----
        call    fill_screen
        db      0xFF                    ; fill value: all pixels on

        ; ----- ERASE PASS: blank every scanline -----
        call    fill_screen
        db      0x00                    ; fill value: all pixels off

        ; ----- Read end tick count -----
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [es:BDA_TICKS_LO]
        mov     [tick_end], ax

        ; ----- Restore text mode -----
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [orig_equip]
        mov     [es:BDA_EQUIP], ax      ; restore equipment word before INT 10h

        xor     ah, ah
        mov     al, [orig_mode]
        int     0x10                    ; BIOS: set video mode (restores text)

        ; ----- Compute and print results -----
        ; tick_delta = tick_end - tick_start
        ; ms_approx  = tick_delta * 55   (true factor is 54.925; close enough)
        mov     ax, [tick_end]
        sub     ax, [tick_start]
        mov     [tick_delta], ax

        ; Print the tick count first
        mov     dx, msg_ticks
        mov     ah, 0x09
        int     0x21
        mov     ax, [tick_delta]
        call    print_word_decimal
        mov     dx, msg_crlf
        mov     ah, 0x09
        int     0x21

        ; Compute milliseconds: delta * 55
        ; MUL is 16x16->32 on 8088: DX:AX = AX * operand
        ; We only use AX (low 16 bits); for up to ~1193 ticks (~65.6 sec)
        ; the result fits in 16 bits.  Longer runs would overflow -- but
        ; if this benchmark takes over a minute something is very wrong.
        mov     ax, [tick_delta]
        mov     bx, 55
        mul     bx                      ; DX:AX = ticks * 55
        ; AX now holds milliseconds (low word)
        mov     dx, msg_ms
        push    ax                      ; save ms value
        mov     ah, 0x09
        int     0x21
        pop     ax
        call    print_word_decimal
        mov     dx, msg_ms_unit
        mov     ah, 0x09
        int     0x21

        ; ----- Exit -----
        mov     ax, 0x4C00
        int     0x21

; ---------------------------------------------------------------------------
; set_lemd_mode
;
; Activate the Leading Edge 720x348 enhanced monochrome graphics mode.
; Sequence from diagnose.com disassembly; confirmed on hardware.
; See lemd_enhanced_mono_spec.md section 2 for full explanation.
;
; Destroys: AX, CX, DX, SI, ES
; ---------------------------------------------------------------------------
set_lemd_mode:
        ; Step 1: Set BIOS equipment word bits [5:4] = 11b (MDA).
        ; OR in the bits rather than overwriting so other flags survive.
        mov     ax, BDA_SEG
        mov     es, ax
        or      word [es:BDA_EQUIP], 0x0030

        ; Step 2: Program the MC6845 CRTC.
        ; The MC6845 is the display timing chip.  It generates the horizontal
        ; and vertical sync signals and controls how many scan lines appear.
        ; We write register index to 0x3B4, then data to 0x3B5, for each of
        ; the 16 registers R0..R15.
        mov     si, crtc_vals           ; SI -> table of 16 register values
        xor     ah, ah                  ; AH = current register index (0..15)
        mov     cx, 16
.crtc_loop:
        mov     dx, PORT_CRTC_ADDR
        mov     al, ah
        out     dx, al                  ; write register index
        mov     dx, PORT_CRTC_DATA
        lodsb                           ; AL = next value from table, SI++
        out     dx, al                  ; write register value
        inc     ah
        loop    .crtc_loop

        ; Step 3: MDA Mode Control = 0x0A
        ; Bit 1 = graphics mode; bit 3 = video signal enable.
        mov     dx, PORT_MDA_MODE
        mov     al, 0x0A
        out     dx, al

        ; Step 4: CGA Mode Control = 0x1A
        ; Bit 1 = graphics; bit 3 = video enable; bit 4 = 640-wide.
        ; Both MDA and CGA ports must be written -- see spec ambiguity A2.
        mov     dx, PORT_CGA_MODE
        mov     al, 0x1A
        out     dx, al

        ; Step 5: CGA Color Select = 0x00 (irrelevant in mono mode)
        mov     dx, PORT_CGA_COLOR
        xor     al, al
        out     dx, al

        ; Step 6: Leading Edge proprietary control = 0x08.
        ; Port 0x3DD does not exist on standard IBM hardware.  Bit 3 is
        ; the enable flag for the enhanced mono mode.  Without this the
        ; CRTC reprogramming above has no visible effect.
        mov     dx, PORT_LE_CTRL
        mov     al, 0x08
        out     dx, al

        ret

; ---------------------------------------------------------------------------
; fill_screen
;
; Fill every active scanline with the byte value that IMMEDIATELY follows
; the CALL instruction in the caller's code stream.  This is a "near
; self-modifying" trick that lets us reuse one fill routine for both 0xFF
; and 0x00 without passing arguments through registers.
;
; How it works:
;   The CALL pushes the return address (= address of the byte after the
;   CALL opcode) onto the stack.  We pop it into SI, read the fill byte,
;   increment SI past it, push SI back, then RET to the incremented
;   address -- skipping over the inline operand.
;
; For each scanline Y (0..347):
;   bank      = Y AND 3          (which of the 4 interleaved banks)
;   row       = Y SHR 2          (which row within that bank)
;   offset    = bank*0x2000 + row*90
;
;   Then REP STOSB writes 90 bytes of the fill value starting at that offset.
;
; Destroys: AX, BX, CX, DX, DI, ES, SI  (all registers)
; ---------------------------------------------------------------------------
fill_screen:
        ; Retrieve the inline fill byte from the call site.
        pop     si                      ; SI = address of inline fill byte
        mov     al, [si]                ; AL = fill value (0xFF or 0x00)
        inc     si                      ; SI now points past the inline byte
        push    si                      ; push updated return address

        mov     [fill_val], al          ; stash fill value for the inner loop

        ; Point ES at the framebuffer segment.
        mov     ax, VID_SEG
        mov     es, ax

        ; Outer loop: BX = current scanline Y, 0..347.
        xor     bx, bx                  ; BX = Y = 0

.scanline_loop:
        ; ---- Compute bank base address ----
        ; bank = Y AND 3.  Each bank starts 0x2000 bytes after the previous.
        ; bank_base = bank * 0x2000 = (Y AND 3) << 13
        mov     ax, bx                  ; AX = Y
        and     ax, 0x0003              ; AX = bank (0-3)
        mov     cl, 13
        shl     ax, cl                  ; AX = bank * 0x2000
        mov     di, ax                  ; DI = bank base offset

        ; ---- Compute row offset within bank ----
        ; row = Y SHR 2.  Each row is 90 bytes.
        ; row_offset = row * 90
        ;
        ; Multiply by 90 using shifts and adds (no MUL needed, no 186+ opcodes):
        ;   90 = 64 + 16 + 8 + 2
        ;
        ; We keep row in DX and accumulate into CX.
        mov     ax, bx                  ; AX = Y
        shr     ax, 1
        shr     ax, 1                   ; AX = row = Y / 4

        mov     dx, ax                  ; DX = row (save for repeated shifts)

        ; row * 64
        mov     cx, dx
        shl     cx, 1
        shl     cx, 1
        shl     cx, 1
        shl     cx, 1
        shl     cx, 1
        shl     cx, 1                   ; CX = row * 64

        ; + row * 16
        mov     ax, dx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1                   ; AX = row * 16
        add     cx, ax

        ; + row * 8
        mov     ax, dx
        shl     ax, 1
        shl     ax, 1
        shl     ax, 1                   ; AX = row * 8
        add     cx, ax

        ; + row * 2
        mov     ax, dx
        shl     ax, 1                   ; AX = row * 2
        add     cx, ax                  ; CX = row * 90

        add     di, cx                  ; DI = bank_base + row * 90

        ; ---- Write 90 bytes ----
        mov     al, [fill_val]          ; reload fill byte (AX was clobbered)
        mov     cx, BYTES_PER_ROW       ; CX = 90
        rep     stosb                   ; ES:DI <- AL, 90 times; DI advances

        ; ---- Next scanline ----
        inc     bx                      ; Y++
        cmp     bx, SCREEN_H            ; 348 scanlines total
        jl      .scanline_loop

        ret

; ---------------------------------------------------------------------------
; print_word_decimal
;
; Print the 16-bit value in AX as an unsigned decimal string using INT 21h
; character output (AH=02h).  No leading zeros.
;
; Algorithm: repeatedly divide by 10, collect remainders, push them on the
; stack (which reverses their order), then pop and print.
;
; Destroys: AX, BX, CX, DX
; ---------------------------------------------------------------------------
print_word_decimal:
        mov     bx, 10                  ; divisor
        xor     cx, cx                  ; CX = digit count

.divide_loop:
        xor     dx, dx                  ; DX:AX = AX (zero-extend for DIV)
        div     bx                      ; AX = quotient, DX = remainder (digit)
        push    dx                      ; push digit (0-9) onto stack
        inc     cx                      ; one more digit
        test    ax, ax                  ; quotient == 0?
        jnz     .divide_loop            ; no -> keep dividing

.print_loop:
        pop     dx                      ; DL = digit (0-9)
        add     dl, '0'                 ; convert to ASCII
        mov     ah, 0x02
        int     0x21                    ; print character in DL
        loop    .print_loop

        ret

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------

; MC6845 register values R0..R15.
; Source: diagnose.com offset 0x25BE, confirmed by hardware.
; See lemd_enhanced_mono_spec.md section 2.2 for field definitions.
crtc_vals:
        db      0x35            ; R0  Horizontal Total
        db      0x2D            ; R1  Horizontal Displayed  (45 * 16 = 720 px)
        db      0x2E            ; R2  H Sync Position
        db      0x07            ; R3  Sync Widths
        db      0x5B            ; R4  Vertical Total
        db      0x02            ; R5  Vertical Total Adjust
        db      0x57            ; R6  Vertical Displayed    (87 rows * 4 = 348)
        db      0x57            ; R7  Vertical Sync Position
        db      0x02            ; R8  Interlace Mode
        db      0x03            ; R9  Max Scan Line Addr    (4 lines/row)
        db      0x00            ; R10 Cursor Start
        db      0x00            ; R11 Cursor End
        db      0x00            ; R12 Start Address High
        db      0x00            ; R13 Start Address Low
        db      0x00            ; R14 Cursor Address High
        db      0x00            ; R15 Cursor Address Low

; Saved state
orig_equip:     dw      0       ; BIOS equipment word on entry
orig_mode:      db      0       ; BIOS video mode number on entry

; Timing
tick_start:     dw      0
tick_end:       dw      0
tick_delta:     dw      0

; Temporary storage for fill value (avoids passing in a register)
fill_val:       db      0

; Messages -- '$' terminated for INT 21h AH=09h
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
