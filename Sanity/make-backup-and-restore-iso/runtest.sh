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

PACKAGES="rear syslinux-extlinux"

REAR_BIN="/usr/sbin/rear"
REAR_CONFIG="/etc/rear/local.conf"
REAR_HOME_DIRECTORY="/root"

rlJournalStart
    if [ "$REBOOTCOUNT" -eq 0 ]; then
        # Fresh start
        rlPhaseStartSetup
            rlAssertRpm --all
        rlPhaseEnd

        rlPhaseStartSetup
            rlFileBackup "$REAR_CONFIG"
            rlRun "echo 'OUTPUT=USB
BACKUP=NETFS
BACKUP_URL=usb:///dev/disk/by-label/REAR-000
ISO_DEFAULT=automatic
ISO_RECOVER_MODE=unattended' | tee $REAR_CONFIG" 0 "Creating basic configuration file"
            rlAssertExists "$REAR_CONFIG"
        rlPhaseEnd

        rlPhaseStartTest
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
            if [ "$(systemd-detect-virt)" = "kvm" ]; then
                REAR_ROOT=/dev/vdb
            else
                REAR_ROOT=/dev/sdb
            fi

            rlLog "Selected $REAR_ROOT"
            rlRun "$REAR_BIN -d format -- -y $REAR_ROOT" 0 "Partition and format $REAR_ROOT"
            rlFileSubmit /var/log/rear/rear*.log rear-format.log
            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: $REAR_BIN -d format -- -y $REAR_ROOT failed. See rear-format.log for details."
            fi

            rlRun -l "lsblk | tee $REAR_HOME_DIRECTORY/drive_layout.old" 0 "Store lsblk output in recovery image"
            rlAssertExists $REAR_HOME_DIRECTORY/drive_layout.old
        rlPhaseEnd

        rlPhaseStartTest
            rlRun "$REAR_BIN -d mkbackup" 0 "Creating backup to $REAR_ROOT"
            rlFileSubmit /var/log/rear/rear*.log rear-mkbackup.log
            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: $REAR_BIN -d mkbackup failed. See rear-mkbackup.log for details."
            fi
        rlPhaseEnd

        rlPhaseStartSetup
            rlRun "touch recovery_will_remove_me" 0 "Create dummy file to be removed by recovery"
            rlAssertExists recovery_will_remove_me
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

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: failed to make the recovery unattended"
            fi
        rlPhaseEnd

        # Use extlinux to chainload ReaR instead of GRUB as that did not work
        # on some systems.
        rlPhaseStartSetup
            ROOT_DEVICE="$(lsblk -no pkname "$(df --output=source /boot | tail -n1)")"
            KERNEL_VERSION="$(uname -r)"
            KERNEL_CMDLINE="$(grub2-editenv list | grep kernelopts | cut -d= -f2-)"
            SERIAL_DEVICE="$(sed -e 's/.*console=ttyS\([^ ]*\).*/\1/' \
                             <<< "$KERNEL_CMDLINE" | tr ',' ' ')"
            rlRun "extlinux --install /boot/extlinux" \
                 0 "Install extlinux to chainload ReaR"
            rlRun "echo 'SERIAL $SERIAL_DEVICE
UI menu.c32
PROMPT 0

MENU TITLE ReaR Chainload Boot Menu
TIMEOUT 50

LABEL linux
    MENU LABEL RHEL
    LINUX ../vmlinuz-$KERNEL_VERSION
    APPEND $KERNEL_CMDLINE
    INITRD ../initramfs-$KERNEL_VERSION.img

LABEL rear
    MENU LABEL Chainload ReaR from hd1
    MENU DEFAULT
    COM32 chain.c32
    APPEND hd1' | tee /boot/extlinux/extlinux.conf" \
                0 "Save extlinux configuration"
            rlRun "cat /usr/share/syslinux/mbr.bin > /dev/$ROOT_DEVICE" \
                0 "Write syslinux to /dev/$ROOT_DEVICE MBR"
            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: Installing syslinux failed"
            fi
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
