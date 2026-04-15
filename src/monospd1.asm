; lemd_perf.asm -- Leading Edge Model D Enhanced Mono Performance Tests
;
; Measures video RAM write throughput for the LEMD enhanced monochrome
; graphics mode (720x348, 4-bank interleave, 0xB000 segment).
;
; Four tests are run in sequence:
;
;   T-PERF-1  Full-frame sequential write to video RAM
;             Writes all 31,320 bytes of the active framebuffer in a tight
;             loop using REP STOSB.  Establishes the raw upper-bound write
;             speed to video memory and is the baseline for the flat-buffer
;             flush approach.
;
;   T-PERF-2  Full-frame sequential write to conventional RAM (control)
;             Identical loop, but the destination is a 32KB buffer in the
;             COM's data segment.  Isolates CPU/bus speed from video RAM
;             contention.  The ratio T-PERF-2 / T-PERF-1 gives the video
;             RAM slowdown factor directly.
;
;   T-PERF-3  Random-access per-pixel write to video RAM
;             Writes 250,560 individual pixels (one full screen worth) using
;             the proper bank-interleaved address formula, touching each byte
;             individually via MOV [es:bx], al.  This is the worst-case
;             drawing path -- simulates what a per-pixel primitive engine
;             experiences.  Each write lands in a different bank (the 4-bank
;             interleave means sequential Y values jump 0x2000 bytes apart),
;             maximising bus contention and cache thrashing on any buffering
;             in the glue logic.
;
;   T-PERF-4  Per-bank sequential write to video RAM
;             Writes each of the four 7,830-byte banks sequentially rather
;             than interleaved by scanline.  Simulates the optimised blit
;             path described in spec section 11.3: process all 87 rows of
;             bank 0, then bank 1, etc.  Expected to be significantly faster
;             than T-PERF-3 because the access pattern is contiguous within
;             each bank.
;
; Timing uses the BIOS real-time clock tick counter at 0040:006C (18.2 Hz).
; Each test runs ITER_COUNT iterations so that at least several ticks
; accumulate, giving meaningful resolution despite the coarse clock.
;
; Output is printed to the screen in text mode after returning from enhanced
; mono mode.  Each line shows:
;   Test name | iterations | ticks elapsed | bytes/tick (derived)
;
; To convert bytes/tick to KB/s:  (bytes_per_tick * 18.2) / 1024
;
; Build:
;   nasm -f bin -o lemd_perf.com lemd_perf.asm
;
; Run on the physical Model D under DOS with a monochrome monitor connected.
; The enhanced mono mode must be activatable (rear switch = mono).
; The program performs the monitor type pre-flight check and aborts with an
; error message if the switch is set to CGA.

        cpu     8086
        org     0x0100

; ---------------------------------------------------------------------------
; Constants
; ---------------------------------------------------------------------------

; Video RAM segment -- same as MDA
VID_SEG         equ     0xB000

; Active framebuffer geometry
BYTES_PER_ROW   equ     90              ; 720 pixels / 8 bits = 90 bytes
ROWS_PER_BANK   equ     87              ; 348 scanlines / 4 banks = 87 rows
NUM_BANKS       equ     4
BANK_SIZE       equ     BYTES_PER_ROW * ROWS_PER_BANK   ; 7,830 bytes
ACTIVE_BYTES    equ     BANK_SIZE * NUM_BANKS            ; 31,320 bytes
BANK_STRIDE     equ     0x2000          ; bytes between bank base addresses

; Total pixels on screen
TOTAL_PIXELS    equ     720 * 348       ; 250,560

; Number of iterations per test.  At 18.2 Hz we want >= 5 ticks of runtime
; for decent precision.  Rough estimate: even at 1 MB/s raw, 31,320 bytes
; takes ~31ms, so 10 iterations = ~310ms = ~5 ticks.  Adjust ITER_COUNT
; upward if the hardware is faster than expected.
ITER_COUNT      equ     20

