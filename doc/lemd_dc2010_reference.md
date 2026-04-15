# Leading Edge Model D -- DC-2010 (512 KB) Chip Reference and Service Guide

**Board P/N:** 2105004105
**Model:** DC-2010 (non-turbo, 4.77 MHz only)
**Manufacturer:** Daewoo for Leading Edge Hardware Products
**BIOS:** Phoenix 2.10 with integrated Enhanced Video BIOS
**Date:** April 2026

This document accompanies the chip locator diagram
(`lemd_dc2010_chip_locator.svg`). It provides a reference table for every
component on the board, followed by service notes covering jumper settings,
switch configurations, and known hardware behaviors.


## 1. Chip Reference Table

### 1.1 CPU Core

| Ref  | Part         | Subsystem | Notes |
|------|--------------|-----------|-------|
| U58  | P8088        | CPU Core  | 8-bit CPU, 4.77 MHz. Intel LG270385. 40-pin DIP. The 8088 has an 8-bit external data bus with a 16-bit internal architecture. Confirmed running in max mode by presence of the 8288 bus controller. |
| U59  | D8087-1      | CPU Core  | Math coprocessor (FPU). Intel L9380448. 40-pin DIP, 10 MHz grade. Overspecified for the 4.77 MHz bus but fully compatible. SW2 switch 2 must be set to OFF when installed. |
| U56  | uPB8288D     | CPU Core  | Bus controller. NEC, 20-pin DIP. Generates bus command signals (MEMR, MEMW, IOR, IOW, INTA) from the 8088's S0-S2 status lines. Its presence confirms the 8088 operates in max mode. |
| U75  | 8284A        | CPU Core  | Clock generator. Intel, 18-pin DIP. Divides the 14.31818 MHz system crystal (Y4) by 3 to produce the 4.77 MHz CPU clock. Also generates the READY and RESET signals. |

### 1.2 I/O Peripherals (PIC / PIT / PPI / DMA)

| Ref  | Part         | Subsystem | Notes |
|------|--------------|-----------|-------|
| U57  | D8259AC      | I/O       | Programmable Interrupt Controller. NEC, 28-pin DIP. Manages 8 hardware interrupt lines (IRQ0-IRQ7). IRQ0=timer tick, IRQ1=keyboard, IRQ2=TOD clock (default, selectable via J12), IRQ6=floppy. |
| U91  | P8253-5      | I/O       | Programmable Interval Timer. Intel, 24-pin DIP, 5 MHz. Three independent 16-bit counters: Ch0 drives IRQ0 for the system tick, Ch1 triggers DRAM refresh via DMA, Ch2 generates speaker tones. |
| U92  | D8255AC-5    | I/O       | Programmable Peripheral Interface. NEC, 40-pin DIP, 5 MHz. Handles keyboard scan code input, speaker gate control, DIP switch reading (SW2), and NMI masking. The central hub for low-speed I/O. |
| U93  | PD8237A-5    | I/O       | DMA Controller. AMD, 40-pin DIP, 5 MHz. Four DMA channels: Ch0 handles DRAM refresh (triggered by PIT Ch1), Ch2 services the floppy disk controller. Ch1 and Ch3 are available for ISA cards. |

### 1.3 Video Subsystem

| Ref  | Part              | Subsystem | Notes |
|------|-------------------|-----------|-------|
| U52  | MC6845P           | Video     | CRT Controller. Motorola QL JR58627, 40-pin DIP. Generates horizontal and vertical sync, character row addressing, and cursor timing. Addressed at ports 0x3B4 (index) and 0x3B5 (data) in MDA mode. The CRTC register values define the display timing for all video modes. |
| U101 | MC4044P           | Video     | Phase-frequency detector. Motorola, 16-pin DIP. Part of the 3-chip PLL that synthesizes the 16 MHz pixel clock. Compares the reference frequency against the VCO output and produces an error signal. |
| U106 | MC4024P           | Video     | Dual voltage-controlled oscillator. Motorola, 14-pin DIP. Part of the PLL. Generates the actual pixel clock frequency, steered by the MC4044P error signal. |
| U191 | SP8616            | Video     | High-speed prescaler. Plessey/Sprague, 16-pin DIP. Part of the PLL. Divides the VCO output down to a frequency the MC4044P can compare against the reference. |
| U190 | SPRAGUE 61Z14A100 | Video     | Delay line / hybrid module. Sprague, 14-pin. Provides precision analog delay for video timing alignment. |
| U196 | SPRAGUE 61Z14A100 | Video     | Delay line, second instance. Same function as U190. |
| U70  | SN74LS166N        | Video     | 8-bit parallel-to-serial shift register. TI, 16-pin. Pixel serializer -- converts VRAM bytes into a serial pixel stream at the 16 MHz dot clock rate. |
| U82  | SN74LS166N        | Video     | Pixel serializer, second instance. Works with U70 to serialize the full pixel data path. |
| U68  | SN74LS37xN        | Video     | Video data pipeline latch. Registers VRAM data for the pixel shift registers. Part of the latch chain between VRAM output and pixel serialization. |
| U71  | SN74LS37xN        | Video     | Video data pipeline latch. Part of the VRAM-to-serializer data path. |
| U83  | SN74LS37xN        | Video     | Video data pipeline latch. Part of the VRAM-to-serializer data path. |
| U74  | MC74F74N          | Video     | Dual D flip-flop, FAST logic family. Motorola, 14-pin. Speed-critical video timing element with approximately 5 ns propagation delay. Likely involved in dot clock domain synchronization. |

