#! /bin/bash
NAMESPACE=cloudbees-core
CLAIM_NAME_SOURCE=${1:-jenkins-home-source-0}
CLAIM_NAME_DESTINATION=${2:-jenkins-home-destination-0}

cat <<EOF | kubectl --namespace=$NAMESPACE apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: rescue-pvc
spec:
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    fsGroup: 1000
  volumes:
    - name: pv-data-source
      persistentVolumeClaim:
        claimName: ${CLAIM_NAME_SOURCE}
    - name: pv-data-destination
      persistentVolumeClaim:
        claimName: ${CLAIM_NAME_DESTINATION}
   # emptyDir: {}
  containers:
  - name: rescue-pvc
    #image: busybox
    image: instrumentisto/rsync-ssh
    command: [ "sh", "-c", "sleep 10000" ]
    volumeMounts:
    - name:  pv-data-source
      mountPath: /tmp/jenkins_home_source
    - name: pv-data-destination
      mountPath: /tmp/jenkins_home_destination
    securityContext:
      allowPrivilegeEscalation: false
EOF


#kubectl exec -ti rescue-pvc -- ls -l /tmp

#This command will sync all jobs and jobs folders excluding the build
kubectl exec -ti rescue-pvc -- rsync -az --exclude="*/builds/" /tmp/jenkins_home_source/jobs/ /tmp/jenkins_home_destination/jobs