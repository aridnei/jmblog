#!/usr/bin/env sh

TASK_NAME="jmblog-api"
DOCKER_IMAGE=${ECR_ENDPOINT}:${CIRCLE_SHA1}
CLUSTER_NAME="jmblog-test"
SERVICE_NAME="jmblog-api"
AWS_CFG="--region us-east-2"

echo "Get the previous task definition"
OLD_TASK_DEF=$(aws $AWS_CFG ecs describe-task-definition --task-definition $TASK_NAME --output json)
OLD_TASK_DEF_REVISION=$(echo $OLD_TASK_DEF | jq ".taskDefinition|.revision")
echo "OLD_TASK_DEF"
echo $OLD_TASK_DEF
echo "OLD_TASK_DEF_REVISION"
echo $OLD_TASK_DEF_REVISION
echo "dropping in the new image"
NEW_TASK_DEF=$(echo $OLD_TASK_DEF | jq --arg NDI $DOCKER_IMAGE '.taskDefinition.containerDefinitions[0].image=$NDI')
echo "NEW_TASK_DEF"
echo $NEW_TASK_DEF
echo "create a new task template with all the required information to bring over"
FINAL_TASK=$(echo $NEW_TASK_DEF | jq '.taskDefinition|{ executionRoleArn: "arn:aws:iam::324148959017:role/ecsTaskExecutionRole", family: .family, volumes: .volumes, memory: .memory, containerDefinitions: .containerDefinitions, networkMode: "awsvpc", cpu: "256", requiresCompatibilities: ["FARGATE"] }')
echo "FINAL_TASK"
echo $FINAL_TASK
#Set variables for re-use
echo "Upload the task information and register the new task definition along with optional information"
UPDATED_TASK=$(aws $AWS_CFG ecs register-task-definition --cli-input-json "$(echo $FINAL_TASK)")
echo "UPDATED_TASK"
echo $UPDATED_TASK
echo "Storing the Revision"
UPDATED_TASK_DEF_REVISION=$(echo $UPDATED_TASK | jq ".taskDefinition|.taskDefinitionArn")
echo "Updated task def revision: $UPDATED_TASK_DEF_REVISION"

echo "switch over to the new task definition by selecting the newest revision"
SUCCESS_UPDATE=$(aws $AWS_CFG ecs update-service --service $SERVICE_NAME --task-definition $TASK_NAME --cluster $CLUSTER_NAME)

echo "Verify the new task definition attached and the old task definitions de-register aka cleanup"
for attempt in {1..8}; do
    #will return true if the updated task def is fully up and running in the service and the primary task def
    IS_ECS_READY=$(aws $AWS_CFG ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME | jq '.services[0] .deployments | .[] | select(.taskDefinition == '${UPDATED_TASK_DEF_REVISION}') | (.desiredCount == .runningCount and .status == "PRIMARY")')
    echo "Is ECS updated: $IS_ECS_READY"
    if [ $IS_ECS_READY = false ]; then
        echo "Waiting for $UPDATED_TASK_DEF_REVISION"
        echo "It needs to become the primary task def and reach desired instance count"
        sleep 20
        echo "Lets find all active task definitions"
        ACTIVE_TASK_DEFS=$(aws $AWS_CFG ecs list-task-definitions --family-prefix $TASK_NAME | jq '.taskDefinitionArns')
        echo "Here are the active task definitions: $ACTIVE_TASK_DEFS"
        #will return true if there are more than 1 task definitions still active
        IS_MULTIPLE_ACTIVE_TASK_DEFS=$(echo $ACTIVE_TASK_DEFS | jq 'map(select(. != '${UPDATED_TASK_DEF_REVISION}')) | length > 1')
        echo "Are there multiple active ones: $IS_MULTIPLE_ACTIVE_TASK_DEFS"
        IS_ALL_TASKS_DRAINED=false #should default this to false, so it doesnt throw an error below
        continue
    elif [ $IS_ALL_TASKS_DRAINED = true ]; then
        echo "Successfully cleaned up old tasks and running the new task."
        PRIMARY_TASK=$(aws $AWS_CFG ecs list-task-definitions --family-prefix $TASK_NAME | jq '.taskDefinitionArns[]')
        echo "$PRIMARY_TASK is the only running task"
        break
    else
        #iterate through the active tasks and register them
        echo $ACTIVE_TASK_DEFS | jq -r '.[] | select(. != '${UPDATED_TASK_DEF_REVISION}')' | \
        while read arn; do
            deregistered_status=$(aws $AWS_CFG ecs deregister-task-definition --task-definition $arn | jq '.taskDefinition .status');
            echo "Setting $arn task definition to " + $(echo $deregistered_status)
        done
        ACTIVE_TASK_DEFS=$(aws $AWS_CFG ecs list-task-definitions --family-prefix $TASK_NAME | jq '.taskDefinitionArns')
        echo "All obsolete tasks have been moved to INACTIVE"
        echo "but we want to make sure they are drained as well"
        sleep 30
        IS_ALL_TASKS_DRAINED=$(aws $AWS_CFG ecs describe-services --cluster $CLUSTER_NAME --services $SERVICE_NAME | jq '.services[0] .deployments | length == 1')
        echo "Are all obsolete tasks drained/stopped: $IS_ALL_TASKS_DRAINED"
    fi
done