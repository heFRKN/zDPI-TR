# Third-Party Notices

zDPI bundles the following third-party binaries in the `core/` folder. They are
redistributed unmodified and remain under their original licenses. The MIT
license in [LICENSE](LICENSE) covers only zDPI's own code (`zDPI.exe` and its
source in `gui/`, `core/zdpi.ps1`, `tools/`) and documentation.

| File | Project | Author | License |
| :-- | :-- | :-- | :-- |
| `core/winws.exe` | [zapret](https://github.com/bol-van/zapret) v72.13 | bol-van | MIT |
| `core/WinDivert.dll`, `core/WinDivert64.sys` | [WinDivert](https://github.com/basil00/WinDivert) 2.2.2 | basil00 | LGPL-3.0 or GPL-2.0 (dual) |
| `core/cygwin1.dll` | [Cygwin](https://cygwin.com) | Cygwin authors | LGPL-3.0 with Cygwin linking exception |

Full license texts:

- zapret: https://github.com/bol-van/zapret/blob/master/LICENSE.txt
- WinDivert: https://github.com/basil00/WinDivert/blob/master/LICENSE
- Cygwin: https://cygwin.com/licensing.html

Source code for WinDivert and Cygwin is available from the links above, as
required by their licenses.

## Verification

All four binaries are byte-identical to the official zapret v72.13 release
(`binaries/windows-x86_64`), as listed in its
[sha256sum.txt](https://github.com/bol-van/zapret/releases/tag/v72.13):

| File | SHA256 |
| :-- | :-- |
| `winws.exe` | `a14bff1df6234ea555d2e0c61b589f0707c0b12d6c9b7eeccda76012154996e8` |
| `cygwin1.dll` | `103104a52e5293ce418944725df19e2bf81ad9269b9a120d71d39028e821499b` |
| `WinDivert.dll` | `c1e060ee19444a259b2162f8af0f3fe8c4428a1c6f694dce20de194ac8d7d9a2` |
| `WinDivert64.sys` | `8da085332782708d8767bcace5327a6ec7283c17cfb85e40b03cd2323a90ddc2` |
