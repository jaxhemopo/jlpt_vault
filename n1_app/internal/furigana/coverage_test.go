package furigana

import "testing"

func TestHanClusterCoverageOK(t *testing.T) {
	cases := []struct {
		s    string
		want bool
	}{
		{"友達[ともだち]と", true},
		{"今日[きょう]は", true},
		{"苦い[にがい]です", true},
		{"食べる[たべる]", true},
		{"好き[すき]です", true},
		{"読みます[よみます]", true},
		{"私[わたし]は医学[いがく]が好き[すき]です。", true},
		{"私は医学[いがく]が好きです。", false},
		{"友達と", false},
		{"静かな夜[よる]", false},
		{"公園で道を踏みます。", false},
		{"公園[こうえん]で道[みち]を踏[ふ]みます。", true},
		{"私は今日[きょう]は暑いです。", false},
		{"私[わたし]は今日[きょう]は暑い[あつい]です。", true},
	}
	for _, tc := range cases {
		if got := HanClusterCoverageOK(tc.s); got != tc.want {
			t.Errorf("%q: got %v want %v", tc.s, got, tc.want)
		}
	}
}
