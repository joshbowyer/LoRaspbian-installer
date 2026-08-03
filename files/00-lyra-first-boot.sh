#!/bin/sh
# Triggers the interactive first-boot wizard on the first interactive login
# (SSH or console) after boot. Harmless no-op once /etc/lyra-first-boot-done
# exists. Runs as the logging-in user (needs sudo for the wizard's systemctl/
# netplan calls, which it invokes itself with sudo where needed - but this
# hook is intended for a user who has sudo, e.g. "lyra").
if [ ! -f /etc/lyra-first-boot-done ] && [ -t 0 ]; then
    sudo /usr/local/sbin/lyra-first-boot-wizard.sh
fi
