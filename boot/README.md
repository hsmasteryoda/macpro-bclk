# Boot persistence

The BCLK setting is **volatile** — a full power-off restores 100 MHz. This service re-applies the overclock at
every boot, **at early boot before the game containers start** (ordered `Before=pve-guests.service`), which is the
only reasonably-idle moment for a live clock write.

```bash
sudo ./install.sh          # install + enable; applies on next boot
# edit the target (100..104):
sudo sed -i 's/^TARGET=.*/TARGET=104/' /etc/default/macpro-bclk
```

**Files:** `macpro-bclk-apply.sh` → `/usr/local/sbin/`, `macpro-bclk.service` → `/etc/systemd/system/`,
`macpro-bclk.default` → `/etc/default/macpro-bclk`, state in `/var/lib/macpro-bclk/`, log in `/var/log/macpro-bclk.log`.

## Safety design
- **Crash-loop guard.** Before stepping, the script writes `attempting` to `/var/lib/macpro-bclk/last-attempt`
  and `sync`s. If a boot ever hangs mid-step, the marker survives the reboot and the **next boot SKIPS** applying
  (so a bad step can never boot-loop the machine). Re-arm with `echo ready > /var/lib/macpro-bclk/last-attempt`.
- **Steps 1 MHz at a time** with a 1 s settle, device-id checked (`byte9==0x35`), target clamped 100–104.
- **Easy kill switch:** `rm /var/lib/macpro-bclk/enabled` disables it without touching systemd.

## Known limitation — a live step can still glitch a disk write
Validated 2026-11-19: applying 104 at boot worked and the box is stable, **but the step moment produced two
transient I/O errors** (`Buffer I/O error on sda1 ... lost sync page write` / `JBD2 ... journal superblock`) as the
PLL relock dropped an in-flight write. It recovered cleanly (FS stayed rw, mounted clean, no accumulation), but it
is the same mechanism that corrupted the FS when a step was done **under load**. A live step is never perfectly
clean on this machine.

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
method, and it is the one that applies 104 MHz each boot (with the one benign, recovered I/O glitch noted above).
To actually eliminate that glitch within the systemd path, the next idea is to `fsfreeze` the mounted
filesystems for the ~1 s of the step (flush + block writes so none can be dropped) — not yet implemented.
