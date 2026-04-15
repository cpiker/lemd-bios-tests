; bdainfo.asm -- BIOS Data Area equipment word decoder
;
; Reads the BIOS equipment word at 0040:0010 and decodes every
; bit field into human-readable output.  Also samples a handful
; of other BDA locations useful for understanding machine state.
;
; Intended use: run once with the rear switch in MDA/mono position,
; once with it in CGA position, and compare the output.  The key
; field for the Leading Edge Model D driver is bits [5:4] of the
; equipment word, which reflects the physical rear switch.
;
; Build:   nasm -f bin -o bdainfo.com bdainfo.asm
; Run:     bdainfo.com        (FreeDOS or any DOS-compatible environment)
;
; Calling conventions used throughout this file:
;
;   print_str        DX = near offset of '$'-terminated string.
;   print_hex16      AX = 16-bit value to print.
;   print_hex8       AL = 8-bit value to print.
;   print_decimal_byte  AX = 0-255 value to print.
;   print_decimal16  AX = 0-65535 value to print.
;   print_crlf       no arguments.
;
;   ALL subroutines preserve every register they touch.
;   The caller never needs to worry about clobber.  Inputs are
;   passed in registers as noted; everything else comes back intact.
;
; Reference: IBM PC Technical Reference Manual, Appendix A (BDA map).
; ======================================================================

        cpu     8086
        org     0x0100

; -----------------------------------------------------------------------
; BIOS Data Area constants  (offsets within segment 0x0040)
; -----------------------------------------------------------------------
BDA_SEG         equ     0x0040

BDA_EQUIP       equ     0x0010  ; equipment word (16-bit)     <-- main target
BDA_MEM_KB      equ     0x0013  ; conventional memory in KB (16-bit)
BDA_KB_FLAGS1   equ     0x0017  ; keyboard shift state, byte 1
BDA_KB_FLAGS2   equ     0x0018  ; keyboard shift state, byte 2
BDA_CUR_MODE    equ     0x0049  ; current video mode number (byte)
BDA_NUM_COLS    equ     0x004A  ; screen width in columns (16-bit)
BDA_TICKS_LO    equ     0x006C  ; IRQ0 tick counter, low word
BDA_TICKS_HI    equ     0x006E  ; IRQ0 tick counter, high word