; BIOS tick counter location (double word, low word sufficient for our delta)
TICK_SEG        equ     0x0040
TICK_OFF        equ     0x006C

; Port assignments -- see spec section 7
PORT_MDA_CRTC_ADDR      equ     0x3B4
PORT_MDA_CRTC_DATA      equ     0x3B5
PORT_MDA_MODE           equ     0x3B8
PORT_CGA_MODE           equ     0x3D8
PORT_CGA_COLOR          equ     0x3D9
PORT_LE_CTRL            equ     0x3DD

; ---------------------------------------------------------------------------
; Entry point
; ---------------------------------------------------------------------------
start:
        ; COM programs start with CS=DS=ES=SS, IP=0x100.
        ; We rely on DS throughout for our data segment.

        ; --- Pre-flight: verify monochrome monitor is selected ---
        ; The BIOS equipment word at 0040:0010, bits [5:4] = 11b means MDA/mono.
        ; Any other value means a CGA monitor is configured and the enhanced
        ; mode will produce no useful output on the mono connector.
        mov     ax, 0x0040
        mov     es, ax
        mov     ax, [es:0x10]           ; equipment word
        and     ax, 0x0030              ; isolate display type bits [5:4]
        cmp     ax, 0x0030              ; 0x30 = MDA / monochrome
        je      .mono_ok
        ; Wrong monitor type -- print error and exit
        mov     dx, msg_wrong_monitor
        mov     ah, 0x09
        int     0x21
        mov     ax, 0x4C01              ; exit with error code 1
        int     0x21
.mono_ok:

        ; --- Save current video mode so we can restore it ---
        mov     ah, 0x0F
        int     0x10
        mov     [saved_mode], al        ; current mode number
        mov     [saved_page], bh        ; current display page

        ; --- Activate the enhanced monochrome graphics mode ---
        ; Sequence per spec section 2.  Order is significant.
        call    activate_enhanced_mode

        ; --- Blank the framebuffer (all pixels off = black screen) ---
        call    blank_vram

        ; --- Run the four performance tests ---
        call    test_perf1_vram_seq
        call    test_perf2_conv_seq
        call    test_perf3_vram_random
        call    test_perf4_vram_per_bank

        ; --- Restore previous video mode ---
        xor     ah, ah
        mov     al, [saved_mode]
        int     0x10

        ; Restore DS = our segment (INT 10h may have clobbered ES but not DS)
        ; Actually on 8088 INT doesn't touch DS, but be explicit.

        ; --- Print results to text mode screen ---
        ; Print header
        mov     dx, msg_header
        mov     ah, 0x09
        int     0x21

        ; Print each test result line
        call    print_result1
        call    print_result2
        call    print_result3
        call    print_result4

        ; Print the conversion note
        mov     dx, msg_footer
        mov     ah, 0x09
        int     0x21

        ; --- Exit cleanly ---
        mov     ax, 0x4C00
        int     0x21

; ---------------------------------------------------------------------------
; activate_enhanced_mode
;
; Programs the MC6845 CRTC and supporting ports to enable the LEMD enhanced
; monochrome graphics mode, per spec section 2.
;
; Destroys: AX, CX, DX, SI
; ---------------------------------------------------------------------------
activate_enhanced_mode:
        ; Step 1: Set BIOS equipment word bits [5:4] = 11b (MDA)
        ; Per spec ambiguity A1, this may not be strictly required by hardware
        ; but is safe and keeps the BDA consistent.
        mov     ax, 0x0040
        mov     es, ax
        or      word [es:0x10], 0x0030

        ; Step 2: Program the MC6845 CRTC
        ; The 16 register values come from diagnose.com at file offset 0x25BE,
        ; confirmed by hardware testing.  See spec Table in section 2.2.
        mov     si, crtc_table          ; SI -> register value table
        mov     cx, 16                  ; 16 registers (R0..R15)
        xor     ah, ah                  ; AH = register index, starts at 0
