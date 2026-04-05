# Ubuntu 25.10 NUC Autoinstall USB — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Produce a single bootable USB drive that installs Ubuntu 25.10 Server on any NUC with zero manual input.

**Architecture:** Write stock ISO to USB with `dd`, then mount the EFI/FAT32 partition on macOS and inject a cloud-init `user-data` autoinstall config + patch `grub.cfg` to trigger unattended install on boot.

**Tech Stack:** macOS Terminal, `dd`, `diskutil`, `openssl` (password hash), Ubuntu 25.10 autoinstall (cloud-init v2)

---

### Task 1: Generate SHA-512 Password Hash

**Files:**
- No files modified — output is used in Task 4

**Step 1: Generate hash**

```bash
openssl passwd -6 'EHXf@n'
```

Expected output: a string starting with `$6$...` — copy this entire string, you will paste it into `user-data` in Task 4.

**Step 2: Verify the hash round-trips**

```bash
python3 -c "import crypt; print(crypt.crypt('EHXf@n', '<paste-hash-here>'))"
```

Expected: outputs the same `$6$...` hash — confirms it is valid.

---

### Task 2: Flash ISO to USB

> **CONFIRM WITH USER BEFORE RUNNING `dd`.** This is destructive and irreversible.

**Step 1: Verify the correct device**

```bash
diskutil list /dev/disk4
```

Expected: shows a ~15.7 GB external disk. Double-check this is the USB, not an internal drive.

**Step 2: Unmount all partitions on the USB**

```bash
diskutil unmountDisk /dev/disk4
```

Expected: `Unmount of all volumes on disk4 was successful`

**Step 3: Flash the ISO (confirm with user first)**

```bash
sudo dd if=/Users/stanleyxie/Downloads/ubuntu-25.10-live-server-amd64.iso \
     of=/dev/rdisk4 bs=1m status=progress
```

Note: `rdisk4` (raw device) is ~3x faster than `disk4` on macOS.
Expected: progress output, then `N bytes transferred` on completion. Takes 3–8 minutes.

**Step 4: Remount the USB**

```bash
diskutil mountDisk /dev/disk4
```

Expected: macOS mounts the partitions; a volume appears on the Desktop or in Finder.

---

### Task 3: Locate and Identify EFI Partition Mount Point

**Step 1: Find where the EFI partition was mounted**

```bash
diskutil list /dev/disk4
```

Note the identifier of the FAT32 partition (likely `disk4s1` or `disk4s2`).

```bash
ls /Volumes/
```

Expected: a volume named something like `Ubuntu-Server 25...` or `EFI` is listed — note the exact name.

**Step 2: Confirm grub.cfg is present**

```bash
find /Volumes -name "grub.cfg" 2>/dev/null
```

Expected: a path like `/Volumes/Ubuntu-Server 25.10 amd64/boot/grub/grub.cfg` — note the exact path for Task 4.

---

### Task 4: Patch grub.cfg

**Files:**
- Modify: `/Volumes/<efi-volume>/boot/grub/grub.cfg`

**Step 1: View the current default boot entry**

```bash
grep -n "linux.*vmlinuz" "/Volumes/<efi-volume>/boot/grub/grub.cfg"
```

Expected: one or more lines like:
```
linux   /casper/vmlinuz  ---
```

**Step 2: Back up grub.cfg before editing**

```bash
cp "/Volumes/<efi-volume>/boot/grub/grub.cfg" \
   "/Volumes/<efi-volume>/boot/grub/grub.cfg.bak"
```

**Step 3: Patch the linux kernel line**

Replace `---` at the end of the first `linux /casper/vmlinuz` line with the autoinstall parameters.
Use the Edit tool to change:

```
linux   /casper/vmlinuz  ---
```

to:

```
linux   /casper/vmlinuz autoinstall ds=nocloud\;s=/cdrom/nocloud/  ---
```

> Note: `\;` escapes the semicolon for grub. The path `/cdrom/nocloud/` refers to the USB root as seen by the live environment — this maps to where we place our files in Task 5.

**Step 4: Verify the patch**

```bash
grep "autoinstall" "/Volumes/<efi-volume>/boot/grub/grub.cfg"
```

Expected: the patched line is present with `autoinstall ds=nocloud\;s=/cdrom/nocloud/`.

---

### Task 5: Create Autoinstall Config Files

**Files:**
- Create: `/Volumes/<efi-volume>/nocloud/meta-data`
- Create: `/Volumes/<efi-volume>/nocloud/user-data`

**Step 1: Create the nocloud directory**

```bash
mkdir -p "/Volumes/<efi-volume>/nocloud"
```

**Step 2: Create meta-data (empty but required)**

Create `/Volumes/<efi-volume>/nocloud/meta-data` with empty content:
```
```
(Empty file — cloud-init requires it to exist.)

