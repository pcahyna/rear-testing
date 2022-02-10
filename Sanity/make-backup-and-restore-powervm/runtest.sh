#!/bin/bash
# vim: dict+=/usr/share/beakerlib/dictionary.vim cpt=.,w,b,u,t,i,k
# ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#
#   runtest.sh of /CoreOS/rear/Sanity/make-backup-and-restore-powervm
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

PACKAGES="rear powerpc-utils"

rlJournalStart
    if [ "$REBOOTCOUNT" -eq 0 ]; then
        # Fresh start
        rlPhaseStartSetup
            rlAssertRpm --all
        rlPhaseEnd

        # Sanity check
        rlPhaseStartSetup
            # We use the same procedure that REAR uses for machine detection.
            MACHINE="$(uname -m)"
            if [ "$MACHINE" != ppc64le ]; then
                rlDie "Not a ppc64le machine! Got: $MACHINE"
            fi

            if [ "$(awk '/platform/ {print $NF}' < /proc/cpuinfo)" = PowerNV ]; then
                rlDie "Got PowerNV machine!"
            fi

            if grep -q "emulated by qemu" /proc/cpuinfo ; then
                rlPass "Got PowerKVM machine!"
            else
                rlPass "Got PowerVM machine!"
            fi
        rlPhaseEnd

        rlPhaseStartSetup
            rlFileBackup "/etc/rear/local.conf"
            rlRun -l "echo 'OUTPUT=ISO
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
            # TODO: backup whole /dev/nvram???
            rlRun -l "nvram --print-config | tee nvram.bak" 0 \
                     "Backup NVRAM entries"

            rlLog "Backup original boot order"
            rlRun -l "nvram --print-config=boot-device | tee bootorder.bak" 0 \
                         "Backup original boot order"

            rlLog "#######################################################"
            rlLog "#####                   WARNING!                  #####"
            rlLog "#######################################################"
            rlLog "Beware that the contents of 'boot-device' NVRAM entry  "
            rlLog "may become corrupted if ReaR or any tool it depends on "
            rlLog "does something unexpected!  In such case, fix it before"
            rlLog "the machine is returned back to Beaker, otherwise it   "
            rlLog "will be corrupted.                                     "
            rlLog "                                                       "
            rlLog "If you can boot to some working instance of RHEL, use  "
            rlLog "the following command to fix it:                       "
            rlLog "                                                       "
            rlLog "nvram -p common --update-config 'boot-device=$(cat bootorder.bak)'"
            rlLog "                                                       "
            rlLog "Otherwise, set it directly in the firmware to the      "
            rlLog "following value:                                       "
            rlLog "                                                       "
            rlLog " $(cat bootorder.bak) "

            rlAssertExists bootorder.bak
            rlAssertExists nvram.bak

            rlFileSubmit bootorder.bak
            rlFileSubmit nvram.bak
        rlPhaseEnd

        rlPhaseStartSetup
            rlLog "Select device for REAR"

            # TODO: disk selection
            REAR_ROOT="/dev/sdb"
            rlLog "Selected $REAR_ROOT"

            # Use --raw as the size column would otherwise have a different
            # width after the ISO was applied to $REAR_ROOT.  Even though the
            # output would be still correct.
            rlRun -l "lsblk --raw | tee drive_layout.old" 0 \
                "Store lsblk output in recovery image"
            rlAssertExists drive_layout.old
        rlPhaseEnd

        rlPhaseStartTest
            rlRun "rear -v mkbackup" 0 "Creating backup ISO"
            rlAssertExists "/var/lib/rear/output/rear-$(hostname -s).iso"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: rear -v mkbackup failed"
            fi
        rlPhaseEnd

        rlPhaseStartSetup
            rlRun "touch recovery_will_remove_me" 0 "Create dummy file to be removed by recovery"
            rlAssertExists recovery_will_remove_me
        rlPhaseEnd

        # TODO: unattended recovery should be configurable in
        # /etc/rear/local.conf!!!
        rlPhaseStartSetup
            rlRun "xorriso -dev '/var/lib/rear/output/rear-$(hostname -s).iso' -osirrox on -cpx /boot/grub/grub.cfg $PWD/grub.cfg" \
                0 "Get grub.cfg from the ISO image"
            rlRun "sed -i '/^[[:blank:]]*linux/s/$/ unattended/' grub.cfg" \
                0 "Add 'unattended' to kernel cmdline"
            rlRun "xorriso -indev '/var/lib/rear/output/rear-$(hostname -s).iso' -update $PWD/grub.cfg /boot/grub/grub.cfg -outdev - | dd of=$REAR_ROOT" \
                0 "Update grub.cfg and apply ISO to $REAR_ROOT"
            rlRun "sync" 0 "Sync all writes"

            if ! rlGetPhaseState; then
                rlDie "FATAL ERROR: Applying ISO to $REAR_ROOT failed"
            fi
        rlPhaseEnd

        # TODO: check that bootorder.bak was really backed-up.

        rlPhaseStartTest
            rlLog "Setup correct boot order for REAR"

            OFPATH_REAR="$(ofpathname "$REAR_ROOT")"
            rlLog "$REAR_ROOT Open Firmware path: $OFPATH_REAR"

            if grep -q "emulated by qemu" /proc/cpuinfo ; then
                # PowerKVM
                :
                # you have to boot manually at the moment :(

                # PowerKVM completely ignores boot-device nvram variable!!!
                # TODO: Is always boot-device in 'common' partition?
                # rlRun "nvram -p common --update-config boot-device='$OFPATH_REAR'" \
                #    0 "Set boot-device to $OFPATH_REAR"
            else
                # PowerVM
                BOOTLIST_CMD="bootlist -m normal -r"

                OFPATH_LAST_BOOTED="$(nvram --print-config=ibm,last-booted)"
                rlLog "Last booted path: $OFPATH_LAST_BOOTED"

                # Let bootlist to load the new boot order from a file
                # so that we don't have to deal with whitespaces.
                rlRun -l "$BOOTLIST_CMD | \
                          sed 's|$OFPATH_LAST_BOOTED|$OFPATH_REAR\n$OFPATH_LAST_BOOTED|' | \
                          tee expected_new_boot_order" 0 "Generate new boot order"

                # LAN has to be first! If REAR corrupted the machine and haven't
                # changed the boot order yet, the machine would remain broken as
                # Beaker expects the machine to always boot from LAN first.
                rlRun -l "$BOOTLIST_CMD -f expected_new_boot_order" 0 "Set new bootorder"

                # Sanity check that bootlist did not botch setting the new boot
                # order. Happens (at least) on RHEL 7.6 at the moment.
                rlRun -l "$BOOTLIST_CMD | tee current_boot_order" 0 "Get the new bootorder"
                if ! rlAssertNotDiffer current_boot_order expected_new_boot_order; then
                    rlLogWarning "Bootlist botched the bootorder entry!"
                    rlRun -l "diff -u expected_new_boot_order current_boot_order" \
                        1 "Diff current and expected boot order"

                    # If powerpc-utils-1.3.4-14.el7 are used on RHEL-ALT-7.6
                    # there will be only a minor (and apparently harmless)
                    # difference in the network configuration.  It will contain
                    # the following extra suffix:
                    #
                    # :speed=auto,duplex=auto,0.0.0.0,,0.0.0.0,0.0.0.0
                    if ! grep -q "^$(head -n 1 expected_new_boot_order)" \
                                <(head -n 1 current_boot_order)          \
                    || ! cmp -s <(tail -n +2 expected_new_boot_order)    \
                                <(tail -n +2 current_boot_order); then
                        rlRun "nvram -p common --update-config 'boot-device=$(cat bootorder.bak)'" \
                            0 "Set original boot-device"

                        rlDie "Bootlist binary is broken! Stopping so that REAR does not destroy this VM."
                    fi

                    rlLog "The difference made by bootlist is minor. Will continue"
                fi
            fi
        rlPhaseEnd

        rhts-reboot
    elif [ "$REBOOTCOUNT" -eq 1 ]; then
        # REAR hopefully recovered the OS
        rlPhaseStartTest
            rlAssertNotExists recovery_will_remove_me

            rlAssertExists bootorder.bak
            rlAssertExists drive_layout.old
            rlAssertExists nvram.bak
            rlAssertExists /root/rear*.log

            # Check that REAR did not overwrite itself
            rlAssertExists /dev/disk/by-label/RELAXRECOVER
            REAR_DEV="$(realpath /dev/disk/by-label/RELAXRECOVER | xargs basename)"

            # dd changes disk layout so skip $REAR_DEV is we already know that
            # REAR did not overwrite itself
            rlLog "ReaR is on $REAR_DEV, $REAR_DEV will be skipped in the following comparison"

            # Use --raw as the size column would otherwise have a different
            # width after the ISO was applied to $REAR_ROOT.  Even though the
            # output would be still correct.
            rlRun -l "lsblk --raw | grep -v '^$REAR_DEV' | tee drive_layout.new" \
                0 "Get current lsblk output"

            if ! rlAssertNotDiffer drive_layout.old drive_layout.new; then
                rlRun -l "diff -u drive_layout.old drive_layout.new" \
                    1 "Diff drive layout changes"
            fi

            rlFileSubmit /root/rear*.log
        rlPhaseEnd

        rlPhaseStartCleanup
            if grep -q "emulated by qemu" /proc/cpuinfo ; then
                # PowerKVM
                # TODO: Do nothing?
                :
            else
                # PowerVM
                rlRun "nvram -p common --update-config 'boot-device=$(cat bootorder.bak)'" \
                       0 "Set original boot-device"
            fi

            rlFileRestore
            rlRun "rm -f drive_layout.{old,new}" 0 "Remove lsblk outputs"
            rlRun "rm -f bootorder.bak" 0 "Remove bootorder backup"
            rlRun "rm -f nvram.bak" 0 "Remove NVRAM variables backup"
            rlRun "rm -f /root/rear*.log" 0 "Remove ReaR recovery log"
        rlPhaseEnd

    else
        rlDie "Only sensible reboot count is 0 or 1! Got: $REBOOTCOUNT"
    fi

rlJournalPrintText
rlJournalEnd