Additional TTL chips in the video subsystem area (U51, U69, U72, U73,
U80, U81, U84-U89, U112-U116, U134-U139, U163-U166, U186-U189,
U209-U215) provide address multiplexing, bus buffering, timing division,
and control logic for the video data path. These are standard 74LS and
74S series parts performing functions such as VRAM address muxing (CPU vs
CRTC access), bank selection for the 4-bank interleave, and sync signal
conditioning.

### 1.4 Video RAM (VRAM)

| Ref  | Part         | Subsystem | Notes |
|------|--------------|-----------|-------|
| U108 | MB81416-12   | VRAM      | 16K x 4-bit DRAM, 120 ns. Fujitsu, 18-pin DIP. One of 8 VRAM chips providing 64 KB total video memory. The 4 chips U108-U111 form the visible display page (lower 32 KB at B000:0000-7FFF). Each chip maps to one interleave bank: the chip at bank N holds scanlines N, N+4, N+8, ... N+344. |
| U109 | MB81416-12   | VRAM      | VRAM bank chip. Same specs as U108. |
| U110 | MB81416-12   | VRAM      | VRAM bank chip. Same specs as U108. |
| U111 | MB81416-12   | VRAM      | VRAM bank chip. Same specs as U108. |
| U131 | MB81416-12   | VRAM      | 16K x 4-bit DRAM. Fujitsu, 18-pin DIP. One of 4 chips forming the hidden display page (upper 32 KB at B000:8000-FFFF). This is the off-screen drawing buffer documented as Ambiguity A10 in the enhanced mono spec. |
| U132 | MB81416-12   | VRAM      | Hidden page VRAM chip. Same specs as U131. |
| U133 | MB81416-12   | VRAM      | Hidden page VRAM chip. Same specs as U131. |
| U134 | MB81416-12   | VRAM      | Hidden page VRAM chip. Same specs as U131. |

Note: Some chips may be marked MB81416-15 (150 ns) rather than -12
(120 ns). The suffix is the access time grade only; the chips are
otherwise identical. The -12 and -15 variants are interchangeable in this
application.

### 1.5 System DRAM

| Ref  | Part         | Subsystem | Notes |
|------|--------------|-----------|-------|
| U122 | KM41256-15   | DRAM      | 256K x 1-bit DRAM, 150 ns. Samsung, 16-pin DIP. Bank A (9 chips, U122-U130). Eight chips provide 256 KB of data; the ninth is the parity bit. |
| U123 | KM41256-15   | DRAM      | Bank A. |
| U124 | KM41256-15   | DRAM      | Bank A. |
| U125 | KM41256-15   | DRAM      | Bank A. |
| U126 | KM41256-15   | DRAM      | Bank A. |
| U127 | KM41256-15   | DRAM      | Bank A. |
| U128 | KM41256-15   | DRAM      | Bank A. |
| U129 | KM41256-15   | DRAM      | Bank A. |
| U130 | KM41256-15   | DRAM      | Bank A. |
| U150 | KM41256-15   | DRAM      | 256K x 1-bit DRAM, 150 ns. Samsung, 16-pin DIP. Bank B (9 chips, U150-U158). |
| U151 | KM41256-15   | DRAM      | Bank B. |
| U152 | KM41256-15   | DRAM      | Bank B. |
| U153 | KM41256-15   | DRAM      | Bank B. |
| U154 | KM41256-15   | DRAM      | Bank B. |
| U155 | KM41256-15   | DRAM      | Bank B. |
| U156 | KM41256-15   | DRAM      | Bank B. |
| U157 | KM41256-15   | DRAM      | Bank B. |
| U158 | KM41256-15   | DRAM      | Bank B. |