**Step 3: Create user-data**

Create `/Volumes/<efi-volume>/nocloud/user-data` with the following content.
Replace `<SHA512-HASH>` with the hash generated in Task 1.

```yaml
#cloud-config
autoinstall:
  version: 1

  locale: en_US.UTF-8
  keyboard:
    layout: us
  timezone: CET

  identity:
    hostname: nuc
    username: stanley
    password: "<SHA512-HASH>"

  network:
    network:
      version: 2
      ethernets:
        enp3s0:
          dhcp4: true

  storage:
    config:
      - id: disk0
        type: disk
        ptable: gpt
        path: /dev/nvme0n1
        wipe: superblock
        preserve: false
        grub_device: false

      - id: bios-boot
        type: partition
        size: 1MB
        device: disk0
        flag: bios_grub
        preserve: false

      - id: efi-part
        type: partition
        size: 1GB
        device: disk0
        flag: boot
        preserve: false

      - id: boot-part
        type: partition
        size: 1GB
        device: disk0
        preserve: false

      - id: lvm-part
        type: partition
        size: -1
        device: disk0
        preserve: false

      - id: ubuntu-vg
        type: lvm_volgroup
        name: ubuntu-vg
        devices: [lvm-part]
        preserve: false

      - id: lv-root
        type: lvm_partition
        name: lv-root
        volgroup: ubuntu-vg
        size: 100G
        preserve: false

      - id: lv-varlog
        type: lvm_partition
        name: lv-varlog
        volgroup: ubuntu-vg
        size: 20G
        preserve: false

      - id: lv-docker
        type: lvm_partition
        name: lv-docker
        volgroup: ubuntu-vg
        size: 200G
        preserve: false

      - id: lv-data
        type: lvm_partition
        name: lv-data
        volgroup: ubuntu-vg
        size: -1
        preserve: false

      - id: efi-format
        type: format
        fstype: fat32
        volume: efi-part
        preserve: false

      - id: boot-format
        type: format
        fstype: xfs
        volume: boot-part
        preserve: false

      - id: root-format
        type: format
        fstype: xfs
        volume: lv-root
        preserve: false

      - id: varlog-format
        type: format
        fstype: xfs
        volume: lv-varlog
        preserve: false

      - id: docker-format
        type: format
        fstype: xfs
        volume: lv-docker
        preserve: false

      - id: data-format
        type: format
        fstype: xfs
        volume: lv-data
        preserve: false

      - id: efi-mount
        type: mount
        device: efi-format
        path: /boot/efi

      - id: boot-mount
        type: mount
        device: boot-format
        path: /boot

      - id: root-mount
        type: mount
        device: root-format
        path: /

      - id: varlog-mount
        type: mount
        device: varlog-format
        path: /var/log

      - id: docker-mount
        type: mount
        device: docker-format
        path: /var/lib/docker

      - id: data-mount
        type: mount
        device: data-format
        path: /data

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
    - chmod 440 /target/etc/sudoers.d/stanley
    - dd if=/dev/zero of=/target/swap.img bs=1M count=2048
    - chmod 600 /target/swap.img
    - mkswap /target/swap.img
    - echo '/swap.img none swap sw 0 0' >> /target/etc/fstab
```

**Step 4: Verify files are in place**

```bash
ls -la "/Volumes/<efi-volume>/nocloud/"
```

Expected:
```
meta-data    (0 bytes)
user-data    (non-zero bytes)
```

---

### Task 6: Eject USB Safely

**Step 1: Eject the USB**

```bash
diskutil eject /dev/disk4
```

Expected: `Disk /dev/disk4 ejected`

The USB is now ready. Plug into any NUC, boot from USB (F10 or F2 for boot menu on most NUCs), and the install runs fully automated.

---

## Post-Install Checklist

After the NUC reboots into the installed system:

- [ ] SSH in: `ssh stanley@<dhcp-ip>`
- [ ] Confirm LVM layout: `sudo lvs` and `df -hT`
- [ ] Confirm XFS on all mounts: `df -Th | grep xfs`
- [ ] Confirm `/data` and `/var/lib/docker` mounts exist
- [ ] Set DHCP reservation on router for this NUC's MAC address
- [ ] Repeat for remaining NUCs

---

## Notes

- **Re-flashing:** To reuse the USB for another NUC, just eject and replug — no changes needed, config is identical for all NUCs.
- **Hostname uniqueness:** All NUCs install as hostname `nuc`. Rename post-install with `hostnamectl set-hostname nuc-01` etc., or add a late-command using the MAC address to set a unique hostname.
- **grub.cfg path may vary:** Ubuntu 25.10 may place grub.cfg at a slightly different path. Task 3 Step 2 (`find`) handles discovery.
