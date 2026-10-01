// 텐서 패딩/마스크/연결과 문장·길이 기반 텍스트 분할 — ONNX 추론과 무관한 순수 로직
#[derive(Debug, Clone, PartialEq)]
pub struct PaddedTensor<T: Clone + PartialEq> {
    pub values: Vec<T>,
    pub rows: usize,
    pub columns: usize,
}

pub struct SupertonicTensor;

const ABBREVIATIONS: &[&str] = &[
    "Dr.", "Mr.", "Mrs.", "Ms.", "Prof.", "Sr.", "Jr.", "St.", "Ave.", "Rd.", "Blvd.", "Dept.", "Inc.", "Ltd.", "Co.",
    "Corp.", "etc.", "vs.", "i.e.", "e.g.", "Ph.D.",
];

impl SupertonicTensor {
    pub fn pad<T: Clone + PartialEq>(rows: &[Vec<T>], padding: T) -> PaddedTensor<T> {
        let columns = rows.iter().map(|row| row.len()).max().unwrap_or(0);
        let mut values = Vec::with_capacity(rows.len() * columns);
        for row in rows {
            values.extend(row.iter().cloned());
            for _ in row.len()..columns {
                values.push(padding.clone());
            }
        }
        PaddedTensor { values, rows: rows.len(), columns }
    }

    pub fn length_mask(lengths: &[usize], max_length: Option<usize>) -> Vec<f32> {
        let width = max_length.unwrap_or_else(|| lengths.iter().copied().max().unwrap_or(0));
        let mut mask = Vec::with_capacity(lengths.len() * width);
        for &length in lengths {
            for i in 0..width {
                mask.push(if i < length { 1.0 } else { 0.0 });
            }
        }
        mask
    }

    pub fn concatenate(chunks: &[Vec<f32>], silence_samples: i64) -> Vec<f32> {
        let Some((first, rest)) = chunks.split_first() else { return Vec::new() };
        let silence_count = silence_samples.max(0) as usize;
        let mut result = first.clone();
        for chunk in rest {
            result.extend(std::iter::repeat_n(0.0, silence_count));
            result.extend(chunk.iter().copied());
        }
        result
    }

    pub fn float_samples(data: &[u8]) -> Vec<f32> {
        if !data.len().is_multiple_of(std::mem::size_of::<f32>()) {
            return Vec::new();
        }
        data.as_chunks::<4>().0.iter().map(|bytes| f32::from_le_bytes(*bytes)).collect()
    }

    pub fn split_text(text: &str, max_length: usize) -> Vec<String> {
        assert!(max_length > 0);
        let trimmed = text.trim();
        if trimmed.is_empty() {
            return vec![String::new()];
        }

        let mut chunks: Vec<String> = Vec::new();
        let mut current = String::new();
        for sentence in Self::sentences(trimmed) {
            for fragment in Self::fragments(&sentence, max_length) {
                let joined = if current.is_empty() { fragment.clone() } else { format!("{current} {fragment}") };
                if joined.chars().count() <= max_length {
                    current = joined;
                } else {
                    if !current.is_empty() {
                        chunks.push(std::mem::take(&mut current));
                    }
                    current = fragment;
                }
            }
        }
        if !current.is_empty() {
            chunks.push(current);
        }
        if chunks.is_empty() {
            vec![String::new()]
        } else {
            chunks
        }
    }

    /// `([.!?])(?:\s+|$)` 뒤에서 문장을 자르되, 줄임말(`Dr.` 등)로 끝나면 자르지 않는다.
    fn sentences(text: &str) -> Vec<String> {
        let chars: Vec<char> = text.chars().collect();
        let mut boundaries: Vec<usize> = Vec::new();
        for (i, &c) in chars.iter().enumerate() {
            if c != '.' && c != '!' && c != '?' {
                continue;
            }
            let next = chars.get(i + 1);
            let at_whitespace_or_end = match next {
                None => true,
                Some(c) => c.is_whitespace(),
            };
            if !at_whitespace_or_end {
                continue;
            }
            // 공백 하나(또는 그 이상)를 모두 소비한다 — `\s+`에 대응.
            let mut end = i + 1;
            while chars.get(end).is_some_and(|c| c.is_whitespace()) {
                end += 1;
            }
            boundaries.push(end);
        }

        if boundaries.is_empty() {
            return vec![text.to_string()];
        }

        let mut result = Vec::new();
        let mut start = 0usize;
        for end in boundaries {
            let candidate: String = chars[start..end].iter().collect::<String>().trim().to_string();
            if ABBREVIATIONS.iter().any(|a| candidate.ends_with(a)) {
                continue;
            }
            result.push(candidate);
            start = end;
        }
        if start < chars.len() {
            let tail: String = chars[start..].iter().collect::<String>().trim().to_string();
            result.push(tail);
        }
        result.into_iter().filter(|s| !s.is_empty()).collect()
    }

    fn fragments(sentence: &str, max_length: usize) -> Vec<String> {
        if sentence.chars().count() <= max_length {
            return vec![sentence.to_string()];
        }
        let mut result: Vec<String> = Vec::new();
        let mut current = String::new();
        for word in sentence.split_whitespace() {
            let word_len = word.chars().count();
            if word_len > max_length {
                if !current.is_empty() {
                    result.push(std::mem::take(&mut current));
                }
                let chars: Vec<char> = word.chars().collect();
                let mut offset = 0;
                while chars.len() - offset > max_length {
                    result.push(chars[offset..offset + max_length].iter().collect());
                    offset += max_length;
                }
                current = chars[offset..].iter().collect();
                continue;
            }
            let joined = if current.is_empty() { word.to_string() } else { format!("{current} {word}") };
            if joined.chars().count() > max_length {
                result.push(std::mem::take(&mut current));
                current = word.to_string();
            } else {
                current = joined;
            }
        }
        if !current.is_empty() {
            result.push(current);
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pads_rows_and_builds_masks_deterministically() {
        let padded = SupertonicTensor::pad(&[vec![4i64, 5], vec![9]], 0);
        assert_eq!(padded.values, vec![4, 5, 9, 0]);
        assert_eq!(padded.rows, 2);
        assert_eq!(padded.columns, 2);
        assert_eq!(SupertonicTensor::length_mask(&[2, 1], Some(3)), vec![1.0, 1.0, 0.0, 1.0, 0.0, 0.0]);
    }

    #[test]
    fn concatenates_chunks_with_exact_silence() {
        assert_eq!(
            SupertonicTensor::concatenate(&[vec![0.25, 0.5], vec![-0.5]], 2),
            vec![0.25, 0.5, 0.0, 0.0, -0.5]
        );
    }

    #[test]
    fn converts_native_float_tensor_data() {
        let source: Vec<f32> = vec![-1.0, -0.25, 0.0, 0.5, 1.0];
        let data: Vec<u8> = source.iter().flat_map(|f| f.to_le_bytes()).collect();
        assert_eq!(SupertonicTensor::float_samples(&data), source);
    }

    #[test]
    fn splits_korean_sentences_without_dropping_punctuation() {
        assert_eq!(
            SupertonicTensor::split_text("첫 문장입니다. 두 번째인가요? 네!", 10),
            vec!["첫 문장입니다.".to_string(), "두 번째인가요?".to_string(), "네!".to_string()]
        );
        assert_eq!(
            SupertonicTensor::split_text("Dr. Kim arrived. Ready?", 18),
            vec!["Dr. Kim arrived.".to_string(), "Ready?".to_string()]
        );
    }
}
