# Boot persistence

The BCLK setting is **volatile** — a full power-off restores 100 MHz. This service re-applies the overclock at
every boot, **at early boot before the game containers start** (ordered `Before=pve-guests.service`), which is the
only reasonably-idle moment for a live clock write.

```bash
sudo ./install.sh          # install + enable; applies on next boot
# edit the target (100..104). TARGET=103 is the recommended reliable ceiling on this box (see below):
sudo sed -i 's/^TARGET=.*/TARGET=103/' /etc/default/macpro-bclk
```

**Files:** `macpro-bclk-apply.sh` → `/usr/local/sbin/`, `macpro-bclk.service` → `/etc/systemd/system/`,
`macpro-bclk.default` → `/etc/default/macpro-bclk`, state in `/var/lib/macpro-bclk/`, log in `/var/log/macpro-bclk.log`.

## Safety design
- **Crash-loop guard.** Before stepping, the script writes `attempting` to `/var/lib/macpro-bclk/last-attempt`
  and `sync`s. If a boot ever hangs mid-step, the marker survives the reboot and the **next boot SKIPS** applying
  (so a bad step can never boot-loop the machine). Re-arm with `echo ready > /var/lib/macpro-bclk/last-attempt`.
- **Steps 1 MHz at a time** with a 1 s settle, device-id checked (`byte9==0x35`), target clamped 100–104.
- **fsfreeze glitch protection (implemented).** Each step runs `sync` → `fsfreeze -f` on every rw ext4/xfs mount →
  the `i2cset` relock → settle → `fsfreeze -u`, so there is **no in-flight disk write for the PLL relock to drop**.
  Because `fsfreeze` and its libraries live on the frozen filesystems, all frozen-window tools (`fsfreeze`,
  `i2cset`, `sleep` + libs + loader) are staged into **tmpfs** (`/dev/shm`) and run from there, with a tmpfs
  **watchdog** that force-unfreezes after 15 s if anything stalls, plus a trap that unfreezes on any exit. Validated
  on real hardware: freeze ~40–65 ms, unfreeze ~3–5 ms, and the boot that used it showed **zero I/O errors**.
- **Easy kill switch:** `rm /var/lib/macpro-bclk/enabled` disables it without touching systemd.

## What's clean, and what isn't — the step-hang is the PLL, not disk I/O
Validated 2026-11-19 across several boots:

- **The I/O glitch is solved.** Before fsfreeze, a step dropped an in-flight write (`Buffer I/O error on sda1 ...
  lost sync page write` / `JBD2 ... journal superblock`). With fsfreeze, boots that step the clock show **0 I/O
  errors** and the filesystems stay clean. No corruption risk.
- **But the live step is still probabilistically flaky.** fsfreeze did **not** stop the box from occasionally
  hanging on a step (it hit 102→103 on one boot, 103→104 on another) — so the hang is the **PLL relock itself
  wedging**, not an FS-I/O collision. Only pre-boot firmware could fully quiesce that, and the SMBus isn't
  reachable pre-mount here (see below).
- **It's safe regardless.** The crash-loop guard turns any hang into a one-shot reset that lands on a stable,
  glitch-free frequency (102–104) instead of a boot-loop or a corruption. **104 is stable once running** (survived
  25 min of full 24-core stress), but reaching it live is a ~coin-flip on the top step.
- **Recommendation: `TARGET=103`** — a reliable, glitch-free **+3 %** that avoids the flaky top step (and is a
  clean no-op on a warm reboot, since the clock is preserved). Set `TARGET=104` only if you'll accept an occasional
  extra hang-reset per boot before it settles.

## initramfs pre-mount attempt — built, but blocked by hardware on this Mac

The fully-clean idea is to apply the BCLK from an **initramfs pre-mount hook**, before the root filesystem is
mounted read-write, so there are no in-flight FS writes for the PLL relock to drop. That hook is built and shipped
in [`initramfs/`](initramfs/) (`hook-macpro-bclk`, `premount-macpro-bclk`, `install-initramfs.sh`), and it installs
and runs correctly — but on the 2013 Mac Pro **it cannot actually program the clock that early**:

> Tested across three boots (2026-11-19). At `init-premount` the i801 SMBus adapter **is** present and correctly
> detected as bus 0, but every block read of the clock generator returns **empty** — tried with bus auto-detect by
> name, 6× retries with settle, and `i2c_i801 disable_features=0x10` (polling mode, since IRQs aren't wired up
> that early). The controller binds but its host transactions don't complete until later in OS boot (firmware/SMM
> SMBus arbitration; ACPI is already up before initramfs, so it isn't an ACPI-timing issue).

The hook is **fail-open**: on any read failure it logs to the kernel ring and boots stock, so it never hangs the
boot and never leaves the box in a bad state. It is safe to leave installed (useful if a future kernel/firmware
makes early SMBus access work). Escape hatch regardless: add `bclk=off` to the kernel cmdline at the GRUB edit
screen.

**Net on this machine:** the initramfs hook fails open → the **systemd service** (above) remains the working
method. The glitch it used to produce is now eliminated by the fsfreeze protection in the apply script (see
"Safety design"); the only residual is the occasional PLL-relock hang on the top step, which the crash-loop guard
handles safely. `TARGET=103` sidesteps it for a clean, reliable, glitch-free overclock.
