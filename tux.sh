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
    deps_to_install=()
    source $BUILD_FILE
    for dep in ${depends[@]}; do
        if [ "$2" == "all-deps" ]; then
            deps_to_install+=( $(tux_resolve_deps $dep all-deps) )
            deps_to_install+=( "${dep}" )
        elif [ ! -d "$ROOT/etc/tux/installed/$dep" ]; then
            deps_to_install+=( $(tux_resolve_deps $dep) )
            deps_to_install+=( "${dep}" )
        fi
    done
    for dep in ${deps_to_install[@]}; do
        deps_to_install=( "$(echo ${deps_to_install[@]} | sed s/\ $dep\ /\ /2g 2> /dev/null)" )
    done
    echo ${deps_to_install[@]}
}

tux_install() {
    OPT=$2
    if [ ! -d "$REPO_DIR" ]; then
        tux_info "Package repository not found, cloning it..."
        git clone $(cat $REPO_FILE) $REPO_DIR
    fi

    if [ ! -d "${REPO_DIR}/${1}" ]; then
        tux_error "Failed to find package $1"
        exit 1
    fi

    tux_info "The following packages will be installed:"
    echo $(tux_resolve_deps $1) $1
    if [ "$OPT" == "true" ]; then
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
        source $BUILD_FILE
        if [ ! -d "$BUILD_DIR" ]; then
            mkdir -p $BUILD_DIR
        elif [ -d "$BUILD_DIR" ] && type continuepkg &> /dev/null; then
            tux_info "Build directory already exists, continuing package build..."
            cd $BUILD_DIR
            if [ -f "$ROOT/etc/tux/$pkg-make.conf" ]; then
                source $ROOT/etc/tux/$pkg-make.conf
                for flag in $(cat $ROOT/etc/tux/$pkg-make.conf); do
                    IFS='=' read -ra flags <<< "$flag"
                    export ${flags[0]}
                done
            else
                source $ROOT/etc/tux/make.conf
                for flag in $(cat $ROOT/etc/tux/make.conf); do
                    IFS='=' read -ra flags <<< "$flag"
                    export ${flags[0]}
                done
            fi
            DST=$ROOT/var/lib/tux/$pkg-$pkgver
            mkdir -p $DST
            if ! continuepkg; then
                tux_error "Failed to build package $pkg"
                rm -rf $BUILD_DIR
                exit 1
            fi
            tux_info "Installing package ${pkg}..."
            if ! installpkg; then
                tux_error "Failed to install package ${pkg}"
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
                    tux_error "Package may not be installed correctly"
                    rm -rf $BUILD_DIR $DST $INDEX_DIR
                    exit 1
                fi
            fi
            tux_info "Cleaning up..."
            rm -rf $BUILD_DIR $DST
	        unset -f buildpkg
	        unset -f installpkg
	        unset -f postinstpkg
            unset -f continuepkg
            unset -f copypkgfiles
            tux_success "Successfully installed $pkg"
            continue
        fi
        tux_info "Downloading files for package ${pkg}..."
        sleep 0.5
        for url in ${pkgurls[@]}; do
            IFS='/' read -ra pkgnm <<< "$url"
            if [ ! -f "$ROOT/var/lib/tux/sources/${pkgnm[-1]}" ]; then
                wget -c $url -P ${BUILD_DIR}/
            else
                cp $ROOT/var/lib/tux/sources/${pkgnm[-1]} $BUILD_DIR/
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
        if [ -f "$ROOT/etc/tux/$pkg-make.conf" ]; then
            source $ROOT/etc/tux/$pkg-make.conf
            for flag in $(cat $ROOT/etc/tux/$pkg-make.conf); do
                IFS='=' read -ra flags <<< "$flag"
                export ${flags[0]}
            done
        else
            source $ROOT/etc/tux/make.conf
            for flag in $(cat $ROOT/etc/tux/make.conf); do
                IFS='=' read -ra flags <<< "$flag"
                export ${flags[0]}
            done
        fi
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
            rm -rf $BUILD_DIR
            exit 1
        fi
        tux_info "Installing package ${pkg}..."
        sleep 0.5
        if ! installpkg; then
            tux_error "Failed to install package ${pkg}"
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
                tux_error "Package may not be installed correctly"
                rm -rf $BUILD_DIR $DST $INDEX_DIR
                exit 1
            fi
        fi
        tux_info "Cleaning up..."
        rm -rf $BUILD_DIR $DST $LOG_FILE
	    unset -f buildpkg
	    unset -f installpkg
	    unset -f postinstpkg
        unset -f continuepkg
        unset -f copypkgfiles
        tux_success "Successfully installed ${pkg}"
    done
}

