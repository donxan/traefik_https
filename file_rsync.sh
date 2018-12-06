#!/bin/bash

for i in `seq 11 15`
do
  rsync -av /etc/kubernetes/ssl/tls* 192.168.2.$i:/etc/kubernetes/ssl/
  rsync -av /etc/k8s/ 192.168.2.$i:/etc/k8s/
done
