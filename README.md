# macpro-bclk

**Runtime BCLK overclocking, benchmarking, and stability testing for the 2013 Mac Pro 6,1 (`MacPro6,1`) running Linux.**

The 2013 "trashcan" Mac Pro's Xeon E5-2697 v2 (Ivy Bridge-EP) is multiplier-locked and, under Apple's locked
firmware, has no exposed CPU overclock, voltage, or turbo controls. This project reverse-engineers the one
overclock lever that *is* reachable from the OS — the base clock (BCLK) — by reprogramming the onboard clock
generator over SMBus, and ships tooling to drive it safely and measure the result.

> ⚠️ **Experimental. Overclocking can crash the machine and, in rare cases, corrupt data or damage hardware.**
> The write path was reverse-engineered and **has now been validated on real hardware** (a 2013 Mac Pro 6,1
> running Proxmox). Use at your own risk, and keep backups of anything the box holds. See **Safety**.

---

## TL;DR — how to overclock your Mac Pro

Validated outcome on real hardware: a **reliable, glitch-free +3 % (BCLK 103 MHz)** that re-applies on every boot.
104 is reachable and stable at speed but the live step to it is flaky (see [Validated results](#validated-results-2026-11-19-on-real-hardware)), so **103 is the recommended ceiling**.

**1. Try it live (one step, reversible — the setting is volatile, a power-off restores 100):**
```bash
sudo apt-get install -y i2c-tools stress-ng
sudo ./macpro-bclk.sh read            # confirm the clock gen (byte9=0x35, byte6=0x13 = 100 MHz)
sudo ./macpro-bclk.sh write 101       # step up 1 MHz — ONLY on an idle box
sudo ./macpro-bclk.sh measure         # confirm it rose; watch for errors
# repeat write 102 / 103; restore with ./macpro-bclk.sh restore (or just power-cycle)
```

**2. Make it stick across reboots (recommended — fsfreeze-protected, crash-loop-guarded):**
```bash
cd boot
sudo sed -i 's/^TARGET=.*/TARGET=103/' macpro-bclk.default   # (103 is already the default)
sudo ./install.sh        # installs + enables the systemd service; applies 103 at every boot
```
That's it. Full detail, safety design, and the kill switch are in [`boot/README.md`](boot/README.md). To undo:
`sudo rm /var/lib/macpro-bclk/enabled` (disable) or `sudo systemctl disable --now macpro-bclk.service`.

> **Why only a live write, never pre-boot?** The cleanest place to set the clock is an initramfs hook before the
> filesystem mounts — that's built (`boot/initramfs/`) but the i801 SMBus isn't reachable that early on this Mac, so
> it fails open and the **systemd service** does the job instead. Details below and in `boot/README.md`.

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

## Validated results (2026-11-19, on real hardware)

Full sweep on an **idle** box (all-core clock = ratio 30 × BCLK):

| BCLK | all-core clock | CPU (stress-ng) | RAM bandwidth | pkg temp | stability | ECC/MCE/IO |
|------|---------------|-----------------|---------------|----------|-----------|------------|
| 100 (stock) | 3000 MHz | 16570 bogo-ops/s | 543.8 | 51 °C | — | 0 |
| 101 | 3030 | +1.6% | +1.0% | 54 °C | PASS | 0 |
| 102 | 3060 | +3.5% | +1.8% | 56 °C | PASS | 0 |
| 103 | 3090 | +5.0% | +2.9% | 58 °C | PASS | 0 |
| **104** | **3120** | **+7.2%** | **+4.0%** | 59 °C | PASS | 0 |

- **RAM bandwidth scales almost exactly with BCLK** (+4.0 % at +4 %) — clean proof the overclock is real.
- **104 MHz is the hard ceiling.** The frequency byte (byte6) is a 3-bit field; the next value (0x18) flips a
  non-frequency control bit and **hangs the box**. The tools refuse anything above 104.
- The CPU showed **zero** instability across the whole range — we ran out of register range, not silicon headroom.
- Temps had huge margin (59 °C peak vs 99 °C crit); RAM (TM0P/TM1P) stayed ~38–40 °C.

> **⚠️ Incident during testing — read this.** Writing BCLK **live while the box was under load** hung it
> instantly, and the resulting **unclean reboots corrupted the root filesystem** (I/O errors across many
> binaries; recovered with a cold power-cycle + fsck, no lasting damage). The *same* frequencies written at
> **idle** were rock-stable. Lessons, now enforced by the tools:
> 1. **Never write BCLK up while the machine is under load.** The tools refuse an up-step when load > ½ the core
>    count (override `BCLK_FORCE=1` only if truly idle).
> 2. **Overclocking a host that boots from its own disk risks your data.** Have backups.
> 3. Watch for **I/O errors**, not just ECC — storage is a BCLK-sensitive failure mode (the stability test
>    now counts them).

### Recommended operating point: 103 MHz (+3 %)

Further testing refined the picture:

- **104 is stable *once running*** — it survived **~25 minutes of full 24-core `stress-ng` with zero errors**. The
  silicon is fine at 104.
- **But reaching 104 via a live step is a coin-flip.** Any 1 MHz step can occasionally wedge the **PLL relock** and
  hang the box (seen at 102→103 on one boot, 103→104 on another). This is *not* a disk-I/O collision — `fsfreeze`ing
  the filesystems during the step (now implemented) **eliminated the I/O glitch** but did **not** stop the hang, so
  the hang is the PLL relock itself, which only pre-boot firmware could fully avoid.
- **The crash-loop guard makes any outcome safe** — a hung step becomes a one-shot reset that lands on a stable,
  glitch-free frequency (102–104) instead of a boot-loop or corruption.

**So the sweet spot is `TARGET=103`:** a reliable, glitch-free **+3 %** that avoids the flaky top step. Set
`TARGET=104` only if you'll tolerate an occasional extra reset per boot before it settles.

## Boot persistence (confirmed working)

BCLK is **volatile** — a cold power-off restores 100 MHz. The [`boot/`](boot/) directory ships a crash-loop-guarded,
**fsfreeze-protected** systemd service that re-applies the overclock at **early boot, before the game containers
start**. Each step freezes the filesystems for the ~1 s PLL relock (tools staged in tmpfs, watchdog backstop) so no
in-flight disk write can be dropped — boots that step the clock now show **zero I/O errors**.

**Clocksource after a stepping boot (found 2026-11-27):** the kernel calibrates the TSC before the service runs, so
on a boot that has to step the clock (after a cold power-off) the TSC then ticks ~2-3 % faster than calibrated. The
kernel's clocksource watchdog catches it ("Marking TSC unstable due to clocksource watchdog") and switches to
**HPET**: time stays correct (chrony fine), but HPET is much slower to read, which costs CPU on clock-heavy workloads
like game servers. **Fix: one warm reboot** — the clock gen keeps its value, the kernel calibrates the TSC at the
overclocked rate (e.g. 2781 MHz at 103) and keeps it, and the service is a no-op. Check:
`cat /sys/devices/system/clocksource/clocksource0/current_clocksource` should say `tsc`.

```bash
cd boot && sudo ./install.sh     # applies TARGET MHz (default 103) on next boot
```

A fully pre-boot path (`boot/initramfs/`) is also built, but the i801 SMBus isn't reachable at `init-premount` on
this Mac (the adapter binds yet block reads return empty — firmware/SMM arbitration), so it **fails open** and the
systemd service does the work. Full design, findings, and the kill switch: [`boot/README.md`](boot/README.md).

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
The GUI has three tabs — **Overclock** (read/step BCLK live, **and manage boot persistence**: enable/disable the
systemd service and set the boot target, with the current state and 103 recommendation shown), **Benchmark**
(CPU/RAM, with a BCLK-tagged results table), **Stability** (PASS/FAIL). Writes and the stability test are each gated
behind a "maintenance window" checkbox and a confirm dialog. So the GUI covers everything: live stepping,
benchmarking, stability validation, and persistent boot-time overclocking.

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
| `boot/` | **Boot persistence.** `install.sh` + `macpro-bclk-apply.sh` (fsfreeze-protected, crash-loop-guarded apply) + `macpro-bclk.service` + `macpro-bclk.default` (`TARGET=`). See [`boot/README.md`](boot/README.md). |
| `boot/initramfs/` | Pre-mount apply hook (built; fails open on this Mac — SMBus unreachable that early). `install-initramfs.sh`. |
| `LAB-NOTES.md` | Full reverse-engineering notebook: MSRs, firmware dump, dead-ends with evidence, the BCLK confirmation, clock-domain decoupling, the live-OC run + incident, boot persistence, initramfs attempt, and the fsfreeze/PLL-hang findings. |
| `docs/ISL6367-datashort.pdf` | VRM controller datasheet (for the undervolt dead-end analysis). |
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
