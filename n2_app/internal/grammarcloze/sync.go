package grammarcloze

import (
	"strings"

	"n3_app/internal/furigana"
)

const blankToken = "[____]"

// NormalizeBlank normalizes common LLM blank spellings to the exact "[____]" token.
func NormalizeBlank(cloze string) string {
	s := cloze
	repls := []struct{ from, to string }{
		{"［＿＿＿＿］", blankToken},
		{"［____］", blankToken},
		{"[＿＿＿＿]", blankToken},
		{"[＿＿＿]", blankToken},
		{"[＿＿]", blankToken},
		{"[ ___ ]", blankToken},
		{"[___]", blankToken},
		{"[__]", blankToken},
		{"[ ____ ]", blankToken},
		{"[____ ]", blankToken},
		{"[ ____]", blankToken},
	}
	for _, p := range repls {
		s = strings.ReplaceAll(s, p.from, p.to)
	}
	return s
}

// FinalizeAfterFuriganaPatch trims input, normalizes the blank, checks raw structure, applies
// PatchCommonFuriganaGaps to sentence and cloze, then finds cloze_answer' such that
// Replace(cloze', blank, cloze_answer') == sentence'.
//
// The model often omits readings inside cloze_answer while the same span in sentence_jp gets
// patched (e.g. 今日は → 今日[きょう]は). Trying furigana.PatchCommonFuriganaGaps(cloze_answer)
// fixes splice equality without weakening the mechanical furigana rules on the full sentence.
func FinalizeAfterFuriganaPatch(sentenceJP, clozeJP, clozeAnswer string) (outS, outC, outA string, ok bool) {
	sentenceJP = strings.TrimSpace(sentenceJP)
	clozeJP = strings.TrimSpace(NormalizeBlank(clozeJP))
	clozeAnswer = strings.TrimSpace(clozeAnswer)

	if clozeAnswer == "" || strings.Count(clozeJP, blankToken) != 1 {
		return "", "", "", false
	}
	i := strings.Index(clozeJP, blankToken)
	left := clozeJP[:i]
	right := clozeJP[i+len(blankToken):]
	if left+clozeAnswer+right != sentenceJP {
		return "", "", "", false
	}

	outS = furigana.PatchCommonFuriganaGaps(sentenceJP)
	outC = furigana.PatchCommonFuriganaGaps(clozeJP)

	patchedAns := furigana.PatchCommonFuriganaGaps(clozeAnswer)
	candidates := []string{clozeAnswer, patchedAns}
	seen := map[string]struct{}{}
	for _, a := range candidates {
		if a == "" {
			continue
		}
		if _, dup := seen[a]; dup {
			continue
		}
		seen[a] = struct{}{}
		if strings.Replace(outC, blankToken, a, 1) == outS {
			return outS, outC, a, true
		}
	}
	return "", "", "", false
}

// FinalizeN2LearnerCloze validates cloze structure and splice equality only. It does not run
// PatchCommonFuriganaGaps — N2 learners are not required to ruby every N4/N5-level kanji.
//
// When the model adds furigana in sentence_jp but puts a shorter/plain cloze_answer, left+answer+right
// no longer equals sentence_jp. If the cloze's left/right glue matches sentence_jp as prefix/suffix,
// the blank span is taken from sentence_jp so Replace(cloze, "[____]", span) == sentence_jp.
// clozeAnswer is ignored for validation; the stored answer is always the exact substring of
// sentence_jp between the cloze left/right glue (fixes model furigana mismatch on the blank span).
func FinalizeN2LearnerCloze(sentenceJP, clozeJP, clozeAnswer string) (outS, outC, outA string, ok bool) {
	_ = clozeAnswer
	sentenceJP = strings.TrimSpace(sentenceJP)
	clozeJP = strings.TrimSpace(NormalizeBlank(clozeJP))

	if strings.Count(clozeJP, blankToken) != 1 {
		return "", "", "", false
	}
	i := strings.Index(clozeJP, blankToken)
	left := clozeJP[:i]
	right := clozeJP[i+len(blankToken):]

	if !strings.HasPrefix(sentenceJP, left) || !strings.HasSuffix(sentenceJP, right) {
		return "", "", "", false
	}
	if len(sentenceJP) < len(left)+len(right) {
		return "", "", "", false
	}
	mid := sentenceJP[len(left) : len(sentenceJP)-len(right)]
	if mid == "" {
		return "", "", "", false
	}
	if strings.Replace(clozeJP, blankToken, mid, 1) != sentenceJP {
		return "", "", "", false
	}
	return sentenceJP, clozeJP, mid, true
}
