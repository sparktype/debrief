# Grafana Dashboard Assets

## 파일

- `spark-driver-executor-dashboard-v1.json`

## 사용법

1. Grafana에서 `Dashboards > New > Import`로 JSON 파일을 업로드합니다.
2. `datasource_metrics`에는 `Prometheus` 또는 `Mimir` datasource를 연결합니다.
3. `datasource_traces`에는 `Tempo` datasource를 연결합니다.
4. import 후 각 panel query의 metric 이름을 실제 환경 이름으로 맞춥니다.

## 전제 조건

- Spark metrics가 Prometheus 계열에 scrape 되어 있어야 합니다.
- Tempo에 Spark driver / executor trace가 들어와 있어야 합니다.
- 가능하면 Tempo metrics-generator span metrics와 Prometheus exemplars가 같이 연결돼 있어야 합니다.

## 주의

- 이 JSON은 초안입니다. metric 명세는 환경마다 다르므로 `spark_job_duration_seconds`, `spark_executor_runtime_ms`, `spark_stage_duration_seconds` 등은 실제 이름으로 조정해야 합니다.
- Tempo panel의 TraceQL 검색도 label 계약이 맞아야 동작합니다.
