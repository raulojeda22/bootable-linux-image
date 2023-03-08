#!/bin/bash
# @author Raül Ojeda Gandia
# Exercise 1 Bootable Linux image via QEMU

SCRIPT=$(realpath "$0")
SCRIPT_PATH=$(dirname "$SCRIPT")
KERN_VERS="${1:-6.2.2}" # KERN_VERS format: ^([3-6]+\.)?(\d+\.)?(\*|\d+)$
MAJOR_VERS=$(echo "$KERN_VERS" | cut -d"." -f1) # e.g.: 6.2.2 -> 6
KERN_BASE_URL="https://cdn.kernel.org/pub/linux/kernel"
BUSYBOX_VERS="${2:-1.33.2}"
BUSYBOX_BASE_URL="https://busybox.net/downloads"
ORIGINAL_PATH=$(pwd)

info() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&1
}

err() {
  echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')]: $*" >&2
}

######################################
# Must download file from given url
# Terminates program otherwise
# Arguments:
#   $1 Filename
#   $2 Url
######################################
must_download() {
  info "Downloading $2"
  if ! curl -sL -o "$1" "$2" || [ ! -f "$1" ]; then
    err "Failure downloading file from $2."
    err "Check the filename, the url or your internet connection."
    err "Aborting script."
    cd "$ORIGINAL_PATH" || exit 1
    exit 1
  fi
}

######################################
# Downloads checksumfile from url
# and validates a file with it
# Arguments:
#   $1 Filename
#   $2 Url
# Returns:
#   0 if checksum valid,
#   any value in 0 < x < 256 otherwise
######################################
valid_checksum() {
  must_download "downloads/sha256sums.txt" "$2"
  # sha256sums.txt contents (multiple lines with): $sha256hash $fileName
  # grep gets only the line with "$1", sed appends "downloads/" to "$1"
  # so sha256sum knows where the file is located and can validate $sha256hash
  [ -f "downloads/$1" ] \
    && sha256sum -c <(grep "$1" "downloads/sha256sums.txt" \
                        | sed "s/$1/downloads\/$1/g")
}

######################################
# Downloads checksum. Downloads file
# if it isn't already downloaded or
# it's checksum is invalid.
# Arguments:
#   $1 Filename
#   $2 Url
#   $3 Checksum filename
######################################
download_source() {
  if ! valid_checksum "$1" "$2/$3"; then
    must_download "downloads/$1" "$2/$1"
  fi
}

make_linux() {
  make -C "linux-$KERN_VERS/" x86_64_defconfig
  make -C "linux-$KERN_VERS/" kvm_guest.config
  make -C "linux-$KERN_VERS/" "-j$(nproc)"
}

make_busybox() {
  make -C "busybox-$BUSYBOX_VERS" defconfig
  sed -i "s/# CONFIG_STATIC is not set/CONFIG_STATIC=y/g" \
    "busybox-$BUSYBOX_VERS/.config"
  make -C "busybox-$BUSYBOX_VERS" "-j$(nproc)"
  make -C "busybox-$BUSYBOX_VERS" install
}

######################################
# If checkfile is already available
# assume source is built. Extract
# and build otherwise. Abort program
# if checkfile not present at the end.
# Arguments:
#   $1 Checkfile
#   $2 Sourcefile
######################################
build_source() {
  if [ ! -f "$2" ]; then
    local source
    source=$(echo "$1" | cut -d"-" -f1)
    info "Extracting $source..."
    tar xf "downloads/$1"
    info "Building $source..."
    make_"$source"
    if [ ! -f "$2" ]; then
      err "Failure building $source."
      err "Make sure all the needed packages are available."
      err "Aborting script."
      cd "$ORIGINAL_PATH" || exit 1
      exit 1
    fi
  fi
}

if [ "$MAJOR_VERS" -lt 3 ]; then
    err "This script only supports kernel v3.x.x and above."
    exit 1
fi

info "Downloading necessary utilities..."
sudo apt install -y curl build-essential flex bison \
  libelf-dev libssl-dev qemu-system-x86

info "Change directory to $SCRIPT_PATH"
cd "$SCRIPT_PATH" || exit 1
mkdir -p downloads

download_source "linux-$KERN_VERS.tar.xz" \
  "$KERN_BASE_URL/v$MAJOR_VERS.x" sha256sums.asc

build_source "linux-$KERN_VERS.tar.xz" \
  "linux-$KERN_VERS/arch/x86/boot/bzImage"

download_source "busybox-$BUSYBOX_VERS.tar.bz2" \
  "$BUSYBOX_BASE_URL" "busybox-$BUSYBOX_VERS.tar.bz2.sha256"

build_source "busybox-$BUSYBOX_VERS.tar.bz2" \
  "busybox-$BUSYBOX_VERS/_install/linuxrc"

info "Creating initramfs..."
mkdir -p initramfs
cd initramfs || exit 1
mkdir -p bin sbin etc proc sys usr/bin usr/sbin
cp "$SCRIPT_PATH/init" init
chmod +x init
cp -a "$SCRIPT_PATH/busybox-$BUSYBOX_VERS/_install/." .
find . -print0 | cpio --null -ov --format=newc > ../initramfs.cpio
cd "$SCRIPT_PATH" || exit 1
[ -f "initramfs.cpio.gz" ] && rm "initramfs.cpio.gz"
gzip initramfs.cpio

info "Running qemu..."
sudo qemu-system-x86_64 -enable-kvm -m 256M \
  -kernel "linux-$KERN_VERS/arch/x86/boot/bzImage" \
  -initrd initramfs.cpio.gz \
  -append "console=ttyS0" \
  -serial stdio \
  -display none \
  -cpu host

cd "$ORIGINAL_PATH" || exit 1
