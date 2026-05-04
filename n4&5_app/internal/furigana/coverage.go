package furigana

import "unicode"

// HanClusterCoverageOK is true when every contiguous run of CJK ideographs has a matching
// [reading] before any further kanji appears. Okurigana between the kanji cluster and the
// bracket is allowed (e.g. 食べる[たべる], 好き[すき], 読みます[よみます], 苦い[にがい]).
// Bare patterns like 私は… with no [ before the next 漢字 still fail (e.g. 私は医学[…]).
// Text inside [...] is skipped. Nested brackets are not supported.
func HanClusterCoverageOK(s string) bool {
	runes := []rune(s)
	for i := 0; i < len(runes); i++ {
		r := runes[i]
		if r == '[' {
			for i++; i < len(runes) && runes[i] != ']'; i++ {
			}
			continue
		}
		if unicode.Is(unicode.Han, r) {
			j := i
			for j < len(runes) && unicode.Is(unicode.Han, runes[j]) {
				j++
			}
			k := j
			for k < len(runes) && runes[k] != '[' {
				if unicode.Is(unicode.Han, runes[k]) {
					return false
				}
				k++
			}
			if k >= len(runes) {
				return false
			}
			i = k
			for i++; i < len(runes) && runes[i] != ']'; i++ {
			}
			continue
		}
	}
	return true
}
