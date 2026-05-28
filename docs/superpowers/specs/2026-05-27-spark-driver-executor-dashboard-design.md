# Spark Driver / Executor 성능 대시보드 설계

**날짜**: 2026-05-27  
**상태**: 제안됨  
**범위**: Grafana 대시보드, Tempo trace drilldown, Prometheus/Tempo span metric 연계, Spark Job 특화 Driver/Executor 관측

---

## 1. 개요

Spark Job 장애와 성능 저하를 분석할 때 운영자가 가장 자주 묻는 질문은 아래 3가지다.

1. 전체 Job 지연의 원인이 Driver인지, 특정 Executor 군인지
2. 병목이 CPU/GC/Shuffle/Spill/Data Skew 중 어디에 있는지
3. 이상 징후가 관측된 시점의 대표 Trace/Span을 즉시 열어볼 수 있는지

본 설계는 Spark Job을 일반 인프라 대시보드가 아니라, **Trace 계층의 Driver / Executor span 아래 성능 메트릭을 집중적으로 보는 운영 대시보드**로 설계한다.

---

## 2. 설계 목표

- Job 단위와 Trace 단위를 한 화면에서 연결한다.
- Driver와 Executor를 같은 시간축에서 비교한다.
- 장기 추세는 Prometheus 기반으로, 단기 심층 분석은 Tempo Trace/TraceQL 기반으로 본다.
- 운영자가 “느리다”에서 끝나지 않고 “어느 Executor, 어느 Stage, 어떤 Span 속성”까지 3클릭 이내로 내려가게 한다.

비목표:

- Spark UI 전체를 Grafana로 1:1 복제
- 모든 Spark metric을 무차별 노출
- Job 제어/kill/retry 기능 포함

---

## 3. 데이터소스 전략

### 3-1. 기본 원칙

대시보드는 두 계층을 같이 사용한다.

1. **Prometheus 계층**  
   장기 보관, 비교, 집계, Alerting용

2. **Tempo 계층**  
   Trace drilldown, span 기반 원인 파악용

### 3-2. 선택 이유

- Grafana Tempo는 tracing data로부터 metrics-generator를 통해 Prometheus 호환 저장소로 metric을 써 넣을 수 있고, span metrics와 service graph를 만들 수 있다. 또한 TraceQL metrics로 span 기반 시계열을 즉석 계산할 수 있지만, 장기 범위 대시보드보다는 탐색성 쿼리에 더 적합하다. citeturn1view1turn2view0turn1view3
- Trace to metrics correlation은 Tempo trace에서 Prometheus 계열 metric으로 이동하는 링크를 제공하며, span attribute를 metrics label로 매핑할 수 있다. citeturn1view2
- Grafana의 exemplar 기능은 Prometheus metric에서 대표 trace로 바로 점프하게 해 주며, Prometheus data source에서 지원된다. citeturn2view2turn1view1

### 3-3. 권장 구성

#### 필수

- **Tempo**
  - Job / Driver / Executor trace 저장
  - Trace panel, trace drilldown

- **Prometheus 또는 Mimir**
  - Spark built-in Prometheus metrics 저장
  - Tempo metrics-generator로 생성한 span metrics 저장

#### 권장

- **Spark built-in Prometheus endpoint**
  - Spark 3.0+ 기준 built-in Prometheus plugin 사용
  - master / worker / driver endpoint scrape

- **Tempo metrics-generator**
  - `span metrics` 활성화
  - 필요 시 `service graphs` 활성화

### 3-4. 운영 정책

- **장기 KPI/비교 대시보드**: PromQL만 사용
- **최근 3시간 내 원인분석**: TraceQL metrics + Trace panel 허용
- **최종 근거 확인**: exemplar 또는 trace panel로 대표 trace 열기

---

## 4. 계측 계약

이 대시보드는 데이터가 있어야 의미가 있으므로, Spark span/metric에 아래 라벨 계약을 강제한다.

### 4-1. 공통 리소스 속성

- `cluster`
- `namespace`
- `spark_cluster`
- `spark_app_name`
- `spark_app_id`
- `spark_job_name`
- `spark_job_id`
- `deployment_env`

### 4-2. Driver span 필수 속성

- `span.role = "driver"`
- `spark.stage.id`
- `spark.stage.attempt_id`
- `spark.sql.execution_id` (SQL 기반이면)
- `spark.input.bytes`
- `spark.output.bytes`
- `spark.shuffle.read.bytes`
- `spark.shuffle.write.bytes`
- `spark.memory.spill.bytes`
- `spark.disk.spill.bytes`
- `spark.gc.time.ms`

### 4-3. Executor span 필수 속성

