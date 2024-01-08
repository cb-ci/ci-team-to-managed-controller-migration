#! /bin/bash
source ./envvars.sh
##This script will request the set of connected Team Controllers from Cjoc
#Cjoc returns an array in this format
# {
#  "_class" : "com.cloudbees.hudson.plugins.folder.Folder",
#  "jobs" : [
#    {
#      "_class" : "com.cloudbees.opscenter.server.model.ManagedMaster",
#      "name" : "team1",
#      "url" : "https://example.com/cjoc/view/all/job/Teams/job/team1/"
#    }
#  ]
#}
# The scripts iterate over all TC and return names and URLs
# If more details are required, please adjust the JSON queries to your need
# Alternative you can iterate over a static bash array with a for/while loop

jq -cr '.jobs[] | (.name)' <<< $(curl -u $TOKEN "$CJOC_URL/view/all/job/Teams/api/json?pretty=true&tree=jobs\[name,url\]"
) | while read teamcontroller; do
   echo "TC: $teamcontroller"
   # We can now call the migration script
   # migrateTC2MC-simple.sh $teamcontroller
done



