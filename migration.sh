#!/bin/bash

# Frédéric Pierret <fepitre> frederic.pierret@qubes-os.org

set -e
if [ "${VERBOSE:-0}" -ge 2 ] || [ "${DEBUG:-0}" -eq 1 ]; then
    set -x
fi

#-----------------------------------------------------------------------------#

usage() {
echo "Usage: $0 [OPTIONS]...

This script is used for updating current QubesOS R4.0 to R4.1.

Options:
    --update                (STAGE 1) Update of dom0, TemplatesVM and StandaloneVM.
    --release-upgrade       (STAGE 2) Update 'qubes-release' for Qubes R4.1.
    --dist-upgrade          (STAGE 3) Upgrade to Qubes R4.1 and Fedora 31 repositories.
    --setup-efi-grub        (STAGE 4) Setup EFI Grub.

    --assumeyes             Automatically answer yes for all questions.
    --usbvm                 Current UsbVM defined (default 'sys-usb').
    --netvm                 Current NetVM defined (default 'sys-net').
    --updatevm              Current UpdateVM defined (default 'sys-firewall').

Remark:
A reboot is necessary at the end of STAGE 3.
"
    exit 1
}

exit_migration() {
    local exit_code=$?
    if [ $exit_code -gt 0 ]; then
        echo "-> Launch restoration..."
        if ! is_qubes_uefi && [ -e /backup/default_grub ]; then
            # In case of any manual modifications
            echo "---> Restoring legacy Grub..."
            mkdir -p /etc/default/
            cp /backup/default_grub /etc/default/grub
            grub2-mkconfig -o /boot/grub2/grub.cfg
        fi
        if is_qubes_uefi && [ -e /backup/efi_disk ]; then
            if [ -e /backup/boot.img ] && [ -e /backup/partitions_table.txt ] && [ -e /backup/fstab ] && [ -e /backup/efi_part ]; then
                echo "---> Restoring EFI boot partition..."
                umount /boot/efi || true
                umount /boot || true
                # Restore partition table
                sfdisk --no-reread -f "$(cat /backup/efi_disk)" < /backup/partitions_table.txt
                # Resync partition
                partprobe
                # Restore boot partition
                dd if=/backup/boot.img of="$(cat /backup/efi_part)"
                # Remount previous EFI part
                cp /backup/fstab /etc/fstab
                mkdir -p /boot/efi
                mount /boot/efi
            fi
            echo "---> Restoring EFI boot manager..."
            # Restore EFI boot manager entry
            efibootmgr_entry="$(efibootmgr -v | grep "Qubes" | awk '{print $1}')"
            efibootmgr_entry="${efibootmgr_entry//Boot/}"
            efibootmgr_entry="${efibootmgr_entry//\*/}"
            if [ -n "$efibootmgr_entry" ]; then
                efibootmgr -b "$efibootmgr_entry" -B
            fi
            efibootmgr -c -d "$(cat /backup/efi_disk)" -L Qubes -l '\EFI\qubes\xen.efi'
            # Remove previous default grub conf created
            rm -rf /etc/default/grub
        fi
    fi
    exit "$exit_code"
}

confirm() {
    read -r -p "${1} [y/N] " response
    case "$response" in
        [yY]) 
            true
            ;;
        *)
            false
            ;;
    esac
}

is_boot_partition_exists() {
    grep -v /boot/efi /etc/fstab | grep -q /boot
}

is_qubes_uefi() {
    grep -q /boot/efi /etc/fstab >/dev/null
}

get_uuid_from_fstab() {
    local mountpoint="$1"
    if [ -n "$mountpoint" ]; then
        grep "$mountpoint" /etc/fstab | awk '{print $1}' | cut -d'=' -f2
    fi
}

get_uuid_from_block() {
    local blockpoint="$1"
    if [ -n "$blockpoint" ]; then
        lsblk -no uuid "$blockpoint"
    fi
}

get_disk_from_uuid() {
    local uuid="$1"
    if [ -n "$uuid" ]; then
        lsblk -no pkname "/dev/disk/by-uuid/$uuid"
    fi
}

get_partnumber_from_uuid() {
    local uuid="$1"
    if [ -n "$uuid" ]; then
        disk="$(get_disk_from_uuid "$uuid")"
        partnumber="$(lsblk -no name "/dev/disk/by-uuid/$uuid")"
        partnumber="${partnumber//$disk/}"
        # possibly with prefix 'p'
        echo "$partnumber"
    fi
}

