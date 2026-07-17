#!/usr/bin/env bash
# shellcheck disable=SC2016  # --query의 JMESPath 백틱과 '$Latest'는 셸 확장이 아니라 aws CLI 리터럴입니다.
#########################################################################################################
## eks_lab_reset.sh — EKS 실습 리소스 강제 초기화 (학생용)
##
## 언제 쓰는가:
##   terraform apply/destroy가 중간에 끊기거나(노트북 절전, 자격 증명 만료, Ctrl+C),
##   state 파일과 실제 AWS 리소스가 어긋나면(재 apply 시 AlreadyExists 등) terraform만으로는
##   복구가 안 됩니다. 이 스크립트는 실습 클러스터가 만든 리소스를 태그·이름 패턴으로 찾아
##   의존 순서대로 지워, 수동 콘솔 정리 없이 "깨끗한 재시작" 상태를 만듭니다.
##
## 사용법:
##   bash eks_lab_reset.sh <cluster_name>                        # 기본값: 지울 대상 목록만 출력(dry-run)
##   bash eks_lab_reset.sh <cluster_name> --delete               # 실제 삭제 (목록·계정 확인 후
##                                                               #  클러스터 이름 재입력해야 진행)
##   bash eks_lab_reset.sh <cluster_name> --delete --reset-local # 삭제 + 로컬 tfstate/.terraform 초기화
##
## 옵션:
##   --delete         실제로 삭제합니다. 삭제 직전에 대상 전체 목록·개수·계정을 다시 보여 주고,
##                    클러스터 이름을 그대로 재입력해야만 진행합니다(반사적 엔터·y 복붙 방지).
##   --reset-local    terraform 로컬 상태(tfstate·백업·.terraform/·lock)를 제거합니다.
##                    state 파일은 tfstate-backup-<시각>/ 으로 옮겨 두므로 복구 가능합니다.
##   --tf-dir <경로>  --reset-local이 정리할 terraform 디렉토리 (기본: 현재 디렉토리)
##   --profile <이름> AWS CLI 프로필 (기본: AWS_PROFILE 환경변수 또는 기본 자격 증명)
##   --region <리전>  AWS 리전 (기본: AWS_REGION > AWS_DEFAULT_REGION > ap-northeast-2)
##   --skip-tf-check  시작 시 "terraform destroy 먼저" 리마인드를 생략합니다.
##   --yes            [강사·자동화 전용 — 학생 사용 금지] 이름 재입력 확인 없이 즉시 삭제합니다.
##                    CI 등 비대화형 자동화를 위한 플래그입니다. 교재·FAQ에는 이 플래그를
##                    노출하지 않습니다 — 학생 표준 경로는 --delete의 이름 재입력 확인입니다.
##
## 필요 도구: bash, aws CLI v2 (jq 불필요 — --query만 사용)
##
## ── 안전 보증: 이 스크립트가 건드리는 리소스의 범위 ─────────────────────────────────────
## 아래 "발견 근거" 중 하나에 해당하는 리소스만 대상으로 삼습니다. 근거가 없는 리소스는
## 같은 계정에 있어도 절대 조회 목록에 넣지 않고, 따라서 삭제도 하지 않습니다.
##
##   (1) EKS 클러스터/노드그룹/Pod Identity: 이름이 정확히 <cluster_name>이고 실습 공통 태그
##       project=cloudwave-eks(실습 tf의 default_tags)가 붙은 클러스터와 그 하위 리소스.
##       동명이지만 실습 태그가 없는 클러스터(다른 방식으로 만든 것)는 경고만 하고 제외합니다.
##   (2) 로드밸런서(ALB/NLB)·타깃그룹: AWS Load Balancer Controller가 붙이는
##       elbv2.k8s.aws/cluster = <cluster_name> 태그
##   (3) VPC와 그 내부(서브넷·IGW·라우트테이블·보안그룹·ENI·EC2):
##       Name = <cluster_name>-vpc 태그 + 실습 공통 태그 project=cloudwave-eks가 둘 다
##       붙은 전용 VPC의 경계 안. 실습 tf는 클러스터마다 VPC를 새로 만들므로(공유 VPC 없음),
##       이 VPC 안의 리소스는 전부 이 실습의 산물입니다. VPC 경계 자체가 발견 근거입니다.
##       (한계: 같은 계정에서 다른 사람이 "같은 클러스터명"으로 같은 실습을 돌렸다면 이름으로
##        구분할 방법이 없습니다. 공용 계정에서는 클러스터명을 서로 다르게 쓰는 것이 전제입니다.)
##   (4) EC2 인스턴스·EBS 볼륨·스냅샷: kubernetes.io/cluster/<cluster_name> = owned|shared
##       또는 eks:cluster-name = <cluster_name> 태그 (EKS·EBS CSI 드라이버가 붙임)
##   (5) Auto Scaling 그룹: eks:cluster-name = <cluster_name> 또는
##       kubernetes.io/cluster/<cluster_name> = owned 태그 (EKS 관리형 노드그룹이 붙임 —
##       노드그룹 레코드만 지워지고 ASG가 남으면 인스턴스를 계속 재생성하는 잔존물)
##   (6) IAM 역할: 실습 tf의 실제 네이밍 + 실습 공통 태그(project=cloudwave-eks) 동시 일치 —
##         <cluster_name>-ebs-csi            (tf가 이름을 직접 지정)
##         <cluster_name>-cluster-<난수>      (EKS 모듈이 name_prefix로 생성)
##         default-eks-node-group-<난수>      (모듈 노드그룹 역할 — 이름에 클러스터명이 없어
##                                            노드그룹이 살아 있으면 nodeRole ARN으로 정확히 잡고,
##                                            이미 사라졌으면 이름 접두어 + 실습 태그 +
##                                            "현재 어떤 클러스터도 사용 중이 아님"
##                                            3중 확인을 통과한 것만 대상)
##   (7) IAM OIDC 공급자: Name = <cluster_name>-eks-irsa 태그 + 실습 공통 태그 동시 일치
##   (8) CloudWatch 로그 그룹: 이름이 정확히 /aws/eks/<cluster_name>/cluster
##       (EKS 모듈이 control plane 로그용으로 생성 — 클러스터를 지워도 남는 대표 잔존물)
##   (9) 런치 템플릿: 노드그룹이 살아 있으면 노드그룹이 참조하는 ID로,
##       사라졌으면 "실습 태그 + 템플릿의 보안그룹이 (3)의 VPC 소속"일 때만 대상
## ──────────────────────────────────────────────────────────────────────────────────────
#########################################################################################################
set -uo pipefail
# 왜 set -e를 안 쓰는가: 이 스크립트의 절반은 "이미 없는 리소스 조회"라서 aws CLI의
# 실패(exit≠0)가 정상 흐름입니다. -e로 즉사시키는 대신 단계마다 성패를 직접 판정합니다.

#########################################################################################################
## 인자 파싱
#########################################################################################################
CLUSTER_NAME=""
DELETE_MODE=false   # --delete: 이름 재입력 확인을 거쳐 삭제 (학생 표준 경로)
ASSUME_YES=false    # --yes: 확인 없이 삭제 (강사·자동화 전용)
RESET_LOCAL=false
SKIP_TF_CHECK=false
TF_DIR="$PWD"
PROFILE="${AWS_PROFILE:-}"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-2}}"