; -----------------------------------------------------------------------
; Entry point
; COM programs start with CS=DS=ES=SS all set to the PSP segment.
; We use DS for our own data throughout.
; -----------------------------------------------------------------------
start:
        ; Point ES at the BDA and snapshot every value we need into
        ; our own data segment.  Collect everything in one block so
        ; ES is only diverted briefly and print routines never see it
        ; pointing anywhere unexpected.
        mov     ax, BDA_SEG
        mov     es, ax

        mov     ax, [es:BDA_EQUIP]
        mov     [equip], ax

        mov     ax, [es:BDA_MEM_KB]
        mov     [mem_kb], ax

        mov     al, [es:BDA_KB_FLAGS1]
        mov     [kb_flags1], al

        mov     al, [es:BDA_KB_FLAGS2]
        mov     [kb_flags2], al

        mov     al, [es:BDA_CUR_MODE]
        mov     [cur_mode], al

        mov     ax, [es:BDA_NUM_COLS]
        mov     [num_cols], ax

        mov     ax, [es:BDA_TICKS_LO]
        mov     [ticks_lo], ax

        mov     ax, [es:BDA_TICKS_HI]
        mov     [ticks_hi], ax

        ; Restore ES = DS so string addressing works normally from here.
        push    ds
        pop     es

        ; ---------------------------------------------------------------
        ; Banner
        ; ---------------------------------------------------------------
        mov     dx, msg_banner
        call    print_str

        ; ---------------------------------------------------------------
        ; Section 1 -- Equipment Word
        ; ---------------------------------------------------------------
        mov     dx, msg_section_equip
        call    print_str

        ; Raw value in hex
        mov     dx, msg_equip_raw
        call    print_str
        mov     ax, [equip]
        call    print_hex16
        call    print_crlf

        ; Raw binary pattern -- easy to read fields by eye
        mov     dx, msg_equip_bits
        call    print_str
        mov     ax, [equip]
        call    print_bits16
        call    print_crlf

        ; ---------------------------------------------------------------
        ; Decode each field of the equipment word.
        ;
        ; IBM PC BIOS equipment word bit assignments:
        ;
        ;  Bit   0      Floppy drive(s) installed (1 = yes)
        ;  Bit   1      8087 math coprocessor present (1 = yes)
        ;  Bits [3:2]   System board RAM (PC only; meaningless on XT/AT)
        ;                 00=16KB  01=32KB  10=48KB  11=64KB
        ;  Bits [5:4]   Display adapter / initial video mode
        ;                 0x00 = no display
        ;                 0x10 = CGA 40-column
        ;                 0x20 = CGA 80-column
        ;                 0x30 = MDA monochrome  <-- switch pos for Model D
        ;  Bits [7:6]   Floppy drive count minus 1 (valid only if bit 0=1)
        ;                 00=1 drive  01=2 drives  10=3  11=4
        ;  Bit   8      DMA chip absent (0 = DMA present; logic inverted)
        ;  Bits [11:9]  Number of RS-232 serial ports installed (0-7)
        ;  Bit  12      Game/joystick port attached (1 = yes)
        ;  Bit  13      Serial printer attached (rarely used)
        ;  Bits [15:14] Number of LPT parallel ports (0-3)
        ; ---------------------------------------------------------------

        mov     ax, [equip]

        ; --- Bit 0: floppy installed ---
        mov     dx, msg_floppy
        call    print_str
        test    ax, 0x0001
        jz      .no_floppy
        mov     dx, msg_yes
        call    print_str
        jmp     .after_floppy
.no_floppy:
        mov     dx, msg_no
        call    print_str
.after_floppy:
        call    print_crlf

        ; --- Bits [7:6]: floppy drive count (only meaningful if bit 0 = 1) ---
        ; Stored as (count - 1), so 00b = 1 drive, 01b = 2 drives, etc.
        mov     dx, msg_floppy_count
        call    print_str
        test    ax, 0x0001              ; is bit 0 set?
        jz      .floppy_na
        mov     bx, ax
        and     bx, 0x00C0             ; isolate bits [7:6]
        mov     cl, 6
        shr     bx, cl                 ; shift right 6; CL form required on 8088
        inc     bx                     ; stored as count-1, so add 1
        mov     ax, bx
        call    print_decimal_byte
        mov     ax, [equip]            ; restore AX for subsequent tests
        jmp     .after_floppy_count
.floppy_na:
        mov     dx, msg_na
        call    print_str
.after_floppy_count:
        call    print_crlf

        ; --- Bit 1: 8087 math coprocessor ---
        mov     dx, msg_fpu
        call    print_str
        test    ax, 0x0002
        jz      .no_fpu
        mov     dx, msg_yes
        call    print_str
        jmp     .after_fpu
.no_fpu:
        mov     dx, msg_no
        call    print_str
.after_fpu:
        call    print_crlf

        ; --- Bits [3:2]: system board RAM (original PC only) ---
        ; On XT and later this field is not meaningful.  On the original
        ; IBM PC it records how much RAM is soldered to the motherboard.
        mov     dx, msg_ramsize
        call    print_str
        mov     bx, ax
        and     bx, 0x000C
        cmp     bx, 0x0000
        je      .ram16
        cmp     bx, 0x0004
        je      .ram32
        cmp     bx, 0x0008
        je      .ram48
        mov     dx, msg_ram64          ; 0x000C
        call    print_str
        jmp     .after_ram
.ram16: mov     dx, msg_ram16
        call    print_str
        jmp     .after_ram
.ram32: mov     dx, msg_ram32
        call    print_str
        jmp     .after_ram
.ram48: mov     dx, msg_ram48
        call    print_str
