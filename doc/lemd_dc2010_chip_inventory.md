# Leading Edge Model D — DC-2010 (512 KB) Chip Inventory

**Board P/N:** 2105004105
**Model:** DC-2010 (non-turbo, 4.77 MHz only)
**Manufacturer:** Daewoo for Leading Edge Hardware Products
**Date:** April 2026 investigation
**ISA slot outer plastic length:** 3.30 inches (measured, use as scale reference)

## Status

All major system ICs identified. One 8-pin chip (5722M at U169) remains
unidentified. The 8284A clock generator location confirmed but U-number
read from description, not photo. FDC corrected from earlier misread
(PP272A → P8272A).

## Corrections Log

- **P8272A FDC:** Earlier misread as "PP272A" (thought it was a PAL). It is
  Intel P8272A floppy disk controller at U65, 40-pin.
- **GI 9631 CDA:** Not a separate chip. This is the manufacturer marking on
  U162 (P/N 23097000, character generator ROM). GI = General Instrument
  manufactured the mask ROM for Daewoo.
- **SP8616:** 16-pin, not 8-pin as initially estimated.
- **SUNNY SCO-010:** 1.8432 MHz (UART baud rate clock), NOT 14.31818 MHz as
  initially misread from lower-resolution photo.
- **23097000:** 28-pin, not 24-pin.
- **SPRAGUE 61Z14A100:** 14-pin, two instances (U190, U196), not one.

## Daewoo Custom Parts (Sequential P/Ns)

| P/N        | Silkscreen | U#   | Pins | Function                        |
|------------|------------|------|------|---------------------------------|
| 23096000   | BIOS       | U96  | 28   | System BIOS ROM                 |
| 23097000   | (none)     | U162 | 28   | Character generator ROM (mfr: GI 9631 CDA, General Instrument) |
| 23098000   | CPU        | U144 | 20   | CPU support PAL/PLA             |
| 23098001   | MEM        | U174 | 20   | Memory decode PAL/PLA           |
| 23098002   | I/O        | U78  | 20   | I/O decode PAL/PLA. Most likely location of port 0x3DD decode |

## CPU and Core System Logic

| Chip              | U#   | Pins | Manufacturer   | Function                        |
|-------------------|------|------|----------------|---------------------------------|
| P8088 (LG270385)  | U58  | 40   | Intel          | 8-bit CPU, 4.77 MHz             |
| D8087-1 (L9380448)| U59  | 40   | Intel          | Math coprocessor (FPU), 10 MHz grade |
| uPB8288D          | U56  | 20   | NEC            | Bus controller. Confirms max mode |
| 8284A             | U75  | 18   | Intel          | Clock generator. 14.31818 MHz / 3 = 4.77 MHz |
| PD8237A-5         | U93  | 40   | AMD            | DMA controller, 5 MHz grade     |
| D8255AC-5         | U92  | 40   | NEC            | PPI. Keyboard, speaker, DIP switches, NMI |
| D8259AC           | U57  | 28   | NEC            | PIC. 8 IRQ lines                |
| P8253-5           | U91  | 24   | Intel          | PIT. Tick counter, DRAM refresh, speaker |
| P/N 23098000      | U144 | 20   | Daewoo         | CPU support PAL/PLA             |

## Video Subsystem

### CRTC
| Chip              | U#   | Pins | Manufacturer   | Notes                           |
|-------------------|------|------|----------------|---------------------------------|
| MC6845P (QL JR58627) | U52 | 40 | Motorola       | CRT Controller. Ports 0x3B4/0x3B5 |

### Pixel Clock / PLL
| Chip              | U#   | Pins | Manufacturer   | Notes                           |
|-------------------|------|------|----------------|---------------------------------|
| KXO-01 16 MHz     | (osc)| 4    | Kyocera        | Dot clock. 864 dots/line = ~18.5 kHz H-freq |
| MC4044P           | U101 | 16   | Motorola       | Phase-frequency detector        |
| MC4024P           | U106 | 14   | Motorola       | Dual VCO                        |
| SP8616            | U191 | 16   | Plessey/Sprague| High-speed prescaler            |

### Video RAM
| Chip              | U#   | Pins | Manufacturer   | Notes                           |
|-------------------|------|------|----------------|---------------------------------|
| MB81416-12 (x~8)  | (cluster) | 18 | Fujitsu   | 16K x 4-bit DRAM, 120 ns. 8 chips = 64 KB VRAM. Confirms hidden page |

### Character Generator ROM
| Chip              | U#   | Pins | Manufacturer   | Notes                           |
|-------------------|------|------|----------------|---------------------------------|
| P/N 23097000 / GI 9631 CDA / 9864DS-1176 | U162 | 28 | General Instrument (for Daewoo) | Chargen ROM. May contain Enhanced Video BIOS (A5) |

