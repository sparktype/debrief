# Spark Driver / Executor 대시보드 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use disciplined incremental delivery. Finish datasource contract before building panels.

**Goal:** Spark Job 전용으로 Driver/Executor span 아래 성능과 메트릭을 집중해서 볼 수 있는 Grafana 대시보드 v1을 설계 기준대로 구현한다.

**Reference:** `docs/superpowers/specs/2026-05-27-spark-driver-executor-dashboard-design.md`

---

## Task 1. 계측 계약 확정

**산출물**
- span attribute 명세
- Prometheus label 명세
- dotted attr → snake_case 매핑표

- [ ] Driver span 필수 속성 확정
- [ ] Executor span 필수 속성 확정
- [ ] app/job/stage/executor 식별자 필드 확정
- [ ] trace-to-metrics tag mapping 표 확정

**검증**
- 샘플 trace 3개에서 필수 속성이 모두 존재하는지 확인
- label cardinality 예상치 검토

---

## Task 2. Metrics 파이프라인 정비

**산출물**
- Spark built-in Prometheus scrape 설정
- Tempo metrics-generator / span metrics 설정
- Prometheus or Mimir 저장 확인

- [ ] Spark driver endpoint scrape 추가
- [ ] worker / executor 관련 endpoint scrape 정비
- [ ] Tempo span metrics 차원 설정
- [ ] exemplar가 보존되도록 Prometheus 계열 저장소 확인

**검증**
- Prometheus에서 Spark metric 조회 가능
- `traces_spanmetrics_*` 계열 조회 가능

---

## Task 3. Grafana Datasource 연동

**산출물**
- Tempo datasource
- Prometheus datasource
- trace to metrics correlation 설정

- [ ] Tempo datasource에서 trace-to-metrics 설정
- [ ] tag mapping 추가
- [ ] exemplar 표시 활성화 여부 확인
- [ ] 변수 친화적인 label 이름 재검토

**검증**
- trace 화면에서 `Metrics for this span` 링크 노출
- metric panel exemplar 클릭 시 Tempo trace 열림

---

## Task 4. Dashboard v1 구축

**산출물**
- Job Cockpit
- Driver Lane
- Executor Fleet
- Failures & Drilldown

- [ ] Global filter variables 생성
- [ ] Job KPI row 생성
- [ ] Driver 전용 row 생성
- [ ] Executor fleet row 생성
- [ ] Trace / exemplar drilldown row 생성

**검증**
- app/job 선택 시 panel 동기 필터
- executor multi-select 동작
- trace panel deep link 확인

---

## Task 5. Stage / Shuffle 심화 뷰 추가

**산출물**
- Stage duration table
- shuffle / spill / skew row

- [ ] stage-level table 구성
- [ ] skew score 계산식 적용
- [ ] shuffle read/write 및 spill 패널 추가
- [ ] top skew executor 링크 추가

**검증**
- skew가 큰 job에서 상위 executor가 분리 표시되는지 확인

---

## Task 6. 운영 적용

**산출물**
- 대시보드 UID
- 운영 가이드
- alert 후보 목록

- [ ] 운영자용 사용 가이드 작성
- [ ] v2 개선 후보 정리
- [ ] 알럿 후보 지표 정리

**검증**
- 운영자 리뷰 1회
- 실제 장애/느린 job 사례 1건 replay

---

## v1 완료 기준

- Driver vs Executor 병목 방향을 한 화면에서 판별 가능
- 느린 시점의 representative trace를 exemplar 또는 trace panel로 바로 열 수 있음
- stage / shuffle / spill / skew 중 무엇이 병목인지 최소 1개 이상 수치로 확인 가능
