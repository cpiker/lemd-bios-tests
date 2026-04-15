# Leading Edge Model D — Enhanced Monochrome Graphics Mode
## Hardware Specification (Reverse Engineered)

**Document status:** Draft — framebuffer layout fully confirmed by hardware
testing. Mode activation confirmed working. Pixel aspect ratio confirmed (A6
resolved). Several ambiguities remain regarding port behavior and BIOS
extensions; see Section 6.

**Reverse engineered by:** Dude & Claude (Anthropic), March 2026.
Methodology: disassembly of `diagnose.com` (DOS COM binary), CRTC register
extraction, and iterative hardware testing on two physical Leading Edge Model D
units with original amber monochrome monitors.

---

## 1. Overview

The Leading Edge Model D incorporates an onboard video controller that supports
a proprietary extended monochrome graphics mode beyond the standard MDA and CGA
modes also present on the hardware. This mode provides:

- **720 × 348 pixel** resolution, monochrome (1 bit per pixel)
- **Non-square pixel aspect ratio** — the display measures 4:3 physically at
  720×348 pixels, giving a pixel aspect ratio of 29:45 (width:height, ~0.644).
  Each pixel is taller than it is wide. This is closer to square than Hercules
  (which at the same resolution has an even more elongated pixel) but is not
  square. See Section 6 A6 for derivation and validation.
- **MDA-space video RAM** at segment `0xB000`
- **Not Hercules compatible** at the framebuffer level — same resolution but
  different scanline interleave scheme (see Section 4)

The video controller is built around a **Motorola MC6845 CRTC** (or compatible
clone) with proprietary surrounding logic implemented in glue chips or a custom
ASIC. The MC6845 handles sync generation; the surrounding logic implements the
4-bank interleaved framebuffer scheme.

The Model D has two video output connectors on the rear panel — one CGA and one
monochrome — and a physical rear switch that selects which monitor type is
connected. The enhanced monochrome graphics mode is only meaningful when the
monochrome connector and monitor are in use. See Section 10 for how to detect
this condition before attempting mode activation.

---

## 2. Mode Activation Sequence

The following sequence must be executed in order to activate the enhanced
monochrome graphics mode. This sequence was extracted from `diagnose.com` by
disassembly and confirmed by hardware testing.

### 2.1 BIOS Equipment Word

Set bits `[5:4]` of the BIOS equipment word to `11b` (indicating MDA adapter).
This is located at `0x0040:0x0010`.

```asm
mov     ax, 0x40
mov     es, ax
or      word [es:0x10], 0x0030
```

**Ambiguity A1:** It is not known whether this step is strictly required by the
hardware, or whether it was only done in `diagnose.com` to keep the BIOS data
area consistent. The CRTC and port writes may be sufficient on their own. See
Section 6.

### 2.2 Program the MC6845 CRTC

Write 16 register values to the MC6845 via the MDA CRTC ports:
- **Address port:** `0x3B4` — write the register index (0–15)
- **Data port:** `0x3B5` — write the register value

```asm
mov     dx, 0x3B4
mov     al, reg_index       ; 0 through 15
out     dx, al
inc     dx                  ; dx = 0x3B5
mov     al, reg_value
out     dx, al
```

Register values (extracted from `diagnose.com` at file offset `0x25BE`):

| Reg | Value | Name                  | Notes                              |
|-----|-------|-----------------------|------------------------------------|
| R0  | 0x35  | Horizontal Total      | 53 character clocks total          |
| R1  | 0x2D  | Horizontal Displayed  | 45 chars × 16px = 720px            |
| R2  | 0x2E  | H Sync Position       |                                    |
| R3  | 0x07  | Sync Widths           | HSync=7, VSync=0                   |
| R4  | 0x5B  | Vertical Total        | 91 character rows                  |
| R5  | 0x02  | Vertical Total Adjust | +2 scanlines                       |
| R6  | 0x57  | Vertical Displayed    | 87 rows × 4 scanlines = 348 lines  |
| R7  | 0x57  | Vertical Sync Pos     |                                    |
| R8  | 0x02  | Interlace Mode        | Interlace sync+video               |
| R9  | 0x03  | Max Scan Line Addr    | 4 scanlines per character row      |
| R10 | 0x00  | Cursor Start          | Cursor disabled                    |
| R11 | 0x00  | Cursor End            |                                    |
| R12 | 0x00  | Start Address High    | Framebuffer at offset 0x0000       |
| R13 | 0x00  | Start Address Low     |                                    |
| R14 | 0x00  | Cursor Address High   |                                    |
| R15 | 0x00  | Cursor Address Low    |                                    |

