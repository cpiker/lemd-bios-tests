; =============================================================================
; lemdshow.asm
; Leading Edge Model D -- .lemd image viewer
;
; Target:    IBM PC compatible, Leading Edge Model D hardware
; Assembler: nasm -f bin -o lemdshow.com lemdshow.asm
; Format:    DOS COM (single segment, org 0x100)
; CPU:       8088 / 8086  (no 286+ opcodes, no FPU)
;
; Usage (from DOS prompt):
;   lemdshow image.lemd
;
; The named file must be a .lemd file produced by lemdconv: exactly
; 31,320 bytes in LEMD 4-bank interleave order.
;
; Sequence:
;   1. Pre-flight: confirm monochrome monitor is selected.
;   2. Save original equipment word and video mode.
;   3. Activate enhanced monochrome graphics mode.
;   4. Open the .lemd file via INT 21h.
;   5. Read and blit each of the 4 banks in turn:
;        read 7,830 bytes into scratch buffer
;        REP MOVSB from buffer into 0xB000:bank_offset
;   6. Close the file.
;   7. Wait for a keypress.
;   8. Restore text mode and exit.
;
; Why four reads instead of one big read:
;   A COM file lives in a single 64KB segment.  The scratch buffer (7,830
;   bytes, one bank) fits comfortably.  Reading the whole 31,320 bytes at
;   once would require either a large static buffer eating nearly half the
;   COM segment or a separate allocation scheme -- both unnecessary when the
;   hardware wants the data delivered in four bank-sized blobs anyway.
;
; File I/O uses INT 21h:
;   AH=3Dh -- open file (returns handle in AX)
;   AH=3Fh -- read from handle into DS:DX
;   AH=3Eh -- close handle
;   AH=01h -- wait for keypress (with echo; fine for our purposes)
;   AH=4Ch -- terminate program
;
; Framebuffer quick reference (see lemd_enhanced_mono_spec.md):
;   Segment  : 0xB000
;   Banks    : 4, at offsets 0x0000 / 0x2000 / 0x4000 / 0x6000
;   Bank size: 87 rows * 90 bytes = 7,830 bytes each
;   Total    : 4 * 7,830 = 31,320 bytes
; =============================================================================

        cpu     8086
        org     0x0100

; ---------------------------------------------------------------------------
; Constants
; ---------------------------------------------------------------------------

VID_SEG         equ     0xB000

LEMD_BANK_BYTES equ     7830            ; 87 rows * 90 bytes
LEMD_BANKS      equ     4
LEMD_TOTAL      equ     31320           ; LEMD_BANKS * LEMD_BANK_BYTES

BDA_SEG         equ     0x0040
BDA_EQUIP       equ     0x0010

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
        ; COM programs start with CS=DS=ES=SS.  We rely on DS for our own
        ; data and set ES explicitly whenever we need a different segment.

        ; ----- Locate filename argument in the PSP -----
        ; DOS places the command tail at PSP+0x80 (length byte) and
        ; PSP+0x81 (the characters, not null-terminated by DOS, but we
        ; will null-terminate it ourselves).
        ;
        ; The PSP occupies the first 256 bytes of the COM segment; since
        ; org is 0x100, the PSP is at DS:0x0000.
        mov     cl, [0x0080]            ; CL = command tail length
        xor     ch, ch                  ; CX = length (16-bit)
        test    cx, cx
        jz      .no_arg

        ; Null-terminate the filename in place so we can pass it to
        ; INT 21h AH=3Dh (which expects a DS:DX pointer to an ASCIIZ string).
        mov     si, 0x0081              ; SI -> start of command tail
        add     si, cx                  ; SI -> one past last character
        mov     byte [si], 0x00         ; null terminator

        ; Skip leading spaces in the command tail to find the filename.
        mov     si, 0x0081