.crtc_loop:
        mov     dx, PORT_MDA_CRTC_ADDR
        mov     al, ah                  ; register index
        out     dx, al
        mov     dx, PORT_MDA_CRTC_DATA
        lodsb                           ; AL = value from table, SI++
        out     dx, al
        inc     ah
        loop    .crtc_loop

        ; Step 3: MDA Mode Control -- 0x0A = graphics mode enable + video enable
        mov     dx, PORT_MDA_MODE
        mov     al, 0x0A
        out     dx, al

        ; Step 4: CGA Mode Control -- 0x1A = graphics + video + 640-wide
        ; Why both MDA and CGA ports?  See spec ambiguity A2.  The hardware
        ; appears to monitor both port ranges simultaneously.
        mov     dx, PORT_CGA_MODE
        mov     al, 0x1A
        out     dx, al

        ; Step 5: CGA Color Select -- 0x00 (no colour, mono mode)
        mov     dx, PORT_CGA_COLOR
        xor     al, al
        out     dx, al

        ; Step 6: Leading Edge proprietary control -- bit 3 enables enhanced mode
        ; This port (0x3DD) does not exist on standard IBM CGA or MDA cards.
        ; See spec ambiguity A3 for the unknown bit definitions.
        mov     dx, PORT_LE_CTRL
        mov     al, 0x08
        out     dx, al

        ret

; MC6845 register values for enhanced mono mode (R0..R15)
; Source: diagnose.com offset 0x25BE, confirmed by hardware test.
crtc_table:
        db      0x35    ; R0  Horizontal Total      (53 char clocks)
        db      0x2D    ; R1  Horizontal Displayed  (45 chars * 16px = 720px)
        db      0x2E    ; R2  H Sync Position
        db      0x07    ; R3  Sync Widths           (HSync=7, VSync=0)
        db      0x5B    ; R4  Vertical Total        (91 char rows)
        db      0x02    ; R5  Vertical Total Adjust (+2 scanlines)
        db      0x57    ; R6  Vertical Displayed    (87 rows * 4 scans = 348)
        db      0x57    ; R7  Vertical Sync Pos
        db      0x02    ; R8  Interlace Mode        (interlace sync+video)
        db      0x03    ; R9  Max Scan Line Addr    (4 scanlines/char row)
        db      0x00    ; R10 Cursor Start          (cursor disabled)
        db      0x00    ; R11 Cursor End
        db      0x00    ; R12 Start Address High    (framebuffer at 0x0000)
        db      0x00    ; R13 Start Address Low
        db      0x00    ; R14 Cursor Address High
        db      0x00    ; R15 Cursor Address Low

; ---------------------------------------------------------------------------
; blank_vram
;
; Writes 0x00 to all 32KB of the video RAM window at 0xB000:0000..0x7FFF.
; We blank the full window (not just active bytes) to avoid stale data in
; the unused upper region (see spec ambiguity A8).
;
; Destroys: AX, CX, DI, ES
; ---------------------------------------------------------------------------
blank_vram:
        mov     ax, VID_SEG
        mov     es, ax
        xor     di, di                  ; ES:DI = 0xB000:0x0000
        xor     al, al                  ; fill value = 0 (all pixels off)
        mov     cx, 0x8000              ; 32,768 bytes = full window
        rep     stosb
        ret

; ---------------------------------------------------------------------------
; read_ticks  -- returns current low word of BIOS tick counter in AX
;
; The BIOS maintains a 32-bit tick counter at 0040:006C that increments at
; 18.2 Hz (once per timer interrupt).  We use only the low 16 bits, which
; overflow after ~3,600 seconds -- more than enough for our test durations.
;
; Destroys: AX, ES
; ---------------------------------------------------------------------------
read_ticks:
        push    bx
        mov     bx, TICK_SEG
        mov     es, bx
        mov     ax, [es:TICK_OFF]       ; low word of tick counter
        pop     bx
        ret