**Note on R1 / pixel width:** With R1=45 characters and R9=3 (4 scanlines/row),
the character cell width must be 16 pixels to produce 720 horizontal pixels
(45 × 16 = 720). This is consistent with the MDA-style pixel clock.

### 2.3 MDA Mode Control Register

Write to port `0x3B8`:

```asm
mov     dx, 0x3B8
mov     al, 0x0A
out     dx, al
```

Value `0x0A` = `0000 1010b`:
- Bit 1 = 1: Graphics mode enable
- Bit 3 = 1: Video signal enable
- All other bits = 0

### 2.4 CGA Mode Control Register

Write to port `0x3D8`:

```asm
mov     dx, 0x3D8
mov     al, 0x1A
out     dx, al
```

Value `0x1A` = `0001 1010b`:
- Bit 1 = 1: Graphics mode
- Bit 3 = 1: Video enable
- Bit 4 = 1: 640-pixel-wide mode

**Ambiguity A2:** It is unusual to write both the MDA mode register (0x3B8) and
the CGA mode register (0x3D8) for the same mode. The hardware appears to use
both simultaneously, suggesting the video controller monitors both port ranges.
The exact role of each register in this mode is not fully understood. See
Section 6.

### 2.5 CGA Color Select Register

Write to port `0x3D9`:

```asm
mov     dx, 0x3D9
xor     al, al              ; 0x00
out     dx, al
```

### 2.6 Leading Edge Proprietary Control Register

Write to port `0x3DD`:

```asm
mov     dx, 0x3DD
mov     al, 0x08
out     dx, al
```

**This is the key enable register for the enhanced mode.** Port `0x3DD` is not
present on standard IBM CGA or MDA cards. Bit 3 (`0x08`) enables the enhanced
monochrome graphics mode.

**Ambiguity A3:** The full bit definition of port `0x3DD` is unknown. Only bit 3
has been confirmed as the enhanced mode enable. The behavior of other bits is
undocumented. `diagnose.com` was observed to write the value with bit 3 set,
ORed into a previously saved value — suggesting other bits may be meaningful.
In our testing we write `0x08` directly (safe conservative value). See Section 6.

**Ambiguity A4:** It is unknown whether port `0x3DD` supports reads. On some
XT-era hardware, control registers are write-only and reading them returns bus
float or undefined values. Do not attempt a read-modify-write on this port
without further investigation.

---

## 3. Video RAM Layout

### 3.1 Base Address

Video RAM is located at segment **`0xB000`** (physical address `0x000B0000`),
identical to MDA. The total framebuffer occupies `0x8000` bytes
(32,768 bytes), though only ~31,320 bytes are actually used for pixel data.

### 3.2 Four-Bank Interleave

The 348 scanlines are distributed across **four banks**, each `0x2000` bytes
apart within the `0xB000` segment:

| Bank | Offset  | Scanlines contained         |
|------|---------|-----------------------------|
| 0    | 0x0000  | 0, 4, 8, 12, ..., 344       |
| 1    | 0x2000  | 1, 5, 9, 13, ..., 345       |
| 2    | 0x4000  | 2, 6, 10, 14, ..., 346      |
| 3    | 0x6000  | 3, 7, 11, 15, ..., 347      |

Each bank holds **87 rows** (348 ÷ 4 = 87).

### 3.3 Address Calculation

To find the byte address of a pixel at coordinates (x, y):

```
bank        = y AND 3
row         = y SHR 2           (integer divide by 4)
byte_col    = x SHR 3           (integer divide by 8)
bit_index   = 7 - (x AND 7)    (bit 7 = leftmost pixel in byte)

byte_offset = (bank × 0x2000) + (row × 90) + byte_col
bit_mask    = 0x80 SHR (x AND 7)

address     = 0xB000:byte_offset
```

**Row stride within a bank: 90 bytes** (720 pixels ÷ 8 bits/byte).

### 3.4 Pixel Encoding

- **Bit = 1:** Pixel is illuminated (white/amber depending on monitor)
- **Bit = 0:** Pixel is dark
- Within each byte, **bit 7 is the leftmost pixel** (most significant = leftmost),
  bit 0 is the rightmost. This matches CGA and MDA conventions.

### 3.5 Confirmation

The complete framebuffer layout was confirmed by hardware testing using
`lemd_test.com` (NASM source: `lemd_test.asm`), a purpose-built DOS COM test
program. Four tests were run in sequence on a physical Leading Edge Model D with
original amber monochrome monitor:

- **Test 1 (clear screen):** Writing 0x00 to all of 0xB000:0x0000–0x7FFF
  produced a fully dark screen, confirming the framebuffer base address and
  that no stale data interferes.

