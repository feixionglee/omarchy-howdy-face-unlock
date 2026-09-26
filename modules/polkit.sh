#!/bin/bash
# Howdy integration module: Polkit/PAM desktop authentication.
# Arch ships the vendor PAM service in /usr/lib/pam.d. A file in /etc/pam.d
# is the administrator override, so never edit the package-owned vendor file.

HOWDY_POLKIT_VENDOR_PAM="/usr/lib/pam.d/polkit-1"
HOWDY_POLKIT_PAM="/etc/pam.d/polkit-1"
HOWDY_POLKIT_BACKUP="/etc/pam.d/polkit-1.howdy-face-unlock.orig"
HOWDY_POLKIT_MARKER="# Managed by io.github.feixionglee.howdy-face-unlock"

setup_polkit_module() {
  echo -e "\nConfiguring Polkit for Howdy authentication...\n"

  if [[ ! -f $HOWDY_POLKIT_VENDOR_PAM && ! -f $HOWDY_POLKIT_PAM ]]; then
    echo -e "\e[33mSkipping Polkit integration: no polkit-1 PAM service was found.\e[0m"
    return 0
  fi

  if [[ -f $HOWDY_POLKIT_PAM ]] && grep -q 'pam_howdy\.so' "$HOWDY_POLKIT_PAM"; then
    echo "Polkit already has Howdy authentication configured."
    return 0
  fi

  if [[ -f $HOWDY_POLKIT_PAM ]]; then
    [[ -f $HOWDY_POLKIT_BACKUP ]] || sudo cp -a "$HOWDY_POLKIT_PAM" "$HOWDY_POLKIT_BACKUP"
  else
    sudo cp -a "$HOWDY_POLKIT_VENDOR_PAM" "$HOWDY_POLKIT_PAM"
  fi

  local tmp
  tmp=$(mktemp)
  awk -v marker="$HOWDY_POLKIT_MARKER" '
    !done && /^[[:space:]]*auth[[:space:]]+include[[:space:]]+system-auth([[:space:]]|$)/ {
      print marker
      print "auth       sufficient   pam_howdy.so"
      done=1
    }
    { print }
    END {
      if (!done) exit 42
    }
  ' "$HOWDY_POLKIT_PAM" > "$tmp" || {
    rm -f "$tmp"
    echo -e "\e[31mCould not find the expected system-auth line in $HOWDY_POLKIT_PAM; Polkit integration was not changed.\e[0m" >&2
    if [[ ! -f $HOWDY_POLKIT_BACKUP ]]; then sudo rm -f "$HOWDY_POLKIT_PAM"; fi
    return 1
  }
  sudo install -o root -g root -m 644 "$tmp" "$HOWDY_POLKIT_PAM"
  rm -f "$tmp"
  echo "Polkit authentication now tries Howdy first, with system-auth as fallback."
}

remove_polkit_module() {
  if [[ -f $HOWDY_POLKIT_BACKUP ]]; then
    echo "Restoring the pre-existing Polkit PAM override..."
    sudo install -o root -g root -m 644 "$HOWDY_POLKIT_BACKUP" "$HOWDY_POLKIT_PAM"
    sudo rm -f "$HOWDY_POLKIT_BACKUP"
  elif [[ -f $HOWDY_POLKIT_PAM ]] && grep -qF "$HOWDY_POLKIT_MARKER" "$HOWDY_POLKIT_PAM"; then
    echo "Removing the plugin-created Polkit PAM override..."
    sudo rm -f "$HOWDY_POLKIT_PAM"
  elif grep -q 'pam_howdy\.so' "$HOWDY_POLKIT_PAM" 2>/dev/null; then
    echo -e "\e[33mPolkit has Howdy configuration not marked as plugin-managed; leaving it alone.\e[0m"
  fi
}