Empty sockets U177-U185 accept a third bank of 9 KM41256-15 chips to
expand system memory from 512 KB to 640 KB. Jumper J23 must be changed
to indicate 640 KB when the expansion bank is populated. Unpopulated
silkscreen positions U199-U207 were designed for a fourth bank that would
bring total capacity to 1 MB, but this configuration was never shipped.
The XT memory map cannot use conventional RAM above 640 KB, so the fourth
bank would only be useful with special software or memory managers.

### 1.6 Daewoo Custom Parts

| Ref  | Part            | Subsystem | Notes |
|------|-----------------|-----------|-------|
| U96  | P/N 23096000    | Daewoo    | System BIOS ROM. 28-pin DIP. Contains Phoenix 2.10 BIOS with integrated Enhanced Video BIOS. 8K or 16K (J16 has no jumper, indicating 8K or 16K size). This is the only ROM needed for normal operation. The "Leading Edge Model D with Enhanced Video BIOS" banner at boot comes from this chip. |
| U162 | P/N 23097000    | Daewoo    | Character generator ROM. 28-pin DIP. Manufactured by General Instrument (markings: GI 9631 CDA, 9864DS-1176). Contains the dot patterns for MDA text mode characters. May also be consulted during CGA text mode. |
| U144 | P/N 23098000    | Daewoo    | CPU support PAL/PLA. 20-pin DIP. Silkscreen label "CPU". Custom address and control decode logic. |
| U174 | P/N 23098001    | Daewoo    | Memory decode PAL/PLA. 20-pin DIP. Silkscreen label "MEM". Handles DRAM bank selection and refresh decode. |
| U78  | P/N 23098002    | Daewoo    | I/O decode PAL/PLA. 20-pin DIP. Silkscreen label "I/O". Most likely location of port 0x3DD decode logic -- the proprietary register that enables the enhanced monochrome graphics mode. This is the single most critical chip for the enhanced video mode and is irreplaceable without a donor board or reverse-engineered PAL equations. |

The five Daewoo custom parts use sequential part numbers (23096000
through 23098002). These are proprietary and cannot be sourced as
standard parts. If any of these fail, a replacement must come from
another DC-2010 board.

### 1.7 Floppy Disk Controller

| Ref  | Part         | Subsystem | Notes |
|------|--------------|-----------|-------|
| U65  | P8272A       | FDC       | Floppy Disk Controller. Intel L6270068, 40-pin DIP. Functionally equivalent to the NEC uPD765. Directly drives the floppy ribbon cable via connector J15. Can be disabled via J13 jumper 4 if an ISA floppy controller card is installed. |

### 1.8 Serial Port

| Ref  | Part         | Subsystem | Notes |
|------|--------------|-----------|-------|
| U9   | WD8250-PL    | Serial    | UART. Western Digital, 40-pin DIP. Original IBM PC type 8250 (not the later 16550 with FIFO). Directly drives the DB-25 serial connector at J7. Clocked by the SUNNY 1.8432 MHz oscillator (Y2). Can be disabled via J13 jumper 5. |
| U10  | GD75188      | Serial    | RS-232 line driver. Goldstar, 14-pin DIP. MC1488 equivalent. Converts TTL-level UART outputs to RS-232 voltage levels (+/- 12V). |
| U11  | GD75189A     | Serial    | RS-232 line receiver. Goldstar, 14-pin DIP. MC1489 equivalent. Converts RS-232 input voltages to TTL levels for the UART. |

### 1.9 Real-Time Clock

| Ref  | Part         | Subsystem | Notes |
|------|--------------|-----------|-------|
| U22  | MM58167AN    | RTC       | Real-Time Clock. National Semiconductor, 24-pin DIP. Maintains date and time when the system is powered off. Backed by a sealed NiCd battery (B1), not a supercapacitor as previously documented. The RTC interrupt can be assigned to IRQ 2, 4, 5, or 7 via jumper J12 (default: IRQ 2). Removing J12 entirely disables the RTC interrupt. The RTC subsystem can be fully disabled via J13 jumper 2. |

### 1.10 Unidentified