- **Test 2 (border and grid):** Drawing a screen border and an 8×6 interior
  grid using the pixel address formula produced straight, evenly spaced lines
  covering the full 720×348 display area. This confirms the address formula is
  correct across all four banks, the 90-byte row stride is correct, and the
  bit-endianness (bit 7 = leftmost) is correct.

- **Test 3 (bank isolation):** Filling bank 0 with 0xFF, bank 1 with 0x55,
  bank 2 with 0xAA, and bank 3 with 0x00 produced horizontal stripes cycling
  every 4 scanlines across the full screen height. The 0x55 and 0xAA stripes
  (banks 1 and 2) appeared offset by one pixel horizontally from each other,
  which is expected — they are bitwise complements, not addressing errors.
  This confirms the 4-bank interleave and the 0x2000 bank spacing.

- **Test 4 (scanline stripes):** Writing 0xFF to row 0 of each bank (offsets
  0x0000, 0x2000, 0x4000, 0x6000) lit exactly the top four scanlines of the
  screen and left everything else dark. This confirms that bank N row 0 maps
  to screen scanline N, and that the display origin is at the top of the
  framebuffer (R12/R13 start address = 0x0000).

---

## 4. Comparison With Hercules

The Leading Edge enhanced mono mode is **not** Hercules-compatible, despite
producing the same 720×348 resolution.

| Property              | Hercules              | LE Enhanced Mono      |
|-----------------------|-----------------------|-----------------------|
| Base segment          | 0xB000                | 0xB000                |
| Number of banks       | 2                     | **4**                 |
| Bank offset           | 0x2000                | 0x2000                |
| Bytes per scanline    | 90                    | 90                    |
| Scanlines per bank    | 174                   | 87                    |
| Bank 0 scanlines      | 0, 2, 4, 6, ...       | 0, 4, 8, 12, ...      |
| Bank 1 scanlines      | 1, 3, 5, 7, ...       | 1, 5, 9, 13, ...      |
| Bank 2 scanlines      | (none)                | 2, 6, 10, 14, ...     |
| Bank 3 scanlines      | (none)                | 3, 7, 11, 15, ...     |
| Enable port           | 0x3B8 bit 1           | 0x3DD bit 3           |
| Mode set via INT 10h  | No (direct hardware)  | Unknown (see A5)      |

**Why Starflight's Hercules mode fails:** Starflight writes even scanlines to
bank 0 and odd scanlines to bank 1 (correct for Hercules). On the Leading Edge
hardware, this means banks 2 and 3 (which carry scanlines 2,3,6,7,10,11,...)
are never written and remain dark. The result is a vertically compressed image
occupying approximately the top 2/3 of the screen — confirmed by photography.

---

## 5. Mode Deactivation / Restore

To return to a standard text mode, issue a normal INT 10h mode-set call. The
BIOS should restore standard MDA or CGA operation. It is advisable to restore
the BIOS equipment word to its original value first.

```asm
; Restore equipment word (save original value before mode set)
mov     ax, 0x40
mov     es, ax
mov     [es:0x10], original_equip_word

; Set standard mode (e.g., mode 3 = CGA 80x25 color text,
; or mode 7 = MDA 80x25 mono text)
xor     ah, ah
mov     al, 0x07            ; or 0x03 for CGA
int     0x10
```

**Ambiguity A5:** It is not known whether the Enhanced Video BIOS on the Model D
provides an INT 10h hook that can set/clear the enhanced mono mode via a
non-standard mode number (e.g., 0x40+). The VOGONS thread mentions the BIOS
identifies as "Leading Edge Model D with Enhanced Video BIOS," strongly
suggesting such an extension exists. If it does, it would be the preferred
activation method for software compatibility. This has not been investigated.

---

## 6. Known Ambiguities and Suggested Tests

### A1 — BIOS equipment word necessity
**Question:** Is the `or word [0x40:0x10], 0x30` step strictly necessary, or
does it only matter for BIOS calls made after mode set?

**Test:** Activate the mode without touching the equipment word. Observe whether
the display initializes correctly.

### A2 — Role of CGA port 0x3D8 in this mode
**Question:** Why does the mode write to both 0x3B8 (MDA) and 0x3D8 (CGA)?
Does one of these have no effect, or does the hardware monitor both?

**Test:** Try activating the mode with only 0x3B8 written (skip 0x3D8), then
vice versa. Observe which combination produces a valid display.

### A3 — Full bit definition of port 0x3DD
**Question:** What do bits other than bit 3 of port 0x3DD control?

**Test:** With the mode active, write different values to 0x3DD (0x00, 0x01,
0x02, 0x04, 0x08, 0x0F, 0xFF) and observe display behavior. Bits that produce
no visible effect or revert to text mode are informative.

