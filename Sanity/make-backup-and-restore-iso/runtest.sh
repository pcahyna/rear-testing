#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/rear/Sanity/rear-basic
#   Description: Test basic functionality of REAR on systems with BIOS.
#   Author: Lukas Zaoral <lzaoral@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2021 Red Hat, Inc.
#
#   This program is free software: you can redistribute it and/or
#   modify it under the terms of the GNU General Public License as
#   published by the Free Software Foundation, either version 2 of
#   the License, or (at your option) any later version.
#
#   This program is distributed in the hope that it will be
#   useful, but WITHOUT ANY WARRANTY; without even the implied
#   warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
#   PURPOSE.  See the GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program. If not, see http://www.gnu.org/licenses/.
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

# Include Beaker environment
. /usr/share/beakerlib/beakerlib.sh || exit 1

PACKAGE="rear"
# FIXME: Remove
ADDITONAL_PACKAGES=("syslinux-extlinux")

REAR_BIN="/usr/sbin/rear"
REAR_CONFIG="/etc/rear/local.conf"
REAR_HOME_DIRECTORY="/root"

rlJournalStart
    if [ "$REBOOTCOUNT" -eq 0 ]; then
        # Fresh start
        rlPhaseStartSetup
            rlAssertRpm $PACKAGE
            rlRun "dnf install -y ${ADDITONAL_PACKAGES[*]}" 0 "Install ${ADDITONAL_PACKAGES[*]}"
            for p in "${ADDITONAL_PACKAGES[@]}"; do
                rlAssertRpm "$p"
            done
        rlPhaseEnd

        rlPhaseStartSetup
            rlFileBackup "$REAR_CONFIG"
            rlRun "echo 'OUTPUT=ISO
USER_INPUT_TIMEOUT=10
BACKUP=NETFS
BACKUP_URL=iso:///backup
OUTPUT_URL=null
# 4gb backup limit
PRE_RECOVERY_SCRIPT=(\"mkdir /tmp/mnt;\" \"mount /dev/vda2 /tmp/mnt/;\" \"modprobe loop;\" \"dd if=/tmp/mnt/root/rear/var/lib/rear/output/rear-fedora.iso of=/dev/cdrom;\" \"umount /tmp/mnt/;\")
ISO_FILE_SIZE_LIMIT=4294967296
ISO_DEFAULT=automatic
ISO_RECOVER_MODE=unattended' | tee $REAR_CONFIG" 0 "Creating basic configuration file"
            rlAssertExists "$REAR_CONFIG"
        rlPhaseEnd

        rlPhaseStartTest
            rlRun -l "lsblk | tee $REAR_HOME_DIRECTORY/drive_layout.old" 0 "Store lsblk output in recovery image"
            rlAssertExists $REAR_HOME_DIRECTORY/drive_layout.old
        rlPhaseEnd

        rlPhaseStartTest
            rlRun "$REAR_BIN -v mkbackup" 0 "Creating backup to $REAR_ROOT"
        rlPhaseEnd

        rlPhaseStartSetup
            rlRun "touch recovery_will_remove_me" 0 "Create dummy file to be removed by recovery"
            rlAssertExists recovery_will_remove_me
        rlPhaseEnd

        rlPhaseStartSetup
            rlLog "Setup GRUB"
            rlRun "echo 'menuentry \"ReaR-recover\" {
  loopback loop (hd0,msdos2)/root/rear/var/lib/rear/output/rear-fedora.iso
  linux (loop)/isolinux/kernel rw selinux=0 console=ttyS0,9600 console=tty0 auto_recover unattended
  initrd (loop)/isolinux/initrd.cgz
}
set default=\"ReaR-recover\"' >> /boot/grub2/grub.cfg"
        rlPhaseEnd

        rhts-reboot

    elif [ "$REBOOTCOUNT" -eq 1 ]; then
        # REAR hopefully recovered the OS
        rlPhaseStartTest
            rlAssertNotExists $REAR_HOME_DIRECTORY/recovery_will_remove_me
            rlAssertExists $REAR_HOME_DIRECTORY/drive_layout.old
            rlRun "lsblk | tee $REAR_HOME_DIRECTORY/drive_layout.new" 0 "Get current lsblk output"
            rlAssertNotDiffer $REAR_HOME_DIRECTORY/drive_layout.old $REAR_HOME_DIRECTORY/drive_layout.new
        rlPhaseEnd

        rlPhaseStartCleanup
            rlFileRestore
            rlRun "rm -f $REAR_HOME_DIRECTORY/drive_layout{,.new}" 0 "Remove lsblk outputs"
        rlPhaseEnd

    else
        rlDie "Only sensible reboot count is 0 or 1! Got: $REBOOTCOUNT"
    fi

rlJournalPrintText
rlJournalEnd