### Video Signal Path
| Chip              | U#   | Pins | Manufacturer   | Notes                           |
|-------------------|------|------|----------------|---------------------------------|
| SN74LS166N (x mult)| (various) | 16 | TI         | Parallel-to-serial SR. Pixel serialization at 16 MHz |
| SN74LS374N        | (various) | 20 | TI          | Octal D flip-flop. Video data pipeline latch |
| SN74LS373N        | (various) | 20 | TI          | Octal transparent latch         |
| DM74S153N         | U72  | 16   | National Semi  | Dual 4-to-1 mux (Schottky). Fast video path |
| MC74F74N          | U74  | 14   | Motorola       | Dual D flip-flop (FAST). Speed-critical timing |
| SN74LS670N        | (not located) | 16 | Motorola | 4x4 register file. Could not locate among discrete logic |

### Custom / Specialty Video
| Chip              | U#   | Pins | Manufacturer   | Notes                           |
|-------------------|------|------|----------------|---------------------------------|
| P/N 23098002      | U78  | 20   | Daewoo         | I/O PAL. Silkscreen "I/O". Probable port 0x3DD decode |
| SPRAGUE 61Z14A100 | U190 | 14   | Sprague        | Delay line / hybrid module      |
| SPRAGUE 61Z14A100 | U196 | 14   | Sprague        | Second instance                 |

## FDC

| Chip              | U#   | Pins | Manufacturer   | Notes                           |
|-------------------|------|------|----------------|---------------------------------|
| P8272A (L6270068) | U65  | 40   | Intel          | Floppy Disk Controller (uPD765 equivalent) |

## Serial Port

| Chip              | U#   | Pins | Manufacturer   | Notes                           |
|-------------------|------|------|----------------|---------------------------------|
| WD8250-PL         | U9   | 40   | Western Digital| UART. Original IBM PC type      |
| SUNNY SCO-010 1.8432 MHz | (osc) | 4 | Sunny   | Baud rate clock (NOT system clock) |
| GD75188           | U10  | 14   | Goldstar       | RS-232 line driver (MC1488 equiv) |
| GD75189A          | U11  | 14   | Goldstar       | RS-232 line receiver (MC1489 equiv) |

## RTC

| Chip              | U#   | Pins | Manufacturer   | Notes                           |
|-------------------|------|------|----------------|---------------------------------|
| MM58167AN         | U22  | 24   | National Semi  | Real-Time Clock. Backed by supercap |

## Memory

| Chip              | U#   | Pins | Manufacturer   | Notes                           |
|-------------------|------|------|----------------|---------------------------------|
| KM41256-15 (banks of 9) | (array) | 16 | Samsung | 256K x 1 DRAM, 150 ns. 2 banks = 512 KB. High-memory fault |
| P/N 23098001      | U174 | 20   | Daewoo         | Memory decode PAL/PLA. Silkscreen "MEM" |

## Unidentified

| Chip              | U#   | Pins | Notes                           |
|-------------------|------|------|---------------------------------|
| 5722M             | U169 | 8    | Near PIC/PPI area. Unknown function. Second marking "8029" may be date code |

## TTL Discrete Logic -- Functionally Significant

| Chip              | Function                        | Likely Role                     |
|-------------------|---------------------------------|---------------------------------|
| SN74LS245N        | Octal bus transceiver (bidir)   | Data bus buffering, CPU to VRAM |
| SN74LS244N        | Octal buffer (unidir)          | Address bus buffering            |
| SN74LS243N        | Octal bus transceiver           | Data bus segment                 |
| SN74LS240N        | Octal inverting buffer          | Bus driving with inversion       |
| SN74LS139N        | Dual 2-to-4 decoder             | Bank selection for 4-bank interleave |
| SN74LS138N        | 3-to-8 decoder                  | I/O port address decode          |
| SN74LS157N        | Quad 2-to-1 mux                 | Address mux: CPU vs CRTC for VRAM |
| SN74LS257AN       | Quad 2-to-1 mux (tri-state)    | Address mux with three-state     |
| SN74LS161AN       | 4-bit synchronous counter       | Timing/address counter           |
| SN74LS164N        | 8-bit serial-in/parallel-out SR | Serial-to-parallel conversion    |
| SN74LS299N        | 8-bit bidirectional universal SR| Bidirectional shift register     |
| SN74LS688N        | 8-bit magnitude comparator      | Address comparison for MMIO decode |
| SN74LS85N         | 4-bit magnitude comparator      | Address/value comparison         |
| SN74LS155N        | Dual 2-to-4 decoder/demux      | Address/control decode           |
| SN74LS112AN       | Dual J-K flip-flop              | Clock division / state machine   |
| SN74LS109AN       | Dual J-K flip-flop (pos edge)  | State machine / clock logic      |
| SN74LS174N        | Hex D flip-flop                 | Register/pipeline                |
| SN74LS175N        | Quad D flip-flop                | Register/pipeline                |
| SN74LS74AN        | Dual D flip-flop                | Timing / state                   |
| SN74LS14N         | Hex Schmitt-trigger inverter    | Signal cleanup, switch debounce  |
| SN74LS93N         | 4-bit binary counter (ripple)  | Frequency division               |
| SN74LS21N         | Dual 4-input AND                | Control logic                    |
| DM74S74N          | Dual D flip-flop (Schottky)    | Speed-critical timing path       |
| DM74S08N          | Quad AND (Schottky)             | Speed-critical control logic     |
| DM74S51N          | Dual AND-OR-INVERT (Schottky)  | Speed-critical combined logic    |
| DM74S153N         | Dual 4-to-1 mux (Schottky)    | Fast mux in video path           |
| DM74S157N         | Quad 2-to-1 mux (Schottky)    | Fast address mux                 |
| DM7406N           | Hex inverter (open-collector)  | Shared interrupt lines           |