usage() {
  cat <<'EOF'
사용법:
  bash eks_lab_reset.sh <cluster_name>                        # dry-run: 지울 대상 목록만 출력
  bash eks_lab_reset.sh <cluster_name> --delete               # 실제 삭제(이름 재입력 확인 후 진행)
  bash eks_lab_reset.sh <cluster_name> --delete --reset-local # 삭제 + 로컬 tfstate/.terraform 초기화

옵션:
  --delete         실제로 삭제합니다. 삭제 직전에 대상 목록·개수·계정을 다시 보여 주고,
                   클러스터 이름을 그대로 재입력해야만 진행합니다.
  --reset-local    terraform 로컬 상태(tfstate·백업·.terraform/·lock)를 제거합니다.
                   state 파일은 tfstate-backup-<시각>/ 으로 옮겨 두므로 복구 가능합니다.
  --tf-dir <경로>  --reset-local이 정리할 terraform 디렉토리 (기본: 현재 디렉토리)
  --profile <이름> AWS CLI 프로필 (기본: AWS_PROFILE 환경변수 또는 기본 자격 증명)
  --region <리전>  AWS 리전 (기본: AWS_REGION > AWS_DEFAULT_REGION > ap-northeast-2)
  --skip-tf-check  시작 시 "terraform destroy 먼저" 리마인드를 생략합니다.
  --yes            [강사·자동화 전용 — 학생 사용 금지] 이름 재입력 확인 없이 즉시 삭제합니다.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --delete)        DELETE_MODE=true ;;
    --yes)           DELETE_MODE=true; ASSUME_YES=true ;;
    --reset-local)   RESET_LOCAL=true ;;
    --skip-tf-check) SKIP_TF_CHECK=true ;;
    --tf-dir)        TF_DIR="${2:?--tf-dir 뒤에 경로가 필요합니다}"; shift ;;
    --profile)       PROFILE="${2:?--profile 뒤에 프로필 이름이 필요합니다}"; shift ;;
    --region)        REGION="${2:?--region 뒤에 리전이 필요합니다}"; shift ;;
    -h|--help)       usage; exit 0 ;;
    -*)              echo "알 수 없는 옵션: $1" >&2; usage; exit 2 ;;
    *)               if [ -z "$CLUSTER_NAME" ]; then CLUSTER_NAME="$1"; else echo "인자가 너무 많습니다: $1" >&2; exit 2; fi ;;
  esac
  shift
done

if [ -z "$CLUSTER_NAME" ]; then
  echo "사용법: bash eks_lab_reset.sh <cluster_name> [--delete] [--reset-local] ..." >&2
  echo "자세한 도움말: bash eks_lab_reset.sh --help" >&2
  exit 2
fi

# aws 호출 공통 래퍼. 왜 래퍼인가: 프로필·리전·페이저 옵션을 매번 반복하지 않고,
# 출력은 전부 --query + text로 받아 jq 의존을 없애기 위해서입니다.
AWS_GLOBAL=(--region "$REGION" --output text --no-cli-pager)
[ -n "$PROFILE" ] && AWS_GLOBAL+=(--profile "$PROFILE")
awsx() { aws "${AWS_GLOBAL[@]}" "$@"; }

# --output text는 값이 없을 때 "None"을 찍습니다. 빈 문자열로 정규화해야
# for 루프가 "None"이라는 유령 ID를 돌지 않습니다.
norm() { sed '/^None$/d' | sed 's/[[:space:]]*$//' | sed '/^$/d'; }

say()  { printf '%s\n' "$*"; }
head1() { printf '\n=== %s\n' "$*"; }

#########################################################################################################
## 선행 안내: terraform destroy가 되는 상태면 그쪽이 우선
#########################################################################################################
if [ "$SKIP_TF_CHECK" = false ]; then
  say "────────────────────────────────────────────────────────────────────"
  say " 먼저 확인하십시오: terraform destroy가 아직 동작하는 상태라면"
  say " 그 방법이 우선입니다 (state가 아는 리소스를 순서까지 알아서 지움):"
  say "   terraform destroy -var-file=student.tfvars"
  say ""
  say " 이 스크립트는 destroy가 실패하거나 state가 실제와 어긋난 상황"
  say " (AlreadyExists, state 유실 등)에서 쓰는 도구입니다."
  say " destroy를 이미 시도했고 실패했다면 그대로 진행하면 됩니다."
  say " (이 안내를 생략하려면 --skip-tf-check)"
  say "────────────────────────────────────────────────────────────────────"
fi

say ""
say "대상 클러스터 : $CLUSTER_NAME"
say "리전          : $REGION"
say "프로필        : ${PROFILE:-"(기본 자격 증명)"}"
if [ "$ASSUME_YES" = true ]; then
  say "모드          : 실제 삭제 — 확인 생략 (--yes, 강사·자동화 전용)"
elif [ "$DELETE_MODE" = true ]; then
  say "모드          : 실제 삭제 (--delete) — 목록 확인 후 클러스터 이름 재입력이 필요합니다"
else
  say "모드          : dry-run — 목록만 출력하고 아무것도 지우지 않습니다"
fi

# 자격 증명이 죽어 있으면 이후 모든 조회가 헛돕니다. 여기서 한 번에 걸러 냅니다.
# 계정 ID와 함께 "누구로 로그인했는지"(ARN)도 받아 둡니다 — 삭제 확인 문구에 넣어,
# 다른 계정·다른 프로필에 이 스크립트를 그대로 베껴 쓴 경우 스스로 알아차리게 합니다.
CALLER_LINE="$(awsx sts get-caller-identity --query '[Account, Arn]' 2>/dev/null | norm | head -1)"
ACCOUNT_ID=""; CALLER_ARN=""
read -r ACCOUNT_ID CALLER_ARN <<EOF
$CALLER_LINE
EOF
if [ -z "$ACCOUNT_ID" ]; then
  say ""
  say "[오류] AWS 자격 증명을 확인할 수 없습니다. 로그인(aws sso login 등) 후 다시 실행하십시오." >&2
  exit 1
fi
say "계정          : $ACCOUNT_ID"
say "로그인 주체   : $CALLER_ARN"

#########################################################################################################
## 1단계: 발견 (조회만 — 이 구간은 dry-run이든 아니든 아무것도 바꾸지 않습니다)
##
## 왜 전부 먼저 찾고 나서 지우는가:
##   노드그룹 IAM 역할과 런치 템플릿은 이름에 클러스터명이 없어서, 노드그룹이 살아 있을 때
##   API로 물어봐야 정확한 ID를 얻습니다. 지우기 시작한 뒤에는 그 근거가 사라지므로
##   발견을 삭제보다 앞에 전부 몰아 둡니다.
#########################################################################################################
FOUND_ROWS=""   # "유형|ID|발견 근거" 줄 모음 (dry-run 표 출력용)
FOUND_COUNT=0
add_found() { # $1=유형 $2=ID $3=근거
  FOUND_ROWS="${FOUND_ROWS}${1}|${2}|${3}
"
  FOUND_COUNT=$((FOUND_COUNT + 1))
}

say ""
say "리소스를 조회합니다 (조회만 — 변경 없음)..."

## (1) EKS 클러스터·노드그룹·Pod Identity ---------------------------------------------------------------
EKS_EXISTS=false
NODEGROUPS=""
NODE_ROLE_ARNS=""   # 노드그룹이 참조하는 IAM 역할 — 살아 있을 때 잡아 두는 정본 근거
LT_IDS=""           # 노드그룹이 참조하는 런치 템플릿
POD_ASSOC_IDS=""
CLUSTER_STATUS="$(awsx eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.status' 2>/dev/null | norm)"
if [ -n "$CLUSTER_STATUS" ]; then
  # 같은 이름의 클러스터는 계정·리전당 하나뿐이지만, 그 하나가 이 실습 tf로 만든 것인지까지
  # 확인합니다(실습 공통 태그). 다른 방식으로 만든 동명 클러스터를 지우는 사고 방지.
  CLUSTER_TAG="$(awsx eks describe-cluster --name "$CLUSTER_NAME" --query 'cluster.tags.project' 2>/dev/null | norm)"
  if [ "$CLUSTER_TAG" != "cloudwave-eks" ]; then
    say "[경고] 클러스터 '$CLUSTER_NAME'이 있지만 실습 태그(project=cloudwave-eks)가 없습니다."
    say "       이 실습 tf가 만든 클러스터가 아닐 수 있어 대상에서 제외합니다. 정말 실습 산물이라면"
    say "       콘솔에서 태그를 확인한 뒤 수동으로 삭제하십시오."
    CLUSTER_STATUS=""
  fi
