# turbodisable

Switch Intel Turbo Boost **off and on** on macOS with no password prompts.

`turboctl off` / `turboctl on`, from an unprivileged account, hitting a root
LaunchDaemon over a unix socket. The daemon does the privileged work: it loads
and unloads a kernel extension that flips bit 38 of `IA32_MISC_ENABLE`
(MSR `0x1A0`) on every core.

---

## Dependency: Turbo Boost Switcher

The ring-0 half is **Turbo Boost Switcher's kernel extension**, not ours.
`turbodisable` is the control layer around it.

| | |
|---|---|
| What we use | `DisableTurboBoost.64bits.kext` |
| Bundle identifier | `com.rugarciap.DisableTurboBoost` |
| Signed by | Developer ID: Ruben Garcia Perez, team `A7JE7SS8Z7`, notarized |
| Upstream | https://www.rugarciap.com/ |

Turbo Boost Switcher is freeware. `install.sh` fetches it automatically if it is
not already present, then uses its kernel extension and **never launches its
app**. That is why the purchase prompt never appears: the app is not the thing
doing the work.

The download is verified before anything is copied:

1. the newest `Turbo_Boost_Switcher_v*.dmg` is located on the official site
   (pin a specific build with `TBS_DMG_URL=...`);
2. the image is mounted read-only and the app inside must be signed by team
   **`A7JE7SS8Z7`** *and* accepted by Gatekeeper;
3. only `tbswitcher_resources` — the kernel extensions — is installed into
   `/Applications`. The GUI app is not installed.

If either check fails, nothing is copied and the installer refuses. Use
`--no-fetch` to skip the download entirely and provide the kext yourself.

Turbo Boost Switcher is not bundled in this repository or in the `.pkg`; it is
fetched from the vendor at install time, and remains Rugarciap's under whatever
terms they publish. What this project provides is the daemon, the CLI, and the
packaging.

### Why the TBS kext and not our own

We wrote one (`kext/TurboLock.c`, ~95 lines, MIT, from the Intel SDM) and it
works — but a locally built kext is unsigned, and macOS will not load an
unapproved unsigned kext. Turbo Boost Switcher's kext is covered by an existing
per-machine allowance for that bundle identifier, so it loads without a
`csrutil` change and without a paid Apple Developer account. Using it removes
the one-time Recovery step entirely.

`TurboLock.kext` is still built by `install.sh` and still used as a fallback if
the TBS kext is absent and kext signing is relaxed. See *Backends* below.

## How it works

```
        turboctl (unprivileged, uid 501)
            │  "off" / "on" / "status"    unix socket, 0660 root:staff
            ▼
        turbod (root, launchd, KeepAlive)
            │  kextload / kextunload     IORegisterForSystemPower
            ▼                             + 120 s drift check
        DisableTurboBoost.kext  ──►  wrmsr 0x1A0 bit 38, on all cores
```

* **No password.** The socket is `0660 root:staff`; anyone in `staff` can talk
  to it. `turbod` runs as root from `launchd` and needs no prompt to call
  `kextload`.
* **Survives reboot.** `RunAtLoad` plus a boot worker apply the stored state at
  startup.
* **Survives wake.** Firmware may rewrite `IA32_MISC_ENABLE` across S3, and a
  kext that is merely still loaded will *not* re-apply bit 38 — only its
  `start()` does. So after every wake the daemon cycles the kext (unload, then
  load) to rewrite the MSR on all cores.
* **Survives silent drift.** State is re-checked every 120 s, and every 5th
  check (10 min) also cycles the kext, so a reset that produced no wake
  notification is still repaired.

## Install

```sh
git clone git@github.com:computerex/turbod.git
cd turbod
sudo ./install.sh
```

`install.sh` fetches Turbo Boost Switcher if it is not already installed, builds
and installs `turbod`, `turboctl`, and `clocktest`, and verifies that a kext
backend actually loads **before** touching anything else. If it can't load one,
it stops and says why.

## Backends

`turbod` picks, in order:

