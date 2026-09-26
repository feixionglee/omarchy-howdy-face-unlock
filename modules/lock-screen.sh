#!/bin/bash
# Howdy integration module: Omarchy lock screen.
#
# The implementation remains in setup/remove because it patches both the stock
# Omarchy lock service and optional replacement lock plugins. These entry points
# make the integration an explicit module alongside sudo and Polkit, while
# preserving the existing, well-tested patch/repair path.

setup_lock_screen_module() {
  configure_lock_screen_integration
}

remove_lock_screen_module() {
  remove_lock_screen_integration
}
