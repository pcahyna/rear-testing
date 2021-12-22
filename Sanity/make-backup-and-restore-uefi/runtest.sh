#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/rear/Sanity/rear-basic
#   Description: Test basic functionality of REAR on systems with UEFI.
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
. /usr/bin/rhts-environment.sh || exit 1
. /usr/share/beakerlib/beakerlib.sh || exit 1

PACKAGE="rear"
# FIXME: Remove
ADDITONAL_PACKAGES=("grub2-efi-x64-modules" "syslinux-extlinux")

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

        # Sanity check
        rlPhaseStartSetup
            rlRun "ls /sys/firmware/ | grep efi" 0 "Check that we are on UEFI machine"
            if [ $? -eq 1 ]; then
                rlDie "Machine without UEFI"
            fi

            rlLog "Remove previous REAR boot entries"
            for entry in $(efibootmgr | grep REAR | cut -c 5-8); do
                rlRun "efibootmgr -b $entry -B" 0 "Removing entry $entry"
            done

            rlRun -l "efibootmgr | tee efibootmgr.bak" "Create efibootmgr.bak"
            OLD_BOOT_ORDER="$(grep '^BootOrder' efibootmgr.bak | cut -d: -f2)"

            rlLog "#######################################################"
            rlLog "#####                   WARNING!                  #####"
            rlLog "#######################################################"
            rlLog "Beware that the BootOrder EFI variable may contain     "
            rlLog "unexpected values if ReaR or any tool it depends on    "
            rlLog "does something unexpected!  In such case, fix it before"
            rlLog "the machine is returned back to Beaker, otherwise it   "
            rlLog "will be corrupted.                                     "
            rlLog "                                                       "
            rlLog "If you can boot to some working instance of RHEL, use  "
            rlLog "the following command to fix it:                       "
            rlLog "                                                       "
            rlLog "efibootmgr --bootorder '$OLD_BOOT_ORDER'               "
            rlLog "                                                       "
            rlLog "Otherwise, set it directly in the firmware to the      "
            rlLog "following value:                                       "
            rlLog "                                                       "
            rlLog "$OLD_BOOT_ORDER                                        "

            rlAssertExists efibootmgr.bak
            rlFileSubmit efibootmgr.bak
        rlPhaseEnd

        rlPhaseStartSetup
            rlFileBackup "/etc/rear/local.conf"
            rlRun "echo 'OUTPUT=USB
BACKUP=NETFS
BACKUP_URL=usb:///dev/disk/by-label/REAR-000
ISO_DEFAULT=automatic
ISO_RECOVER_MODE=unattended
USB_UEFI_PART_SIZE=500' | tee /etc/rear/local.conf" 0 "Create basic configuration file"
            rlAssertExists "/etc/rear/local.conf"
            rlRun "cat /etc/rear/local.conf"
        rlPhaseEnd

        rlPhaseStartSetup
            rlLog "Select device for REAR"

            # TODO: disk selection
            REAR_ROOT="/dev/sdb"

            rlLog "Selected $REAR_ROOT"
            rlRun "rear -v format -- -y --efi $REAR_ROOT" 0 "Partition and format $REAR_ROOT"

            rlRun -l "lsblk | tee drive_layout.old" 0 "Store lsblk output in recovery image"
            rlAssertExists drive_layout.old
        rlPhaseEnd

        rlPhaseStartTest
            rlRun "rear -v mkbackup" 0 "Creating backup to $REAR_ROOT"
        rlPhaseEnd

        rlPhaseStartSetup
            rlRun "touch recovery_will_remove_me" 0 "Create dummy file to be removed by recovery"
            rlAssertExists recovery_will_remove_me
        rlPhaseEnd

        rlPhaseStartSetup
            rlRun "efibootmgr --create --gpt --disk $REAR_ROOT --part 1 --write-signature --label REAR --loader '\EFI\BOOT\BOOTX64.efi'" 0 "Add REAR entry to EFI"

            OLD_BOOT_ORDER="$(grep '^BootOrder' efibootmgr.bak | cut -d: -f2)"
            rlRun "efibootmgr --bootorder '$OLD_BOOT_ORDER'" 0 "Restore old boot order"

            # will find BootXXXX* REAR
            REAR_BOOT_ENTRY="$(efibootmgr | grep REAR | cut -c 5-8)"
            rlRun "efibootmgr --bootnext '$REAR_BOOT_ENTRY'" \
                0 "Set next boot entry to $REAR_BOOT_ENTRY"
        rlPhaseEnd

        # TODO: this should be configurable in /etc/rear/local.conf!!!
        rlPhaseStartSetup
            rlRun "mount ${REAR_ROOT}1 /mnt" 0 "Mount ${REAR_ROOT}1"

            # TODO: Will this work with SecureBoot?
            # Grub uses different default boot entry:
            # set default="0" -> set default="1"
            rlRun "sed -i '/^[ ]*linux/ s/$/ unattended/' /mnt/EFI/BOOT/grub.cfg" 0 "Make the recovery unattended"
            rlRun "umount -R /mnt" 0 "Unmount ${REAR_ROOT}1"
        rlPhaseEnd

        # TODO: rhts-reboot sets BootNext
        reboot

    elif [ "$REBOOTCOUNT" -eq 1 ]; then
        # REAR hopefully recovered the OS
        rlPhaseStartTest
            rlAssertNotExists recovery_will_remove_me

            rlAssertExists drive_layout.old
            rlAssertExists /root/rear*.log

            rlRun -l "lsblk | tee drive_layout.new" 0 "Get current lsblk output"
            if ! rlAssertNotDiffer drive_layout.old drive_layout.new; then
                rlRun -l "diff -u drive_layout.old drive_layout.new" \
                    1 "Diff drive layout changes"
            fi

            rlFileSubmit /root/rear*.log
        rlPhaseEnd

        rlPhaseStartCleanup
            rlLog "Remove created REAR boot entries"
            for entry in $(efibootmgr | grep REAR | cut -c 5-8); do
                rlRun "efibootmgr -b $entry -B" 0 "Removing entry $entry"
            done

            OLD_BOOT_ORDER="$(grep '^BootOrder' efibootmgr.bak | cut -d: -f2)"
            rlRun -l "efibootmgr --bootorder '$OLD_BOOT_ORDER'" \
                0 "Restore old boot order"

            rlFileRestore
            rlRun "rm -f drive_layout.{old,new}" 0 "Remove lsblk outputs"
            rlRun "rm -f /root/rear*.log" 0 "Remove ReaR recovery log"
        rlPhaseEnd
    else
        rlDie "Only sensible reboot count is 0 or 1! Got: $REBOOTCOUNT"
    fi

rlJournalPrintText
rlJournalEnd