1. `com.rugarciap.DisableTurboBoost` at:
   * `/Applications/tbswitcher_resources/DisableTurboBoost.64bits.kext`
   * `/Library/StagedExtensions/Applications/tbswitcher_resources/DisableTurboBoost.64bits.kext`
   * `/Library/Extensions/DisableTurboBoost.64bits.kext`
2. `com.turbodisable.TurboLock` at:
   * `/Library/Extensions/TurboLock.kext`
   * `/usr/local/libexec/turbodisable/kext/TurboLock.kext`

Backend 1 needs no approval step. Backend 2 is ours and needs either a paid
Developer ID or the one-time `csrutil enable --without kext` if you want to use
it instead.

`sudo ./install.sh --status` prints which backend is present, which is loaded,
and whether kext signing is currently enforced.

## Usage

```sh
turboctl off        # disable Turbo Boost
turboctl on         # re-enable
turboctl toggle
turboctl status     # state + measured GHz
turboctl doctor     # everything, for bug reports
turboctl log        # daemon history
```

No `sudo` for any of these.

## Verify it actually worked

```sh
turboctl on   ; turboctl bench     # ~2.3 GHz  -> DISABLED
turboctl off  ; turboctl bench     # ~4.3 GHz  -> ENABLED
```

`clocktest` is a dependent-add chain — one add retires per cycle, so
`iterations / elapsed` *is* the real clock frequency. The kext flag tells you
what the tool *intended*; the measured clock tells you what the CPU *did*. If
they disagree, `status` says so rather than picking one.

## Package

```sh
make package      # -> dist/turbodisable-1.0.0.pkg
```

One file: the daemon, the CLI, the LaunchDaemon, and a copy of our own kext for
backend 2. The `.pkg` itself does not fetch Turbo Boost Switcher — `postinstall`
uses it when already present and otherwise says where to get it, or how to fall
back to our own kext. For the automatic fetch, use `install.sh`.

## Files

| Path | Purpose |
|---|---|
| `turbod.c` | root daemon + privileged helper, backend selection |
| `turboctl` | CLI (status/doctor/toggle/bench/log) |
| `clocktest.c` | clock-frequency verifier |
| `com.turbodisable.turbod.plist` | LaunchDaemon |
| `kext/TurboLock.c` | our own kext, optional backend 2 |
| `kext/Info.plist`, `kext/build.sh` | bundle metadata, CLT-only build |
| `install.sh` / `uninstall.sh` | setup / teardown |
| `packaging/` | `.pkg` builder and postinstall |
| `test-sandbox.sh` | end-to-end daemon test, no root (`make check`) |

## Caveats

* **Ownership matters.** The kernel requires `root:wheel` on every path inside a
  kext bundle. `install.sh` enforces it for ours; TBS's bundle is already
  correct from its own installer.
* **Intel only.** No Turbo Boost on Apple Silicon, and no third-party kexts at
  all.
* **TBS updates** can replace or move the kext. Re-run `install.sh --status`
  after updating it.
* **Uninstalling TBS** removes your backend. `turboctl` will report the missing
  kext instead of silently doing nothing.
* **Firmware may restore the MSR across S3.** The wake hook handles it; a second
  `turbo disabled` line after a wake in `turboctl log` is it working.

## Uninstall

```sh
sudo ./uninstall.sh        # or: sudo /usr/local/libexec/turbodisable/uninstall.sh
```

Unloads the kext, stops and removes the daemon, removes `turboctl`,
`clocktest`, and the LaunchDaemon. Turbo Boost returns. It does not touch Turbo
Boost Switcher — that is yours, and it stays installed.

## License

MIT for this project: `turbod.c`, `turboctl`, `clocktest.c`, `install.sh`,
`kext/TurboLock.c`, and the packaging. `kext/TurboLock.c` was written from the
public Intel Software Developer's Manual and contains no third-party code.

Turbo Boost Switcher and `DisableTurboBoost.kext` are Rugarciap's, are not part
of this repository, and are covered by their own terms.
