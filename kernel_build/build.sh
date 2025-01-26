#!/bin/bash

XY_VERSION="R1.0-RQT"

set -e

if [ -z "$1" ]; then
    echo "Please exec from root directory"
    exit 1
fi
cd "$1"

if [ "$(uname -m)" != "x86_64" ]; then
  echo "This script requires an x86_64 (64-bit) machine."
  exit 1
fi

export PATH="$(pwd)/kernel_build/bin:$PATH"

# Configs
OUTDIR="$(pwd)/out"
MODULES_OUTDIR="$(pwd)/modules_out"
TMPDIR="$(pwd)/kernel_build/tmp"

IN_PLATFORM="$(pwd)/kernel_build/vboot_platform"
IN_DLKM="$(pwd)/kernel_build/vboot_dlkm"
IN_DTB="$OUTDIR/arch/arm64/boot/dts/exynos/s5e3830.dtb"

PLATFORM_RAMDISK_DIR="$TMPDIR/ramdisk_platform"
DLKM_RAMDISK_DIR="$TMPDIR/ramdisk_dlkm"
MODULES_DIR="$DLKM_RAMDISK_DIR/lib/modules"

MKBOOTIMG="$(pwd)/kernel_build/mkbootimg/mkbootimg.py"
MKDTBOIMG="$(pwd)/kernel_build/dtb/mkdtboimg.py"

OUT_KERNELZIP="$(pwd)/kernel_build/ExynosUnbound-${XY_VERSION}_a14.zip"
OUT_KERNELTAR="$(pwd)/kernel_build/ExynosUnbound-${XY_VERSION}_a14.tar"
OUT_KERNEL="$OUTDIR/arch/arm64/boot/Image"
OUT_BOOTIMG="$(pwd)/kernel_build/zip/boot.img"
OUT_VENDORBOOTIMG="$(pwd)/kernel_build/zip/vendor_boot.img"
OUT_DTBIMAGE="$TMPDIR/dtb.img"

# Kernel-side
BUILD_ARGS="LOCALVERSION=-XyUnbound-${XY_VERSION} KBUILD_BUILD_USER=Gabriel260BR KBUILD_BUILD_HOST=ExynosUnbound"

kfinish() {
    rm -rf "$TMPDIR"
#    rm -rf "$OUTDIR"
    rm -rf "$MODULES_OUTDIR"
}

kfinish

DIR="$(readlink -f .)"
PARENT_DIR="$(readlink -f ${DIR}/..)"

export CROSS_COMPILE="$PARENT_DIR/clang-r450784d/bin/aarch64-linux-gnu-"
export CC="$PARENT_DIR/clang-r450784d/bin/clang"

export PLATFORM_VERSION=13
export ANDROID_MAJOR_VERSION=t
export PATH="$PARENT_DIR/build-tools/path/linux-x86:$PARENT_DIR/clang-r450784d/bin:$PATH"
export TARGET_SOC=s5e3830
export LLVM=1 LLVM_IAS=1
export ARCH=arm64

if [ ! -d "$PARENT_DIR/clang-r450784d" ]; then
    git clone https://gitlab.com/tejas101k/clang-r450784d.git/ "$PARENT_DIR/clang-r450784d" --depth=1
fi

if [ ! -d "$PARENT_DIR/build-tools" ]; then
    git clone https://android.googlesource.com/platform/prebuilts/build-tools "$PARENT_DIR/build-tools" --depth=1
fi

make -j$(nproc --all) -C $(pwd) O=out $BUILD_ARGS a14_defconfig
make -j$(nproc --all) -C $(pwd) O=out $BUILD_ARGS dtbs
make -j$(nproc --all) -C $(pwd) O=out $BUILD_ARGS
make -j$(nproc --all) -C $(pwd) O=out INSTALL_MOD_STRIP="--strip-debug --keep-section=.ARM.attributes" INSTALL_MOD_PATH="$MODULES_OUTDIR" modules_install

rm -rf "$TMPDIR"
rm -f "$OUT_BOOTIMG"
rm -f "$OUT_VENDORBOOTIMG"
mkdir "$TMPDIR"
mkdir -p "$MODULES_DIR/0.0"
mkdir "$PLATFORM_RAMDISK_DIR"