## TTL Discrete Logic -- Generic Gates

Present in multiple instances across the board:
- SN74LS00N (quad 2-input NAND)
- SN74LS02N (quad 2-input NOR)
- SN74LS04N (hex inverter)
- SN74LS06N (hex inverter/buffer OC)
- SN74LS08N (quad 2-input AND)
- SN74LS10N (triple 3-input NAND)
- SN74LS11N (triple 3-input AND)
- SN74LS27N (triple 3-input NOR)
- SN74LS30N (8-input NAND)
- SN74LS32N (quad 2-input OR)
- SN74LS38N (quad 2-input NAND OC)
- SN74LS86N (quad 2-input XOR)
- SN74LS125AN (quad bus buffer tri-state)
- GD74S32 / GSS (quad 2-input OR, Schottky, Goldstar Semiconductor) -- multiple

## Resistor Networks (SIP, vertical mount)

| Marking      | Value           | Location / Role                 |
|--------------|-----------------|----------------------------------|
| DWR220J      | 220 ohm, 5%    | Near CGA connector. Bus termination |
| DWR330J (x6+)| 330 ohm, 5%   | RP6, RP7 below MC6845; below DRAM columns |
| DWR472J (x5+)| 4.7K ohm, 5%  | RP3, RP14, RP15 and others. Pull-ups |
| DWR221331J   | 220/330 ohm combo | Above floppy connector        |

## Miscellaneous

| Item              | Description                     | Notes                           |
|-------------------|---------------------------------|---------------------------------|
| 14.31818 MHz xtal | System master crystal           | Metal can package near 8284A (U75) |
| SPARE             | Empty socket                    | Near D8255AC (U92)               |
| Daewoo PRO 2 OK   | QC sticker                     | Production line 2 passed         |
| ALPS DIP switch   | S1 configuration switches       | Lower-right corner               |
| Supercap          | RTC backup capacitor            | Near parallel port. No leaking   |
| Yellow paint dab  | Factory QC mark                 | Between COLOR and SERIAL connectors |

## Back Panel (left to right)

| Connector   | Type       | Function                        |
|-------------|------------|---------------------------------|
| MONO        | DE-9F      | MDA monochrome output           |
| Toggle switch| SPDT      | MONO / COLOR selector           |
| COLOR       | DE-9F      | CGA RGBI digital color output   |
| SERIAL      | DB-25M     | RS-232 serial port              |
| PARALLEL    | DB-25F     | Centronics parallel port        |

## Key Findings for Enhanced Mono Mode Investigation

1. **64 KB VRAM confirmed** -- 8x MB81416-12 at 16Kx4 = 64 KB. Hidden page
   at 0x8000-0xFFFF is backed by real silicon.

2. **Dedicated 16 MHz pixel clock** -- KXO-01 oscillator independent of CPU
   clock domain (14.31818 MHz system crystal is separate).

3. **Three-chip PLL** -- MC4044P (U101) + MC4024P (U106) + SP8616 (U191).

4. **Five Daewoo custom parts** -- BIOS, chargen ROM, CPU PAL, MEM PAL, I/O PAL.
   The I/O PAL (U78, P/N 23098002) is the most likely location of port 0x3DD
   decode logic.

5. **Character generator ROM (U162)** manufactured by General Instrument for
   Daewoo. May contain Enhanced Video BIOS extension (Ambiguity A5).

6. **Port 0x3DD logic** -- With GI 9631 CDA confirmed as just the manufacturer
   marking on the chargen ROM, the proprietary port decode is most likely in
   the Daewoo I/O PAL (U78) or distributed across discrete TTL.

7. **Two clock domains** -- 14.31818 MHz (system, via 8284A) and 16 MHz (video,
   via KXO-01 + PLL). Fully independent.
