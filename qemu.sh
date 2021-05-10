#!/bin/sh

set -e

# If not set, then run as root
#   $ useradd -m -r -s /bin/bash -G kvm $QEMU_USER || true
# FIXME: Doesn't work for now due to RLIMIT_MEMLOCK issue
#QEMU_USER="qemuuser"
#

# default parameters that can be configured
CONFIG_HUGEPAGES=1
CONFIG_HUGEPAGES_2MB=1
CONFIG_NVIDIA_MODULE_UNLOAD=1
CONFIG_RYZEN_WORKAROUND=1
CONFIG_VIRTUAL_DISPLAY=1

# Enable for effortless Windows installation. Disable
# after installing virtio-win drivers (and rebooting at least once!)
CONFIG_NO_PARAVIRT=0

CONFIG_RAM=24576
ROOT_DIR=$(dirname $0)/workdir
STORAGE_IMAGE_PATH=${ROOT_DIR}/vm_root.qcow2
DUMMY_STORAGE_PATH=${ROOT_DIR}/dummy.qcow2
#CDROM_IMAGE_PATH=/home/user/installer.iso

OVMF_BINARY_PATH=${ROOT_DIR}/ovmf_code.fd
OVMF_VARS_PATH=${ROOT_DIR}/ovmf_vars.fd
GPU_ROM_PATH=${ROOT_DIR}/video_bios.rom
SMBIOS_BIN_PATH=${ROOT_DIR}/smbios_host.bin
TPM_DIR=/tmp/qemu_sw_tpm/
#TBD: use host-like ACPI table

log_msg() {
    echo "|$(date "+%x-%H:%M:%S")|" $@ || true
}

add_pci_dev_pt() {
    # TODO: $1 argument to use for debug prints
    PCI_DEVICES="$PCI_DEVICES $2"
}

add_usb_dev_pt() {
    USB_DEVICES="$USB_DEVICES $2"
}

is_cfg_set() {
    if [ ! -z "$1" ] && [ "$1" != "0" ]; then
        return 0
    fi
    return 1
}

fill_configuration()
{
    add_pci_dev_pt AMD_GPU_PCI_ID 0b:00.0,multifunction=on,x-vga=on
    add_pci_dev_pt AMD_GPU_PCI_ID 0b:00.1
    if ! is_cfg_set $CONFIG_VIRTUAL_DISPLAY ; then

	GPU_PCI_BUS="0b:00.0"
        if [ ! -e ${GPU_ROM_PATH} ]; then
            log_msg "Didn't find GPU ROM image which is needed for NVIDIA cards. Will try to dump it from the current GPU"
            echo 1 > /sys/bus/pci/devices/0000:${GPU_PCI_BUS}/rom
            cat /sys/bus/pci/devices/0000:${GPU_PCI_BUS}/rom > ${GPU_ROM_PATH}
            echo 0 > /sys/bus/pci/devices/0000:${GPU_PCI_BUS}/rom
        fi
        add_pci_dev_pt GPU_PCI_ID ${GPU_PCI_BUS},romfile=${GPU_ROM_PATH},multifunction=on,x-vga=on
        add_pci_dev_pt GPU_AUDIO_PCI_ID 0a:00.1
        add_usb_dev_pt USB_MOUSE 413c:2514
    fi
}

# End of configuration
#################################

fill_default_values()
{
    if is_cfg_set $CONFIG_HUGEPAGES_2MB ; then
        PAGE_PATH="/dev/hugepages"
        PAGE_CONFIG_PATH="/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
        HUGEPAGES_NUM=$((CONFIG_RAM / 2 + 1))
    else
        PAGE_PATH="/dev/hugepages1G"
        PAGE_CONFIG_PATH="/sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages"
        HUGEPAGES_NUM=$((CONFIG_RAM / 1024 + 1))
    fi
}

check_file()
{
    FILE=$1
    TIME=$2
    while [ ! -z "${TIME}" ] && [  ${TIME} != "0" ] && [ ! -e $FILE ]; do
        log_msg "Waiting for $FILE"
        sleep 1
        TIME=$((TIME-1))
    done

    [ -e $FILE ];
}

