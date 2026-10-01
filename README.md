# debian-piano

Debian trixie arm64 GNOME and boot-image builders for Xiaomi Pad 8 Pro (piano / SM8750). Code defaults to MIT; the rootfs DT overlay carries GPL-2.0-only and `mkbootimg/` retains AOSP Apache-2.0. The unlicensed sheng builder is a design reference only; no files are copied.

## GNOME on userdata

From the **workspace root**, with `linux-piano` and `debian-piano` present:

```sh
# Refresh tools: older trees lack libgmp10, needed by dropbear's libtomcrypt.
debian-piano/scripts/fetch-arm64-tools.sh --output-dir out/arm64-tools
scripts/build-rootfs-image.sh --jobs 24
```

The orchestrator requests sudo for debootstrap/chroot and ext4 assembly, not for kernel compilation. Install clang/lld, make, flex, bison, rsync, dtc, Python 3, cpio, kmod, debootstrap, Debian archive keyring, curl, OpenSSH tools, OpenSSL and e2fsprogs. On x86_64, install static qemu-aarch64 and enable its binfmt handler **before** building. On Arch Linux: `pacman -S debootstrap debian-archive-keyring qemu-user-static qemu-user-static-binfmt`, then `systemctl restart systemd-binfmt`. The bootstrap requires a Debian archive signing keyring; for a nonstandard host location, set `DEBIAN_ARCHIVE_KEYRING` explicitly. It does not silently fall back to unauthenticated Release metadata.

Outputs in `debian-piano/out/gnome-image/`:

- `boot.img`: v4, empty external ramdisk, embedded `/pianoinit`.
- `dtbo.img`: `dtbo-piano-rootfs.dts` extends the validated wlanbt overlay with mainline UFS bindings and corrects the simple-framebuffer format to `a8r8g8b8` (ABL scans out XRGB; the old value swapped red and blue).
- `userdata.img`: Android sparse ext4, default expanded size 12 GiB. Only allocated blocks are stored; free space is DONT_CARE (`ext4-to-simg.py`), because ABL writes img2simg-style zero FILL chunks slowly enough to look hung.
- `userdata.raw.img`: equivalent raw ext4 for local inspection (not uploaded by CI).
- `kernel.config`, `packages.txt`, `MANIFEST.txt`: configuration, package versions, source revisions/working-tree diff hashes and artifact hashes.
- `access-key` / `.pub`: generated SSH key unless `--authorized-keys FILE` is provided. Private key mode is 0600; never publish it.
- `rootfs-build/login.txt`: random local password for user `piano` (0600, owned by the bootstrap user/root; read with sudo). No fixed/default password.
- `rootfs/`: assembled tree; the reusable `rootfs-build/rootfs` base stays free of injected firmware and kernel modules.

Use `--output DIR` for a new set, `--image-size 12G` to change the expanded size, or `--rootfs-build DIR` to reuse a completed firmware-free base built by `scripts/build-rootfs.sh`. Reuse only a base built with the current profile; its SSH authorized keys are replaced with those for the new set. `--kernel-only` builds boot/dtbo for smoke verification; it does **not** produce a usable userdata image. Never mix kernel-only output with an unrelated rootfs. The GNOME kernel uses a `-piano-gnome` release suffix, distinct from beacon test kernels. If reusing a base, `login.txt` remains in that base's directory.

### Firmware and compliance

