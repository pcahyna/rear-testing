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

REBOOTCOUNT=${REBOOTCOUNT:-0}

PACKAGE="rear"
# FIXME: Remove
ADDITONAL_PACKAGES=("syslinux-extlinux" "syslinux-nonlinux" "xorriso" "snapper")

NFS_SERVER_IP=$(cat /etc/hosts | grep server | awk '{print $1}')

ROOT_PATH=$(grub2-mkrelpath /)
BOOT_PATH=$(grub2-mkrelpath /boot)
BOOT_FS_UUID=$(grub2-probe --target=fs_uuid /boot)
ROOT_FS_UUID=$(grub2-probe --target=fs_uuid /)
# BOOT_DRIVE=$(grub2-probe --target=drive /boot)
# ROOT_DRIVE=$(grub2-probe --target=drive /)


ROOT_DISK=$(df -hT | grep /$ | awk '{print $1}')

# REAR_ROOT="/root/rear"
REAR_ROOT=""
REAR_BIN="$REAR_ROOT/usr/sbin/rear"
#REAR_BIN="rear"
REAR_CONFIG="$REAR_ROOT/etc/rear/local.conf"
REAR_HOME_DIRECTORY="/root"
REAR_ISO_OUTPUT="/var/lib/rear/output"

HOST_NAME=$(hostname -s)

rlJournalStart

    if [ "$TMT_REBOOT_COUNT" -eq 0 ]; then
        # Phase to check rear existing
        rlPhaseStartSetup
            if ! rlCheckRpm "rear"; then
                rlDie "FATAL ERROR: rear hasn't been installed!"
            fi
        rlPhaseStartEnd

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
            rlRun "echo 'REQUIRED_PROGS+=( snapper chattr )
PROGS+=( ps lsblk sleep cat lsattr )
COPY_AS_IS+=( /usr/share/beakerlib ${TMT_PLAN_DATA/data/discover}/default/tests/Sanity/make-backup-and-restore-iso )
ISO_DEFAULT=manual
ISO_RECOVER_MODE=unattended
OUTPUT=ISO
BACKUP_URL=iso:///backup
USER_INPUT_TIMEOUT=10
OUTPUT_URL=null
BACKUP=NETFS
# 4gb backup limit
PRE_RECOVERY_SCRIPT=(\"mkdir /tmp/mnt;\" \"mount $ROOT_DISK /tmp/mnt/;\" \"modprobe brd rd_nr=1 rd_size=2097152;\" \"dd if=/tmp/mnt/$ROOT_PATH/var/lib/rear/output/rear-$HOST_NAME.iso of=/dev/ram0;\" \"umount /tmp/mnt/;\")
ISO_FILE_SIZE_LIMIT=4294967296' | tee $REAR_CONFIG" 0 "Creating basic configuration file"
            rlAssertExists "$REAR_CONFIG"
        rlPhaseEnd

        rlPhaseStartTest
            rlRun -l "lsblk | tee $REAR_HOME_DIRECTORY/drive_layout.old" 0 "Store lsblk output in recovery image"
            rlAssertExists $REAR_HOME_DIRECTORY/drive_layout.old
        rlPhaseEnd

        rlPhaseStartTest
            rlRun "export TMPDIR='/var/tmp'"
            rlRun "$REAR_BIN -v mkbackup" 0 "Creating backup to $REAR_ROOT"
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
            rlRun "echo 'search --no-floppy --fs-uuid --set=bootfs $BOOT_FS_UUID
search --no-floppy --fs-uuid --set=rootfs $ROOT_FS_UUID
terminal_input serial
terminal_output serial
menuentry \"ReaR-recover\" {
linux16 (\$bootfs)$BOOT_PATH/memdisk iso raw selinux=0 console=ttyS0,9600 console=tty0 auto_recover unattended
initrd16 (\$rootfs)$ROOT_PATH/$REAR_ISO_OUTPUT/small-rear.iso
}
set default=\"ReaR-recover\"' >> /boot/grub2/grub.cfg"
        rlPhaseEnd

       # rhts-reboot
       rlRun "tmt-reboot -t 900" 0 "Reboot the machine"
   elif [ "$TMT_REBOOT_COUNT" -eq 1 ]; then
        # REAR hopefully recovered the OS
        rlRun "rear -D recover &"
        for i in {1..30}; do
            rlRun "sleep 2"
            rlRun "ps -e | grep -i rear"
            rlRun "lsblk -f"
            rlRun "cat /var/log/rear/rear*.log"
        done
        rlRun "dmesg"
        rlDie "Done"
    else
        rlDie "Only sensible reboot count is 0 or 1! Got: $REBOOTCOUNT"
    fi

rlJournalPrintText
rlJournalEnd
