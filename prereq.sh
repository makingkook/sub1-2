#!/bin/bash
# eksctl create cluster 전에 1번 실행 (CloudShell)
set -euo pipefail
R=ap-northeast-2
CLUSTER=unicorn-eks-cluster
ACC=$(aws sts get-caller-identity --query Account --output text)
APP_KEY=$(aws kms describe-key --region $R --key-id alias/unicorn-kms-app --query KeyMetadata.Arn --output text)
PLATFORM_KEY=$(aws kms describe-key --region $R --key-id alias/unicorn-kms-platform --query KeyMetadata.Arn --output text)
cd "$(dirname "$0")"

# 1) 클러스터 로그 그룹 (Platform 키 암호화) — eksctl은 로그 그룹 암호화를 못 함
aws logs create-log-group --region $R --log-group-name /aws/eks/$CLUSTER/cluster --kms-key-id "$PLATFORM_KEY" 2>/dev/null \
  || echo "log group already exists"

# 2) AWS Load Balancer Controller 정책
aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json >/dev/null 2>&1 || echo "LBC policy already exists"

# 3) Book App Pod Identity Role: 이 클러스터에서만 사용 + PutItem/App 키만
cat > /tmp/book-trust.json <<J
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"pods.eks.amazonaws.com"},
 "Action":["sts:AssumeRole","sts:TagSession"],
 "Condition":{"StringEquals":{"aws:SourceAccount":"$ACC"},
              "ArnEquals":{"aws:SourceArn":"arn:aws:eks:$R:$ACC:cluster/$CLUSTER"}}}]}
J
cat > /tmp/book-policy.json <<J
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":"dynamodb:PutItem","Resource":"arn:aws:dynamodb:$R:$ACC:table/unicorn-concert-db"},
 {"Effect":"Allow","Action":["kms:Decrypt","kms:GenerateDataKey"],"Resource":"$APP_KEY",
  "Condition":{"StringEquals":{"kms:ViaService":"dynamodb.$R.amazonaws.com"}}}]}
J
aws iam create-role --role-name unicorn-book-app-role --assume-role-policy-document file:///tmp/book-trust.json >/dev/null 2>&1 \
  || aws iam update-assume-role-policy --role-name unicorn-book-app-role --policy-document file:///tmp/book-trust.json
aws iam put-role-policy --role-name unicorn-book-app-role --policy-name unicorn-book-app-policy --policy-document file:///tmp/book-policy.json

# 4) Grafana Pod Identity Role: CloudWatch 메트릭 조회만
cat > /tmp/grafana-trust.json <<J
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"Service":"pods.eks.amazonaws.com"},
 "Action":["sts:AssumeRole","sts:TagSession"],
 "Condition":{"StringEquals":{"aws:SourceAccount":"$ACC"},
              "ArnEquals":{"aws:SourceArn":"arn:aws:eks:$R:$ACC:cluster/$CLUSTER"}}}]}
J
cat > /tmp/grafana-policy.json <<J
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["cloudwatch:GetMetricData","cloudwatch:ListMetrics","cloudwatch:GetMetricStatistics"],"Resource":"*"}]}
J
aws iam create-role --role-name unicorn-grafana-role --assume-role-policy-document file:///tmp/grafana-trust.json >/dev/null 2>&1 \
  || aws iam update-assume-role-policy --role-name unicorn-grafana-role --policy-document file:///tmp/grafana-trust.json
aws iam put-role-policy --role-name unicorn-grafana-role --policy-name unicorn-grafana-policy --policy-document file:///tmp/grafana-policy.json

echo "done: log group / LBC policy / unicorn-book-app-role / unicorn-grafana-role"