This repository contains **no firmware**; its code licences (MIT / GPL-2.0-only / Apache-2.0) do not extend to any firmware. Device firmware (WLAN, Bluetooth, touch) comes from the separate repository [bluseliu50/piano-firmware](https://github.com/bluseliu50/piano-firmware), whose README carries the compliance statement and per-file provenance: linux-firmware files under their redistribution licences, plus unmodified stock Xiaomi/Qualcomm/Novatek files without a redistribution licence, provided only so device owners can operate their hardware.

- CI and `--firmware-tree DIR` use a piano-firmware checkout (`DIR` = its `firmware/`), verified against its SHA256SUMS.
- Without that option, `stage-piano-firmware.sh` builds the same set from a local extraction in workspace `local/firmware/`; such images must not be published. `--without-firmware` builds an image without any firmware.

Modules and boot Image come from one kernel build, including a regenerated kernel release and a vermagic check for every installed module. SSH private keys never enter git or CI artifacts.

### Desktop and access

GNOME/GDM automatically logs in the ordinary user `piano`. This deliberately exposes the desktop to anyone holding the tablet; sudo requires the generated password. Root has no password login. SSH accepts keys only (root or piano), both in Debian and the early rescue environment. SSH host keys are generated on each installed system's first boot; the ephemeral rescue host key changes on reboot. Verify this distinction when accepting a changed SSH host key.

Preinstalled: Firefox ESR, Terminal, Files, Text Editor, System Monitor, NetworkManager, BlueZ, PipeWire, Chinese-capable fonts, git, Python, curl, rsync, editors, strace, htop, evtest, libinput tools, iw, PCI/USB utilities and Mesa diagnostics. `piano-smoke` reports service/device status; `sudo piano-collect-desktop` collects logs without starting hardware trials. From GNOME Terminal use `glxinfo -B` / `eglinfo -B` to inspect rendering.

There is **no Adreno acceleration** in this profile. Mesa uses llvmpipe; GNOME at 3200x2136 can be slow. Default UI scale is 2, animations disabled. Suspend, lock/idle blanking and idle dimming are disabled because only the bootloader's simpledrm framebuffer is available. Do not restart native DSI/panel drivers or start ADSP: there is no recovery from the resulting black screen without reboot. GNOME rendering and touch calibration still require physical-device acceptance, not merely a successful image build.

### Boot ordering

`linux-piano/arch/arm64/configs/piano_rootfs.config` merges over `piano_defconfig`. The existing beacon test profile stays unchanged. The production forced command line selects `/pianoinit` (Android's appended `/init` must not win), `root=PARTLABEL=userdata rootfstype=ext4 rootwait ro`, keeps clocks/power domains on, disables console blanking and automatic panic reboot, and blocks qcom_q6v5_pas. Native MSM display and PAS are disabled in this profile; simpledrm stays built in.

Before udev exists, the initramfs repairs QUP1/QUP2/PCIe/UFS SMMU stream matches. It enables the UFS clock reference at stock TCSR base 0x0f204008 + the upstream 0x1000 offset, then loads the UFS PHY module closure. As with PCIe, a fixed clock represents that explicitly enabled reference; the legacy USB clock provider is not changed. UFS rails retain ABL's state through always-on regulators. This is bring-up power management, not validated suspend support. It waits at most 90 seconds for the GPT userdata partition, mounts ext4 read-only, checks the installed kernel release/modules, and moves dev/proc/sys/run into the real root before `switch_root /sbin/init`. systemd checks/remounts root and grows ext4 to the partition size through `x-systemd.growfs`.

A missing, corrupt or mismatched rootfs enters key-only USB SSH rescue at 10.42.0.2; no telnet, framebuffer beacon or radio trial runs there. SMMU failure also stops before loading DMA masters. Use the console if USB itself fails. In Debian, separate units initialize NCM, touch/uinput and the radios. Module blacklists prevent udev from racing the ordered initialization, and an `/etc/udev/rules.d/80-drivers.rules` override stops udev autoloading drivers for SoC-bus devices (`of:`, `platform:`, `amba:`, `spmi:`, ...). The stock DT exposes many nodes whose mainline drivers are unvalidated on piano; loading them during coldplug froze the display. USB/HID/input still autoload. PCIe PHY has an install guard; only the radio unit bypasses it after setting the verified 0x0f204008 clkref bit. Bluetooth uses `piano_retries=0 piano_peri=106`.

### Flashing (operator action, destructive)

**Writing userdata erases Android data. Booting Android may reformat userdata and destroy Debian.** Keep a verified full backup and a stock fastboot rescue ROM in `local/rom/`. A-slot boot partitions remain stock, but Android data is not preserved. Do not flash until accepting this tradeoff.

1. Check `fastboot getvar current-slot` and ensure the active slot is **b**. Changing active slot, if needed, is an explicit operator action; recheck.
2. Check `fastboot getvar partition-size:userdata`. It must be at least the **expanded** raw image size (`stat -c%s userdata.raw.img`), not sparse size.
3. Recheck current-slot before **each** write. Write only: `fastboot flash dtbo_b dtbo.img`, then `fastboot flash userdata userdata.img`.
4. Use `fastboot boot boot.img`. Do not write vendor_boot, init_boot, slot A, vbmeta or any bootloader-chain partition. Do not use `fastboot -w`.
5. Set the host's USB NIC to 10.42.0.1/24 (no gateway/DNS required):

   ```sh
   nmcli connection add type ethernet ifname <usb-nic> con-name piano-ncm \
       ipv4.method manual ipv4.addresses 10.42.0.1/24 ipv6.method disabled
   nmcli connection up piano-ncm
   ssh -i debian-piano/out/gnome-image/access-key piano@10.42.0.2
   # Early rescue uses root instead of piano.
   ```

Acceptance: GNOME stays visible; touch clicks the correct screen locations; `sudo piano-smoke` passes; `systemctl --failed` has no unexpected failures; `nmcli device wifi list` sees APs, then use `nmcli --ask device wifi connect SSID`; `bluetoothctl` sees and pairs your device. WiFi association, BT pairing/audio, charging and suspend are not proven by this build. ADSP remains off, so battery telemetry and controlled charging are unavailable; keep sessions supervised. Do not run legacy destructive framebuffer/audio bring-up tests under GNOME.

## Component interfaces and CI

`build-rootfs.sh --suite trixie --output DIR [--authorized-keys FILE]` builds a firmware-free tree with GNOME and device configuration. Optional `--userspace-dir DIR` installs locally built debs through apt; the image build uses it for the piano-sensors packages. `assemble-rootfs-image.sh` copies the pristine base (reflink where possible), adds one matched kernel module tree, optional local firmware and the static touch/BusyBox helpers, then builds/checks raw and sparse ext4. It refuses an already assembled base to prevent stale modules or firmware leaking into CI. `build-initramfs.sh --mode rootfs` requires a key and installs `/pianoinit`; default `--mode test` retains the legacy `/beaconinit` tests. `build-test-bootimg.sh --mode rootfs` shares the proven v4 pack/unpack gate. The generic `build-bootimg.sh` retains its stock-parameter provenance gate.

CI uploads two artifacts from one build: `piano-gnome-flash-<sha>` (`boot.img`, `dtbo.img`, `userdata.img.zst`, kernel configuration, package versions, manifest and checksums) and `piano-gnome-rootfs-<sha>` (the rootfs tarball). The raw ext4 is never uploaded. Decompress before flashing: `zstd -d userdata.img.zst`. Images include the piano-firmware set; the manifest records its revision and points to its compliance statement. The sensors stack comes from [piano-sensors](https://github.com/bluseliu50/piano-sensors): CI builds its runtime packages (adsprpcd, libssc, a patched iio-sensor-proxy, the `piano-sensors` integration package) and installs them into the rootfs; the manifest records its revision. These are versioned Debian packages pinned by `+piano` version, so later updates can come through APT. No sensor data is shipped: the tablet's own sensor configuration (odm) and registry and calibration (persist) are imported read-only on first boot. The AudioReach topology (`qcom/sm8750/Xiaomi Pad 8 Pro-tplg.bin`: speaker playback over the secondary LPAIF TDM port, digital-microphone capture) is compiled from `topology/` by `scripts/build-topology.sh` against a pinned [linux-msm/audioreach-topology](https://github.com/linux-msm/audioreach-topology) macro checkout; the manifest records its revision. Once the ADSP runs, `piano-audio` loads the sound card in order (speaker amplifiers, AudioReach services, VA macro, card); the routing is the UCM profile `Qualcomm/sm8750/Xiaomi-Pad-8-Pro` (alsa-ucm-conf layout). Speaker playback and microphone capture are verified on the device: a stereo stream plays on the top pair of speakers, a four-channel one on all four. The ADSP firmware and the speaker amplifier presets (`fs19xx.fsm`) come with the piano-firmware set.

The keyboard cover (keyboard, touchpad, backlight) sits behind a Nanosic WN8030 MCU on QUP1 SE6, described by `boot/dtbo-piano-keyboard.dts`. After the touchscreen and display units, `piano-keyboard` loads `hid_nanosic_wn8030`, which powers the MCU (L11B 1.8 V, then L14B 3.3 V), downloads its RAM firmware `nanosic/MCU_Upgrade.bin` from the piano-firmware set and registers the `Xiaomi Keyboard` and `Xiaomi Touchpad` HID devices; the backlight is the `nanosic::kbd_backlight` LED (0..100). L14B is voted at 3296 mV: the mainline LDO step rounds the stock 3300 mV up to 3304 mV, and enabling that vote resets the SoC.

CPU frequency scaling goes through the CPUCP firmware over SCMI, as on stock. The stock base describes the SCMI node and the CPU links to its perf protocol; `boot/dtbo-piano-cpufreq.dts` only gives the CPUCP mailbox the mainline compatible, and `qcom_cpucp_mbox` is loaded through modules-load.d. Both clusters then scale with schedutil (cpu0-5: 384 MHz to 3.53 GHz; cpu6-7: 1.02 GHz to 4.09 GHz, with 4.20 and 4.32 GHz as boost levels, off by default: `echo 1 > /sys/devices/system/cpu/cpufreq/boost`). Thermal throttling uses the stock CPU thermal zones, whose passive trips are bound to the cpufreq cooling devices.

Charging stays with the ADSP firmware (float voltage 4350 mV, charge current 3000 mA, JEITA, AICL); the AP only sets the USB input current limit. Left alone the ADSP holds every source at about 0.4 A at 5 V, below the system draw, so `piano-adsp` loads `piano_mca` with `charge_policy=1`: CDP 900 mA; DCP, QC and PD sources 1500 mA, all kept at 5 V and a PD source capped at what it advertises at 5 V; anything else 500 mA, and 500 mA outside a 15-45 °C battery window. `/sys/class/power_supply/piano-mca-usb` reports the charger type, bus voltage/current and limit. It also loads `hv_charge=1`: a PD source with a fixed 9 V PDO is asked for 9 V (battery 15-40 °C; back to 5 V until unplugged if the bus does not settle at 8.0-9.6 V), with the input limit capped at 1500 mA, so 13.5 W at most. And `charge_current=1`: the battery charge current follows the charger type (stock values, capped at 2000 mA, 15-40 °C) instead of the ADSP's ~0.5 A fallback, which otherwise is the limit even with input to spare. `CHARGE_POLICY=0`, `CHARGE_HV=0` or `CHARGE_CURRENT=0` in `/etc/piano/adsp.conf` turn the parts off. PPS, Xiaomi MiPPS and the charge pump are not enabled.

Swap comes in two tiers. First a zram device (zstd, half of RAM up to 8 GB, priority 100), set up by systemd-zram-generator from `/etc/systemd/zram-generator.conf`; the kernel builds zram in. Then a 16 GB `/swapfile` on userdata (priority 10), which `piano-swapfile` creates on first boot, after the root filesystem has grown, and turns on at every boot; `SIZE=` in `/etc/piano/swap.conf` resizes it (delete the file) or `SIZE=0` turns it off. Check both with `swapon --show`.

The arm64 workflow uses `CC="ccache clang"` and a persistent 4 GiB compiler cache, with content-based compiler identity and per-run keys; the cache is saved even when a build fails. The local orchestrator also uses ccache automatically when installed. `workflow_dispatch` accepts `workspace_ref` and `kernel_ref`; the selected umbrella revision must contain the orchestration script and the kernel revision must contain `piano_rootfs.config`. Merge those companion changes before relying on default `main` / `piano-7.2.6` CI refs, or dispatch their feature refs explicitly. No workflow weakens branch protection.

Set repository variable `PIANO_SSH_PUBLIC_KEY` to your public key for operator-accessible CI images. Without it, CI generates and discards an ephemeral private key and marks the bundle **SMOKE ONLY**. Private keys and the random local password are never uploaded. With your public key, use root SSH to set a new `piano` password after boot. GNOME autologin still allows physical desktop access. Shellcheck covers installed runtime helpers; actionlint validates both workflows.

## Status (milestone-boot)

Device-verified: the sparse userdata image flashes through stock fastboot, `/pianoinit` brings up UFS and switches to Debian, and the GNOME session is shown on the simpledrm framebuffer. WiFi association, Bluetooth pairing/audio, touch calibration, charging and suspend still need acceptance on the device.
