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

# Create DNS A record for the load balancer.
load_balancer_name=$(aws elbv2 describe-load-balancers --region us-east-1 --query 'LoadBalancers[0].LoadBalancerName' --output text)
load_balancer_dns_name="dualstack.$(aws elbv2 describe-load-balancers --region us-east-1 --query "LoadBalancers[?LoadBalancerName=='$load_balancer_name'].DNSName" --output text)"
hosted_zone_id=$(aws route53 list-hosted-zones --query "HostedZones[0].Id" --output text | cut -d'/' -f3)
canon_hosted_zone_id=$(aws elbv2 describe-load-balancers --names "$load_balancer_name" --query 'LoadBalancers[0].CanonicalHostedZoneId' --output text)
domain_name=$(aws route53 get-hosted-zone --id "$hosted_zone_id" --query "HostedZone.Name" --output text)
cat > change-batch.json <<EOL
{
  "Comment": "Add alias record for sample-app",
  "Changes": [
    {
      "Action": "CREATE",
      "ResourceRecordSet": {
        "Name": "sample-app.$domain_name",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "$canon_hosted_zone_id",
          "DNSName": "$load_balancer_dns_name",
          "EvaluateTargetHealth": false
        }
      }
    }
  ]
}
EOL
aws route53 change-resource-record-sets --hosted-zone-id $hosted_zone_id --change-batch file://change-batch.json
