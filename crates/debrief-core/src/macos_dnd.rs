// macOS 방해금지(집중 모드) 활성 여부를 DoNotDisturb Assertions.json에서 읽는다
use std::path::{Path, PathBuf};

pub struct MacosDnd;

impl MacosDnd {
    pub fn assertions_url(home: &Path) -> PathBuf {
        home.join("Library/DoNotDisturb/DB/Assertions.json")
    }

    /// 활성이면 `Some(true)`, 비활성이면 `Some(false)`, 읽거나 해석할 수 없으면 `None`.
    pub fn is_active(home: &Path) -> Option<bool> {
        let text = std::fs::read_to_string(Self::assertions_url(home)).ok()?;
        Self::active_from_json(&text)
    }

    /// 집중 모드가 켜지면 `data[*].storeAssertionRecords`에 항목이 생긴다.
    /// 꺼진 상태에는 `storeInvalidationRecords` 등 다른 키만 남는다.
    pub fn active_from_json(text: &str) -> Option<bool> {
        let value: serde_json::Value = serde_json::from_str(text).ok()?;
        let items = value.get("data")?.as_array()?;
        Some(items.iter().any(|item| {
            item.get("storeAssertionRecords").and_then(|records| records.as_array()).is_some_and(|r| !r.is_empty())
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn inactive_when_only_invalidation_records_exist() {
        let json = r#"{"data":[{"storeInvalidationRequestRecords":[{}],"storeInvalidationRecords":[{}]}]}"#;
        assert_eq!(MacosDnd::active_from_json(json), Some(false));
    }

    #[test]
    fn active_when_an_assertion_record_exists() {
        let json = r#"{"data":[{"storeAssertionRecords":[{"assertionDetails":{}}]}]}"#;
        assert_eq!(MacosDnd::active_from_json(json), Some(true));
    }

    #[test]
    fn empty_assertion_list_is_inactive() {
        assert_eq!(MacosDnd::active_from_json(r#"{"data":[{"storeAssertionRecords":[]}]}"#), Some(false));
    }

    #[test]
    fn unreadable_or_unexpected_shapes_are_unknown() {
        assert_eq!(MacosDnd::active_from_json("not json"), None);
        assert_eq!(MacosDnd::active_from_json(r#"{"other":1}"#), None);
        assert_eq!(MacosDnd::is_active(Path::new("/nonexistent-home")), None);
    }
}