get_available_partnumber() {
    local disk="$1"
    if [ -b "$disk" ]; then
        partitions_list="$(fdisk -l "$disk" | grep "^$disk" | awk -v disk="$disk" '{ gsub(disk,"",$1); print $1 }')"
        last_partnumber="$(echo "$partitions_list" | tail -1)"
        if [ -n "$last_partnumber" ]; then
            echo "$((last_partnumber + 1))"
        fi
    fi
}

get_boot_efi_size(){
    local uuid
    efi_uuid="$(get_uuid_from_fstab /boot/efi)"
    if [ -n "$efi_uuid" ]; then
        lsblk -b -no size "/dev/disk/by-uuid/$efi_uuid"
    fi
}

update_prechecks() {
    if ! is_boot_partition_exists; then
        if is_qubes_uefi; then
            efi_uuid="$(get_uuid_from_fstab /boot/efi)"
            if [ -n "$efi_uuid" ]; then
                # Minimum size for boot partition: 500Mo
                min_efi_size=524288000
                efi_boot_size="$(get_boot_efi_size)"
                if [ "${efi_boot_size:-0}" -lt "$min_efi_size" ]; then
                    echo "WARNING: EFI boot partitition size is less than 500Mo."
                fi
            else
                echo "ERROR: Cannot find EFI boot partitition UUID."
                exit 1
            fi
        fi
    fi
    # updatevm_template="$(qvm-prefs "$updatevm" template)"
    # if [ "$updatevm_template" != "fedora-30" ] && [ "$updatevm_template" != "debian-10" ]; then
    #    echo "ERROR: UpdateVM should be a Fedora 30+ or Debian 10+ template based VM."
    #    exit 1
    # fi
}

default_grub_config() {
cat > /etc/default/grub << EOF
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="$(sed 's, release .*$,,g' /etc/system-release)"
GRUB_DEFAULT=saved
GRUB_DISABLE_SUBMENU=true
GRUB_TERMINAL_OUTPUT="gfxterm"
GRUB_CMDLINE_LINUX="@GRUB_CMDLINE_LINUX@"
GRUB_CMDLINE_XEN_DEFAULT="@GRUB_CMDLINE_XEN_DEFAULT@"
GRUB_DISABLE_RECOVERY="true"
GRUB_THEME="/boot/grub2/themes/qubes/theme.txt"
GRUB_DISABLE_OS_PROBER="true"
EOF

# Use current default options
sed -i "s|@GRUB_CMDLINE_LINUX@|$(cat /proc/cmdline)|g" /etc/default/grub
sed -i "s|@GRUB_CMDLINE_XEN_DEFAULT@|$(xl info xen_commandline)|g" /etc/default/grub
}

update_legacy_grub() {
    if ! is_qubes_uefi; then
        if [ -e /etc/default/grub ]; then
            echo "---> Updating Grub..."
            mkdir -p /backup
            cp /etc/default/grub /backup/default_grub
            sed -i 's|^GRUB_THEME=.*|GRUB_THEME="/boot/grub2/themes/qubes/theme.txt"|g' /etc/default/grub
            grub2-mkconfig -o /boot/grub2/grub.cfg
        fi
    fi
}

