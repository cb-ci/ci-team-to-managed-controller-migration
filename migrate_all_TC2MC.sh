#! /bin/bash
echo HALLO
source ./envvars.sh

##This script will request the set of connected Team Controllers from Cjoc
#Cjoc return an array in this format
#{
#  "_class" : "com.cloudbees.hudson.plugins.folder.Folder",
#  "jobs" : [
#    {
#      "_class" : "com.cloudbees.opscenter.server.model.ManagedMaster",
#      "name" : "team1",
#      "url" : "https://example.com/cjoc/view/all/job/Teams/job/team1/"
#    }
#  ]
#}
# The scripts iterates over all TC and return names and urls
# If more details are required, pleas adjust the json queries to your need
# Alternative you can iterate over an static bash array with an for/while loop

jq -cr '.jobs[] | (.name, .url)' <<< $(curl -u $TOKEN "$CJOC_URL/view/all/job/Teams/api/json?pretty=true&tree=jobs\[name,url\]"
) | while read teamcontroller; do
   echo "TC: $name URL:$url"
   # We can now call the migration script
   # ./migrateTC2MC.sh $name
done