.after_ram:
        call    print_crlf

        ; --- Bits [5:4]: display adapter type ---
        ; This is THE field written by the physical rear switch on the
        ; Model D.  The BIOS reads the switch during POST and writes
        ; the result here.  A driver must check for 0x30 before
        ; activating the enhanced monochrome graphics mode.
        mov     dx, msg_video
        call    print_str
        mov     bx, ax
        and     bx, 0x0030
        cmp     bx, 0x0000
        je      .vid_none
        cmp     bx, 0x0010
        je      .vid_cga40
        cmp     bx, 0x0020
        je      .vid_cga80
        mov     dx, msg_vid_mda        ; 0x0030
        call    print_str
        jmp     .after_video
.vid_none:
        mov     dx, msg_vid_none
        call    print_str
        jmp     .after_video
.vid_cga40:
        mov     dx, msg_vid_cga40
        call    print_str
        jmp     .after_video
.vid_cga80:
        mov     dx, msg_vid_cga80
        call    print_str
.after_video:
        call    print_crlf

        ; --- Bit 8: DMA present (logic is inverted -- 0 means DMA IS present) ---
        ; The original IBM PC had an 8237 DMA controller.  Bit 8 = 1 signals
        ; DMA is absent.  On virtually all PC-compatibles DMA is present (0).
        mov     dx, msg_dma
        call    print_str
        test    ax, 0x0100
        jz      .dma_present
        mov     dx, msg_absent
        call    print_str
        jmp     .after_dma
.dma_present:
        mov     dx, msg_present
        call    print_str
.after_dma:
        call    print_crlf

        ; --- Bits [11:9]: number of RS-232 serial ports ---
        mov     dx, msg_serial
        call    print_str
        mov     bx, ax
        and     bx, 0x0E00
        mov     cl, 9
        shr     bx, cl
        mov     ax, bx
        call    print_decimal_byte
        mov     ax, [equip]
        call    print_crlf

        ; --- Bit 12: game port ---
        mov     dx, msg_gameport
        call    print_str
        test    ax, 0x1000
        jz      .no_game
        mov     dx, msg_yes
        call    print_str
        jmp     .after_game
.no_game:
        mov     dx, msg_no
        call    print_str
.after_game:
        call    print_crlf

        ; --- Bits [15:14]: number of LPT parallel ports ---
        mov     dx, msg_lpt
        call    print_str
        mov     bx, ax
        and     bx, 0xC000
        mov     cl, 14
        shr     bx, cl
        mov     ax, bx
        call    print_decimal_byte
        mov     ax, [equip]
        call    print_crlf

        ; ---------------------------------------------------------------
        ; Section 2 -- Other interesting BDA fields
        ; ---------------------------------------------------------------
        mov     dx, msg_section_other
        call    print_str

        ; Conventional memory size as reported by the BIOS.
        ; This is what BIOS INT 12h also returns, in kilobytes.
        mov     dx, msg_memkb
        call    print_str
        mov     ax, [mem_kb]
        call    print_decimal16
        mov     dx, msg_kb
        call    print_str
        call    print_crlf

        ; Current video mode set by the BIOS.
        ; 0/1 = CGA 40-col text,  2/3 = CGA 80-col text,  7 = MDA 80-col text.
        ; Other values indicate graphics or EGA/VGA modes.
        mov     dx, msg_vidmode
        call    print_str
        mov     al, [cur_mode]
        call    print_hex8
        call    print_crlf

        ; Screen width in character columns (written by BIOS on mode set).
        mov     dx, msg_cols
        call    print_str
        mov     ax, [num_cols]
        call    print_decimal16
        call    print_crlf

        ; Keyboard shift-key state, byte 1.
        ; Bit 7: Insert active  6: CapsLock  5: NumLock  4: ScrollLock
        ; Bit 3: Alt held       2: Ctrl held  1: L-Shift  0: R-Shift
        mov     dx, msg_kbflags1
        call    print_str
        mov     al, [kb_flags1]
        call    print_hex8
        call    print_crlf

        ; Keyboard shift-key state, byte 2.
        ; Bit 3: Ctrl+NumLock (pause) active  2: Ctrl+SysRq
        ; Bit 1: Left Alt held                0: Left Ctrl held
        mov     dx, msg_kbflags2
        call    print_str
        mov     al, [kb_flags2]
        call    print_hex8
        call    print_crlf

        ; IRQ0 tick counter -- informational.
        ; Incremented ~18.2x/second by the timer interrupt.
        ; Starts near 0 at boot; useful to confirm machine was live and
        ; timer is running.  Printed as a 32-bit hex value (hi:lo).
        mov     dx, msg_ticks
        call    print_str
        mov     ax, [ticks_hi]
        call    print_hex16
        mov     ax, [ticks_lo]
        call    print_hex16
        call    print_crlf

        ; ---------------------------------------------------------------
        ; Done -- exit cleanly
        ; ---------------------------------------------------------------
        mov     dx, msg_done
        call    print_str

        mov     ax, 0x4C00             ; INT 21h AH=4Ch: terminate with code 0
        int     0x21