.skip_space:
        mov     al, [si]
        cmp     al, ' '
        jne     .have_filename
        inc     si
        cmp     si, 0x0081
        jae     .skip_space             ; (safety: don't run past PSP)
        jmp     .no_arg

.have_filename:
        mov     [filename_ptr], si      ; save pointer to filename

        ; ----- Pre-flight: monochrome monitor must be selected -----
        ; BDA equipment word bits [5:4] = 11b (0x30) means MDA/mono.
        ; Any other value means the rear switch is in a CGA position and
        ; the enhanced mono mode will produce no output.
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

        ; ----- Save state -----
        ; We must restore the BIOS equipment word before calling INT 10h
        ; to set a text mode, because INT 10h reads it to determine what
        ; adapter is present.
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [es:BDA_EQUIP]
        mov     [orig_equip], ax

        mov     ah, 0x0F                ; BIOS get current video mode
        int     0x10
        mov     [orig_mode], al

        ; ----- Open the .lemd file -----
        ; INT 21h AH=3Dh: open file for reading
        ;   DS:DX -> ASCIIZ filename
        ;   AL    = 0 (read only)
        ; Returns: AX = file handle (on success), CF clear
        ;          CF set on error, AX = error code
        mov     dx, [filename_ptr]
        mov     ax, 0x3D00              ; AH=3Dh, AL=0 (read-only)
        int     0x21
        jnc     .open_ok
        mov     dx, msg_open_err
        mov     ah, 0x09
        int     0x21
        mov     ax, 0x4C01
        int     0x21
.open_ok:
        mov     [file_handle], ax

        ; ----- Activate enhanced mono mode -----
        ; We activate the mode AFTER opening the file to keep the screen
        ; in text mode as long as possible for error message visibility.
        call    set_lemd_mode

        ; ----- Clear the framebuffer to black before loading -----
        ; Without this, any previous framebuffer contents will be visible
        ; while the four banks load sequentially.
        call    clear_framebuffer

        ; ----- Read and blit each bank -----
        ; We iterate over banks 0..3.  For each bank:
        ;   1. Read LEMD_BANK_BYTES (7,830) bytes into scratch_buf.
        ;   2. Copy from scratch_buf into ES:DI (framebuffer bank).
        ;
        ; The .lemd file is already in bank order (bank 0 first), which
        ; is exactly what lemdconv wrote, so we read sequentially.
        ;
        ; BX = current bank index (0..3), used to compute bank offset.
        xor     bx, bx

.bank_loop:
        ; ---- Read one bank from file into scratch buffer ----
        ; INT 21h AH=3Fh: read from file
        ;   BX = file handle
        ;   CX = byte count to read
        ;   DS:DX -> destination buffer
        ; Returns: AX = bytes actually read, CF set on error.
        push    bx                      ; save bank index across INT call
        mov     bx, [file_handle]
        mov     cx, LEMD_BANK_BYTES
        mov     dx, scratch_buf
        mov     ah, 0x3F
        int     0x21
        pop     bx                      ; restore bank index
        jc      .read_err
        cmp     ax, LEMD_BANK_BYTES
        jne     .read_err               ; short read = truncated or wrong file

        ; ---- Blit scratch buffer into framebuffer bank ----
        ; bank offset = bank_index * 0x2000
        ; On 8088 we can only shift by 1 or by CL, and shifting BX (0..3)
        ; left 13 times would be tedious.  Instead we use a small lookup
        ; table of the four bank base offsets.
        mov     si, bx                  ; SI = bank index (0..3)
        shl     si, 1                   ; SI = index * 2 (word table offset)
        mov     di, [bank_offsets + si] ; DI = bank base offset in framebuffer

        ; Set up ES for the framebuffer segment.
        push    ds                      ; save DS (points to our COM segment)
        mov     ax, VID_SEG
        mov     es, ax                  ; ES = 0xB000

        ; Set DS:SI to scratch_buf for MOVSB.
        ; DS currently points to our COM segment -- scratch_buf is in it.
        ; We need DS for the source and ES for the destination.
        ; Since DS currently = our COM segment, we can set SI to scratch_buf.
        mov     si, scratch_buf         ; DS:SI -> source (scratch buffer)
        mov     cx, LEMD_BANK_BYTES     ; CX = byte count
        rep     movsb                   ; ES:DI <- DS:SI, CX times

        pop     ds                      ; restore DS to COM segment

        ; ---- Next bank ----
        inc     bx
        cmp     bx, LEMD_BANKS
        jl      .bank_loop

        ; ----- Close the file -----
        mov     bx, [file_handle]
        mov     ah, 0x3E
        int     0x21

        ; ----- Wait for keypress -----
        ; INT 21h AH=08h: read character without echo.
        ; (AH=01h echoes to screen; in graphics mode that corrupts the image.)
        mov     ah, 0x08
        int     0x21

        ; ----- Restore text mode and exit -----
.restore:
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [orig_equip]
        mov     [es:BDA_EQUIP], ax      ; restore equipment word before INT 10h

        xor     ah, ah
        mov     al, [orig_mode]
        int     0x10                    ; BIOS: restore original video mode

        mov     ax, 0x4C00
        int     0x21

        ; ---- Error paths ----
.no_arg:
        mov     dx, msg_usage
        mov     ah, 0x09
        int     0x21
        mov     ax, 0x4C01
        int     0x21

.read_err:
        ; We're already in graphics mode here, so we restore text first,
        ; then print the error message.
        mov     ax, BDA_SEG
        mov     es, ax
        mov     ax, [orig_equip]
        mov     [es:BDA_EQUIP], ax

        xor     ah, ah
        mov     al, [orig_mode]
        int     0x10

        mov     dx, msg_read_err
        mov     ah, 0x09
        int     0x21

        mov     bx, [file_handle]
        mov     ah, 0x3E
        int     0x21

        mov     ax, 0x4C01
        int     0x21

; ---------------------------------------------------------------------------
; set_lemd_mode
;
; Activate the Leading Edge 720x348 enhanced monochrome graphics mode.
; Sequence extracted from diagnose.com disassembly and confirmed on hardware.
; See lemd_enhanced_mono_spec.md section 2 for full explanation.
;
; Destroys: AX, CX, DX, SI, ES
; ---------------------------------------------------------------------------
set_lemd_mode:
        ; Step 1: Set BIOS equipment word bits [5:4] = 11b (MDA/mono).
        ; OR in the bits so other flags in the word survive.
        mov     ax, BDA_SEG
        mov     es, ax
        or      word [es:BDA_EQUIP], 0x0030

        ; Step 2: Program MC6845 CRTC registers R0..R15.
        ; Write register index to address port 0x3B4, then value to 0x3B5.
        mov     si, crtc_vals
        xor     ah, ah                  ; AH = register index
        mov     cx, 16
.crtc_loop:
        mov     dx, PORT_CRTC_ADDR
        mov     al, ah
        out     dx, al
        mov     dx, PORT_CRTC_DATA
        lodsb
        out     dx, al
        inc     ah
        loop    .crtc_loop

        ; Step 3: MDA Mode Control = 0x0A (graphics enable + video enable)
        mov     dx, PORT_MDA_MODE
        mov     al, 0x0A
        out     dx, al

        ; Step 4: CGA Mode Control = 0x1A (graphics + video + 640-wide)
        ; Both MDA and CGA ports are written -- see spec ambiguity A2.
        mov     dx, PORT_CGA_MODE
        mov     al, 0x1A
        out     dx, al

        ; Step 5: CGA Color Select = 0x00
        mov     dx, PORT_CGA_COLOR
        xor     al, al
        out     dx, al

        ; Step 6: Leading Edge proprietary control = 0x08 (enable bit).
        ; Port 0x3DD does not exist on standard IBM hardware.  Without
        ; this write the CRTC reprogramming has no visible effect.
        mov     dx, PORT_LE_CTRL
        mov     al, 0x08
        out     dx, al

        ret

; ---------------------------------------------------------------------------
; clear_framebuffer
;
; Fills the entire 0xB000 framebuffer window (0x0000..0x7FFF, 32,768 bytes)
; with 0x00.  This includes the small unused region beyond the active pixel
; data (see spec section 3 / ambiguity A8) which we zero as a precaution.
;
; Uses REP STOSB with ES:DI for the fill.
; Destroys: AX, CX, DI, ES
; ---------------------------------------------------------------------------
clear_framebuffer:
        mov     ax, VID_SEG
        mov     es, ax
        xor     di, di                  ; ES:DI = 0xB000:0x0000
        xor     al, al                  ; fill byte = 0x00
        mov     cx, 0x8000              ; 32,768 bytes
        rep     stosb
        ret

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------

; MC6845 register values R0..R15.
; Source: diagnose.com at offset 0x25BE, confirmed on hardware.
crtc_vals:
        db      0x35            ; R0  Horizontal Total
        db      0x2D            ; R1  Horizontal Displayed  (45 * 16 = 720px)
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

; Framebuffer bank base offsets for the four banks.
; bank 0 -> 0x0000, bank 1 -> 0x2000, bank 2 -> 0x4000, bank 3 -> 0x6000.
; Indexed as a word table: bank_offsets[bank * 2].
bank_offsets:
        dw      0x0000
        dw      0x2000
        dw      0x4000
        dw      0x6000

; Saved state
orig_equip:     dw      0
orig_mode:      db      0

; Open file handle (word, as returned by INT 21h AH=3Dh)
file_handle:    dw      0

; Pointer to the filename string in the PSP command tail (near pointer).
filename_ptr:   dw      0

; Messages
msg_usage:
        db      'Usage: lemdshow image.lemd', 0x0D, 0x0A
        db      'Displays a .lemd image on the LEMD enhanced monochrome screen.', 0x0D, 0x0A
        db      '$'

msg_wrong_monitor:
        db      'ERROR: Monochrome monitor not selected (check rear switch).', 0x0D, 0x0A
        db      '$'

msg_open_err:
        db      'ERROR: Cannot open file.', 0x0D, 0x0A
        db      '$'

msg_read_err:
        db      'ERROR: File read failed or file is not a valid .lemd image.', 0x0D, 0x0A
        db      '$'

; ---------------------------------------------------------------------------
; Scratch buffer -- one bank's worth of pixel data (7,830 bytes).
;
; Placed at the end of the data section.  The COM segment is 64KB; after
; code, tables, messages, and this buffer we use roughly 8,300 bytes total,
; well within the single-segment limit.
;
; The buffer must be in the DS segment (= COM segment) so that DS:DX is
; valid for INT 21h AH=3Fh, and DS:SI is valid for REP MOVSB.
; ---------------------------------------------------------------------------
scratch_buf:
        times   LEMD_BANK_BYTES db 0