**Caution:** Avoid leaving the display in an undefined state that might produce
no sync signal for extended periods. Always have a way to reboot.

### A4 — Port 0x3DD readability
**Question:** Does port 0x3DD support reads?

**Test:** Read the port (`in al, 0x3DD`) and compare the returned value to what
was written. If the value is 0xFF or 0x00 regardless of what was written, the
port is likely write-only.

### A5 — Enhanced Video BIOS INT 10h extension
**Question:** Does the Enhanced Video BIOS provide a non-standard INT 10h mode
number to activate this mode?

**Test:** Hook INT 10h before it executes (using a debugger such as DEBUG.COM)
and trace what mode number, if any, `diagnose.com` passes in AL when AH=0x00
just before the enhanced mode appears. Alternatively, scan the BIOS ROM image
(if obtainable) for INT 10h handlers that check for mode numbers above 0x13.

### A6 — Pixel aspect ratio ✓ RESOLVED

**Result:** The pixel aspect ratio is **29:45 (width:height), approximately
0.644**. Each pixel is taller than it is wide by a factor of 45/29 ≈ 1.552.

**Derivation:** The display measures 4:3 physically and contains 720×348
pixels.

```
pixel width  = (4/3) / 720 = 1/540  of screen width
pixel height =  (1)  / 348 = 1/348  of screen height
aspect ratio (w:h) = 348/540 = 29/45 ≈ 0.644
```

**Validation:** A photograph was converted using a Linux-side converter
(`lemdconv`) that compensates for the aspect ratio by using a 720×540
square-pixel virtual canvas (derived from the 4:3 geometry above) and
subsampling the 540 virtual rows down to 348 physical scanlines. The
converted image was displayed on the physical hardware and compared
side-by-side with the source photograph. No detectable distortion was
observed; any remaining error is below the threshold of visual detection
when the images are overlaid with transparency.

**Implication for driver and application developers:** Applications performing
geometry (circles, aspect-correct scaling, square fills) must apply a
correction factor of 45/29 ≈ 1.552 to vertical pixel counts relative to
horizontal pixel counts in order to produce undistorted output. A circle of
radius R pixels should be drawn with horizontal radius R and vertical radius
`R * 348 / 540` = `R * 29 / 45`.

### A7 — Behavior of the interlace bit (R8 = 0x02)
**Question:** R8 = 0x02 sets "interlace sync+video" on the MC6845. Is the
display actually interlaced, or is this a quirk of the CRTC programming?

**Observation:** The display appeared stable and non-flickery in testing,
suggesting non-interlaced operation. However this has not been rigorously
confirmed.

**Test:** Try R8 = 0x00 (non-interlace) and observe whether the display changes.

### A8 — Bank tail regions (unused bytes within each bank's 0x2000 slot)
**Question:** Each bank occupies a fixed 0x2000-byte (8,192-byte) slot, but
only uses 87 × 90 = 7,830 bytes of it. The remaining 362 bytes at the end of
each bank are unused:

| Bank | Used region         | Tail (unused)       | Tail size |
|------|---------------------|---------------------|-----------|
| 0    | 0x0000 – 0x1E95     | 0x1E96 – 0x1FFF     | 362 bytes |
| 1    | 0x2000 – 0x3E95     | 0x3E96 – 0x3FFF     | 362 bytes |
| 2    | 0x4000 – 0x5E95     | 0x5E96 – 0x5FFF     | 362 bytes |
| 3    | 0x6000 – 0x7E95     | 0x7E96 – 0x7FFF     | 362 bytes |

Total unused within 0x0000–0x7FFF: 4 × 362 = 1,448 bytes.

Note: an earlier version of this document incorrectly stated the tail as
0x7A78–0x7FFF (106 bytes), treating the four banks as contiguous. They are
not — each bank starts at a fixed 0x2000 boundary regardless of how many
rows it holds.

**Test:** Write a distinctive pattern to the tail of each bank and observe
whether any visual artifact appears on screen. Also check whether the MC6845
CRTC wraps its address counter into these regions during normal display
scanning.

### A10 — Hidden page at 0xB000:0x8000–0xFFFF
**Question:** The segment 0xB000 is 64KB, but the four active banks only
occupy the lower 32KB (0x0000–0x7FFF). The upper 32KB (0x8000–0xFFFF) is
entirely unaccounted for. On Hercules hardware, this region is a second
display page that can be written while the lower page is displayed, then
flipped into view instantaneously — a classic double-buffer.

