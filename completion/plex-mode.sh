#!/bin/bash
# install the command itself (since /usr/local is RAM)
install -D -m 0755 /boot/config/custom/bin/plex-mode /usr/local/sbin/plex-mode

# install completion and make sure bash-completion is sourced
install -D -m 0644 /boot/config/custom/bash-completion/plex-mode /etc/bash_completion.d/plex-mode
grep -q '/etc/bash_completion' /root/.bashrc 2>/dev/null || echo '[ -f /etc/bash_completion ] && . /etc/bash_completion' >> /root/.bashrc