- `span.role = "executor"`
- `spark.executor.id`
- `spark.executor.host`
- `spark.stage.id`
- `spark.task.id`
- `spark.task.attempt`
- `spark.executor.cpu.time.ms`
- `spark.executor.run.time.ms`
- `spark.executor.deserialize.time.ms`
- `spark.result.serialize.time.ms`
- `spark.jvm.gc.time.ms`
- `spark.input.records`
- `spark.output.records`
- `spark.shuffle.read.bytes`
- `spark.shuffle.write.bytes`
- `spark.memory.spill.bytes`
- `spark.disk.spill.bytes`

### 4-4. 메트릭 라벨 정규화

Trace to metrics 상관관계와 Grafana variable 사용성을 위해 dotted attribute는 snake_case label로 매핑한다.

예:

- `resource.service.name -> service_name`
- `spark.app.id -> spark_app_id`
- `spark.executor.id -> spark_executor_id`
- `k8s.pod -> pod`

이 방식은 Grafana trace-to-metrics 설정에서 tag key와 target label을 별도로 매핑하는 공식 패턴과 맞는다. citeturn1view2

---

## 5. 대시보드 정보구조

대시보드는 단일 페이지 + collapsible section 구조를 권장한다.

### Row A. Global Filters

Variables:

- `datasource_metrics`
- `datasource_traces`
- `cluster`
- `spark_cluster`
- `spark_app_name`
- `spark_app_id`
- `spark_job_name`
- `spark_job_id`
- `stage_id`
- `executor_id`
- `trace_id`

기본 동작:

- `spark_app_name` 선택 시 `spark_app_id` 자동 필터
- `spark_job_id` 선택 시 관련 stage / executor만 남김
- `executor_id`는 multi-select 허용

### Row B. Job Cockpit

운영자가 제일 먼저 보는 요약 영역.

패널:

1. **Job Duration**
2. **Job Success / Failed Task Ratio**
3. **Active Executors**
4. **Driver GC Time**
5. **Shuffle Read / Write Throughput**
6. **Spill Bytes**
7. **Skew Index**
8. **Representative Slow Trace Count**

### Row C. Driver Lane

Driver 중심 병목 분석.

패널:

1. Driver span duration trend
2. Driver CPU / GC / Heap pressure
3. Stage scheduling latency
4. Driver-side shuffle planning delay
5. Driver warning/error count
6. Driver trace panel

### Row D. Executor Fleet

Executor 분산과 편차를 보는 핵심 영역.

패널:

1. Executor runtime heatmap
2. Executor task throughput by executor
3. Top N slow executors
4. Top N high-GC executors
5. Executor shuffle read skew
6. Executor spill skew
7. Executor failure / retry count
8. Selected executor trace panel

### Row E. Stage & Shuffle

Stage 단위 성능과 데이터 skew 진단.

패널:

1. Stage duration table
2. Stage input/output bytes
3. Stage shuffle read/write
4. Stage max-min executor runtime delta
5. Stage skew score
6. Stage representative traces

### Row F. Failures & Drilldown

원인 확정 영역.

패널:

1. Error span list
2. Retries / failed tasks
3. Exemplars-enabled latency graph
4. Trace detail panel
5. Logs deep link

---

## 6. 패널 상세 설계

### 6-1. Job Cockpit

#### Panel: Job Duration

- 타입: `Stat`
- 데이터소스: Prometheus
- 의미: 선택된 app/job의 end-to-end duration

예시 전략:

- Spark exporter metric이 있으면 직접 사용
- 없으면 Driver root span duration metric 사용

#### Panel: Representative Slow Trace Count

- 타입: `Time series`
- 데이터소스: Tempo TraceQL metrics
- 용도: 최근 단기 구간에서 느린 driver/executor span 수를 계수

예시:

```traceql
{ resource.service.name = "spark-driver" && spark.job.id = "$spark_job_id" } | quantile_over_time(span:duration, .95)
```

TraceQL metrics는 span selector 뒤에 `quantile_over_time`, `count_over_time`, `rate`, `histogram_over_time` 등을 붙여 시계열 집계를 만들 수 있다. citeturn1view3

### 6-2. Driver Lane

#### Panel: Driver Span Duration Trend

- 타입: `Time series`
- 데이터소스: Prometheus
- 주 쿼리: `driver root span p50/p95/p99`
- exemplar: `ON`

권장 metric 예시:

- `traces_spanmetrics_duration_seconds`
- label: `service_name="spark-driver"`

#### Panel: Driver Trace Panel

- 타입: `Trace panel`
- 데이터소스: Tempo
- 기본 쿼리:

```traceql
{ resource.service.name = "spark-driver" && spark.app.id = "$spark_app_id" && spark.job.id = "$spark_job_id" }
```

