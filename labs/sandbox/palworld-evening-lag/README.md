# 자기조사 샌드박스 — 팰월드 서버 (저녁 렉 제보)

얼린 **12시간 관측 스냅샷**을 학생이 직접 조회하며 가설을 세우고 판단하는 실습용 로컬 스택입니다.
데이터는 익명화된 실측 스냅샷이며(플레이어는 `Player A~D`, 라이브 서버에 연결하지 않습니다), 명령어 한 줄로 뜹니다.

## 실행

```bash
docker compose up
```

- 처음 실행 시 이미지를 내려받고, Prometheus에 지표를 백필하고, Loki에 로그를 주입합니다(자동, 수십 초).
- 뜨면 브라우저에서 **http://localhost:3000** (Grafana, 로그인 없이 열림) → 왼쪽 **Explore**.
  - **Prometheus** 데이터소스: PromQL로 지표 조회
  - **Loki** 데이터소스: LogQL로 로그 조회
- **데이터 창: 2026-07-13 11:00 ~ 23:00 (KST)** — Grafana 오른쪽 위 시간 범위를 이 구간으로 맞추세요(그 밖 구간은 비어 있습니다).

## 조회를 시작할 신호 (출발점일 뿐, 조합은 직접)

- 게임: `palworld_server_fps{instance="palworld-2"}`, `palworld_server_fps_average`, `palworld_current_players`, `palworld_player_online_ping`, `palworld_basecamp_num`, `palworld_days`
- 컨테이너 자원: `container_cpu_usage_seconds_total{name="palworld-2"}`(멀티코어라 `rate(...[5m])*100`이 100% 초과 정상), `container_memory_usage_bytes{name="palworld-2"}`, `container_network_receive_bytes_total` / `..._transmit_bytes_total`
- 호스트 자원: `node_memory_MemAvailable_bytes{instance="home-server-1"}`, 호스트 CPU 사용률 `100 - avg(rate(node_cpu_seconds_total{instance="home-server-1",mode="idle"}[5m]))*100`
- 로그: `{container="palworld-2"}` — 접속/퇴장, 서버 경고, 저장·백업 이벤트에 REST 폴링 노이즈가 섞여 있습니다

## 정지

```bash
docker compose down        # 컨테이너 정지
docker compose down -v      # 주입 데이터(볼륨)까지 삭제 후 초기화
```

## 구성

| 서비스 | 역할 |
| --- | --- |
| `prometheus-init` | `prometheus/metrics_openmetrics.txt`를 TSDB 블록으로 1회 백필 |
| `prometheus` | 백필된 스냅샷 조회(:9090) |
| `loki` | 로그 저장(:3100), 과거 타임스탬프 주입 허용 |
| `loki-loader` | `loki/logs.jsonl`을 Loki에 1회 주입 후 종료 |
| `grafana` | :3000, Prometheus·Loki 데이터소스 미리 연결, 익명 접근 |

데이터셋을 바꾸려면 `prometheus/metrics_openmetrics.txt`와 `loki/logs.jsonl`을 다른 케이스 것으로 교체하고 `docker compose down -v && docker compose up` 하면 됩니다.
