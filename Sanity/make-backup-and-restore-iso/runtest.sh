#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/rear/Sanity/make-backup-and-restore-bios
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

PACKAGES="rear syslinux-extlinux syslinux-nonlinux xorriso"

ROOT_DISK=$(df -hT | grep /$ | awk '{print $1}')

REAR_BIN="/usr/sbin/rear"
REAR_CONFIG="/etc/rear/local.conf"
REAR_HOME_DIRECTORY="/root"
REAR_ISO_OUTPUT="/var/lib/rear/output"

HOST_NAME=$(hostname -s)

rlJournalStart
    if [ "$REBOOTCOUNT" -eq 0 ]; then
        # Fresh start
        rlPhaseStartSetup
            rlAssertRpm --all
        rlPhaseEnd

        rlPhaseStartSetup
            rlFileBackup "$REAR_CONFIG"
            rlRun "echo 'OUTPUT=ISO
USER_INPUT_TIMEOUT=10
BACKUP=NETFS
BACKUP_URL=iso:///backup
OUTPUT_URL=null
# 4gb backup limit
PRE_RECOVERY_SCRIPT=(\"mkdir /tmp/mnt;\" \"mount $ROOT_DISK /tmp/mnt/;\" \"modprobe brd rd_nr=1 rd_size=2097152;\" \"dd if=/tmp/mnt/var/lib/rear/output/rear-$HOST_NAME.iso of=/dev/ram0;\" \"umount /tmp/mnt/;\")
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
            rlRun "$REAR_BIN -d mkbackup" 0 "Creating backup to $REAR_ISO_OUTPUT"
            rlFileSubmit /var/log/rear/rear*.log rear-mkbackup.log
            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: $REAR_BIN -d mkbackup failed. See rear-mkbackup.log for details."
            fi
        rlPhaseEnd

        rlPhaseStartSetup
            rlRun "touch recovery_will_remove_me" 0 "Create dummy file to be removed by recovery"
            rlAssertExists recovery_will_remove_me
        rlPhaseEnd

        rlPhaseStartSetup
            rlLog "Make small iso file that is bootable by memdisk"
            rlRun "xorriso -as mkisofs -r -V 'REAR-ISO' -J -J -joliet-long -cache-inodes -b isolinux/isolinux.bin -c isolinux/boot.cat -boot-load-size 4 -boot-info-table -no-emul-boot -eltorito-alt-boot -dev $REAR_ISO_OUTPUT/rear-$HOST_NAME.iso -o $REAR_ISO_OUTPUT/small-rear.iso -- -rm_r backup"
        rlPhaseEnd


        rlPhaseStartSetup
            rlLog "Setup Boot"
            rlLog "Copying memdisk"
            rlRun "cp /usr/share/syslinux/memdisk /boot/"
            rlLog "Setup GRUB"
            rlRun "echo 'menuentry \"ReaR-recover\" {
linux16 (hd0,msdos1)/memdisk iso raw selinux=0 console=ttyS0,9600 console=tty0 auto_recover unattended
initrd16 (hd0,msdos2)$REAR_ISO_OUTPUT/small-rear.iso
}
set default=\"ReaR-recover\"' >> /boot/grub2/grub.cfg"
        rlPhaseEnd

        rhts-reboot

    elif [ "$REBOOTCOUNT" -eq 1 ]; then
        # REAR hopefully recovered the OS
        rlPhaseStartTest
            rlAssertNotExists $REAR_HOME_DIRECTORY/recovery_will_remove_me

            rlAssertExists $REAR_HOME_DIRECTORY/drive_layout.old
            rlAssertExists $REAR_HOME_DIRECTORY/rear*.log

            rlRun -l "lsblk | tee $REAR_HOME_DIRECTORY/drive_layout.new" 0 "Get current lsblk output"
            if ! rlAssertNotDiffer $REAR_HOME_DIRECTORY/drive_layout.old $REAR_HOME_DIRECTORY/drive_layout.new; then
                rlRun -l "diff -u $REAR_HOME_DIRECTORY/drive_layout.old $REAR_HOME_DIRECTORY/drive_layout.new" \
                    1 "Diff drive layout changes"
            fi

            rlFileSubmit $REAR_HOME_DIRECTORY/rear*.log rear-recover.log
        rlPhaseEnd

        rlPhaseStartCleanup
            rlFileRestore
            rlRun "rm -f $REAR_HOME_DIRECTORY/drive_layout.{old,new}" 0 "Remove lsblk outputs"
            rlRun "rm -f $REAR_HOME_DIRECTORY/rear*.log" 0 "Remove ReaR recovery log"
        rlPhaseEnd

    else
        rlDie "Only sensible reboot count is 0 or 1! Got: $REBOOTCOUNT"
    fi

rlJournalPrintText
rlJournalEnd
