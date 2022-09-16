#!/bin/sh
# set -x

initial_workload_ns=""
pvc_name="dd-io-pvc-nf" # nf stands for noflag for dd
unset pvc_snapshot_array
unset pvc_array
unset pending_pod_array
unset all_pod_array

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
        for z in {1..10}
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
    sleep 1
done

sleep 10

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
pvc_array=()
for i in "${pvc_snapshot_array[@]}"
do
    output=$(oc get pvc $i-sp-pvc -o json |jq -r .status.phase)
    if [ "$output" == "Bound" ]
    then
        echo "$i is in Bound state"
        pvc_array+=("$i-sp-pvc")
    else
        for z in {1..15}
        do
            output_time=$(oc get pvc $i-sp-pvc -o json |jq -r .status.phase)
            if [ "$output_time" == "Bound" ]
            then
                echo "$i-sp-pvc is in Bound state"
                pvc_array+=("$i-sp-pvc")
                break
            else
                sleep 10
            fi
        done
    fi
done

sleep 10

echo "Creating Pod's" 

for i in "${pvc_array[@]}"
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
     image: quay.io/ocsci/nginx:latest
     volumeMounts:
       - name: mypvc
         mountPath: /var/lib/www/html
  volumes:
   - name: mypvc
     persistentVolumeClaim:
       claimName: $i
       readOnly: false" | kubectl apply -f -
done

sleep 100

echo "Checking pod status"
pending_pod_array=()
all_pod_array=()
for i in "${pvc_array[@]}"
do
    output=$(oc get pod $i-pod -o json |jq -r .status.phase)
    if [ "$output" == "Running" ]
    then
        echo "$i-pod is in Running state"
        all_pod_array+=("$i-pod")
    else
        for z in {1..20}
        do
            output_time=$(oc get pod $i-pod -o json |jq -r .status.phase)
            if [ "$output_time" == "Running" ]
            then
                echo "$i-pod is in Running state"
                all_pod_array+=("$i-pod")
                break
            else
                sleep 15
            fi
        echo "$i-pod Failed to reach Running State and current status is $output_time"
               
        done
        # echo "$i-pod Failed to reach Running State and current status is $output_time"
        # pending_pod_array+=("$i-pod")
        check=$(oc get pods $i-pod --no-headers |awk '{print$3}')
        if [ "$check" != "Running" ]
        then
          pending_pod_array+=("$i-pod")  
        fi 
        all_pod_array+=("$i-pod")
    fi
done


echo "Collecting logs of non running pods if any"
for i in "${pending_pod_array[@]}"
do
    echo $i
    oc describe pod $i |tee ~/run_logs/$i > /dev/null # notprinting stdout
done
sleep 5

#removing pending pod from list for future
for del in ${pending_pod_array[@]}
do
   all_pod_array=("${all_pod_array[@]/$del}") #Quotes when working with strings
done

#removing pending pvc from list for future
for del in ${pending_pod_array[@]}
do
   to_delete=$(echo $del|rev |cut -c5- |rev)
   pvc_array=("${pvc_array[@]/$to_delete}") #Quotes when working with strings
done

#removing pending snap from list for future
for del in ${pending_pod_array[@]}
do
   to_delete=$(echo $del|rev |cut -c12- |rev)
   pvc_snapshot_array=("${pvc_snapshot_array[@]/$to_delete}") #Quotes when working with strings
done

for i in "${all_pod_array[@]}"
do
    oc delete pod $i --wait=true
done
sleep 20

for i in "${pvc_array[@]}"
do
    oc delete pvc $i --wait=true
done
sleep 20



for i in "${pvc_snapshot_array[@]}"
do
    oc delete VolumeSnapshot $i --wait=true
done

unset pvc_snapshot_array
unset pvc_array
unset pending_pod_array
unset all_pod_array

echo "Sleeping for 300 seconds"
sleep 300
