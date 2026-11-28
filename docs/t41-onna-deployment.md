# T41NQ Live Deployment & Firmware Optimization Notes (`yoloxn3-v1` + `ONNA=1`)

Field test results, reproducible cross-build instructions, and firmware optimization findings from
deploying [`model-yoloxn3-v1`](https://github.com/Small6oy/thingino-ai/releases/tag/model-yoloxn3-v1)
(`yoloxn3-v1_t41.bin`, md5 `dce54bddabe5910c7c234eea5944d3bf`, 3-class `person / pet / vehicle`
YOLOX-Nano distilled from YOLOX-M) via Thingino Raptor `rvd` with the open T41 NNA backend
(`ONNA=1`, `Small6oy/raptor-hal` `onna-backend` @ `7f3443e` + `Small6oy/raptor` `ivs-detect-frames`
@ `2d2b337`) on two production Ingenic **T41NQ** camera boards:

- **Noorio T110** (T41NQ, GC4023, AIC8800 USB, Thingino `2026-11-16` base)
- **Wyze Cam v4** (T41NQ, OS04D10, ATBM6062S SDIO, Thingino `2026-10-20` base)

Both cameras ran 24/7 `2560x1440 @ 15 fps` (H.264 main) + `640x360 @ 15 fps` (H.264 sub) RTSP
streams simultaneously while running `yoloxn3-v1_t41.bin` at `1 Hz` (`detect_interval_ms = 1000`) on
the T41 NNA with **no `libvenus.so`, no `libjzdl`, no `libstdc++`, no `nmem`, and no L2 split change**.

---

## 1. Live Silicon Results (`yoloxn3-v1_t41.bin` @ 1 Hz in `rvd`)

| Metric | Noorio T110 (T41NQ, GC4023) | Wyze Cam v4 (T41NQ, OS04D10) |
|---|---|---|
| `rvd` binary (`ONNA=1`, stripped) | `255 KB` (`ld-uClibc-mipsn8.so.0`, 0 new `.so` deps) | `255 KB` (`ld-uClibc-mipsn8.so.0`, 0 new `.so` deps) |
| **`ONNA: mean of 100` — NV12 resize (MXU3)** | **3.3–3.4 ms** | **3.6–3.7 ms** |
| **`ONNA: mean of 100` — NNA network (PR #82 fused)** | **55.0–55.6 ms** | **53.9–54.6 ms** |
| **`ONNA: mean of 100` — decode** | **0.2 ms** | **0.2–0.3 ms** |
| **Total inference time / frame** | **58.6–59.0 ms** | **57.8–58.6 ms** |
| **`rvd` CPU (5s `/proc/stat` delta at 1 Hz)** | **8.4 % of 1 core** (4.2 % SoC, 91.7 % SoC idle) | **9.9 % of 1 core** (4.9 % SoC, 85.4 % SoC idle) |
| **`rvd` RSS (flat over 400+ frames)** | **`13.2 MiB`** (`13,548 kB`) | **`13.0 MiB`** (`13,344 kB`) |
| **Core-0 deadlock mitigation (`isp_fw_process`)** | Verified pinned to `CPU0` | Verified pinned to `CPU0` |
| **Linux RAM available (`MemAvailable`)** | `53.2 MiB` (of `87.3 MB`) | `25.6 MiB` (of `60.4 MB`) |
| **IMP `rmem` (`continuous_mem_info`)** | `27.85 / 29.00 MiB` (`96%`, fell back to `nr_vbs=1`) | `33.13 / 64.00 MiB` (`51%`, `30.87 MiB` unused) |
| **RTSP `ch0` (`2560x1440 @ 15 fps`)** | Verified live, 0 frame drops after channel rebuild | Verified live, `nr_vbs=2`, 0 frame drops |
| **Live walk-test** | 0 false positives over 400+ static frames; fired immediately on person walk-past (`rmd` triggered) | Live detections active immediately after start |

The MXU3 NV12 resize (`tools/ojzdl` PR #73) cut resize from ~9.5–21 ms down to **3.3–3.7 ms**, and
PR #82's folded 1x1-after-add + concat-deconv passes brought YOLOX-Nano T41 network time down from
~67–75 ms to **53.9–55.6 ms** on real T41NQ silicon.

---

## 2. Reproducible Cross-Build & Reversible Camera Deploy

Use [scripts/build-t41-rvd-onna.sh](../scripts/build-t41-rvd-onna.sh) on an `aarch64` or `x86_64`
Linux host:

```sh
# Pull the target camera's shared libs for exact symbol verification (optional):
mkdir -p /tmp/cam-syslib
ssh root@<camera-ip> 'tar -cf - -C / lib/librss_common.so lib/librss_ipc.so usr/lib/libimp.so usr/lib/libalog.so' \
  | tar -xf - -C /tmp/cam-syslib

SYSLIB_DIR=/tmp/cam-syslib scripts/build-t41-rvd-onna.sh /tmp/t41-rvd-onna-build
```

Download `yoloxn3-v1_t41.bin` and `yoloxn3-v1.conf` from
[`model-yoloxn3-v1`](https://github.com/Small6oy/thingino-ai/releases/tag/model-yoloxn3-v1), place
them in `/usr/share/models/` (with a matching `<stem>.conf` symlink/copy `yoloxn3-v1_t41.conf` for
sidecar lookup), and test reversibly with a bind-mount before persisting to `/overlay`:

```sh
# On the camera (reversible test — reboot restores /rom/usr/bin/rvd):
cp -a /etc/raptor.conf /tmp/raptor.conf.bak
mount --bind /tmp/rvd-onna /usr/bin/rvd
/etc/init.d/S31raptor restart

# Verify ONNA, ISP core-0 pinning, and live detections:
logread | grep -E 'ONNA:|JZDL'
raptorctl rvd ivs-status
raptorctl rvd ivs-detections
```

Recommended `[motion]` block in `/etc/raptor.conf` (when `[recording] enabled = false`):

```ini
[motion]
enabled = true
record = false
algorithm = yolo
model = /usr/share/models/yoloxn3-v1_t41.bin
num_classes = 3
conf_threshold = 40
class_thresholds = 40,30,40
nms_threshold = 45
detect_interval_ms = 1000
```

Once verified, unmount `/usr/bin/rvd` and copy `rvd-onna` to `/usr/bin/rvd` (writes to `/overlay`,
leaving `/rom/usr/bin/rvd` intact for rollback).

---

## 3. Code & Firmware Optimization Sweep (T41NQ Findings)

A read-only audit of both running T41NQ cameras against latest upstream (`2026-11-28`) surfaced
several high-impact optimizations and bugs worth addressing upstream and in future firmware builds:

### A. `raptor-hal` / `raptor` Detection Pipeline
1. **`hal_ivs_onna.c` per-class `class_thresholds` (`Small6oy/raptor-hal` `onna-backend` `7f3443e` — FIXED & VERIFIED)**:
   - Upstream `hal_ivs_onna.c` still ran its pre-#26 scalar `head_decode(..., c->conf_thresh)` instead
     of the shared `hal_yolo_t` decoder from `gtxaspec/raptor-hal#26`, silently dropping `pet`
     detections in `[0.30, 0.40)` under `conf_threshold = 40` / `class_thresholds = 40,30,40`.
   - **Applied fix ([scripts/patches/hal_ivs_onna-hal_yolo.patch](../scripts/patches/hal_ivs_onna-hal_yolo.patch)):**
     Wired `hal_ivs_onna.c` to `hal_yolo_init` / `hal_yolo_begin` / `hal_yolo_decode_head` /
     `hal_yolo_finish` / `hal_yolo_emit` (preserving `.qgraph` anchor fallback via `onnaq_anchors`),
     removing ~150 duplicate lines and per-frame `realloc`s, passing all 36 `raptor-hal` ASan unit
     tests, and verified live on both T41NQ boards (`58.9 ms` mean, `13.0–13.1 MiB` `rvd` RSS;
     reported upstream on [`gtxaspec/raptor-hal#25`](https://github.com/gtxaspec/raptor-hal/pull/25#issuecomment-7235619439)).
2. **`rvd` standalone `yolo` `rmem` savings (`rvd_ivs.c`, `rvd_pipeline.c`)**:
   - Even when `algorithm = yolo` (standalone FrameSource read, never using IMP IVS), `rvd_ivs_init()`
     still creates and binds IMP IVS Group 0 to `stream1`. Skipping IVS group creation/bind in
     standalone mode avoids an extra bind hop and saves `rmem`.
3. **Sidecar naming & `rmd` default (VERIFIED LIVE)**:
   - `docs/model-conf.md` looks up `<stem>.conf` (`yoloxn3-v1_t41.conf`) or `<file>.conf`
     (`yoloxn3-v1_t41.bin.conf`) next to the `.bin`.
   - `rmd_main.c` defaults `[motion] record = true` even when `[recording] enabled = false`, logging
     `recording start/stop command failed (RMR not running?)` on every detection; adding
     `record = false` under `[motion]` silences these warnings cleanly.

### B. T41NQ Bootargs Memory Split (`mem` / `rmem` / `nmem`) & Upstream Firmware Upgrade (`master+6666647`)
Measured IMP `rmem` usage for `2560x1440` + `640x360` + 2 JPEG channels at `nr_vbs=2` is **`33.13 MiB`**,
and `ONNA` uses **0 bytes of `nmem`**:

- **Noorio T110 (`mem=91M rmem=29M nmem=8M` → `mem=84M@0x0 rmem=44M@0x5400000`, `0M nmem` — VERIFIED LIVE)**:
  Upgraded to `themactep/thingino-firmware` `master+6666647` (`2026-11-28`) with `ONNA=1` +
  `hal_yolo_t` + `raptor` `6902893` baked natively into `/rom/usr/bin/rvd`:
  - Eliminated the `IMP_FrameSource_EnableChn(0)` allocation failure and 6-second boot stall (`nr_vbs=2` starts cleanly on boot with ~11 MiB `rmem` headroom).
  - Reclaimed 8 MiB of unused `nmem`; Linux reports `47.8 MiB` available RAM (`80.1 MiB` total).
  - Active upstream `wifi-aic8800` `ps_on=N` (`#2248`), `ric` `trigger = luma` (`#2242`, zero IR-cut clicking), and `rvd` `ONNA=1` (`58.9 ms` mean, `13.0 MiB` RSS) running directly from `/rom`.
- **Wyze Cam v4 (`mem=64M rmem=64M` → `mem=84M@0x0 rmem=44M@0x5400000`)**:
  Reclaims `20 MiB` from idle `rmem` (`30.87 MiB` previously unused) back to Linux (`+20 MiB` RAM)
  while keeping `~11 MiB` free `rmem` headroom above the `33.13 MiB` `nr_vbs=2` peak.
  > **CRITICAL Wyze Cam v4 OTA Upgrade Note (`#2067` / `9db4191`):** When upgrading a Wyze Cam v4
  > from pre-`2026-11-19` Thingino firmware via kernel+rootfs OTA while preserving `/overlay`,
  > **delete `"wlan": 78` from `/overlay/etc/thingino.json` BEFORE rebooting**. Newer `S36wireless`
  > applies `gpio.wlan` on 4.4 kernels as well, and driving GPIO 78 as an output disables the
  > ATBM6062S Wi-Fi radio until `/overlay/etc/thingino.json` is cleared or updated to match
  > `/rom/etc/thingino.json` (which drops `"wlan": 78`). Also include `gtxaspec/raptor-hal#17` if
  > runtime Gen3 `set-sinter` / `set-temper` NR tuning is used.

### C. High-Value Upstream Firmware & Raptor Upgrades (`2026-10-20` / `2026-11-16` → `2026-11-28`)
- **`themactep/thingino-firmware`**:
  - `677ae9a` (`#2248`): `wifi-aic8800` `ps_on=N uapsd_queues=0` (prevents AIC8800 USB RX drops and
    AP deauths on Noorio T110).
  - `bd49939` & `600ebf0` (`#2242`): `trigger = luma` IR-cut defaults on Noorio T110 and Wyze Cam v4
    (avoids reflected-IR `DAY <-> NIGHT` filter clicking under `trigger = photo`).
  - `13043bb` (`#2295`), `3d98954` (`#2294`), `8e44e03` (`#2297`): bound `thingino-agent` and
    `uhttpd` CGI memory spikes on 64 MB RAM profiles.
- **`gtxaspec/raptor` (`01588df` + open PRs)**:
  - `S31raptor` daemon watchdog + `oom_score_adj = -500` on `rvd`/`rmr` (`33482cc`, `864fdc2`,
    `987b7f5`, `36c50d7`).
  - `rsd` / `rhd` / `rwd` 24/7 stream hardening (`5a1e433`, `49d81f3`, `ec67758`, `075facb`,
    `b61a23e`, `a1c0c82`, `266ea77`).
  - `ric` zero-gain under IR fixes (`#94` `eb748d9`, `#102` `83e46f6`, `050c7e2`) and `rvd` PRs
    `#96` (`detect_interval_ms`), `#104` (`JZDL_LIBS=`), `#105` (no CPU spin if model load fails),
    `#106` (OSD detection boxes), `#108` (`save raw` + ONNA race fix), `#113` (`S31raptor` hooks).
- **`gtxaspec/raptor-hal` (`6cf27fc` + open PRs)**:
  - `4b23b72` + `b117377` + `ebb6571`: preserve runtime ISP tuning across `ric` day/night switches.
  - `#22` / `#26` / `#25` (`ojzdl` + shared YOLO decode + `onna`), `#20` (Gen3 linear `total_gain`),
    `#17` (Gen3 `sinter`/`temper` NR controls).
- **`gtxaspec/raptor-ipc` & `raptor-common`**:
  - `raptor-ipc` `6dd61c7`, `304c724` (SHM bounds & `0600` sockets); `raptor-common` `27c4270`,
    `cd3f207`, `3eab513` (per-connection TLS deadlines).
