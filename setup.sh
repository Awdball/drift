#!/bin/sh
set -e

# Sysinit runlevel
rc-update add sysfs sysinit
rc-update add devfs sysinit
rc-update add dmesg sysinit
rc-update add udev sysinit
rc-update add udev-trigger sysinit
rc-update add udev-settle sysinit
rc-update add cgroups sysinit

# Boot runlevel (Storage & Network come up BEFORE default daemons)
rc-update add hwclock boot
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add syslog boot
rc-update add networking boot
rc-update add seedrng boot
rc-update add zfs-import boot
rc-update add zfs-mount boot

# Default runlevel (NFS Server, SSH, Netboot HA, and Talos KVM VM)
rc-update add udev-postmount default
rc-update add acpid default
rc-update add crond default
rc-update add openntpd default
rc-update add sshd default
rc-update add rpcbind default
rc-update add nfs default
rc-update add keepalived default
rc-update add in.tftpd default
rc-update add darkhttpd default
rc-update add talos-vm default

# Shutdown runlevel
rc-update add killprocs shutdown
rc-update add mount-ro shutdown

# Ensure required runtime directories and permissions exist
mkdir -p /boot/efi /var/lib/nfs /var/log /tmp /run /tftpboot /var/www/localhost/htdocs
chmod 600 /etc/ssh/ssh_host_ed25519_key
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys
chmod +x /etc/init.d/talos-vm