; ======================================================================
; Subroutines
;
; Design rule: every subroutine pushes all registers it modifies at
; entry and pops them before every return path.  Callers are guaranteed
; that nothing is clobbered.
; ======================================================================

; ----------------------------------------------------------------------
; print_str
; Print a '$'-terminated string to stdout via INT 21h AH=09h.
;
; IN:  DX = near offset of string in DS
; OUT: all registers preserved
; ----------------------------------------------------------------------
print_str:
        push    ax
        push    dx
        mov     ah, 0x09
        int     0x21
        pop     dx
        pop     ax
        ret

; ----------------------------------------------------------------------
; print_crlf
; Emit a CR+LF pair.
;
; IN:  nothing
; OUT: all registers preserved
; ----------------------------------------------------------------------
print_crlf:
        push    dx
        mov     dx, str_crlf
        call    print_str               ; print_str preserves everything
        pop     dx
        ret

; ----------------------------------------------------------------------
; print_hex16
; Print AX as "0xXXXX" (4 hex digits, uppercase, with prefix).
;
; IN:  AX = value
; OUT: all registers preserved
; ----------------------------------------------------------------------
print_hex16:
        push    ax
        push    bx
        push    cx
        push    dx

        mov     dx, str_hex_prefix
        call    print_str

        mov     bx, ax                 ; keep full value in BX
        mov     al, bh                 ; high byte first
        call    .emit_byte
        mov     al, bl                 ; then low byte
        call    .emit_byte

        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

        ; Emit AL as two hex digits.  Touches AL and AH only.
        ; Callers above have already saved those.
.emit_byte:
        push    ax
        shr     al, 1                  ; shift high nibble into low position;
        shr     al, 1                  ; 8088 only allows shift-by-1 or shift-by-CL,
        shr     al, 1                  ; so we chain four single-bit shifts
        shr     al, 1
        call    .emit_nibble
        pop     ax
        and     al, 0x0F
        ; fall through to emit_nibble

.emit_nibble:
        ; Emit the low nibble of AL as a single ASCII hex character.
        push    ax
        push    dx
        and     al, 0x0F
        add     al, '0'
        cmp     al, '9'
        jle     .is_digit
        add     al, 7                  ; skip ':' through '@': 'A'='9'+1+7
.is_digit:
        mov     ah, 0x02               ; INT 21h: write character in DL
        mov     dl, al
        int     0x21
        pop     dx
        pop     ax
        ret

; ----------------------------------------------------------------------
; print_hex8
; Print AL as "0xXX" (2 hex digits, uppercase, with prefix).
;
; IN:  AL = value
; OUT: all registers preserved
; ----------------------------------------------------------------------
print_hex8:
        push    ax
        push    bx
        push    cx
        push    dx

        mov     dx, str_hex_prefix
        call    print_str

        call    print_hex16.emit_byte  ; AL is already set; emit it

        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ----------------------------------------------------------------------
