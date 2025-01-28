#!/usr/bin/env bash

cd hands-on-with-amazon-eks
./scripts-by-chapter/prepare-cloud-shell.sh
./scripts-by-chapter/chapter-1.sh

# Chapter 2.
nodegroup_iam_role=$(aws cloudformation list-exports --query "Exports[?contains(Name, 'nodegroup-eks-node-group::InstanceRoleARN')].Value" --output text | xargs | cut -d "/" -f 2)

( cd ./Infrastructure/k8s-tooling/load-balancer-controller && ./create.sh )
aws_lb_controller_policy=$(aws cloudformation describe-stacks --stack-name aws-load-balancer-iam-policy --query "Stacks[*].Outputs[?OutputKey=='IamPolicyArn'].OutputValue" --output text | xargs)
aws iam attach-role-policy --role-name ${nodegroup_iam_role} --policy-arn ${aws_lb_controller_policy}
# Attach admin policy as policies above aren't enough for the load balancer controller.
aws iam attach-role-policy --role-name ${nodegroup_iam_role} --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

( cd ./Infrastructure/cloudformation/ssl-certificate && ./create.sh )

aws iam attach-role-policy --role-name ${nodegroup_iam_role} --policy-arn arn:aws:iam::aws:policy/AmazonRoute53FullAccess
( cd ./Infrastructure/k8s-tooling/external-dns && ./create.sh )

( cd ./clients-api/infra/cloudformation && ./create-dynamodb-table.sh development ) & \
( cd ./inventory-api/infra/cloudformation && ./create-dynamodb-table.sh development ) & \
( cd ./renting-api/infra/cloudformation && ./create-dynamodb-table.sh development ) & \
( cd ./resource-api/infra/cloudformation && ./create-dynamodb-table.sh development ) &
wait

aws iam attach-role-policy --role-name ${nodegroup_iam_role} --policy-arn arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess

( cd ./resource-api/infra/helm && ./create.sh ) & \
( cd ./clients-api/infra/helm && ./create.sh ) & \
( cd ./inventory-api/infra/helm && ./create.sh ) & \
( cd ./renting-api/infra/helm && ./create.sh ) & \
( cd ./front-end/infra/helm && ./create.sh ) &
wait

# Wait for load balancer to be ready.
while true; do
  # Získajte zoznam load balancerov a ich stavov
  LOAD_BALANCERS=$(aws elbv2 describe-load-balancers --region us-east-1 --query "LoadBalancers[*].{Name:LoadBalancerName, State:State.Code}" --output text)

  # Prechádzajte cez každý load balancer a kontrolujte stav
  while read -r NAME STATE; do
    if [ "$STATE" == "active" ]; then
      echo "Load balancer $NAME is ready with state: $STATE"
      exit 0
    fi
  done <<< "$LOAD_BALANCERS"

  echo "No load balancers are ready yet. Checking again in 5 seconds."
  sleep 5
done

aws eks create-addon --addon-name vpc-cni --cluster-name eks-acg

# Wait for VPC CNI add-on to be in ACTIVE state.
addon_name="vpc-cni"
cluster_name="eks-acg"

check_addon_status() {
  aws eks describe-addon --cluster-name "$cluster_name" --addon-name "$addon_name" --query "addon.status" --output text
}

echo "Waiting for add-on '$addon_name' to be in 'ACTIVE' state..."

while true; do
  status=$(check_addon_status)
  if [ "$status" == "ACTIVE" ]; then
    echo "Add-on '$addon_name' is now ACTIVE."
    break
  else
    echo "Current status: $status. Waiting..."
    sleep 15
  fi
done

echo "Add-on VPC CNI is active."

( cd ./Infrastructure/k8s-tooling/cni && ./setup.sh )

# Delete former ec2 instances and wait for the new.
instance_ids=$(aws ec2 describe-instances --filters "Name=tag:alpha.eksctl.io/nodegroup-name,Values=eks-node-group" --query "Reservations[*].Instances[*].InstanceId" --output text)

echo "Terminating instances: $instance_ids"
AWS_PAGER="" aws ec2 terminate-instances --instance-ids $instance_ids

aws ec2 wait instance-terminated --instance-ids $instance_ids
echo "Old instances terminated."

get_running_instance_count() {
    aws ec2 describe-instance-status --filters "Name=instance-status.status,Values=ok" --query "InstanceStatuses[*].InstanceId" --output text | wc -w
}

echo "Waiting for new instances to be in 'running' state..."
while true; do
    running_count=$(get_running_instance_count)
    if [ "$running_count" -ge 3 ]; then
        echo "At least 3 new instances are running."
        break
    else
        echo "Currently running instances: $running_count. Waiting..."
        sleep 15
    fi
done

echo "New worker nodes are up and running."
