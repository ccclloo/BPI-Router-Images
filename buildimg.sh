#!/bin/bash
#sudo apt-get install qemu-user-static debootstrap binfmt-support
#r2: dev: 0 part: 1/2
#r64: dev: 1 part: 4/5 (maybe needs fix for root in uboot, boot is checked by checkgpt)
#r2pro: dev: 1 part: 2/3
#r3: dev: 0 part: 5/6
board=$1
distro=$2 #buster|bullseye|jammy
kernel="6.1"
case "$board" in
	"bpi-r2")
		mmcdev=0
		mmcbootpart=1
		mmcrootpart=2
		arch="armhf"
		kernel="5.15" #6.0+ does not support internal wifi
	;;
	"bpi-r64")
		mmcdev=1
		mmcbootpart=4
		mmcrootpart=5
		arch="arm64"
	;;
	"bpi-r2pro")
		mmcdev=0
		mmcbootpart=2
		mmcrootpart=3
		arch="arm64"
	;;
	"bpi-r3")
		mmcdev=0
		mmcbootpart=5
		mmcrootpart=6
		arch="arm64"
	;;
	*)
		echo "missing/unsupported board $1";exit
	;;
esac

LDEV=`losetup -f`

function cleanup() {
	sudo umount mnt/BPI-BOOT
	sudo umount mnt/BPI-ROOT
	sudo losetup -d $1
}

trap ctrl_c INT
function ctrl_c() {
        echo "** Trapped CTRL-C ($LDEV)"
	cleanup $LDEV
	exit 1
}

echo "create image for ${board} (${arch}) ${distro} ${kernel}"

python3 downloadfiles.py ${board} ${kernel}

. sourcefiles_${board}.conf
echo "image-file:"$imgfile
echo "kernel-file:"$kernelfile
if [[ ! -e ${distro}_${arch}.tar.gz ]];then
	./buildchroot.sh ${arch} ${distro}
else
	echo "packed rootfs already exists"
fi
ls -lh ${distro}_${arch}.tar.gz
ls -lh ${imgfile}

newimgfile=${board}_${distro}_${kernel}.img.gz
cp $imgfile $newimgfile
echo "unpack imgfile..."
gunzip $newimgfile
echo "setting up imgfile to loopdev..."
sudo losetup ${LDEV} ${newimgfile%.*} 1> /dev/null
echo "mounting loopdev..."
sudo partprobe ${LDEV}
mkdir -p mnt/BPI-{B,R}OOT
sudo mount ${LDEV}p${mmcbootpart} mnt/BPI-BOOT
sudo mount ${LDEV}p${mmcrootpart} mnt/BPI-ROOT
echo "unpack rootfs to bpi-root loopdev..."
sudo tar -xzf ${distro}_${arch}.tar.gz -C mnt/BPI-ROOT
echo "unpack kernel to bpi-boot loopdev..."
sudo tar -xzf $kernelfile --strip-components=1 -C mnt/BPI-BOOT BPI-BOOT
echo "unpack kernel-modules to bpi-root loopdev..."
sudo tar -xzf $kernelfile --strip-components=2 -C mnt/BPI-ROOT/lib/. BPI-ROOT/lib/

if [[ "$board" == "bpi-r2pro" ]];then
	conffile=mnt/BPI-BOOT/extlinux/extlinux.conf
	#mkdir -p $(dirname ${conffile})
	imgname="Image.gz"
	dtbname="bpi-r2pro.dtb"
	ls -la $(dirname ${conffile})
	echo -e "menu title Select the boot mode\n#timeout 1/10s\nTIMEOUT 50\nDEFAULT linux" | sudo tee $conffile
	echo -e "LABEL linux\n	linux $imgname\n	fdt $dtbname\n"\
		"	append earlycon=uart8250,mmio32,0xfe660000 " \
		"console=ttyS2,1500000n8 root=/dev/mmcblk${mmcdev}p${mmcrootpart} rootwait rw " \
		"earlyprintk" | sudo tee -a $conffile
	cat ${conffile}
fi

echo "configure rootfs for ${board}..."

targetdir="mnt/BPI-ROOT"

sudo chroot $targetdir tee "/etc/fstab" > /dev/null <<EOF
# <file system>		<dir>	<type>	<options>		<dump>	<pass>
/dev/mmcblk${mmcdev}p${mmcbootpart}		/boot	vfat	errors=remount-ro	0	1
/dev/mmcblk${mmcdev}p${mmcrootpart}		/	ext4	defaults		0	0
EOF

echo $board | sudo tee $targetdir/etc/hostname

if [[ ${board} != "bpi-r2pro" ]];then
	sudo chroot $targetdir bash -c "apt update; apt install --no-install-recommends -y hostapd iw xz-utils"
fi

sudo cp -r conf/generic/* ${targetdir}/
if [[ -e conf/$board ]];then
	sudo rsync -av --partial --progress --exclude={'bin','lib','sbin'} conf/${board}/. ${targetdir}/

	#fix for copy dir over symlink (rejected by cp)
	for d in bin lib sbin;do
		if [[ -d conf/${board}/$d ]];then
			sudo cp -r conf/${board}/$d/* ${targetdir}/$d/
		fi
	done
fi
sudo chroot $targetdir bash -c "systemctl enable systemd-networkd"

#wifi related commands
if [[ ${board} != "bpi-r2pro" ]];then
	#fix for ConditionFileNotEmpty in existing hostapd service (can also point to ${DAEMON_CONF})
	sudo chroot $targetdir bash -c "ln -fs hostapd_wlan0.conf /etc/hostapd/hostapd.conf"

	#copy firmware
	if [[ ! -d firmware ]];
	then
		./getfirmware.sh
	fi
	echo "copy firmware files"
	sudo cp -r firmware/* ${targetdir}/lib/firmware/

	curl https://git.kernel.org/pub/scm/linux/kernel/git/sforshee/wireless-regdb.git/plain/regulatory.db -o regulatory.db
	curl https://git.kernel.org/pub/scm/linux/kernel/git/sforshee/wireless-regdb.git/plain/regulatory.db.p7s -o regulatory.db.p7s

	sudo cp -r regulatory.* ${targetdir}/lib/firmware/
fi

#install/start resolved after all is done
sudo chroot $targetdir bash -c "apt install -y systemd-resolved;systemctl enable systemd-resolved"

cleanup ${LDEV}

echo "packing ${newimgfile}"
gzip ${newimgfile%.*}
