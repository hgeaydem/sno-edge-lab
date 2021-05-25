#!/bin/bash
KUBECONFIG=/root/auth-rhacm/kubeconfig

echo -ne "\n[INFO] Waiting for the rhacm cluster to be done installing (1/5, this one can take up to 40 minutes so sit back and relax)"
while [ ! "`oc status 2>/dev/null |grep -o openshift`" ]; do
   echo -n "."
   sleep 60s
done
echo -ne "\n[INFO] Waiting for the rhacm cluster to be done installing (2/5)"
while [ "`oc status 2>/dev/null |grep -o openshift`" ]; do
   echo -n "."
   sleep 5s
done
echo -ne "\n[INFO] Waiting for the rhacm cluster to be done installing (3/5)"
while [ ! "`oc status 2>/dev/null |grep -o openshift`" ]; do
   echo -n "."
   sleep 1s
done
echo -ne "\n[INFO] Waiting for the rhacm cluster to be done installing (4/5)"
while [ "`oc status 2>/dev/null |grep -o openshift`" ]; do
   echo -n "."
   sleep 5s
done
echo -ne "\n[INFO] Waiting for the rhacm cluster to be done installing (5/5 ... We're almost there !)"
while [ ! "`oc status 2>/dev/null |grep -o openshift`" ]; do
   echo -n "."
   sleep 1s
done
