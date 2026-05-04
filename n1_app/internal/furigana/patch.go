package furigana

import "strings"

// PatchCommonFuriganaGaps fixes frequent LLM omissions so HanClusterCoverageOK can pass.
// Only rewrites fixed literal phrases; does not run on already-correct text.
func PatchCommonFuriganaGaps(s string) string {
	s = patchNoNoKo(s)

	repls := []struct{ from, to string }{
		{"今日は", "今日[きょう]は"},
		{"今日の", "今日[きょう]の"},
		{"今日も", "今日[きょう]も"},
		{"今日、", "今日[きょう]、"},
		{"明日は", "明日[あした]は"},
		{"明日の", "明日[あした]の"},
		{"昨日は", "昨日[きのう]は"},
		{"昨日の", "昨日[きのう]の"},
		{"今週は", "今週[こんしゅう]は"},
		{"今月は", "今月[こんげつ]は"},
		{"今年は", "今年[ことし]は"},
		{"今晩は", "今晩[こんばん]は"},
		{"今朝は", "今朝[けさ]は"},
		{"今は", "今[いま]は"},
		{"今、", "今[いま]、"},
	}
	for _, p := range repls {
		s = strings.ReplaceAll(s, p.from, p.to)
	}

	particles := []string{"は", "が", "の", "に", "を", "も", "で", "と", "へ", "から", "まで", "や", "か"}
	for _, x := range particles {
		from := "私" + x
		to := "私[わたし]" + x
		// Avoid turning 私[わたし]は into double brackets: "私は" does not occur inside that form.
		s = strings.ReplaceAll(s, from, to)
	}

	// 行く / 行き — avoid touching 銀行 (行 is not after に/を/へ as single 行)
	s = strings.ReplaceAll(s, "に行きます", "に行[い]きます")
	s = strings.ReplaceAll(s, "を行きます", "を行[い]きます")
	s = strings.ReplaceAll(s, "へ行きます", "へ行[い]きます")
	s = strings.ReplaceAll(s, "で行きます", "で行[い]きます")
	s = strings.ReplaceAll(s, "に行き", "に行[い]き")
	s = strings.ReplaceAll(s, "に行く", "に行[い]く")
	s = strings.ReplaceAll(s, "を行く", "を行[い]く")
	s = strings.ReplaceAll(s, "へ行く", "へ行[い]く")
	s = strings.ReplaceAll(s, "に行って", "に行[い]って")
	s = strings.ReplaceAll(s, "に行った", "に行[い]った")
	s = strings.ReplaceAll(s, "に行か", "に行[い]か")

	s = strings.ReplaceAll(s, "を読みます", "を読[よ]みます")
	s = strings.ReplaceAll(s, "が読みます", "が読[よ]みます")
	s = strings.ReplaceAll(s, "を書きます", "を書[か]きます")
	s = strings.ReplaceAll(s, "を聞きます", "を聞[き]きます")
	s = strings.ReplaceAll(s, "が聞きます", "が聞[き]きます")
	s = strings.ReplaceAll(s, "を買います", "を買[か]います")
	s = strings.ReplaceAll(s, "を食べます", "を食[た]べます")
	s = strings.ReplaceAll(s, "を見ます", "を見[み]ます")
	s = strings.ReplaceAll(s, "が見ます", "が見[み]ます")

	// 〜てあげる / common omissions
	s = strings.ReplaceAll(s, "を教えます", "を教[おし]えます")
	s = strings.ReplaceAll(s, "に教えます", "に教[おし]えます")
	s = strings.ReplaceAll(s, "を使います", "を使[つか]います")
	s = strings.ReplaceAll(s, "を作ります", "を作[つく]ります")

	s = strings.ReplaceAll(s, "学校で", "学校[がっこう]で")
	s = strings.ReplaceAll(s, "学校に", "学校[がっこう]に")
	s = strings.ReplaceAll(s, "学校へ", "学校[がっこう]へ")
	s = strings.ReplaceAll(s, "学校の", "学校[がっこう]の")
	s = strings.ReplaceAll(s, "公園で", "公園[こうえん]で")
	s = strings.ReplaceAll(s, "公園に", "公園[こうえん]に")
	s = strings.ReplaceAll(s, "家で", "家[いえ]で")
	s = strings.ReplaceAll(s, "家に", "家[いえ]に")
	s = strings.ReplaceAll(s, "家の", "家[いえ]の")
	// 日本… before 本… so we never turn 日本は into 日本[ほん]は
	s = strings.ReplaceAll(s, "日本は", "日本[にほん]は")
	s = strings.ReplaceAll(s, "日本の", "日本[にほん]の")
	s = strings.ReplaceAll(s, "日本に", "日本[にほん]に")
	s = strings.ReplaceAll(s, "本は", "本[ほん]は")
	s = strings.ReplaceAll(s, "本を", "本[ほん]を")
	s = strings.ReplaceAll(s, "本が", "本[ほん]が")

	return s
}

func patchNoNoKo(s string) string {
	s = strings.ReplaceAll(s, "男の子[おとこのこ]", "男[おとこ]の子[こ]")
	s = strings.ReplaceAll(s, "女の子[おんなのこ]", "女[おんな]の子[こ]")
	return s
}
