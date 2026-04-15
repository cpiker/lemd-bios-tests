# 8088 Assembly Notes for Claude
## Purpose
This file is a self-reference for Claude when generating 8088/8086 assembly.
It captures failure modes and hard constraints discovered through actual hardware
testing, not documentation. Written for AI processing, not human tutorial use.

---

## 1. Register Clobber — The #1 Source of Bugs

### AX/AH/AL are one register
`mov ax, bx` destroys AH. `and ax, 0x0003` destroys AH.
Any 16-bit operation on AX invalidates a value stored in AH or AL.

**Pattern that kills saved values:**
```asm
; Compute mask, stash in AH for "later"
mov  ah, [some_mask]
; ... inner loop ...
mov  ax, bx          ; <<< AH is GONE. Every time. No exceptions.
```

**Fix:** If a value must survive address arithmetic that uses AX, save it to a
named memory variable and reload it after the math. One extra memory access per
iteration is negligible on 8088 versus a silent correctness bug.

### CX is the shift register AND the loop counter
`loop` decrements CX. `rep` uses CX. `shl ax, cl` uses CL.
These cannot coexist in the same code path without explicit save/restore.
When doing variable shifts inside a loop, CX is consumed by the shift setup
(`mov cl, count`), which means the outer LOOP instruction will see a wrong CX.
Use `jl`/`jge`/explicit `dec`+`jnz` instead of `loop` when CL is also needed.

### DX is both a general register AND the I/O port register
`out dx, al` and `in al, dx` require DX = port address.
Any computation that puts a value in DX for port I/O destroys whatever was
being used there for arithmetic. Sequence port I/O as discrete units; don't
interleave with address computation using DX.

### ES is not free
`rep stosb`, `rep movsb`, and string instructions write through ES:DI.
If ES is set to VID_SEG for framebuffer access, loading the BDA segment into ES
for a tick read destroys the framebuffer pointer. Either:
- Reload ES to VID_SEG after every BDA access, or
- Do all BDA reads/writes in contiguous blocks, then restore ES.

### BP implicitly uses SS
`[bp]`, `[bp+offset]` address relative to SS (stack segment), not DS.
Using BP as a general-purpose counter is safe as long as it is never used as a
memory operand base. In COM files CS=DS=ES=SS at start, so the distinction
only matters if segments diverge — but it is a latent hazard. Prefer BX or SI
as loop counters when BP isn't strictly needed.

---

## 2. Shift Instructions on 8088

Only two forms are legal:
```asm
shl ax, 1       ; immediate 1 only — hardcoded in opcode
shl ax, cl      ; variable count must be in CL specifically
```
`shl ax, 13` is an 80186+ opcode. NASM will assemble it but it will fault or
misbehave on real 8088 hardware. For large fixed shifts, use `mov cl, N` then
`shl ax, cl`, or chain `shl ax, 1` N times (verbose but unambiguous).

Multiply-by-constant using shifts on 8088 — reference decompositions:
- × 90  = ×64 + ×16 + ×8 + ×2   (4 shifts + 3 adds)
- × 80  = ×64 + ×16              (2 shifts + 1 add)
- × 45  = ×32 + ×8 + ×4 + ×1    (4 shifts + 3 adds)

For these, preserve the original value in a second register (e.g., DX = row)
and generate each term into AX, adding into an accumulator (CX).

---

## 3. Instruction Set Boundary: 8088 vs 80186+

These instructions are NOT available on 8088/8086:
- `shl ax, imm` where imm > 1  (80186+)
- `push imm`                   (80186+)
- `imul reg, imm`              (80186+)
- `pusha` / `popa`             (80186+)
- `enter` / `leave`            (80186+)
- `insb` / `outsb`             (80186+)

NASM will silently assemble some of these without warning unless `cpu 8086`
is declared. Always put `cpu 8086` at the top of the file. This causes NASM
to error on illegal opcodes rather than assemble them silently.

MUL and DIV are available and useful:
- `mul bx`  →  DX:AX = AX * BX  (unsigned 16×16→32)
- `div bx`  →  AX = DX:AX / BX, DX = remainder  (unsigned)
- DX must be zeroed before DIV for 16-bit division: `xor dx, dx`
- Division overflow (quotient > 16 bits) causes INT 0 — guard inputs.

---

## 4. Memory Segmentation in DOS COM Files

COM files load with CS = DS = ES = SS = PSP segment, IP = 0x100.
The program occupies one segment; all segment registers point to it.
This means near pointers work for everything within the program.