cp -rf "$IN_PLATFORM"/* "$PLATFORM_RAMDISK_DIR/"
mkdir -p "$PLATFORM_RAMDISK_DIR/first_stage_ramdisk"
cp -f "$PLATFORM_RAMDISK_DIR/fstab.s5e3830" "$PLATFORM_RAMDISK_DIR/first_stage_ramdisk/fstab.s5e3830"

if ! find "$MODULES_OUTDIR/lib/modules" -mindepth 1 -type d | read; then
    echo "Unknown error!"
    exit 1
fi

missing_modules=""

for module in $(cat "$IN_DLKM/modules.load"); do
    i=$(find "$MODULES_OUTDIR/lib/modules" -name $module);
    if [ -f "$i" ]; then
        cp -f "$i" "$MODULES_DIR/0.0/$module"
    else
	missing_modules="$missing_modules $module"
    fi
done

if [ "$missing_modules" != "" ]; then
        echo "ERROR: the following modules were not found: $missing_modules"
	exit 1
fi

depmod 0.0 -b "$DLKM_RAMDISK_DIR"
sed -i 's/\([^ ]\+\)/\/lib\/modules\/\1/g' "$MODULES_DIR/0.0/modules.dep"
cd "$MODULES_DIR/0.0"
for i in $(find . -name "modules.*" -type f); do
    if [ $(basename "$i") != "modules.dep" ] && [ $(basename "$i") != "modules.softdep" ] && [ $(basename "$i") != "modules.alias" ]; then
        rm -f "$i"
    fi
done
cd "$DIR"

cp -f "$IN_DLKM/modules.load" "$MODULES_DIR/0.0/modules.load"
mv "$MODULES_DIR/0.0"/* "$MODULES_DIR/"
rm -rf "$MODULES_DIR/0.0"

echo "Building dtb image..."
python2 "$MKDTBOIMG" create "$OUT_DTBIMAGE" --custom0=0x00000000 --custom1=0xff000000 --version=0 --page_size=2048 "$IN_DTB" || exit 1

echo "Building boot image..."

$MKBOOTIMG --header_version 4 \
    --kernel "$OUT_KERNEL" \
    --output "$OUT_BOOTIMG" \
    --os_version 13.0.0 \
    --os_patch_level 2025-01 || exit 1

echo "Done!"
echo "Building vendor_boot image..."

cd "$DLKM_RAMDISK_DIR"
find . | cpio --quiet -o -H newc -R root:root | lz4 -9cl > ../ramdisk_dlkm.lz4
cd ../ramdisk_platform
find . | cpio --quiet -o -H newc -R root:root | lz4 -9cl > ../ramdisk_platform.lz4
cd ..
echo "buildtime_bootconfig=enable" > bootconfig

$MKBOOTIMG --header_version 4 \
    --vendor_boot "$OUT_VENDORBOOTIMG" \
    --vendor_bootconfig "$(pwd)/bootconfig" \
    --dtb "$OUT_DTBIMAGE" \
    --vendor_ramdisk "$(pwd)/ramdisk_platform.lz4" \
    --ramdisk_type dlkm \
    --ramdisk_name dlkm \
    --vendor_ramdisk_fragment "$(pwd)/ramdisk_dlkm.lz4" \
    --os_version 13.0.0 \
    --os_patch_level 2025-01 || exit 1

cd "$DIR"

echo "Done!"

echo "Building zip..."
cd "$(pwd)/kernel_build/zip"
rm -f "$OUT_KERNELZIP"
brotli --quality=6 -c boot.img > boot.br
brotli --quality=6 -c vendor_boot.img > vendor_boot.br
zip -r9 -q "$OUT_KERNELZIP" META-INF boot.br vendor_boot.br
rm -f boot.br vendor_boot.br
cd "$DIR"
echo "Done! Output: $OUT_KERNELZIP"

echo "Building tar..."
cd "$(pwd)/kernel_build"
rm -f "$OUT_KERNELTAR"
lz4 -c -12 -B6 --content-size "$OUT_BOOTIMG" > boot.img.lz4
lz4 -c -12 -B6 --content-size "$OUT_VENDORBOOTIMG" > vendor_boot.img.lz4
tar -cf "$OUT_KERNELTAR" boot.img.lz4 vendor_boot.img.lz4
cd "$DIR"
rm -f boot.img.lz4 vendor_boot.img.lz4
echo "Done! Output: $OUT_KERNELTAR"

echo "Cleaning..."
rm -f "${OUT_VENDORBOOTIMG}" "${OUT_BOOTIMG}"
kfinish
