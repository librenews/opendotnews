package domain

import (
	"fmt"
	"strings"
)

const (
	MinNamespaceLen   = 3
	MaxNamespaceLen   = 32
	MaxChannelPathLen = 128
)

var reservedNamespaces = map[string]struct{}{
	"system":      {},
	"admin":       {},
	"root":        {},
	"opendotnews": {},
	"internal":    {},
	"api":         {},
	"oauth":       {},
	"mcp":         {},
	"healthz":     {},
	"readyz":      {},
	"metrics":     {},
	"well-known":  {},
}

// ChannelName represents a validated, canonicalized channel identifier (@namespace/channel/path).
type ChannelName struct {
	Namespace string
	Path      string
}

// Canonical returns the canonical public channel string "@namespace/path".
func (c ChannelName) Canonical() string {
	return "@" + c.Namespace + "/" + c.Path
}

// ValidateNamespace canonicalizes (lowercases) and validates a namespace name.
func ValidateNamespace(raw string) (string, error) {
	if raw == "" {
		return "", fmt.Errorf("%w: empty namespace", ErrInvalidNamespace)
	}
	ns := strings.ToLower(raw)
	if len(ns) < MinNamespaceLen || len(ns) > MaxNamespaceLen {
		return "", fmt.Errorf("%w: length must be between %d and %d", ErrInvalidNamespace, MinNamespaceLen, MaxNamespaceLen)
	}
	for i := 0; i < len(ns); i++ {
		ch := ns[i]
		isLower := ch >= 'a' && ch <= 'z'
		isDigit := ch >= '0' && ch <= '9'
		if i == 0 {
			if !isLower && !isDigit {
				return "", fmt.Errorf("%w: must start with ASCII letter or digit", ErrInvalidNamespace)
			}
			continue
		}
		if !isLower && !isDigit && ch != '_' && ch != '-' {
			return "", fmt.Errorf("%w: illegal character %q", ErrInvalidNamespace, ch)
		}
	}
	if _, reserved := reservedNamespaces[ns]; reserved {
		return "", fmt.Errorf("%w: %q", ErrReservedNamespace, ns)
	}
	return ns, nil
}

// ParseChannel validates and canonicalizes a public channel name "@namespace/channel/path".
// Remote cross-hub syntax "@namespace@hub.example/path" is explicitly rejected with
// ErrRemoteChannelUnsupported.
func ParseChannel(raw string) (ChannelName, error) {
	if raw == "" {
		return ChannelName{}, fmt.Errorf("%w: empty channel", ErrInvalidChannel)
	}
	if raw[0] != '@' {
		return ChannelName{}, fmt.Errorf("%w: must start with '@'", ErrInvalidChannel)
	}
	rest := raw[1:]
	slashIdx := strings.IndexByte(rest, '/')
	if slashIdx <= 0 {
		if strings.ContainsRune(rest, '@') {
			return ChannelName{}, ErrRemoteChannelUnsupported
		}
		return ChannelName{}, fmt.Errorf("%w: must have format @namespace/path", ErrInvalidChannel)
	}

	rawNS := rest[:slashIdx]
	rawPath := rest[slashIdx+1:]

	if strings.ContainsRune(rawNS, '@') {
		return ChannelName{}, ErrRemoteChannelUnsupported
	}

	ns, err := ValidateNamespace(rawNS)
	if err != nil {
		return ChannelName{}, err
	}

	if err := ValidateChannelPath(rawPath); err != nil {
		return ChannelName{}, err
	}

	return ChannelName{
		Namespace: ns,
		Path:      rawPath,
	}, nil
}

// ValidateChannelPath checks path segment syntax and prevents wildcards, traversal, or control chars.
func ValidateChannelPath(path string) error {
	if len(path) == 0 || len(path) > MaxChannelPathLen {
		return fmt.Errorf("%w: path length must be 1..%d bytes", ErrInvalidChannel, MaxChannelPathLen)
	}
	if path[0] == '/' || path[len(path)-1] == '/' {
		return fmt.Errorf("%w: leading or trailing slash not allowed", ErrInvalidChannel)
	}

	segments := strings.Split(path, "/")
	for _, seg := range segments {
		if seg == "" {
			return fmt.Errorf("%w: empty path segment", ErrInvalidChannel)
		}
		if seg == "." || seg == ".." {
			return fmt.Errorf("%w: relative segment %q not allowed", ErrInvalidChannel, seg)
		}
		for i := 0; i < len(seg); i++ {
			ch := seg[i]
			isUpper := ch >= 'A' && ch <= 'Z'
			isLower := ch >= 'a' && ch <= 'z'
			isDigit := ch >= '0' && ch <= '9'
			if !isUpper && !isLower && !isDigit && ch != '_' && ch != '-' && ch != '.' {
				return fmt.Errorf("%w: illegal character %q in channel path", ErrInvalidChannel, ch)
			}
		}
	}
	return nil
}

// NATSSubject returns a safe, opaque internal NATS subject for a namespace + channel ID pair.
// Untrusted public channel strings are never passed directly as NATS subjects.
func NATSSubject(namespaceID, channelID string) string {
	return "ev." + namespaceID + "." + channelID
}
