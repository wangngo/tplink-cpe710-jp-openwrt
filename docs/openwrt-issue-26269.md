### Describe the bug

The official `tplink_cpe710-v2` factory image is rejected by the stock firmware on the Japanese (JP) variant. The cause is that `tplink-safeloader`'s `CPE710V2` support list only covers UN/EU/US. The same thing happens with the Canadian variant (#20253), and #9388 covers the v1 regional variants.

Device product-info, read from the `info` partition:
`CPE710(TP-LINK|JP|AC866-5|4A500000):2.0`
Stock firmware is `1.0.2 Build 20231226 Rel. 66362 (4A50)`.

The stock JP firmware's own support-list (`soft-info` partition) lists all four regions for the same build:
```
CPE710(TP-LINK|UN|AC866-5|00000000):2.0
CPE710(TP-LINK|EU|AC866-5|45550000):2.0
CPE710(TP-LINK|US|AC866-5|55530000):2.0
CPE710(TP-LINK|JP|AC866-5|4A500000):2.0
```
This suggests the hardware is identical across these regions.

### Tested fix

I added the JP line to `CPE710V2.support_list` in `firmware-utils/src/tplink-safeloader.c`. Then I repacked the 25.12.6 kernel and rootfs with the patched tool. Before that, I checked that repacking with the unpatched tool reproduces the official factory image byte for byte.

The stock web UI accepted the repacked image. The device booted OpenWrt 25.12.6 (r33311-981c978eff). Ethernet, ath10k-ct detection and LuCI all work. The `art` partition and u-boot are unchanged.

```diff
 			"CPE710(TP-LINK|US|AC866-5|55530000):2.0\r\n"
+			"CPE710(TP-LINK|JP|AC866-5|4A500000):2.0\r\n"
 			"CPE710(TP-LINK|UN|AC866-5):2.0\r\n"
```

If the CA owner from #20253 can confirm their `special_id`, the same one-line approach may apply to CA (`43410000`).

### OpenWrt version

25.12.6

### OpenWrt target/subtarget

ath79/generic

### Device

TP-Link CPE710 v2 (JP)

### Image kind

Official downloaded image (rejected); self-repacked image (works)
