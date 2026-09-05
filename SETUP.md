# Setting up a new environment

`./setup.sh` installs the *host* tools (Icarus, yosys, KLayout, Python) and
verifies everything. **It does not clone or build ORFS** — that has to exist
first, and on macOS it is by far the hardest part.

Read the section for your platform, then run `./setup.sh`.

### Why this is longer than "four commands"

Write-ups of ORFS projects often give a four-line bootstrap of this shape:

```bash
git clone --recursive https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts
cd OpenROAD-flow-scripts
git clone <the design repo>
cd flow && make DESIGN_CONFIG=<...>/config.mk gds
```

**That cannot work on a fresh machine.** Nothing in it builds or installs a
tool, and ORFS ships submodule *source*, not binaries. The last line fails
immediately with:

```
flow/scripts/synth.sh: line 5: .../tools/install/yosys/bin/yosys: No such file or directory
```

On Linux the fix is small — it is two commands short, not twenty:

| Typical write-up | Actually works |
|---|---|
| clone ORFS | clone ORFS |
| `cd` | `cd` |
| clone the design | **`sudo ./setup.sh`** |
| `make … gds` | **`./build_openroad.sh --local`** |
| | clone the design |
| | `make … gds` |

So on a supported Linux, section 2 below is four commands and this document is
short. The length is entirely the macOS path, which exists because ORFS's own
`build_openroad.sh --local` is broken on macOS in four specific places
(enumerated below). That complexity belongs to the platform, not to this
document — and if you want the four-line experience, running the flow inside a
Linux container or VM genuinely delivers it.

---

## 1. This repo

```bash
git clone <your-remote>/my-chip
cd my-chip
```

## 2. ORFS + a working `openroad`

### Linux — the supported path

ORFS officially supports Ubuntu 20.04/22.04 (incl. aarch64), RHEL 8, RockyLinux
9 and Debian 11. On those, upstream's own instructions work:

```bash
git clone --recursive https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts
cd OpenROAD-flow-scripts
sudo ./setup.sh              # ORFS's setup.sh, not this repo's
./build_openroad.sh --local
```

Prebuilt OpenROAD binaries also exist for Ubuntu 20.04/22.04 and Debian 11
(Precision Innovations GitHub releases), which skips the compile entirely.

### macOS — not a supported platform

**`./build_openroad.sh --local` does not work on macOS.** It fails in four
separate places, so the build has to be driven manually. Everything below was
executed successfully on **macOS 26.5.1, arm64, Homebrew 6.0.20**; the version
pins are dictated by what Homebrew shipped at that time and *will* drift.

Why the supported path fails, for the record:

| Defect | Location |
|---|---|
| `" -D CMAKE_INSTALL_PREFIX=…"` has a leading space; `eval` turns the first `-D` into an empty define, so the prefix is silently dropped and cmake keeps `/usr/local` (root-owned) | `build_openroad.sh:210` |
| `cmakeOptions` is declared an **array** (`cmakeOptions=()`) but the darwin blocks append with **string** syntax (`+=" -D…"`), which appends to element `[0]`. Every macOS-specific option — Qt5, Tcl, flex, boost — is discarded | `build_openroad.sh:282-295`, `Build.sh:290-303` |
| `_install_darwin_packages` never installs **CUDD**, though OpenSTA links it unconditionally and there is no Homebrew formula | `etc/DependencyInstaller.sh` |
| `FindTCL.cmake` searches `PATH_SUFFIXES include include/tcl`; Homebrew puts `tcl.h` in `include/tcl-tk`, so `TCL_HEADER` is never found | `cmake/FindTCL.cmake:70` |

#### 2a. Clone

```bash
git clone --recursive https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts
export ORFS=$PWD/OpenROAD-flow-scripts
```

#### 2b. Homebrew dependencies

```bash
xcode-select --install          # if not already present

brew install bison boost bzip2 cmake eigen flex fmt groff googletest icu4c \
  libomp or-tools pandoc pkg-config qt@5 python readline spdlog tcl-tk@8 \
  zlib swig yaml-cpp yosys
brew install The-OpenROAD-Project/lemon-graph/lemon-graph
brew link --force libomp
brew install --cask klayout
brew install autoconf automake libtool     # needed to build CUDD
```

`qt@5` is deprecated in Homebrew (scheduled for removal 2027-05-19). If it is
gone, build with `-DBUILD_GUI=OFF` and lose `make path`'s GUI and the layout
images, but nothing else.

#### 2c. CUDD (no Homebrew formula; OpenSTA requires it)

