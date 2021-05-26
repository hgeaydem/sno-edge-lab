#!/bin/bash

for i in ocp4-bastion rhacm edge1 edge2 edge3 edge4
do
  virsh destroy $i
  virsh undefine $i
  rm -rf sno-workdir-$i
  rm -rf auth-$i
  rm -f /var/lib/libvirt/images/$i.qcow2
  rm -f /var/lib/libvirt/images/installer-SNO-image-$i
done
rm -rf kubectl oc bin base.iso bastion-deploy.sh openshift-client* registry-config.json
virsh net-destroy ocp4-net
