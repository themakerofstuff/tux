#!/bin/bash
set -e

OPTION=$1
PACKAGE=$2

WHITE='\033[0;37m'
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NONE='\033[0m'

REPO_DIR=${ROOT}/var/lib/tux/repo
REPO_FILE=${ROOT}/etc/tux/repo

tux_info() {
    echo -e "${BLUE}>>> ${WHITE}${1}${NONE}"
}

tux_error() {
    echo -e "${RED}>>> ${WHITE}${1}${NONE}"
}

tux_success() {
    echo -e "${GREEN}>>> ${WHITE}${1}${NONE}"
}


tux_resolve_deps() {
    BUILD_FILE=${REPO_DIR}/${1}/tuxbuild

    if [ ! -d "${REPO_DIR}/${1}" ]; then
        tux_error "Failed to find package $1"
        exit 1
    fi
    circular=$1
    deps_to_install=()
    source $BUILD_FILE
    for dep in ${depends[@]}; do
        if [ "$(ls ${ROOT}/etc/tux/installed | grep $dep)" == "" ]; then
            deps_to_install+=( $(tux_resolve_deps $dep) )
            deps_to_install+=( "${dep}" )
        fi
    done
    echo ${deps_to_install[@]}
}

tux_install() {
    if [ ! -d "$REPO_DIR" ]; then
        tux_info "Package repository not found, cloning it..."
        git clone $(cat $REPO_FILE) $REPO_DIR
    fi

    if [ ! -d "${REPO_DIR}/${1}" ]; then
        tux_error "Failed to find package $1"
        exit 1
    fi

    if [ -d "$ROOT/etc/tux/installed/$1" ]; then tux_info "Package $1 is already installed"; return 0; fi

    tux_info "The following packages will be installed:"
    echo $(tux_resolve_deps $1) $1
    if [ "$2" == "true" ]; then
        read -p "Do you want to continue? [y/n] " yn
        if [ "$yn" == "n" ] || [ "$yn" == "N" ]; then
            exit 1
        fi
    fi
    deps=( $(tux_resolve_deps $1) $1 )
    for pkg in ${deps[@]}; do
        BUILD_FILE=${REPO_DIR}/${pkg}/tuxbuild
        BUILD_DIR=${ROOT}/var/lib/tux/build/${pkg}
        LOG_FILE=${ROOT}/var/lib/tux/${pkg}-log.txt
        if [ ! -d "$BUILD_DIR" ]; then
            mkdir -p $BUILD_DIR
        else
            rm -rf $BUILD_DIR
            mkdir -p $BUILD_DIR
        fi
        source $BUILD_FILE
        tux_info "Downloading files for package ${pkg}..."
        sleep 0.5
        for url in ${pkgurls[@]}; do
            IFS='/' read -ra pkgname <<< "$url"
            if [ ! -f $ROOT/var/lib/tux/sources/${pkgname[-1]} ]; then
                wget $url -P ${BUILD_DIR}/
            else
                cp $ROOT/var/lib/tux/sources/${pkgname[-1]} $BUILD_DIR/
            fi
        done
        if [ -f "${REPO_DIR}/${pkg}/sha512sums" ]; then
            tux_info "Checking sha512sums for package ${pkg}..."
            sleep 0.5
            cd $BUILD_DIR
            if ! sha512sum -c ${REPO_DIR}/${pkg}/sha512sums; then
                tux_error "sha512sum checking failed for ${pkg}"
                rm -rf $BUILD_DIR
                exit 1
            fi
        fi
        source $ROOT/etc/tux/make.conf
        export MAKEFLAGS CFLAGS CXXFLAGS LDFLAGS CPPFLAGS
        tux_info "Building package ${pkg}..."
        cd $BUILD_DIR
	    DST=$ROOT/var/lib/tux/$pkg-$pkgver
	    mkdir -p $DST
        sleep 0.5
        DST=${ROOT}/var/lib/tux/${pkg}-${pkgver}
        if [ ! -d "$DST" ]; then
            mkdir -p $DST
        fi
        if ! buildpkg; then
            tux_error "Failed to build package ${pkg}"
            tux_error "Log can be found at:"
            echo $LOG_FILE
            rm -rf $BUILD_DIR
            exit 1
        fi
        tux_info "Installing package ${pkg}..."
        sleep 0.5
        if ! installpkg; then
            tux_error "Failed to install package ${pkg}"
            tux_error "Log can be found at:"
            echo $LOG_FILE
            rm -rf $BUILD_DIR $DST
            exit 1
        fi
        cd $DST
        INDEX_DIR=${ROOT}/etc/tux/installed/${pkg}
        if [ ! -d "$INDEX_DIR" ]; then mkdir -p $INDEX_DIR; else rm -rf $INDEX_DIR; mkdir -p $INDEX_DIR; fi
        find . -type f | sed s/.// > ${INDEX_DIR}/FILES
        find . -type l | sed s/.// > ${INDEX_DIR}/LINKS
        find . -type d | sed s/.// > ${INDEX_DIR}/DIRS
        echo $pkgver > ${INDEX_DIR}/VERSION
        for x in ${depends[@]}; do
            echo $x >> ${INDEX_DIR}/DEPENDS
        done
        tux_info "Copying files for ${pkg}..."
        sleep 0.5
        if type copypkgfiles &> /dev/null; then
            copypkgfiles
        else
            rsync -aK ${DST}/* ${ROOT}/
        fi
        if type postinstpkg &> /dev/null; then
            tux_info "Running post install tasks for ${pkg}..."
            cd $BUILD_DIR
            if ! postinstpkg; then
                tux_error "Failed to run post-install for package ${pkg}"
                tux_error "Log can be found at:"
                echo $LOG_FILE
                rm -rf $BUILD_DIR $DST
                exit 1
            fi
        fi
        tux_info "Cleaning up..."
        rm -rf $BUILD_DIR $DST $LOG_FILE
	    unset -f buildpkg
	    unset -f installpkg
	    unset -f postinstpkg
        tux_success "Successfully installed ${pkg}"
    done
}

tux_check_deps_bootstrap() {
    LC_ALL=C 
    PATH=/usr/bin:/bin

    bail() { echo "FATAL: $1"; exit 1; }
    grep --version > /dev/null 2> /dev/null || bail "grep does not work"
    sed '' /dev/null || bail "sed does not work"
    sort   /dev/null || bail "sort does not work"

    ver_check()
    {
    if ! type -p $2 &>/dev/null
    then 
        echo "ERROR: Cannot find $2 ($1)"; return 1; 
    fi
    v=$($2 --version 2>&1 | grep -E -o '[0-9]+\.[0-9\.]+[a-z]*' | head -n1)
    if printf '%s\n' $3 $v | sort --version-sort --check &>/dev/null
    then 
        printf "OK:    %-9s %-6s >= $3\n" "$1" "$v"; return 0;
    else 
        printf "ERROR: %-9s is TOO OLD ($3 or later required)\n" "$1"; 
        return 1; 
    fi
    }

    ver_kernel()
    {
    kver=$(uname -r | grep -E -o '^[0-9\.]+')
    if printf '%s\n' $1 $kver | sort --version-sort --check &>/dev/null
    then 
        printf "OK:    Linux Kernel $kver >= $1\n"; return 0;
    else 
        printf "ERROR: Linux Kernel ($kver) is TOO OLD ($1 or later required)\n" "$kver"; 
        return 1; 
    fi
    }

    # Coreutils first because --version-sort needs Coreutils >= 7.0
    ver_check Coreutils      sort     8.1 || bail "Coreutils too old, stop"
    ver_check Bash           bash     3.2
    ver_check Binutils       ld       2.13.1
    ver_check Bison          bison    2.7
    ver_check Diffutils      diff     2.8.1
    ver_check Findutils      find     4.2.31
    ver_check Gawk           gawk     4.0.1
    ver_check GCC            gcc      5.2
    ver_check "GCC (C++)"    g++      5.2
    ver_check Grep           grep     2.5.1a
    ver_check Gzip           gzip     1.3.12
    ver_check M4             m4       1.4.10
    ver_check Make           make     4.0
    ver_check Patch          patch    2.5.4
    ver_check Perl           perl     5.8.8
    ver_check Python         python3  3.4
    ver_check Sed            sed      4.1.5
    ver_check Tar            tar      1.22
    ver_check Texinfo        texi2any 5.0
    ver_check Xz             xz       5.0.0
    ver_kernel 4.19

    if mount | grep -q 'devpts on /dev/pts' && [ -e /dev/ptmx ]
    then echo "OK:    Linux Kernel supports UNIX 98 PTY";
    else echo "ERROR: Linux Kernel does NOT support UNIX 98 PTY"; fi

    alias_check() {
    if $1 --version 2>&1 | grep -qi $2
    then printf "OK:    %-4s is $2\n" "$1";
    else printf "ERROR: %-4s is NOT $2\n" "$1"; fi
    }
    echo "Aliases:"
    alias_check awk GNU
    alias_check yacc Bison
    alias_check sh Bash

    echo "Compiler check:"
    if printf "int main(){}" | g++ -x c++ -
    then echo "OK:    g++ works";
    else echo "ERROR: g++ does NOT work"; fi
    rm -f a.out

    if [ "$(nproc)" = "" ]; then
    echo "ERROR: nproc is not available or it produces empty output"
    else
    echo "OK: nproc reports $(nproc) logical cores are available"
    fi
    if ! curl ifconfig.me &> /dev/null; then
        bail "curl does not work"
    fi
    if ! git --help &> /dev/null; then
        bail "git does not work"
    fi

}

tux_bootstrap() {
    tux_info "Checking dependencies..."
    sleep 0.3
    tux_check_deps_bootstrap
    tux_info "Setting up root in ${ROOT}..."
    mkdir -p ${ROOT}/{etc,var} ${ROOT}/usr/{bin,lib,sbin}
    for x in bin lib sbin; do
	if [ ! -d "$ROOT/$x" ]; then
        	ln -s usr/$x $ROOT/$x
	fi
    done
    case $(uname -m) in
        x86_64) mkdir -p $ROOT/lib64 ;;
    esac
    mkdir -p $ROOT/tools
    mkdir -p ${ROOT}/etc/tux/installed
    mkdir -p ${ROOT}/var/lib/tux
    [ -z "$MAKEFLAGS" ] && echo MAKEFLAGS=-j$(nproc) >> $ROOT/etc/tux/make.conf || echo MAKEFLAGS=$MAKEFLAGS >> $ROOT/etc/tux/make.conf
    [ -z "$CFLAGS" ] || echo CFLAGS=$CFLAGS >> $ROOT/etc/tux/make.conf
    [ -z "$CXXFLAGS" ] || echo CXXFLAGS=$CXXFLAGS >> $ROOT/etc/tux/make.conf
    [ -z "$CPPFLAGS" ] || echo CPPFLAGS=$CPPFLAGS >> $ROOT/etc/tux/make.conf
    [ -z "$LDFLAGS" ] || echo LDFLAGS=$LDFLAGS >> $ROOT/etc/tux/make.conf
    echo https://github.com/themakerofstuff/tuxpkgs > $REPO_FILE
    tux_info "Cloning package repository..."
    sleep 0.3
    if [ ! -d "$REPO_DIR" ]; then
    	git clone $(cat $REPO_FILE) $REPO_DIRi
    fi
    tux_info "Setting environment..."
    set +h
    umask 022
    LC_ALL=POSIX
    CC_TGT=$(uname -m)-tux-linux-gnu
    PATH=/usr/bin
    if [ ! -L /bin ]; then PATH=/bin:$PATH; fi
    PATH=$ROOT/tools/bin:$PATH
    CONFIG_SITE=$ROOT/usr/share/config.site
    export ROOT LC_ALL CC_TGT PATH CONFIG_SITE

    tux_info "Building binutils-cross-bootstrap..."
    tux_install binutils-cross-bootstrap false
    tux_info "Building gcc-cross-bootstrap..."
    tux_install gcc-cross-bootstrap false
    tux_info "Building linux-api-headers..."
    tux_install linux-api-headers false
    tux_info "Building glibc-bootstrap..."
    tux_install glibc-bootstrap false
    tux_info "Building libstdcpp-bootstrap..."
    tux_install libstdcpp-bootstrap false
    tux_info "Building base-bootstrap..."
    tux_install base-bootstrap false
}

if [ "$EUID" != "0" ]; then tux_error "This must be run as root"; exit 1; fi

tux_info "Using ${ROOT}/ as root directory"

if [ "$OPTION" == "install" ] && [ "$PACKAGE" != "" ]; then
    tux_install $PACKAGE
elif [ "$OPTION" == "bootstrap" ]; then
    tux_bootstrap
elif [ "$OPTION" == "check-deps" ]; then
    tux_check_deps_bootstrap
else
    tux_error "Valid arguments not specified"
    exit 1
fi
