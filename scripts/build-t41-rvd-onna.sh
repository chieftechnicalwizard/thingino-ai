#!/usr/bin/env bash
# Reproducible cross-build of Thingino Raptor `rvd` for Ingenic T41 (XBurst2, uClibc GCC 16)
# with the open T41 NNA backend (`ONNA=1`), shared YOLO decode, MXU3 NV12 resize, and
# per-class thresholds (`class_thresholds`), linking zero proprietary NNA/JZDL/libstdc++ libs.
#
# Usage:
#   scripts/build-t41-rvd-onna.sh [BUILD_DIR]
#
# Optional environment overrides:
#   HOST_ARCH       aarch64 or x86_64 (auto-detected from uname -m)
#   SYSLIB_DIR      directory containing target lib/librss_common.so, lib/librss_ipc.so,
#                   usr/lib/libimp.so, usr/lib/libalog.so (if omitted, builds librss_*
#                   from source and links with --allow-shlib-undefined)
#   HAL_REF         Small6oy/raptor-hal ref (default: onna-backend)
#   RAPTOR_REF      Small6oy/raptor ref (default: ivs-detect-frames)
#
# Output:
#   $BUILD_DIR/rvd-onna  (stripped MIPS32r2 XBurst2 uClibc binary for /usr/bin/rvd)
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
BUILD_DIR=${1:-/tmp/t41-rvd-onna-build}
HOST_ARCH=${HOST_ARCH:-$(uname -m)}
HAL_REF=${HAL_REF:-onna-backend}
RAPTOR_REF=${RAPTOR_REF:-ivs-detect-frames}

case "$HOST_ARCH" in
  aarch64|arm64) HOST_ARCH=aarch64 ;;
  x86_64|amd64)  HOST_ARCH=x86_64 ;;
  *) echo "unsupported host arch: $HOST_ARCH (want aarch64 or x86_64)" >&2; exit 2 ;;
esac

TC_NAME="thingino-toolchain-${HOST_ARCH}_xburst2_uclibc_gcc16-linux-mipsel.tar.gz"
TC_URL="https://github.com/themactep/thingino-firmware/releases/download/toolchain-${HOST_ARCH}/${TC_NAME}"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

echo "=== [1/5] Thingino XBurst2 uClibc GCC 16 toolchain ($HOST_ARCH) ==="
if [ ! -x "$BUILD_DIR/tc/bin/mipsel-linux-gcc" ]; then
  if [ ! -f "$TC_NAME" ]; then
    curl -fL --retry 3 -o "$TC_NAME.tmp" "$TC_URL"
    mv "$TC_NAME.tmp" "$TC_NAME"
  fi
  mkdir -p tc
  tar -xzf "$TC_NAME" -C tc --strip-components=1
  (cd tc && ./relocate-sdk.sh)
fi
CROSS="$BUILD_DIR/tc/bin/mipsel-linux-"
"${CROSS}gcc" --version | head -n 1

echo "=== [2/5] Fetch raptor-hal ($HAL_REF), raptor ($RAPTOR_REF), headers, common/ipc ==="
clone_or_keep() {
  local dir=$1 url=$2 branch=${3:-}
  if [ ! -d "$dir/.git" ]; then
    if [ -n "$branch" ]; then
      git clone --depth 10 --branch "$branch" "$url" "$dir"
    else
      git clone --depth 5 "$url" "$dir"
    fi
  fi
}
clone_or_keep raptor-hal      https://github.com/Small6oy/raptor-hal.git    "$HAL_REF"
clone_or_keep ingenic-headers https://github.com/gtxaspec/ingenic-headers.git
clone_or_keep raptor-common   https://github.com/gtxaspec/raptor-common.git
clone_or_keep raptor-ipc      https://github.com/gtxaspec/raptor-ipc.git
clone_or_keep raptor          https://github.com/Small6oy/raptor.git        "$RAPTOR_REF"

echo "=== [3/5] Apply hal_ivs_onna hal_yolo_t fix, JZDL_LIBS (#104), and class_thresholds ==="
ONNA_PATCH="$SCRIPT_DIR/patches/hal_ivs_onna-hal_yolo.patch"
if [ -f "$ONNA_PATCH" ] && ! grep -q 'hal_yolo_init' "$BUILD_DIR/raptor-hal/src/hal_ivs_onna.c"; then
  git -C "$BUILD_DIR/raptor-hal" apply "$ONNA_PATCH"
fi
python3 - "$BUILD_DIR/raptor/Makefile" "$BUILD_DIR/raptor/rvd/rvd_ivs.c" <<'PY'
import sys