; ---------------------------------------------------------------------------
; T-PERF-1: Sequential full-frame write to video RAM
;
; Writes ACTIVE_BYTES bytes (31,320) to the framebuffer ITER_COUNT times,
; starting at 0xB000:0x0000 and writing linearly through the full active
; region.  Note that this linear write traverses all four banks in order
; (0x0000..0x1E96 is bank 0, 0x2000..0x3E96 is bank 1, etc.), so the
; access pattern IS sequential within each bank, but the banks are written
; in sequence rather than interleaved.
;
; This test answers: "How long does a flat-buffer flush take?"
;
; Result stored in: result1_iters, result1_ticks
; Destroys: AX, BX, CX, DX, DI, ES
; ---------------------------------------------------------------------------
test_perf1_vram_seq:
        call    read_ticks
        mov     [result1_start], ax     ; record start tick

        mov     bx, ITER_COUNT          ; outer loop: number of iterations
        mov     ax, VID_SEG
        mov     es, ax

.iter_loop:
        xor     di, di                  ; start of framebuffer each iteration
        mov     al, 0xFF                ; fill all pixels ON (white screen)
        mov     cx, ACTIVE_BYTES        ; 31,320 bytes
        rep     stosb
        dec     bx
        jnz     .iter_loop

        call    read_ticks
        sub     ax, [result1_start]     ; elapsed ticks
        mov     [result1_ticks], ax
        mov     word [result1_iters], ITER_COUNT
        ret

; ---------------------------------------------------------------------------
; T-PERF-2: Sequential full-frame write to conventional RAM (control test)
;
; Identical to T-PERF-1 but the destination is conv_buf in the COM's data
; segment (conventional RAM, typically in the first 640KB, no video bus
; contention).
;
; Ratio result1_ticks / result2_ticks gives the video RAM slowdown factor.
; If video RAM is 3x slower, expect result1_ticks ~= 3 * result2_ticks.
;
; Result stored in: result2_iters, result2_ticks
; Destroys: AX, BX, CX, DX, DI, ES
; ---------------------------------------------------------------------------
test_perf2_conv_seq:
        call    read_ticks
        mov     [result2_start], ax

        mov     bx, ITER_COUNT
        ; ES:DI -> conv_buf in our data segment
        mov     ax, ds
        mov     es, ax

.iter_loop:
        mov     di, conv_buf
        mov     al, 0xFF
        mov     cx, ACTIVE_BYTES
        rep     stosb
        dec     bx
        jnz     .iter_loop

        call    read_ticks
        sub     ax, [result2_start]
        mov     [result2_ticks], ax
        mov     word [result2_iters], ITER_COUNT
        ret

; ---------------------------------------------------------------------------
; T-PERF-3: Random-access per-pixel write to video RAM
;
; Iterates over every (x, y) coordinate in raster order and writes a single
; pixel using the proper bank-interleaved address formula:
;
;   bank   = y AND 3
;   row    = y SHR 2
;   offset = (bank << 13) + (row * 90) + (x >> 3)
;
; This hits all four banks on every four successive Y values, causing the
; memory access pattern to sawtooth across 24KB (three bank offsets of
; 0x2000 apart).  This is the adversarial case for any write-buffering in
; the glue logic.  It is also what a naive per-pixel drawing routine does.
;
; To keep iteration count manageable (one full screen = 250,560 pixels,
; which is already a lot), we run only ITER_COUNT/4 outer iterations.
;
; Result stored in: result3_iters, result3_ticks
; Destroys: AX, BX, CX, DX, SI, DI, ES, BP
; ---------------------------------------------------------------------------
test_perf3_vram_random:
        call    read_ticks
        mov     [result3_start], ax

        mov     ax, VID_SEG
        mov     es, ax

        ; Outer iteration loop
        mov     bp, ITER_COUNT / 4      ; fewer iters because inner loop is huge

