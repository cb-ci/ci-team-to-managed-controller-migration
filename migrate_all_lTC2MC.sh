#! /bin/bash
echo HALLO
source ./envvars.sh

jq -cr '.jobs[] | (.name, .url)' <<< $(curl -u $TOKEN "$CJOC_URL/view/all/job/Teams/api/json?pretty=true&tree=jobs\[name,url\]"
) | while read teamcontroller; do
   echo "TC: $name URL:$url"
   # We can now call the migration script
   # ./migrateTC2MC.sh $name

done