**Observed evidence:** Running `lemdrtim.com` v1 (which contained a Bresenham
bug causing writes to land at offsets above 0x8000) produced a screen that
remained black for an extended period then flashed to nearly fully lit all at
once. This all-at-once appearance is inconsistent with progressive drawing and
strongly suggests a page-flip event — the upper 32KB was being written
invisibly, then something triggered it to become the displayed page.

**Candidate flip mechanisms** (in order of likelihood):

1. **Port 0x3B8 bit 7** — On standard Hercules, bit 7 of the MDA Mode Control
   register selects which 32KB page is displayed (0 = lower, 1 = upper). The
   LEMD hardware is Hercules-derived and this bit is the most probable
   flip mechanism. Currently written as 0x0A (bit 7 clear = page 0 displayed).
   Test: write 0x8A and observe.

2. **Port 0x3DD bits other than bit 3** — The LE proprietary register has
   unknown upper bits. `diagnose.com` was observed to OR bit 3 into a
   previously saved value, implying other bits are meaningful. Any of bits
   0,1,2,4,5,6,7 could be a page select. Test: probe each bit individually.

3. **MC6845 R12/R13 (Start Address)** — Currently both 0x00. Writing a nonzero
   start address scrolls the CRTC display origin into higher RAM addresses.
   Depending on how the surrounding logic maps the 14-bit CRTC address space
   onto the physical segment, a start address of 0x1000 (in CRTC character
   units) might map display output into 0x8000+. This is a different mechanism
   from a true page flip but achieves a similar result. Lower risk than port
   probing since R12/R13 are defined MC6845 registers that cannot produce
   out-of-spec sync signals.

**Suggested test sequence for `lemdpage.asm`:**
1. Activate enhanced mono mode (lower page displayed, upper page dark).
2. Fill 0xB000:0x0000–0x7FFF with a distinctive pattern (e.g. horizontal
   stripes, all pixels lit).
3. Fill 0xB000:0x8000–0xFFFF with a different pattern (e.g. alternating
   bytes 0x55/0xAA).
4. Confirm the lower-page pattern is visible on screen.
5. Write 0x8A to port 0x3B8 (set bit 7). Observe screen.
6. If no change: restore 0x3B8 = 0x0A. Probe port 0x3DD bits one at a time
   (0x09, 0x0A, 0x0C, 0x18, 0x28, 0x48, 0x88), observing after each write.
7. If still no change: restore 0x3DD = 0x08. Write MC6845 R12=0x10, R13=0x00
   (start address = 0x1000 in CRTC units) and observe.
8. At each step document the value written, the visible result, and whether
   sync was lost.

**Safety:** If any write causes loss of sync (blank screen, flyback whine),
restore the affected register immediately and power-cycle if the monitor does
not recover within a few seconds. The MC6845 R12/R13 probe (step 7) is the
safest as it cannot generate out-of-spec sync frequencies.

### A9 — Monitor type switch and CGA output behavior
**Question:** When the rear switch is set to CGA (not monochrome), does
`diagnose.com` refuse to offer the enhanced mono test? Does attempting to
activate the mode with a CGA monitor connected produce any output, garbage
sync, or nothing?

**Status:** Test procedure documented (see Section 10). Not yet executed —
requires a CGA monitor or a CGA-to-VGA adapter, neither of which is currently
available.

---

## 7. Port Summary

| Port  | Direction | Name                        | Value in enhanced mode |
|-------|-----------|-----------------------------|------------------------|
| 0x3B4 | Write     | MDA CRTC Address            | Register index 0..15   |
| 0x3B5 | Write     | MDA CRTC Data               | See register table     |
| 0x3B8 | Write     | MDA Mode Control            | 0x0A                   |
| 0x3D8 | Write     | CGA Mode Control            | 0x1A                   |
| 0x3D9 | Write     | CGA Color Select            | 0x00                   |
| 0x3DD | Write(?)  | LE Proprietary Control      | 0x08 (bit 3 = enable)  |

---

## 8. Framebuffer Summary (Quick Reference)

```
Segment:         0xB000
Banks:           4
Bank offsets:    0x0000, 0x2000, 0x4000, 0x6000
Scanlines/bank:  87
Bytes/scanline:  90
Total scanlines: 348
Total pixels:    720 × 348 = 250,560
Pixel order:     Bit 7 = leftmost, bit 0 = rightmost

Address formula:
  bank   = y AND 3
  row    = y SHR 2
  offset = (bank SHL 13) + (row * 90) + (x SHR 3)
  mask   = 0x80 SHR (x AND 7)
  addr   = 0xB000:offset
```

---

## 9. Source Material

- `diagnose.com` — DOS COM binary, Leading Edge Model D diagnostic program.
  Disassembled with `ndisasm -b 16 -o 0x100`. This is the primary source for
  the mode activation sequence and CRTC register values.