.outer_loop:
        ; Inner loops: y from 0..347, x from 0..719 (in bytes: 0..89)
        xor     dx, dx                  ; DX = y (0..347)

.y_loop:
        ; Compute bank and row from Y
        ; bank = y AND 3  (which bank this scanline lives in)
        ; row  = y SHR 2  (which row within the bank)
        mov     ax, dx
        and     ax, 0x03                ; AX = bank (0..3)
        mov     cl, 3
        shl     ax, cl                  ; AX = bank * 8 (will become bank << 13)
        ; We need bank << 13.  We have bank * 8 in AX.  bank << 13 = bank*8 * 0x1000.
        ; But that overflows 16-bit if we just multiply.  Instead, store bank offset
        ; as a segment offset directly.
        ; bank 0: 0x0000, bank 1: 0x2000, bank 2: 0x4000, bank 3: 0x6000
        ; Easier: use a lookup table.
        mov     ax, dx
        and     ax, 0x03                ; AX = bank (0..3)
        mov     si, ax
        shl     si, 1                   ; SI = bank * 2 (word index into table)
        mov     bx, [bank_offsets + si] ; BX = bank base offset

        ; row = y >> 2
        mov     ax, dx
        shr     ax, 1
        shr     ax, 1                   ; AX = row (0..86)

        ; row * 90 -- multiply AX by 90
        ; 90 = 64 + 16 + 8 + 2, but easier: mul by constant
        ; AX * 90: use the fact that 90 = 2 * 45 = 2 * 5 * 9
        ; Simplest correct approach on 8088: use MUL (16-bit)
        mov     cx, BYTES_PER_ROW       ; 90
        mul     cx                      ; DX:AX = row * 90 (DX always 0 here)
        add     bx, ax                  ; BX = bank_offset + row * 90

        ; Now iterate over x bytes within this scanline (0..89)
        ; Each byte = 8 pixels; we write the whole byte at once.
        mov     cx, BYTES_PER_ROW       ; 90 bytes per row
        mov     al, 0xAA                ; alternating pixel pattern (1010_1010)

.x_loop:
        mov     [es:bx], al             ; write one byte (8 pixels) to video RAM
        inc     bx
        loop    .x_loop

        inc     dx                      ; next scanline
        cmp     dx, 348
        jl      .y_loop

        dec     bp
        jnz     .outer_loop

        call    read_ticks
        sub     ax, [result3_start]
        mov     [result3_ticks], ax
        mov     word [result3_iters], ITER_COUNT / 4
        ret

; Bank base offsets for T-PERF-3 and T-PERF-4
; bank 0 = 0x0000, bank 1 = 0x2000, bank 2 = 0x4000, bank 3 = 0x6000
bank_offsets:
        dw      0x0000, 0x2000, 0x4000, 0x6000

; ---------------------------------------------------------------------------
; T-PERF-4: Per-bank sequential write to video RAM
;
; Writes all 87 rows of bank 0 contiguously, then bank 1, bank 2, bank 3.
; This is the memory access pattern of an optimised blit as described in
; spec section 11.3.  Each bank is a contiguous 7,830-byte region, so
; REP STOSB can be used for the full bank in one shot.
;
; Expected to be significantly faster than T-PERF-3 (which zigzags between
; banks on every scanline) and comparable to T-PERF-1 (which also writes
; contiguous memory, but driven by REP STOSB rather than explicit loops).
; Any difference between T-PERF-1 and T-PERF-4 reveals the overhead of the
; bank-setup bookkeeping in T-PERF-4's inner loop.
;
; Result stored in: result4_iters, result4_ticks
; Destroys: AX, BX, CX, DI, ES
; ---------------------------------------------------------------------------
test_perf4_vram_per_bank:
        call    read_ticks
        mov     [result4_start], ax

        mov     ax, VID_SEG
        mov     es, ax
        mov     bx, ITER_COUNT