To access the BDA (BIOS Data Area):
```asm
mov  ax, 0x0040
mov  es, ax
mov  ax, [es:0x0010]    ; equipment word
mov  ax, [es:0x006C]    ; tick counter low word
```
ES is now 0x0040. Restore it to DS (or VID_SEG) before any ES-relative
framebuffer or program-data access.

To access video RAM:
```asm
mov  ax, 0xB000         ; MDA / LEMD framebuffer
mov  es, ax
mov  [es:di], al        ; write to framebuffer
```

**Never assume ES is still what you set it to after any subroutine call.**
INT 10h, INT 21h, and any helper routine may clobber ES. Reload after calls
if ES-based addressing is needed.

---

## 5. The LEMD Four-Bank Interleave Address Formula

This hardware appears in projects targeting the Leading Edge Model D.
Confirmed by hardware testing on two physical units.

```
Segment:  0xB000
Banks:    4, at offsets 0x0000 / 0x2000 / 0x4000 / 0x6000
Layout:   scanline Y -> bank (Y AND 3), row (Y SHR 2)
Stride:   90 bytes per row within a bank (720 pixels / 8)

byte_offset = ((Y AND 3) SHL 13) + ((Y SHR 2) * 90) + (X SHR 3)
bit_mask    = 0x80 SHR (X AND 7)      ; bit 7 = leftmost pixel
```

Horizontal lines (constant Y): all 90 bytes are contiguous. Use REP STOSB.
Vertical lines (constant X): one byte per scanline, sawtooth across 4 banks.
  Requires read-modify-write per pixel. ~10x slower than horizontal.

The bitmask for a vertical line column is constant across all Y values for
that column. Compute it once per column. But: the address formula clobbers
AX (and therefore AH) on every iteration, so the mask CANNOT be held in AH.
Save it to a named byte variable and reload it after the address math.

---

## 6. Mode Activation and Restoration (LEMD)

**Always save state before activating graphics mode:**
```asm
; Save equipment word
mov  ax, 0x0040
mov  es, ax
mov  ax, [es:0x0010]
mov  [orig_equip], ax

; Save video mode
mov  ah, 0x0F
int  0x10
mov  [orig_mode], al
```

**Always restore before calling INT 10h to set a text mode:**
```asm
; Restore equipment word FIRST -- INT 10h reads it
mov  ax, 0x0040
mov  es, ax
mov  ax, [orig_equip]
mov  [es:0x0010], ax

; Then restore video mode
xor  ah, ah
mov  al, [orig_mode]
int  0x10
```

If the program crashes or hangs inside graphics mode without restoring:
- The CRTC remains in custom timing mode.
- Warm reboot (Ctrl-Alt-Del) skips full POST; DOS starts with bad CRTC state.
- The monitor receives wrong sync frequencies; rapid scanline scroll and
  audible whine from the flyback transformer are the visible symptoms.
- Power-cycle (cold boot) forces full POST which reinitializes the CRTC.
- The monitor is not damaged by brief exposure to wrong sync; prolonged
  exposure at extreme frequencies could cause harm. Power off quickly.

---

## 7. Timing via BIOS Tick Counter

The tick counter at 0x0040:0x006C is a 32-bit value (low word at 006C,
high word at 006E) incremented ~18.2065 times per second by IRQ0.

**Practical limits before choosing 16-bit vs 32-bit read:**
- Low word alone: safe for deltas up to ~1,092 ticks (~60 seconds).
  The ms conversion (ticks × 55) overflows 16-bit at 1,192 ticks; stop at
  1,092 to leave headroom.
- Vertical-line full-screen operations on 8088 measured at ~1,015 ticks
  (~56 seconds) in practice. 16-bit is marginal; use 32-bit for anything
  expected to take more than ~30 seconds.

**16-bit read (fast operations, < ~30 seconds):**
```asm
mov  ax, 0x0040
mov  es, ax
mov  ax, [es:0x006C]     ; low word only
mov  [tick_start], ax
; ... work ...
mov  ax, [es:0x006C]
sub  ax, [tick_start]    ; 16-bit delta, handles single wraparound
mov  bx, 55
mul  bx                  ; DX:AX = ms; AX holds result if delta < 1192
```

