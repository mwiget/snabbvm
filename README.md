### Overview

Create a Docker Container Image that contains Qemu and Snabb to launch a Virtual
Machine from the current directory or from a URL. Cloud-init support is available by
passing a user-data file.

### Requirements

- Bare metal linux server with [Docker](https://www.docker.com) installed. 
- One or more Intel 82599 based 10G Ethernet ports. 
- The kernel must have HugePages reserved by setting the following options in /etc/default/grub.
- IOMMU needs to be disabled if the host cpu is a SandyBridge 

```
# cat /etc/default/grub
...
GRUB_CMDLINE_LINUX_DEFAULT="hugepages=1000 intel_iommu=off"
...
# update-grub
# reboot
```

Qemu and snabb will get downloaded and compiled during the creation of the vmx docker image, hence there are no requirements on the server itself to have qemu or even developer tools installed.

### Download a VM Image 

```
$ docker pull marcelwiget/snabbvm
$ docker images
REPOSITORY          TAG                 IMAGE ID            CREATED             VIRTUAL SIZE
```

### Running the VM via the snabbvm Container

The following example launches the latest version of the container, downloads
Ubuntu wily (15.10) cloud image, bridges eth0 to docker0 (which provides 
Internet access for the VM) and connects eth1 to the 10GE port found at PCI address
0000:05:00.0.

User account settings and initial commands to configure eth1 can be passed via 
user_data.txt

```
$ cat user_data.txt
#cloud-config
user: ubuntu
password: ubuntu
chpasswd: {expire: False}

runcmd:
 - ifconfig eth1 1.1.1.1/24
```

```
docker run --name vm1 --rm --privileged -i -t -v $PWD:/u \
  marcelwiget/snabbvm -u user_data.txt \
  https://cloud-images.ubuntu.com/wily/current/wily-server-cloudimg-amd64-disk1.img
  0000:05:00.0
```

--name <name> 
The name must be unique across containers on the same server (e.g. vm1)

--rm          
Destroy the container after termination (use -d to run as daemon instead)

-d            
Optional instead of --rm: Launch the Container in detached mode, making it possible to launch fully unattended, while allowing the user to re-attach to the console via 'docker attach <name>'.

--v $PWD:/u:ro
Provides access to the VM image and cloud-init user_data file locally.
The destination directory must always be /u and the source directory can be adjusted as needed.

-i          
Keep STDIN open even if not attached. Required to keep tmux happy, even when
not attached.

-t          
Allocate a pseudo-TTY. Required for proper operation.

First parameter is the filename or URL for the virtual disk image or ISO disk
to download and run. This file is copied before execution, so any changes made 
will be lost once the containers is destroyed.

Subsequent parameters are expected to be a list of PCI Addresses of the 10GE 
Intel 82599 ports to attach to the VM, beginning with eth1. (eth0 is bridged
to docker0 for Internet access).

In addition to the TTY console within tmux in the Container, a VNC session is
automatically launched at Port 5901 of the running containers IP address. Remote
access can be achieved e.g. via ssh to the docker host and use port forwarding to the
containers IP address.


