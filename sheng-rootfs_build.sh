#!/bin/bash
set -e
IMAGE_SIZE="8G"
FILESYSTEM_UUID="ee8d3593-59b1-480e-a3b6-4fefb17ee7d8"

if [ $# -lt 2 ]; then exit 1; fi
if [ "$(id -u)" -ne 0 ]; then exit 1; fi

DISTRO=$1
KERNEL=$2
TARGET_MODE=${3:-all}
TARGET_FLAVOUR=${4:-all} 
CUSTOM_USER=${5:-xiaomi}
CUSTOM_PASS=${6:-123456}

distro_version="trixie"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

BOOTMODES=("$TARGET_MODE")
FLAVOURS=("$TARGET_FLAVOUR")

cleanup_mounts() {
    fuser -k -9 -m rootdir 2>/dev/null || true
    sleep 2; umount -l rootdir/dev/pts 2>/dev/null || true
    umount -l rootdir/dev 2>/dev/null || true
    umount -l rootdir/proc 2>/dev/null || true
    umount -l rootdir/sys 2>/dev/null || true
    umount -l rootdir 2>/dev/null || true
    rm -rf rootdir
}
trap cleanup_mounts EXIT ERR INT TERM

for FLAVOUR in "${FLAVOURS[@]}"; do
    for MODE in "${BOOTMODES[@]}"; do
        ROOTFS_IMG="debian_${distro_version}_${FLAVOUR}_${MODE}_${TIMESTAMP}.img"
        cleanup_mounts; mkdir -p rootdir
        truncate -s $IMAGE_SIZE "$ROOTFS_IMG"
        mkfs.ext4 -O ^metadata_csum "$ROOTFS_IMG"
        mount -o loop "$ROOTFS_IMG" rootdir

        debootstrap --arch=arm64 "$distro_version" rootdir http://deb.debian.org/debian/
        mount --bind /dev rootdir/dev; mount --bind /dev/pts rootdir/dev/pts
        mount -t proc proc rootdir/proc; mount -t sysfs sys rootdir/sys

        echo "nameserver 8.8.8.8" > rootdir/etc/resolv.conf
        chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get update && apt-get install -y --no-install-recommends systemd sudo vim wget curl network-manager openssh-server wpasupplicant dbus locales dialog"

        sed -i 's/^# *\(en_US.UTF-8\)/\1/' rootdir/etc/locale.gen
        sed -i 's/^# *\(zh_CN.UTF-8\)/\1/' rootdir/etc/locale.gen
        chroot rootdir locale-gen
        echo "LANG=zh_CN.UTF-8" > rootdir/etc/default/locale
        echo "LANG=zh_CN.UTF-8" > rootdir/etc/locale.conf
        chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y fonts-noto-cjk fonts-wqy-microhei fcitx5 fcitx5-chinese-addons"

        mapfile -t DRIVER_DEBS < <(find . -maxdepth 1 -type f -name "*.deb" -printf "%f\n" | sort)
        if [ "${#DRIVER_DEBS[@]}" -eq 0 ]; then
            echo "No Debian driver packages found before rootfs install"
            exit 1
        fi

        DRIVER_PACKAGES=()
        for deb in "${DRIVER_DEBS[@]}"; do
            pkg="$(dpkg-deb -f "$deb" Package)"
            test -n "$pkg" || { echo "Cannot read package name from $deb"; exit 1; }
            DRIVER_PACKAGES+=("$pkg")
            echo "Will install release Debian package: $deb -> $pkg"
        done
        cp "${DRIVER_DEBS[@]}" rootdir/tmp/

        chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y libglib2.0-0 libprotobuf-c1 libqmi-glib5 libmbim-glib4 initramfs-tools alsa-ucm-conf"
        chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get -o Dpkg::Options::='--force-overwrite' install -y /tmp/*.deb"
        chroot rootdir bash -c "dpkg --configure -a && apt-get -f install -y"
        chroot rootdir bash -c "dpkg-query -W -f='\${Package} \${Status}\n' ${DRIVER_PACKAGES[*]}"
        for pkg in "${DRIVER_PACKAGES[@]}"; do
            chroot rootdir dpkg-query -W -f='${Status}' "$pkg" | grep -q '^install ok installed$'
            echo "Verified release Debian package installed: $pkg"
        done
        chroot rootdir test -x /usr/bin/xiaomi_devauth

        # The current firmware package may place device firmware under /usr/lib
        # directly. Linux firmware_class searches /lib/firmware, which resolves
        # to /usr/lib/firmware on Debian usrmerge systems.
        mkdir -p rootdir/usr/lib/firmware
        for fwdir in ath12k qcom nanosic cirrus; do
            if [ -d "rootdir/usr/lib/$fwdir" ]; then
                rm -rf "rootdir/usr/lib/firmware/$fwdir"
                cp -a "rootdir/usr/lib/$fwdir" rootdir/usr/lib/firmware/
                echo "Mirrored $fwdir firmware into /usr/lib/firmware"
            else
                echo "Missing optional firmware directory: /usr/lib/$fwdir"
            fi
        done
        if [ -f rootdir/usr/lib/firmware/ath12k/WCN7850/hw2.0/board-2.bin ] && [ ! -e rootdir/usr/lib/firmware/ath12k/WCN7850/hw2.0/board.bin ]; then
            ln -s board-2.bin rootdir/usr/lib/firmware/ath12k/WCN7850/hw2.0/board.bin
            echo "Added ath12k board.bin compatibility symlink"
        fi

        for required_path in \
            usr/lib/firmware/nanosic/MCU_Upgrade.bin \
            usr/lib/firmware/ath12k/WCN7850/hw2.0/board-2.bin \
            usr/lib/firmware/ath12k/WCN7850/hw2.0/board.bin \
            usr/lib/firmware/qcom/sm8550/sheng \
            usr/lib/firmware/cirrus; do
            if [ ! -e "rootdir/$required_path" ]; then
                echo "Required sheng firmware path is missing after package install: /$required_path"
                exit 1
            fi
        done

        for required_module in \
            hid-nanosic-wn8030.ko.zst \
            hid-multitouch.ko.zst \
            nt36532e_ts.ko.zst \
            goodix_berlin_spi.ko.zst; do
            if ! find rootdir/usr/lib/modules -name "$required_module" -print -quit | grep -q .; then
                echo "Required sheng input/touch module is missing: $required_module"
                exit 1
            fi
        done

        mkdir -p rootdir/etc/modules-load.d
        cat > rootdir/etc/modules-load.d/sheng-input.conf <<'EOF'
hid_generic
hid_multitouch
hid_nanosic_wn8030
i2c_hid_of
i2c_hid_of_elan
nt36532e_ts
goodix_ts
goodix_berlin_core
goodix_berlin_spi
EOF

        cat > rootdir/etc/modules-load.d/sheng-platform.conf <<'EOF'
ath12k
ath12k_wifi7
fastrpc
qcom_battmgr
qcom_q6v5_pas
qcom_q6v5_adsp
qcom_pil_info
qcom_sysmon
qcom_glink_smem
EOF

        mkdir -p rootdir/etc/udev/rules.d
        printf 'ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="1 0 0 0 1 0 0 0 1"\n' > rootdir/etc/udev/rules.d/99-touchscreen-sheng.rules
        chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y qrtr-tools || true"
        chroot rootdir systemctl enable qrtr-ns || true
        
        chroot rootdir bash -c "echo 'root:$CUSTOM_PASS' | chpasswd"
        echo "debian-$FLAVOUR-$MODE" > rootdir/etc/hostname

        chroot rootdir useradd -m -s /bin/bash "$CUSTOM_USER" || true
        chroot rootdir bash -c "echo '$CUSTOM_USER:$CUSTOM_PASS' | chpasswd"
        chroot rootdir usermod -aG sudo,audio,video,input "$CUSTOM_USER"

        if [ "$FLAVOUR" = "gnome" ]; then
            chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y gnome-shell gnome-session gnome-terminal gdm3"
            mkdir -p rootdir/etc/gdm3
            printf "[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=$CUSTOM_USER\n" > rootdir/etc/gdm3/daemon.conf
            chroot rootdir systemctl enable gdm3
        elif [ "$FLAVOUR" = "kde" ]; then
            chroot rootdir bash -c "export DEBIAN_FRONTEND=noninteractive && apt-get install -y kde-standard sddm"
            mkdir -p rootdir/etc/sddm.conf.d
            printf "[Autologin]\nUser=$CUSTOM_USER\nSession=plasma\n" > rootdir/etc/sddm.conf.d/autologin.conf
            chroot rootdir systemctl enable sddm
        fi
        chroot rootdir systemctl enable NetworkManager
        chroot rootdir systemctl set-default graphical.target

        [ "$MODE" = "dual" ] && echo "PARTLABEL=linux / ext4 defaults,noatime,errors=remount-ro 0 1" > rootdir/etc/fstab || echo "PARTLABEL=userdata / ext4 defaults,noatime,errors=remount-ro 0 1" > rootdir/etc/fstab

        chroot rootdir apt-get clean; rm -f rootdir/tmp/*.deb
        cleanup_mounts; tune2fs -U $FILESYSTEM_UUID "$ROOTFS_IMG"
        img2simg "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"
        7z a "${ROOTFS_IMG%.img}.7z" "sparse_${ROOTFS_IMG}"
        rm -f "$ROOTFS_IMG" "sparse_${ROOTFS_IMG}"
    done
done
trap - EXIT ERR INT TERM
