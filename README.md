# macpro-bclk

**Runtime BCLK overclocking, benchmarking, and stability testing for the 2013 Mac Pro 6,1 (`MacPro6,1`) running Linux.**

The 2013 "trashcan" Mac Pro's Xeon E5-2697 v2 (Ivy Bridge-EP) is multiplier-locked and, under Apple's locked
firmware, has no exposed CPU overclock, voltage, or turbo controls. This project reverse-engineers the one
overclock lever that *is* reachable from the OS — the base clock (BCLK) — by reprogramming the onboard clock
generator over SMBus, and ships tooling to drive it safely and measure the result.

> ⚠️ **Experimental. Overclocking can crash the machine and, in rare cases, corrupt data or damage hardware.**
> The write path was reverse-engineered and is guarded, but had not been validated on real hardware at first
> release. Use at your own risk, ideally not on a box anyone depends on. See **Safety**.

---

## What it does

- **Reads and steps the base clock** by reprogramming the clock generator (ICS **932SQL435AL**, CK420BQ family)
  on the PCH SMBus (i801) at address **0x69**. Confirmed live: a block read returns
  `ff fe 8f 14 03 00 13 01 0a 35` → device id `0x35` ("435"), vendor nibble `1` (ICS/IDT), frequency byte
  `0x13` = bits[2:0] `011` = **100 MHz** (stock). Raising those three bits steps BCLK in ~1 MHz increments.
- **CPU and RAM benchmarks** (via `stress-ng`) so you can measure the *real* gain of each step, with a results
  table tagged by the BCLK it ran at (before/after comparison).
- **A stability tester** — full-load `stress-ng --verify` plus EDAC/MCE hardware-error counting — that returns a
  clear **PASS/FAIL**. This is what proves a given BCLK is safe to keep.

Two front-ends, same logic:
- `macpro-bclk.sh` — CLI (`read` / `measure` / `write <MHz>` / `restore`).
- `macpro-bclk-gui.py` — a dependency-free local **web GUI** (Python stdlib only). Runs on the Mac Pro; open it
  from a browser on **any** OS — macOS, Linux, a phone. (A *native* macOS app would need a signed SMBus
  kext/DriverKit driver, which SIP blocks — out of scope; the web GUI is the portable answer.)

---

## How BCLK behaves on this machine (important)

BCLK is a shared reference, but the domains are **not** all coupled the same way:

| Domain | Scales with BCLK? | Notes |
|---|---|---|
| **CPU cores** | **Yes** (the point) | `f_core = fused_ratio × BCLK`. The multiplier is locked, so BCLK is the only lever. |
| **RAM** | **Yes — cannot be decoupled** | The memory controller is **on-die**, clocked from the same host clock. +6% BCLK ≈ DDR3-1866→~1980. ECC *corrects and reports*, so the stability tester catches it. **RAM is the real ceiling.** |
| **PCIe / DMI / SATA / USB / TB** | **Likely no** | CK420-family clock gens keep the PCIe **SRC** outputs on a separate ~100 MHz domain from the CPU host clock (this is why Sandy/Ivy "BCLK strap" OC works). Verify after a step with `lspci -vv` / `smartctl` / `journalctl -k`. |

You **cannot** "spoof" a higher CPU clock while RAM stays put — the core PLL multiplies the *physical* clock, and
the ratio is fused. The honest ceiling is set by **RAM stability**, with IO probably along for a free ride.
Full reasoning in [`LAB-NOTES.md`](LAB-NOTES.md).

---

## Quickstart

On the Mac Pro / Linux host, as root:

```bash
apt-get install -y i2c-tools stress-ng
# optional, for accurate effective-MHz readout:
apt-get install -y linux-cpupower        # provides turbostat
```

### Web GUI (recommended)
```bash
# read-only (safe): serve the UI, benchmarks + stability work, BCLK writes disabled
python3 macpro-bclk-gui.py

# to enable BCLK writes (needs root for SMBus); still arm each write in the UI:
sudo python3 macpro-bclk-gui.py --allow-write

# from another computer, tunnel it (keeps it off the network):
ssh -L 8099:localhost:8099 root@<macpro-ip>
# then open http://localhost:8099
```
The GUI has three tabs — **Overclock** (read/step BCLK), **Benchmark** (CPU/RAM, with a BCLK-tagged results
table), **Stability** (PASS/FAIL). Writes and the stability test are each gated behind a "maintenance window"
checkbox and a confirm dialog.

### CLI
```bash
./macpro-bclk.sh read          # dump + decode the clock gen (confirm byte9=0x35, byte6=0x13)
./macpro-bclk.sh measure       # baseline effective MHz

# at a quiet window, able to power-cycle:
./macpro-bclk.sh write 101     # BCLK 100 -> 101 MHz (one step)
./macpro-bclk.sh measure       # confirm ~1% higher
./macpro-bclk.sh restore       # back to 100 MHz (or just power-cycle)
```

---

## Safety

- **Reads are harmless. Writes are live and risky.** A PLL step at runtime can **hang the box instantly**. The
  setting is **volatile** — a full power-off restores 100 MHz, so recovery from a hang is a power cycle.
- **Step 1 MHz at a time** and run the **stability test** after each step. Locked v2 Xeons typically top out around
  **106–112 MHz** BCLK before something breaks; the realistic CPU gain is a few percent.
- **RAM is the limiter.** Watch the stability tester's EDAC/MCE counters — new ECC errors mean back off a step.
- **Benchmarks and the stability test peg the machine to 100%.** On a server with users, that means lag. Run them
  in a maintenance window.
- Writing live also **skews the TSC/timekeeping** while the kernel runs. A persistent, clean OC would be done
  **pre-boot via an EFI app** (not built here) — this project is for finding and validating the ceiling.
- **This does _not_ undervolt** and **does _not_ change the multiplier/turbo table** — both are architecturally
  blocked on Ivy Bridge-EP (no OC mailbox / fused OC-lock). The only hardware path to undervolt is a VRM
  feedback/VID mod on the board's ISL6367 — documented, not implemented, in `LAB-NOTES.md`.

---

## Files

| File | What |
|---|---|
| `macpro-bclk-gui.py` | Local web GUI: BCLK read/step + CPU/RAM benchmarks + stability tester. Python stdlib only. |
| `macpro-bclk.sh` | CLI for the same BCLK read/step. |
| `LAB-NOTES.md` | Full reverse-engineering notebook: MSRs, firmware dump, dead-ends with evidence, the BCLK confirmation, clock-domain decoupling analysis, hardware-mod notes. |
| `bclk-stock-block.txt` | Auto-saved stock clock-gen register block (created on first write). *gitignored.* |
| `bench-results.json` | Benchmark/stability history. *gitignored.* |

## Background / provenance

Found by dumping the Mac Pro's BIOS (`flashrom`, Macronix MX25L6405 8 MB) and analyzing its firmware alongside
live MSR probing over SSH. Undervolt and turbo-override were ruled out with evidence (no OC mailbox on IVB-EP;
`#GP` on MSR `0x150/0x620/0x690`; `PLATFORM_INFO[28]=0` fused OC-lock; the PCU PCU mailbox has no VID command —
`MAILBOX_BIOS_CMD_VR_INTERFACE` is "new in Haswell"). BCLK via the clock generator is the one surviving,
confirmed lever. Details and the full dead-end trail are in `LAB-NOTES.md`.

## License

MIT — see [`LICENSE`](LICENSE). Provided as-is, with no warranty; overclocking is entirely at your own risk.