.outer_loop:
        ; Write bank 0: offset 0x0000, 7,830 bytes
        mov     di, 0x0000
        mov     al, 0x55                ; alternating pattern (0101_0101)
        mov     cx, BANK_SIZE
        rep     stosb

        ; Write bank 1: offset 0x2000
        mov     di, 0x2000
        mov     cx, BANK_SIZE
        rep     stosb

        ; Write bank 2: offset 0x4000
        mov     di, 0x4000
        mov     cx, BANK_SIZE
        rep     stosb

        ; Write bank 3: offset 0x6000
        mov     di, 0x6000
        mov     cx, BANK_SIZE
        rep     stosb

        dec     bx
        jnz     .outer_loop

        call    read_ticks
        sub     ax, [result4_start]
        mov     [result4_ticks], ax
        mov     word [result4_iters], ITER_COUNT
        ret

; ---------------------------------------------------------------------------
; Result printing routines
;
; Each routine prints one line:
;   <label>  iters=<N>  ticks=<N>  bytes/tick=<N>
;
; The bytes/tick figure is computed as:
;   T-PERF-1/2/4: (ACTIVE_BYTES * iters) / ticks
;   T-PERF-3:     (ACTIVE_BYTES * iters) / ticks  (same formula; fewer iters)
;
; All division is 16-bit and will saturate at 65535 for very fast results.
; If ticks = 0, print "TOO FAST" instead of dividing by zero.
;
; Destroys: AX, BX, CX, DX, SI
; ---------------------------------------------------------------------------

; Helper: print a decimal number in AX (unsigned 16-bit, max 65535)
; Uses a simple divide-by-10 approach, printing digits right-to-left via stack.
print_dec:
        push    bp
        mov     bp, sp
        mov     cx, 0                   ; digit count

.divide_loop:
        xor     dx, dx
        mov     bx, 10
        div     bx                      ; AX = quotient, DX = remainder
        push    dx                      ; push digit (0..9)
        inc     cx
        test    ax, ax
        jnz     .divide_loop

.print_loop:
        pop     dx
        add     dl, '0'
        mov     ah, 0x02
        int     0x21
        loop    .print_loop

        pop     bp
        ret

; Helper: print a string at DS:DX ($ terminated)
print_str:
        mov     ah, 0x09
        int     0x21
        ret

; Common result print routine.
; Parameters (passed via variables set by caller):
;   prt_label  -- pointer to label string ($ terminated, up to 30 chars)
;   prt_iters  -- iteration count
;   prt_ticks  -- ticks elapsed
;   prt_bytes  -- bytes written per iteration (for bytes/tick calculation)
print_one_result:
        ; Print label
        mov     dx, [prt_label]
        call    print_str

        ; Print " iters="
        mov     dx, msg_iters
        call    print_str
        mov     ax, [prt_iters]
        call    print_dec

        ; Print "  ticks="
        mov     dx, msg_ticks
        call    print_str
        mov     ax, [prt_ticks]
        call    print_dec

        ; Compute and print bytes/tick
        mov     dx, msg_bpt
        call    print_str

        mov     ax, [prt_ticks]
        test    ax, ax
        jz      .too_fast

        ; bytes/tick = (bytes_per_iter * iters) / ticks
        ; We must avoid 16-bit overflow: ACTIVE_BYTES (31320) * ITER_COUNT (20)
        ; = 626,400 which overflows 16 bits.  Use 32-bit divide:
        ; DX:AX = bytes_per_iter * iters  (using 16x16=32 MUL)
        mov     ax, [prt_bytes]         ; bytes per iteration
        mov     bx, [prt_iters]
        mul     bx                      ; DX:AX = product
        ; Now divide DX:AX by ticks (in CX)
        mov     cx, [prt_ticks]
        div     cx                      ; AX = quotient (bytes/tick), DX = remainder
        call    print_dec
        jmp     .done