VFIO_PCI_SYSFS_PATH="/sys/bus/pci/drivers/vfio-pci/"
PCI_DEV_SYSFS_PATH_PREFIX="/sys/bus/pci/devices/0000:"

pci_parse_dev_bus() {
    dev_id=$(echo $1 | cut -f1 -d",")
    [ -z $dev_id ] && log_msg "Wrong device '$1' format" && return 1
    DEV_DIR="${PCI_DEV_SYSFS_PATH_PREFIX}$dev_id/"
}

pci_vfio_bind_devices()
{
    for dev in $PCI_DEVICES ; do
        pci_parse_dev_bus $dev || continue

        log_msg "VFIO bind $dev_id device"

        if [ -e $VFIO_PCI_SYSFS_PATH/0000:$dev_id ]; then
            log_msg "Device $dev_id already bound to vfio. Skip it"
            continue
        fi
        echo vfio-pci > $DEV_DIR/driver_override
    done
    pci_bind_devices
}

pci_vfio_unbind_devices()
{
    for dev in $PCI_DEVICES ; do
        pci_parse_dev_bus $dev || continue
        log_msg "VFIO unbind $dev_id device"
        echo > $DEV_DIR/driver_override
    done
    pci_unbind_devices
}

pci_unbind_devices()
{
    for dev in $PCI_DEVICES ; do
        pci_parse_dev_bus $dev || continue

        log_msg "PCI unbind $dev_id device"

        if [ -e $DEV_DIR/driver ]; then
            echo 0000:$dev_id > $DEV_DIR/driver/unbind
        fi
    done
}

pci_bind_devices()
{
    for dev in $PCI_DEVICES ; do
        pci_parse_dev_bus $dev || continue

        log_msg "PCI bind $dev_id device"

        if [ ! -e $DEV_DIR/driver ]; then
            echo 0000:$dev_id > /sys/bus/pci/drivers_probe
        fi
    done
}

ignore_msrs()
{
    IGNORE_MSRS_PATH="/sys/module/kvm/parameters/ignore_msrs"
    if check_file $IGNORE_MSRS_PATH ; then
        echo $1 > $IGNORE_MSRS_PATH
    else
        log_msg "Couldn't find $IGNORE_MSRS_PATH"
    fi
}

VTCON_BIND="/sys/class/vtconsole/vtcon1/bind"
EFI_FBUF="/sys/bus/platform/drivers/efi-framebuffer/"

nvidia_unload()
{
    if check_file $VTCON_BIND ; then
        echo 0 > $VTCON_BIND
    fi

    if check_file ${EFI_FBUF}/unbind && [ -e $EFI_FBUF ] ; then
        echo efi-framebuffer.0 > ${EFI_FBUF}/unbind || true
    fi

    if is_cfg_set $CONFIG_NVIDIA_MODULE_UNLOAD ; then
        rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia
    fi
}

nvidia_load()
{
    echo efi-framebuffer.0 > /sys/bus/platform/drivers_probe

    if check_file ${EFI_FBUF}/bind 3 && [ ! -e $EFI_FBUF ] ; then
        echo efi-framebuffer.0 > ${EFI_FBUF}/bind
    else
        log_msg "Timeout waiting for efi-framebuffer"
    fi

    if check_file $VTCON_BIND ; then
        echo 1 > $VTCON_BIND
    else
        log_msg "Couldn't find $VTCON_BIND"
    fi

    if is_cfg_set $CONFIG_NVIDIA_MODULE_UNLOAD ; then
        modprobe -a nvidia nvidia_modeset nvidia_drm
    fi
}