| Ref  | Part         | Subsystem | Notes |
|------|--------------|-----------|-------|
| U169 | 5722M        | Unknown   | 8-pin DIP. Near the PIC/PPI area. Second marking "8029" may be a date code (1980 week 29). Function unknown. Possibly a small timing or supervisory IC. |

### 1.11 EMI Filter

| Ref  | Part              | Subsystem | Notes |
|------|-------------------|-----------|-------|
| F1   | TDK ZJY51R5-8P    | Filter    | Common mode filter, 8-line DIP package. TDK, date code 8620. Provides EMI suppression on 8 signal lines for FCC compliance. Located near the back panel connectors. Not a logic component -- passive ferrite filter. |

### 1.12 Empty Sockets

| Ref  | Function               | Notes |
|------|------------------------|-------|
| U97  | Optional BIOS ROM      | 40-pin DIP socket. Accepts a supplemental ROM (e.g. network boot ROM, hard disk controller ROM). A small jumper near U97 selects between the two BIOS sockets. J16 must be installed if the total ROM space reaches 32K. |
| U177-U185 | RAM Expansion (Bank C) | 9 x 16-pin DIP sockets. Accept KM41256-15 or equivalent 256K x 1-bit DRAM to expand system memory from 512 KB to 640 KB. All 9 chips must be installed together (8 data + 1 parity). Set J23 bottom jumper when populated. |


## 2. Connectors

| Ref  | Type          | Function |
|------|---------------|----------|
| J1   | ISA 62-pin    | ISA Expansion Slot 1 |
| J2   | ISA 62-pin    | ISA Expansion Slot 2 |
| J3   | ISA 62-pin    | ISA Expansion Slot 3 |
| J4   | ISA 62-pin    | ISA Expansion Slot 4 |
| J6   | DB-25F        | Parallel port (Centronics). Can be disabled via J13 jumper 3. |
| J7   | DB-25M        | Serial port (RS-232). Directly driven by WD8250 UART at U9. Can be disabled via J13 jumper 5. |
| J8   | DE-9F         | Color monitor output (CGA / CGA-enhanced RGBI digital). Active when rear panel switch SW1 is set to "C". |
| J9   | DE-9F         | Monochrome monitor output (MDA). Active when rear panel switch SW1 is set to "M". Required for the enhanced monochrome graphics mode. |
| J14  | Molex-type    | Main power connector. Accepts the standard AT power supply connector. |
| J15  | 34-pin header | Floppy disk drive ribbon cable connector. Directly driven by P8272A FDC at U65. |


## 3. Crystals and Oscillators

| Ref  | Frequency     | Function |
|------|---------------|----------|
| Y2   | 1.8432 MHz    | UART baud rate clock. SUNNY SCO-010 oscillator can. Divided internally by the WD8250 to produce standard baud rates (300, 1200, 2400, 4800, 9600, etc.). This is NOT the system clock. |
| Y3   | 16 MHz        | Pixel dot clock. KXO-01 Kyocera oscillator can. Feeds the 3-chip PLL (U101, U106, U191) which synthesizes the pixel clock for the video subsystem. 864 dots per line gives approximately 18.5 kHz horizontal frequency. Completely independent of the system clock domain. |
| Y4   | 14.31818 MHz  | System master crystal. Metal can package near U75 (8284A). Divided by 3 by the 8284A to produce the 4.77 MHz CPU clock. This is the standard IBM PC crystal frequency. |

The system has two independent clock domains: 14.31818 MHz (system, via
Y4 and U75) and 16 MHz (video, via Y3 and PLL). They are asynchronous
to each other.


## 4. Jumpers and Switches

### 4.1 Jumpers