fi
if [ -n "$CLUSTER_STATUS" ]; then
  EKS_EXISTS=true
  add_found "EKS 클러스터" "$CLUSTER_NAME ($CLUSTER_STATUS)" "이름 일치+태그 project=cloudwave-eks (EKS API)"
  NODEGROUPS="$(awsx eks list-nodegroups --cluster-name "$CLUSTER_NAME" --query 'nodegroups[]' 2>/dev/null | tr '\t' '\n' | norm)"
  for ng in $NODEGROUPS; do
    add_found "EKS 노드그룹" "$CLUSTER_NAME/$ng" "클러스터 $CLUSTER_NAME 소속 (EKS API)"
    role_arn="$(awsx eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --query 'nodegroup.nodeRole' 2>/dev/null | norm)"
    [ -n "$role_arn" ] && NODE_ROLE_ARNS="$NODE_ROLE_ARNS $role_arn"
    lt_id="$(awsx eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" --query 'nodegroup.launchTemplate.id' 2>/dev/null | norm)"
    [ -n "$lt_id" ] && LT_IDS="$LT_IDS $lt_id"
  done
  POD_ASSOC_IDS="$(awsx eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" --query 'associations[].associationId' 2>/dev/null | tr '\t' '\n' | norm)"
  for pid in $POD_ASSOC_IDS; do
    add_found "Pod Identity 연관" "$pid" "클러스터 $CLUSTER_NAME 소속 (EKS API)"
  done
fi

## (2) 로드밸런서·타깃그룹 (AWS Load Balancer Controller 산물) -----------------------------------------
# LBC는 자기가 만든 모든 ELBv2 리소스에 elbv2.k8s.aws/cluster=<클러스터명> 태그를 붙입니다.
# 이 태그가 있는 것만 대상 — 같은 계정의 다른 로드밸런서는 태그가 없으므로 목록에 안 들어옵니다.
LB_ARNS=""
for arn in $(awsx elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' 2>/dev/null | tr '\t' '\n' | norm); do
  hit="$(awsx elbv2 describe-tags --resource-arns "$arn" \
        --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER_NAME'] | length(@)" 2>/dev/null | norm)"
  if [ "$hit" = "1" ]; then
    LB_ARNS="$LB_ARNS $arn"
    add_found "로드밸런서(ELBv2)" "${arn##*loadbalancer/}" "태그 elbv2.k8s.aws/cluster=$CLUSTER_NAME"
  fi
done
TG_ARNS=""
for arn in $(awsx elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' 2>/dev/null | tr '\t' '\n' | norm); do
  hit="$(awsx elbv2 describe-tags --resource-arns "$arn" \
        --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER_NAME'] | length(@)" 2>/dev/null | norm)"
  if [ "$hit" = "1" ]; then
    TG_ARNS="$TG_ARNS $arn"
    add_found "타깃그룹" "${arn##*targetgroup/}" "태그 elbv2.k8s.aws/cluster=$CLUSTER_NAME"
  fi
done

## (3) 전용 VPC와 내부 리소스 --------------------------------------------------------------------------
# 실습 tf는 Name=<cluster_name>-vpc 태그로 VPC를 만들고 default_tags(project=cloudwave-eks)도
# 함께 붙입니다. 두 태그를 동시에 요구해 "우연히 같은 Name을 쓴 남의 VPC"를 배제합니다.
# 이 VPC는 실습 전용(공유 없음)이라 경계 안의 서브넷·SG·ENI·인스턴스는 전부 이 실습 산물입니다.
# 재-apply가 반쯤 성공해 같은 이름의 VPC가 2개 생긴 경우도 있으므로 복수 매칭을 그대로 다 처리합니다.
VPC_IDS="$(awsx ec2 describe-vpcs \
          --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" "Name=tag:project,Values=cloudwave-eks" \
          --query 'Vpcs[].VpcId' 2>/dev/null | tr '\t' '\n' | norm)"
SUBNET_IDS=""; IGW_IDS=""; RTB_IDS=""; SG_IDS=""; VPC_SG_SET=""
for vpc in $VPC_IDS; do
  add_found "VPC" "$vpc" "태그 Name=${CLUSTER_NAME}-vpc + project=cloudwave-eks"
  for s in $(awsx ec2 describe-subnets --filters "Name=vpc-id,Values=$vpc" --query 'Subnets[].SubnetId' 2>/dev/null | tr '\t' '\n' | norm); do
    SUBNET_IDS="$SUBNET_IDS $s"; add_found "서브넷" "$s" "VPC $vpc 내부"
  done
  for g in $(awsx ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$vpc" --query 'InternetGateways[].InternetGatewayId' 2>/dev/null | tr '\t' '\n' | norm); do
    IGW_IDS="$IGW_IDS $g:$vpc"; add_found "인터넷 게이트웨이" "$g" "VPC $vpc 연결"
  done
  # 메인 라우트테이블은 VPC와 함께 삭제되므로 명시 삭제 대상은 비-메인만.
  for r in $(awsx ec2 describe-route-tables --filters "Name=vpc-id,Values=$vpc" \
             --query 'RouteTables[?length(Associations[?Main==`true`])==`0`].RouteTableId' 2>/dev/null | tr '\t' '\n' | norm); do
    RTB_IDS="$RTB_IDS $r"; add_found "라우트테이블" "$r" "VPC $vpc 내부 (비-메인)"
  done
  # default SG는 지울 수 없고 VPC와 함께 사라지므로 제외합니다.
  for sg in $(awsx ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" \
              --query "SecurityGroups[?GroupName!='default'].GroupId" 2>/dev/null | tr '\t' '\n' | norm); do
    SG_IDS="$SG_IDS $sg"; add_found "보안그룹" "$sg" "VPC $vpc 내부 (default 제외)"
  done
  # default 포함 전체 SG 목록 — 런치 템플릿 소속 판정((6)단계)에서 "이 VPC의 SG인가"를 대조할 때 씁니다.
  VPC_SG_SET="$VPC_SG_SET $(awsx ec2 describe-security-groups --filters "Name=vpc-id,Values=$vpc" --query 'SecurityGroups[].GroupId' 2>/dev/null | tr '\t' '\n' | norm | tr '\n' ' ')"
done

## (4) EC2 인스턴스 (VPC 내부 + 클러스터 태그, 합집합) --------------------------------------------------
# 노드그룹 삭제가 인스턴스를 회수하지만, 노드그룹 자체가 반쯤 지워진 상태라면 인스턴스만
# 남아 있을 수 있습니다. VPC 경계와 EKS 태그 두 갈래로 찾아 합칩니다.
INSTANCE_IDS=""
# 종료(terminated) 상태는 AWS가 알아서 지우는 중이므로 제외 — 그 외 모든 상태가 대상입니다.
LIVE_STATES="Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped"
_add_instances() { # 인자: describe-instances에 넘길 --filters 값들. _INST_REASON을 근거로 기록.
  local ids i
  ids="$(awsx ec2 describe-instances --filters "$@" "$LIVE_STATES" \
        --query 'Reservations[].Instances[].InstanceId' 2>/dev/null | tr '\t' '\n' | norm)"
  for i in $ids; do
    case " $INSTANCE_IDS " in *" $i "*) ;; *) INSTANCE_IDS="$INSTANCE_IDS $i"; add_found "EC2 인스턴스" "$i" "$_INST_REASON" ;; esac
  done
}
for vpc in $VPC_IDS; do
  _INST_REASON="VPC $vpc 내부"
  _add_instances "Name=vpc-id,Values=$vpc"
done
# 태그 값을 owned|shared로 한정하는 이유: 키 존재만 보면 같은 키를 임의 값으로 붙인
# 무관한 인스턴스까지 걸립니다. EKS·CSI가 붙이는 값은 owned(전용)와 shared(공유) 둘뿐입니다.
_INST_REASON="태그 kubernetes.io/cluster/$CLUSTER_NAME=owned|shared"
_add_instances "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned,shared"
_INST_REASON="태그 eks:cluster-name=$CLUSTER_NAME"
_add_instances "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME"