format_qemu_args()
{
    QEMU_FORMAT_ARGS=""
    for dev in $PCI_DEVICES ; do
        QEMU_FORMAT_ARGS="$QEMU_FORMAT_ARGS -device vfio-pci,host=$dev"
    done

    for dev in $USB_DEVICES ; do
        vendor_id=$(echo $dev | cut -d':' -f1)
        product_id=$(echo $dev | cut -d':' -f2)
        QEMU_FORMAT_ARGS="$QEMU_FORMAT_ARGS -device usb-host,bus=xhci.0,vendorid=0x$vendor_id,productid=0x$product_id"
    done

    if [ ! -z "$QEMU_USER" ] ; then
        QEMU_FORMAT_ARGS="$QEMU_FORMAT_ARGS -runas $QEMU_USER"
    fi
}

QEMU_PID_FILE="/tmp/qemu.pid"

run_qemu()
{
    CPU_CORES_NUM=$(nproc)
    CPU_ARGS="-cpu host,kvm=off,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_vendor_id=asus,smep=off,-hypervisor -overcommit mem-lock=off"
    CPU_MULTICORE_ARGS="-smp $CPU_CORES_NUM,sockets=1,cores=$CPU_CORES_NUM"

    MEM_ARGS="-m $CONFIG_RAM"

    if is_cfg_set $CONFIG_HUGEPAGES ; then
        MEM_ARGS="$MEM_ARGS -mem-path $PAGE_PATH"
    fi

    if is_cfg_set $CONFIG_NO_PARAVIRT ; then
        NET_ARGS="-device e1000,netdev=main_net"
    else
        NET_ARGS="-device virtio-net-pci,netdev=main_net"
    fi
    NET_ARGS="$NET_ARGS -netdev user,id=main_net"
    RTC_ARGS="-rtc base=localtime"

    STORAGE_ARGS="-device ahci,id=ahci"
    USB3_ARGS="-device nec-usb-xhci,id=xhci,addr=06"

    if [ -e $STORAGE_IMAGE_PATH ]; then
        if is_cfg_set $CONFIG_NO_PARAVIRT ; then
            STORAGE_ARGS="$STORAGE_ARGS -drive id=disk,file=$STORAGE_IMAGE_PATH"
        else
            STORAGE_ARGS="$STORAGE_ARGS -object iothread,id=io1 -drive id=block,file=$STORAGE_IMAGE_PATH,if=none,aio=threads -device virtio-blk-pci,iothread=io1,drive=block"
        fi

	# a dummy virtio-blk disk is only added here as a dirty workaround for
	# windows systems that refuse to boot after switching from software
	# emulated HDD to virtio-blk even with virtio-win drivers installed.
	log_msg "Adding dummy virtio-blk HDD"
	STORAGE_ARGS="$STORAGE_ARGS -object iothread,id=io2 -drive id=dummy_block,file=$DUMMY_STORAGE_PATH,if=none,aio=threads -device virtio-blk-pci,iothread=io2,drive=dummy_block"
    fi

    if [ -e $CDROM_IMAGE_PATH ]; then
        STORAGE_ARGS="$STORAGE_ARGS -drive file=$CDROM_IMAGE_PATH,media=cdrom,id=cdrom,if=none -device ide-cd,drive=cdrom,bus=ahci.0,model=Samsung_SE-S084_DVD-ROM"
    fi

    QEMU_DEBUG_ARGS="-s"

    if ! is_cfg_set $CONFIG_VIRTUAL_DISPLAY ; then
        QEMU_VIDEO_ARGS="-vga none -nographic"
    else
        QEMU_VIDEO_ARGS="-device usb-tablet,bus=xhci.0"
        if is_cfg_set $CONFIG_NO_PARAVIRT ; then
            QEMU_VIDEO_ARGS="$QEMU_VIDEO_ARGS -device VGA"
        else
            QEMU_VIDEO_ARGS="$QEMU_VIDEO_ARGS -device virtio-gpu"
        fi
    fi

    QEMU_TPM_ARGS="-chardev socket,id=chrtpm,path=${TPM_DIR}/swtpm-sock \
        -tpmdev emulator,id=tpm0,chardev=chrtpm \
        -device tpm-tis,tpmdev=tpm0"

# pulseaudio needs to be configured to allow root connections
# export QEMU_AUDIO_DRV=pa
# QEMU_AUDIO_ARGS="-soundhw hda"

    format_qemu_args

    if [ ! -e ${SMBIOS_BIN_PATH} ]; then
        log_msg "No smbios image: trying to obtain one from host via dmidecode."
        dmidecode -q --dump-bin ${SMBIOS_BIN_PATH}
    fi

    if [ ! -e ${OVMF_BINARY_PATH} -o ! -e ${OVMF_VARS_PATH} ]; then
        log_msg "No ovmf fw files. Will copy those provided by the host distro"
        cp /usr/share/OVMF/OVMF_CODE.secboot.fd ${OVMF_BINARY_PATH}
        cp /usr/share/OVMF/OVMF_VARS.secboot.fd ${OVMF_VARS_PATH}
    fi
    set +e

    mkdir -p ${TPM_DIR}
    swtpm socket --tpmstate dir=${TPM_DIR} \
        --ctrl type=unixio,path=${TPM_DIR}/swtpm-sock \
        --tpm2 --log level=0 &

    qemu-system-x86_64 \
        -pidfile $QEMU_PID_FILE \
        -drive if=pflash,format=raw,readonly=on,file=$OVMF_BINARY_PATH \
        -drive if=pflash,format=raw,file=$OVMF_VARS_PATH \
        $USB3_ARGS \
        $STORAGE_ARGS \
        $NET_ARGS \
        $QEMU_VIDEO_ARGS \
        $RTC_ARGS \
        -enable-kvm $CPU_ARGS $CPU_MULTICORE_ARGS -M q35 \
        $MEM_ARGS \
        -smbios file=$SMBIOS_BIN_PATH \
        -monitor telnet::45454,server,nowait \
        -serial none \
        $QEMU_DEBUG_ARGS \
        $QEMU_AUDIO_ARGS \
        $PARAVIRT_ARGS \
        $QEMU_TPM_ARGS \
        $QEMU_FORMAT_ARGS
    res=$?

    killall -SIGTERM swtpm
    set -e
    if [ $res -ne 0 ] ; then
        log_msg "QEMU returned non-zero code"
    fi
}

