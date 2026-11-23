package delivery

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"

	"github.com/librenews/opendotnews/internal/domain"
)

var blockedPrefixes = mustParsePrefixes([]string{
	"0.0.0.0/8",          // "This network"
	"10.0.0.0/8",         // RFC1918
	"100.64.0.0/10",      // CGNAT / RFC6598
	"127.0.0.0/8",        // Loopback
	"169.254.0.0/16",     // Link-local & AWS/GCP/Azure metadata
	"172.16.0.0/12",      // RFC1918
	"192.0.0.0/24",       // IETF protocol assignments
	"192.0.2.0/24",       // TEST-NET-1
	"192.168.0.0/16",     // RFC1918
	"198.18.0.0/15",      // Benchmarking
	"198.51.100.0/24",    // TEST-NET-2
	"203.0.113.0/24",     // TEST-NET-3
	"224.0.0.0/4",        // Multicast
	"240.0.0.0/4",        // Reserved
	"255.255.255.255/32", // Broadcast
	"::/128",             // Unspecified
	"::1/128",            // Loopback
	"fc00::/7",           // Unique local (ULA)
	"fe80::/10",          // Link-local
	"ff00::/8",           // Multicast
	"2001:db8::/32",      // Documentation
	"fd00:ec2::254/128",  // AWS IPv6 IMDS
})

func mustParsePrefixes(cidrs []string) []netip.Prefix {
	out := make([]netip.Prefix, 0, len(cidrs))
	for _, c := range cidrs {
		out = append(out, netip.MustParsePrefix(c))
	}
	return out
}

// ValidateEndpointURL validates syntax and scheme for a webhook destination URL.
func ValidateEndpointURL(rawURL string, allowInsecureHTTP bool) (*url.URL, error) {
	if strings.TrimSpace(rawURL) == "" {
		return nil, fmt.Errorf("%w: empty url", domain.ErrInvalidEndpoint)
	}
	u, err := url.Parse(rawURL)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", domain.ErrInvalidEndpoint, err)
	}
	if u.Host == "" || u.Hostname() == "" {
		return nil, fmt.Errorf("%w: missing host", domain.ErrInvalidEndpoint)
	}
	if u.User != nil {
		return nil, fmt.Errorf("%w: userinfo not allowed in webhook URL", domain.ErrInvalidEndpoint)
	}
	if u.Fragment != "" {
		return nil, fmt.Errorf("%w: fragment not allowed in webhook URL", domain.ErrInvalidEndpoint)
	}
	scheme := strings.ToLower(u.Scheme)
	if scheme != "https" && !(allowInsecureHTTP && scheme == "http") {
		return nil, fmt.Errorf("%w: scheme %q not permitted (https required)", domain.ErrInvalidEndpoint, u.Scheme)
	}
	return u, nil
}

// IsBlockedIP reports whether ip falls into loopback, RFC1918, link-local, metadata, or reserved space.
func IsBlockedIP(ip netip.Addr) bool {
	if !ip.IsValid() {
		return true
	}
	ip = ip.Unmap()
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() {
		return true
	}
	for _, p := range blockedPrefixes {
		if p.Contains(ip) {
			return true
		}
	}
	return false
}

// Resolver abstracts DNS resolution for connect-time SSRF verification and deterministic testing.
type Resolver interface {
	LookupNetIP(ctx context.Context, network, host string) ([]netip.Addr, error)
}

// NewSafeHTTPClient builds an HTTP client that disables redirects and checks resolved IPs
// at connect time to defend against SSRF and DNS rebinding.
func NewSafeHTTPClient(timeout time.Duration, allowPrivate bool, resolver Resolver) *http.Client {
	if timeout <= 0 {
		timeout = 10 * time.Second
	}
	if resolver == nil {
		resolver = net.DefaultResolver
	}

	baseDialer := &net.Dialer{
		Timeout:   minDuration(timeout, 5*time.Second),
		KeepAlive: 30 * time.Second,
	}

	transport := &http.Transport{
		Proxy:                 nil, // Never silently follow proxy env vars around SSRF guard
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   10,
		IdleConnTimeout:       60 * time.Second,
		TLSHandshakeTimeout:   minDuration(timeout, 5*time.Second),
		ExpectContinueTimeout: 1 * time.Second,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}

			// Handle literal IP addresses first.
			if ip, err := netip.ParseAddr(host); err == nil {
				if !allowPrivate && IsBlockedIP(ip) {
					return nil, fmt.Errorf("%w: destination IP %s is disallowed", domain.ErrSSRFBlocked, ip)
				}
				return baseDialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
			}

			if !allowPrivate && strings.EqualFold(host, "localhost") {
				return nil, fmt.Errorf("%w: localhost is disallowed", domain.ErrSSRFBlocked)
			}

			ips, err := resolver.LookupNetIP(ctx, "ip", host)
			if err != nil {
				return nil, err
			}
			if len(ips) == 0 {
				return nil, fmt.Errorf("%w: no IP addresses resolved for %q", domain.ErrSSRFBlocked, host)
			}

			// Verify every resolved address before attempting any connection so split-horizon/rebinding
			// answers cannot smuggle an internal IP alongside a public IP.
			for _, ip := range ips {
				if !allowPrivate && IsBlockedIP(ip) {
					return nil, fmt.Errorf("%w: resolved IP %s for %q is disallowed", domain.ErrSSRFBlocked, ip, host)
				}
			}

			var lastErr error
			for _, ip := range ips {
				conn, dialErr := baseDialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
				if dialErr == nil {
					return conn, nil
				}
				lastErr = dialErr
			}
			return nil, lastErr
		},
	}

	return &http.Client{
		Timeout:   timeout,
		Transport: transport,
		CheckRedirect: func(_ *http.Request, _ []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
}

func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}
