# Flashing OpenWrt on TP-Link CPE710 v2 (JP / Regional Variants) Without Serial/UART

> **TL;DR:** The official OpenWrt `tplink_cpe710-v2-squashfs-factory.bin` image is rejected by the stock Pharos OS web UI on the **Japanese (`JP`) variant of the TP-Link CPE710 v2** (`"Error: The uploaded file is not accepted by the device"` / hardware not supported).
>
> **Root Cause:** `tplink-safeloader.c` in OpenWrt `firmware-utils` only lists `UN`, `EU`, and `US` in `CPE710V2.support_list`, omitting `CPE710(TP-LINK|JP|AC866-5|4A500000):2.0`—even though the stock JP firmware's own `soft-info` partition lists all four regions (`UN`, `EU`, `US`, `JP`) on identical hardware (QCA956X / AP152, 16MB NOR flash). Reported upstream at [openwrt/openwrt#26269](https://github.com/openwrt/openwrt/issues/26269) (see [`docs/openwrt-issue-26269.md`](docs/openwrt-issue-26269.md)).
>
> This repository provides:
> 1. **`tools/pssh.py` & `tools/pdump.py`**: Python (`paramiko<4`) helpers to SSH into stock Pharos OS (which uses legacy `ssh-dss` DSA host keys rejected by OpenSSH 10+) and back up all 16MB flash partitions (`mtd0..mtd7`, including `mtd7` `ART` RF calibration) before flashing.
> 2. **`patches/safeloader-cpe710v2-jp.patch` & `scripts/repack-cpe710-jp.sh`**: An automated repacker with a **byte-identical round-trip safety gate** that patches `tplink-safeloader` and repacks any official or ASU-customized OpenWrt `factory.bin` so the stock Pharos web UI accepts it directly.
> 3. **`uci-defaults-99-cpe710-site.template`**: Safe first-boot configuration template for remote flashing over an existing LAN without losing connectivity or causing DHCP conflicts.

---

## 1. Hardware & Partition Verification on Stock Pharos OS

### Gotcha: Pharos SSH Uses Legacy `ssh-dss` (DSA-Only) Host Keys
Modern OpenSSH clients (OpenSSH 10.0+) completely removed support for `ssh-dss` (DSA) keys, so standard `ssh admin@192.168.0.254` fails at key exchange. Use `paramiko<4` via [`tools/pssh.py`](tools/pssh.py):

```bash
pip install "paramiko<4"
PHAROS_PW='<your-admin-password>' python3 tools/pssh.py 192.168.0.254 \
  "cat /proc/mtd" \
  "strings /dev/mtdblock4" \
  "strings /dev/mtdblock6"
```

On the **TP-Link CPE710 v2 (JP)** running stock Pharos `1.0.2 Build 20231226 Rel. 66362 (4A50)`:
- **`info` partition (`mtd4`)** contains the hardware product-info string checked during firmware upgrade:
  ```text
  CPE710(TP-LINK|JP|AC866-5|4A500000):2.0
  ```
- **`soft-info` partition (`mtd6`)** inside the stock JP firmware lists all four regions for the exact same firmware binary, confirming identical hardware:
  ```text
  CPE710(TP-LINK|UN|AC866-5|00000000):2.0
  CPE710(TP-LINK|EU|AC866-5|45550000):2.0
  CPE710(TP-LINK|US|AC866-5|55530000):2.0
  CPE710(TP-LINK|JP|AC866-5|4A500000):2.0
  ```

---

## 2. Step 1 — Back Up Full 16MB NOR Flash (`mtd0..mtd7`) Before Flashing

Always dump all 8 MTD partitions (`mtd0` `u-boot` through `mtd7` `art`) over SSH before flashing:

```bash
PHAROS_PW='<your-admin-password>' python3 tools/pdump.py 192.168.0.254 ./backup/stock 8
shasum -a 256 ./backup/stock/mtd*.bin > ./backup/stock/SHA256SUMS
```

> **Important:** `mtd7` (`0x10000` bytes) is the unique factory **ART (Atheros Radio Test)** RF calibration partition. Keep this backup safe offline.

---

## 3. Step 2 — Obtain or Customize the OpenWrt Factory Image