; print_decimal_byte
; Print AX (0-255) as unsigned decimal with no leading zeros.
;
; IN:  AX = value (0-255; high byte ignored)
; OUT: all registers preserved
; ----------------------------------------------------------------------
print_decimal_byte:
        push    ax
        push    bx
        push    cx
        push    dx

        xor     ah, ah                 ; treat AL as unsigned 8-bit

        ; Decompose into hundreds / tens / units via repeated division.
        mov     bx, 100
        xor     dx, dx
        div     bx                     ; AX = hundreds, DX = remainder
        mov     ch, al                 ; CH = hundreds digit

        mov     ax, dx
        mov     bx, 10
        xor     dx, dx
        div     bx                     ; AX = tens digit, DX = units digit
        mov     cl, al                 ; CL = tens digit
        mov     bx, dx                 ; BL = units digit (BX preservable)

        ; Print hundreds -- suppress if zero
        mov     dl, ch
        or      dl, dl
        jz      .skip_h
        add     dl, '0'
        mov     ah, 0x02
        int     0x21
.skip_h:
        ; Print tens -- suppress if hundreds and tens are both zero
        mov     dl, cl
        mov     ax, cx                 ; AH=hundreds, AL=tens
        or      ah, al                 ; non-zero if either hundreds or tens
        jz      .skip_t
        mov     dl, cl
        add     dl, '0'
        mov     ah, 0x02
        int     0x21
.skip_t:
        ; Units digit always printed
        mov     dl, bl
        add     dl, '0'
        mov     ah, 0x02
        int     0x21

        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ----------------------------------------------------------------------
; print_decimal16
; Print AX (0-65535) as unsigned decimal with no leading zeros.
;
; IN:  AX = value
; OUT: all registers preserved
; ----------------------------------------------------------------------
print_decimal16:
        push    ax
        push    bx
        push    cx
        push    dx
        push    si

        ; Special-case zero.
        or      ax, ax
        jnz     .nonzero
        mov     dl, '0'
        mov     ah, 0x02
        int     0x21
        jmp     .done

.nonzero:
        ; Divide by 10 repeatedly; remainders (digits) come out in reverse
        ; order, so push each onto the stack and pop to print forward.
        xor     si, si                 ; SI = digit count
        mov     bx, 10
.divloop:
        xor     dx, dx
        div     bx                     ; AX = quotient, DX = digit (0-9)
        push    dx
        inc     si
        or      ax, ax
        jnz     .divloop

.printloop:
        or      si, si
        jz      .done
        pop     dx
        add     dl, '0'
        mov     ah, 0x02
        int     0x21
        dec     si
        jmp     .printloop

.done:
        pop     si
        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret

; ----------------------------------------------------------------------
; print_bits16
; Print AX as 16 binary digits grouped in nibbles (MSB first).
; Example:  0011 0000 0000 0001
;
; IN:  AX = value
; OUT: all registers preserved
; ----------------------------------------------------------------------
print_bits16:
        push    ax
        push    bx
        push    cx
        push    dx

        mov     bx, ax                 ; BX = working copy, shifted left each iteration
        mov     cx, 16                 ; bit counter

.bitloop:
        ; Insert a space between nibble groups.
        ; CX counts down 16..1.  We want spaces before bits 12, 8, 4
        ; (i.e., when CX = 12, 8, 4 -- after printing 4, 8, 12 bits).
        ; A space goes before each nibble group except the very first.
        ; We want a space before nibble groups 2, 3, 4 -- i.e. before the
        ; bit when CX = 12, 8, or 4.  These all satisfy (CX AND 3) == 0,
        ; as does CX=16 (the first bit), which we must suppress.
        mov     ax, cx
        and     ax, 0x0003             ; low 2 bits of CX
        jnz     .no_space              ; not a nibble boundary, skip
        cmp     cx, 16                 ; suppress space before the very first bit
        je      .no_space
        mov     ah, 0x02
        mov     dl, ' '
        int     0x21
