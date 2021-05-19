#!/bin/bash
set -x

PULL_SECRET=''

INSTALLATION_DISK="/dev/vda"
RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release:4.8.0-fc.0-x86_64"
BASE_OS_IMAGE="https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/4.7/4.7.0/rhcos-4.7.0-x86_64-live.x86_64.iso"

OC_CLIENT=https://mirror.openshift.com/pub/openshift-v4/clients/ocp/latest-4.7/openshift-client-linux.tar.gz


########################
SNO_DIR="$(pwd)"
INSTALLER_WORKDIR="sno-workdir"
INSTALLER_BIN="bin/openshift-install"
LIVE_ISO_IGNITION_NAME="bootstrap-in-place-for-live-iso.ign"
BIP_LIVE_ISO_IGNITION="${INSTALLER_WORKDIR}/${LIVE_ISO_IGNITION_NAME}"
DOWNLOAD_PATH="${INSTALLER_WORKDIR}/base.iso"
EMBEDDED_ISO="${INSTALLER_WORKDIR}/embedded.iso"

LIBVIRT_ISO_PATH="/var/lib/libvirt/images"
INSTALLER_ISO_PATH="${SNO_DIR}/installer-image.iso"
INSTALLER_ISO_PATH_SNO="${SNO_DIR}/installer-SNO-image.iso"
INSTALLER_ISO_PATH_SNO_IN_LIBVIRT="${LIBVIRT_ISO_PATH}/installer-SNO-image.iso"

INSTALL_CONFIG_TEMPLATE="${SNO_DIR}/files/install-config.yaml.template"
INSTALL_CONFIG="${SNO_DIR}/install-config.yaml"
INSTALL_CONFIG_IN_WORKDIR="${INSTALLER_WORKDIR}/install-config.yaml"

NET_CONFIG_TEMPLATE="${SNO_DIR}/files/net.xml.template"
NET_CONFIG="${SNO_DIR}/net.xml"

NET_NAME="ocp4-net"
VM_NAME="rhacm"
VOL_NAME="$VM_NAME.qcow2"

SSH_KEY=$(cat ~/.ssh/id_rsa.pub)

SSH_KEY_DIR="${SNO_DIR}/ssh-key"
SSH_KEY_PUB_PATH="${SSH_KEY_DIR}/key.pub"
SSH_KEY_PRIV_PATH="${SSH_KEY_DIR}/key"

SSH_FLAGS=" -o IdentityFile=${SSH_KEY_PRIV_PATH} \
 			-o UserKnownHostsFile=/dev/null \
 			-o StrictHostKeyChecking=no"

SNO_HOST_IP="192.168.126.10"
SSH_HOST="core@${SNO_HOST_IP}"

prepare_host() {
  mkdir -p $INSTALLER_WORKDIR
  mkdir -p bin
  sudo dnf -y update
  sudo dnf -y install podman libvirt kvm-qemu jq bind dhcp-server
  sudo cp -f files/dhcpd.conf /etc/dhcp/dhcp.conf
  sudo cp -f files/named.conf /etc/named.conf
  sudo cp -f files/*.db /var/named/
  systemctl enable named
  systemctl enable dhcpd
  systemctl start named
  systemctl start dhcpd
  wget $OC_CLIENT
  tar -zxvf openshift-client*
  cp oc kubectl /usr/bin/
  jq -n $PULL_SECRET > registry-config.json
  oc adm release extract --registry-config=registry-config.json --command=openshift-install --to ./bin ${RELEASE_IMAGE}
}

download_live_iso() {
  curl ${BASE_OS_IMAGE} --retry 5 -o $DOWNLOAD_PATH
}

embed_ign() {
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

  rm nohup.out
  nohup virt-install \
      --connect qemu:///system \
      -n "${VM_NAME}" \
      -r "${RAM_MB}" \
      --vcpus "${CPU_CORE}" \
      --os-variant="${OS_VARIANT}" \
      --import \
      --network=network:${NET_NAME},mac=ba:dc:0f:fe:ee:00 \
      --graphics=none \
      --events on_reboot=restart \
      --cdrom "${INSTALLER_ISO_PATH_SNO_IN_LIBVIRT}" \
      --disk pool=default,size="${DISK_GB}" \
      --boot hd,cdrom \
      --noautoconsole \
      --wait=-1 &
}

prepare_host
define_network
download_live_iso
customize_install_config
generate_ign
generate_manifests
embed_ign
cp -f $EMBEDDED_ISO $INSTALLER_ISO_PATH_SNO_IN_LIBVIRT
install_vm_ign
