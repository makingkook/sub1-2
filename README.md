# k8s — Book App + Grafana 배포

eksctl로 클러스터를 만들고, ALB/TG는 AWS에서 직접 만든 뒤 **AWS Load Balancer Controller의 TargetGroupBinding**으로 Pod를 TG에 연결하는 방식입니다. Ingress는 쓰지 않습니다.

```
CloudFront ─ VPC Origin ─ unicorn-alb(Internal) ─ unicorn-tg ─ TGB ─ unicorn-book-app-svc ─ Book App Pod (app 노드)
사용자 ──────────────── unicorn-grafana-alb ─ unicorn-grafana-tg ─ TGB ─ unicorn-monitoring-grafana ─ Grafana (addon 노드)
```

## 파일
| 파일 | 내용 |
|---|---|
| `cluster.yaml` | eksctl 클러스터 (Private 전환, Secrets/EBS 암호화, 로그 5종, KST, Pod Identity) |
| `prereq.sh` | 클러스터 생성 전 1회: 로그 그룹, LBC 정책, Book App / Grafana Role |
| `iam_policy.json` | AWS Load Balancer Controller 정책 |
| `config.yaml` | Namespace `unicorn` + ConfigMap (AWS_REGION, TABLE_NAME) |
| `deployment.yaml` | ServiceAccount `unicorn-app-sa` + Deployment |
| `service.yaml` | ClusterIP Service |
| `book-tgb.yaml` | unicorn-tg ↔ Book App |
| `monitoring/values.yaml` | kube-prometheus-stack 설정 |
| `monitoring/grafana-tgb.yaml` | unicorn-grafana-tg ↔ Grafana |
| `monitoring/dashboard.yaml` | unicorn-grafana-dashboard (패널 5개) |

## 미리 AWS에 있어야 하는 것
- VPC/서브넷, KMS 키 3개, DynamoDB `unicorn-concert-db`, ECR 이미지 `unicorn-concert-app:latest`
- `unicorn-alb` (Internal, HTTP 80) + `unicorn-tg` (**IP 타입, 8080, health `/health`**)
  - ALB SG 인바운드: CloudFront prefix list(`com.amazonaws.global.cloudfront.origin-facing`) 80만
- `unicorn-grafana-alb` (Internet-facing, 퍼블릭 서브넷, HTTP 80) + `unicorn-grafana-tg` (**IP 타입, 3000, health `/api/health`**)

## 배포 순서
```bash
# 1. 사전 준비
bash prereq.sh

# 2. 클러스터
eksctl create cluster -f cluster.yaml

# 3. AWS Load Balancer Controller (addon 노드)
VPC_ID=$(aws eks describe-cluster --name unicorn-eks-cluster --query cluster.resourcesVpcConfig.vpcId --output text)
helm repo add eks https://aws.github.io/eks-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName=unicorn-eks-cluster --set region=ap-northeast-2 --set vpcId=$VPC_ID \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller \
  --set nodeSelector.unicorn=addon
kubectl -n kube-system rollout status deploy/aws-load-balancer-controller

# 4. Book App (파일 순서 중요: Namespace가 먼저)
kubectl apply -f config.yaml -f deployment.yaml -f service.yaml -f book-tgb.yaml

# 5. Prometheus + Grafana  (values.yaml 의 <번호> 먼저 수정)
helm install unicorn-monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace -f monitoring/values.yaml

# 6. Grafana TGB, 대시보드 (각 파일의 <...> 값 먼저 수정)
kubectl apply -f monitoring/grafana-tgb.yaml -f monitoring/dashboard.yaml

# 7. API 엔드포인트 Private 전환 (채점 6-1-A: false true)
eksctl utils update-cluster-vpc-config --cluster unicorn-eks-cluster \
  --public-access=false --private-access=true --approve
```
7번 이후 kubectl은 VPC 안(CloudShell `unicorn-mark`)에서만 됩니다. 클러스터 SG에 `443 / 10.97.0.0/16` 인바운드를 열어 두세요.

## `<...>` 값 찾기
```bash
# monitoring/grafana-tgb.yaml
aws elbv2 describe-target-groups --names unicorn-grafana-tg --query "TargetGroups[0].TargetGroupArn" --output text
aws elbv2 describe-load-balancers --names unicorn-grafana-alb --query "LoadBalancers[0].SecurityGroups[0]" --output text

# monitoring/dashboard.yaml (ARN에서 'app/...', 'targetgroup/...' 부분)
aws elbv2 describe-load-balancers --names unicorn-alb --query "LoadBalancers[0].LoadBalancerArn" --output text | sed 's#.*:loadbalancer/##'
aws elbv2 describe-target-groups --names unicorn-tg --query "TargetGroups[0].TargetGroupArn" --output text | sed 's#.*:##'
```

## 확인
```bash
kubectl get pods -n unicorn -o wide          # app 노드에 2개 Running
kubectl get pods -n monitoring               # prometheus-unicorn-monitoring-..., unicorn-monitoring-grafana-... Running
kubectl get targetgroupbinding -A
kubectl exec -n unicorn deploy/unicorn-book-app-deploy -c book -- printenv AWS_REGION TABLE_NAME
aws eks list-pod-identity-associations --cluster-name unicorn-eks-cluster
```
Grafana: `http://<unicorn-grafana-alb DNS>` → `skills<번호>` / `HelloKrSkills!<번호>@` → `unicorn-grafana-dashboard`

## 참고
- **HTTP Request Duration 패널**은 ALB `TargetResponseTime`(p50/p95/p99)을 CloudWatch에서 가져옵니다. 요청이 한 번도 없으면 No Data로 보이니 채점 전에 POST/GET 몇 번 보내 두세요.
- **ServiceAccount**를 이미 `kubectl create sa`로 만들었다면 `deployment.yaml` 맨 위 SA 부분은 있어도(경고만) 없어도 됩니다.
- **컨테이너 로그(Fluent Bit → `/unicorn/eks/book-app`)**는 이 폴더에 포함되어 있지 않습니다.
