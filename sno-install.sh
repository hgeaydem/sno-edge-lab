#!/bin/bash
set -x

PULL_SECRET=''

INSTALLATION_DISK="/dev/vda"
RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:4.8.0-fc.0-x86_64"
RHEL8_KVM=https://cloud.centos.org/centos/8/x86_64/images/CentOS-8-GenericCloud-8.2.2004-20200611.2.x86_64.qcow2
BASE_OS_IMAGE="https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/4.7/4.7.0/rhcos-4.7.0-x86_64-live.x86_64.iso"
BASTION_MEMORY=8192
OC_CLIENT=https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest-4.7/openshift-client-linux.tar.gz


########################
SNO_DIR="$(pwd)"
INSTALLER_WORKDIR="sno-workdir-$VM_NAME"
INSTALLER_BIN="bin/openshift-install"
LIVE_ISO_IGNITION_NAME="bootstrap-in-place-for-live-iso.ign"
BIP_LIVE_ISO_IGNITION="${INSTALLER_WORKDIR}/${LIVE_ISO_IGNITION_NAME}"


LIBVIRT_ISO_PATH="/var/lib/libvirt/images"
INSTALLER_ISO_PATH="${SNO_DIR}/installer-image.iso"
INSTALLER_ISO_PATH_SNO_IN_LIBVIRT="${LIBVIRT_ISO_PATH}/installer-SNO-image.iso"

INSTALL_CONFIG="${SNO_DIR}/install-config.yaml"
INSTALL_CONFIG_IN_WORKDIR="${INSTALLER_WORKDIR}/install-config.yaml"

NET_NAME="ocp4-net"
VM_NAME="rhacm"
VOL_NAME="$VM_NAME.qcow2"

SSH_KEY=$(cat ~/.ssh/id_rsa.pub)

SNO_HOST_IP="192.168.126.10"
SSH_HOST="core@${SNO_HOST_IP}"

prepare_host() {
  if [ ! -f $SSH_PUB_FILE ]; then
    ssh-keygen -b 2048 -t rsa -f ~/.ssh/id_rsa -q -N ""
    SSH_PUB_FILE=~/.ssh/id_rsa.pub
    SSH_KEY=$(cat ~/.ssh/id_rsa.pub)
  fi
  mkdir -p bin
  sudo dnf -y update
  sudo dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
  sudo dnf -y install wget libvirt qemu-kvm virt-manager virt-install libguestfs libguestfs-tools libguestfs-xfs net-tools sshpass virt-what nmap
  sudo dnf -y install podman jq
  wget $OC_CLIENT
  tar -zxvf openshift-client*
  cp oc kubectl /usr/bin/
  jq -n $PULL_SECRET > registry-config.json
  oc adm release extract --registry-config=registry-config.json --command=openshift-install --to ./bin ${RELEASE_IMAGE}
}

download_live_iso() {
  DOWNLOAD_PATH="${INSTALLER_WORKDIR}/base.iso"
  curl ${BASE_OS_IMAGE} --retry 5 -o $DOWNLOAD_PATH
}

embed_ign() {
  DOWNLOAD_PATH="${INSTALLER_WORKDIR}/base.iso"
  EMBEDDED_ISO="${INSTALLER_WORKDIR}/embedded.iso"
  BIP_LIVE_ISO_IGNITION="${INSTALLER_WORKDIR}/${LIVE_ISO_IGNITION_NAME}"
  podman run \
    --pull=always \
    --privileged \
    --rm \
    -v /dev:/dev \
    -v /run/udev:/run/udev \
    -v $(realpath $(dirname $DOWNLOAD_PATH)):/data:Z \
    -v $(realpath $(dirname $BIP_LIVE_ISO_IGNITION)):/ignition_data:Z \
    -v $(realpath $(dirname $EMBEDDED_ISO)):/output_data:Z \
    --workdir /data \
    quay.io/coreos/coreos-installer:release \
    iso ignition embed /data/$(basename $DOWNLOAD_PATH) \
    --force \
    --ignition-file /ignition_data/$(basename $BIP_LIVE_ISO_IGNITION) \
    --output /output_data/$(basename $EMBEDDED_ISO)
  cp -f $EMBEDDED_ISO $INSTALLER_ISO_PATH_SNO_IN_LIBVIRT
}

generate_ign() {
  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${RELEASE_IMAGE}" \
  ${INSTALLER_BIN} create single-node-ignition-config --dir=${INSTALLER_WORKDIR}
}

generate_manifests() {
  echo Generating manifests...

  OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${RELEASE_IMAGE}" \
  ${INSTALLER_BIN} create manifests --dir=${INSTALLER_WORKDIR}
}

define_network() {
  sudo virsh net-create files/ocp4-net.xml
}

customize_install_config() {
  cp files/install-config.yaml ${INSTALLER_WORKDIR}
  sed -i "s/CLUSTER_NAME/$VM_NAME/g" ${INSTALLER_WORKDIR}/install-config.yaml
  sed -i "s|INSTALLATION_DISK|$INSTALLATION_DISK|g" ${INSTALLER_WORKDIR}/install-config.yaml
  sed -i "s/PULL_SECRET/$PULL_SECRET/g" ${INSTALLER_WORKDIR}/install-config.yaml
  sed -i "s|SSH_KEY|$SSH_KEY|g" ${INSTALLER_WORKDIR}/install-config.yaml
}