You can start from either:
- The standard official factory image: `openwrt-25.12.6-ath79-generic-tplink_cpe710-v2-squashfs-factory.bin`
- Or a custom image built via the [OpenWrt Firmware Selector](https://firmware-selector.openwrt.org/) / Attended Sysupgrade (ASU) API.

### Gotchas When Building a Custom ASU Image for Remote Flashing
1. **Include `"luci"` explicitly:** If you pass a custom `packages` array to the ASU API, `packages: []` builds a headless image **without LuCI**. Include `"luci"` in `packages`.
2. **Prevent LAN DHCP conflicts & keep the stock IP (`192.168.0.254`):** If the CPE710 is attached to an existing production LAN (`192.168.0.0/24`) and you are flashing it remotely, OpenWrt's default `192.168.1.1/24` + enabled DHCP server will cut off your access or clash with the site router. Embed [`uci-defaults-99-cpe710-site.template`](uci-defaults-99-cpe710-site.template) in the ASU `"defaults"` field so first boot keeps `192.168.0.254/24`, disables DHCPv4/RA/DHCPv6 on LAN, and installs your `ssh-ed25519` public key.

---

## 4. Step 3 — Repack with Byte-Identical Round-Trip Verification

Why a naive repack fails or produces different bytes:
- `tplink-safeloader -x` extracts `file-system` **with** the 4-byte JFFS2 end-of-filesystem marker (`0xdeadc0de`) at the end. When repacking with `-j`, `tplink-safeloader` appends `0xdeadc0de` again, so the trailing 4 bytes must be stripped first (`rootfs.noeof`).
- `tplink-safeloader` embeds `SOURCE_DATE_EPOCH` (stored as a 4-byte BCD date `YYYYMMDD` at offset `12..15` of `soft-version`) and the revision number (`-V r<rev>`, stored as a big-endian `uint32` at offset `16..19` of `soft-version`).

[`scripts/repack-cpe710-jp.sh`](scripts/repack-cpe710-jp.sh) automates the entire process and **refuses to proceed unless the unpatched repack matches the original input image byte-for-byte**:

```bash
./scripts/repack-cpe710-jp.sh \
  openwrt-25.12.6-ath79-generic-tplink_cpe710-v2-squashfs-factory.bin \
  factory-jp.bin
```

Example output:
```text
[*] Extracting partitions from openwrt-25.12.6-ath79-generic-tplink_cpe710-v2-squashfs-factory.bin...
[*] Parsed metadata from soft-version: SOURCE_DATE_EPOCH=1792195200, revision=r33311
[*] Safety gate: verifying byte-identical round-trip with unpatched tplink-safeloader...
[+] Round-trip verification PASSED (100% byte-identical to original).
[*] Building JP-compatible factory image...
[+] Created: factory-jp.bin
[+] Verified support-list inside factory-jp.bin:
SupportList:
CPE710(TP-LINK|UN|AC866-5|00000000):2.0
CPE710(TP-LINK|EU|AC866-5|45550000):2.0
CPE710(TP-LINK|US|AC866-5|55530000):2.0
CPE710(TP-LINK|JP|AC866-5|4A500000):2.0
CPE710(TP-LINK|UN|AC866-5):2.0
CPE710(TP-LINK|EU|AC866-5):2.0
CPE710(TP-LINK|US|AC866-5):2.0
```

---

## 5. Step 4 — Flash via Stock Web UI & U-Boot TFTP Recovery Note

1. Log into the stock Pharos Web UI (`http://192.168.0.254`) → **System > Firmware Upgrade**.
2. Upload `factory-jp.bin` and confirm the upgrade.
3. Wait ~2–3 minutes for the CPE710 v2 to reboot into OpenWrt.
4. Verify post-flash integrity:
   ```bash
   ssh root@192.168.0.254 "cat /etc/openwrt_release; cat /proc/mtd; sha256sum /dev/mtd0 /dev/mtd8"
   ```
   *(On OpenWrt, `u-boot` (`mtd0`) and `art` (`mtd8`/`mtd9`) remain byte-identical to the stock backup).*

### U-Boot TFTP Recovery
If ever needed, the CPE710 v2 bootloader pulls `recovery.bin` (a `factory.bin` image renamed to `recovery.bin`) from a TFTP server at **`192.168.0.100`** when holding the Reset button for 30–40 seconds during PoE power-on.

---

## Tóm tắt Tiếng Việt

1. **Nguyên nhân bản Nhật (`JP`) không nạp được OpenWrt gốc:**
   - Bản **TP-Link CPE710 v2 (JP)** có chuỗi định danh trong phân vùng `info` là `CPE710(TP-LINK|JP|AC866-5|4A500000):2.0`.
   - Công cụ đóng gói `tplink-safeloader.c` của OpenWrt hiện chỉ khai báo `UN/EU/US` cho `CPE710V2` (đã mở issue upstream [openwrt/openwrt#26269](https://github.com/openwrt/openwrt/issues/26269)), dù phân vùng `soft-info` của firmware stock JP xác nhận cả 4 mã vùng `UN/EU/US/JP` dùng chung 1 phần cứng.
2. **Quy trình nạp an toàn từ xa:**
   - **Bước 1 (Backup):** Dùng `tools/pssh.py` và `tools/pdump.py` (`paramiko<4`, vượt lỗi `ssh-dss` trên OpenSSH 10+) để dump toàn bộ `mtd0..mtd7` (16MB NOR, đặc biệt `mtd7 = ART` calibration).
   - **Bước 2 (Repack có cổng kiểm chứng round-trip):** Chạy `./scripts/repack-cpe710-jp.sh <openwrt-factory.bin> factory-jp.bin`. Script tự đọc `SOURCE_DATE_EPOCH` + `-V r<rev>` từ `soft-version`, cắt 4 byte `deadc0de` cuối `file-system`, kiểm tra đóng gói bằng bản chưa patch phải **khớp 100% từng byte (`cmp -s`) với file gốc** rồi mới xuất `factory-jp.bin` có thêm mã vùng `JP`.
   - **Bước 3 (Nạp qua Web UI Pharos):** Upload trực tiếp `factory-jp.bin` trên giao diện web stock Pharos mà không cần bung máy hàn UART.