stop_cmd()
{
    set +e

    if [ ! -e $QEMU_PID_FILE ]; then
        log_msg "Qemu process stopped"
    else
        pkill --pidfile $QEMU_PID_FILE

        while pgrep --pidfile $QEMU_PID_FILE ; do
            sleep 1
        done
    fi

    if is_cfg_set $CONFIG_RYZEN_WORKAROUND ; then
        ignore_msrs 0
    fi

    if is_cfg_set $CONFIG_HUGEPAGES ; then
        echo 0 > $PAGE_CONFIG_PATH
    fi

    pci_vfio_unbind_devices

    if ! is_cfg_set $CONFIG_VIRTUAL_DISPLAY ; then
        rmmod vfio-pci vfio_iommu_type1 vfio
        nvidia_load
    fi

    pci_bind_devices

    if ! is_cfg_set $CONFIG_VIRTUAL_DISPLAY ; then
        systemctl start display-manager
    fi

    set -e
}

start_cmd()
{
    if ! is_cfg_set $CONFIG_VIRTUAL_DISPLAY ; then
        systemctl stop display-manager

        if systemctl is-active nvidia-persistenced ; then
            log_msg "nvidia-persistenced prevent the device from being unbound, thus, disable it"
            systemctl mask nvidia-persistenced
            systemctl stop nvidia-persistenced
	fi

	log_msg "Just wait for 1 second after stopping the GUI"
        sleep 1
        nvidia_unload
    fi

    pci_unbind_devices

    modprobe -a vfio vfio-pci

    pci_vfio_bind_devices

    if is_cfg_set $CONFIG_RYZEN_WORKAROUND ; then
        ignore_msrs 1
    fi

    if is_cfg_set $CONFIG_HUGEPAGES ; then
        echo $HUGEPAGES_NUM > $PAGE_CONFIG_PATH
        HUGEPAGES_NUM_OBTAINED=$(cat $PAGE_CONFIG_PATH)
        if [ $HUGEPAGES_NUM_OBTAINED -lt $HUGEPAGES_NUM ]; then
            log_msg "Not enough available hugepages. $HUGEPAGES_NUM_OBTAINED < $HUGEPAGES_NUM. Try reducing/disabling hugepages?"
            return 0
        fi
    fi

    run_qemu
}

