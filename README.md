# TC-MC-Migration


# JSON API 
* https://www.cloudbees.com/blog/taming-jenkins-json-api-depth-and-tree
* https://garygeorge84.medium.com/jenkins-api-with-node-4d3826322367

> curl -u $TOKEN "https://sda.acaternberg.flow-training.beescloud.com/cjoc/view/all/job/Teams/api/json&tree=jobs[name,lastBuild[number,duration,timestamp,result,changeSet[items[msg,author[fullName]]]]]"
> curl -u $TOKEN "https://sda.acaternberg.flow-training.beescloud.com/cjoc/view/all/job/Teams/api/json?depth=2&pretty=true?tree=jobs" | jq