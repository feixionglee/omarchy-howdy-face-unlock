# Howdy Face Unlock

Face unlock for IR webcams on Omarchy, via [Howdy](https://github.com/boltgolt/howdy).
Mirrors the fingerprint flow as closely as Omarchy's plugin system allows.

## Install

```
omarchy plugin add https://github.com/feixionglee/omarchy-howdy-face-unlock
~/.config/omarchy/plugins/io.github.feixionglee.howdy-face-unlock/setup
```

`omarchy plugin add` only clones files — run `setup` yourself afterward. It
detects your IR camera, installs `howdy-git` and `linux-enable-ir-emitter`
from the AUR (building `python-dlib` CPU-only unless it detects an Nvidia
GPU, to dodge that AUR package's broken CUDA subpackage; the CPU-only build
clones the AUR PKGBUILD pinned to a fixed commit SHA so upstream can't move
under the build), configures the emitter, enrolls your face, and enables three independent
authentication modules in one pass:

- **Omarchy lock screen** — face unlock alongside password/fingerprint.
- **sudo** — tries Howdy first, then falls back to the existing PAM stack.
- **Polkit / desktop authentication** — enables Howdy for applications and
  privileged desktop actions that authenticate through Polkit/PAM (including
  1Password's Linux system-authentication flow).

All three modules are selected by default. Interactive setup shows the choices
before making PAM changes; press Enter to accept all three, or toggle the
modules you do not want. For automation, use `./setup --all` or select an
explicit subset such as `./setup --modules lock-screen,polkit`.

Setup and removal are also reachable from the Omarchy menu: **Setup → Security
→ Face Unlock** and **Remove → Security → Face Unlock** (both only appear
once an IR camera is detected / Howdy is installed, respectively).

## Remove

```
~/.config/omarchy/plugins/io.github.feixionglee.howdy-face-unlock/remove
omarchy plugin remove io.github.feixionglee.howdy-face-unlock
```

## Independent locks and legacy integration

The active lock determines how this plugin integrates with the shell. Setup
queries `omarchy plugin list --json`; run it while the shell is available and
exactly one lock plugin is enabled.

- **An independent lock clone** (`clonedFrom: omarchy.lock`, any plugin ID):
  setup creates the dedicated `/etc/pam.d/omarchy-lock-howdy` service but does
  not modify the clone, the packaged default lock, or dormant Explorer files.
  The clone must already implement Howdy authentication. This plugin does not
  inject authentication code into arbitrary third-party QML.
- **The stock lock or supported Lock Screen Explorer**: the existing QML
  patch integration and update repair remain available for compatibility.
- **Unknown or ambiguous active lock**: the lock-screen setup step stops before
  modifying PAM or lock files. The post-update hook skips repairs and explains
  that the lock could not be identified. Other earlier setup steps may already
  have completed; this is not a rollback of the whole installer.

The post-update hook inspects the active integration before doing anything.
For independent clones it only reports health, without invoking sudo or
writing system files. Existing legacy installations keep their repair path.
Installing an updated plugin checkout alone does not replace the previously
copied hook; install the new hook explicitly:

```sh
omarchy hook install post-update ~/.config/omarchy/plugins/io.github.feixionglee.howdy-face-unlock/hooks/post-update.d/repair-howdy-lock.hook
omarchy-shell shell rescanPlugins
```

### Health checks

`omarchy-shell howdy status` returns `ok`, `broken`, or `unknown`.
`omarchy-shell howdy check` requests a new check (the result is asynchronous).

The check first reads `omarchy-shell lock status`. Locks can expose boolean
`howdy` and `passwordPam` fields: both true means ready, and either false
means broken. These fields report dependency readiness, not a successful
camera recognition attempt. No authentication is started by the check.

If this status API is unavailable or unsupported, only the known stock and
Explorer integrations fall back to checking their active QML file and the
dedicated PAM service. An arbitrary clone without the status fields is
**unknown**, not broken; no repair notification is issued merely because its
API differs. A patched but inactive default lock cannot make a custom lock
appear healthy. Startup checks retry briefly while the shell loads.

The helper can also be run directly for diagnostics:

```sh
python3 bin/howdy-lock-state.py integration  # custom, legacy, or unknown
python3 bin/howdy-lock-state.py health       # ok, broken, or unknown
```

These checks use only the standard library and make read-only IPC calls.
An absent shell, malformed response, or timeout never authorizes patching an
unknown lock.

### Legacy patch installation

The legacy installer and update hook patch an unprivileged temporary copy of
QML and use sudo only to install the resulting file. They do not run the
Python patcher as root. Explorer files are user-owned and are patched without
sudo. These paths are skipped entirely for independent lock clones.

## Authentication modules

The installer remains one-click by default, but interactive runs let the user
choose the integrations before they are configured. The integrations are separate in
`modules/`: `lock-screen.sh`, `sudo.sh`, and `polkit.sh`. This keeps each
authentication surface independently installable/removable in code without
turning `system-auth` into a global Howdy switch.

The Polkit module never edits Arch's package-owned
`/usr/lib/pam.d/polkit-1`. It creates an administrator override at
`/etc/pam.d/polkit-1`, inserts `pam_howdy.so` before the existing
`system-auth` include, and removes/restores only configuration the plugin
owns. The sudo module follows the same ownership rule and preserves a pristine
backup before changing `/etc/pam.d/sudo`.

## What setup actually changes

- Installs `howdy-git`, `linux-enable-ir-emitter`, `v4l-utils`, `python-dlib`
- `/etc/howdy/config.ini` — tuned for IR (`dark_threshold`, `certainty`,
  `max_height`), `workaround = off` (Howdy's default `input` workaround tries
  to fake an Enter keypress via `/dev/uinput` to unblock a legacy
  simultaneous-password-prompt flow this lock screen doesn't have — with a
  dedicated `PamContext` per auth method, it just hangs), and made
  world-readable (the lock screen's PAM module runs unprivileged, in-process,
  with no root daemon to broker access the way fprintd has, so it has to be
  able to read its own config as that user)
- `/etc/pam.d/omarchy-lock-howdy` — a PAM service dedicated to Howdy,
  independent of `omarchy-lock-fingerprint`
- `lock/Service.qml` — a parallel `startHowdy()`/`howdyPam`/`howdyCheckProc`
  path, wired in alongside the existing fingerprint one. When the lock
  screen engages — e.g. when you close the lid — Howdy starts
  authenticating right away, retrying every 250 ms on failure. So face
  unlock is already live when you open the lid: just look at the camera.
  A failed attempt only keeps retrying while there's been recent activity
  (the lock just engaged, or a wake signal — mouse move, key press, a
  password attempt — within the last 10s); otherwise retries pause instead
  of burning through attempts against an empty room while nobody's there.
  Any wake signal while paused (or even after full lockout) resets the
  attempt count and re-arms a fresh attempt immediately, so face unlock is
  live again the moment you're actually back — not still shaking off a
  lockout from the last time it scanned an empty desk. Only 5 failed
  attempts in a row *with* someone actually present trips the fallback to
  password-only for the rest of that lock. A retry never starts while a
  password submission is already in flight, so typing your password
  doesn't risk a fresh camera scan landing right as it succeeds.
- Before trusting Howdy as configured, the lock screen checks that
  `/etc/pam.d/omarchy-lock-howdy`, your enrolled face model, and
  `pam_howdy.so` are all root-owned and not group/world-writable — the
  same way it already trusts nothing it can't verify for fingerprint/PAM.
  Session code able to rewrite any of those could otherwise enroll a face
  everyone matches or swap in an auth module that always succeeds.
- If [Lock Screen Explorer](https://github.com/SirJul1337/omarchy-lock-explorer)
  is installed, its own `Service.qml` gets the same treatment via a second
  patcher tuned to its structure — see
  [Lock-screen replacement plugins](#lock-screen-replacement-plugins-lock-screen-explorer)
  below.

## Known rough edges

- `linux-enable-ir-emitter configure` doesn't manage to save anything on
  every camera — some just work under plain capture, and the tool's own
  "already working" pre-check exits non-zero for that. `setup` treats this as
  informational, not fatal.
- Omarchy is actively deciding between Howdy and other face-auth backends
  (see [basecamp/omarchy#5212](https://github.com/basecamp/omarchy/pull/5212)
  and [discussion #4982](https://github.com/basecamp/omarchy/discussions/4982)).
  This plugin exists so face unlock works today, independent of how that
  settles upstream.

## Lock-screen replacement plugins (Lock Screen Explorer)

Plugins that replace the lock screen entirely declare
`"omarchy": {"clonedFrom": "omarchy.lock"}` in their manifest. Enabling one
makes Omarchy disable the stock `omarchy.lock` service and load the
replacement's own `Service.qml` for the `lock` IPC target instead — Omarchy
only ever loads one `lock`-targeting service at a time, so whichever one
isn't currently enabled is dormant, patched or not.

[Lock Screen Explorer](https://github.com/SirJul1337/omarchy-lock-explorer)
(`io.github.sirjul1337.lock-explorer`) is one such plugin, and this project
now ships a second patcher, `patch-lock-howdy-explorer.py`, tuned to its
actual `Service.qml` structure (it's a large, single-file service with its
own avatar detection, clip-design wallpaper prep, boot-screen/Plymouth
integration, and a design/skin picker — the skins themselves are pure
display components with no auth logic of their own, so one patch target is
enough). `setup` runs it automatically, in addition to the stock patch,
whenever it finds Lock Screen Explorer installed at
`~/.config/omarchy/plugins/io.github.sirjul1337.lock-explorer/` —
regardless of which of the two is currently *enabled*, so Howdy is already
wired in however and whenever you switch between them. The post-update
hook and this plugin's own Service.qml watchdog both know how to check
whichever of the two files is actually active, the same way.

A few things worth knowing about this support:

- **It's non-fatal.** Lock Screen Explorer is a fast-moving third-party
  plugin outside this project's control, and its structure *will*
  eventually drift out from under `patch-lock-howdy-explorer.py`'s anchors
  (unlike the stock patch, which stays a hard failure — that's the
  primary, stable target). When that happens, `setup` prints a clear
  warning and continues with the rest of Howdy's install; it doesn't abort
  just because a bonus, independently-versioned integration went stale.
- **No automatic repair after `omarchy plugin update`.** That command (not
  `omarchy update`) is what pulls a new version of Lock Screen Explorer,
  and Omarchy has no post-plugin-update hook point today for this plugin
  to catch that with. The post-update hook (`omarchy update`) still
  opportunistically re-patches Explorer's file as a safety net, and this
  plugin's own Service.qml watchdog will notice and tell you to rerun
  `setup` by hand if a plugin update reverts it in between.
- **Tested by static patch application and code reading, not by enabling
  Lock Screen Explorer as the live lock screen.** The patch has been
  applied to Lock Screen Explorer's actual installed `Service.qml`,
  checked for idempotency (a second run no-ops) and brace/paren balance,
  and read through line by line to confirm the Howdy path doesn't collide
  with Explorer's own `authenticating` aggregate, its retry timers, or its
  IPC `status()` fields. It has not been verified against the live,
  enabled lock screen. If something doesn't work in practice, please open
  an issue.

## Tests

```sh
python3 -m unittest discover -s tests
qmllint Service.qml
bash -n modules/lock-screen.sh hooks/post-update.d/repair-howdy-lock.hook
```

Tests use temporary files and mocked IPC/privilege commands. They do not modify
the desktop, open the camera, or require sudo.
