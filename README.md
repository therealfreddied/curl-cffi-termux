# curl-cffi-termux

Install [`curl_cffi`](https://github.com/lexiforest/curl_cffi) — libcurl with
browser TLS impersonation — on **Termux (Android)** in one shot, on **any
Python version** (3.10 through 3.14), **fresh install or not**.

No root. No `PYTHONPATH` hacks. No dangerous system tweaks. Just run the
command.

---

## One-shot install

```bash
curl -fsSL https://raw.githubusercontent.com/therealfreddied/curl-cffi-termux/refs/heads/main/install-curl-cffi.sh | bash
```

That's it. On a completely fresh Termux the script first provisions the whole
toolchain (`python`, `clang`, `make`, `binutils`, `libc++`, `libffi`,
`pkg-config`) via `pkg`, then builds `curl_cffi` from source and verifies it
with a real TLS-impersonation request. Total: about one minute.

## Verify it works

```bash
python3 -c "from curl_cffi import requests; r = requests.get('https://example.com', impersonate='chrome'); print('HTTP', r.status_code)"
```

Expected output:

```
OK  curl_cffi 0.16.0 | chrome impersonation -> HTTP 200
```

## Idempotent by design

Every stage detects what is already present and skips it:

- **Termux packages** are checked via `pkg list-installed`; only missing ones
  are installed.
- **pip build deps** (`cffi`, `wheel`, `setuptools`) are import-checked and
  skipped if present.
- **`curl_cffi` itself** is smoke-tested with a live `impersonate='chrome'`
  request; a working install exits instantly with "nothing to do".

Only an explicit `--force` forces a rebuild. Run the one-liner every day — it
costs nothing when everything is already in place.

## Why not just `pip install curl_cffi`?

On Termux a naive `pip install` fails, for two separate reasons:

### 1. The official Android wheel is broken off-by-one

PyPI ships `curl_cffi-0.16.0-cp313-abi3-android_24_arm64_v8a.whl`, built
against `libpython3.13.so`. On a Termux running Python 3.10, 3.11, 3.12, or
3.14 that shared library does not exist, so the import fails instantly.

### 2. The Termux C++ toolchain links the wrong libc++

Even building from the sdist with `--no-binary :all:` produces a
`_wrapper.abi3.so` that crashes at import:

```
ImportError: dlopen failed: cannot locate symbol
"_ZNSt6__ndk16__sortIRNS_6__lessIttEEPtEEvT0_S5_T_" referenced by
".../curl_cffi/_wrapper.abi3.so"
```

Termux's `clang` resolves `-lc++` to `/system/lib64/libc++.so` — the ancient
Android system libc++ that predates the modern `__ndk1` C++ ABI. The
statically-linked `_wrapper` needs `__ndk1` symbols, the system library does
not provide them, and `dlopen` dies.

## How the installer works

The script performs four steps:

1. **Provision the toolchain** — only the packages missing from
   `python clang make binutils libc++ libffi pkg-config` are installed.

2. **Fix the C++ link target, scoped to the build only.** The sdist's
   `scripts/build.py` would otherwise link with `-lc++`, which Termux clang
   resolves to `/system/lib64/libc++.so`. The installer downloads the sdist,
   patches `-lc++` -> `-lc++_shared` (Termux's own libc++), and builds from
   that patched tree. **Nothing under `/usr/lib` — or anywhere else global —
   is created or modified.** The patch lives only in an ephemeral build
   directory.

3. **Build from source.** curl_cffi's `scripts/build.py` detects the
   Termux/Android environment, downloads a prebuilt **static**
   `libcurl-impersonate.a` (aarch64-linux-android), and fuses it into
   `_wrapper.abi3.so`. The resulting wheel is:

   - **abi3** — installs and runs on every Python 3.10+, current or future;
   - **self-contained** — no runtime libcurl dependency (statically linked);
   - **verified** — checked with a live `impersonate='chrome'` request and,
     when `readelf` is available, confirmed to link `libc++_shared.so`
     instead of the system `libc++.so`.

4. **Verify** — runtime TLS-impersonation smoke test against
   `https://example.com` must return `HTTP 200`.

## Options

| Flag / env          | Effect                                                          |
| ------------------- | --------------------------------------------------------------- |
| `--force`           | Force a rebuild even if the installed version already passes    |
| `CURL_CFFI_VERSION` | Pin a different version, e.g. `CURL_CFFI_VERSION="curl_cffi==0.17.0"` |
| `PIP`               | Use a different pip command, e.g. `PIP="uv pip install"`        |

Examples:

```bash
bash install-curl-cffi.sh --force
CURL_CFFI_VERSION="curl_cffi==0.17.0" bash install-curl-cffi.sh --force
```

## Why version 0.16.0?

The default pin. Newer curl_cffi releases change the bundled static
libcurl-impersonate build, which may reintroduce the `__ndk1` ABI drift on
Termux. `0.16.0` uses the pure-C v2.0.0 static archive and builds cleanly.
You can override with `CURL_CFFI_VERSION`, but verify with the smoke test
afterwards.

## Requirements

- Termux (Android, aarch64/arm64; also tested on armv7 via 32-bit builds)
- `python3` — any supported version; dev headers ship with the Termux `python`
  package, no separate dev package needed
- Working network once — to fetch the sdist, the pip build deps, and the
  static `libcurl-impersonate.a` archive

## Troubleshooting

| Symptom | Cause | Fix |
| ------- | ----- | --- |
| `cannot locate symbol _ZNSt6__ndk1...` | `_wrapper` linked `/system/lib64/libc++.so` instead of Termux's libc++ | Re-run the installer (it patches `build.py` to link `-lc++_shared`) |
| `libc++_shared.so not found` | `libc++` package missing | `pkg install libc++`, then rerun |
| Re-running changes nothing (instant "nothing to do") | `curl_cffi` already works | Intended — idempotent by design. Pass `--force` only to rebuild |
| Import error mentioning `libpython3.13.so` | Upstream Android wheel installed by hand | `python3 -m pip uninstall curl_cffi`, then rerun the installer |
| Hangs during install | Some Termux python builds try to compile extensions from source | `pkg install python clang make libc++ libffi` then rerun; the Linux-style caching is bypassed with `--no-cache-dir` |
| Offline | Script needs network once for build archives | Pre-seed the pip cache, then rerun with `--no-build-isolation` |

## License

MIT. `curl_cffi`, `libcurl-impersonate`, and their artifacts are the property
of their respective authors and are downloaded from their public releases.