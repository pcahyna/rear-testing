#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/rear/Sanity/make-backup-and-restore-s390x
#   Description: Test basic functionality of REAR on s390x machines.
#   Author: Lukas Zaoral <lzaoral@redhat.com>
#
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   Copyright (c) 2022 Red Hat, Inc.
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

PACKAGES="rear s390utils"
NFS_SERVER="${NFS_SERVER:-""}"

rlJournalStart
    if [ "$REBOOTCOUNT" -eq 0 ]; then
        # Fresh start
        rlPhaseStartSetup
            rlAssertRpm --all
        rlPhaseEnd

        # Sanity check
        rlPhaseStartSetup
            if [ -z "$NFS_SERVER" ]; then
                rlDie "NFS_SERVER was not specified!"
            fi

            MACHINE="$(uname -m)"
            if [ "$MACHINE" != s390x ]; then
                rlDie "Not a s390x machine! Got: $MACHINE"
            fi
            rlPass "Got s390x machine!"
        rlPhaseEnd

        rlPhaseStartSetup
            rlFileBackup "/etc/rear/local.conf"
            rlRun -l "echo 'OUTPUT=IPL
OUTPUT_URL=file://\$ISO_DIR
BACKUP=NETFS
PROGS+=( chreipl )
POST_RECOVERY_SCRIPT=( \"chreipl \${TARGET_FS_ROOT}/boot\" )
BACKUP_URL=nfs://$NFS_SERVER/mnt/rear' | tee /etc/rear/local.conf" \
                0 "Create basic configuration file"
            rlAssertExists "/etc/rear/local.conf"
        rlPhaseEnd

        rlPhaseStartSetup
            rlRun -l "lsreipl | tee bootorder.bak" 0 "Backup bootorder"

            rlAssertExists bootorder.bak
            rlFileSubmit bootorder.bak
        rlPhaseEnd

        rlPhaseStartSetup
            rlLog "Select device for REAR"

            # TODO: disk selection
            REAR_DEVICE="0.0.0121"
            rlRun "grep -v $REAR_DEVICE /etc/dasd.conf" \
                0 "Assert that $REAR_DEVICE is unused"

            rlRun -l "echo $REAR_DEVICE | tee -a /etc/dasd.conf" \
                0 "Add $REAR_DEVICE to dasd.conf"
            rlRun "cio_ignore -r $REAR_DEVICE" \
                0 "Make $REAR_DEVICE visible to Linux"
            rlRun "udevadm settle" 0 "Wait for udev"

            REAR_ROOT="$(realpath /dev/disk/by-path/ccw-$REAR_DEVICE)"
            rlLog "Selected $REAR_ROOT"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: disk selection failed!"
            fi

            # TODO: this is just a work-around for the fact that ReaR formats
            # every DASD it finds and wipefs does not remove partition table
            # on DASDs, so remove any trace of partitions on $REAR_ROOT from
            # the lsblk output.  Otherwise, the comparison after successful
            # recovery would have failed.
            #
            # Ideally, this check should be performed after we prepare the
            # drive for ReaR.
            rlRun -l "lsblk | \
                      grep -v -E '$(basename "$REAR_ROOT")[[:digit:]]+' | \
                      tee drive_layout.old" \
                0 "Store lsblk output in the recovery image"
            rlAssertExists drive_layout.old

        rlPhaseEnd

        rlPhaseStartSetup
            rlRun "fdasd -a $REAR_ROOT" 0 "Erase $REAR_ROOT"
            rlRun "mkfs.ext3 ${REAR_ROOT}1" 0 "Format ${REAR_ROOT}1"
        rlPhaseEnd

        rlPhaseStartTest
            rlRun "rear -v mkbackup" 0 "Creating rescue image and backup"

            RESCUE_IMAGE_PATH="/var/lib/rear/output/$(hostname -s)"
            rlAssertExists "$RESCUE_IMAGE_PATH/"vmlinuz-*.el*.s390x
            rlAssertExists "$RESCUE_IMAGE_PATH/initrd.cgz"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: rear -v mkbackup failed"
            fi
        rlPhaseEnd

        rlPhaseStartSetup
            rlRun "touch recovery_will_remove_me" \
                0 "Create dummy file to be removed by recovery"
            rlAssertExists recovery_will_remove_me
        rlPhaseEnd

        rlPhaseStartTest
            rlRun "mkdir /mnt/rear" 0 "Create /mnt/rear"
            rlRun "mount ${REAR_ROOT}1 /mnt/rear" 0 "Mount ${REAR_ROOT}1 to /mnt/rear"

            rlRun "cp $RESCUE_IMAGE_PATH/* /mnt/rear" 0 "Copy rescue image to ${REAR_ROOT}1"

            rlRun "zipl -t /mnt/rear -i /mnt/rear/vmlinuz-*.el*.s390x -r /mnt/rear/initrd.cgz -P 'root=/dev/ram0 ro unattended'" \
                0 "Install bootloader to $REAR_ROOT"

            rlRun -l "chreipl /mnt/rear" 0 "Set $REAR_ROOT as the reboot device"
        rlPhaseEnd

        rhts-reboot
    elif [ "$REBOOTCOUNT" -eq 1 ]; then
        # REAR hopefully recovered the OS
        rlPhaseStartTest
            rlAssertNotExists recovery_will_remove_me

            rlAssertExists bootorder.bak
            rlAssertExists drive_layout.old
            rlAssertExists /root/rear*.log

            rlRun -l "lsblk | tee drive_layout.new" \
                0 "Get current lsblk output"

            if ! rlAssertNotDiffer drive_layout.old drive_layout.new; then
                rlRun -l "diff -u drive_layout.old drive_layout.new" \
                    1 "Diff drive layout changes"
            fi

            rlFileSubmit /root/rear*.log
        rlPhaseEnd

        rlPhaseStartCleanup
            rlRun "chreipl /boot" 0 "Restore reboot device"

            rlFileRestore
            rlRun "rm -f drive_layout.{old,new}" 0 "Remove lsblk outputs"
            rlRun "rm -f bootorder.bak" 0 "Remove bootorder backup"
            rlRun "rm -f /root/rear*.log" 0 "Remove ReaR recovery log"
        rlPhaseEnd

    else
        rlDie "Only sensible reboot count is 0 or 1! Got: $REBOOTCOUNT"
    fi

rlJournalPrintText
rlJournalEnd