주의:

- Tempo search와 TraceQL search는 비결정적일 수 있으므로, 최근 trace를 우선 보려면 `most_recent=true` 전략을 링크 쿼리 쪽에 적용하는 것이 좋다. citeturn1view4

### 6-3. Executor Fleet

#### Panel: Executor Runtime Heatmap

- 타입: `Heatmap`
- 데이터소스: Prometheus
- 목적: Executor별 runtime 분포와 롱테일 확인

권장 지표:

- executor runtime histogram
- 또는 span duration histogram from Tempo metrics-generator

#### Panel: Top N Slow Executors

- 타입: `Bar gauge`
- 데이터소스: Prometheus

예시 쿼리 패턴:

```promql
topk(10, avg by (spark_executor_id) (executor_run_time_ms{spark_app_id="$spark_app_id", spark_job_id="$spark_job_id"}))
```

#### Panel: Executor Shuffle Read Skew

- 타입: `Table`
- 계산식:
  - `executor shuffle read bytes / median(executor shuffle read bytes)`
- 임계값:
  - `> 2.0`: warning
  - `> 4.0`: critical

#### Panel: Selected Executor Trace Panel

- 타입: `Trace panel`
- 데이터소스: Tempo

예시 쿼리:

```traceql
{ resource.service.name = "spark-executor" && spark.app.id = "$spark_app_id" && spark.executor.id = "$executor_id" }
```

### 6-4. Stage & Shuffle

#### Panel: Stage Duration Table

- 타입: `Table`
- 컬럼:
  - stage id
  - attempt
  - total duration
  - max executor duration
  - min executor duration
  - skew score
  - shuffle read
  - shuffle spill
  - error count

#### Panel: Stage Skew Score

권장 계산:

```text
skew_score = p95(executor_stage_runtime) / p50(executor_stage_runtime)
```

또는

```text
skew_score = max(executor_stage_runtime) / median(executor_stage_runtime)
```

이 값이 높을수록 특정 executor에 데이터가 몰렸을 가능성이 높다.

### 6-5. Failures & Drilldown

#### Panel: Error Span List

- 타입: `Table`
- 데이터소스: Tempo

예시:

```traceql
{ span:status = error && spark.app.id = "$spark_app_id" }
```

#### Panel: Exemplars-enabled Latency Graph

- 타입: `Time series`
- 데이터소스: Prometheus
- exemplar: `ON`

Prometheus exemplar는 metric spike 시 대표 trace를 선택해 Tempo로 열 수 있으므로, “느린 순간의 대표 trace”를 가장 빨리 여는 패널로 쓴다. citeturn2view2turn1view1

---

## 7. 데이터소스별 역할 분담

### Prometheus / Mimir

담당:

- 장기 추세
- SLA / SLO
- 비교 시계열
- Alert rule 소스
- Heatmap / Histogram / TopK

소스:

- Spark built-in Prometheus metrics
- Tempo metrics-generator span metrics

Grafana는 Prometheus data source를 기본 내장으로 제공하며, Spark integration은 Spark 3.0+의 built-in prometheus plugin 기반 scrape 예시를 제공한다. citeturn3search3turn1view0

### Tempo

담당:

- trace 패널
- trace search
- short-range trace metric drilldown
- root cause 확인

소스:

- Spark driver / executor OTel traces

Grafana에서는 Tempo trace 결과를 패널로 저장할 수 있고, trace search와 trace drilldown을 대시보드에 포함할 수 있다. citeturn1view4

---

## 8. Trace to Metrics / Metrics to Trace 연결

### 8-1. Trace → Metrics

Tempo data source에서 trace-to-metrics 설정:

- Metrics data source: Prometheus
- Tag mappings:
  - `spark.app.id -> spark_app_id`
  - `spark.job.id -> spark_job_id`
  - `spark.executor.id -> spark_executor_id`
  - `resource.service.name -> service_name`

효과:

- Driver trace에서 “이 span에 대한 metric”으로 이동
- Executor trace에서 CPU, GC, Shuffle metric으로 이동

### 8-2. Metrics → Trace

Prometheus panel에서 exemplar 활성화:

- p95 latency
- shuffle spike
- GC spike
- spill spike

효과:

- 이상 시점의 대표 trace를 바로 열 수 있음

---

## 9. 권장 쿼리 템플릿

### 9-1. Driver RED from span metrics

```promql
sum(rate(traces_spanmetrics_calls_total{service_name="spark-driver", spark_app_id="$spark_app_id"}[$__rate_interval]))
```

