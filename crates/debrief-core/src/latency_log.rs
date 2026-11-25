// 발화별 지연(대기·첫 문장 합성·첫 소리)을 JSONL로 남기고 요약하는 기록기
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::Path;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LatencyEntry {
    pub ts: u64,
    pub lane: String,
    pub chars: usize,
    pub queue_ms: u64,
    pub synth_first_ms: u64,
    pub first_sound_ms: u64,
}

pub struct LatencyLog;

impl LatencyLog {
    const TRIM_ABOVE: usize = 400;
    const KEEP: usize = 200;

    /// 한 줄 추가. 실패는 호출자가 무시한다(재생에 영향 없음).
    pub fn append(path: &Path, entry: &LatencyEntry) -> std::io::Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let line = serde_json::to_string(entry).map_err(std::io::Error::other)?;
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path)?;
        writeln!(file, "{line}")?;
        if let Ok(text) = std::fs::read_to_string(path) {
            if let Some(trimmed) = Self::trim(&text) {
                std::fs::write(path, trimmed)?;
            }
        }
        Ok(())
    }

    /// 줄 수가 TRIM_ABOVE를 넘으면 마지막 KEEP줄만 남긴 내용을 돌려준다.
    pub fn trim(text: &str) -> Option<String> {
        let lines: Vec<&str> = text.lines().collect();
        (lines.len() > Self::TRIM_ABOVE).then(|| lines[lines.len() - Self::KEEP..].join("\n") + "\n")
    }

    /// 최근 기록의 첫 소리 지연 p50/p95(ms)와 건수. 읽을 수 있는 줄이 없으면 None.
    pub fn summarize(text: &str) -> Option<(u64, u64, usize)> {
        let mut values: Vec<u64> =
            text.lines().filter_map(|line| serde_json::from_str::<LatencyEntry>(line).ok()).map(|e| e.first_sound_ms).collect();
        if values.is_empty() {
            return None;
        }
        values.sort_unstable();
        // 가장 가까운 순위(nearest-rank) 백분위.
        let percentile = |p: usize| values[(p * values.len()).div_ceil(100).max(1) - 1];
        Some((percentile(50), percentile(95), values.len()))
    }

    /// `debrief status`의 한 줄 값. 기록이 없으면 "기록 없음".
    pub fn status_value(path: &Path) -> String {
        match std::fs::read_to_string(path).ok().and_then(|text| Self::summarize(&text)) {
            Some((p50, p95, count)) => {
                format!("p50 {:.1}초 · p95 {:.1}초 (최근 {count}건)", p50 as f64 / 1000.0, p95 as f64 / 1000.0)
            }
            None => "기록 없음".to_string(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(first_sound_ms: u64) -> LatencyEntry {
        LatencyEntry { ts: 1, lane: "companion".to_string(), chars: 10, queue_ms: 0, synth_first_ms: 1, first_sound_ms }
    }

    fn lines(values: &[u64]) -> String {
        values.iter().map(|v| serde_json::to_string(&entry(*v)).unwrap() + "\n").collect()
    }

    #[test]
    fn summarize_uses_nearest_rank_percentiles_and_skips_bad_lines() {
        let mut text = lines(&(1..=20).map(|n| n * 100).collect::<Vec<_>>());
        text.push_str("not json\n");
        assert_eq!(LatencyLog::summarize(&text), Some((1000, 1900, 20)));
        assert_eq!(LatencyLog::summarize("garbage\n"), None);
        assert_eq!(LatencyLog::summarize(&lines(&[1200])), Some((1200, 1200, 1)));
    }

    #[test]
    fn trim_keeps_last_200_lines_only_above_400() {
        assert_eq!(LatencyLog::trim(&lines(&[1; 400])), None);
        let text = lines(&(0..401).collect::<Vec<_>>());
        let trimmed = LatencyLog::trim(&text).unwrap();
        assert_eq!(trimmed.lines().count(), 200);
        assert!(trimmed.lines().last().unwrap().contains("\"first_sound_ms\":400"));
    }

    #[test]
    fn append_writes_a_line_and_status_value_reports_it() {
        let path = std::env::temp_dir().join(format!("debrief-latency-{}/latency.jsonl", std::process::id()));
        assert_eq!(LatencyLog::status_value(&path), "기록 없음");
        LatencyLog::append(&path, &entry(1250)).unwrap();
        assert_eq!(LatencyLog::status_value(&path), "p50 1.2초 · p95 1.2초 (최근 1건)");
        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }
}
