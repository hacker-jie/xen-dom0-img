#!/bin/bash -ex

WRKDIR=$(pwd)/
NPROC=$(nproc)

USERNAME=calinyara
PASSWORD=calinyara
SALT=nice
HASHED_PASSWORD=$(perl -e "print crypt(\"${PASSWORD}\",\"${SALT}\");")
# HASHED_PASSWORD=${PASSWORD}

KERNEL_BUILD_DIR=${WRKDIR}linux/build
QEMU_DIR=${WRKDIR}qemu
XEN_DIR=${WRKDIR}xen

ROOTFSURL=http://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/
ROOTFS=ubuntu-base-22.04-base-arm64.tar.gz
if [ ! -s ${ROOTFS} ]; then
    curl -OLf ${ROOTFSURL}${ROOTFS}
fi

#MNTRAMDISK=/mnt/ramdisk/
#MNTROOTFS=/mnt/qemu-arm64-rootfs/

IMGNAME=dom0.img
MNTRAMDISK=${WRKDIR}ramdisk/
MNTROOTFS=${WRKDIR}qemu-arm64-rootfs/
MNTBOOT=${MNTROOTFS}boot/
if [ ! -s ${IMGNAME} ]; then
    IMGFILE=${MNTRAMDISK}${IMGNAME}
else
    IMGFILE=${IMGNAME}
    IMG_EXISTS=yes
fi

unmountstuff () {
  sudo umount ${MNTROOTFS}proc || true
  sudo umount ${MNTROOTFS}dev/pts || true
  sudo umount ${MNTROOTFS}dev || true
  sudo umount ${MNTROOTFS}sys || true
  sudo umount ${MNTROOTFS}tmp || true
  sudo umount ${MNTBOOT} || true
  sudo umount ${MNTROOTFS} || true
}

mountstuff () {
  sudo mkdir -p ${MNTROOTFS}
  sudo mount ${LOOPDEVROOTFS} ${MNTROOTFS}
  sudo mkdir -p ${MNTBOOT}
  sudo mount ${LOOPDEVBOOT} ${MNTBOOT}
  sudo mount -o bind /proc ${MNTROOTFS}proc
  sudo mount -o bind /dev ${MNTROOTFS}dev
  sudo mount -o bind /dev/pts ${MNTROOTFS}dev/pts
  sudo mount -o bind /sys ${MNTROOTFS}sys
  sudo mount -o bind /tmp ${MNTROOTFS}tmp
}

finish () {
  cd ${WRKDIR}
  sudo sync
  unmountstuff
  sudo kpartx -dvs ${IMGFILE} || true
  sudo rmdir ${MNTROOTFS} || true
  mv ${IMGFILE} . || true
  sudo umount ${MNTRAMDISK} || true
  sudo rmdir ${MNTRAMDISK} || true
}

trap finish EXIT


sudo mkdir -p ${MNTRAMDISK}
sudo mount -t tmpfs -o size=3g tmpfs ${MNTRAMDISK}

if [ "${IMG_EXISTS}" != "yes" ]; then
    qemu-img create ${IMGFILE} 2G
    parted ${IMGFILE} --script -- mklabel msdos
    parted ${IMGFILE} --script -- mkpart primary fat32 2048s 264191s
    parted ${IMGFILE} --script -- mkpart primary ext4 264192s -1s
fi

LOOPDEVS=$(sudo kpartx -avs ${IMGFILE} | awk '{print $3}')
LOOPDEVBOOT=/dev/mapper/$(echo ${LOOPDEVS} | awk '{print $1}')
LOOPDEVROOTFS=/dev/mapper/$(echo ${LOOPDEVS} | awk '{print $2}')

if [ "${IMG_EXISTS}" != "yes" ]; then
    sudo mkfs.vfat ${LOOPDEVBOOT}
    sudo mkfs.ext4 ${LOOPDEVROOTFS}

    sudo fatlabel ${LOOPDEVBOOT} BOOT
    sudo e2label ${LOOPDEVROOTFS} QemuUbuntu

    sudo mkdir -p ${MNTROOTFS}
    sudo mount ${LOOPDEVROOTFS} ${MNTROOTFS}

    sudo tar -C ${MNTROOTFS} -xf ${ROOTFS}
    sudo umount ${MNTROOTFS}
fi

mountstuff

sudo cp `which qemu-aarch64-static` ${MNTROOTFS}usr/bin/

sudo cp $KERNEL_BUILD_DIR/arch/arm64/boot/Image ${MNTBOOT}
cd ${WRKDIR}linux
sudo make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- O=$KERNEL_BUILD_DIR INSTALL_MOD_PATH=${MNTROOTFS} modules_install > ${WRKDIR}modules_install.log
cd ${WRKDIR}

