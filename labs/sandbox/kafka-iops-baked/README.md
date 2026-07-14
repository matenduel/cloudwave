# kafka-iops-baked — 자기조사 샌드박스 (얼린 실측 스냅샷)

Kafka consumer lag/IOPS 사건의 **실측 관측 데이터**를 얼려서 담은 baked 샌드박스입니다.
라이브 재현 킷(`../kafka-iops/`)을 실제로 돌려 캡처한 Prometheus 지표 + Loki 로그를 재생합니다.
합성이 아니라 진짜 실행에서 나온 값이며, 매번 동일하게 재현됩니다.

## 실행 (한 줄)

```bash
docker compose up
```

- Grafana `http://localhost:3000` (익명) → Explore에서 PromQL/LogQL 직접 조회. 정지: `docker compose down -v`

## 데이터 창

- **사건 시각: 2026-07-14 10:00~10:08 KST**(폴트는 ~10:02:30부터, ~10:05:30 회복). Grafana 범위를 **2026-07-14 09:59 ~ 10:09** 로 맞추세요.
- 지표(Prometheus)는 `up` 직후 조회. **로그(Loki)는 주입 후 약 1~2분** 뒤 조회됩니다(store flush).

## 들어있는 신호 (출발점 — 무엇을 조합할지는 스스로)

- **표면(가장 먼저 눈에 띄는 값)**: `kafka_consumergroup_lag` — consumer lag이 폴트 구간에 선형으로 급증(1 → 6,000+)했다가 회복 시 drain. "consumer가 못 따라간다/트래픽이 몰렸나?" 처럼 보임.
- **함정 — 표면은 조용함**: `kafka_consumergroup_members`(=1 불변), `producer_records_total` rate(=60/s 불변, 유입은 그대로), `up`(전부 1), consumer 에러/리밸런스 로그(0건). 즉 "뻔한 지표"로는 이상 원인이 안 잡힘.
- **진짜 원인(파고들어야 보임 — 앱 IOPS 카운터)**:
  - `consumer_sink_write_ops_total` — 레코드당 sink write 횟수 급증(rate 60/s → ~194/s).
  - `consumer_sink_write_bytes_total` — sink write 바이트 급증(~60 KiB/s → ~1.5 MiB/s).
  - `consumer_processing_delay_seconds` — 레코드 처리에 얹힌 추가 지연(0 → 0.04s).
  - `consumer_records_processed_total` — 처리율이 60/s → ~24/s로 떨어짐(그래서 lag이 쌓임).
- **로그**: `{container="consumer"}`, `{container="producer"}` (`| json` 으로 필드 조회).

## 이 문제의 반전

consumer lag은 뻔히 급증하지만, 표면 지표(member 수·유입률·에러·`up`)는 전 구간 정상이라 **고정된 관측 지표만 보면 "이상 없음"으로 오판**하기 쉽습니다. lag이 쌓이는 진짜 이유(consumer의 **sink write I/O가 레코드당 8배로 증폭**되어 처리율이 떨어진 것)는 `consumer_sink_write_ops_total`/`_bytes_total` 앱 카운터를 **따로 조회해야만** 드러납니다. "무엇을 조회해야 하는지" 자체가 이 문제의 핵심입니다.

> ⚠️ 물리 디스크 IOPS(cAdvisor 등)는 macOS Docker Desktop에서 신뢰할 수 없습니다. 여기서 "IOPS"는 앱이 노출하는 sink write ops/bytes 카운터로 봅니다.

## 원본

라이브 재현 킷: `../kafka-iops/` (이 스냅샷은 그 킷을 로컬에서 실제로 돌려 캡처한 것).
