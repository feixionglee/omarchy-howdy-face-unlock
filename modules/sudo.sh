#!/bin/bash
# Howdy integration module: sudo authentication.

HOWDY_SUDO_PAM="/etc/pam.d/sudo"
HOWDY_SUDO_BACKUP="/etc/pam.d/sudo.howdy-face-unlock.orig"

setup_sudo_module() {
  echo -e "\nConfiguring sudo for Howdy authentication...\n"

  if [[ ! -f $HOWDY_SUDO_PAM ]]; then
    echo -e "\e[33mSkipping sudo integration: $HOWDY_SUDO_PAM does not exist.\e[0m"
    return 0
  fi

  if grep -Eq '^[[:space:]]*auth[[:space:]]+(sufficient|required)[[:space:]]+pam_howdy\.so([[:space:]]|$)' "$HOWDY_SUDO_PAM"; then
    echo "sudo already has Howdy authentication configured."
    return 0
  fi

  [[ -f $HOWDY_SUDO_BACKUP ]] || sudo cp -a "$HOWDY_SUDO_PAM" "$HOWDY_SUDO_BACKUP"

  local tmp
  tmp=$(mktemp)
  awk '
    !done && /^[[:space:]]*auth[[:space:]]/ {
      print "auth            sufficient      pam_howdy.so"
      done=1
    }
    { print }
    END {
      if (!done) exit 42
    }
  ' "$HOWDY_SUDO_PAM" > "$tmp" || {
    rm -f "$tmp"
    echo -e "\e[31mCould not find an auth line in $HOWDY_SUDO_PAM; sudo integration was not changed.\e[0m" >&2
    return 1
  }
  sudo install -o root -g root -m 644 "$tmp" "$HOWDY_SUDO_PAM"
  rm -f "$tmp"
  echo "sudo authentication now tries Howdy first, with the existing PAM stack as fallback."
}

remove_sudo_module() {
  if [[ -f $HOWDY_SUDO_BACKUP ]]; then
    echo "Restoring sudo PAM configuration..."
    sudo install -o root -g root -m 644 "$HOWDY_SUDO_BACKUP" "$HOWDY_SUDO_PAM"
    sudo rm -f "$HOWDY_SUDO_BACKUP"
  elif grep -q 'pam_howdy\.so' "$HOWDY_SUDO_PAM" 2>/dev/null; then
    echo -e "\e[33mNo plugin-created sudo backup found; leaving the existing Howdy sudo configuration alone.\e[0m"
  fi
}
