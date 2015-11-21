#!/bin/bash

MEM=1000
CPU=1

set -e	#  Exit immediately if a command exits with a non-zero status.

#---------------------------------------------------------------------------
function show_help {
 echo ""
 echo "Usage: "
 echo ""
 echo "docker run --name <name> --rm [--volume \$PWD:/u:ro] \\"
 echo "   --privileged -i -t marcelwiget/snabbvm[:version] \\"
 echo "   -u <user_data_filename> \\"
 echo "   [-m <kbytes>] [-c <cpu count>] <url/image> <pci-address> [<pci-address> ...]"
 echo ""
 echo "[:version]       Container version. Defaults to :latest"
 echo ""
 echo " -v \$PWD:/u:ro   Required to access a file in the current directory"
 echo "                 docker is executed from (ro forces read-only access)"
 echo "                 The file will be copied from this location"
 echo ""
 echo "<pci-address>    PCI Address of the Intel 825999 based 10GE port"
 echo "                 Multiple ports can be specified, space separated"
 echo ""
 echo " -c  Specify the number of virtual CPU's (default is $CPU)"
 echo " -m  Specify the amount of memory (default is ${MEM} kBytes)"
 echo " -u  cloud-init user_data file (requires --volume)"
 echo ""
 echo "The running VM can be reached via VNC on port 5901 of the containers IP"
 echo ""
 echo "Example:"
 echo "docker run --name vm1 --rm --privileged -i -t -v \$PWD:/u \\"
 echo "  marcelwiget/snabbvm -u user_data.txt \\"
 echo "  https://cloud-images.ubuntu.com/wily/current/wily-server-cloudimg-amd64-disk1.img"
 echo "  0000:05:00.0"
 echo ""
 echo "See https://github.com/mwiget/snabbvm.git for latest source"
}

#---------------------------------------------------------------------------
function cleanup {

  echo ""
  echo ""
  echo "VM $IMAGE terminated."
  echo ""
  echo "cleaning up ..."


  if [ ! -z "$PCIDEVS" ]; then
    echo "Giving 10G ports back to linux kernel"
    for PCI in $PCIDEVS; do
      echo -n "$PCI" > /sys/bus/pci/drivers/ixgbe/bind 2>/dev/null
    done
  fi
  trap - EXIT SIGINT SIGTERM
  echo "done"
  exit 0
}


#---------------------------------------------------------------------------
function pci_node {
  case "$1" in
    *:*:*.*)
      cpu=$(cat /sys/class/pci_bus/${1%:*}/cpulistaffinity | cut -d "-" -f 1)
      numactl -H | grep "cpus: $cpu" | cut -d " " -f 2
      ;;
    *)
      echo $1
      ;;
  esac
}

USERDATA=""

while getopts "h?c:m:u:" opt; do
    case "$opt" in
    h|\?)
        show_help
        exit 0
        ;;
    c)  CPU=$OPTARG
        ;;
    m)  MEM=$OPTARG
        ;;
    u)  USERDATA=$OPTARG
        ;;
    esac
done

shift $((OPTIND-1))

X=$@
if [ "X$X" == "X" ]; then
  echo "Please specify the filneame or URL of the image/iso to boot"
  show_help
  exit 1
fi

# first parameter is the url or filename of the image/iso to boot
FILE=$1
shift