.too_fast:
        mov     dx, msg_too_fast
        call    print_str

.done:
        mov     dx, msg_crlf
        call    print_str
        ret

; Convenience wrappers: set prt_* variables and call print_one_result

print_result1:
        mov     word [prt_label], msg_t1
        mov     ax, [result1_iters]
        mov     [prt_iters], ax
        mov     ax, [result1_ticks]
        mov     [prt_ticks], ax
        mov     word [prt_bytes], ACTIVE_BYTES
        call    print_one_result
        ret

print_result2:
        mov     word [prt_label], msg_t2
        mov     ax, [result2_iters]
        mov     [prt_iters], ax
        mov     ax, [result2_ticks]
        mov     [prt_ticks], ax
        mov     word [prt_bytes], ACTIVE_BYTES
        call    print_one_result
        ret

print_result3:
        mov     word [prt_label], msg_t3
        mov     ax, [result3_iters]
        mov     [prt_iters], ax
        mov     ax, [result3_ticks]
        mov     [prt_ticks], ax
        mov     word [prt_bytes], ACTIVE_BYTES
        call    print_one_result
        ret

print_result4:
        mov     word [prt_label], msg_t4
        mov     ax, [result4_iters]
        mov     [prt_iters], ax
        mov     ax, [result4_ticks]
        mov     [prt_ticks], ax
        mov     word [prt_bytes], ACTIVE_BYTES
        call    print_one_result
        ret

; ---------------------------------------------------------------------------
; Data segment
; ---------------------------------------------------------------------------

; Saved state for mode restore
saved_mode      db      0x07            ; default: MDA text mode 7
saved_page      db      0x00

; Per-test result storage
result1_start   dw      0
result1_iters   dw      0
result1_ticks   dw      0

result2_start   dw      0
result2_iters   dw      0
result2_ticks   dw      0

result3_start   dw      0
result3_iters   dw      0
result3_ticks   dw      0

result4_start   dw      0
result4_iters   dw      0
result4_ticks   dw      0

; Print helper temporaries
prt_label       dw      0
prt_iters       dw      0
prt_ticks       dw      0
prt_bytes       dw      0

; Strings ($ terminated for INT 21h AH=09)
msg_wrong_monitor:
        db      "ERROR: Monochrome monitor not selected (check rear switch).", 0x0D, 0x0A
        db      "Enhanced mono mode requires mono connector and switch set to MDA.", 0x0D, 0x0A, "$"

msg_header:
        db      0x0D, 0x0A
        db      "LEMD Enhanced Mono -- Video RAM Write Performance", 0x0D, 0x0A
        db      "-------------------------------------------------", 0x0D, 0x0A
        db      "$"

msg_t1: db      "T-PERF-1 VRAM seq  ", "$"
msg_t2: db      "T-PERF-2 Conv seq  ", "$"
msg_t3: db      "T-PERF-3 VRAM rand ", "$"
msg_t4: db      "T-PERF-4 VRAM bank ", "$"

msg_iters:      db      " iters=", "$"
msg_ticks:      db      "  ticks=", "$"
msg_bpt:        db      "  bytes/tick=", "$"
msg_too_fast:   db      "TOO FAST (< 1 tick)", "$"
msg_crlf:       db      0x0D, 0x0A, "$"

msg_footer:
        db      0x0D, 0x0A
        db      "To convert: KB/s = (bytes/tick * 18.2) / 1024", 0x0D, 0x0A
        db      "Slowdown = T-PERF-1 ticks / T-PERF-2 ticks", 0x0D, 0x0A
        db      "$"

; Conventional RAM buffer for T-PERF-2 (control test)
; Must be at least ACTIVE_BYTES = 31,320 bytes.  Placed here in the data
; segment.  A COM file's total size including this buffer must fit under
; ~60KB to leave stack room.  31,320 bytes is well within that.
conv_buf:       times ACTIVE_BYTES db 0
