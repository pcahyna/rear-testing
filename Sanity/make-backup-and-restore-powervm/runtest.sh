#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/rear/Sanity/rear-basic
#   Description: Test basic functionality of REAR on PowerVM machines.
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

rlJournalStart
    if [ "$REBOOTCOUNT" -eq 0 ]; then
        # Fresh start
        rlPhaseStartSetup
            rlAssertRpm $PACKAGE
        rlPhaseEnd

        # Sanity check
        rlPhaseStartSetup
            rlRun "systemd-detect-virt | grep powervm" 0 "Check that we are on PowerVM machine"
            if [ $? -eq 1 ]; then
                rlDie "Not a PowerVM machine!!!"
            fi
        rlPhaseEnd

        rlPhaseStartSetup
            rlFileBackup "/etc/rear/local.conf"
            rlRun "echo 'OUTPUT=ISO
OUTPUT_URL=null
BACKUP=NETFS
BACKUP_URL=iso://backup
ISO_DEFAULT=automatic
AUTOEXCLUDE_MULTIPATH=n
MIGRATION_MODE=n
ISO_RECOVER_MODE=unattended' | tee /etc/rear/local.conf" 0 "Create basic configuration file"
            rlAssertExists "/etc/rear/local.conf"
        rlPhaseEnd

        rlPhaseStartSetup
            rlLog "Backup original boot order"
            if lparstat > /dev/null; then
                rlRun "bootlist -m normal -r | tee bootorder.bak" 0 "Backup original bootorder"
            else
                rlLog "KVM???"
                rlDie "TODO:"
            fi

            rlAssertExists bootorder.bak
        rlPhaseEnd

        rlPhaseStartSetup
            rlLog "Select device for REAR"

            # TODO: disk selection
            REAR_ROOT="/dev/sdb"

            rlLog "Selected $REAR_ROOT"
            rlRun "lsblk | tee drive_layout" 0 "Store lsblk output in recovery image"
            rlAssertExists drive_layout
        rlPhaseEnd

        rlPhaseStartTest
            rlRun "rear -v mkbackup" 0 "Creating backup to $REAR_ROOT"
            rlAssertExists "/var/lib/rear/output/rear-$(hostname -s).iso"
        rlPhaseEnd

        rlPhaseStartSetup
            rlRun "touch recovery_will_remove_me" 0 "Create dummy file to be removed by recovery"
            rlAssertExists recovery_will_remove_me
        rlPhaseEnd

        # TODO: make the recovery unattended!
        # should be configurable in /etc/rear/local.conf!!!

        rlPhaseStartSetup
            rlRun "dd if='/var/lib/rear/output/rear-$(hostname -s).iso' of=$REAR_ROOT" 0 "Apply ISO to $REAR_ROOT"
            rlrun "sync" 0 "Sync all writes"
        rlPhaseEnd

        # TODO: check that bootorder.bak was really backed-up.

        rlPhaseStartTest
            rlLog "Setup correct boot order for REAR"
            if lparstat > /dev/null; then
                BOOTLIST_CMD="bootlist -m normal -r"

                OFPATH_LAST_BOOTED="$(nvram --print-config=ibm,last-booted)"
                OFPATH_REAR="$(ofpathname "$REAR_ROOT")"

                NEW_BOOT_ORDER="$($BOOTLIST_CMD | sed "s|$OFPATH_LAST_BOOTED|$OFPATH_REAR|")"

                # LAN has to be first! If REAR corrupted the machine and haven't
                # changed the boot order yet, the machine would remain broken as
                # Beaker expects the machine to always boot from LAN first.
                rlRun "$BOOTLIST_CMD $NEW_BOOT_ORDER" 0 "Set new bootorder"
            else
                rlLog "KVM???"
                rlDie "TODO:"
            fi
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
            if lparstat > /dev/null; then
                rlRun "bootlist -m normal -r -f bootorder.bak" 0 "Restore the original bootorder"
            else
                rlLog "KVM???"
                rlDie "TODO:"
            fi

            rlFileRestore
            rlRun "rm -f drive_layout{,.new}" 0 "Remove lsblk outputs"
            rlRun "rm -f bootorder.bak" 0 "Remove bootorder backup"
        rlPhaseEnd

    else
        rlDie "Only sensible reboot count is 0 or 1! Got: $REBOOTCOUNT"
    fi

rlJournalPrintText
rlJournalEnd
