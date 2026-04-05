# Ubuntu 25.10 NUC Autoinstall USB — Design

**Date:** 2026-04-01
**Target:** Intel NUC fleet (identical hardware)
**OS:** Ubuntu 25.10 Server (live-server-amd64)
**Source ISO:** `/Users/stanleyxie/Downloads/ubuntu-25.10-live-server-amd64.iso`
**USB Device:** `/dev/disk4` (15.7 GB)

---

## Goal

Create a single bootable USB drive that installs Ubuntu 25.10 Server on any NUC in the fleet with zero manual input. All NUCs share identical hardware; static IPs are handled via DHCP reservations on the router (by MAC address).

---

## Approach: `dd` + EFI Partition Modification

Write the ISO to USB with `dd`, then mount the EFI/FAT32 partition (natively readable on macOS) and inject autoinstall files + patch grub.cfg.

### Flow

```
macOS Terminal
│
├── 1. diskutil unmountDisk /dev/disk4
├── 2. dd ISO → /dev/rdisk4          (confirm before executing)
├── 3. diskutil mountDisk /dev/disk4
├── 4. Mount EFI partition (FAT32)
│       └── locate /Volumes/<efi>/boot/grub/grub.cfg
├── 5. Patch grub.cfg
│       └── add kernel params: autoinstall ds=nocloud\;s=/cdrom/nocloud/
├── 6. Create /Volumes/<efi>/nocloud/
│       ├── user-data    ← autoinstall YAML
│       └── meta-data    ← empty file (required by cloud-init)
└── 7. diskutil eject /dev/disk4
```

---

## Disk Layout (1TB NVMe — `/dev/nvme0n1`)

| Partition | Size | Mount | Filesystem |
|-----------|------|-------|------------|
| BIOS boot | 1 MB | — | — |
| EFI | 1 GB | `/boot/efi` | FAT32 |
| boot | 1 GB | `/boot` | XFS |
| LVM VG: `ubuntu-vg` | ~997 GB | — | — |
| `lv-root` | 100 GB | `/` | XFS |
| `lv-varlog` | 20 GB | `/var/log` | XFS |
| `lv-docker` | 200 GB | `/var/lib/docker` | XFS |
| `lv-data` | ~677 GB (remainder) | `/data` | XFS |

- No swap partition; 2 GB swapfile at `/swap.img` created via late-command
- `lv-varlog` isolates logs from root to prevent disk exhaustion
- `lv-docker` maps to Docker's default storage path — no extra Docker config needed

---

## autoinstall `user-data`

```yaml
#cloud-config
autoinstall:
  version: 1

  locale: en_US.UTF-8
  keyboard: {layout: us}
  timezone: CET

  identity:
    hostname: nuc
    username: stanley
    password: <sha512-hashed-at-build-time>   # plaintext: never written to disk

  network:
    network:
      version: 2
      ethernets:
        enp3s0:
          dhcp4: true

  storage:
    config:
      # Full explicit LVM config (generated during implementation):
      # nvme0n1 → BIOS + EFI + /boot + ubuntu-vg
      # lv-root 100G XFS /, lv-varlog 20G XFS /var/log,
      # lv-docker 200G XFS /var/lib/docker, lv-data remainder XFS /data

  packages:
    - openssh-server
    - curl
    - wget
    - git
    - htop
    - vim

  package_update: true
  package_upgrade: true

  ssh:
    install-server: true
    allow-pw: true

  late-commands:
    - echo 'stanley ALL=(ALL) NOPASSWD:ALL' > /target/etc/sudoers.d/stanley
    - dd if=/dev/zero of=/target/swap.img bs=1M count=2048
    - chmod 600 /target/swap.img
    - mkswap /target/swap.img
    - echo '/swap.img none swap sw 0 0' >> /target/etc/fstab
```

---

## grub.cfg Patch

Modify the default boot entry on the EFI partition:

```
# Before
linux   /casper/vmlinuz quiet splash ---

# After
linux   /casper/vmlinuz quiet autoinstall ds=nocloud\;s=/cdrom/nocloud/ ---
```

---

## USB File Layout (post-dd)

```
/Volumes/<efi>/
├── boot/grub/grub.cfg     ← patched existing file
└── nocloud/
    ├── user-data          ← autoinstall YAML
    └── meta-data          ← empty file
```

---

## Security Notes

- Password stored as SHA-512 hash (generated via `openssl passwd -6` at build time)
- Plaintext password never written to any file
- `stanley` granted passwordless sudo via sudoers drop-in

---

## Post-Install: Static IPs

Assign fixed IPs per NUC via DHCP reservations on the router, keyed by each NUC's MAC address. The installed OS needs no changes — DHCP lease is always the same IP.
