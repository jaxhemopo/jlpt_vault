package grammarcloze

import (
	"strings"
	"testing"
)

func TestFinalizeN2LearnerClozePlainKanjiNoPatch(t *testing.T) {
	sent := "私は今日は忙しくなる"
	cloze := "私は[____]忙しくなる"
	ans := "今日は"

	s, c, a, ok := FinalizeN2LearnerCloze(sent, cloze, ans)
	if !ok {
		t.Fatal("expected ok without 今日[きょう]")
	}
	if s != sent || c != cloze || a != ans {
		t.Fatalf("unexpected mutation: %q %q %q", s, c, a)
	}
	if strings.Replace(c, "[____]", a, 1) != s {
		t.Fatal("splice")
	}
}

func TestFinalizeN2LearnerClozeDerivesSpanWhenAnswerOmitsFurigana(t *testing.T) {
	sent := "食事[しょくじ]の最中[さいちゅう]に電話[でんわ]が鳴った"
	cloze := "食事[しょくじ]の[____]電話[でんわ]が鳴った"
	ansModel := "最中に" // missing さいちゅう readings

	s, c, a, ok := FinalizeN2LearnerCloze(sent, cloze, ansModel)
	if !ok {
		t.Fatal("expected ok with derived mid")
	}
	want := "最中[さいちゅう]に"
	if a != want {
		t.Fatalf("cloze_answer should be derived from sentence: got %q want %q", a, want)
	}
	if s != sent || c != cloze {
		t.Fatalf("unexpected mutation")
	}
}