| Ref  | Pins | Function | Notes |
|------|------|----------|-------|
| J10  | --   | Monitor controller disable | Not populated on this board. Solder pads visible near J9 (mono connector). Remove this jumper to disable the onboard video controller when installing a separate monitor controller in an expansion slot. |
| J11  | 6    | Light pen connector | 6-pin header for an external light pen. Period-correct input device. |
| J12  | 4    | TOD clock interrupt request selection | Selects which IRQ line the MM58167AN RTC uses. Position 1: IRQ 2 (default). Position 2: IRQ 4. Position 3: IRQ 5. Position 4: IRQ 7. Removing the jumper entirely disables the RTC interrupt, freeing the IRQ for other use. |
| J13  | 5    | I/O controller enable/disable | Five jumpers controlling four onboard I/O subsystems individually. Removing a jumper disables the corresponding controller to avoid conflicts with ISA expansion cards. Jumper 5: Serial controller. Jumper 4: Floppy-disk controller. Jumper 3: Parallel controller. Jumper 2: Real-time clock. Jumper 1: Not used. |
| J16  | 1    | Installed ROM size | No jumper: 8K or 16K ROM (normal, single BIOS at U96). Jumper installed: 32K ROM (when supplemental ROM is installed in U97). |
| J17  | 1    | Unknown | Located on the right edge of the board near the case connector pins. Not connected to anything on the units examined. |
| J18  | 2    | Keyboard connector | Case connector for the keyboard cable. |
| J19  | 2    | Speaker connector | Case connector for the internal speaker. |
| J20  | 1    | Reset switch | Case connector for the front panel reset button. |
| J21  | 1    | Power LED | Case connector for the front panel power indicator LED. |
| J23  | 2    | RAM size indication | Double jumper. Top jumper installed: 512 KB RAM (default with Banks A and B populated). Bottom jumper installed: 640 KB RAM (with Bank C at U177-U185 also populated). |

### 4.2 SW1 -- Rear Panel Monitor Switch

| Position | Monitor Type |
|----------|--------------|
| M        | Monochrome (MDA). Selects J9 output. Required for enhanced mono graphics mode. BIOS equipment word bits [5:4] are set to 11b. |
| C        | Color (CGA). Selects J8 output. Enhanced mono graphics mode must not be activated in this position. |

### 4.3 SW2 -- DIP Configuration Switch (8 positions)

| Switch | OFF | ON |
|--------|-----|------|
| 1      | Normal system operation | Loop on self-tests (manufacturing/service mode -- POST runs in an infinite loop) |
| 2      | 8087 coprocessor mounted | 8087 coprocessor not mounted |
| 3+4    | Either OFF: all memory tested at power-on | Both ON: only 64K of memory tested at power-on |
| 5+6    | Both OFF: control deferred to SW1 on the rear panel; select "M" (Monochrome) or "C" (Color) | Other combinations: not documented in the operator's manual |
| 7+8    | Both ON: 1 floppy drive. 7 OFF + 8 ON: 2 drives. 7 ON + 8 OFF: 3 drives. Both OFF: 4 drives | (see left) |


## 5. Other Components

| Ref  | Type              | Notes |
|------|-------------------|-------|
| B1   | Sealed NiCd battery | Backs the MM58167AN RTC at U22. Located near the parallel port connector. Previously misidentified as a supercapacitor. Neither unit examined shows signs of leakage or corrosion, but the batteries are unlikely to hold charge after 40 years. Replacement with a modern equivalent or a supercap conversion is advisable if accurate timekeeping is needed. |


## 6. Glue Logic (TTL)

98 chips on the board are standard 74LS-series and 74S-series TTL logic
performing address decode, bus buffering, timing, and control functions.
These are all commodity parts available from any electronics supplier.
The most commonly occurring types are:

SN74LS244N and SN74LS245N (octal buffers and transceivers for data/address
bus driving), SN74LS373N and SN74LS374N (octal latches and flip-flops for
pipeline registers), SN74LS138N (3-to-8 decoders for address decode),
SN74LS157N and SN74LS257AN (quad 2-to-1 multiplexers for address muxing
between CPU and CRTC VRAM access), SN74LS04N and SN74LS00N (hex inverters
and quad NAND gates for general control logic), and SN74LS174N/175N (hex
and quad D flip-flops for state registers and timing dividers).

Several Schottky (74S) parts are used in the speed-critical video timing
path: DM74S153N (dual 4-to-1 mux), DM74S74N (dual D flip-flop),
DM74S08N (quad AND), and DM74S280N (parity generator). These have
approximately 2-3x faster propagation delay than their LS equivalents
and are used where the 16 MHz pixel clock demands it.

A Goldstar GD74S32 / GSS (quad OR, Schottky) appears in multiple
instances, recognizable by the "GSS" manufacturer logo.

Note: The U-number sequence has gaps where discrete passive components
(resistor networks, capacitors) occupy positions in the layout grid.
Notably, U40 and U148 are occupied by passives, and U199-U207 are
unpopulated silkscreen positions for the never-shipped fourth DRAM bank.


## 7. Service Notes

### 7.1 CRTC Warm Reboot Hazard

