# TC-MC-Migration



see https://www.cloudbees.com/blog/taming-jenkins-json-api-depth-and-tree


curl -u $TOKEN https://sda.acaternberg.flow-training.beescloud.com/cjoc/view/all/job/Teams/api/json&tree=jobs[name,lastBuild[number,duration,timestamp,result,changeSet[items[msg,author[fullName]]]]]