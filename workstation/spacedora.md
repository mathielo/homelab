# spacedora

Fedora workstation: Intel i7-11700K on an ASUS ROG STRIX B560-F GAMING WIFI, with 4× 8 GB
DDR4 from two Corsair kits.

| Slots            | Kit                  | Model                |
| ---------------- | -------------------- | -------------------- |
| A-DIMM0, B-DIMM0 | Vengeance RGB PRO    | `CMW16GX4M2C3200C16` |
| A-DIMM1, B-DIMM1 | Vengeance RGB PRO SL | `CMH16GX4M2E3200C16` |

## Faulty RAM

One module has a defective region. Memtest86+ fails a ~32 KB window at physical
`0x175ce81d8`–`0x175cefe98` (5.83 GB): every error is single-bit, on bits 58 and 61 only
(`Bits in Error Mask: 2400000000000000`). It is not known which DIMM holds it. On a running
system the faults show up as segfaults across unrelated processes, all with
`si_code=0x80` and `si_addr=0` (a #GP from a non-canonical pointer), plus the occasional
kernel oops.

A kernel parameter marks the page-aligned 64 KB block around the window as reserved, so
the kernel never allocates it:

```
memmap=0x10000%0x175ce0000-1+2
```

`memmap=<size>%<offset>-<oldtype>+<newtype>` changes the range's e820 type from 1 (RAM)
to 2 (reserved).

**Never use the `$` form** (`memmap=0x10000$0x175ce0000`). Both the shell inside
`grub2-mkconfig` and GRUB's BLS parser expand `$0x…` as a variable. That leaves a bare
`memmap=0x10000`, which the kernel reads as "64 KB of usable RAM", and the boot hangs with
no message. Escaping doesn't help, because `grubby` strips the backslash. `GRUB_BADRAM`
doesn't work either: on UEFI the kernel gets its memory map from the firmware, not from
GRUB.

XMP stays **disabled** in the BIOS, so the memory runs at 2133 MT/s. The failing window
was measured at that speed and has not been characterised at 3200 MT/s.

The physical address depends on which slots hold which DIMMs. After moving, adding or
removing a module, derive a new range before relying on this one.

### Applying after a reinstall

1. In the BIOS, confirm that XMP is off. Clearing the CMOS turns it back on.

2. Boot once with the parameter without writing it anywhere. Hold Shift during boot to
   bring up the GRUB menu, press `e` on the entry, append the parameter to the `linux`
   line, then press Ctrl-X.

3. Check that the hole exists:

   ```bash
   journalctl -b -k | grep 'user: \[mem 0x000000017'
   ```

   The output must show the reserved block, with System RAM resuming right after it:

   ```
   user: [mem 0x0000000175ce0000-0x0000000175ceffff]  device reserved
   user: [mem 0x0000000175cf0000-0x000000085fffffff]  System RAM
   ```

4. Append the parameter to `GRUB_CMDLINE_LINUX` in `/etc/default/grub`. That is the
   source `/etc/kernel/cmdline` is regenerated from (kernel-install re-syncs it whenever
   `/etc/default/grub` is newer), and `/etc/kernel/cmdline` is the template for every new
   kernel's BLS entry. Then regenerate it and update the entries that are already
   installed:

   ```bash
   sudo grub2-mkconfig -o /etc/grub2.cfg
   sudo grubby --update-kernel=ALL --args='memmap=0x10000%0x175ce0000-1+2'
   ```

5. Before rebooting, check that both places contain the parameter exactly as written:

   ```bash
   cat /etc/kernel/cmdline
   sudo sh -c "grep '^options' /boot/loader/entries/*.conf"
   ```

A missing parameter fails silently: the system boots and the crashes come back. The
`journalctl` check from step 3 confirms it for any boot, and `journalctl -b -N -k` does the
same for earlier boots. Reading `/proc/iomem` as non-root shows only zeros, so it proves
nothing.

### Recovering from a bad parameter

If the boot hangs right after GRUB, press `e` at the GRUB menu, delete the `memmap=`
argument from the `linux` line, and press Ctrl-X. Once booted, remove it from
`/etc/default/grub`, then run:

```bash
sudo grub2-mkconfig -o /etc/grub2.cfg
sudo grubby --update-kernel=ALL --remove-args=memmap
```

### Deriving a new range

1. Boot Memtest86+ with CPU mode set to `SEQ`. Parallel mode prints so many errors to the
   console that it looks frozen.

2. Set the error report mode to the Linux `memmap` list. Tests 0 and 7 are left out of
   that list because they can't pin an exact address.

3. Memtest86+ writes nothing to disk, so photograph the screen.

4. Round the reported span outward to 64 KB boundaries: the start down to a multiple of
   `0x10000`, and the size up to a multiple of `0x10000`.