- `lemd_test.asm` — Purpose-built DOS COM test program (NASM). Source of the
  hardware confirmation results documented in Section 3.5.
- Hardware testing on two physical Leading Edge Model D units (both showed
  identical behavior), original amber monochrome monitors.
- VOGONS forum thread (t=92355, now returning 404) — confirmed the DIAGNOSE
  program as the source of the 640×200 16-color and enhanced mono video tests,
  and noted the "Enhanced Video BIOS" identification string.
- Wikipedia: Leading Edge Model D — confirmed MC6845 presence and special
  extended graphics mode (described there as "EGA: 640×200").
- Starflight (Electronic Arts, 1986) — Hercules mode behavior on Model D
  hardware provided visual confirmation of the 4-bank vs 2-bank incompatibility.

---

## 10. Monitor Type Detection

### 10.1 Background

The Leading Edge Model D has two video output connectors on the rear panel: one
CGA (color) and one monochrome. A physical switch on the rear of the machine
selects which monitor type is connected. The BIOS reads this switch during POST
and records the result in the BIOS Data Area (BDA) equipment word.

The enhanced monochrome graphics mode produces output only on the monochrome
connector. A driver must verify that a monochrome monitor is configured before
attempting to activate this mode.

`diagnose.com` was observed to detect the monitor type and presumably gates the
enhanced mono video test on the monochrome switch setting. The exact mechanism
is assumed to be the BDA equipment word, as described below.

### 10.2 The BIOS Equipment Word

The equipment word is a 16-bit value maintained by the BIOS at `0x0040:0x0010`.
Bits [5:4] encode the display adapter type as set by the rear switch:

| Bits [5:4] | Value | Meaning                  |
|------------|-------|--------------------------|
| 00         | 0x00  | No display               |
| 01         | 0x10  | CGA, 40-column           |
| 10         | 0x20  | CGA, 80-column           |
| 11         | 0x30  | MDA / monochrome         |

A driver should check for `0x30` in bits [5:4] before activating enhanced mono
mode. Any other value indicates the machine is configured for CGA output and the
mode should not be set.

```c
/* C pseudocode for the pre-flight check */
uint16_t equip = *((uint16_t far *)0x00400010);
if ((equip & 0x0030) != 0x0030) {
    /* monochrome monitor not selected -- do not activate enhanced mode */
    return ERROR_WRONG_MONITOR;
}
```

### 10.3 Suggested Tests (not yet executed)

The following tests require a CGA monitor or a working CGA-to-VGA adapter,
which is not currently available. They are documented here for future execution.

**Test A9a — Confirm switch reflects in equipment word:**
With the rear switch in the monochrome position, read `[0x0040:0x0010]` and
confirm bits [5:4] = `11b` (0x30). Flip the switch to a CGA position, reboot,
and confirm bits [5:4] change to `10b` or `01b` (0x20 or 0x10).

**Test A9b — diagnose.com behavior with CGA switch:**
With the switch in a CGA position, run `diagnose.com` and observe whether the
enhanced mono video test is absent from the menu or produces a warning.

**Test A9c — Mode activation with CGA monitor:**
With a CGA monitor connected and the switch in CGA position, attempt to run
`lemd_test.com`. Observe whether the mode activates (garbled output is
informative; no sync signal is also informative).

---

## 11. Notes for a Driver Developer

This section summarizes what is known, what is unknown, and what a driver
targeting this hardware (e.g. a nanoX/ELKS graphics driver) needs to handle.

### 11.1 What is confirmed and safe to rely on

- The complete mode activation sequence in Section 2 works on two independent
  hardware units and should be treated as definitive unless A1 or A2 testing
  reveals that some steps are unnecessary.
- The framebuffer layout in Section 3 is fully confirmed. The address formula
  is correct. The 90-byte stride and 0x2000 bank spacing are correct.
- Mode deactivation via INT 10h AH=0 AL=7 (mode 7, MDA text) works cleanly.
  Restore the equipment word first (Section 5).
- The monochrome equipment word check (Section 10) is the correct pre-flight
  gate. Do not attempt to activate the mode without confirming bits [5:4] of
  `[0x0040:0x0010]` equal 0x30.

### 11.2 What the driver must do conservatively until ambiguities are resolved

- **A1:** Include the equipment word OR step (Section 2.1) in the activation
  sequence. It is harmless if unnecessary, and may be required.
- **A2:** Write both 0x3B8 and 0x3D8 as shown. Do not omit either until A2 is
  resolved.
- **A3/A4:** Write 0x08 to port 0x3DD unconditionally. Do not attempt to read
  the port or perform a read-modify-write.
