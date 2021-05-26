#!/bin/bash
KUBECONFIG=/root/auth-rhacm/kubeconfig

echo -ne "\n[INFO] Waiting for the rhacm cluster to be done installing (1/4, this one can take up to 40 minutes so sit back and relax)"
while [ ! "`nmap -sV -p 6443 192.168.123.10 |grep open`" ]; do
  echo -n "."
  sleep 1s
done
echo -ne "\n[INFO] Waiting for the rhacm cluster to be done installing (2/4)"
while [ ! "`oc status 2>/dev/null |grep -o openshift`" ]; do
   echo -n "."
   sleep 60s
done
echo -ne "\n[INFO] Waiting for the rhacm cluster to be done installing (3/4)"
while [ "`oc status 2>/dev/null |grep -o openshift`" ]; do
   echo -n "."
   sleep 5s
done
echo -ne "\n[INFO] Waiting for the rhacm cluster to be done installing (4/4)"
while [ ! "`oc status 2>/dev/null |grep -o openshift`" ]; do
   echo -n "."
   sleep 1s
done
# echo -ne "\n[INFO] Waiting for the rhacm cluster to be done installing (4/5)"
# while [ "`oc status 2>/dev/null |grep -o openshift`" ]; do
#    echo -n "."
#    sleep 5s
# done
# echo -ne "\n[INFO] Waiting for the rhacm cluster to be done installing (5/5 ... We're almost there !)"
# while [ ! "`oc status 2>/dev/null |grep -o openshift`" ]; do
#    echo -n "."
#    sleep 1s
# done
