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
. /usr/bin/rhts-environment.sh || exit 1
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
            rlFileBackup "/etc/rear/local.conf"
            rlRun "echo 'OUTPUT=USB
BACKUP=NETFS
BACKUP_URL=usb:///dev/disk/by-label/REAR-000
ISO_DEFAULT=automatic
ISO_RECOVER_MODE=unattended' | tee /etc/rear/local.conf" 0 "Creating basic configuration file"
            rlAssertExists "/etc/rear/local.conf"
        rlPhaseEnd

        rlPhaseStartSetup
            rlLog "Select device for REAR"

            # TODO: does not work due to bug in anaconda (and would be unreliable either way)
            # for dev in $(lsblk -o name -lpn); do
            #     if [[ "$(grub2-probe --target=drive --device "$dev")" = "(hd1)" ]]; then
            #         REAR_ROOT="$dev"
            #     fi
            # done
            # if [[ -z "$REAR_ROOT" ]]; then
            #     rlDie "This machine does not have a usable disk"
            # else
            #     rlLog "Selected $REAR_ROOT"
            # fi
            REAR_ROOT=/dev/vdb

            rlLog "Selected $REAR_ROOT"
            rlRun "rear -v format -- -y $REAR_ROOT" 0 "Partition and format $REAR_ROOT"
            rlRun "lsblk | tee drive_layout" 0 "Store lsblk output in recovery image"
            rlAssertExists drive_layout
        rlPhaseEnd

        rlPhaseStartTest
            rlRun "rear -v mkbackup" 0 "Creating backup to $REAR_ROOT"
        rlPhaseEnd

        rlPhaseStartSetup
            rlRun "touch recovery_will_remove_me" 0 "Create dummy file to be removed by recovery"
            rlAssertExists recovery_will_remove_me
        rlPhaseEnd

        rlPhaseStartSetup
            rlLog "Add REAR entry to GRUB 2"
            rlRun "echo 'menuentry \"REAR\" {
    drivemap --swap hd0 hd1
    chainloader (hd1)+1
    boot
}' >> /etc/grub.d/40_custom"
            rlAssertExists "/etc/grub.d/40_custom"
            rlRun "chmod u+x /etc/grub.d/40_custom"
            rlRun "cat /etc/grub.d/40_custom"
            rlRun "grub2-mkconfig -o /boot/grub2/grub.cfg"
            rlRun "grub2-set-default REAR"
            rlRun "grub2-editenv list | grep 'saved_entry=REAR' > /dev/null"
        rlPhaseEnd

        # TODO: should be configurable in /etc/rear/local.conf!!!
        rlPhaseStartSetup
            rlLog "Make REAR autoboot to unattended recovery"
            rlRun "mkdir /mnt/rear" 0 "Make /mnt/rear"
            rlRun "mount ${REAR_ROOT}1 /mnt/rear" 0 "Mount REAR partition"
            rlRun "sed -i '/^ontimeout/d' /mnt/rear/boot/syslinux/extlinux.conf" 0 "Disable hd1 autoboot on timeout"

            HOSTNAME_SHORT=$(hostname --short)
            rlRun "sed -i '/^menu begin/i default $HOSTNAME_SHORT' /mnt/rear/rear/syslinux.cfg" 0 "Set recovery menu as default boot target"
            rlRun "sed -i '1idefault rear-unattended' /mnt/rear/rear/$HOSTNAME_SHORT/*/syslinux.cfg" 0 "Set latest backup as default boot target (1/2)"
            rlRun "sed -z -i 's/label[^\n]*\(\n[^\n]*AUTOMATIC\)/label rear-unattended\1/' /mnt/rear/rear/$HOSTNAME_SHORT/*/syslinux.cfg" 0 "Set latest backup as default boot target (2/2)"
            rlRun "sed -i 's/auto_recover/unattended/' /mnt/rear/rear/$HOSTNAME_SHORT/*/syslinux.cfg" 0 "Pass 'unattended' to kernel command-line"
            rlRun "umount -R /mnt/rear" 0 "Unmount REAR partition"
        rlPhaseEnd

        rhts-reboot

    elif [ "$REBOOTCOUNT" -eq 1 ]; then
        # REAR hopefully recovered the OS
        rlPhaseStartTest
            rlAssertNotExists recovery_will_remove_me
            rlAssertExists drive_layout
            rlRun "lsblk | tee drive_layout.new" 0 "Get current lsblk output"
            rlAssertNotDiffer drive_layout drive_layout.new
        rlPhaseEnd

        rlPhaseStartCleanup
            rlFileRestore
            rlRun "rm -f drive_layout{,.new}" 0 "Remove lsblk outputs"
        rlPhaseEnd

    else
        rlDie "Only sensible reboot count is 0 or 1! Got: $REBOOTCOUNT"
    fi

rlJournalPrintText
rlJournalEnd
