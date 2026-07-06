# Observability Labs

CLOUDWAVE 관측성(Observability) 파트 실습에서 쓰는 매니페스트·스크립트 모음입니다.

## 이 폴더는 뭔가요?

교재(GitHub Pages) 본문에서 `kubectl apply -f <raw URL>` 형태로 참조하는 파일들이 실제로 들어 있는 곳입니다. 예를 들어 교재에 있는 명령은 이렇게 생겼습니다:

```
kubectl apply -f https://raw.githubusercontent.com/matenduel/cloudwave/main/labs/manifests/namespaces.yaml
```

즉 교재 명령이 이 폴더의 파일을 인터넷에서 직접 받아 적용하는 구조입니다.

## 직접 수정해야 하나요?

아니요. 이 폴더의 파일을 **로컬로 내려받거나 편집할 필요가 없습니다.** 교재에 나오는 명령을 그대로 복사해서 터미널에 붙여넣으면, 명령 안의 raw URL이 이 폴더의 파일을 가져다 적용합니다. 파일 내용을 직접 열어볼 필요는 있지만(무엇을 적용하는지 궁금할 때), 수정하거나 별도로 관리할 필요는 없습니다.

## 폴더 구성

- `manifests/` — 네임스페이스, 데모 앱, 관측 스택(Prometheus/Grafana/Loki/Tempo/OTel), 결함 주입용 매니페스트
- `optional/settlement-batch/` — 20장 [고급] 선택 실습용 매니페스트 (이미지는 Docker Hub에서 pull, 별도 빌드 없음)
- `scripts/install-tools.*` — kind/kubectl/helm 등 실습에 필요한 CLI 도구 설치 스크립트 (Windows는 `.cmd`, macOS/Linux는 `.sh`)
- `VERSIONS.env` — 실습에서 고정하는 각 도구·이미지 버전

궁금한 점이나 실습 진행 방법은 교재 본문을 따라가세요.