## (4b) Auto Scaling 그룹 -------------------------------------------------------------------------------
# EKS 관리형 노드그룹의 실체는 ASG입니다. 노드그룹 레코드만 지워지고 ASG가 남는 부분 실패가
# 나면, 인스턴스를 종료해도 ASG가 즉시 새 노드를 만들어 "지워도 되살아나는" 상태가 됩니다.
# EKS는 ASG에 eks:cluster-name 태그를 붙이므로 그걸로 잡습니다.
ASG_NAMES=""
for asg in $(awsx autoscaling describe-auto-scaling-groups \
            --filters "Name=tag:eks:cluster-name,Values=$CLUSTER_NAME" \
            --query 'AutoScalingGroups[].AutoScalingGroupName' 2>/dev/null | tr '\t' '\n' | norm); do
  ASG_NAMES="$ASG_NAMES $asg"
  add_found "Auto Scaling 그룹" "$asg" "태그 eks:cluster-name=$CLUSTER_NAME"
done
for asg in $(awsx autoscaling describe-auto-scaling-groups \
            --filters "Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned" \
            --query 'AutoScalingGroups[].AutoScalingGroupName' 2>/dev/null | tr '\t' '\n' | norm); do
  case " $ASG_NAMES " in *" $asg "*) ;; *) ASG_NAMES="$ASG_NAMES $asg"; add_found "Auto Scaling 그룹" "$asg" "태그 kubernetes.io/cluster/$CLUSTER_NAME=owned" ;; esac
done

## (5) IAM 역할·OIDC 공급자 ----------------------------------------------------------------------------
# 실습 tf의 실제 네이밍(모듈 v21.24.0 실배포로 확인):
#   <cluster>-ebs-csi                     : tf가 name을 직접 지정
#   <cluster>-cluster-<26자리 난수>        : EKS 모듈이 name_prefix "<cluster>-cluster-"로 생성
#   default-eks-node-group-<26자리 난수>   : 노드그룹 역할. "default"는 노드그룹 키라서
#                                           클러스터명이 이름에 없음 — 아래 별도 처리
IAM_ROLES=""
_role_exists() { awsx iam get-role --role-name "$1" --query 'Role.RoleName' 2>/dev/null | norm; }
# 이름이 맞아도 실습 태그가 없으면 남의 역할일 수 있으므로 태그까지 요구합니다.
_role_has_lab_tag() {
  [ "$(awsx iam list-role-tags --role-name "$1" \
      --query "Tags[?Key=='project' && Value=='cloudwave-eks'] | length(@)" 2>/dev/null | norm)" = "1" ]
}
r="$(_role_exists "${CLUSTER_NAME}-ebs-csi")"
if [ -n "$r" ] && _role_has_lab_tag "$r"; then
  IAM_ROLES="$IAM_ROLES $r"; add_found "IAM 역할" "$r" "이름 정확 일치+태그 project=cloudwave-eks (tf: aws_iam_role.ebs_csi)"
fi
for r in $(awsx iam list-roles --query "Roles[?starts_with(RoleName, '${CLUSTER_NAME}-cluster-')].RoleName" 2>/dev/null | tr '\t' '\n' | norm); do
  _role_has_lab_tag "$r" || continue
  IAM_ROLES="$IAM_ROLES $r"; add_found "IAM 역할" "$r" "이름 접두어 ${CLUSTER_NAME}-cluster- +태그 project=cloudwave-eks"
done

# 노드그룹 역할: 노드그룹이 살아 있었다면 위 (1)에서 nodeRole ARN을 정확히 확보했습니다.
for arn in $NODE_ROLE_ARNS; do
  r="${arn##*/}"
  case " $IAM_ROLES " in *" $r "*) ;; *) IAM_ROLES="$IAM_ROLES $r"; add_found "IAM 역할" "$r" "노드그룹 nodeRole 참조 (EKS API)" ;; esac
done
# 노드그룹은 이미 사라졌는데 역할만 남은 경우(부분 destroy): 이름 접두어만으로는
# 다른 실습 클러스터의 역할과 구분이 안 되므로 3중 확인을 겁니다 —
#   ① 이름이 default-eks-node-group-* (이 tf의 노드그룹 키 "default" 유래)
#   ② 실습 공통 태그 project=cloudwave-eks (tf default_tags가 붙임)
#   ③ 이 리전의 어떤 살아 있는 노드그룹도 이 역할을 쓰고 있지 않음
# 셋 다 통과해야 대상입니다. 하나라도 어긋나면 건드리지 않습니다.
if [ -z "$NODE_ROLE_ARNS" ]; then
  ROLES_IN_USE=""
  for c in $(awsx eks list-clusters --query 'clusters[]' 2>/dev/null | tr '\t' '\n' | norm); do
    for ng in $(awsx eks list-nodegroups --cluster-name "$c" --query 'nodegroups[]' 2>/dev/null | tr '\t' '\n' | norm); do
      ROLES_IN_USE="$ROLES_IN_USE $(awsx eks describe-nodegroup --cluster-name "$c" --nodegroup-name "$ng" --query 'nodegroup.nodeRole' 2>/dev/null | norm)"
    done
  done
  for r in $(awsx iam list-roles --query "Roles[?starts_with(RoleName, 'default-eks-node-group-')].RoleName" 2>/dev/null | tr '\t' '\n' | norm); do
    _role_has_lab_tag "$r" || continue
    case " $ROLES_IN_USE " in *"/$r "*|*"/$r") continue ;; esac
    IAM_ROLES="$IAM_ROLES $r"
    # 남은 한계: 공용 계정에서 "다른 클러스터명으로 돌린 같은 실습"이 남긴 고아 역할과는
    # 구분할 수 없습니다(이름·태그가 완전히 동일). 살아 있는 클러스터의 역할은 ③이 보호하고,
    # 걸리는 것은 어차피 리셋 대상인 실습 고아뿐이므로 삭제 대상에 포함합니다.
    add_found "IAM 역할" "$r" "이름 접두어+태그 project=cloudwave-eks+현행 노드그룹 미사용 (3중 확인, 공용 계정이면 다른 실습의 고아일 수 있음)"
  done
fi