print_usage()
{
cat << EOF
Usage: $0 --<format|start|stop|help> [OPTION]...

The script depends on qemu-system-x86_64 vbetool kmod procps coreutils dmidecode from Debian 9 repository.

Optional arguments:
    -m - RAM in megabytes (default is $CONFIG_RAM)
    --no-ryzen-msrs-wa - Disable workaround for AMD Ryzen processors, which fixes crash when running Windows 10 installer
    --hugepages <none|2MB|1GB> - Control hugepages allocation. Default is 2MB
        Example /etc/fstab config:
            hugetlbfs /dev/hugepages hugetlbfs mode=1770,gid=kvm,pagesize=2MB 0 0
    --no-nvidia-driver-unload - Do not unload NVIDIA GPU driver when starting/stopping QEMU.
    --virtual-display - Run QXL virtual display instead of GPU passthrough
    --no-paravirt - Don't use paravirtualization devices. Aka "stealth" mode for VM-wary software
EOF
}

parse_args()
{
    TEMP=$(getopt -l "format,start,stop,help,no-ryzen-msrs-wa,hugepages:,no-nvidia-driver-unload,no-paravirt,virtual-display" -o "hm:" -a -- "$@")
    if [ $? -ne 0 ]; then
        print_usage
        exit 1
    fi

    eval set -- "$TEMP"

    while true ; do
        case $1 in
            --format)
		FORMAT_CMD=1
		;;
            --start)
                START_CMD=1
                STOP_CMD=1
                ;;

            --stop)
                STOP_CMD=1
                ;;
            -m)
                shift
                CONFIG_RAM=$1
                ;;
            --no-ryzen-msrs-wa)
                CONFIG_RYZEN_WORKAROUND=0
                ;;
            --hugepages)
                shift
                case $1 in
                    none)
                        CONFIG_HUGEPAGES=0
                        ;;
                    2MB)
                        CONFIG_HUGEPAGES_2MB=1
                        ;;
                    1GB)
                        CONFIG_HUGEPAGES_2MB=0
                        ;;
                    *)
                        print_usage
                        exit 1
                        ;;
                esac
                ;;
            --no-nvidia-driver-unload)
                CONFIG_NVIDIA_MODULE_UNLOAD=0
                ;;
            --virtual-display)
                CONFIG_VIRTUAL_DISPLAY=1
                ;;
            --no-paravirt)
                CONFIG_NO_PARAVIRT=1
                ;;
            --)
                shift
                break
                ;;
            *)
                print_usage
                exit 1
                ;;
        esac
        shift
    done

    if ! is_cfg_set $START_CMD && ! is_cfg_set $STOP_CMD && ! is_cfg_set $FORMAT_CMD ; then
        print_usage
        exit 1
    fi
}

if [ $(id -u) != 0 ] ; then
    echo "Must be run as root" 2> /dev/null
    exit 1
fi

mkdir -p ${ROOT_DIR}

parse_args $@

fill_configuration
fill_default_values

if is_cfg_set $START_CMD ; then
    start_cmd
fi
if is_cfg_set $STOP_CMD ; then
    stop_cmd
fi
if is_cfg_set $FORMAT_CMD ; then
    log_msg "The operation will erase virtio-blk storage. Are you sure? (ctrl-c if not)"
    read -r
    qemu-img create -f qcow2 -o cluster_size=2M ${DUMMY_STORAGE_PATH} 2M
    qemu-img create -f qcow2 -o cluster_size=2M ${STORAGE_IMAGE_PATH} 120G
fi
