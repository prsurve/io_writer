#!/bin/sh

initial_workload_ns=""
pvc_name="dd-io-pvc-nf" # nf stands for noflag for dd
unset pvc_snapshot_array
unset pod_array
unset pending_pod_array

echo "Switching project to $initial_workload_ns"
oc project $initial_workload_ns


echo "Creating Snapshot"
for i in {1..25}
do
    echo "apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $pvc_name-$i-snapshot
spec:
  volumeSnapshotClassName: ocs-storagecluster-rbdplugin-snapclass
  source:
    persistentVolumeClaimName: $pvc_name-$i
" | kubectl apply -f -

done

echo "Checking VolumeSnapshot status"
pvc_snapshot_array=() # Array
for i in {1..25}
do
    output=$(oc get volumesnapshots $pvc_name-$i-snapshot -o json |jq -r .status.readyToUse)
    if [ "$output" == "true" ]
    then
        echo "$pvc_name-$i-snapshot is in Ready State"
        pvc_snapshot_array+=("$pvc_name-$i-snapshot")
    else
        for timeout on {1..10}
        do
            output_time=$(oc get volumesnapshots $pvc_name-$i-snapshot -o json |jq -r .status.readyToUse)
            if [ "$output_time" == "true" ]
            then
                echo "$pvc_name-$i-snapshot is in Ready State"
                pvc_snapshot_array+=("$pvc_name-$i-snapshot")
            else
                sleep 10
            fi
        done
        echo "$pvc_name-$i-snapshot Failed to reach Ready State"            
    fi
done


echo "Creating PVC from Snapshot"
for i in "${pvc_snapshot_array[@]}"
do
    echo "apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $i-snapshot-pvc
  labels:
    snapshot: bz
spec:
  storageClassName: ocs-storagecluster-ceph-rbd
  dataSource:
    name: $i
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
" | kubectl apply -f -
done

echo "Checking PVC status created from Snapshot"
pod_array=()
for i in $(oc get pvc --no-headers -l snapshot=bz|awk '{print$1}')
do
    output=$(oc get pvc $i -o json |jq -r .status.phase)
    if [ "$output" == "Bound" ]
    then
        echo "$i is in Bound state"
        pod_array+=("$i")
    else
        for timeout on {1..15}
        do
            output_time=$(oc get pvc $i -o json |jq -r .status.phase)
            if [ "$output_time" == "Bound" ]
            then
                echo "$i is in Bound state"
                pod_array+=("$i")
            else
                sleep 10
            fi
        done
        echo "$i Failed to reach Bound State"            
    fi
done

echo "Creating Pod's" 

for i in "${pvc_snapshot_array[@]}"
do
    echo "apiVersion: apps/v1
kind: Deployment
metadata:
  name: $i-pod
spec:
  selector:
    matchLabels:
      app: $i
      snapshot: bz
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        snapshot: bz
        app: $i
    spec:
      containers:
      - command:
        - sh
        - -c
        - /run-io.sh
        image: quay.io/prsurve/busybox:noflag
        imagePullPolicy: Always
        name: busybox
        volumeMounts:
        - mountPath: /mnt/test
          name: mypvc
      volumes:
      - name: mypvc
        persistentVolumeClaim:
          claimName: $i
          readOnly: false " | kubectl apply -f -
done


echo "Checking pod status"
pending_pod_array=()
for i in $(oc get pods -l snapshot=bz --no-headers|awk '{print$1}')
do
    output=$(oc get pod $i -o json |jq -r .status.phase)
    if [ "$output" == "Running" ]
    then
        echo "$i is in Running state"
    else
        for timeout on {1..15}
        do
            output_time=$(oc get pod $i -o json |jq -r .status.phase)
            if [ "$output_time" == "Running" ]
            then
                echo "$i is in Running state"
            else
                sleep 10
            fi
        done
        echo "$i Failed to reach Running State and current status is $output_time"    
        pending_pod_array+=("$i")        
    fi
done

echo "Collecting logs of non running pods if any"
for i in "${pending_pod_array[@]}"
do
    oc describe pod $i |tee ~/run_logs/$i > /dev/null # notprinting stdout
done

for i in $(oc get deployment -l snapshot=bz --no-headers|awk '{print$1}')
do
    oc delete deployment $i --force --grace-period=0
done
sleep 20
for i in $(oc get pvc -l snapshot=bz --no-headers|awk '{print$1}')
do
    oc delete pvc $i --force --grace-period=0
done
sleep 20

for i in "${pvc_snapshot_array[@]}"
do
    oc delete VolumeSnapshot $i --force --grace-period=0
done
sleep 20

unset pvc_snapshot_array
unset pod_array
unset pending_pod_array