if [[ $FILE =~ http.*:// ]]; then
  wget --no-check-certificate $FILE 
  IMAGE=`basename $FILE`
  if [ ! -e $IMAGE ]; then
    echo "Failed to download $FILE"
    show_help
    exit 1
  fi
else
  # ok. We didn't get a URL, so this must be a file we can reach
  # via the mounted filesystem given via 'docker run --volume'
  IMAGE=$FILE
  if [ ! -e "/u/$IMAGE" ]; then
    echo "Can't access $IMAGE via mount point. Did you specify --volume \$PWD:/u:ro ?"
    show_help
    exit 1
  fi
  cp /u/$IMAGE .
fi

# unpack image if its compressed
if [[ "$IMAGE" =~ \.gz$ ]]; then
  gunzip $IMAGE
fi

qemu=/usr/local/bin/qemu-system-x86_64
snabb=/usr/local/bin/snabb

# mount hugetables, remove directory if this isn't possible due
# to lack of privilege level. A check for the diretory is done further down
mkdir /hugetlbfs && mount -t hugetlbfs none /hugetlbfs || rmdir /hugetlbfs

# check that we are called with enough privileges and env variables set
if [ ! -d "/hugetlbfs" ]; then
  echo "Can't access /hugetlbfs. Did you specify --privileged ?"
  show_help
  exit 1
fi

echo "Checking system for hugepages ..."
HUGEPAGES=`cat /proc/sys/vm/nr_hugepages`
if [ "0" -gt "$HUGEPAGES" ]; then
  echo "No HUGEPAGES found. Did you specify --privileged ?"
  show_help
  exit 1
fi

# ==========================================================================
# $@ contains hopefully the PCI addresses to launch snabbnfv on each of them

trap cleanup EXIT SIGINT SIGTERM
port_n=0	# added to each tap interface to make them unique
PCIDEVS=""

for DEV in $@; do # ======================== loop thru interfaces start

  if [ ! -L /sys/bus/pci/drivers/ixgbe/$DEV ]; then
    echo "Trying to rebind $DEV ..."
    echo -n "$DEV" > /sys/bus/pci/drivers/ixgbe/bind
  fi

  if [ -L /sys/bus/pci/drivers/ixgbe/$DEV ]; then
    echo "$DEV is a supported Intel 82599-based 10G port."
    # add $DEV to list
    PCIDEVS="$PCIDEVS $DEV"
    macaddr=`printf '00:49:BA:%02X:%02X:%02X\n' $[RANDOM%256] $[RANDOM%256] $[RANDOM%256]`
    NETDEVS="$NETDEVS -chardev socket,id=char$port_n,path=./xe$port_n.socket,server \
        -netdev type=vhost-user,id=net$port_n,chardev=char$port_n \
        -device virtio-net-pci,netdev=net$port_n,mac=$macaddr"

    cat > xe${port_n}.cfg <<EOF
return {
  {
    port_id = "xe${port_n}",
    mac_address = nil
  }
}
EOF
    node=$(pci_node $DEV)
    numactl="numactl --cpunodebind=$node --membind=$node"
    cat > launch_snabb_xe${port_n}.sh <<EOF
#!/bin/bash
SNABB=$snabb
CONFIG=xe${port_n}.cfg
MAC=$macaddr

while :
do
  $numactl \$SNABB snabbnfv traffic -k 10 -D 0 $DEV \$CONFIG %s.socket
  echo "waiting 5 seconds before relaunch ..."
  sleep 5
done
EOF
    chmod a+rx launch_snabb_xe${port_n}.sh
    port_n=$(($port_n + 1))
  else
    echo "Error: $DEV isn't an Intel 82599-based 10G port!"
    exit 1
  fi

done # ===================================== loop thru interfaces 

# create bridge br0 and place eth0 together with a tap interface em0
# to give to the VM we are going to launch. The VM typically has Internet
# access over the first interface and can be reached at the dynamically
# assigned IP address.
# 
MYIP=`ifconfig | sed -En 's/127.0.0.1//;s/.*inet (addr:)?(([0-9]*\.){3}[0-9]*).*/\2/p'`
GATEWAY=`ip -4 route list 0/0 |cut -d' ' -f3`
ip addr flush dev eth0
brctl addbr br0
ip link set br0 up
ip addr add $MYIP/16 dev br0
route add default gw $GATEWAY
brctl addif br0 eth0
ip tuntap add dev em0 mode tap
ip link set em0 up promisc on
brctl addif br0 em0

NAME="${NAME:-snabbvm}"
tmux_session="$NAME"


if [[ $IMAGE =~ \.iso ]]; then
  CD="-cdrom $IMAGE"
  echo "creating an empty disk image ..."
  qemu-img create -f qcow2 disk.qcow2 2G
  HD="-drive if=virtio,file=disk.qcow2,cache=none"
else
  CD=""
  HD="-drive if=virtio,file=$IMAGE,cache=none"
fi

# prepare cloud-init config drive
mkdir config_drive
mkdir -p config_drive/openstack/2012-08-10
ln -s 2012-08-10 config_drive/openstack/latest
cat > config_drive/openstack/latest/meta_data.json << EOF
{
      "uuid": "$IMAGE"
}
EOF

echo "cloud-init userdata file: $USERDATA"

if [ -f "/u/$USERDATA" ]; then
  echo "creating user_data ..."
  cat /u/$USERDATA > config_drive/openstack/latest/user_data
fi
mkisofs -R -V config-2 -o disk.config config_drive
cat config_drive/openstack/latest/user_data

# we borrow the last $numactl in case of 10G ports. If there wasn't one
# then this will be simply empty
RUNVM="$numactl $qemu -M pc -smp $CPU --enable-kvm -cpu host -m $MEM \
  -numa node,memdev=mem \
  -object memory-backend-file,id=mem,size=${MEM}M,mem-path=/hugetlbfs,share=on \
  -netdev tap,id=tf0,ifname=em0,script=no,downscript=no \
  -device virtio-net-pci,netdev=tf0 $CD $HD -drive file=disk.config,if=virtio \
  $NETDEVS -curses -vnc :1"

echo "$RUNVM" > runvm.sh
chmod a+rx runvm.sh

tmux new-session -d -n "VM" -s $tmux_session ./runvm.sh

# launch snabb drivers, if any
for file in launch_snabb_xe*.sh
do
  tmux new-window -a -d -n "${file:13:3}" -t $tmux_session ./$file
done

# DON'T detach from tmux when running the container! Use docker's ^P^Q to detach
tmux attach

# ==========================================================================
# User terminated tmux, lets kill all VM's too

echo "killing VM and snabb drivers ..."
pkill qemu-system-x86_64 || true
pkill snabb || true

echo "waiting for qemu to terminate ..."
while  true;
do
  if [ "1" == "`ps ax|grep qemu|wc -l`" ]; then
    break
  fi
  sleep 1
  pkill -9 qemu
done

exit  # this will call cleanup, thanks to trap set earlier (hopefully)
