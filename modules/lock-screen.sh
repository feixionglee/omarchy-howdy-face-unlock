#!/bin/bash
# Howdy integration module: Omarchy lock screen.
#
# Owns the dedicated lock-screen PAM service, the stock/Explorer QML patches,
# and the post-update repair hook. setup/remove source this file and invoke the
# module entry points; the implementation is kept out of the orchestrators.

configure_lock_screen_integration() {
  echo -e "\nConfiguring lock screen for Howdy authentication...\n"
sudo tee "$PAM_HOWDY" >/dev/null <<'EOF'
#%PAM-1.0
auth       required                    pam_howdy.so
account    include                     system-local-login
EOF

# Patch the lock plugin to run Howdy as its own path, parallel to (and
# independent of) fingerprint's. `omarchy update` overwrites this file since
# it's package-owned, so this step is designed to be safely rerun -- it
# no-ops once the patch is already present, and reapplies cleanly if an
# update wiped it. This plugin's Service.qml notices that and tells you to
# rerun this script when it happens.
if ! grep -q 'omarchy-lock-howdy' "$LOCK_QML"; then
  echo "Patching lock screen plugin for Howdy..."
  [[ -f $LOCK_QML_ORIG ]] || sudo cp -a "$LOCK_QML" "$LOCK_QML_ORIG"
  # Patch an unprivileged temporary copy, then use sudo only for the final
  # install. This avoids executing plugin-provided Python as root entirely.
  scratch_dir=$(mktemp -d)
  cp "$LOCK_QML" "$scratch_dir/Service.qml"
  if ! python3 "$root/patch-lock-howdy.py" "$scratch_dir/Service.qml"; then
    rm -rf "$scratch_dir"
    echo -e "\e[31mCould not patch the current lock Service.qml.\e[0m" >&2
    echo -e "\e[31mIf this machine has an older/manual face-auth modification, restore the\e[0m" >&2
    echo -e "\e[31mstock Omarchy lock file first, then rerun setup. Existing custom auth\e[0m" >&2
    echo -e "\e[31mcode is deliberately not merged automatically.\e[0m" >&2
    exit 1
  fi
  sudo install -o root -g root -m 644 "$scratch_dir/Service.qml" "$LOCK_QML"
  rm -rf "$scratch_dir"
  omarchy-restart-shell
fi

# Lock Screen Explorer (io.github.sirjul1337.lock-explorer) is a
# `clonedFrom: omarchy.lock` replacement -- when it's enabled, Omarchy
# disables the stock lock plugin patched above and loads Explorer's own
# Service.qml for the `lock` IPC target instead (see the README's
# "Lock-screen replacement plugins" section, and issue #1). Patch its copy
# too, whenever it's installed, regardless of whether
# it's the currently *enabled* target -- so Howdy is already wired in
# however and whenever the user switches between the two.
#
# Unlike the stock file above, Explorer's Service.qml lives in the user's
# own plugin checkout (~/.config/omarchy/plugins/...), not a package-owned
# system path -- the invoking user already owns it outright, so patching it
# doesn't cross a privilege boundary the way writing to /usr/share/omarchy
# does. That's why this step runs the patcher directly instead of the
# root-owned-scratch-dir-plus-hash-verification dance above: that dance
# defends against a warm sudo timestamp being used to run tampered bytes
# as root. With no privilege escalation here, anyone who could tamper with
# this patcher could equally tamper with anything else this user's own
# shell already trusts (~/.bashrc and so on) -- the extra ceremony
# wouldn't buy anything real.
#
# Also unlike the stock step, a failure here does NOT abort setup: Lock
# Screen Explorer is a fast-moving third-party plugin outside this
# project's control, and its structure *will* eventually drift out from
# under patch-lock-howdy-explorer.py's anchors (see that file's
# docstring). When that happens, the rest of Howdy's install (packages,
# camera, enrollment, the stock lock patch, the auto-repair hook) should
# still succeed -- Explorer compatibility is a bonus, not a precondition.
EXPLORER_QML="$HOME/.config/omarchy/plugins/io.github.sirjul1337.lock-explorer/Service.qml"
EXPLORER_QML_ORIG="$EXPLORER_QML.orig"
if [[ -f $EXPLORER_QML ]] && ! grep -q 'omarchy-lock-howdy' "$EXPLORER_QML"; then
  echo "Lock Screen Explorer detected -- patching its lock screen for Howdy too..."
  [[ -f $EXPLORER_QML_ORIG ]] || cp -a "$EXPLORER_QML" "$EXPLORER_QML_ORIG"
  if python3 "$root/patch-lock-howdy-explorer.py" "$EXPLORER_QML"; then
    echo "Patched Lock Screen Explorer's lock screen for Howdy."
  else
    echo -e "\e[33mCouldn't patch Lock Screen Explorer's Service.qml (its structure may have\e[0m"
    echo -e "\e[33mchanged upstream) -- continuing without Explorer support. Howdy still works\e[0m"
    echo -e "\e[33mwith the stock lock screen. See this plugin's README for details.\e[0m"
  fi
fi

# Tell the user which of the two patched files is actually live right now
# -- Omarchy only loads one `lock`-targeting service at a time, so whichever
# one isn't currently enabled is patched-but-dormant until they switch.
if [[ -f $EXPLORER_QML ]] && command -v omarchy >/dev/null 2>&1; then
  explorer_active=$(omarchy plugin list --json 2>/dev/null | python3 -c '
import json, sys
try:
    plugins = json.load(sys.stdin)
except Exception:
    plugins = []
print("yes" if any(p.get("id") == "io.github.sirjul1337.lock-explorer" and p.get("enabled") for p in plugins) else "no")
' 2>/dev/null)
  if [[ $explorer_active == yes ]]; then
    echo -e "\e[33mNote: Lock Screen Explorer is currently enabled, so it -- not the stock\e[0m"
    echo -e "\e[33mlock screen -- is what actually runs when you lock. Howdy's patch to\e[0m"
    echo -e "\e[33mExplorer's own Service.qml (above) is what's live; the stock patch is\e[0m"
    echo -e "\e[33mdormant until you disable Explorer.\e[0m"
  fi
fi

# lock/Service.qml is package-owned, so `omarchy update` can silently revert
# the patch above. Install a post-update hook that re-patches it automatically,
# in the same `omarchy update` run, while pacman's sudo authorization is still
# warm -- so face unlock survives an update without the user having to notice
# a notification and rerun this script by hand. Idempotent: reinstalling just
# overwrites the same file.
if command -v omarchy >/dev/null 2>&1; then
  omarchy hook install post-update "$root/hooks/post-update.d/repair-howdy-lock.hook"
else
  echo -e "\e[33mCouldn't find 'omarchy' to install the auto-repair hook -- \e[0m"
  echo -e "\e[33myou'll need to rerun this script by hand after updates instead.\e[0m"
fi

}

remove_lock_screen_integration() {
if [[ -f $PAM_HOWDY ]]; then
  echo "Removing lock screen Howdy authentication..."
  sudo rm -f "$PAM_HOWDY"
fi

if [[ -f $POST_UPDATE_HOOK ]]; then
  echo "Removing post-update auto-repair hook..."
  rm -f "$POST_UPDATE_HOOK"
fi

if [[ -f $LOCK_QML_ORIG ]]; then
  echo "Restoring the original lock screen plugin..."
  sudo install -o root -g root -m 644 "$LOCK_QML_ORIG" "$LOCK_QML"
  sudo rm -f "$LOCK_QML_ORIG"
  omarchy-restart-shell
elif grep -q 'omarchy-lock-howdy' "$LOCK_QML" 2>/dev/null; then
  echo -e "\e[31mNo pristine backup found (Service.qml.orig) but the lock plugin"
  echo -e "still looks patched -- leaving it alone rather than guessing at a"
  echo -e "revert. An 'omarchy update' will overwrite it back to stock.\e[0m"
fi

if [[ -f $EXPLORER_QML_ORIG ]]; then
  echo "Restoring Lock Screen Explorer's original lock screen..."
  cp -a "$EXPLORER_QML_ORIG" "$EXPLORER_QML"
  rm -f "$EXPLORER_QML_ORIG"
  # Unlike the stock file, no restart here: this file is only ever live
  # while Lock Screen Explorer is enabled, and forcing a shell restart on
  # every plugin removal for a file that's usually dormant isn't worth the
  # disruption. It picks up on the next restart either way.
elif grep -q 'omarchy-lock-howdy' "$EXPLORER_QML" 2>/dev/null; then
  echo -e "\e[31mNo pristine backup found for Lock Screen Explorer's Service.qml but it"
  echo -e "still looks patched -- leaving it alone rather than guessing at a revert.\e[0m"
fi


}

setup_lock_screen_module() {
  configure_lock_screen_integration
}

remove_lock_screen_module() {
  remove_lock_screen_integration
}