```promql
histogram_quantile(0.95, sum by (le) (rate(traces_spanmetrics_latency_bucket{service_name="spark-driver", spark_app_id="$spark_app_id"}[$__rate_interval])))
```

### 9-2. Executor RED by executor id

```promql
sum by (spark_executor_id) (rate(traces_spanmetrics_calls_total{service_name="spark-executor", spark_app_id="$spark_app_id"}[$__rate_interval]))
```

```promql
histogram_quantile(0.95, sum by (spark_executor_id, le) (rate(traces_spanmetrics_latency_bucket{service_name="spark-executor", spark_app_id="$spark_app_id"}[$__rate_interval])))
```

### 9-3. TraceQL short-range executor latency

```traceql
{ resource.service.name = "spark-executor" && spark.app.id = "$spark_app_id" } | quantile_over_time(span:duration, .95) by (spark.executor.id)
```

### 9-4. Error span rate

```traceql
{ span:status = error && spark.app.id = "$spark_app_id" } | rate() by (resource.service.name)
```

---

## 10. UX 설계 원칙

### 원칙 1. 한 화면에서 “원인 방향”이 보여야 한다

대시보드를 열자마자 아래가 보여야 한다.

- Driver가 느린가
- Executor가 느린가
- 일부 Executor만 느린가
- Shuffle / Spill / GC 중 어디가 치솟는가

### 원칙 2. 평균보다 분포를 보여준다

Spark는 평균보다 편차가 중요하므로 다음 시각화를 우선한다.

- heatmap
- histogram
- topk / bottomk
- p50 / p95 / p99
- skew score

### 원칙 3. 표보다 드릴다운 링크가 중요하다

대시보드가 끝점이 아니라 시작점이어야 한다.

- panel click → trace view
- exemplar click → representative trace
- trace click → metrics for this span

### 원칙 4. Driver와 Executor를 색으로 분리한다

- Driver: amber/orange
- Executor: blue/teal
- Error: red
- Spill / GC warning: magenta or yellow

---

## 11. 운영상 리스크

### 리스크 1. label cardinality 폭증

`spark_task_id`, `executor_id`, `stage_id`, `job_id`를 모두 span metrics 차원으로 켜면 cardinality가 커질 수 있다.

대응:

- 장기 metric에는 `task_id` 제외
- 대시보드 기본은 `app_id`, `job_id`, `executor_id`, `stage_id`까지
- task-level은 TraceQL 또는 raw trace로만 제한

Tempo metrics-generator는 차원을 많이 켤수록 cardinality가 증가하므로, 운영 차원은 제한적으로 선택해야 한다. citeturn2view0

### 리스크 2. TraceQL metrics를 장기 대시보드에 남용

TraceQL metrics는 탐색에는 유용하지만 preview 성격이며, 기본 query range도 제한적이다.

대응:

- 장기 KPI는 Prometheus/Mimir 저장 metric만 사용
- TraceQL metrics panel은 “최근 3시간” 섹션에 한정

TraceQL metrics는 public preview로 안내되고, metrics-from-traces 문서는 기본 query range가 약 3시간이라고 설명한다. citeturn0search11turn1view1

### 리스크 3. 검색 결과 비결정성

Tempo trace search는 같은 조건에서도 결과가 달라질 수 있다.

대응:

- slow trace table은 “대표 예시”로 간주
- deterministic 최근 trace 링크에는 `most_recent=true` 전략 적용

Tempo 문서는 search와 TraceQL 결과가 비결정적일 수 있고, `most_recent=true`를 사용하면 최근 결과 기준으로 결정성을 높일 수 있다고 설명한다. citeturn1view4

---

## 12. 구현 순서

1. Spark / Tempo / Prometheus 라벨 계약 확정
2. Tempo metrics-generator span metrics 차원 정의
3. Prometheus scrape / remote_write 정비
4. Grafana datasource mapping
5. Trace to metrics tag mapping
6. Dashboard v1 구축
7. Exemplars 연결
8. 운영자 리뷰 후 v2 패널 정제

---

## 13. 대시보드 v1 최소 범위

v1에서는 아래만 먼저 구현한다.

- Row A: Filters
- Row B: Job Cockpit 6개 패널
- Row C: Driver Lane 4개 패널
- Row D: Executor Fleet 5개 패널
- Row F: Trace / Exemplars drilldown 3개 패널

즉, “원인 방향 판별 + 대표 trace 열기”까지만 먼저 완성한다.

---

## 14. 기대 효과

- Driver 병목 / Executor 병목을 1분 이내 식별
- Data skew / shuffle / spill / GC 원인을 Job 단위로 구분
- metric spike와 representative trace를 직접 연결
- Spark UI와 별도로 운영 관점의 장기 추세 / 이상징후 비교 가능
