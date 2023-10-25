#!/bin/bash

source ./envvars.sh

#In case we trigger this script from a loop, it will take the controller name from the fhe first parameter $1
export CONTROLLER_NAME=${1:-$CONTROLLER_NAME}
export CONTROLLER_URL=${BASE_URL}"/"${CONTROLLER_NAME}

GEN_DIR=gen
rm -rf $GEN_DIR
mkdir -p $GEN_DIR

function checkControllerOnline () {
  # We have to wait until ingress is created and we can call the Jenkins HealthCheck with state 200
  while [ ! -n "$(curl  -IL  ${CONTROLLER_URL}/login | grep -o  'HTTP/2 200')" ]
  do
    echo "wait 30 sec for State HTTP 200:  ${CONTROLLER_URL}/login"
    sleep 30
  done
}

# We render the CasC template instances for cjoc-controller-items.yaml and the casc-folder (target folder)
# All variables from the envvars.sh will be substituted
envsubst < ${CREATE_MM_TEMPLATE_YAML} > $GEN_DIR/${CONTROLLER_NAME}.yaml
envsubst < ${CREATE_MM_FOLDER_TEMPLATE_YAML} > $GEN_DIR/${CONTROLLER_NAME}-folder.yaml

# We switch to the cloudbees namespace, where the TC runs
#kubens $NAMESPACE
kubectl config set-context $(kubectl config current-context) --namespace=$NAMESPACE_CB_CORE

#CREATE MC CONTROLLER
# We apply the cjoc-controller-items.yaml to cjoc. Cjoc will create a new MC for us using our $GEN_DIR/${CONTROLLER_NAME}.yaml
echo "------------------  CREATING MANAGED CONTROLLER ------------------"
curl -XPOST \
   --user $TOKEN \
   "${CJOC_URL}/casc-items/create-items" \
    -H "Content-Type:text/yaml" \
   --data-binary @$GEN_DIR/${CONTROLLER_NAME}.yaml

# We wait until our new Managed Controller pod is up
echo "------------------  WAITING FOR CONTROLLER TO COME UP ------------------"
checkControllerOnline

# Now we apply the target Folder to the Managed Controller.
# This is the root folder where we want to migrate our credentials and jobs to
echo "------------------  CREATING INITIAL TEAM FOLDER ------------------"
curl -v  -XPOST \
    --user $TOKEN \
    "${CONTROLLER_URL}/casc-items/create-items" \
     -H "Content-Type:text/yaml" \
    --data-binary @$GEN_DIR/${CONTROLLER_NAME}-folder.yaml -o $GEN_DIR/create-folder-output.log
# curl  -XPOST -u ${TOKEN} ${CONTROLLER_URL}/casc-items/create-items -d @${CONTROLLER_NAME}-folder.yaml
# sleep 180

# COPY JOBS
# We copy the jobs folder recursive from TC to the new folder on MC
echo "------------------  COPYING JOBS FOLDER ------------------"
mkdir -p $GEN_DIR/teams-${CONTROLLER_NAME}-jobs
#kubectl exec -it teams-${CONTROLLER_NAME}-0 --  tar -cvzf /tmp/${CONTROLLER_NAME}-job.tar.gz -C /var/jenkins_home/jobs/
kubectl cp teams-${CONTROLLER_NAME}-0:var/jenkins_home/jobs/${CONTROLLER_NAME}/jobs/ $GEN_DIR/teams-${CONTROLLER_NAME}-jobs/
kubectl cp $GEN_DIR/teams-${CONTROLLER_NAME}-jobs/. ${CONTROLLER_NAME}-0:var/jenkins_home/jobs/${CONTROLLER_NAME}/jobs
#kubectl exec -it ${CONTROLLER_NAME}-0 --  tar -xvf /tmp/${CONTROLLER_NAME}-job.tar.gz -C /var/jenkins_home/jobs/ 

# Now we restart the MC
curl -u ${TOKEN} -X POST ${CONTROLLER_URL}/restart
checkControllerOnline

# EXPORT FOLDER CREDENTIALS
echo "------------------  EXPORT FOLDER CREDENTIALS  ------------------"
curl -o ./credentials-migration/export-credentials-folder-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/export-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat ./credentials-migration/export-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/teams-${CONTROLLER_NAME}/scriptText  -o $GEN_DIR/test-folder.creds
tail -n 1  $GEN_DIR/test-folder.creds | sed  -e "s#\[\"##g"  -e "s#\"\]##g"  | tee  $GEN_DIR/folder-imports.txt

# IMPORT FOLDER CREDENTIALS
echo "------------------  IMPORT FOLDER CREDENTIALS  ------------------"
kubectl cp $GEN_DIR/folder-imports.txt ${CONTROLLER_NAME}-0:/var/jenkins_home/
curl -o ./credentials-migration/update-credentials-folder-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/update-credentials-folder-level.groovy  
cat ./credentials-migration/update-credentials-folder-level.groovy | sed  "s#^\/\/ encoded.*#encoded = [new File(\"/var\/jenkins_home\/folder-imports.txt\").text]#g" >  $GEN_DIR/update-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat $GEN_DIR/update-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/${CONTROLLER_NAME}/scriptText

# EXPORT SYSTEM CREDENTIALS
echo "------------------  EXPORT SYSTEM CREDENTIALS  ------------------"
curl -o ./credentials-migration/export-credentials-system-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/export-credentials-system-level.groovy
curl --data-urlencode "script=$(cat ./credentials-migration/export-credentials-system-level.groovy)" \
--user $TOKEN ${BASE_URL}/teams-${CONTROLLER_NAME}/scriptText  -o $GEN_DIR/test-system-folder.creds
tail -n 1  $GEN_DIR/test-system-folder.creds | sed  -e "s#\[\"##g"  -e "s#\"\]##g"  | tee  $GEN_DIR/system-imports.txt

# IMPORT SYSTEM CREDENTIALS
echo "-------------------- IMPORT SYSTEM CREDENTIALS  ------------------"
kubectl cp $GEN_DIR/system-imports.txt ${CONTROLLER_NAME}-0:/var/jenkins_home/
curl -o ./credentials-migration/update-credentials-system-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/update-credentials-system-level.groovy
cat ./credentials-migration/update-credentials-system-level.groovy | sed  "s#^\/\/ encoded.*#encoded = [new File(\"/var\/jenkins_home\/system-imports.txt\").text]#g" >  $GEN_DIR/update-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat $GEN_DIR/update-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/${CONTROLLER_NAME}/scriptText