# OIDC 공급자: EKS 모듈이 Name=<cluster>-eks-irsa 태그를 붙여 만듭니다.
# Name과 실습 공통 태그(project)를 동시에 요구해 남이 같은 Name을 붙인 경우를 배제합니다.
OIDC_ARNS=""
for arn in $(awsx iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' 2>/dev/null | tr '\t' '\n' | norm); do
  hit="$(awsx iam list-open-id-connect-provider-tags --open-id-connect-provider-arn "$arn" \
        --query "length(Tags[?Key=='Name' && Value=='${CLUSTER_NAME}-eks-irsa']) == \`1\` && length(Tags[?Key=='project' && Value=='cloudwave-eks']) == \`1\`" 2>/dev/null | norm)"
  if [ "$hit" = "True" ] || [ "$hit" = "true" ]; then
    OIDC_ARNS="$OIDC_ARNS $arn"
    add_found "IAM OIDC 공급자" "${arn##*/}" "태그 Name=${CLUSTER_NAME}-eks-irsa + project=cloudwave-eks"
  fi
done

## (6) 런치 템플릿 (노드그룹 참조가 없을 때의 잔존물 탐색) -----------------------------------------------
# 모듈 런치 템플릿 이름도 노드그룹 키 유래(default-<난수>)라 클러스터명이 없습니다.
# 노드그룹에서 못 잡았다면: 실습 태그가 있고, 템플릿이 참조하는 보안그룹이 위 (3)의
# 전용 VPC 소속일 때만 대상입니다. VPC까지 이미 사라진 경우는 근거가 약하므로
# 자동 삭제하지 않고 아래에서 수동 확인 안내만 합니다.
for lt in $LT_IDS; do add_found "런치 템플릿" "$lt" "노드그룹 참조 (EKS API)"; done
if [ -n "${VPC_SG_SET// /}" ]; then
  for lt in $(awsx ec2 describe-launch-templates \
              --filters "Name=tag:project,Values=cloudwave-eks" "Name=tag:managed_by,Values=terraform" \
              --query 'LaunchTemplates[].LaunchTemplateId' 2>/dev/null | tr '\t' '\n' | norm); do
    case " $LT_IDS " in *" $lt "*) continue ;; esac   # 노드그룹 경로로 이미 잡은 것은 중복 제외
    lt_sgs="$(awsx ec2 describe-launch-template-versions --launch-template-id "$lt" --versions '$Latest' \
             --query 'LaunchTemplateVersions[0].LaunchTemplateData.[SecurityGroupIds, NetworkInterfaces[].Groups[]][]' 2>/dev/null | tr '\t' '\n' | norm)"
    for sg in $lt_sgs; do
      case " $VPC_SG_SET " in *" $sg "*)
        LT_IDS="$LT_IDS $lt"
        add_found "런치 템플릿" "$lt" "실습 태그+참조 보안그룹이 전용 VPC 소속"
        break ;;
      esac
    done
  done
elif [ -z "${LT_IDS// /}" ]; then
  # VPC까지 이미 사라져 소속을 확정할 수 없으면 자동 삭제하지 않고 알려만 줍니다(안전 보증 (8)).
  LT_LEFT="$(awsx ec2 describe-launch-templates \
            --filters "Name=tag:project,Values=cloudwave-eks" "Name=tag:managed_by,Values=terraform" \
            --query 'LaunchTemplates[].LaunchTemplateId' 2>/dev/null | tr '\t' '\n' | norm)"
  if [ -n "$LT_LEFT" ]; then
    say "[참고] 실습 태그(project=cloudwave-eks)가 붙은 런치 템플릿이 있으나, 전용 VPC가 이미 없어"
    say "       '$CLUSTER_NAME' 소속인지 확정할 수 없으므로 자동 삭제 대상에서 제외합니다:"
    for lt in $LT_LEFT; do say "         $lt  (콘솔에서 확인 후 필요하면 직접 삭제)"; done
  fi
fi

## (7) CloudWatch 로그 그룹 ----------------------------------------------------------------------------
# EKS 모듈이 control plane 로그용으로 만드는 그룹. 클러스터를 지워도 남는 대표 잔존물이라
# 재-apply 때 "log group already exists"의 주범입니다.
LOG_GROUP="/aws/eks/${CLUSTER_NAME}/cluster"
LG_EXISTS="$(awsx logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
            --query "logGroups[?logGroupName=='$LOG_GROUP'] | length(@)" 2>/dev/null | norm)"
if [ "$LG_EXISTS" = "1" ]; then
  add_found "CloudWatch 로그 그룹" "$LOG_GROUP" "이름 정확 일치 (EKS 모듈 생성 경로)"
else
  LOG_GROUP=""
fi

## (8) 고아 EBS 볼륨·스냅샷 -----------------------------------------------------------------------------
# PVC로 만든 EBS는 EBS CSI 드라이버가 kubernetes.io/cluster/<이름>=owned 태그를 붙입니다.
# 클러스터를 지워도 PV의 reclaim 처리가 안 끝났으면 볼륨이 남습니다.
# status=available(어디에도 안 붙음)만 대상 — 붙어 있는 볼륨은 인스턴스 종료가 풀어 줍니다.
VOL_TAG_FILTER="Name=tag:kubernetes.io/cluster/$CLUSTER_NAME,Values=owned,shared"
VOLUME_IDS="$(awsx ec2 describe-volumes \
             --filters "$VOL_TAG_FILTER" "Name=status,Values=available" \
             --query 'Volumes[].VolumeId' 2>/dev/null | tr '\t' '\n' | norm)"
for v in $VOLUME_IDS; do
  add_found "EBS 볼륨(고아)" "$v" "태그 kubernetes.io/cluster/$CLUSTER_NAME=owned|shared + 미사용(available)"
done
# 스냅샷 실습(VolumeSnapshot)을 했다면 볼륨과 별개로 스냅샷이 남아 과금됩니다.
# 같은 클러스터 태그가 붙은 것만 대상(태그가 없으면 아무것도 안 잡힘 — 안전 보증 유지).
SNAPSHOT_IDS="$(awsx ec2 describe-snapshots --owner-ids self \
               --filters "$VOL_TAG_FILTER" \
               --query 'Snapshots[].SnapshotId' 2>/dev/null | tr '\t' '\n' | norm)"
for s in $SNAPSHOT_IDS; do
  add_found "EBS 스냅샷" "$s" "태그 kubernetes.io/cluster/$CLUSTER_NAME=owned|shared (본인 소유)"
done

#########################################################################################################
## 발견 결과 출력
#########################################################################################################
head1 "발견된 리소스: ${FOUND_COUNT}개"
if [ "$FOUND_COUNT" -gt 0 ]; then
  printf '%-22s %-52s %s\n' "유형" "ID/이름" "발견 근거"
  printf '%-22s %-52s %s\n' "----" "-------" "---------"
  printf '%s' "$FOUND_ROWS" | while IFS='|' read -r t i b; do
    [ -n "$t" ] && printf '%-22s %-52s %s\n' "$t" "$i" "$b"
  done
else
  say "이 계정·리전에서 '$CLUSTER_NAME' 실습의 흔적을 찾지 못했습니다. AWS 쪽은 이미 깨끗합니다."
fi

if [ "$DELETE_MODE" = false ]; then
  say ""
  if [ "$FOUND_COUNT" -gt 0 ]; then
    say "dry-run이므로 아무것도 지우지 않았습니다. 실제 삭제:"
    say "  bash $0 $CLUSTER_NAME --delete"
  fi
  if [ "$RESET_LOCAL" = true ]; then
    say "--reset-local도 --delete와 함께 실행해야 적용됩니다 (지금은 계획만 표시):"
    say "  대상 디렉토리: $TF_DIR"
    for f in terraform.tfstate terraform.tfstate.backup .terraform.lock.hcl; do
      [ -e "$TF_DIR/$f" ] && say "  백업 후 제거 예정: $TF_DIR/$f"
    done
    [ -d "$TF_DIR/.terraform" ] && say "  제거 예정(재생성 가능): $TF_DIR/.terraform/"
  fi
  exit 0
fi

#########################################################################################################
## 삭제 확인 게이트
## 위에 방금 출력된 전체 목록·개수가 곧 "지워질 것 전부"입니다. 여기서 계정·주체까지 다시 보여 주고,
## 클러스터 이름을 그대로 재입력해야만 진행합니다. 왜 y/N이 아니라 이름 재타이핑인가:
## 반사적으로 y·엔터를 누르는 실수를 막고, 지우려는 대상이 무엇인지 한 번 더 눈으로
## 확인시키기 위해서입니다(GitHub 저장소 삭제와 같은 패턴). --yes는 이 확인을 건너뜁니다
## (비대화형 자동화 전용 — 학생 안내 문서에는 노출하지 않습니다).
#########################################################################################################
if [ "$FOUND_COUNT" -eq 0 ] && [ "$RESET_LOCAL" = false ]; then
  say ""
  say "지울 AWS 리소스가 없어 그대로 종료합니다. (로컬 상태 정리가 필요하면 --reset-local을 함께 쓰십시오.)"
  exit 0
fi
say ""
say "────────────────────────────────────────────────────────────────────"
say " 지금 계정 $ACCOUNT_ID"
say "   (로그인 주체: $CALLER_ARN)"
say " 의 '$CLUSTER_NAME' 리소스 ${FOUND_COUNT}개(위 목록 전부)를 삭제합니다."
[ "$RESET_LOCAL" = true ] && say " 로컬 terraform 상태($TF_DIR)도 함께 초기화합니다."
say " 계정이나 목록이 예상과 다르면 지금 중단하십시오(Ctrl+C)."
say "────────────────────────────────────────────────────────────────────"
if [ "$ASSUME_YES" = false ]; then
  if [ ! -t 0 ]; then
    say "[중단] 비대화형 입력에서는 이름 재입력 확인을 받을 수 없습니다. 아무것도 지우지 않았습니다."
    say "       (자동화 파이프라인이라면 --yes를 쓰되, 이는 강사·자동화 전용입니다.)"
    exit 1
  fi
  printf '정말 삭제하려면 클러스터 이름(%s)을 그대로 입력하십시오: ' "$CLUSTER_NAME"
  read -r CONFIRM_INPUT
  if [ "$CONFIRM_INPUT" != "$CLUSTER_NAME" ]; then
    say "[중단] 입력('$CONFIRM_INPUT')이 클러스터 이름과 일치하지 않습니다. 아무것도 지우지 않았습니다."
    exit 1
  fi
fi

#########################################################################################################
## 2단계: 삭제 (확인 게이트를 통과했을 때만 도달)
##
## 순서가 곧 성공률입니다. AWS는 참조되는 리소스를 못 지우게 하므로,
## "만드는 쪽(컨트롤러)부터 멈추고, 쓰는 쪽에서 쓰이는 쪽으로" 지웁니다.
##   노드그룹 → 클러스터 → 로드밸런서·타깃그룹(재조회) → ASG 잔존 → 런치템플릿
##   → 잔존 인스턴스 → ENI 대기·정리 → 보안그룹 → 서브넷·라우트·IGW → VPC
##   → IAM → 로그 그룹 → EBS 볼륨·스냅샷
## 로드밸런서를 클러스터보다 뒤에 지우는 이유: 클러스터가 살아 있으면 그 안의
## Load Balancer Controller가 "내 ALB가 사라졌다"고 판단해 즉시 다시 만듭니다.
## 컨트롤러(클러스터)를 먼저 없애고, 로드밸런서는 그 뒤에 다시 조회해서 지워야
## 재생성 경주가 없습니다. (LBC가 만든 LB는 클러스터를 지워도 자동으로 사라지지 않습니다.)
## 모든 단계는 "이미 없으면 건너뜀"이라 중간에 끊겨도 재실행하면 이어서 진행됩니다.
#########################################################################################################

# 폴링 공통 루틴: AWS 삭제는 대부분 비동기라 "요청 접수"와 "실제 소멸" 사이가 깁니다.
# 다음 단계는 실제 소멸을 전제하므로 상한을 두고 기다립니다.
wait_until() { # $1=설명 $2=최대시도 $3=간격(초) $4...=성공(빈 출력) 판정 명령
  local desc="$1" max="$2" interval="$3"; shift 3
  local n=0 out
  while [ "$n" -lt "$max" ]; do
    out="$("$@" 2>/dev/null | norm)"
    [ -z "$out" ] && return 0
    n=$((n + 1))
    say "  ... $desc 대기 중 ($n/$max, ${interval}초 간격, 남은 대상: $(printf '%s' "$out" | wc -w | tr -d ' ')건)"
    sleep "$interval"
  done
  return 1
}

## [1/13] EKS 노드그룹 ----------------------------------------------------------------------------------
head1 "[1/13] EKS 노드그룹 삭제"
if [ "$EKS_EXISTS" = true ] && [ -n "$NODEGROUPS" ]; then
  for ng in $NODEGROUPS; do
    say "  삭제 요청: $ng"
    awsx eks delete-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" >/dev/null 2>&1 || say "  (이미 삭제 중이거나 없음)"
  done
  for ng in $NODEGROUPS; do
    say "  노드그룹 '$ng' 소멸 대기 (수 분 걸립니다)..."
    # aws CLI 내장 waiter: 30초 간격 40회(최대 20분). 노드그룹 삭제는 인스턴스 회수를 포함해 깁니다.
    awsx eks wait nodegroup-deleted --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" 2>/dev/null \
      || { say "  [중단] 노드그룹이 20분 내에 사라지지 않았습니다. EKS 콘솔에서 상태(헬스 이슈)를 확인하고 다시 실행하십시오."; exit 1; }
  done
else
  say "  없음 — 건너뜀"
fi

## [2/13] Pod Identity 연관 → EKS 클러스터 ---------------------------------------------------------------
# Pod Identity 연관·액세스 엔트리·애드온은 클러스터의 하위 리소스라 클러스터 삭제로 같이
# 사라집니다. 그래도 연관을 먼저 지우는 이유: 클러스터 삭제가 어떤 이유로든 막혔을 때
# 남는 참조를 줄여 두면 재시도가 단순해집니다.
head1 "[2/13] Pod Identity 연관·EKS 클러스터 삭제"
if [ "$EKS_EXISTS" = true ]; then
  for pid in $POD_ASSOC_IDS; do
    say "  Pod Identity 연관 삭제: $pid"
    awsx eks delete-pod-identity-association --cluster-name "$CLUSTER_NAME" --association-id "$pid" >/dev/null 2>&1 || say "  (이미 없음)"
  done
  say "  클러스터 삭제 요청: $CLUSTER_NAME"
  awsx eks delete-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || say "  (이미 삭제 중이거나 없음)"
  say "  클러스터 소멸 대기 (수 분 걸립니다)..."
  awsx eks wait cluster-deleted --name "$CLUSTER_NAME" 2>/dev/null \
    || { say "  [중단] 클러스터가 제한 시간 내에 사라지지 않았습니다. EKS 콘솔 확인 후 다시 실행하십시오."; exit 1; }
else
  say "  없음 — 건너뜀"
fi

## [3/13] 로드밸런서 (클러스터 삭제 후 재조회) -------------------------------------------------------------
# 발견 시점 이후 LBC가 새로 만들었을 수 있으므로 태그 기준으로 다시 조회해 합칩니다.
# 이제 클러스터(=LBC)가 없으니 재생성 경주도 없습니다.
head1 "[3/13] 로드밸런서 삭제"
for arn in $(awsx elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerArn' 2>/dev/null | tr '\t' '\n' | norm); do
  case " $LB_ARNS " in *" $arn "*) continue ;; esac
  hit="$(awsx elbv2 describe-tags --resource-arns "$arn" \
        --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER_NAME'] | length(@)" 2>/dev/null | norm)"
  [ "$hit" = "1" ] && { LB_ARNS="$LB_ARNS $arn"; say "  (재조회에서 추가 발견: ${arn##*loadbalancer/})"; }
done
if [ -n "${LB_ARNS// /}" ]; then
  for arn in $LB_ARNS; do
    # 삭제 보호가 켜져 있으면 delete가 거부됩니다. Ingress 어노테이션으로 켜졌을 수 있어 먼저 끕니다.
    awsx elbv2 modify-load-balancer-attributes --load-balancer-arn "$arn" \
      --attributes Key=deletion_protection.enabled,Value=false >/dev/null 2>&1
    say "  삭제 요청: ${arn##*loadbalancer/}"
    awsx elbv2 delete-load-balancer --load-balancer-arn "$arn" >/dev/null 2>&1 || say "  (이미 없음 — 건너뜀)"
  done
  _lbs_left() {
    local a out=""
    for a in $LB_ARNS; do
      out="$out $(awsx elbv2 describe-load-balancers --load-balancer-arns "$a" --query 'LoadBalancers[].LoadBalancerArn' 2>/dev/null | norm)"
    done
    printf '%s\n' "$out" | tr ' ' '\n' | norm
  }
  wait_until "로드밸런서 소멸" 24 10 _lbs_left \
    || { say "  [중단] 로드밸런서가 4분 내에 사라지지 않았습니다. 잠시 후 이 스크립트를 다시 실행하십시오."; exit 1; }
else
  say "  없음 — 건너뜀"
fi

## [4/13] 타깃그룹 (재조회 포함) --------------------------------------------------------------------------
head1 "[4/13] 타깃그룹 삭제"
for arn in $(awsx elbv2 describe-target-groups --query 'TargetGroups[].TargetGroupArn' 2>/dev/null | tr '\t' '\n' | norm); do
  case " $TG_ARNS " in *" $arn "*) continue ;; esac
  hit="$(awsx elbv2 describe-tags --resource-arns "$arn" \
        --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster' && Value=='$CLUSTER_NAME'] | length(@)" 2>/dev/null | norm)"
  [ "$hit" = "1" ] && { TG_ARNS="$TG_ARNS $arn"; say "  (재조회에서 추가 발견: ${arn##*targetgroup/})"; }
done
if [ -n "${TG_ARNS// /}" ]; then
  for arn in $TG_ARNS; do
    say "  삭제: ${arn##*targetgroup/}"
    awsx elbv2 delete-target-group --target-group-arn "$arn" >/dev/null 2>&1 || say "  (이미 없음 — 건너뜀)"
  done
else
  say "  없음 — 건너뜀"
fi

## [5/13] Auto Scaling 그룹 잔존물 ------------------------------------------------------------------------
# 정상 경로면 노드그룹 삭제가 자기 ASG를 같이 지웠습니다. 이 단계는 "노드그룹 레코드는
# 사라졌는데 ASG만 남은" 부분 실패용 — ASG를 그대로 두면 인스턴스를 지워도 계속 되살립니다.
# --force-delete가 소속 인스턴스 종료까지 포함합니다. 런치 템플릿을 참조하는 것도 ASG이므로
# 반드시 런치 템플릿(다음 단계)보다 먼저 지웁니다.
head1 "[5/13] Auto Scaling 그룹 삭제"
if [ -n "${ASG_NAMES// /}" ]; then
  for asg in $ASG_NAMES; do
    say "  삭제 요청(강제): $asg"
    awsx autoscaling delete-auto-scaling-group --auto-scaling-group-name "$asg" --force-delete >/dev/null 2>&1 || say "  (이미 없음 — 건너뜀)"
  done
  _asgs_left() {
    local a out=""
    for a in $ASG_NAMES; do
      out="$out $(awsx autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$a" --query 'AutoScalingGroups[].AutoScalingGroupName' 2>/dev/null | norm)"
    done
    printf '%s\n' "$out" | tr ' ' '\n' | norm
  }
  wait_until "ASG 소멸" 30 10 _asgs_left \
    || { say "  [중단] ASG가 5분 내에 사라지지 않았습니다. 잠시 후 이 스크립트를 다시 실행하십시오."; exit 1; }
else
  say "  없음 — 건너뜀"
fi

## [6/13] 런치 템플릿 -----------------------------------------------------------------------------------
# EKS가 자체 생성한 템플릿(eks-*)은 노드그룹과 함께 사라지지만, 모듈이 만든 템플릿은 남습니다.
head1 "[6/13] 런치 템플릿 삭제"
if [ -n "${LT_IDS// /}" ]; then
  for lt in $LT_IDS; do
    say "  삭제: $lt"
    awsx ec2 delete-launch-template --launch-template-id "$lt" >/dev/null 2>&1 || say "  (이미 없음 — 건너뜀)"
  done
else
  say "  없음 — 건너뜀"
fi

## [7/13] 잔존 EC2 인스턴스 ------------------------------------------------------------------------------
# 정상 경로면 노드그룹 삭제가 다 회수했겠지만, 노드그룹 없이 남은 인스턴스(부분 파괴)를 위한 단계.
head1 "[7/13] 잔존 EC2 인스턴스 종료"
LIVE_INSTANCES=""
for i in $INSTANCE_IDS; do
  st="$(awsx ec2 describe-instances --instance-ids "$i" --query 'Reservations[].Instances[].State.Name' 2>/dev/null | norm)"
  case "$st" in ""|terminated) ;; *) LIVE_INSTANCES="$LIVE_INSTANCES $i" ;; esac
done
if [ -n "${LIVE_INSTANCES// /}" ]; then
  say "  종료 요청:$LIVE_INSTANCES"
  # shellcheck disable=SC2086 # 공백 구분 ID 목록을 개별 인자로 넘기려는 의도
  awsx ec2 terminate-instances --instance-ids $LIVE_INSTANCES >/dev/null 2>&1
  # shellcheck disable=SC2086
  awsx ec2 wait instance-terminated --instance-ids $LIVE_INSTANCES 2>/dev/null \
    || { say "  [중단] 인스턴스가 제한 시간 내에 종료되지 않았습니다. 잠시 후 다시 실행하십시오."; exit 1; }
else
  say "  없음 — 건너뜀"
fi

## [8/13] ENI 정리 --------------------------------------------------------------------------------------
# 로드밸런서·노드·EKS가 쓰던 네트워크 인터페이스는 소유 서비스가 지운 뒤에도 몇 분간
# VPC에 남아 보안그룹·서브넷 삭제를 막습니다. in-use가 다 풀릴 때까지 기다렸다가
# available 상태로 남은 것(고아)만 직접 지웁니다. (in-use ENI를 강제로 떼지 않는 이유:
# AWS 서비스 소유 ENI는 detach가 거부되며, 소유 서비스가 회수하는 것이 정상 경로입니다.)
head1 "[8/13] ENI 정리 (VPC 내부)"
if [ -n "$VPC_IDS" ]; then
  for vpc in $VPC_IDS; do
    _enis_in_use() { awsx ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" "Name=status,Values=in-use" --query 'NetworkInterfaces[].NetworkInterfaceId' 2>/dev/null | tr '\t' '\n' | norm; }
    if ! wait_until "사용 중 ENI 해제" 30 10 _enis_in_use; then
      say "  [중단] 5분이 지나도 사용 중인 ENI가 남아 있습니다. 아직 회수 중인 서비스가 있다는 뜻이므로"
      say "         설명(어느 서비스 소유인지)을 확인하고 몇 분 뒤 다시 실행하십시오:"
      awsx ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" "Name=status,Values=in-use" \
        --query 'NetworkInterfaces[].[NetworkInterfaceId, Description]' 2>/dev/null | sed 's/^/         /'
      exit 1
    fi
    for eni in $(awsx ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$vpc" "Name=status,Values=available" --query 'NetworkInterfaces[].NetworkInterfaceId' 2>/dev/null | tr '\t' '\n' | norm); do
      say "  고아 ENI 삭제: $eni"
      awsx ec2 delete-network-interface --network-interface-id "$eni" >/dev/null 2>&1 || say "  (이미 없음 — 건너뜀)"
    done
  done
else
  say "  대상 VPC 없음 — 건너뜀"
fi

## [9/13] 보안그룹 --------------------------------------------------------------------------------------
# 보안그룹끼리 서로 참조(노드 SG ↔ 클러스터 SG)하면 어느 쪽을 먼저 지워도 거부됩니다.
# 그래서 먼저 모든 규칙을 비워 상호 참조를 끊고, 그다음 그룹을 지웁니다.
head1 "[9/13] 보안그룹 삭제"
if [ -n "${SG_IDS// /}" ]; then
  for sg in $SG_IDS; do
    in_rules="$(awsx ec2 describe-security-group-rules --filters "Name=group-id,Values=$sg" \
               --query "SecurityGroupRules[?IsEgress==\`false\`].SecurityGroupRuleId" 2>/dev/null | tr '\t' '\n' | norm)"
    # shellcheck disable=SC2086
    [ -n "$in_rules" ] && awsx ec2 revoke-security-group-ingress --group-id "$sg" --security-group-rule-ids $in_rules >/dev/null 2>&1
    out_rules="$(awsx ec2 describe-security-group-rules --filters "Name=group-id,Values=$sg" \
                --query "SecurityGroupRules[?IsEgress==\`true\`].SecurityGroupRuleId" 2>/dev/null | tr '\t' '\n' | norm)"
    # shellcheck disable=SC2086
    [ -n "$out_rules" ] && awsx ec2 revoke-security-group-egress --group-id "$sg" --security-group-rule-ids $out_rules >/dev/null 2>&1
  done
  for sg in $SG_IDS; do
    say "  삭제: $sg"
    awsx ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1 || say "  (이미 없거나 아직 참조 중 — 아래 VPC 단계 실패 시 재실행)"
  done
else
  say "  없음 — 건너뜀"
fi

## [10/13] 서브넷·라우트테이블·IGW ------------------------------------------------------------------------
head1 "[10/13] 서브넷·라우트테이블·인터넷 게이트웨이 삭제"
for s in $SUBNET_IDS; do
  say "  서브넷 삭제: $s"
  awsx ec2 delete-subnet --subnet-id "$s" >/dev/null 2>&1 || say "  (이미 없음 — 건너뜀)"
done
for r in $RTB_IDS; do
  # 서브넷 연결이 남아 있으면 라우트테이블 삭제가 거부되므로 연결부터 해제합니다.
  for assoc in $(awsx ec2 describe-route-tables --route-table-ids "$r" --query 'RouteTables[0].Associations[?Main!=`true`].RouteTableAssociationId' 2>/dev/null | tr '\t' '\n' | norm); do
    awsx ec2 disassociate-route-table --association-id "$assoc" >/dev/null 2>&1
  done
  say "  라우트테이블 삭제: $r"
  awsx ec2 delete-route-table --route-table-id "$r" >/dev/null 2>&1 || say "  (이미 없음 — 건너뜀)"
done
for gv in $IGW_IDS; do
  g="${gv%%:*}"; vpc="${gv##*:}"
  say "  IGW 분리·삭제: $g"
  awsx ec2 detach-internet-gateway --internet-gateway-id "$g" --vpc-id "$vpc" >/dev/null 2>&1
  awsx ec2 delete-internet-gateway --internet-gateway-id "$g" >/dev/null 2>&1 || say "  (이미 없음 — 건너뜀)"
done
[ -z "${SUBNET_IDS// /}${RTB_IDS// /}${IGW_IDS// /}" ] && say "  없음 — 건너뜀"

## [11/13] VPC ------------------------------------------------------------------------------------------
head1 "[11/13] VPC 삭제"
if [ -n "$VPC_IDS" ]; then
  for vpc in $VPC_IDS; do
    ok=false
    for attempt in 1 2 3 4 5; do
      if awsx ec2 delete-vpc --vpc-id "$vpc" >/dev/null 2>&1; then ok=true; break; fi
      # 남은 종속물이 아직 회수 중일 수 있어 짧게 재시도합니다.
      st="$(awsx ec2 describe-vpcs --vpc-ids "$vpc" --query 'Vpcs[].VpcId' 2>/dev/null | norm)"
      [ -z "$st" ] && { ok=true; break; }   # 이미 사라졌으면 성공으로 간주
      say "  VPC $vpc 삭제 재시도 ($attempt/5, 15초 대기)..."
      sleep 15
    done
    if [ "$ok" = true ]; then
      say "  삭제 완료: $vpc"
    else
      say "  [중단] VPC $vpc 를 지우지 못했습니다. 남은 종속물을 확인하십시오:"
      say "         aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=$vpc"
      say "         확인 후 이 스크립트를 다시 실행하면 이어서 진행합니다."
      exit 1
    fi
  done
else
  say "  없음 — 건너뜀"
fi

## [12/13] IAM 역할·OIDC 공급자·CloudWatch 로그 그룹 ------------------------------------------------------
# IAM 역할은 attach된 관리형 정책·인라인 정책·인스턴스 프로파일을 모두 떼어야 삭제됩니다.
# 하나라도 남으면 DeleteConflict — 학생이 콘솔에서 헤매는 대표 지점이라 순서대로 다 처리합니다.
head1 "[12/13] IAM·로그 그룹 삭제"
for role in $IAM_ROLES; do
  [ -z "$(_role_exists "$role")" ] && { say "  IAM 역할 $role 이미 없음 — 건너뜀"; continue; }
  for p in $(awsx iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' 2>/dev/null | tr '\t' '\n' | norm); do
    awsx iam detach-role-policy --role-name "$role" --policy-arn "$p" >/dev/null 2>&1
  done
  for p in $(awsx iam list-role-policies --role-name "$role" --query 'PolicyNames[]' 2>/dev/null | tr '\t' '\n' | norm); do
    awsx iam delete-role-policy --role-name "$role" --policy-name "$p" >/dev/null 2>&1
  done
  for ip in $(awsx iam list-instance-profiles-for-role --role-name "$role" --query 'InstanceProfiles[].InstanceProfileName' 2>/dev/null | tr '\t' '\n' | norm); do
    awsx iam remove-role-from-instance-profile --instance-profile-name "$ip" --role-name "$role" >/dev/null 2>&1
    # EKS가 노드그룹용으로 만든 프로파일(eks-*)이 고아로 남으면 같이 지웁니다.
    # 그 외 이름의 프로파일은 이 실습 산물이라는 근거가 없으므로 두고 갑니다.
    case "$ip" in eks-*) awsx iam delete-instance-profile --instance-profile-name "$ip" >/dev/null 2>&1 ;; esac
  done
  say "  IAM 역할 삭제: $role"
  awsx iam delete-role --role-name "$role" >/dev/null 2>&1 || say "  (삭제 실패 — 콘솔에서 남은 연결을 확인하십시오)"
done
for arn in $OIDC_ARNS; do
  say "  OIDC 공급자 삭제: ${arn##*/}"
  awsx iam delete-open-id-connect-provider --open-id-connect-provider-arn "$arn" >/dev/null 2>&1 || say "  (이미 없음 — 건너뜀)"
done
if [ -n "$LOG_GROUP" ]; then
  say "  로그 그룹 삭제: $LOG_GROUP"
  awsx logs delete-log-group --log-group-name "$LOG_GROUP" >/dev/null 2>&1 || say "  (이미 없음 — 건너뜀)"
fi
[ -z "${IAM_ROLES// /}${OIDC_ARNS// /}$LOG_GROUP" ] && say "  없음 — 건너뜀"

## [13/13] 고아 EBS 볼륨·스냅샷 --------------------------------------------------------------------------
# 처음 발견 때 인스턴스에 붙어 있던 볼륨이 인스턴스 종료로 풀렸을 수 있으므로 여기서 다시 조회합니다.
head1 "[13/13] 고아 EBS 볼륨·스냅샷 삭제"
VOLUME_IDS_NOW="$(awsx ec2 describe-volumes \
                 --filters "$VOL_TAG_FILTER" "Name=status,Values=available" \
                 --query 'Volumes[].VolumeId' 2>/dev/null | tr '\t' '\n' | norm)"
if [ -n "$VOLUME_IDS_NOW" ]; then
  for v in $VOLUME_IDS_NOW; do
    say "  볼륨 삭제: $v"
    awsx ec2 delete-volume --volume-id "$v" >/dev/null 2>&1 || say "  (이미 없음 — 건너뜀)"
  done
else
  say "  볼륨 없음 — 건너뜀"
fi
for s in $SNAPSHOT_IDS; do
  say "  스냅샷 삭제: $s"
  awsx ec2 delete-snapshot --snapshot-id "$s" >/dev/null 2>&1 || say "  (이미 없음 — 건너뜀)"
done
# 클러스터 태그가 있는데 아직 붙어 있는(in-use) 볼륨이 남았다면 알려만 줍니다.
STUCK_VOLS="$(awsx ec2 describe-volumes --filters "$VOL_TAG_FILTER" --query 'Volumes[].VolumeId' 2>/dev/null | tr '\t' '\n' | norm)"
if [ -n "$STUCK_VOLS" ]; then
  say "  [주의] 클러스터 태그가 있는 볼륨이 아직 사용 중입니다. 몇 분 뒤 스크립트를 다시 실행하면 정리됩니다:"
  for v in $STUCK_VOLS; do say "         $v"; done
fi

#########################################################################################################
## 로컬 terraform 상태 초기화 (--reset-local)
#########################################################################################################
if [ "$RESET_LOCAL" = true ]; then
  head1 "로컬 terraform 상태 초기화: $TF_DIR"
  ls "$TF_DIR"/*.tf >/dev/null 2>&1 || say "  [주의] $TF_DIR 에 .tf 파일이 없습니다. --tf-dir 경로가 맞는지 확인하십시오."
  BACKUP_DIR="$TF_DIR/tfstate-backup-$(date +%Y%m%d-%H%M%S)"
  moved=false
  for f in terraform.tfstate terraform.tfstate.backup .terraform.lock.hcl; do
    if [ -e "$TF_DIR/$f" ]; then
      mkdir -p "$BACKUP_DIR"
      mv "$TF_DIR/$f" "$BACKUP_DIR/"
      say "  백업 후 제거: $f → ${BACKUP_DIR##*/}/"
      moved=true
    fi
  done
  # .terraform/은 provider 바이너리·모듈 캐시라 terraform init이 언제든 다시 만듭니다. 백업 불필요.
  if [ -d "$TF_DIR/.terraform" ]; then
    rm -rf "$TF_DIR/.terraform"
    say "  제거: .terraform/ (terraform init이 재생성)"
    moved=true
  fi
  [ "$moved" = false ] && say "  정리할 로컬 상태 파일이 없습니다 — 이미 깨끗합니다."
fi

head1 "완료"
say "리셋이 끝났습니다. 같은 리소스를 다시 확인하려면 dry-run으로 재실행하십시오:"
say "  bash $0 $CLUSTER_NAME"
say "0건이 나오면 terraform init && terraform apply 로 깨끗하게 재시작할 수 있습니다."