tux_update() {
    tux_info "Cloning package repository..."
    rm -rf $REPO_DIR
    git clone $(cat REPO_FILE) REPO_DIR
    tux_success "Repository successfully cloned"
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
    [ -z "$NINJAJOBS" ] && echo NINJAJOBS=-j$(nproc) >> $ROOT/etc/tux/make.conf || echo NINJAJOBS=$NINJAJOBS >> $ROOT/etc/tux/make.conf
    [ -z "$CFLAGS" ] || echo CFLAGS=$CFLAGS >> $ROOT/etc/tux/make.conf
    [ -z "$CXXFLAGS" ] || echo CXXFLAGS=$CXXFLAGS >> $ROOT/etc/tux/make.conf
    [ -z "$CPPFLAGS" ] || echo CPPFLAGS=$CPPFLAGS >> $ROOT/etc/tux/make.conf
    [ -z "$LDFLAGS" ] || echo LDFLAGS=$LDFLAGS >> $ROOT/etc/tux/make.conf
    echo https://github.com/themakerofstuff/tuxpkgs > $REPO_FILE
    tux_info "Cloning package repository..."
    sleep 0.3
    if [ ! -d "$REPO_DIR" ]; then
    	git clone $(cat $REPO_FILE) $REPO_DIR
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
    tux_info "Mounting virtual file systems..."
    mkdir -pv $ROOT/{dev,proc,sys,run}
    mount -v --bind /dev $ROOT/dev
    mount -vt devpts devpts -o gid=5,mode=0620 $ROOT/dev/pts
    mount -vt proc proc $ROOT/proc
    mount -vt sysfs sysfs $ROOT/sys
    mount -vt tmpfs tmpfs $ROOT/run
    if [ -h $LFS/dev/shm ]; then
        install -v -d -m 1777 $ROOT$(realpath /dev/shm)
    else
        mount -vt tmpfs -o nosuid,nodev tmpfs $ROOT/dev/shm
    fi
    tux_info "Creating full root filesystem..."
    chroot $ROOT /usr/bin/env -i HOME=/root TERM="$TERM" PS1="(chroot)\u:\w$ " PATH=/usr/bin:/usr/sbin /bin/bash --login -e << "EOT"
mkdir -pv /{boot,home,mnt,opt,srv}
mkdir -pv /etc/{opt,sysconfig}
mkdir -pv /lib/firmware
mkdir -pv /media/{floppy,cdrom}
mkdir -pv /usr/{,local/}{include,src}
mkdir -pv /usr/lib/locale
mkdir -pv /usr/local/{bin,lib,sbin}
mkdir -pv /usr/{,local/}share/{color,dict,doc,info,locale,man}
mkdir -pv /usr/{,local/}share/{misc,terminfo,zoneinfo}
mkdir -pv /usr/{,local/}share/man/man{1..8}
mkdir -pv /var/{cache,local,log,mail,opt,spool}
mkdir -pv /var/lib/{color,misc,locate}

[ -d "/var/run" ] || ln -sfv /run /var/run
[ -d "/var/lock" ] || ln -sfv /run/lock /var/lock

install -dv -m 0750 /root
install -dv -m 1777 /tmp /var/tmp
[ -f "/etc/mtab" ] || ln -sv /proc/self/mounts /etc/mtab
cat > /etc/hosts << EOF
127.0.0.1  localhost $(hostname)
::1        localhost
EOF
cat > /etc/passwd << "EOF"
root:x:0:0:root:/root:/bin/bash
bin:x:1:1:bin:/dev/null:/usr/bin/false
daemon:x:6:6:Daemon User:/dev/null:/usr/bin/false
messagebus:x:18:18:D-Bus Message Daemon User:/run/dbus:/usr/bin/false
systemd-journal-gateway:x:73:73:systemd Journal Gateway:/:/usr/bin/false
systemd-journal-remote:x:74:74:systemd Journal Remote:/:/usr/bin/false
systemd-journal-upload:x:75:75:systemd Journal Upload:/:/usr/bin/false
systemd-network:x:76:76:systemd Network Management:/:/usr/bin/false
systemd-resolve:x:77:77:systemd Resolver:/:/usr/bin/false
systemd-timesync:x:78:78:systemd Time Synchronization:/:/usr/bin/false
systemd-coredump:x:79:79:systemd Core Dumper:/:/usr/bin/false
uuidd:x:80:80:UUID Generation Daemon User:/dev/null:/usr/bin/false
systemd-oom:x:81:81:systemd Out Of Memory Daemon:/:/usr/bin/false
nobody:x:65534:65534:Unprivileged User:/dev/null:/usr/bin/false
EOF
cat > /etc/group << "EOF"
root:x:0:
bin:x:1:daemon
sys:x:2:
kmem:x:3:
tape:x:4:
tty:x:5:
daemon:x:6:
floppy:x:7:
disk:x:8:
lp:x:9:
dialout:x:10:
audio:x:11:
video:x:12:
utmp:x:13:
cdrom:x:15:
adm:x:16:
messagebus:x:18:
systemd-journal:x:23:
input:x:24:
mail:x:34:
kvm:x:61:
systemd-journal-gateway:x:73:
systemd-journal-remote:x:74:
systemd-journal-upload:x:75:
systemd-network:x:76:
systemd-resolve:x:77:
systemd-timesync:x:78:
systemd-coredump:x:79:
uuidd:x:80:
systemd-oom:x:81:
wheel:x:97:
users:x:999:
nogroup:x:65534:
EOF
localedef -i C -f UTF-8 C.UTF-8
EOT
    chroot $ROOT /usr/bin/env -i HOME=/root TERM="$TERM" PS1="(chroot)\u:\w$ " PATH=/usr/bin:/usr/sbin /bin/bash --login -e << "EOT"
touch /var/log/{btmp,lastlog,faillog,wtmp}
chgrp -v utmp /var/log/lastlog
chmod -v 664  /var/log/lastlog
chmod -v 600  /var/log/btmp
EOT
    tux_info "Building base-temptools..."
    chroot $ROOT /usr/bin/env -i HOME=/root TERM="$TERM" PS1="(chroot)\u:\w$ " PATH=/usr/bin:/usr/sbin /bin/bash --login -e << "EOT"
export ROOT=""
tux install base-temptools
EOT
    tux_info "Cleaning up temporary tools..."
    chroot $ROOT /usr/bin/env -i HOME=/root TERM="$TERM" PS1="(chroot)\u:\w$ " PATH=/usr/bin:/usr/sbin /bin/bash --login -e << "EOT"
rm -rf /usr/share/{info,man,doc}/*
find /usr/{lib,libexec} -name \*.la -delete
rm -rf /tools
EOT
    tux_info "Building base..."
    chroot $ROOT /usr/bin/env -i HOME=/root TERM="$TERM" PS1="(chroot)\u:\w$ " PATH=/usr/bin:/usr/sbin /bin/bash --login -e << "EOT"
export ROOT=""
tux install base
EOT
    tux_info "Cleaning up..."
    chroot $ROOT /usr/bin/env -i HOME=/root TERM="$TERM" PS1="(chroot)\u:\w$ " PATH=/usr/bin:/usr/sbin /bin/bash --login -e << "EOT"
save_usrlib="$(cd /usr/lib; ls ld-linux*[^g])
             libc.so.6
             libthread_db.so.1
             libquadmath.so.0.0.0
             libstdc++.so.6.0.33
             libitm.so.1.0.0
             libatomic.so.1.2.0"

cd /usr/lib

for LIB in $save_usrlib; do
    objcopy --only-keep-debug --compress-debug-sections=zlib $LIB $LIB.dbg
    cp $LIB /tmp/$LIB
    strip --strip-unneeded /tmp/$LIB
    objcopy --add-gnu-debuglink=$LIB.dbg /tmp/$LIB
    install -vm755 /tmp/$LIB /usr/lib
    rm /tmp/$LIB
done

online_usrbin="bash find strip"
online_usrlib="libbfd-2.43.1.so
               libsframe.so.1.0.0
               libhistory.so.8.2
               libncursesw.so.6.5
               libm.so.6
               libreadline.so.8.2
               libz.so.1.3.1
               libzstd.so.1.5.6
               $(cd /usr/lib; find libnss*.so* -type f)"

for BIN in $online_usrbin; do
    cp /usr/bin/$BIN /tmp/$BIN
    strip --strip-unneeded /tmp/$BIN
    install -vm755 /tmp/$BIN /usr/bin
    rm /tmp/$BIN
done

for LIB in $online_usrlib; do
    cp /usr/lib/$LIB /tmp/$LIB
    strip --strip-unneeded /tmp/$LIB
    install -vm755 /tmp/$LIB /usr/lib
    rm /tmp/$LIB
done

for i in $(find /usr/lib -type f -name \*.so* ! -name \*dbg) \
         $(find /usr/lib -type f -name \*.a)                 \
         $(find /usr/{bin,sbin,libexec} -type f); do
    case "$online_usrbin $online_usrlib $save_usrlib" in
        *$(basename $i)* )
            ;;
        * ) strip --strip-unneeded $i
            ;;
    esac
done

unset BIN LIB save_usrlib online_usrbin online_usrlib
rm -rf /tmp/{*,.*}
find /usr/lib /usr/libexec -name \*.la -delete
find /usr -depth -name $(uname -m)-tux-linux-gnu\* | xargs rm -rf
rm -rf /etc/tux/installed/*-bootstrap /etc/tux/installed/*-temp /etc/tux/installed/base-temptools
rm -rf /var/lib/tux/sources/*
EOT
}

tux_download() {
    OPT=$2
    if [ ! -d "$REPO_DIR" ]; then
        tux_info "Package repository not found, cloning it..."
        git clone $(cat $REPO_FILE) $REPO_DIR
    fi

    if [ ! -d "${REPO_DIR}/${1}" ]; then
        tux_error "Failed to find package $1"
        exit 1
    fi

    tux_info "The following packages will be downloaded:"
    echo $(tux_resolve_deps $1 all-deps) $1
    if [ "$OPT" == "true" ]; then
        read -p "Do you want to continue? [y/n] " yn
        if [ "$yn" == "n" ] || [ "$yn" == "N" ]; then
            exit 1
        fi
    fi
    deps=( $(tux_resolve_deps $1 all-deps) $1 )
    for pkg in ${deps[@]}; do
        mkdir -p $ROOT/var/lib/tux/sources
        tux_info "Downloading package ${pkg}..."
        sleep 0.5
        source $REPO_DIR/$pkg/tuxbuild
        for url in ${pkgurls[@]}; do
            IFS='/' read -ra pkgnm <<< "$url"
            if [ ! -f "$ROOT/var/lib/tux/sources/${pkgnm[-1]}" ]; then
                wget -c $url -P $ROOT/var/lib/tux/sources
            fi
        done
        tux_success "Successfully downloaded $pkg"
    done
}

if [ "$EUID" != "0" ]; then tux_error "This must be run as root"; exit 1; fi

tux_info "Using ${ROOT}/ as root directory"

if [ "$OPTION" == "install" ] && [ "$PACKAGE" != "" ]; then
    [ "$3" == "-y" ] && tux_install $PACKAGE false || tux_install $PACKAGE true
elif [ "$OPTION" == "bootstrap" ]; then
    tux_bootstrap
elif [ "$OPTION" == "check-deps" ]; then
    tux_check_deps_bootstrap
else
    tux_error "Valid arguments not specified"
    exit 1
fi
