package grammarcloze

import (
	"strings"
	"testing"
)

func TestFinalizePatchesAnswerWhenChunkCarriesPatchablePhrase(t *testing.T) {
	sent := "私は今日は忙しくなる"
	cloze := "私は[____]忙しくなる"
	ans := "今日は"

	s, c, a, ok := FinalizeAfterFuriganaPatch(sent, cloze, ans)
	if !ok {
		t.Fatalf("expected ok, sent=%q cloze=%q ans=%q", sent, cloze, ans)
	}
	if strings.Replace(c, "[____]", a, 1) != s {
		t.Fatalf("splice: s=%q c=%q a=%q", s, c, a)
	}
	if !strings.Contains(a, "今日[きょう]は") {
		t.Fatalf("expected patched 今日は in answer, got %q", a)
	}
}

func TestFinalizePlainAnswerUnchangedWhenPatchOnlyOutsideBlank(t *testing.T) {
	sent := "私は医者になる"
	cloze := "私は[____]"
	ans := "医者になる"

	s, c, a, ok := FinalizeAfterFuriganaPatch(sent, cloze, ans)
	if !ok {
		t.Fatal("expected ok")
	}
	if a != ans {
		t.Fatalf("expected raw answer %q, got %q", ans, a)
	}
	if strings.Replace(c, "[____]", a, 1) != s {
		t.Fatalf("splice failed: %q + %q", c, a)
	}
}
