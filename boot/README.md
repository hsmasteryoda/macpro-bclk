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

**Fully-clean alternative (not yet built):** apply the BCLK from an **initramfs pre-mount hook**, before the root
filesystem is mounted read-write — then there are no in-flight FS writes to lose. More robust, but an initramfs
hang is harder to recover. Open an issue / see LAB-NOTES if you want this path.
