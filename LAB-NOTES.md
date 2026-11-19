# Mac Pro 6,1 (E5-2697 v2) — CPU tuning / OC / undervolt investigation

Running lab notebook. Goal: find any method to undervolt, overclock, or override the turbo table on the
2013 Mac Pro's Xeon E5-2697 v2 (Ivy Bridge-EP, CPUID 0x306E4, 12c/24t). Host = Proxmox at 10.27.27.6
("trashcanmac"). All work dated 2026-11-19.

## TL;DR status
- **Turbo-ratio override: DEAD END (silicon fuse).** PLATFORM_INFO[28]=0 → part is not OC-capable; 0x1AD writes won't stick.
- **Software undervolt: DEAD END.** No OC mailbox on Ivy Bridge-EP (MSR 0x150/0x620/0x690 all #GP live).
- **Custom-BIOS undervolt: DEAD END.** Apple EFI has no CPU-voltage/SVID/OC code path; PCU mailbox has no VID command on IVB-EP.
- **Power limits: writable but useless here.** PKG_POWER_LIMIT unlocked, but the chip already holds all-core 3.0 GHz at ~71 W / 130 W limit.
- **BCLK overclock: ALIVE and confirmed.** Clock gen is runtime-reprogrammable over SMBus. See "BCLK" below. This is the one working OC path.
- **CPU swap to unlocked E5-16xx v2: PLAUSIBLE (hardware).** Apple's PPM keeps the turbo-override path; an unlocked part would allow 0x1AD writes.
- **VRM undervolt (ISL6367): hardware mod only.**

## Hardware facts (live MSRs, read 2026-11-19)
- PLATFORM_INFO (0xCE) = 0x00000c10e4811b00 → base ratio 27 (2.7 GHz), min 12 (1.2 GHz),
  **bit28 (turbo programmable / OC-capable) = 0**, bit29 (TDP programmable)=1, bit30 (TJ)=1.
- PKG_POWER_LIMIT (0x610) = 0x000684e000148410 → **bit63 LOCK = 0 (unlocked)**, PL1=130 W en, PL2=156 W en.
- PERF_STATUS (0x198) = cur ratio 30 (3.0 GHz all-core), cur voltage ~1.036 V.
- FLEX_RATIO (0x194) = 0 → OC-lock bit20 = 0, enable bit16 = 0.
- MISC_ENABLE (0x1A0) bit38 (turbo disable) = 0 (turbo on).
- **#GP (unreadable) on this CPU:** MSR 0x150 (OC mailbox), 0x620 (uncore ratio), 0x690 (limit reasons).
  → Ivy Bridge-EP has no on-die FIVR / OC mailbox. This is the architectural wall for software undervolt.
- Under real DayZ load: all 12 cores at 3002 MHz, ~71 W, 57 °C → not power- or thermally-limited.

## Firmware dump
- flashrom -p internal: chipset Intel C60x/X79; chip Macronix **MX25L6405, 8 MB**, mapped 0xFF800000.
- Regions: descriptor 0x0-0xFFF, ME 0x1000-0x18FFFF, BIOS 0x190000-0x7FFFFF (standard Intel layout).
- **SPI Protected Range (write locks):** PR0 0x0-0xFFF, PR1 0x190000-0x59FFFF, PR2 0x5C2000-end → most of
  the BIOS region is read-only to the internal programmer. A custom-BIOS *write* needs a hardware programmer
  (CH341A + SOIC-8 clip). Reads are not blocked.
- Dump: two reads, byte-identical, sha256 `e4dd89c2aba33fab2dbfbe074ea48833d96c633384e9d717d7c043fcb979ae09`.
  Saved: `../macpro_bios_dump_20261119_MX25L6405_8MB.bin` (verified backup). Extracted tree analyzed.
- Microcode present: 0x306E0/0x306E2/0x306E3/**0x306E4 rev 0x42e** (2019-03-14), two banks. (Apple ships a
  *newer* v2 microcode than the ASUS P9X79 BIOS, which had rev 0x42c.)
- CPU PowerManagement DXE = Intel reference PPM. GUIDs: `77ad7fdb-df2a-4302-8898-c72e4cdbd0f4` (sweep hit),
  `f7731b4c-58a2-4df4-8980-5645d39ece58` (PPM with "BootCampProcessorPstates"). Keeps a turbo-override path
  (writes 0x1AD/0x1AE if PLATFORM_INFO[28] set and FLEX_RATIO[19:17] non-zero) — inert on a fused-locked part.
- No CPU-voltage/SVID/overclock strings anywhere in the Apple image (only "DDR Voltage Level").

## Why PCU / custom-BIOS voltage is a dead end (second-opinion static analysis)
- IVB-EP PCU is bus 0xFF, dev 10, func 0-3. A BIOS↔pcode mailbox exists at D10:F1 offset 0x8C (data)/0x90
  (interface, bit31 run). Apple's PPM uses it (commands 0x91/0x93/0x9A/0x9C).
- Intel's Grantley header marks `MAILBOX_BIOS_CMD_VR_INTERFACE 0x04 // New in HSX` → the SVID/VR passthrough
  does **not exist on Ivy Bridge (IVT)**. IVT-era commands are DDR VDD ramp, DIMM VR phase shed,
  ACTIVE_VR_MASK, READ_CPU_VR_INFO, VR12 workarounds — none sets a core VID or offset.
- So neither a custom BIOS nor an injected DXE can set a core-voltage offset on this CPU. "CPU VCORE Offset"
  on X79 boards is therefore applied at the board's VRM controller, not CPU-side — not replicable on the Mac,
  whose VRM (Intersil ISL6367) is Apple-wired, most likely to the SMC.

## BCLK — the live overclock path (CONFIRMED)
- Clock generator: **ICS 932SQL435AL** (CK420BQ family), on the PCH SMBus (i801, `0000:00:1f.3` = i2c bus 0),
  address **0x69**. iFixit teardown corroborates the chip.
- The firmware programs it: PEI module `ee685731-cff3-4ee7-9388-7e63fc5a59b0` does SMBus ReadBlock @0x69,
  sets byte[1] |= 0x80, WriteBlock (CK420BQ block protocol).
- **Live read-only probe (2026-11-19), SMBus block read of 0x69:**
  ```
  byte: 0    1    2    3    4    5    6    7    8    9
        ff   fe   8f   14   03   00  [13] [01]  0a  [35]
  ```
  - byte9 = 0x35 → device id "435" ✓ (ICS 932SQL435AL)
  - byte7 = 0x01 → vendor low nibble 1 = ICS/IDT ✓
  - byte6 = 0x13 → freq select bits[2:0] = 011 = **100 MHz (default/stock)** ✓ (matches the 932SQL420 table)
- **Frequency table (932SQL420 sibling; the 435's own table is unverified):** byte6 bits[2:0]:
  000=97, 001=98, 010=99, 011=100(default), 100=101, 101=102, 110=103, 111=104 MHz (1 MHz steps,
  "margining only / not guaranteed"). A wider-table sibling (932SQ420D) reaches ~110 MHz.
- **Expected gain:** ~+1 MHz BCLK ≈ +1% on CPU **and** PCIe/DMI/SATA/TB/RAM. Locked v2 Xeons on X79 boards
  reportedly top out ~106-112 MHz BCLK. So realistically 3.0→~3.1-3.3 GHz all-core before something breaks.
- **Risks:** a PLL step at runtime can hang the box; IO buses scale (small corruption risk); TSC/timekeeping
  skews under a running kernel (do it pre-boot via an EFI app to avoid). Setting is **volatile** → power-cycle
  restores 100 MHz. The 435's exact table is unverified, so step 1 MHz at a time.
- **Plan (user chose: prep script, run at a quiet window):** tool = `macpro-bclk.sh` (read-only default).
  Procedure in `README.md`. First real write pending a maintenance window with no players.

## Can we overclock ONLY the CPU — decouple RAM/PCIe/IO? (analysis 2026-11-19)
Question raised: "trick the CPU with a false BCLK so only the CPU OCs, RAM/IO unaffected," and "is there a
solder mod for it?" Honest engineering answer:

- **You cannot spoof it.** Core frequency = `ratio × physical host-clock`, and the PLL locks to the *real*
  differential clock — there is no register the CPU reads a "BCLK number" from and multiplies. PERF_STATUS /
  `cpu MHz` are *reported* values, not inputs. And the ratio is fused-locked (PLATFORM_INFO[28]=0), so the
  only way to raise core MHz is to raise the real host clock. The real question is clock-domain separation.

- **PCIe / DMI / SATA / USB / TB — probably ALREADY decoupled (good news).** The CK420-family clock gen emits
  *separate* output domains: a CPU host-clock differential pair (what byte6's freq-select moves) and independent
  **SRC** outputs (PCIe 100 MHz, spread-spectrum) plus a legacy 14.318/33 MHz ref. On classic CK420 parts the
  "CPU frequency select" moves ONLY the CPU host pair; the SRC/PCIe outputs stay pinned near 100 MHz. That is
  exactly why Sandy/Ivy "BCLK strap/gear" OC works at all — PCIe/DMI are held near 100 while the CPU host clock
  climbs. **If that holds here, raising byte6 raises only the CPU host clock and leaves IO at 100 — the scary
  "IO corruption" risk is largely moot.** TESTABLE: after a 1 MHz step, confirm `lspci -vv` link speeds, NVMe/SATA
  (`smartctl`), and `journalctl -k` are clean; and map more of the clock-gen block for a separate SRC select byte
  (we only decode byte6/7/9 so far; bytes 2–5 = 8f 14 03 00 are unexplored and likely SRC/ratio/SSC controls).

- **RAM — CANNOT be decoupled.** The E5-2697 v2's memory controller is **on-die**, clocked from the *same* CPU
  host clock: `DRAM = host_clock × DDR_ratio`. No solder iron can separate that — the path is inside the package.
  So RAM scales with the CPU OC, full stop. Mitigations:
  - Lower the DDR multiplier one notch so DDR lands back in spec (e.g. 1866→1600 strap). **But** the Mac Pro's
    memory ratio is picked by Apple's MRC at boot with no Setup/runtime knob — we don't have that lever (would
    need a custom BIOS we can't easily flash). Effectively unavailable.
  - Accept a mild RAM OC: DDR3-1866 ECC at +6% ≈ 1980. Server ECC usually tolerates this, and crucially **ECC
    corrects and REPORTS** — the stability tester's EDAC counter is exactly how we'd catch it, not silent corruption.
  → Net: **RAM, not IO, is the real ceiling** of a Mac Pro BCLK OC. Better than first assumed.

- **Hardware/solder mods.**
  - *For the clock:* none beats the SMBus method — you can't physically decouple RAM from the on-die IMC host clock.
  - *For voltage (the thing software can't touch on IVB-EP):* the legitimate mod is a **VRM feedback/VID mod on the
    ISL6367**. VCORE is Apple-driven over SVID; adding/shifting a resistor on the controller's offset or remote-sense
    node can bias VCORE **down (undervolt for efficiency)** or **up (more BCLK headroom)**. Harder than the classic
    FB-divider trick because an SVID loop regulates to its target (a naive FB resistor can be compensated out); the
    clean version taps an offset pin or the sense network. Needs the ISL6367 datasheet + board schematic/probing,
    fine SMD rework, real brick risk. This is the one hardware mod with genuine payoff (matches the DayZ-efficiency
    goal). First step is read-only: confirm the controller part and locate its FB/offset network from teardown photos.

## VRM / ISL6367 voltage control — research (2026-11-19)
Goal: a hardware (or better, software) route to the CPU undervolt that the CPU's own interfaces can't do on IVB-EP.

**Part confirmed.** Two independent teardowns (iFixit #20778; manuals.plus guide) identify the Mac Pro 6,1 CPU VRM
controller as the **Intersil/Renesas ISL6367** — "Green Hybrid Digital Dual 6+1 Phase PWM Controller for VR12/IMVP7,
with SMBus/PMBus/I2C." 60-lead QFN. 6-phase output VR0 = CPU core (or memory); 1-phase VR1 = GPU/SA/VCCIO. Now
obsolete; full datasheet (FN7884) is gated ("request from Intersil"). Only the 2-page data-short is public.

**Key line from the data-short (changes the plan):** *"It includes programmable functions and telemetries… and
**overclocking applications using SMBus, PMBus, or I2C (Modified) interface, which is designed to be conflict free with
CPU's SVID bus.**"* Plus "SerialVID with Programmable IMAX, TMAX, BOOT, **ADDRESS OFFSET** Registers."

Interpretation:
- The ISL6367 has an **independent SMBus/PMBus register interface, explicitly for overclocking, that does NOT fight
  the CPU's SVID bus.** So a **software voltage offset (undervolt/overvolt) may be possible with NO soldering** — not
  via the CPU (which has no OC mailbox on IVB-EP), but by commanding the **VR chip directly over PMBus.** This partially
  overturns the earlier "no software undervolt" verdict: it was true for CPU-side interfaces, but the VR itself has a
  back door. (The "ADDRESS OFFSET" register is the SVID *bus-address* offset, not a voltage offset — don't confuse them;
  the voltage-offset capability is the separate PMBus/overclocking register set, whose map is in the gated full datasheet.)
- **The catch — reachability.** This only works if the ISL6367's PMBus pins are wired to a bus the Proxmox host can see
  (e.g. the PCH i801 SMBus where the clock gen lives at 0x69, or a muxed segment), rather than to Apple's **SMC** on a
  private bus. On most Macs the VR telemetry goes to the SMC, not the host PCH — so this may be unreachable from the OS.
  **This is the decisive unknown, and it's testable READ-ONLY** (see below).

**Solder-mod reality (the original question):**
- Classic Intersil **OFS-pin** undervolt: on sibling analog parts (ISL6313/6333/6264) a resistor on the OFS pin sets a
  DC offset — OFS→GND raises VCORE, OFS→VCC lowers it (undervolt); `Voffset = Ioffset × RFB`, `ROFS = Vref×RFB/Voffset`
  (Vref 0.3V to GND / 1.6V to VCC on ISL6313; 1.2V on ISL6264). **BUT** I could not confirm the ISL6367 even has an
  *analog* OFS pin — VR12/SVID parts generally moved offset into **digital registers** (the PMBus path above), which fits
  this part's "overclocking over PMBus" pitch. So the clean solder mod may not exist; the intended knob is PMBus.
- **Remote-sense (VSEN/RTN/VDIFF) injection mod:** universal to analog-sense VRs — add a resistor to bias the sense node
  and the loop regulates to a shifted VCORE. On a ±0.5% differential-remote-sense SVID part with droop, this is finicky
  and can trip protection; high brick risk. Last resort.
- **Reading resistor values/locations off teardown photos is NOT feasible** — iFixit's Mac Pro 2013 shots aren't macro
  board-level images with legible 0402 markings. Any solder mod needs the **820-5494-A boardview/schematic** (Rossmann
  community has an 820-5494-A thread) or the physical board under a scope. Photo-only identification is a dead end.

**Verdict / priority flip:** before any soldering, test the **software PMBus path** — it's non-destructive, reversible,
and if the VR answers on the host SMBus it gives the undervolt with zero hardware risk. Only if the VR is SMC-private
(unreachable) does a solder mod (remote-sense injection, or OFS if the pin exists) become the fallback.

**Read-only reachability test — RUN 2026-11-19. RESULT: VR is NOT host-reachable → software PMBus path is DEAD.**
Passive discovery on the live host (zero bus writes):
- `i2cdetect -l`: host SMBus = `i2c-0` (i801); i2c-1..14 are all Radeon/GPU DDC buses (display, irrelevant).
- Bound i2c clients on bus 0: only **`0-0052: spd`, `0-0053: spd`** (DIMM SPD/temp EEPROMs) — plus our clock gen at
  0x69 (unbound, read manually). **No VR / no pmbus client anywhere.** No `pmbus`/`isl` module loaded; dmesg has no
  VR hints.
- hwmon: nvme, coretemp, radeon, and **`applesmc-isa-0300`**. CPU VCORE is NOT in any pmbus hwmon; the **SMC** owns the
  management/sensor domain (huge applesmc sensor list) via the ISA interface, not the host SMBus.
→ **Conclusion:** the ISL6367 is on a private bus behind Apple's **SMC**, invisible to the x86 OS. The PMBus
  "overclocking" interface exists on the chip but is not wired anywhere the Proxmox host can reach it. So there is **no
  software undervolt/overvolt path** — confirmed, not just assumed. (A targeted read-only probe of candidate VR
  addresses on bus 0 is possible but unwarranted: the SMC-owns-VR architecture is clear and probing the live SPD/SMC
  segment adds risk for ~no new information.)

**Remaining voltage route = hardware only.** Options, both needing the physical board + the **820-5494-A boardview**
(not obtainable from teardown photos): (1) remote-sense (VSEN/RTN) resistor injection to bias VCORE — finicky on a
differential-sense SVID loop, trip/ brick risk; (2) OFS-pin resistor if the ISL6367 has an analog OFS pin (unconfirmed).
Influencing the SMC firmware to command a VR offset is a dead end (Apple-locked, no documented interface). Net: a CPU
**undervolt** on this machine is a hardware-mod-only proposition; **BCLK remains the one working (software) lever.**

## Open / next
- [ ] Run `macpro-bclk.sh write 101` at a quiet window; measure effective MHz (aperf/TSC), watch for MCE/IO errors.
- [ ] If stable, step to 102/103; find the ceiling where POST/IO/stability breaks.
- [ ] Decide whether to make it persistent (re-apply on boot after the clock resets, or a pre-boot EFI app).
- [ ] (Optional, hardware) price an unlocked E5-1680 v2 (8c, 3.9 GHz, turbo-overclockable) — better for the
      single-thread-bound DayZ main thread than 12c @ 3.0.
- [ ] (Optional, hardware) probe whether the ISL6367 VRM is reachable on any SMBus segment for undervolt.

## Evidence / artifacts
- Firmware dump + analysis tools: project `x99/biostools/` (ucode_scan.py, fit_parse.py, dxe_msr_analyze.py),
  writeup `x99/biostools/FINDINGS.md`. Live MSR/SMBus probes run over SSH (read-only unless noted).
- Datasheets (clock gen / VRM) and PPM disassembly captured during the second-opinion research pass.