# /etc/resolv.conf is required for internet connectivity in chroot. It will get overwritten by dhcp, so don't get too attached to it.
sudo chroot ${MNTROOTFS} bash -c 'echo "nameserver 8.8.8.8" > /etc/resolv.conf'
sudo chroot ${MNTROOTFS} bash -c 'echo "nameserver 2001:4860:4860::8888" >> /etc/resolv.conf'

if [ "${IMG_EXISTS}" != "yes" ]; then
    sudo sed -i -e "s/# deb /deb /" ${MNTROOTFS}etc/apt/sources.list
    sudo chroot ${MNTROOTFS} apt update
fi
# Install the dialog package and others first to squelch some warnings
sudo chroot ${MNTROOTFS} apt update
sudo chroot ${MNTROOTFS} apt install -y dialog apt-utils
sudo chroot ${MNTROOTFS} apt upgrade -y
sudo chroot ${MNTROOTFS} apt install -y systemd systemd-sysv sysvinit-utils sudo udev rsyslog kmod util-linux sed netbase dnsutils ifupdown isc-dhcp-client isc-dhcp-common less vim net-tools iproute2 iputils-ping libnss-mdns iw software-properties-common ethtool dmsetup hostname iptables logrotate lsb-base lsb-release plymouth psmisc tar tcpd libsystemd-dev symlinks uuid-dev libc6-dev libncurses-dev libglib2.0-dev build-essential bridge-utils zlib1g-dev patch libpixman-1-dev libyajl-dev libfdt-dev libaio-dev python3-dev libxml2-dev libxslt-dev python-dev-is-python3 libzstd-dev pkg-config-aarch64-linux-gnu

# Change the shared library symlinks to relative instead of absolute so they play nice with cross-compiling
sudo chroot ${MNTROOTFS} symlinks -c /usr/lib/aarch64-linux-gnu/

if [ "${IMG_EXISTS}" != "yes" ]; then
cd ${XEN_DIR}

# TODO: --with-xenstored=oxenstored

# Ask the native compiler what system include directories it searches through.
SYSINCDIRS=$(echo $(sudo chroot ${MNTROOTFS} bash -c "echo | gcc -E -Wp,-v -o /dev/null - 2>&1" | grep "^ " | sed "s|^ /| -isystem${MNTROOTFS}|"))
SYSINCDIRSCXX=$(echo $(sudo chroot ${MNTROOTFS} bash -c "echo | g++ -x c++ -E -Wp,-v -o /dev/null - 2>&1" | grep "^ " | sed "s|^ /| -isystem${MNTROOTFS}|"))