- **A5:** Use the raw port sequence for activation, not INT 10h. If a BIOS
  extension mode number is discovered (A5), prefer it instead — but that
  investigation has not been done.

### 11.3 Drawing performance characteristics

The four-bank interleave has implications for drawing primitive performance
that a driver implementor should be aware of:

- **Horizontal lines** are the fast case. All pixels in a horizontal span share
  the same Y, therefore the same bank and row. The operation reduces to a
  byte-range fill within a single contiguous memory region. Use `memset` or
  `REP STOSB`.
- **Vertical lines** are the slow case. Each successive pixel increments Y,
  cycling through all four banks and periodically advancing the row. The memory
  access pattern is a sawtooth across a 24KB range. Optimize by precomputing
  the four bank base pointers once and advancing each by 90 bytes per step,
  rather than recalculating the full address per pixel.
- **Diagonal lines (Bresenham)** fall between these extremes. No clean
  optimization pattern exists for the general case; per-pixel address
  calculation is the practical approach.
- **Filled rectangles** decompose naturally into horizontal spans and benefit
  from the horizontal line optimization above.
- **Blits (rectangular copies)** must account for the interleave: source and
  destination rows in the same logical scanline group will be in the same bank,
  but the four banks must be handled independently. A blit loop that iterates
  over logical scanlines and computes bank+row per scanline is correct if
  unoptimized; an optimized blit would process all 87 rows of each bank in a
  single pass.

### 11.4 Unresolved items that may affect driver behavior

- **A6 (pixel aspect ratio): RESOLVED.** Pixel aspect ratio is 29:45
  (width:height). Applications doing geometry must apply a vertical correction
  factor of 29/45 to pixel radii and heights. See Section 6 A6 for the full
  derivation and validation. The converter parameter `LEMD_VIRTUAL_H = 540`
  encodes this correction for image display purposes.
- **A5 (BIOS INT 10h extension):** If a BIOS mode number exists for this mode,
  it is the more compatible activation path. Worth investigating before the
  driver is considered complete.
- **A9 (CGA switch behavior):** Until A9 is tested, treat the equipment word
  check as necessary but unconfirmed. The check logic is sound by PC
  architecture convention, but its interaction with the Enhanced Video BIOS
  has not been directly observed.

---

## 12. Measured Performance

Performance figures measured on physical Leading Edge Model D hardware with
original amber monochrome monitor. Timing via BIOS tick counter (18.2 Hz);
millisecond values computed as ticks × 55. Test programs are standalone DOS
COM files (NASM), each targeting a single primitive for educational clarity
rather than forming a unified benchmark suite.

### 12.1 Horizontal fill and clear — `lemdtime.com`

Full-screen fill (0xFF) followed by full-screen clear (0x00), 348 scanlines
each pass, using `REP STOSB` across the 90-byte contiguous span per scanline.
No per-pixel address calculation; the horizontal line is a pure memory fill
within a single bank region.

| Pass          | Coverage                  | Result  |
|---------------|---------------------------|---------|
| Fill + clear  | 720 × 348, both passes    | ~220 ms |

This establishes the effective memory write bandwidth ceiling for this
framebuffer. Vertical line and pixel-level operations will be substantially
slower due to read-modify-write overhead and non-contiguous access patterns.

### 12.2 Vertical fill and clear — `lemdvtim.com`

Full-screen fill followed by full-screen clear using 720 vertical lines (one
per column), covering the same 720 × 348 = 250,560 pixels per pass as 12.1.
Each pixel requires a full address calculation (bank, row, byte column),
a bitmask load from memory, and a read-modify-write sequence (3 memory bus
cycles vs. 1 for horizontal). Memory access pattern is a sawtooth across all
four banks (~24 KB range) per column drawn.

| Pass          | Coverage                  | Result      |
|---------------|---------------------------|-------------|
| Fill + clear  | 720 × 348, both passes    | ~55,825 ms  |

**Ratio vs. horizontal: ~254×  slower** for identical pixel coverage.

The dominant costs are: (1) per-pixel address arithmetic (~20 instructions of
shifts and adds replacing a single REP STOSB stride increment); (2) the
read-modify-write replacing a pure write; (3) non-contiguous addressing
preventing any burst or prefetch benefit on the 8088 bus.

This result also exposed a timing range issue: 55,825 ms = ~1,015 ticks,
approaching the 16-bit tick counter's useful range (~1,092 ticks before
overflow risk with the ×55 ms conversion). Tests slower than ~45 seconds
should read the full 32-bit tick counter (low word at 0x0040:0x006C, high
word at 0x0040:0x006E) and compute a 32-bit delta.

---

## 13. Image Display Toolchain