setup_efi_grub() {
    # backup current /boot including efi
    if [ ! -d /backup/boot ]; then
        mkdir -p /backup/
        cp -ar /boot /backup/
        if [ -d /backup/boot/efi ]; then
            mv /backup/boot/efi /backup/
        fi
    else
        echo "INFO: Boot backup folder already exists at /backup. Skipping."
    fi

    # backup current fstab
    if [ ! -e /backup/fstab ]; then
        cp /etc/fstab /backup/fstab
    else
        echo "INFO: fstab backup already exists at /backup. Skipping."
    fi

    if is_qubes_uefi; then
        umount /boot/efi || true
        efi_uuid="$(get_uuid_from_fstab /boot/efi)"
        efi_part_number="$(get_partnumber_from_uuid "$efi_uuid")"
        efi_disk="$(get_disk_from_uuid "$efi_uuid")"
        if [ -z "${efi_part_number}" ] || [ ! -b "/dev/${efi_disk}" ]; then
            echo "ERROR: Cannot find EFI part number and disk."
            exit 1
        fi
        echo "/dev/${efi_disk}" > /backup/efi_disk
        if ! is_boot_partition_exists; then
            available_partnumber="$(get_available_partnumber "/dev/${efi_disk}")"
            if [ -z "${available_partnumber}" ]; then
                echo "ERROR: Cannot find available partition number."
                exit 1
            fi
            if [ "${efi_part_number:0:1}" == "p" ]; then
                part_path="/dev/${efi_disk}p"
            else
                part_path="/dev/${efi_disk}"
            fi
            # Backup
            if [ ! -e /backup/boot.img ] && [ ! -e /boot/partitions_table.txt ]; then
                dd if="${part_path}${efi_part_number}" of="/backup/boot.img"
                sfdisk -d "/dev/${efi_disk}" > "/backup/partitions_table.txt"
                echo "${part_path}${efi_part_number}" > /backup/efi_part
            else
                echo "INFO: Boot and partitions table backup already exists at /backup. Skipping."
            fi

            # Recreate EFI partition at the same position
            # Create Boot partition at third position
            printf "d\n%s\nn\n%s\n\n+25M\nn\n%s\n\n\nt\n%s\n1\nw\n" "${efi_part_number//p/}" "${efi_part_number//p}" "${available_partnumber}" "${efi_part_number//p}" | fdisk --wipe-partition always "/dev/$efi_disk"
            # EFI partition
            mkfs.vfat "${part_path}${efi_part_number}"
            # Boot partition
            mkfs.ext4 "${part_path}${available_partnumber}"

            # shellcheck disable=SC2115
            rm -rf /boot/*
            mount "${part_path}${available_partnumber}" /boot
            
            mkdir -p /boot/efi
            mount "${part_path}${efi_part_number}" /boot/efi

            # Copy current /boot into new partition /boot
            # including EFI boot partition content
            cp -r /backup/boot/* /boot/
            mkdir -p /boot/efi/EFI/qubes/fonts /boot/efi/EFI/qubes/entries
            cp -ar /backup/efi/EFI/qubes/fonts /boot/efi/EFI/qubes/
            cp -a /backup/efi/EFI/qubes/grubx64.efi /boot/efi/EFI/qubes/

            # Replace old EFI UUID
            new_efi_uuid="$(get_uuid_from_block "${part_path}${efi_part_number}")"
            # There is no reason for new_efi_uuid being empty
            # but in case we fallback to known entry point
            if [ -n "$new_efi_uuid" ]; then
                sed -i "s|$efi_uuid|$new_efi_uuid|g" /etc/fstab
            else
                sed -i "s|UUID=$efi_uuid|${part_path}${efi_part_number}|g" /etc/fstab
            fi

            # Add entry for /boot partition
            boot_uuid="$(get_uuid_from_block "${part_path}${available_partnumber}")"
            # There is no reason for boot_uuid being empty
            # but in case we fallback to known entry point
            if [ -n "$boot_uuid" ]; then
                echo "UUID=$boot_uuid    /boot    ext4    defaults    1 2" >> /etc/fstab
            else
                echo "${part_path}${available_partnumber}    /boot    ext4    defaults    1 2" >> /etc/fstab
            fi    
        fi
        # Modifiy EFI boot manager
        efibootmgr_entry="$(efibootmgr -v | grep "Qubes" | awk '{print $1}')"
        efibootmgr_entry="${efibootmgr_entry//Boot/}"
        efibootmgr_entry="${efibootmgr_entry//\*/}"
        if [ -n "$efibootmgr_entry" ]; then
            efibootmgr -b "$efibootmgr_entry" -B
        fi
        efibootmgr -c -d "/dev/${efi_disk}" -L Qubes -l '\EFI\qubes\grubx64.efi'

        # Create default Grub config
        default_grub_config

        # Create Grub config
        mount /boot/efi || true
        grub2-editenv /boot/efi/EFI/qubes/grubenv create
        pushd /boot/grub2/
        ln -sf ../efi/EFI/qubes/grubenv .
        popd
        grub2-mkconfig -o /boot/efi/EFI/qubes/grub.cfg

        # Copy font
        mkdir -p /boot/efi/EFI/qubes/fonts/
        cp /usr/share/grub/unicode.pf2 /boot/efi/EFI/qubes/fonts/

        # Set default plymouth theme
        plymouth-set-default-theme qubes-dark

        # Regenerate initrd
        dracut -f
    fi
}

#-----------------------------------------------------------------------------#

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run with root permissions" 
   exit 1
fi

if ! OPTS=$(getopt -o htrsgyu:n:f: --long help,update,release-upgrade,dist-upgrade,setup-efi-grub,assumeyes,usbvm:,netvm:,updatevm: -n "$0" -- "$@"); then
    echo "ERROR: Failed while parsing options."
    exit 1