```bash
export PATH="/opt/homebrew/opt/libtool/libexec/gnubin:$PATH"
git clone --depth=1 -b 3.0.0 https://github.com/The-OpenROAD-Project/cudd.git
cd cudd && autoreconf && ./configure --prefix="$HOME/.local" && make -j install && cd ..
```

#### 2d. fmt **12.1.0** exactly

OpenROAD vendors a SystemVerilog frontend (slang) that declares
`fmt_min_version "12.1"` and pins `GIT_TAG 12.1.0`. Homebrew ships **12.2.0**,
which removes something slang uses — you get
`no member named 'format' in namespace 'fmt'`. The copy bundled in-tree is
**11.2.1**, which is *below* the minimum and is silently rejected, so cmake falls
back to Homebrew's and the build fails. 12.1.0 is the only version that satisfies
both.

```bash
git clone --depth=1 -b 12.1.0 https://github.com/fmtlib/fmt.git
cmake -S fmt -B fmt-build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$HOME/.local/fmt-12.1.0" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DFMT_TEST=OFF -DFMT_DOC=OFF -DFMT_INSTALL=ON
cmake --build fmt-build -j --target install
```

#### 2e. spdlog against that fmt

Homebrew's spdlog is built against fmt 12.2.0, so it cannot be mixed with 12.1.0
(fmt versions its symbols by inline namespace). Build spdlog 1.17.0 against ours:

```bash
git clone --depth=1 -b v1.17.0 https://github.com/gabime/spdlog.git
cmake -S spdlog -B spdlog-build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$HOME/.local/spdlog-1.17.0-fmt121" \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DSPDLOG_FMT_EXTERNAL=ON \
  -Dfmt_DIR="$HOME/.local/fmt-12.1.0/lib/cmake/fmt" \
  -DSPDLOG_BUILD_EXAMPLE=OFF -DSPDLOG_BUILD_TESTS=OFF
cmake --build spdlog-build -j --target install
```

#### 2f. Hide Homebrew's fmt and spdlog for the duration of the build

Their headers live in `/opt/homebrew/include`, which appears **earlier** in the
include order than our local prefixes for some targets — so they shadow the
versions we just built and the build fails again. Unlink them:

```bash
brew unlink fmt spdlog
```

This removes only the symlinks in `/opt/homebrew/{include,lib}`. `/opt/homebrew/opt/fmt`
is untouched, so already-installed formulae that link against it keep working
(verified: `node` still runs). Nothing installed depends on brew's spdlog.

#### 2g. Configure and build OpenROAD

```bash
cd "$ORFS"
export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"
export CMAKE_PREFIX_PATH="$(brew --prefix or-tools)"
_icu="$(brew --prefix icu4c)"
export LDFLAGS="-L$_icu/lib" CPPFLAGS="-I$_icu/include" \
       PKG_CONFIG_PATH="$_icu/lib/pkgconfig" LIBRARY_PATH="/opt/homebrew/lib"
_tcl8="$(brew --prefix tcl-tk@8)"

cmake -S tools/OpenROAD -B tools/OpenROAD/build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$ORFS/tools/install/OpenROAD" \
  -DQt5_DIR="$(brew --prefix qt@5)/lib/cmake/Qt5" \
  -DTCL_LIBRARY="$_tcl8/lib/libtcl8.6.dylib" \
  -DTCL_HEADER="$_tcl8/include/tcl-tk/tcl.h" \
  -DTCL_INCLUDE_PATH="$_tcl8/include/tcl-tk" \
  -DFLEX_INCLUDE_DIR="$(brew --prefix flex)/include" \
  -DCUDD_DIR="$HOME/.local" \
  -Dfmt_DIR="$HOME/.local/fmt-12.1.0/lib/cmake/fmt" \
  -Dspdlog_DIR="$HOME/.local/spdlog-1.17.0-fmt121/lib/cmake/spdlog" \
  -DBUILD_PYTHON=OFF \
  -DCMAKE_CXX_FLAGS=-DBOOST_STACKTRACE_GNU_SOURCE_NOT_REQUIRED \
  -DENABLE_TESTS=OFF

cmake --build tools/OpenROAD/build -j"$(sysctl -n hw.ncpu)"
cmake --install tools/OpenROAD/build
```

Notes on three of those flags:

- **`Qt5_DIR` must point into the keg** (`/opt/homebrew/opt/qt@5/...`). Left to
  auto-detection cmake finds `/opt/homebrew/lib/cmake/Qt5`, a symlink farm whose
  relative prefix resolves to `/opt/homebrew/.`, so it looks for
  `/opt/homebrew/mkspecs/macx-clang` and fails. The real one is in the keg.
