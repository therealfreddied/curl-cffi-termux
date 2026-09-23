#!/usr/bin/env bash
# install-curl-cffi.sh — Termux curl_cffi installer (works on ANY python3,
# including a fresh Termux that has no Python installed yet)
#
#   curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/install-curl-cffi.sh | bash
#
# Bootstrap: installs the whole toolchain (python, clang, make, binutils,
# libc++, libffi, pkg-config) via pkg first, then builds curl_cffi from the
# sdist. The build patches scripts/build.py to link -lc++_shared (Termux's own
# libc++) instead of -lc++ (which Termux clang resolves to the ancient
# /system/lib64/libc++.so lacking the __ndk1 ABI). The patch only lives in the
# ephemeral build dir — nothing under /usr/lib is created or modified.
#
# The upstream Android wheel (cp313-abi3-android_24_arm64_v8a) links
# libpython3.13.so and is broken on every other Termux python, which is why we
# always build from source instead.
#
# Every stage is IDEMPOTENT: existing python/curl_cffi/deps are detected and
# skipped. Only `--force` forces a rebuild of curl_cffi.
set -euo pipefail

# ---- sanity: must be Termux ----------------------------------------------
if ! command -v pkg >/dev/null 2>&1; then
    echo "[!] 'pkg' not found — this script is for Termux/Android only."
    exit 1
fi
PREFIX="$(dirname "$(dirname "$(command -v pkg)")")"
PIP="${PIP:-python3 -m pip}"
# Known-good pin for Termux. Newer versions change the static-archive ABI and
# may need re-verification. Override: CURL_CFFI_VERSION="curl_cffi==X.Y.Z"
CURL_CFFI_VERSION="${CURL_CFFI_VERSION:-curl_cffi==0.16.0}"

PKG_DEPS="python clang make binutils libc++ libffi pkg-config"

echo "== Termux curl_cffi installer (pin: $CURL_CFFI_VERSION) =="

pkg_installed() { pkg list-installed 2>/dev/null | cut -d/ -f1 | grep -qx "$1"; }

# ---- 1. Termux system deps — detect & install ONLY what's missing ----------
echo "> Checking Termux packages ..."
missing=""
for p in $PKG_DEPS; do
    if pkg_installed "$p"; then
        echo "   ok: $p"
    else
        echo "   need: $p"
        missing="$missing $p"
    fi
done
if [ -n "$missing" ]; then
    echo "> Installing missing Termux packages:$missing"
    pkg update >/dev/null 2>&1 || true
    if ! pkg install -y $missing; then
        echo "[!] pkg install failed — run 'pkg install $missing' manually."
        exit 1
    fi
else
    echo "> All Termux packages already present."
fi

command -v python3 >/dev/null 2>&1 || { echo "[!] python3 missing after pkg install"; exit 1; }
command -v clang  >/dev/null 2>&1 || { echo "[!] clang missing after pkg install"; exit 1; }
python3 --version

# ---- 2. curl_cffi already good? -> skip everything ------------------------
if [ "${1:-}" != "--force" ]; then
    status="$(python3 - <<'PY' 2>/dev/null || true
try:
    import curl_cffi  # noqa
    r = curl_cffi.requests.get("https://example.com", impersonate="chrome", timeout=15)
    print("ok" if r.status_code == 200 else "broken")
except ImportError:
    print("missing")
except Exception:  # network/dns errors etc -> leave an installed build alone
    print("ok")
PY
)"
    if [ "$status" == "ok" ]; then
        echo "> curl_cffi already installed and responding — nothing to do."
        exit 0
    fi
    [ "$status" == "broken" ] && echo "> curl_cffi installed but broken -> rebuilding."
    [ "$status" == "missing" ] && echo "> curl_cffi not installed -> installing."
fi

# ---- 3. pip build deps (cffi/wheel/setuptools) — detect & skip ---------------
echo "> Checking pip build deps (cffi, wheel, setuptools) ..."
missing_py=""
for m in cffi wheel setuptools; do
    if python3 -c "import $m" >/dev/null 2>&1; then
        echo "   ok: $m"
    else
        echo "   need: $m (pip)"
        missing_py="$missing_py $m"
    fi
done
if [ -n "$missing_py" ]; then
    echo "> Installing pip build deps:$missing_py"
    $PIP install --no-cache-dir -q $missing_py
else
    echo "> pip build deps already present."
fi

# ---- 4. fetch & patch the sdist (only when not --force) ----------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
echo "> Fetching sdist ..."
$PIP download --no-cache-dir -q --no-binary :all: --no-deps "$CURL_CFFI_VERSION" -d "$WORK"
tar xf "$WORK"/curl_cffi-*.tar.gz -C "$WORK"
SRC="$(echo "$WORK"/curl_cffi-*/scripts/build.py)"
echo "> Patching build.py: -lc++ -> -lc++_shared (Termux libc++, scoped to build)"
python3 - "$SRC" <<'PY'
import re, sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
t2 = re.sub(r'"-lc\+\+"', '"-lc++_shared"', t)
assert t2 != t, "patch anchor '-lc++' not found in build.py"
open(p, "w", encoding="utf-8").write(t2)
PY

# ---- 5. build from source (fast: single C translation unit, abi3 output) ---
echo "> Building curl_cffi from sdist ..."
$PIP install --no-cache-dir -q --no-binary :all: --no-build-isolation "$(echo "$WORK"/curl_cffi-*/)"

# ---- 6. runtime verification -------------------------------------------------
echo "> Verifying https + browser impersonation ..."
python3 - <<'PY'
import shutil, subprocess, sys
from curl_cffi import requests, __version__
r = requests.get("https://example.com", impersonate="chrome", timeout=20)
assert r.status_code == 200, f"HTTP {r.status_code}"
print(f"OK  curl_cffi {__version__} | chrome impersonation -> HTTP {r.status_code}")
if shutil.which("readelf"):
    site = f"{sys.prefix}/lib/python{sys.version_info.major}.{sys.version_info.minor}/site-packages/curl_cffi/_wrapper.abi3.so"
    out = subprocess.run(["readelf", "-d", site], capture_output=True, text=True).stdout
    assert "libc++_shared.so" in out and " libc++.so" not in out, "wrong libc++ link target!"
    print("OK  _wrapper links Termux libc++_shared.so (not /system/lib64/libc++.so)")
PY

echo "== Done. Try: python3 -c \"from curl_cffi import requests\""