## About UMR (Optional / Advanced)

`umr` is AMD's low-level GPU register read/write tool, required by `bc250-cu-live-manager` to enable/disable Compute Units on the BC-250. Since Batocera has no compiler toolchain, `umr` must be built externally and bundled with its dependencies.

**The `install-cu-manager.sh` script handles this automatically** — it downloads `umr-bc250.tar.gz` from this repo. You only need to rebuild it manually if you want to update or downgrade umr.

---

### Bundled version `umr-bc250.tar.gz`

| Field | Value |
|---|---|
| umr version | `1.0.11` |
| git commit | `26e29024` |
| full tag | `1.0.11-273-g26e2902` |
| source | https://gitlab.freedesktop.org/tomstdenis/umr |
| built with | `-DUMR_GUI=OFF -DUMR_NO_LLVM=ON` |

---

### Bundle structure

The tarball extracts to this layout, which `install-cu-manager.sh` places under `/userdata/system/bc250-cu-manager/`:

```
umr-bc250/
  bin/
    umr                      ← main binary
    libncurses.so.6          ← bundled dependency
    libtinfo.so.6            ← bundled dependency
  database/
    cyan_skillfish.asic      ← BC-250 ASIC definition
    cyan_skillfish.soc15     ← BC-250 SOC15 map
    pci.did                  ← PCI device ID table
    ip/
      athub_2_0_0.reg
      clk_11_0_1.reg
      dpcs_2_0_3.reg
      gc_10_1_0.reg
      hdp_5_0_0.reg
      mmhub_2_0_0.reg
      mp_11_0_8.reg
      nbio_2_3_0.reg
      osssys_5_0_0.reg
      smuio_11_0_0.reg
      thm_11_0_2.reg
      vcn_2_0_0.reg
```

> **Note:** `dcn_2_0_3.reg` is referenced in `cyan_skillfish.asic` but does not exist in the umr source tree. This is a known upstream gap and has no impact on WGP/CU register access.

---

### Rebuilding umr manually

> ⚠️ Recommended to be built in an Ubuntu environment. Other distros such as Arch/CachyOS may produce glibc-incompatible libs that will crash on Batocera. Use WSL or Distrobox with Ubuntu if you are on a non-Ubuntu system.

#### Ubuntu / WSL / Distrobox (recommended)

If you're on another distro, use Distrobox to get an Ubuntu environment e.g:
```bash
distrobox create --name ubuntu-build --image ubuntu:24.04
distrobox enter ubuntu-build
```
Once done, you can delete the container:
```bash
distrobox rm ubuntu-build
```

Then follow the steps below inside the Ubuntu environment:

```bash
# 1. Install dependencies
sudo apt update
sudo apt install -y cmake git libdrm-dev libpciaccess-dev build-essential

# 2. Clone umr
cd ~
git clone https://gitlab.freedesktop.org/tomstdenis/umr.git
cd umr

# 3. Build (no GUI, no LLVM)
cmake -DUMR_GUI=OFF \
      -DUMR_NO_LLVM=ON \
      -B build -S .
cmake --build build -j$(nproc)

# 4. Strip debug symbols
strip build/src/app/umr

# 5. Check version
git describe --tags

# 6. Bundle binary + libs + BC-250 database only
mkdir -p /tmp/umr-bc250/bin /tmp/umr-bc250/database/ip

cp build/src/app/umr                               /tmp/umr-bc250/bin/
cp /lib/x86_64-linux-gnu/libncurses.so.6.4         /tmp/umr-bc250/bin/libncurses.so.6
cp /lib/x86_64-linux-gnu/libtinfo.so.6.4           /tmp/umr-bc250/bin/libtinfo.so.6
cp database/cyan_skillfish.asic                    /tmp/umr-bc250/database/
cp database/cyan_skillfish.soc15                   /tmp/umr-bc250/database/
cp database/pci.did                                /tmp/umr-bc250/database/
cp database/ip/athub_2_0_0.reg                     /tmp/umr-bc250/database/ip/
cp database/ip/clk_11_0_1.reg                      /tmp/umr-bc250/database/ip/
cp database/ip/dpcs_2_0_3.reg                      /tmp/umr-bc250/database/ip/
cp database/ip/gc_10_1_0.reg                       /tmp/umr-bc250/database/ip/
cp database/ip/hdp_5_0_0.reg                       /tmp/umr-bc250/database/ip/
cp database/ip/mmhub_2_0_0.reg                     /tmp/umr-bc250/database/ip/
cp database/ip/mp_11_0_8.reg                       /tmp/umr-bc250/database/ip/
cp database/ip/nbio_2_3_0.reg                      /tmp/umr-bc250/database/ip/
cp database/ip/osssys_5_0_0.reg                    /tmp/umr-bc250/database/ip/
cp database/ip/smuio_11_0_0.reg                    /tmp/umr-bc250/database/ip/
cp database/ip/thm_11_0_2.reg                      /tmp/umr-bc250/database/ip/
cp database/ip/vcn_2_0_0.reg                       /tmp/umr-bc250/database/ip/

# 7. Pack — output is at /tmp/umr-bc250.tar.gz
cd /tmp
tar -czf umr-bc250.tar.gz umr-bc250/
ls -lh umr-bc250.tar.gz
```

```bash
# WSL only — copy to Windows
cp /tmp/umr-bc250.tar.gz /mnt/c/Users/<USERNAME>/Downloads/
```

> **Note:** `/tmp` is cleared on reboot. Copy the tarball somewhere permanent before rebooting if you're not uploading it immediately.

---

Once bundled, place the contents directly on Batocera e.g. via SCP, SFTP, USB stick, or shared network folder:

```
# Copy to Batocera (adjust source path to however you transferred the files)
cp -r /path/to/umr-bc250/bin/* /userdata/system/bc250-cu-manager/bin/
cp -r /path/to/umr-bc250/database/* /userdata/system/bc250-cu-manager/database/

# Then either restart the service or reboot
batocera-services restart bc250_cu_manager
```
