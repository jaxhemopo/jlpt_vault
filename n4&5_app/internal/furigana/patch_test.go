package furigana

import "testing"

func TestPatchCommonFuriganaGaps(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{
			"今日は具合[ぐあい]がいいです。",
			"今日[きょう]は具合[ぐあい]がいいです。",
		},
		{
			"私は毎日[まいにち]日記[にっき]を書[か]きます。",
			"私[わたし]は毎日[まいにち]日記[にっき]を書[か]きます。",
		},
		{
			"銀行[ぎんこう]に行きます。",
			"銀行[ぎんこう]に行[い]きます。",
		},
		{
			"男の子[おとこのこ]がいます。",
			"男[おとこ]の子[こ]がいます。",
		},
	}
	for _, tc := range cases {
		got := PatchCommonFuriganaGaps(tc.in)
		if got != tc.want {
			t.Errorf("PatchCommonFuriganaGaps(%q) = %q want %q", tc.in, got, tc.want)
		}
		if !HanClusterCoverageOK(got) {
			t.Errorf("after patch, HanClusterCoverageOK(%q) = false", got)
		}
	}
}