install_vm_ign() {
  OS_VARIANT="rhel8.1"
  RAM_MB="${RAM_MB:-16384}"
  DISK_GB="${DISK_GB:-30}"
  CPU_CORE="${CPU_CORE:-6}"
  MAC_ADDR="${MAC_ADDR:-ba:dc:0f:fe:ee:00}"

  rm nohup.out
  nohup virt-install \
      --connect qemu:///system \
      -n "${VM_NAME}" \
      -r "${RAM_MB}" \
      --vcpus "${CPU_CORE}" \
      --os-variant="${OS_VARIANT}" \
      --import \
      --network=network:${NET_NAME},mac=${MAC_ADDR} \
      --graphics=none \
      --events on_reboot=restart \
      --cdrom "${INSTALLER_ISO_PATH_SNO_IN_LIBVIRT}" \
      --disk pool=default,size="${DISK_GB}" \
      --boot hd,cdrom \
      --noautoconsole \
      --wait=-1 &
}

prepare_bastion() {
  echo -e "\n\n[INFO] Downloading and customising the RHEL8 KVM guest image to become bastion host...\n"

  if [ ! -f /var/lib/libvirt/images/rhel8-kvm.qcow2 ]; then
    sudo wget -O /var/lib/libvirt/images/rhel8-kvm.qcow2 $RHEL8_KVM
  fi

  sudo qemu-img create -f qcow2 /var/lib/libvirt/images/ocp4-bastion.qcow2 -b /var/lib/libvirt/images/rhel8-kvm.qcow2 -F qcow2 200G
  sudo -E virt-customize -a /var/lib/libvirt/images/ocp4-bastion.qcow2 --uninstall cloud-init
  sudo -E virt-customize -a /var/lib/libvirt/images/ocp4-bastion.qcow2 --root-password password:redhat
  sudo -E virt-copy-in -a /var/lib/libvirt/images/ocp4-bastion.qcow2 files/ifcfg-eth0 /etc/sysconfig/network-scripts
  sudo -E virt-customize -a /var/lib/libvirt/images/ocp4-bastion.qcow2 --run-command "mkdir -p /root/.ssh/ && chmod -R 0700 /root/.ssh/"
  sudo -E virt-customize -a /var/lib/libvirt/images/ocp4-bastion.qcow2 --run-command "restorecon -Rv /root/.ssh/"

  mkdir -p node-configs
  sudo virt-install --virt-type kvm --ram $BASTION_MEMORY --vcpus 4 --os-variant rhel8.1 --disk path=/var/lib/libvirt/images/ocp4-bastion.qcow2,device=disk,bus=virtio,format=qcow2 $CPU_FLAGS --noautoconsole --vnc --network network:ocp4-net,mac=52:54:00:22:33:44 --boot hd --name ocp4-bastion --print-xml 1 > node-configs/ocp4-bastion.xml

  echo -e "\n[INFO] Starting the bastion host and copying in our ssh keypair...\n"
  sudo virsh define node-configs/ocp4-bastion.xml
  sudo virsh start ocp4-bastion
  #sleep 60
  echo -ne "\n[INFO] Waiting for the ssh daemon on the bastion host to appear"
  while [ ! "`nmap -sV -p 22 192.168.123.100|grep open`" ]; do
    echo -n "."
    sleep 1s
  done
  echo

  sed -i /192.168.123.100/d ~/.ssh/known_hosts
  sshpass -p redhat ssh-copy-id -o StrictHostKeyChecking=no -i $SSH_PUB root@192.168.123.100

  cat <<EOF > bastion-deploy.sh
  hostnamectl set-hostname ocp4-bastion.cnv.example.com
  dnf install qemu-img jq git httpd squid dhcp-server xinetd net-tools nano bind bind-utils haproxy wget syslinux libvirt-libs -y
  dnf install tftp-server syslinux-tftpboot -y
  dnf update -y
  ssh-keygen -t rsa -b 4096 -N '' -f ~/.ssh/id_rsa
  dnf install firewalld -y
  systemctl enable --now firewalld
  firewall-cmd --add-service=dhcp --permanent
  firewall-cmd --add-service=dns --permanent
  firewall-cmd --add-service=http --permanent
  firewall-cmd --add-service=https --permanent
  firewall-cmd --add-service=squid --permanent
  firewall-cmd --add-service={nfs3,mountd,rpc-bind} --permanent
  firewall-cmd --add-service=nfs --permanent
  firewall-cmd --permanent --add-port 6443/tcp
  firewall-cmd --permanent --add-port 8443/tcp
  firewall-cmd --permanent --add-port 22623/tcp
  firewall-cmd --permanent --add-port 81/tcp
  firewall-cmd --reload
  setsebool -P haproxy_connect_any=1
  mkdir -p /nfs/pv1
  mkdir -p /nfs/pv2
  mkdir -p /nfs/fc31
  chmod -R 777 /nfs
  echo -e "/nfs *(rw,no_root_squash)" > /etc/exports
  # we may have to do something about setting /etc/nfs.conf to v4 only
  systemctl enable httpd
  systemctl enable named
  systemctl enable squid
  systemctl enable dhcpd
  systemctl enable rpcbind
  systemctl enable nfs-server
  sed -i 's/Listen 80/Listen 81/g' /etc/httpd/conf/httpd.conf
  wget $OCP_INSTALL
  wget $OC_CLIENT
  tar -zxvf openshift-client*
  tar -zxvf openshift-install*
  cp oc kubectl /usr/bin/
  rm -f oc kubectl
  chmod a+x /usr/bin/oc
  chmod a+x /usr/bin/kubectl
  mkdir -p /root/ocp-install/
  growpart /dev/vda 1
  xfs_growfs /
  dnf install -y libvirt qemu-kvm mkisofs python3-devel jq ipmitool
  systemctl enable --now libvirtd
  virsh pool-define-as --name default --type dir --target /var/lib/libvirt/images
  virsh pool-start default
  virsh pool-autostart default
  nmcli connection add ifname provisioning type bridge con-name provisioning
  nmcli con add type bridge-slave ifname eth1 master provisioning
  nmcli connection modify provisioning ipv4.addresses 172.22.0.1/24 ipv4.method manual
  nmcli connection modify provisioning ipv4.gateway 172.22.0.254
  nmcli con down provisioning
  nmcli con up provisioning
  nmcli connection add ifname baremetal type bridge con-name baremetal
  nmcli con add type bridge-slave ifname eth0 master baremetal
  nmcli con down "System eth0"
  nmcli connection modify baremetal ipv4.addresses 192.168.123.100/24 ipv4.method manual
  nmcli connection modify baremetal ipv4.gateway 192.168.123.1
  nmcli con down baremetal
  nmcli con up baremetal
  rm -f /etc/sysconfig/network-scripts/ifcfg-eth0
EOF

  echo -e "\n\n[INFO] Running the bastion deployment script remotely...\n"

  scp -o StrictHostKeyChecking=no bastion-deploy.sh root@192.168.123.100:/root/
  ssh -o StrictHostKeyChecking=no root@192.168.123.100 sh /root/bastion-deploy.sh
  ssh -o StrictHostKeyChecking=no root@192.168.123.100 rm -f /root/bastion-deploy.sh

  echo -e "\n\n[INFO] Configuring the supporting services (squid, haproxy, DNS, DHCP, TFTP, httpd)...\n"

	scp -o StrictHostKeyChecking=no files/dhcpd.conf root@192.168.123.100:/etc/dhcp/dhcpd.conf
	scp -o StrictHostKeyChecking=no files/*.db root@192.168.123.100:/var/named/
  scp -o StrictHostKeyChecking=no files/squid.conf root@192.168.123.100:/etc/squid/squid.conf
  scp -o StrictHostKeyChecking=no files/named.conf root@192.168.123.100:/etc/named.conf

  ssh -o StrictHostKeyChecking=no root@192.168.123.100 'echo -e "search example.com\nnameserver 192.168.123.100" > /etc/resolv.conf && chattr +i /etc/resolv.conf'
  echo -e "\n\n[INFO] Rebooting bastion host...\n"

  ssh -o StrictHostKeyChecking=no root@192.168.123.100 reboot

  echo -ne "\n[INFO] Waiting for the ssh daemon on the bastion host to appear"
  while [ ! "`nmap -sV -p 22 192.168.123.100|grep open`" ]; do
    echo -n "."
    sleep 1s
  done
  echo
}

prepare_host
define_network
prepare_bastion
for i in rhacm edge1 edge2 edge3 edge4
do
  VM_NAME=$i
  VOL_NAME="$VM_NAME.qcow2"
  INSTALLER_WORKDIR="sno-workdir-$VM_NAME"
  INSTALLER_ISO_PATH_SNO_IN_LIBVIRT="${LIBVIRT_ISO_PATH}/installer-SNO-image-$VM_NAME.iso"
  MAC_ADDR="ba:dc:0f:fe:ee:00"
  RAM_MB="16384"
  DISK_GB="50"
  CPU_CORE="6"
  mkdir -p $INSTALLER_WORKDIR
  download_live_iso
  customize_install_config
  generate_ign
  generate_manifests
  embed_ign
  case $VM_NAME in
    rhacm) RAM_MB="49152"
           DISK_GB="100"
           CPU_CORE="16"
           ;;
    edge1) MAC_ADDR="ba:dc:0f:fe:ee:01" ;;
    edge2) MAC_ADDR="ba:dc:0f:fe:ee:02" ;;
    edge3) MAC_ADDR="ba:dc:0f:fe:ee:03" ;;
    edge4) MAC_ADDR="ba:dc:0f:fe:ee:04" ;;
  esac
  sleep 2
  install_vm_ign
  echo "Let it SNO !"
  sleep 2
done
