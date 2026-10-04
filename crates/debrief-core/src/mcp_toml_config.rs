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

    /// `command =` 줄을 빼면 두 조각이 같은가. 설치 경로만 달라진 경우를 사용자 수정과 구분한다.
    pub fn same_except_command(a: &str, b: &str) -> bool {
        let significant = |text: &str| -> Vec<String> {
            text.lines()
                .map(str::trim)
                .filter(|line| !line.is_empty() && !line.starts_with("command ="))
                .map(str::to_string)
                .collect()
        };
        significant(a) == significant(b)
    }

    /// 마커가 없거나 한쪽만 남은 `[mcp_servers.debrief]` 테이블을 찾아, 그 자리(와 짝 잃은 마커 줄)를
    /// 마커로 감싼 `fragment`로 바꾼 전체 텍스트와 이전 테이블 본문을 돌려준다. 테이블이 없으면 `None`.
    pub fn replace_loose_table(existing: &str, fragment: &str) -> Option<(String, String)> {
        let lines: Vec<&str> = existing.lines().collect();
        let start = lines.iter().position(|line| line.trim() == "[mcp_servers.debrief]")?;
        let is_marker = |line: &str| line.trim() == Self::BEGIN || line.trim() == Self::END;
        let end = (start + 1..lines.len())
            .find(|&i| lines[i].trim_start().starts_with('[') || is_marker(lines[i]))
            .unwrap_or(lines.len());
        let body = lines[start..end].join("\n").trim_end().to_string();

        // 테이블 앞의 BEGIN, 뒤의 END는 짝을 잃은 우리 마커이므로 함께 교체한다.
        let from = if start > 0 && lines[start - 1].trim() == Self::BEGIN { start - 1 } else { start };
        let to = if end < lines.len() && lines[end].trim() == Self::END { end + 1 } else { end };

        let block = format!("{}\n{}\n{}", Self::BEGIN, fragment.trim_matches('\n'), Self::END);
        let mut merged: Vec<&str> = lines[..from].to_vec();
        merged.push(&block);
        merged.extend_from_slice(&lines[to..]);
        Some((body, merged.join("\n") + "\n"))
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

    #[test]
    fn same_except_command_ignores_only_the_command_line() {
        let a = "[mcp_servers.debrief]\ncommand = \"/a\"\nargs = [\"mcp\"]";
        assert!(McpTomlConfig::same_except_command(a, "[mcp_servers.debrief]\ncommand = \"/b\"\nargs = [\"mcp\"]"));
        assert!(!McpTomlConfig::same_except_command(a, "[mcp_servers.debrief]\ncommand = \"/a\"\nargs = [\"mcp\", \"x\"]"));
        assert!(!McpTomlConfig::same_except_command(a, "[mcp_servers.debrief]\ncommand = \"/a\"\nargs = [\"mcp\"]\nenabled = false"));
    }

    #[test]
    fn replace_loose_table_swaps_table_and_stray_markers_in_place() {
        let fragment = "[mcp_servers.debrief]\ncommand = \"/new\"";
        // END만 남은 경우
        let existing = "[a]\nx = 1\n\n[mcp_servers.debrief]\ncommand = \"/old\"\n# END debrief-mcp\n[z]\ny = 2\n";
        let (body, merged) = McpTomlConfig::replace_loose_table(existing, fragment).unwrap();
        assert_eq!(body, "[mcp_servers.debrief]\ncommand = \"/old\"");
        assert_eq!(
            merged,
            "[a]\nx = 1\n\n# BEGIN debrief-mcp\n[mcp_servers.debrief]\ncommand = \"/new\"\n# END debrief-mcp\n[z]\ny = 2\n"
        );
        // BEGIN만 남은 경우
        let existing = "# BEGIN debrief-mcp\n[mcp_servers.debrief]\ncommand = \"/old\"\n";
        let (_, merged) = McpTomlConfig::replace_loose_table(existing, fragment).unwrap();
        assert_eq!(merged, "# BEGIN debrief-mcp\n[mcp_servers.debrief]\ncommand = \"/new\"\n# END debrief-mcp\n");
        // 테이블이 없으면 None
        assert!(McpTomlConfig::replace_loose_table("[a]\nx = 1\n", fragment).is_none());
    }
}