.no_space:
        ; Emit '1' or '0' based on MSB of BX.
        mov     dl, '0'
        test    bx, 0x8000
        jz      .emit_bit
        mov     dl, '1'
.emit_bit:
        mov     ah, 0x02
        int     0x21

        shl     bx, 1                  ; advance to next bit
        loop    .bitloop

        pop     dx
        pop     cx
        pop     bx
        pop     ax
        ret


; ======================================================================
; Initialized data
; ======================================================================

equip           dw      0
mem_kb          dw      0
kb_flags1       db      0
kb_flags2       db      0
cur_mode        db      0
num_cols        dw      0
ticks_lo        dw      0
ticks_hi        dw      0

str_crlf        db      0x0D, 0x0A, '$'
str_hex_prefix  db      '0x', '$'

msg_banner      db      0x0D, 0x0A
                db      '================================', 0x0D, 0x0A
                db      ' BIOS Data Area Report          ', 0x0D, 0x0A
                db      ' Leading Edge Model D -- bdainfo', 0x0D, 0x0A
                db      '================================', 0x0D, 0x0A
                db      '$'

msg_section_equip db    0x0D, 0x0A
                  db    '-- Equipment Word (0040:0010) --', 0x0D, 0x0A, '$'

msg_section_other db    0x0D, 0x0A
                  db    '-- Other BDA Fields -------------', 0x0D, 0x0A, '$'

msg_equip_raw   db      '  Raw hex    : ', '$'
msg_equip_bits  db      '  Binary     : ', '$'

msg_floppy      db      '  Bit  0     floppy installed    : ', '$'
msg_floppy_count db     '  Bits [7:6] floppy count        : ', '$'
msg_fpu         db      '  Bit  1     8087 FPU            : ', '$'
msg_ramsize     db      '  Bits [3:2] board RAM (PC only) : ', '$'
msg_video       db      '  Bits [5:4] display adapter     : ', '$'
msg_dma         db      '  Bit  8     DMA chip            : ', '$'
msg_serial      db      '  Bits[11:9] serial ports        : ', '$'
msg_gameport    db      '  Bit  12    game port           : ', '$'
msg_lpt         db      '  Bits[15:14] LPT ports          : ', '$'

msg_yes         db      'Yes', '$'
msg_no          db      'No', '$'
msg_na          db      'N/A (no floppy bit)', '$'
msg_present     db      'Present', '$'
msg_absent      db      'Absent', '$'

; The [SWITCH:...] annotation is the key thing you're looking for on
; the Model D.  You want to see [SWITCH: MDA] when the rear switch is
; in the mono position, and one of the CGA lines when it is not.
msg_vid_none    db      '0x00  no display adapter', '$'
msg_vid_cga40   db      '0x10  CGA 40-column  [SWITCH: CGA]', '$'
msg_vid_cga80   db      '0x20  CGA 80-column  [SWITCH: CGA]', '$'
msg_vid_mda     db      '0x30  MDA monochrome [SWITCH: MDA]', 0x0D, 0x0A
                db      '        ^^^ correct for enhanced mono graphics', '$'

msg_ram16       db      '16 KB (PC-class field)', '$'
msg_ram32       db      '32 KB (PC-class field)', '$'
msg_ram48       db      '48 KB (PC-class field)', '$'
msg_ram64       db      '64 KB (PC-class field)', '$'

msg_memkb       db      '  Conventional memory : ', '$'
msg_kb          db      ' KB', '$'
msg_vidmode     db      '  Video mode (0049h)  : ', '$'
msg_cols        db      '  Screen columns      : ', '$'
msg_kbflags1    db      '  KB shift flags 1   : ', '$'
msg_kbflags2    db      '  KB shift flags 2   : ', '$'
msg_ticks       db      '  IRQ0 tick counter  : ', '$'

msg_done        db      0x0D, 0x0A
                db      '================================', 0x0D, 0x0A
                db      '$'
