package domain

import (
	"errors"
	"strings"
	"testing"
)

func TestValidateNamespace(t *testing.T) {
	valid := map[string]string{
		"opennews":     "opennews",
		"OpenNews":     "opennews",
		"abc":          "abc",
		"a_b-123":      "a_b-123",
		"0123456789":   "0123456789",
		strings.Repeat("a", 32): strings.Repeat("a", 32),
	}
	for in, want := range valid {
		got, err := ValidateNamespace(in)
		if err != nil {
			t.Fatalf("ValidateNamespace(%q) unexpected error: %v", in, err)
		}
		if got != want {
			t.Fatalf("ValidateNamespace(%q) = %q, want %q", in, got, want)
		}
	}

	invalid := []struct {
		in   string
		want error
	}{
		{"", ErrInvalidNamespace},
		{"ab", ErrInvalidNamespace},
		{strings.Repeat("a", 33), ErrInvalidNamespace},
		{"-abc", ErrInvalidNamespace},
		{"_abc", ErrInvalidNamespace},
		{"bad.ns", ErrInvalidNamespace},
		{"bad/ns", ErrInvalidNamespace},
		{"bad*ns", ErrInvalidNamespace},
		{"bad>ns", ErrInvalidNamespace},
		{"system", ErrReservedNamespace},
		{"ADMIN", ErrReservedNamespace},
		{"opendotnews", ErrReservedNamespace},
	}
	for _, tc := range invalid {
		_, err := ValidateNamespace(tc.in)
		if !errors.Is(err, tc.want) {
			t.Fatalf("ValidateNamespace(%q) err = %v, want %v", tc.in, err, tc.want)
		}
	}
}

func TestParseChannel(t *testing.T) {
	okCases := map[string]string{
		"@opennews/stamford/zoning": "@opennews/stamford/zoning",
		"@OpenNews/Stamford/v1.2":   "@opennews/Stamford/v1.2",
		"@alice/news_feed-1":        "@alice/news_feed-1",
	}
	for in, want := range okCases {
		ch, err := ParseChannel(in)
		if err != nil {
			t.Fatalf("ParseChannel(%q) unexpected err: %v", in, err)
		}
		if ch.Canonical() != want {
			t.Fatalf("ParseChannel(%q).Canonical() = %q, want %q", in, ch.Canonical(), want)
		}
	}

	badCases := []struct {
		in   string
		want error
	}{
		{"", ErrInvalidChannel},
		{"opennews/news", ErrInvalidChannel},
		{"@opennews", ErrInvalidChannel},
		{"@opennews/", ErrInvalidChannel},
		{"@opennews//news", ErrInvalidChannel},
		{"@opennews/news/", ErrInvalidChannel},
		{"@opennews/../secret", ErrInvalidChannel},
		{"@opennews/./secret", ErrInvalidChannel},
		{"@opennews/*", ErrInvalidChannel},
		{"@opennews/>", ErrInvalidChannel},
		{"@opennews/a.*.b", ErrInvalidChannel},
		{"@opennews/a.>", ErrInvalidChannel},
		{"@opennews/news%20test", ErrInvalidChannel},
		{"@opennews/news\nbreak", ErrInvalidChannel},
		{"@opennews/" + strings.Repeat("a", 129), ErrInvalidChannel},
		{"@alice@hub.example/news", ErrRemoteChannelUnsupported},
		{"@alice@hub.example", ErrRemoteChannelUnsupported},
	}
	for _, tc := range badCases {
		_, err := ParseChannel(tc.in)
		if !errors.Is(err, tc.want) {
			t.Fatalf("ParseChannel(%q) err = %v, want %v", tc.in, err, tc.want)
		}
	}
}

func TestParseStartAt(t *testing.T) {
	for _, raw := range []string{"", "new", "earliest_available", "seq:1", "seq:999"} {
		if _, err := ParseStartAt(raw); err != nil {
			t.Fatalf("ParseStartAt(%q) unexpected err: %v", raw, err)
		}
	}
	for _, raw := range []string{"seq:0", "seq:-1", "seq:abc", "latest", "invalid"} {
		if _, err := ParseStartAt(raw); !errors.Is(err, ErrInvalidCursor) {
			t.Fatalf("ParseStartAt(%q) err = %v, want ErrInvalidCursor", raw, err)
		}
	}
}
