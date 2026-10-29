// 설정의 발음 사전으로 합성 직전 영어 용어를 읽기 쉬운 표기로 바꾼다
use std::collections::HashMap;

pub struct Pronunciation;

impl Pronunciation {
    /// 사용자가 같은 단어를 지우거나 바꾸기 전까지 쓰는 기본 표기. 사용자 사전이 있으면 그것이 이긴다.
    pub fn defaults() -> HashMap<String, String> {
        [("debrief", "디브리프"), ("Codex", "코덱스"), ("Grok", "그록"), ("MCP", "엠씨피")]
            .into_iter()
            .map(|(term, spoken)| (term.to_string(), spoken.to_string()))
            .collect()
    }

    /// 단어 경계(앞뒤가 ASCII 영숫자가 아님)에서 대소문자를 무시하고 바꾼다. 긴 항목이 먼저다.
    pub fn apply(text: &str, lexicon: &HashMap<String, String>) -> String {
        let mut merged = Self::defaults();
        for (term, spoken) in lexicon {
            if term.is_empty() {
                continue;
            }
            merged.retain(|existing, _| !existing.eq_ignore_ascii_case(term));
            merged.insert(term.clone(), spoken.clone());
        }
        let lexicon = merged;
        let mut entries: Vec<(&str, &str)> =
            lexicon.iter().filter(|(term, _)| !term.is_empty()).map(|(t, s)| (t.as_str(), s.as_str())).collect();
        entries.sort_by(|a, b| b.0.len().cmp(&a.0.len()).then(a.0.cmp(b.0)));
        let mut output = String::with_capacity(text.len());
        let mut index = 0;
        'scan: while index < text.len() {
            let at_boundary = !text[..index].chars().next_back().is_some_and(|c| c.is_ascii_alphanumeric());
            if at_boundary {
                for (term, spoken) in &entries {
                    let end = index + term.len();
                    let matches = text.get(index..end).is_some_and(|slice| slice.eq_ignore_ascii_case(term));
                    if matches && !text[end..].chars().next().is_some_and(|c| c.is_ascii_alphanumeric()) {
                        output.push_str(spoken);
                        index = end;
                        continue 'scan;
                    }
                }
            }
            let character = text[index..].chars().next().expect("index is on a char boundary");
            output.push(character);
            index += character.len_utf8();
        }
        output
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn lexicon(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(t, s)| (t.to_string(), s.to_string())).collect()
    }

    #[test]
    fn replaces_whole_terms_next_to_korean_particles_ignoring_case() {
        let lexicon = lexicon(&[("MCP", "엠씨피"), ("cargo", "카고")]);
        assert_eq!(Pronunciation::apply("MCP를 고치고 Cargo test를 돌렸습니다.", &lexicon), "엠씨피를 고치고 카고 test를 돌렸습니다.");
    }

    #[test]
    fn leaves_terms_inside_longer_words() {
        let lexicon = lexicon(&[("PR", "피알")]);
        assert_eq!(Pronunciation::apply("PRint PR2 PR.", &lexicon), "PRint PR2 피알.");
    }

    #[test]
    fn longer_entries_win_over_their_prefixes() {
        let lexicon = lexicon(&[("GitHub", "깃허브"), ("GitHub Actions", "깃허브 액션")]);
        assert_eq!(Pronunciation::apply("GitHub Actions와 GitHub", &lexicon), "깃허브 액션와 깃허브");
    }

    #[test]
    fn empty_lexicon_or_empty_term_keeps_text() {
        assert_eq!(Pronunciation::apply("그대로입니다.", &HashMap::new()), "그대로입니다.");
        assert_eq!(Pronunciation::apply("abc", &lexicon(&[("", "x")])), "abc");
    }

    #[test]
    fn defaults_cover_product_names_until_the_user_overrides_them() {
        assert_eq!(
            Pronunciation::apply("debrief와 Codex, grok, MCP.", &HashMap::new()),
            "디브리프와 코덱스, 그록, 엠씨피."
        );
        assert_eq!(Pronunciation::apply("MCP를 바꿨습니다.", &lexicon(&[("MCP", "엠시피")])), "엠시피를 바꿨습니다.");
        assert_eq!(Pronunciation::apply("Codex", &lexicon(&[("MCP", "엠시피")])), "코덱스");
        assert_eq!(Pronunciation::apply("MCP", &lexicon(&[("MCP", "MCP")])), "MCP", "같은 표기로 기본값을 끈다");
    }
}
