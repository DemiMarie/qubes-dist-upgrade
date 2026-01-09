#!/usr/bin/bash

# Frédéric Pierret (fepitre) frederic.pierret@qubes-os.org
# Exit codes:
# 0: OK
# 1: General errors
# 2: Unsupported distribution
# 3: Upgrade failed

set -ex

if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run with root permissions" 
   exit 1
fi

enable_current_testing=
if [ "$1" = "--enable-current-testing" ]; then
    enable_current_testing=1
fi

if [ -e /etc/fedora-release ]; then
    releasever="$(awk '{print $3}' /etc/fedora-release)"
    # Check Fedora supported release
    if [ "$releasever" -lt 41 ]; then
        exit 2
    fi
    # Backup R4.2 repository file
    cp /etc/yum.repos.d/qubes-r4.repo /etc/yum.repos.d/qubes-r4.repo.bak
    # We don't have $releasever into so manually replace it
    sed -i 's/r4.2/r4.3/g' /etc/yum.repos.d/qubes-r4.repo
    sed -i 's/4\.2-primary/4.3-primary/g' /etc/yum.repos.d/qubes-r4.repo
    dnf_opts=()
    if [ "$enable_current_testing" ]; then
        dnf_opts=("--enablerepo=qubes*current-testing")
    fi
    # Ensure DNF cache is cleaned
    dnf clean all
    # Run upgrade
    if ! dnf distro-sync -y --best --allowerasing "${dnf_opts[@]}"; then
        exit 3
    fi

elif [ -e /etc/debian_version ]; then
    releasever="$(awk -F'.' '{print $1}' /etc/debian_version)"
    # Check Debian supported release
    if [ "$releasever" -lt 12 ]; then
        exit 2
    fi
    # Backup R4.2 repository file
    cp /etc/apt/sources.list.d/qubes-r4.list /etc/apt/sources.list.d/qubes-r4.list.bak
    # We don't have $releasever into so manually replace it
    sed -i 's/r4.2/r4.3/g' /etc/apt/sources.list.d/qubes-r4.list
    sed -i 's/\[arch=amd64\( signed-by=.*\)\?\]/[arch=amd64\ signed-by=\/usr\/share\/keyrings\/qubes-archive-keyring-4.3.gpg]/g' /etc/apt/sources.list.d/qubes-r4.list
    export DEBIAN_FRONTEND=noninteractive
    if [ "$enable_current_testing" ]; then
        # extract just the testing line, without leading '#'
        # if it was uncommented already, apt will complain the repo is listed
        # twice, but it's harmless
        grep -o 'deb .*deb.qubes-os.org.*-testing.*' /etc/apt/sources.list.d/qubes-r4.list > /etc/apt/sources.list.d/qubes-r4-testing.list
    fi
    # Ensure APT cache is cleaned
    apt-get clean
    apt-get update -o Dpkg::Options::="--force-confdef"

    # Run upgrade, without installing "recommended" packages - that would
    # un-minimal a minimal template
    if ! apt-get dist-upgrade -y --no-install-recommends -o Dpkg::Options::="--force-confdef"; then
        exit 3
    fi
    if [ "$enable_current_testing" ]; then
        rm -f /etc/apt/sources.list.d/qubes-r4-testing.list
    fi

elif [ -e /etc/arch-release ]; then
    for conf in /etc/pacman.d/??-qubes*.conf /etc/pacman.d/??-qubes*.conf.disabled; do
        if [ -h "$conf" ]; then
            continue
        fi
        if ! grep -q r4.2 "$conf"; then
            continue
        fi
        # this should change two places: repository name and server URL
        sed -i.bak -e 's/r4\.2/r4.3/' "$conf"
    done

    if [ "$enable_current_testing" ]; then
        # use alternative name, for easier cleanup
        if [ -e "/etc/pacman.d/85-qubes-current-testing.conf.disabled" ]; then
            ln -nsf 85-qubes-current-testing.conf.disabled /etc/pacman.d/84-qubes-current-testing.conf
        else
            echo "WARNING: cannot find /etc/pacman.d/85-qubes-current-testing.conf.disabled, not enabling the current-testing repository" >&2
        fi
    fi

    pacman -Syu --noconfirm

    if [ "$enable_current_testing" ]; then
        rm -f /etc/pacman.d/84-qubes-current-testing.conf
    fi
fi