fi

eval set -- "$OPTS"

# Common DNF options
dnf_opts='--clean --best --allowerasing --enablerepo=*testing*'

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h | --help) usage ;;
        -t | --update ) update=1;;
        -r | --release-upgrade) release_upgrade=1;;
        -s | --dist-upgrade ) dist_upgrade=1;;
        -g | --setup-efi-grub ) update_grub=1;;
        -y | --assumeyes ) assumeyes=1;;
        -u | --usbvm ) usbvm="$2"; shift ;;
        -n | --netvm ) netvm="$2"; shift ;;
        -f | --updatevm ) updatevm="$2"; shift ;;
    esac
    shift
done

if [ "$assumeyes" == "1" ];  then
    dnf_opts="$dnf_opts -y"
fi

# Default values
usbvm="${usbvm:-sys-usb}"
netvm="${netvm:-sys-net}"
updatevm="${updatevm:-sys-firewall}"

# We are goig to shutdown most of the VMs
mapfile -t running_vms < <(qvm-ls --running --raw-list --fields name)
keep_running=( dom0 "$usbvm" "$netvm" "$updatevm")

for vm in "${keep_running[@]}"
do
    for i in "${!running_vms[@]}"
    do
        if [ "${running_vms[i]}" == "$vm" ]; then
            unset "running_vms[i]"
        fi
    done
done

# Run prechecks first
update_prechecks

trap 'exit_migration' 0 1 2 3 6 15
if [ "$assumeyes" == "1" ] || confirm "-> Launch upgrade process?"; then
    # Ask before shutdown
    if [ ${#running_vms[@]} -gt 0 ]; then
        if [ "$assumeyes" == "1" ] || confirm "---> Allow shutdown of unnecessary VM: ${running_vms[*]}?"; then
            qvm-shutdown --wait "${running_vms[@]}"
        else
            exit 0
        fi
    fi

    if [ "$update" == "1" ]; then
        # Ensure 'gui' and 'qrexec' in default template used
        # for management else 'qubesctl' will failed
        management_template="$(qvm-prefs "$(qubes-prefs management_dispvm)" template)"
        if [ -n "$management_template" ]; then
            qvm-features "$management_template" gui 1
            qvm-features "$management_template" qrexec 1
        else
            echo "ERROR: Cannot find default management template."
            exit 1
        fi

        echo "---> Updating dom0, Templates VMs and StandaloneVMs..."
        # we need qubes-mgmt-salt-dom0-update >= 4.0.5
        # shellcheck disable=SC2086
        qubes-dom0-update $dnf_opts
        # TODO: qubesctl --skip-dom0 --templates --standalones state.sls update.qubes-vm
        qubesctl --skip-dom0 --templates state.sls update.qubes-vm
        # Restart UpdateVM with updated templates (several fixes)
        qvm-shutdown --wait "$updatevm"
    fi

    if [ "$release_upgrade" == "1" ]; then
        echo "---> Upgrading 'qubes-release'..."
        # shellcheck disable=SC2086
        qubes-dom0-update $dnf_opts --releasever=4.1 qubes-release
        rpm --import /etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-31-primary
    fi

    if [ "$dist_upgrade" == "1" ]; then
        # xscreensaver remains unsuable while upgrading
        # it's impossible to unlock it due to PAM update
        echo "INFO: Xscreensaver has been killed. Desktop won't lock before next reboot."
        pkill xscreensaver || true

        # Install new Qubes Grub theme before not being able to
        # download anything else due to distro-sync
        grub_packages=grub2-qubes-theme
        if is_qubes_uefi; then
            grub_packages="$grub_packages grub2-efi-x64"
        fi
        # shellcheck disable=SC2086
        qubes-dom0-update $dnf_opts $grub_packages

        # At this point, when update is done, qubesd, libvirt
        # will fail due to Xen upgrade. A reboot is necessary.
        # Notice also ugly fonts. This is temporary and it's fixed
        # at the next reboot.
        echo "---> Upgrading to QubesOS R4.1 and Fedora 31 repositories..."
        # shellcheck disable=SC2086
        qubes-dom0-update $dnf_opts --action=distro-sync || true

        # Update legacy Grub if needed
        update_legacy_grub
    fi

    if [ "$update_grub" == "1" ]; then
        echo "---> Installing EFI Grub..."
        setup_efi_grub
    fi
fi