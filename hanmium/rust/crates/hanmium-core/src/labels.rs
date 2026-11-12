//! Vimium 방식 라벨 글자.

/// 기본 라벨 글자. 스크롤 모드로 바꾸는 j·k 를 뺐다.
pub const DEFAULT_ALPHABET: &str = "sadflewcmpgh";
/// 라벨 모드에서 다른 모드로 바꾸는 키. 라벨 글자로 쓰지 않는다.
pub const TO_SEARCH: char = '/';
pub const TO_SCROLL: [char; 2] = ['j', 'k'];

/// 설정 글자에서 모드 키·공백·겹친 글자를 뺀다. 두 글자 미만이면 기본값.
pub fn alphabet(raw: &str) -> Vec<char> {
    let mut seen = std::collections::HashSet::new();
    let chars: Vec<char> = raw
        .to_lowercase()
        .chars()
        .filter(|c| !c.is_whitespace() && *c != TO_SEARCH && !TO_SCROLL.contains(c) && seen.insert(*c))
        .collect();
    if chars.len() >= 2 { chars } else { DEFAULT_ALPHABET.chars().collect() }
}

/// 라벨 n 개. 적으면 모두 한 글자이고, 모자라면 앞 글자부터 두 글자(더 모자라면 세 글자)로 늘린다. 늘린 글자는 한 글자
/// 라벨로 쓰지 않으므로 어느 라벨도 다른 라벨의 앞부분이 아니다 — 완전히 일치하면 곧 하나뿐이다.
pub fn make(n: usize, alphabet: &[char]) -> Vec<String> {
    if n == 0 || alphabet.len() < 2 {
        return vec![];
    }
    let mut hints = vec![String::new()];
    let mut offset = 0;
    while hints.len() - offset < n || hints.len() == 1 {
        let hint = hints[offset].clone();
        offset += 1;
        for c in alphabet {
            hints.push(format!("{c}{hint}"));
        }
    }
    let mut picked: Vec<String> = hints[offset..offset + n].to_vec();
    picked.sort();
    picked.into_iter().map(|h| h.chars().rev().collect()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_label_is_a_prefix_of_another() {
        let a = alphabet(DEFAULT_ALPHABET);
        for n in [1, 5, 12, 13, 50, 144, 145, 800] {
            let labels = make(n, &a);
            assert_eq!(labels.len(), n);
            let set: std::collections::HashSet<_> = labels.iter().collect();
            assert_eq!(set.len(), n, "중복 {n}");
            for x in &labels {
                assert!(!x.contains(['j', 'k', '/']));
                for y in &labels {
                    assert!(x == y || !y.starts_with(x.as_str()), "{x} 가 {y} 의 앞부분 ({n}개)");
                }
            }
        }
        assert!(make(12, &a).iter().all(|l| l.chars().count() == 1));
        assert_eq!(alphabet("jk/aaa"), DEFAULT_ALPHABET.chars().collect::<Vec<_>>());
    }
}
