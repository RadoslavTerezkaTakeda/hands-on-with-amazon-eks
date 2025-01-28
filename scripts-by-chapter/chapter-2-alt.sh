#!/usr/bin/env bash

git clone https://github.com/pluralsight-cloud/hands-on-with-amazon-eks.git
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

( cd ./Infrastructure/k8s-tooling/load-balancer-controller/test && ./run-with-ssl.sh )

aws iam attach-role-policy --role-name ${nodegroup_iam_role} --policy-arn arn:aws:iam::aws:policy/AmazonRoute53FullAccess
( cd ./Infrastructure/k8s-tooling/external-dns && ./create.sh )

