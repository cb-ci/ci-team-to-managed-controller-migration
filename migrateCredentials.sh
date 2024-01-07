#! /bin/bash

source ./envvars.sh

# EXPORT FOLDER CREDENTIALS
echo "------------------  EXPORT FOLDER CREDENTIALS  ------------------"
curl -o ./credentials-migration/export-credentials-folder-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/export-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat ./credentials-migration/export-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/teams-${CONTROLLER_NAME}/scriptText  -o $GENDIR/test-folder.creds
tail -n 1  $GENDIR/test-folder.creds | sed  -e "s#\[\"##g"  -e "s#\"\]##g"  | tee  $GENDIR/folder-imports.txt

# IMPORT FOLDER CREDENTIALS
echo "------------------  IMPORT FOLDER CREDENTIALS  ------------------"
kubectl cp $GENDIR/folder-imports.txt ${CONTROLLER_NAME}-0:/var/jenkins_home/
curl -o ./credentials-migration/update-credentials-folder-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/update-credentials-folder-level.groovy
cat ./credentials-migration/update-credentials-folder-level.groovy | sed  "s#^\/\/ encoded.*#encoded = [new File(\"/var\/jenkins_home\/folder-imports.txt\").text]#g" >  $GENDIR/update-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat $GENDIR/update-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/${CONTROLLER_NAME}/scriptText

# EXPORT SYSTEM CREDENTIALS
echo "------------------  EXPORT SYSTEM CREDENTIALS  ------------------"
curl -o ./credentials-migration/export-credentials-system-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/export-credentials-system-level.groovy
curl --data-urlencode "script=$(cat ./credentials-migration/export-credentials-system-level.groovy)" \
--user $TOKEN ${BASE_URL}/teams-${CONTROLLER_NAME}/scriptText  -o $GENDIR/test-system-folder.creds
tail -n 1  $GENDIR/test-system-folder.creds | sed  -e "s#\[\"##g"  -e "s#\"\]##g"  | tee  $GENDIR/system-imports.txt

# IMPORT SYSTEM CREDENTIALS
echo "-------------------- IMPORT SYSTEM CREDENTIALS  ------------------"
kubectl cp $GENDIR/system-imports.txt ${CONTROLLER_NAME}-0:/var/jenkins_home/
curl -o ./credentials-migration/update-credentials-system-level.groovy https://raw.githubusercontent.com/cloudbees/jenkins-scripts/master/credentials-migration/update-credentials-system-level.groovy
cat ./credentials-migration/update-credentials-system-level.groovy | sed  "s#^\/\/ encoded.*#encoded = [new File(\"/var\/jenkins_home\/system-imports.txt\").text]#g" >  $GENDIR/update-credentials-folder-level.groovy
curl --data-urlencode "script=$(cat $GENDIR/update-credentials-folder-level.groovy)" \
--user $TOKEN ${BASE_URL}/${CONTROLLER_NAME}/scriptText