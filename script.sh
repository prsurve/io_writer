#!/bin/sh

initial_workload_ns=""
pvc_name="dd-io-pvc-nf" # nf stands for noflag for dd
unset pvc_snapshot_array
unset pod_array
unset pending_pod_array

echo "Switching project to $initial_workload_ns"
oc project $initial_workload_ns


echo "Creating Snapshot"
snapshot_array=()
for i in {1..25}
do
    snapshot_name=$pvc_name-$i-snp-`date -u "+%Y-%m-%d-%H-%M-%S-%3N"`
    snapshot_array+=("$snapshot_name")
    echo "apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: $snapshot_name
spec:
  volumeSnapshotClassName: ocs-storagecluster-rbdplugin-snapclass
  source:
    persistentVolumeClaimName: $pvc_name-$i
" | kubectl apply -f -
sleep 1
done

sleep 10

echo "Checking VolumeSnapshot status"
pvc_snapshot_array=() # Array
for i in "${snapshot_array[@]}"
do
    output=$(oc get volumesnapshots $i -o json |jq -r .status.readyToUse)
    if [ "$output" == "true" ]
    then
        echo "$i is in Ready State"
        pvc_snapshot_array+=("$i")
    else
        for timeout on {1..10}
        do
            output_time=$(oc get volumesnapshots $i -o json |jq -r .status.readyToUse)
            if [ "$output_time" == "true" ]
            then
                echo "$i is in Ready State"
                pvc_snapshot_array+=("$i")
                break
            else
                sleep 10
            fi
        done
    fi
done


echo "Creating PVC from Snapshot"
for i in "${pvc_snapshot_array[@]}"
do
    echo "apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $i-sp-pvc
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

sleep 30

echo "Checking PVC status created from Snapshot"
pod_array=()
for i in "${pvc_snapshot_array[@]}"
do
    output=$(oc get pvc $i-sp-pvc -o json |jq -r .status.phase)
    if [ "$output" == "Bound" ]
    then
        echo "$i is in Bound state"
        pod_array+=("$i-sp-pvc")
    else
        for timeout on {1..15}
        do
            output_time=$(oc get pvc $i-sp-pvc -o json |jq -r .status.phase)
            if [ "$output_time" == "Bound" ]
            then
                echo "$i-sp-pvc is in Bound state"
                pod_array+=("$i-sp-pvc")
                break
            else
                sleep 10
            fi
        done
        echo "$i Failed to reach Bound State"            
    fi
done

echo "Creating Pod's" 

for i in "${pod_array[@]}"
do
    echo "apiVersion: v1
kind: Pod
metadata:
  name: $i-pod
  labels:
    snapshot: bz
spec:
  containers:
   - name: web-server
     image: quay.io/ocsci/nginx:latest" | kubectl apply -f -
done

sleep 60

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
                break
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
for i in "${pod_array[@]}"
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


sleep 300