mk_path, ivs_path = sys.argv[1], sys.argv[2]

mk = open(mk_path).read()
if 'JZDL_LIBS ?=' not in mk:
    old = 'ifeq ($(IVS_DETECT),1)\nCFLAGS += -DIVS_DETECT\nLDFLAGS_HAL += -ljzdl.m $(LINK_STDCXX)'
    new = 'JZDL_LIBS ?= -ljzdl.m $(LINK_STDCXX)\nifeq ($(IVS_DETECT),1)\nCFLAGS += -DIVS_DETECT\nLDFLAGS_HAL += $(JZDL_LIBS)'
    assert old in mk, 'unexpected raptor/Makefile IVS_DETECT block'
    open(mk_path, 'w').write(mk.replace(old, new, 1))

ivs = open(ivs_path).read()
if 'class_thresholds' not in ivs:
    anchor = '\t\tjp.nms_threshold = rss_config_get_int(cfg, "motion", "nms_threshold", 50) / 100.0f;\n'
    add = (
        anchor +
        '\t\tconst char *ct = rss_config_get_str(cfg, "motion", "class_thresholds", "");\n'
        '\t\tif (ct && *ct) {\n'
        '\t\t\tconst char *p = ct;\n'
        '\t\t\tfor (int ci = 0; ci < RSS_IVS_MAX_CLASSES && *p; ci++) {\n'
        '\t\t\t\tchar *end = NULL;\n'
        '\t\t\t\tlong v = strtol(p, &end, 10);\n'
        '\t\t\t\tif (end == p)\n'
        '\t\t\t\t\tbreak;\n'
        '\t\t\t\tif (v > 0 && v <= 100)\n'
        '\t\t\t\t\tjp.class_threshold[ci] = v / 100.0f;\n'
        '\t\t\t\tp = (*end == \',\') ? end + 1 : end;\n'
        '\t\t\t}\n'
        '\t\t}\n'
    )
    assert anchor in ivs, 'unexpected rvd_ivs.c nms_threshold line'
    open(ivs_path, 'w').write(ivs.replace(anchor, add, 1))
PY

echo "=== [4/5] Build libraptor_hal_video.a (PLATFORM=T41 ONNA=1) and rvd ==="
NCPU=$(nproc 2>/dev/null || echo 4)
make -C raptor-hal -j"$NCPU" \
  PLATFORM=T41 ONNA=1 \
  CROSS_COMPILE="$CROSS" \
  INGENIC_HEADERS="$BUILD_DIR/ingenic-headers"

MAKE_LINK_ARGS=()
if [ -n "${SYSLIB_DIR:-}" ]; then
  MAKE_LINK_ARGS+=(
    SYSROOT="$SYSLIB_DIR"
    LIB_IPC="-L${SYSLIB_DIR}/lib -lrss_ipc"
    LIB_IPC_FILE="${SYSLIB_DIR}/lib/librss_ipc.so"
    LIB_COMMON="-L${SYSLIB_DIR}/lib -lrss_common"
    LIB_COMMON_FILE="${SYSLIB_DIR}/lib/librss_common.so"
  )
else
  MAKE_LINK_ARGS+=(
    EXTRA_LDFLAGS="-Wl,--allow-shlib-undefined"
  )
fi

make -C raptor -j"$NCPU" \
  PLATFORM=T41 ONNA=1 \
  INGENIC_HEADERS="$BUILD_DIR/ingenic-headers" \
  CROSS_COMPILE="$CROSS" \
  IVS_DETECT=1 JZDL_LIBS= \
  "${MAKE_LINK_ARGS[@]}" \
  EXTRA_CFLAGS="-I${BUILD_DIR}/ingenic-headers/T41 -I${BUILD_DIR}/ingenic-headers/T41/imp -I${BUILD_DIR}/ingenic-headers/T41/sysutils" \
  rvd

echo "=== [5/5] Strip and verify ELF dependencies ==="
"${CROSS}strip" -o "$BUILD_DIR/rvd-onna" "$BUILD_DIR/raptor/rvd/rvd"
ls -lh "$BUILD_DIR/rvd-onna"
md5sum "$BUILD_DIR/rvd-onna"
"${CROSS}readelf" -l "$BUILD_DIR/rvd-onna" | grep -i interpreter
"${CROSS}readelf" -d "$BUILD_DIR/rvd-onna" | grep -E "NEEDED|RUNPATH"
echo "Done: $BUILD_DIR/rvd-onna"