**32-bit read (slow operations, up to ~1 hour):**
```asm
; Storage: tick_start_lo dw 0, tick_start_hi dw 0
mov  ax, 0x0040
mov  es, ax
mov  ax, [es:0x006C]     ; low word
mov  [tick_start_lo], ax
mov  ax, [es:0x006E]     ; high word
mov  [tick_start_hi], ax
; ... work ...
mov  ax, [es:0x006C]
mov  dx, [es:0x006E]
sub  ax, [tick_start_lo]
sbb  dx, [tick_start_hi] ; DX:AX = 32-bit tick delta (SBB handles borrow)
; Convert DX:AX ticks to ms: multiply 32-bit value by 55
; DX:AX * 55 -- do as two 16-bit MULs:
;   low  = AX * 55  -> partial in DX:AX; save AX as ms_lo, add DX to carry
;   high = (saved DX * 55) + carry_from_low
mov  bx, 55
mov  cx, dx              ; CX = high word of tick delta
mul  bx                  ; DX:AX = tick_lo * 55
mov  [ms_lo], ax         ; save low result word
mov  ax, cx              ; AX = high word of tick delta
mul  bx                  ; DX:AX = tick_hi * 55
add  ax, [ms_lo+1]       ; fold in carry... simpler: just print DX:AX ticks
                         ; and note 1 tick = 54.925 ms in the output
```
For 32-bit timing, printing the raw tick delta and noting the conversion
factor in the output is simpler and less error-prone than the full 32×16
multiply. Reserve the multiply for cases where the ms value is required.

Do NOT use the 8087 FPU for timing conversion. FWAIT hangs the machine if
no 8087 is present. Integer arithmetic is sufficient for all practical cases.

---

## 8. INT 21h String Output Gotcha

`INT 21h AH=09h` prints a '$'-terminated string from DS:DX.
It does NOT print a newline. Always append `0x0D, 0x0A, '$'` to message
strings that should end with a newline, or emit them as a separate string.

After INT 21h calls: DS is preserved, but ES may not be. Reload if needed.

---

## 9. The Inline-Byte Argument Trick

A subroutine can read a literal value from the byte(s) immediately following
the CALL instruction in the caller's code stream:

```asm
; Caller:
call  some_routine
db    0xFF              ; argument byte -- routine reads and skips this

; Callee:
some_routine:
    pop  si             ; SI = address of the byte after the CALL opcode
    mov  al, [si]       ; AL = the argument byte
    inc  si             ; advance past the argument
    push si             ; push updated return address
    ; ... use AL ...
    ret                 ; returns to instruction after the db
```

This avoids consuming a register for simple single-byte arguments.
Works correctly on 8088. Does not work if the routine is called via a
register (indirect CALL) or if the byte is not present -- contract between
caller and callee must be enforced manually.

---

## 10. LEMD Hidden Page — Notes for Investigation

**Context:** The LEMD framebuffer segment 0xB000 is 64KB. The four active
display banks (0x0000–0x7FFF) occupy only the lower 32KB. The upper 32KB
(0x8000–0xFFFF) is unaccounted for. On Hercules hardware the upper 32KB is
a hidden off-screen page used for double-buffering.

**Observed evidence:** A Bresenham bug in `lemdrtim.com` caused writes to
land above 0x8000. The screen stayed black during writing, then flashed to
nearly fully lit all at once — consistent with a page-flip event, not
progressive drawing. The first invalid offset observed was 0x7AB7 (just
inside the bank 3 tail), but the runaway would have continued well into
0x8000+ before enough writes accumulated to trigger the flash.

**FRAMEBUF_MAX correction:** An earlier version of the notes and spec
incorrectly stated the first invalid offset as 0x7A78, treating the four
banks as contiguous in memory. They are not — each bank occupies a fixed
0x2000-byte slot with 362 bytes of unused tail:

```
Bank 0: used 0x0000–0x1E95, tail 0x1E96–0x1FFF (362 bytes)
Bank 1: used 0x2000–0x3E95, tail 0x3E96–0x3FFF (362 bytes)
Bank 2: used 0x4000–0x5E95, tail 0x5E96–0x5FFF (362 bytes)
Bank 3: used 0x6000–0x7E95, tail 0x7E96–0x7FFF (362 bytes)
Total unused within lower 32KB: 1,448 bytes
```

The correct last valid pixel byte is 0x7E95 (bank 3, row 86, byte 89).
Use 0x7E96 as FRAMEBUF_MAX in bounds-checking code.

**Candidate flip mechanisms** (see lemd_enhanced_mono_spec.md A10 for full
test procedure):
- Port 0x3B8 bit 7 — Hercules page select, highest probability
- Port 0x3DD upper bits — LE proprietary register, unknown function
- MC6845 R12/R13 start address — scroll origin into upper RAM

**ES discipline when probing the hidden page:**
Writing to 0xB000:0x8000+ requires ES = 0xB000 and DI >= 0x8000.
The same ES-clobber hazard applies as for normal framebuffer access:
any BDA tick read sets ES = 0x0040. Reload ES = 0xB000 explicitly
before every write into either page.
