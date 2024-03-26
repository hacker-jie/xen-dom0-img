# xen-dom0-img

### Build
``` shell
1. correct the Linux, Qemu and Xen links to your location
2. In Xen (v4.18 or later) folder
   make distclean
   make -C xen XEN_TARGET_ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
   make dist-xen XEN_TARGET_ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
3. ./build_img.sh
```

### QEMU Command

```shell
qemu-system-aarch64 -gdb tcp::3333 \
	-machine virt,gic_version=3 -machine virtualization=true \
	-cpu cortex-a53 -smp 4 -m 2G -nographic \
	-netdev user,id=net0,hostfwd=tcp::2222-:22 -device virtio-net-device,netdev=net0 \
	-kernel ./xen/xen/xen \
	-device loader,file=./linux/arch/arm64/boot/Image,addr=0x40600000 \
	-drive if=virtio,file=./dom0.img,format=raw \
	-dtb ./virt-gicv3.dtb
```