- **`BUILD_PYTHON=OFF`** — the SWIG `utl_py` target does not receive boost's
  include directory and fails on `boost/stacktrace/stacktrace.hpp`. ORFS's flow
  is Tcl-only, so the Python bindings are not needed. Do **not** work around it
  by adding `-I/opt/homebrew/include` to global flags: that re-shadows fmt and
  undoes 2d–2f.
- **`ENABLE_TESTS=OFF`** just saves build time.

#### 2h. Restore Homebrew's fmt and spdlog

```bash
brew link fmt spdlog
```

Safe once the build is done — fmt and spdlog are statically linked into the
`openroad` binary (verify with `otool -L`, which shows no references to them).
**Any future OpenROAD rebuild needs them unlinked again.**

#### 2i. KLayout quarantine

`brew install --cask klayout` sets `com.apple.quarantine`, and KLayout ships
**completely unsigned** (`codesign -v` → *"code object is not signed at all"*).
Gatekeeper only enforces on quarantined files, so the app hangs forever on
`klayout -v` — which ORFS evaluates at makefile-**parse** time, hanging *every*
make target including `make help`.

`./setup.sh` fixes this automatically by making a copy without extended
attributes. To fix `/Applications` instead, grant your terminal **App
Management** in System Settings → Privacy & Security, then:

```bash
xattr -dr com.apple.quarantine /Applications/KLayout/klayout.app
```

`brew install --cask --no-quarantine` no longer exists — Homebrew 6 removed it.

## 3. This repo's setup

```bash
cd my-chip
./setup.sh              # or --check to verify without installing
```

Expected output ends with `setup OK`. It writes `local.mk` with resolved tool
paths, so nothing afterwards needs exported variables.

## 4. Verify end to end

```bash
make sim        # 22/22 must pass
make measure    # N=4; prints one QoR row
make path       # the worst timing path of that run
```

**Check against the row for the configuration you actually built, not the one
below.** `make measure` with no arguments defaults to `CPORT=1`, so it emits
nickname `my_chip_n4_c1` and its comparison row is **f1b** in `EXPERIMENTS.md`.
The row quoted here is **v0**, measured before `C_PORT` existed as a parameter at
all — which is why its nickname has no `_c` suffix. Comparing today's default
against it silently compares two different designs, and the external-C port is
worth +1,170 stdcells and −22 MHz.

```
v0  (C_PORT absent -- historical)
| my_chip_n4    | 4 | 1.00 ns | -0.2776 | -51.594 | +0.0021 | 783 MHz | 0 | 7979 | 455 | 12817 | 0.0820 |
f1b (C_PORT=1 -- what `make measure` builds today)
| my_chip_n4_c1 | 4 | 1.00 ns | -0.3223 | -57.2   | +0.0004 | 756 MHz | 0 | 9158 | 455 | 13663 | 0.0700 |
```

If your numbers differ materially, the likely cause is a different OpenROAD
revision or PDK, not a broken install — record the commit in `EXPERIMENTS.md`.
Note that "ORFS 26Q3-1510" above and in `EXPERIMENTS.md` is **OpenROAD's**
`git describe`, not ORFS's: ORFS's own `26Q3` tag is only a few hundred commits
back, and the ORFS commit that pins OpenROAD `6cb3f2b704` is `6ada18baba`.

### Reproduced on Linux, 2026-09-04

The same OpenROAD commit built on AlmaLinux 9.6 / x86_64 / gcc 11.5 (rather than
macOS / arm64 / AppleClang) reproduces **f1b** as:

```
| my_chip_n4_c1 | 4 | 1.00 ns | -0.3047 | -60.409 | -0.0002 | 766 MHz | 0 | 9142 | 455 | 13526 | 0.0779 |
```

Flip-flops **exact** (455), stdcells −0.17%, area −1.0%, fmax +1.3% — inside the
48 MHz attribution noise this project already measured. Two things did move:
hold went `+0.0004, 0 violations` to `−0.0002, 1 violation`, and power +11%. So
the platform is not a free variable even at identical tool revision: rows
measured on different platforms are comparable in structure and should not be
compared in hold or power.

## Honest status of this document

The macOS section is **transcribed from a session that succeeded**, not from a
tested script. The steps are individually verified but have not been re-run
start to finish on a clean machine. The fmt/spdlog pins in particular exist only
because of what Homebrew shipped on 2026-08-27; when Homebrew moves, re-derive
them from slang's `fmt_min_version` in
`tools/OpenROAD/third-party/slang-elab/third_party/slang/external/CMakeLists.txt`
rather than assuming 12.1.0 is still right.

If you want this as a script instead of a checklist, it is a reasonable thing to
automate — but it should be validated by an actual clean-machine run before
anyone trusts it.