A complete toolchain for displaying photographs and graphics on the LEMD
enhanced monochrome screen was developed and validated on physical hardware
in April 2026. The first photograph ever displayed on this hardware was
produced using these tools.

### 13.1 Overview

Two programs implement the toolchain:

- **`lemdconv`** (Linux, C) — converts a grayscale PGM image to a `.lemd`
  binary file ready for display on the LEMD hardware.
- **`lemdshow.com`** (DOS COM, 8086 assembly) — loads a `.lemd` file from
  disk and blits it to the LEMD framebuffer.

### 13.2 lemdconv — Linux-side converter

```
cc -O2 -Wall -o lemdconv lemdconv.c
./lemdconv input.pgm output.lemd
```

**Input:** Netpbm P5 binary PGM (8-bit grayscale, maxval=255), any dimensions.

**Output:** 31,320-byte `.lemd` file in display-ready LEMD 4-bank interleave
order. Banks are stored sequentially: bank 0 (7,830 bytes), bank 1, bank 2,
bank 3. Each bank is 87 rows × 90 bytes.

**Pipeline:**

1. Read source PGM.
2. Scale into a 720×540 square-pixel virtual canvas using nearest-neighbor
   sampling. Source aspect ratio is preserved; unused borders are black
   (letterbox or pillarbox as needed).
3. Apply Floyd-Steinberg error diffusion dithering to 1-bit in serpentine
   (boustrophedon) scan order — left-to-right on even rows, right-to-left
   on odd rows. Serpentine scanning reduces directional streaking vs.
   standard left-to-right Floyd-Steinberg.
4. Subsample 540 virtual rows to 348 physical scanlines by nearest-center
   row selection. This step applies the pixel aspect ratio correction
   (see Section 6 A6).
5. Scatter linear scanlines into LEMD 4-bank interleave order.
6. Write 31,320 bytes to the output file.

**Aspect ratio correction parameter:**

```c
#define LEMD_VIRTUAL_H  540   /* square-pixel canvas height; derived from
                               * 4:3 display at 720x348: 720*(3/4) = 540 */
```

This value is confirmed correct by hardware validation (Section 6 A6).
Adjust only if physical measurements indicate a different display geometry.

**Recommended ImageMagick pre-processing:**

```bash
convert photo.jpg -resize 720x540^ -gravity center \
        -extent 720x540 -colorspace Gray input.pgm
```

The `^` modifier fills the target size; `-extent` then crops to it,
producing a centred 720×540 crop with no letterboxing.

**Optional gamma compression** (improves highlight detail in high-contrast
photographs): in `scale_to_virtual_canvas()`, replace the direct pixel
assignment with:

```c
#define GAMMA  0.70   /* < 1.0 compresses highlights, expands shadows */

canvas[...] = (unsigned char)(255.0 * pow(v / 255.0, GAMMA) + 0.5);
```

Requires `#include <math.h>` and `-lm` on the build line. Start at 0.70
and bracket toward 0.65 for more aggressive highlight recovery.

### 13.3 lemdshow.com — DOS-side viewer

```
nasm -f bin -o lemdshow.com lemdshow.asm
lemdshow image.lemd
```

**Operation:**

1. Checks BDA equipment word for monochrome monitor (same pre-flight as all
   other LEMD tools).
2. Saves equipment word and current video mode.
3. Activates enhanced mono mode (Section 2 sequence).
4. Clears the framebuffer to black.
5. Opens the `.lemd` file via INT 21h AH=3Dh.
6. For each of the 4 banks: reads 7,830 bytes into a scratch buffer, then
   `REP MOVSB`s the buffer into `0xB000:bank_offset`.
7. Closes the file.
8. Waits for a keypress (INT 21h AH=08h, no echo).
9. Restores equipment word and video mode; exits.

**Display behaviour:** The four-bank blit is visible as a progressive fill:
bank 0 lays down every 4th scanline (0, 4, 8, ...), then banks 1–3 fill
in between. The complete image appears after all four banks are written.
The effect is a characteristic venetian-blind progression over approximately
100ms total. This is an inherent consequence of the 8088 ISA bus write
bandwidth and the file I/O between banks; it is not considered a defect.

**File format requirement:** The `.lemd` file must be exactly 31,320 bytes.
A short read is detected and reported as an error (after restoring text mode).

### 13.4 Validation

The toolchain was validated on physical Leading Edge Model D hardware with
original amber monochrome monitor, April 2026. Source image: 527×415 PGM
(derived from a colour photograph). Output: correctly proportioned,
legible image with good midtone rendering via Floyd-Steinberg dithering.
Highlight clipping was noted in bright areas of the test image; gamma
pre-compression (Section 13.2) is recommended for high-contrast sources.
