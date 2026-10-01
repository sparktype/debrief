// Codex/Grok config.toml용 마커로 감싼 TOML MCP 테이블 본문 관리
pub struct McpTomlConfig;

impl McpTomlConfig {
    pub const BEGIN: &'static str = "# BEGIN debrief-mcp";
    pub const END: &'static str = "# END debrief-mcp";

    pub fn upsert(existing: &str, fragment: &str) -> String {
        let block = format!("{}\n{}\n{}\n", Self::BEGIN, fragment.trim_matches('\n'), Self::END);
        if let Some((start, end)) = Self::owned_block_range(existing) {
            let mut result = existing[..start].to_string();
            result.push_str(&block);
            result.push_str(&existing[end..]);
            return result;
        }
        let base = existing.trim();
        if base.is_empty() {
            block
        } else {
            format!("{base}\n\n{block}")
        }
    }

    pub fn remove_owned(existing: &str) -> String {
        if let Some((start, end)) = Self::owned_block_range(existing) {
            let mut result = existing[..start].to_string();
            result.push_str(&existing[end..]);
            result
        } else {
            existing.to_string()
        }
    }

    /// 소유권 마커 사이의 내부 조각 (있다면)
    pub fn owned_fragment(existing: &str) -> Option<String> {
        let begin_at = existing.find(Self::BEGIN)?;
        let after_begin = begin_at + Self::BEGIN.len();
        let rest = &existing[after_begin..];
        let rest = rest.strip_prefix('\n')?;
        let end_at = rest.find(Self::END)?;
        let fragment = &rest[..end_at];
        Some(fragment.strip_suffix('\n').unwrap_or(fragment).to_string())
    }

    pub fn has_markers(existing: &str) -> bool {
        existing.contains(Self::BEGIN) && existing.contains(Self::END)
    }

    pub fn has_debrief_table(existing: &str) -> bool {
        existing.contains("[mcp_servers.debrief]")
    }

    /// 소유 블록(마커 포함, 그 뒤의 개행문자 하나까지)의 바이트 범위를 돌려준다.
    fn owned_block_range(existing: &str) -> Option<(usize, usize)> {
        let start = existing.find(Self::BEGIN)?;
        let end_marker_at = existing[start..].find(Self::END)? + start;
        let mut end = end_marker_at + Self::END.len();
        if existing[end..].starts_with('\n') {
            end += 1;
        }
        Some((start, end))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upsert_replaces_owned_block_and_keeps_other_entries() {
        let existing = "# BEGIN debrief-mcp\n[mcp_servers.debrief]\ncommand = \"/old/path/debrief\"\n# END debrief-mcp\n\n[mcp_servers.other]\ncommand = \"keep\"";
        let merged = McpTomlConfig::upsert(
            existing,
            "[mcp_servers.debrief]\ncommand = \"/Applications/debrief.app/Contents/MacOS/debrief\"",
        );
        assert!(merged.contains("[mcp_servers.other]"));
        assert!(merged.contains("command = \"keep\""));
        assert!(merged.contains("# BEGIN debrief-mcp"));
        assert!(merged.contains("[mcp_servers.debrief]"));
    }

    #[test]
    fn upsert_appends_block_when_no_existing_marker() {
        let existing = "[mcp_servers.other]\ncommand = \"keep\"";
        let merged = McpTomlConfig::upsert(existing, "[mcp_servers.debrief]\ncommand = \"/bin/debrief\"");
        assert!(merged.contains("[mcp_servers.other]"));
        assert!(merged.contains("# BEGIN debrief-mcp"));
        assert!(merged.contains("# END debrief-mcp"));
    }

    #[test]
    fn remove_owned_strips_only_the_marked_block() {
        let existing = "# BEGIN debrief-mcp\n[mcp_servers.debrief]\ncommand = \"x\"\n# END debrief-mcp\n\n[mcp_servers.other]\ncommand = \"keep\"";
        let removed = McpTomlConfig::remove_owned(existing);
        assert!(!removed.contains("mcp_servers.debrief"));
        assert!(removed.contains("[mcp_servers.other]"));
    }

    #[test]
    fn owned_fragment_returns_inner_text() {
        let existing = "# BEGIN debrief-mcp\n[mcp_servers.debrief]\ncommand = \"x\"\n# END debrief-mcp\n";
        assert_eq!(
            McpTomlConfig::owned_fragment(existing),
            Some("[mcp_servers.debrief]\ncommand = \"x\"".to_string())
        );
    }

    #[test]
    fn has_markers_and_has_debrief_table() {
        let with_markers = "# BEGIN debrief-mcp\n...\n# END debrief-mcp\n";
        assert!(McpTomlConfig::has_markers(with_markers));
        assert!(!McpTomlConfig::has_markers("no markers here"));
        assert!(McpTomlConfig::has_debrief_table("[mcp_servers.debrief]\ncommand=\"x\""));
        assert!(!McpTomlConfig::has_debrief_table("[mcp_servers.other]"));
    }
}
