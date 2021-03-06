#!/usr/bin/env bash
#
# This module contains all build functionalities for JuNest.
#
# Dependencies:
# - lib/utils/utils.sh
# - lib/core/common.sh
#
# vim: ft=sh

function _check_package(){
    if ! pacman -Qq $1 > /dev/null
    then
        die "Package $1 must be installed"
    fi
}

function _install_from_aur(){
    local maindir=$1
    local pkgname=$2
    local installname=$3
    mkdir -p ${maindir}/packages/${pkgname}
    builtin cd ${maindir}/packages/${pkgname}
    $CURL "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=${pkgname}"
    [ -z "${installname}" ] || $CURL "https://aur.archlinux.org/cgit/aur.git/plain/${installname}?h=${pkgname}"
    makepkg -sfcd --skippgpcheck
    sudo pacman --noconfirm --root ${maindir}/root -U ${pkgname}*.pkg.tar.xz
}

function _install_from_aur_with_deps(){
    local maindir=$1
    local pkgname=$2
    mkdir -p ${maindir}/packages/${pkgname}
    builtin cd ${maindir}/packages/${pkgname}
    $CURL "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=${pkgname}"
    makepkg -sfc --skippgpcheck --noconfirm #omg
    sudo pacman --noconfirm --root ${maindir}/root -U ${pkgname}*.pkg.tar.xz
}

function build_image_env(){
    umask 022

    # The function must runs on ArchLinux with non-root privileges.
    (( EUID == 0 )) && \
        die "You cannot build with root privileges."

    _check_package arch-install-scripts
    _check_package gcc

    local disable_validation=$1

    local maindir=$(TMPDIR=$JUNEST_TEMPDIR mktemp -d -t ${CMD}.XXXXXXXXXX)
    sudo mkdir -p ${maindir}/root
    trap - QUIT EXIT ABRT KILL TERM INT
    # fucking self-destructing traps everywhere OMG
    trap "echo sudo rm -rf ${maindir}; die \"Error occurred when installing ${NAME}\"" EXIT QUIT ABRT KILL TERM INT
    info "Installing pacman and its dependencies..."
    # The archlinux-keyring and libunistring are due to missing dependencies declaration in ARM archlinux
    # All the essential executables (ln, mkdir, chown, etc) are in coreutils
    # yaourt requires sed
    # localedef (called by locale-gen) requires gzip
    # unshare command belongs to util-linux
    sudo pacstrap -G -M -d ${maindir}/root pacman coreutils libunistring archlinux-keyring sed gzip util-linux git
    sudo bash -c "echo 'Server = $DEFAULT_MIRROR' >> ${maindir}/root/etc/pacman.d/mirrorlist"
    sudo mkdir -p ${maindir}/root/run/lock

    # AUR packages requires non-root user to be compiled. proot fakes the user to 10
    info "Compiling and installing yaourt..."
    _install_from_aur ${maindir} "package-query"
    _install_from_aur ${maindir} "yaourt"
    _install_from_aur ${maindir} "sudo-fake"

    info "Install ${NAME} script..."
    #sudo pacman --noconfirm --root ${maindir}/root -S git
    _install_from_aur ${maindir} "${CMD}-git" "${CMD}.install"
    #sudo pacman --noconfirm --root ${maindir}/root -Rsn git
    
    if [[ ! -z "$2" ]]; then
        info "Installing additional packages..."        
        echo "$@"
        shift
        
        echo "$@"
        sudo pacman --noconfirm --root ${maindir}/root -Syy || echo "fuck you"
        #sudo ${maindir}/root/opt/junest/bin/groot ${maindir}/root pacman --noconfirm -Syy || echo "FAIL"
        #sudo ${maindir}/root/opt/junest/bin/groot -b /dev ${maindir}/root bash -x -c "pacman --noconfirm -Syy"
        
        for pkg in "$@"
        do
            if [[ "${pkg}" == aur:* ]]; then
                _install_from_aur_with_deps ${maindir} "${pkg:4}" || echo "FFS DONT BREAK MY BUILD"
                #sudo ${maindir}/root/opt/junest/bin/groot bash -x -c \
        #"yogurt --noconfirm -S ${pkg:4} || echo 'Ooops! Package installation failed (${pkg})'"
                #JUNEST_HOME="${maindir}/root" ${maindir}/root/opt/${CMD}/bin/${CMD} -f yogurt --noconfirm -S "${pkg:4}" || echo "Ooops! Package installation failed (${pkg})"
            else
                # sudo pacman --noconfirm --root ${maindir}/root -S "${pkg}"
                #sudo ${maindir}/root/opt/junest/bin/groot bash -x -c \
        #"pacman --noconfirm -Sy ${pkg} || echo 'Ooops! Package installation failed (${pkg})'"
                sudo pacman --noconfirm --root ${maindir}/root -Sy ${pkg} || echo "fuck you 2"
            fi
        done
    fi

    info "Generating the locales..."
    # sed command is required for locale-gen
    sudo ln -sf /usr/share/zoneinfo/posix/UTC ${maindir}/root/etc/localtime
    sudo bash -c "echo 'en_US.UTF-8 UTF-8' >> ${maindir}/root/etc/locale.gen"
    sudo ${maindir}/root/opt/junest/bin/groot ${maindir}/root locale-gen
    sudo bash -c "echo LANG=\"en_US.UTF-8\" >> ${maindir}/root/etc/locale.conf"

    info "Setting up the pacman keyring (this might take a while!)..."
    sudo ${maindir}/root/opt/junest/bin/groot -b /dev ${maindir}/root bash -x -c \
        "pacman-key --init; pacman-key --populate archlinux; [ -e /etc/pacman.d/gnupg/S.gpg-agent ] && gpg-connect-agent -S /etc/pacman.d/gnupg/S.gpg-agent killagent /bye" || echo "I don't care about these bullshit errors"

    #info "Installing aurman"
    #(JUNEST_HOME="${maindir}/root" sudo -E ${maindir}/root/opt/${CMD}/bin/${CMD} -g 'git clone https://github.com/polygamma/aurman.git --depth=1 && cd aurman && sudo makepkg -si --noconfirm --skippgpcheck') || echo "Ooops! Unable to install aurman!"

    
    sudo rm ${maindir}/root/var/cache/pacman/pkg/*

    mkdir -p ${maindir}/output
    builtin cd ${maindir}/output
    local imagefile="${CMD}-${ARCH}.tar.gz"
    info "Compressing image to ${imagefile}..."
    sudo $TAR -zcpf ${imagefile} -C ${maindir}/root .

    #if ! $disable_validation
    #then
    #    mkdir -p ${maindir}/root_test
    #    $TAR -zxpf ${imagefile} -C "${maindir}/root_test"   
    #    JUNEST_HOME="${maindir}/root_test" ${maindir}/root_test/opt/${CMD}/bin/${CMD} -f ${JUNEST_BASE}/lib/checks/check.sh
    #    JUNEST_HOME="${maindir}/root_test" sudo -E ${maindir}/root_test/opt/${CMD}/bin/${CMD} -g ${JUNEST_BASE}/lib/checks/check.sh --run-root-tests
    #fi

    sudo cp ${maindir}/output/${imagefile} ${ORIGIN_WD}/..

    builtin cd ${ORIGIN_WD}
    trap - QUIT EXIT ABRT KILL TERM INT
    echo sudo rm -fr "$maindir"
}