sudo cp -f ${QEMU_DIR}/linux-headers/linux/* ${MNTROOTFS}usr/include/linux

LDFLAGS="-Wl,-rpath-link=${MNTROOTFS}lib/aarch64-linux-gnu -Wl,-rpath-link=${MNTROOTFS}usr/lib/aarch64-linux-gnu" \
./configure \
    PYTHON_PREFIX_ARG=--install-layout=deb \
    --enable-systemd \
    --disable-xen \
    --enable-tools \
    --disable-docs \
    --disable-stubdom \
    --prefix=/usr \
    --with-xenstored=xenstored \
    --build=x86_64-linux-gnu \
    --host=aarch64-linux-gnu \
    CC="aarch64-linux-gnu-gcc --sysroot=${MNTROOTFS} -nostdinc ${SYSINCDIRS} -B${MNTROOTFS}lib/aarch64-linux-gnu -B${MNTROOTFS}usr/lib/aarch64-linux-gnu" \
    CXX="aarch64-linux-gnu-g++ --sysroot=${MNTROOTFS} -nostdinc ${SYSINCDIRSCXX} -B${MNTROOTFS}lib/aarch64-linux-gnu -B${MNTROOTFS}usr/lib/aarch64-linux-gnu" \
    PKG_CONFIG_PATH=${MNTROOTFS}usr/lib/aarch64-linux-gnu/pkgconfig:${MNTROOTFS}usr/share/pkgconfig

LDFLAGS="-Wl,-rpath-link=${MNTROOTFS}lib/aarch64-linux-gnu -Wl,-rpath-link=${MNTROOTFS}usr/lib/aarch64-linux-gnu" \
make dist-tools \
    CROSS_COMPILE=aarch64-linux-gnu- XEN_TARGET_ARCH=arm64 \
    CC="aarch64-linux-gnu-gcc --sysroot=${MNTROOTFS} -nostdinc ${SYSINCDIRS} -B${MNTROOTFS}lib/aarch64-linux-gnu -B${MNTROOTFS}usr/lib/aarch64-linux-gnu" \
    CXX="aarch64-linux-gnu-g++ --sysroot=${MNTROOTFS} -nostdinc ${SYSINCDIRSCXX} -B${MNTROOTFS}lib/aarch64-linux-gnu -B${MNTROOTFS}usr/lib/aarch64-linux-gnu" \
    PKG_CONFIG_PATH=${MNTROOTFS}usr/lib/aarch64-linux-gnu/pkgconfig:${MNTROOTFS}usr/share/pkgconfig \
    QEMU_PKG_CONFIG_FLAGS=--define-variable=prefix=${MNTROOTFS}usr \
    -j $(nproc)

sudo --preserve-env PATH=${PATH} \
LDFLAGS="-Wl,-rpath-link=${MNTROOTFS}lib/aarch64-linux-gnu -Wl,-rpath-link=${MNTROOTFS}usr/lib/aarch64-linux-gnu" \
make install-tools \
    CROSS_COMPILE=aarch64-linux-gnu- XEN_TARGET_ARCH=arm64 \
    CC="aarch64-linux-gnu-gcc --sysroot=${MNTROOTFS} -nostdinc ${SYSINCDIRS} -B${MNTROOTFS}lib/aarch64-linux-gnu -B${MNTROOTFS}usr/lib/aarch64-linux-gnu" \
    CXX="aarch64-linux-gnu-g++ --sysroot=${MNTROOTFS} -nostdinc ${SYSINCDIRSCXX} -B${MNTROOTFS}lib/aarch64-linux-gnu -B${MNTROOTFS}usr/lib/aarch64-linux-gnu" \
    PKG_CONFIG_PATH=${MNTROOTFS}usr/lib/aarch64-linux-gnu/pkgconfig:${MNTROOTFS}usr/share/pkgconfig \
    QEMU_PKG_CONFIG_FLAGS=--define-variable=prefix=${MNTROOTFS}usr \
    DESTDIR=${MNTROOTFS}

sudo chroot ${MNTROOTFS} systemctl enable xen-qemu-dom0-disk-backend.service
sudo chroot ${MNTROOTFS} systemctl enable xen-init-dom0.service
sudo chroot ${MNTROOTFS} systemctl enable xenconsoled.service
sudo chroot ${MNTROOTFS} systemctl enable xendomains.service
sudo chroot ${MNTROOTFS} systemctl enable xen-watchdog.service

cd ${WRKDIR}
fi

# It seems like the xen tools configure script selects a few too many of these backend driver modules, so we override it with a simpler list.
# /usr/lib/modules-load.d/xen.conf
cat > tmp-qemuxen-script-generated-xen.conf <<EOF
xen-evtchn
xen-gntdev
xen-gntalloc
xen-blkback
xen-netback
EOF
sudo cp tmp-qemuxen-script-generated-xen.conf ${MNTROOTFS}usr/lib/modules-load.d/xen.conf
rm tmp-qemuxen-script-generated-xen.conf

# /etc/hostname
HOSTNAME=ubuntu
sudo bash -c "echo ${HOSTNAME} > ${MNTROOTFS}etc/hostname"

# /etc/hosts
cat > tmp-qemuxen-script-generated-hosts <<EOF
127.0.0.1	localhost
127.0.1.1	${HOSTNAME}

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

EOF
sudo cp tmp-qemuxen-script-generated-hosts ${MNTROOTFS}etc/hosts
rm tmp-qemuxen-script-generated-hosts

# /etc/fstab
cat > tmp-qemuxen-script-generated-fstab <<EOF
proc            /proc           proc    defaults          0       0
/dev/vda1       /boot           vfat    defaults          0       2
/dev/vda2       /               ext4    defaults,noatime  0       1
EOF
sudo cp tmp-qemuxen-script-generated-fstab ${MNTROOTFS}etc/fstab
rm tmp-qemuxen-script-generated-fstab

# /etc/network/interfaces.d/eth0br0
cat > tmp-qemuxen-script-generated-interfaces <<EOF
auto eth0
iface eth0 inet manual

auto br0
iface br0 inet dhcp
    bridge_ports eth0
EOF
sudo cp tmp-qemuxen-script-generated-interfaces ${MNTROOTFS}etc/network/interfaces.d/eth0br0
rm tmp-qemuxen-script-generated-interfaces
sudo chmod 0600 ${MNTROOTFS}etc/network/interfaces.d/eth0br0

# User account setup
if [ "${IMG_EXISTS}" != "yes" ]; then
    sudo chroot ${MNTROOTFS} useradd -s /bin/bash -G adm,sudo -m -p ${HASHED_PASSWORD} ${USERNAME}
fi

unmountstuff