Leaving the MC6845P CRTC (U52) programmed for the enhanced monochrome
graphics mode timing before executing a warm reboot (Ctrl+Alt+Del) will
drive the monitor at incorrect sync frequencies. The visible symptom is a
rapid vertical scroll of distorted scanlines, often accompanied by an
audible whine from the monitor's flyback transformer. This is stressful
to the monitor but not immediately destructive.

**Prevention:** Always restore MDA text mode (INT 10h AH=00, AL=07)
before rebooting. Any software that activates the enhanced mode must
include a clean exit path that reprograms the CRTC.

### 7.2 4-Bank vs 2-Bank Interleave Incompatibility

The DC-2010 enhanced monochrome mode uses a 4-bank framebuffer interleave
(scanline Y maps to bank Y AND 3, row Y SHR 2). The Hercules Graphics
Card uses a 2-bank interleave at the same 720x348 resolution.
Hercules-compatible software running on the DC-2010 will silently skip
banks 2 and 3, producing a vertically compressed image that uses only the
top half of the screen. This is a fundamental addressing incompatibility,
not a bug -- the software is writing to the correct Hercules addresses,
but those addresses map to different scanlines on the DC-2010.

The game Starflight is a confirmed example of this behavior.

### 7.3 BDA Transparency

The enhanced monochrome mode activation sequence bypasses INT 10h
entirely, writing directly to the CRTC registers, mode control ports, and
the proprietary port 0x3DD. As a result, the BIOS Data Area video mode
byte at 0040:0049h remains set to 07h (MDA text mode). The BIOS is
completely unaware that the video mode has changed. Software that reads
the BDA to determine the current video mode will incorrectly report MDA
text mode.

### 7.4 Two Independent Clock Domains

The board has two fully independent clock systems. The 14.31818 MHz
system crystal (Y4) feeds the 8284A clock generator (U75) to produce the
4.77 MHz CPU clock. The 16 MHz pixel clock oscillator (Y3) feeds a 3-chip
PLL (U101, U106, U191) to produce the video dot clock. These domains are
asynchronous -- there is no frequency relationship between them.

The UART baud rate clock (Y2, 1.8432 MHz) is a third independent
oscillator dedicated to the serial port.

### 7.5 VRAM Architecture and the Hidden Page

The 64 KB of VRAM is split across 8 Fujitsu MB81416-12 chips in two
groups. U108-U111 map to the visible display page (B000:0000-7FFF) and
U131-U134 map to the hidden page (B000:8000-FFFF). The 4-bank interleave
means each of the 4 chips in a group directly corresponds to one
interleave bank. A failure in a single VRAM chip would produce a
characteristic symptom: every 4th scanline would display corrupted data,
creating a pattern of 3 good lines followed by 1 bad line, repeating
across the entire screen height.

The hidden page provides an off-screen drawing buffer for double-buffered
animation. The mechanism for flipping between visible and hidden pages
(Ambiguity A10 in the enhanced mono spec) has not yet been fully
investigated.

### 7.6 Port 0x3DD -- Enhanced Mode Enable

Port 0x3DD is the proprietary control register that enables the enhanced
monochrome graphics mode. It is not present on standard IBM MDA or CGA
hardware. Bit 3 (value 0x08) is the confirmed mode enable bit. The port
decode logic is most likely implemented in the Daewoo I/O PAL at U78
(P/N 23098002).

The full bit definition of port 0x3DD is not known. Only bit 3 has been
confirmed. The diagnose.com utility was observed to OR bit 3 into a
previously saved value, suggesting other bits may have meaning. Writing
0x08 directly is the safe conservative approach.

It is not known whether port 0x3DD supports reads. Write-only behavior is
common for XT-era control registers. Do not perform read-modify-write on
this port without further investigation.

### 7.7 NiCd Battery (B1)

The RTC backup power source is a sealed NiCd battery, not a supercapacitor
as previously documented. While neither of the two examined units shows
signs of leakage, NiCd batteries of this age (approximately 1986) are
well past their rated service life and should be considered for
replacement. NiCd cells can leak potassium hydroxide which is corrosive
to PCB traces. Periodic visual inspection is recommended.

### 7.8 Diagnostic Note: SW2 Switch 1

Setting SW2 switch 1 to ON puts the system into a self-test loop mode.
POST will run continuously, repeating all power-on diagnostics
indefinitely. This is a factory/service feature for burn-in testing and
intermittent fault diagnosis. The system will not boot to DOS in this
mode. Remember to set switch 1 back to OFF for normal operation.
