// Package proxy implements HTTP/1 CONNECT tunnelling without intercepting the
// destination TLS session. No client HTTP headers are forwarded upstream.
package proxy

import (
	"bufio"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Funny-Rainbow/Easy-proxy/internal/config"
)

var blocked = prefixes(
	"0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
	"172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16",
	"198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
	// Only global unicast IPv6 is accepted below; also exclude special ranges,
	// IPv4 translation/tunnel mechanisms and documentation space.
	"2001::/23", "2001:db8::/32", "2002::/16", "3fff::/20",
)

func prefixes(ss ...string) []netip.Prefix {
	out := make([]netip.Prefix, 0, len(ss))
	for _, s := range ss {
		out = append(out, netip.MustParsePrefix(s))
	}
	return out
}
func Public(ip netip.Addr) bool {
	ip = ip.Unmap()
	if !ip.IsValid() || ip.Zone() != "" || !ip.IsGlobalUnicast() {
		return false
	}
	if ip.Is6() && !netip.MustParsePrefix("2000::/3").Contains(ip) {
		return false
	}
	for _, p := range blocked {
		if p.Contains(ip) {
			return false
		}
	}
	return true
}

type resolver interface {
	LookupNetIP(context.Context, string, string) ([]netip.Addr, error)
}
type dialer interface {
	DialContext(context.Context, string, string) (net.Conn, error)
}

// Resolve once, reject mixed public/private answers, then dial the validated
// literal address. A second resolver lookup must never occur during dial.
func dialPublic(ctx context.Context, address string, r resolver, d dialer) (net.Conn, error) {
	host, port, e := net.SplitHostPort(address)
	if e != nil || port != "443" || host == "" || strings.Contains(host, "%") {
		return nil, errors.New("only public destinations on port 443 are allowed")
	}
	ips, e := r.LookupNetIP(ctx, "ip", host)
	if e != nil {
		return nil, errors.New("destination lookup failed")
	}
	if len(ips) == 0 {
		return nil, errors.New("destination has no addresses")
	}
	for _, ip := range ips {
		if !Public(ip) {
			return nil, errors.New("destination address is restricted")
		}
	}
	var last error
	for _, ip := range ips {
		c, e := d.DialContext(ctx, "tcp", net.JoinHostPort(ip.Unmap().String(), port))
		if e == nil {
			return c, nil
		}
		last = e
	}
	return nil, fmt.Errorf("destination connection failed: %w", last)
}

type Handler struct {
	Config      config.Config
	connect     func(context.Context, string) (net.Conn, *bufio.Reader, error)
	sem         chan struct{}
	mu          sync.Mutex
	connections map[net.Conn]struct{}
	closed      bool
}

func Server(c config.Config) *Handler {
	h := newHandler(c)
	h.connect = func(ctx context.Context, address string) (net.Conn, *bufio.Reader, error) {
		conn, e := dialPublic(ctx, address, net.DefaultResolver, &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second})
		if e != nil {
			return nil, nil, e
		}
		return conn, bufio.NewReader(conn), nil
	}
	return h
}

func Client(c config.Config) (*Handler, error) {
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(c.CA)) {
		return nil, errors.New("invalid proxy CA")
	}
	h := newHandler(c)
	h.connect = func(ctx context.Context, address string) (net.Conn, *bufio.Reader, error) {
		d := tls.Dialer{NetDialer: &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}, Config: &tls.Config{RootCAs: pool, ServerName: c.Host, MinVersion: tls.VersionTLS12, NextProtos: []string{"http/1.1"}}}
		conn, e := d.DialContext(ctx, "tcp", net.JoinHostPort(c.Host, strconv.Itoa(c.Port)))
		if e != nil {
			return nil, nil, errors.New("proxy TLS connection failed (check CA, server IP, and connectivity)")
		}
		_ = conn.SetDeadline(time.Now().Add(15 * time.Second))
		auth := base64.StdEncoding.EncodeToString([]byte(c.Username + ":" + c.Password))
		_, e = fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\nProxy-Authorization: Basic %s\r\n\r\n", address, address, auth)
		if e != nil {
			conn.Close()
			return nil, nil, errors.New("proxy CONNECT write failed")
		}
		br := bufio.NewReaderSize(conn, 4096)
		// Bound upstream response headers even if the configured server is faulty.
		statusBytes, e := br.ReadSlice('\n')
		status := string(statusBytes)
		if e != nil {
			conn.Close()
			return nil, nil, errors.New("proxy CONNECT response failed")
		}
		if len(status) > 4096 {
			conn.Close()
			return nil, nil, errors.New("proxy response too large")
		}
		fields := strings.Fields(status)
		if len(fields) < 2 || fields[0] != "HTTP/1.1" || fields[1] != "200" {
			conn.Close()
			return nil, nil, errors.New("proxy rejected CONNECT (check credentials and destination policy)")
		}
		total := len(status)
		for {
			lineBytes, e := br.ReadSlice('\n')
			line := string(lineBytes)
			total += len(line)
			if e != nil || total > 16384 {
				conn.Close()
				return nil, nil, errors.New("invalid proxy response headers")
			}
			if line == "\r\n" {
				break
			}
		}
		_ = conn.SetDeadline(time.Time{})
		return conn, br, nil
	}
	return h, nil
}

func newHandler(c config.Config) *Handler {
	return &Handler{Config: c, sem: make(chan struct{}, c.MaxConnections), connections: make(map[net.Conn]struct{})}
}

func (h *Handler) track(c net.Conn) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.closed {
		c.Close()
		return false
	}
	h.connections[c] = struct{}{}
	return true
}
func (h *Handler) untrack(c net.Conn) {
	h.mu.Lock()
	delete(h.connections, c)
	h.mu.Unlock()
	c.Close()
}
func (h *Handler) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.closed = true
	for c := range h.connections {
		c.Close()
	}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if h.Config.Kind == "server" {
		provided := r.Header.Get("Proxy-Authorization")
		want := "Basic " + base64.StdEncoding.EncodeToString([]byte(h.Config.Username+":"+h.Config.Password))
		a, b := sha256.Sum256([]byte(provided)), sha256.Sum256([]byte(want))
		if subtle.ConstantTimeCompare(a[:], b[:]) != 1 {
			w.Header().Set("Proxy-Authenticate", `Basic realm="Easy-proxy"`)
			http.Error(w, "proxy authentication required", http.StatusProxyAuthRequired)
			return
		}
	}
	if r.Method != http.MethodConnect {
		http.Error(w, "CONNECT required", http.StatusMethodNotAllowed)
		return
	}
	host, port, e := net.SplitHostPort(r.Host)
	if e != nil || port != "443" || host == "" || strings.ContainsAny(host, "\r\n\t /\\%") || r.RequestURI != r.Host || r.ContentLength > 0 || len(r.TransferEncoding) > 0 {
		http.Error(w, "CONNECT requires host:443", http.StatusForbidden)
		return
	}
	select {
	case h.sem <- struct{}{}:
		defer func() { <-h.sem }()
	default:
		http.Error(w, "connection limit reached", http.StatusServiceUnavailable)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	up, upReader, e := h.connect(ctx, r.Host)
	cancel()
	if e != nil {
		http.Error(w, "CONNECT failed: "+e.Error(), http.StatusBadGateway)
		return
	}
	if !h.track(up) {
		http.Error(w, "proxy stopping", http.StatusServiceUnavailable)
		return
	}
	defer h.untrack(up)
	hijacker, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "HTTP/1 required", http.StatusHTTPVersionNotSupported)
		return
	}
	down, rw, e := hijacker.Hijack()
	if e != nil {
		return
	}
	if !h.track(down) {
		return
	}
	defer h.untrack(down)
	if _, e = rw.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n"); e != nil {
		return
	}
	if e = rw.Flush(); e != nil {
		return
	}
	idle := time.Duration(h.Config.IdleSeconds) * time.Second
	_ = up.SetDeadline(time.Now().Add(idle))
	_ = down.SetDeadline(time.Now().Add(idle))
	a := &activityConn{Conn: down, idle: idle}
	b := &activityConn{Conn: up, idle: idle}
	// Preserve any tunnel bytes net/http or ReadResponse buffered with headers.
	du := io.MultiReader(io.LimitReader(rw.Reader, int64(rw.Reader.Buffered())), a)
	uu := io.MultiReader(io.LimitReader(upReader, int64(upReader.Buffered())), b)
	done := make(chan struct{})
	go func() { io.Copy(b, du); halfClose(up); close(done) }()
	io.Copy(a, uu)
	halfClose(down)
	// Close both sides after downstream EOF/error so an upstream read cannot leak.
	up.Close()
	down.Close()
	<-done
}

func halfClose(c net.Conn) {
	if c, ok := c.(interface{ CloseWrite() error }); ok {
		_ = c.CloseWrite()
	}
}

type activityConn struct {
	net.Conn
	idle time.Duration
}

func (c *activityConn) Read(p []byte) (int, error) {
	n, e := c.Conn.Read(p)
	if n > 0 {
		_ = c.Conn.SetDeadline(time.Now().Add(c.idle))
	}
	return n, e
}
func (c *activityConn) Write(p []byte) (int, error) {
	n, e := c.Conn.Write(p)
	if n > 0 {
		_ = c.Conn.SetDeadline(time.Now().Add(c.idle))
	}
	return n, e
}

func Run(ctx context.Context, c config.Config) error {
	if e := c.Validate(c.Kind); e != nil {
		return e
	}
	var h *Handler
	var e error
	if c.Kind == "server" {
		h = Server(c)
	} else {
		h, e = Client(c)
		if e != nil {
			return e
		}
	}
	defer h.Close()
	l, e := net.Listen("tcp", c.Listen)
	if e != nil {
		return e
	}
	defer l.Close()
	s := &http.Server{Handler: h, ReadHeaderTimeout: 15 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384, TLSConfig: &tls.Config{MinVersion: tls.VersionTLS12, NextProtos: []string{"http/1.1"}}, TLSNextProto: make(map[string]func(*http.Server, *tls.Conn, http.Handler)), ErrorLog: log.New(io.Discard, "", 0)}
	finished := make(chan struct{})
	defer close(finished)
	go func() {
		select {
		case <-ctx.Done():
			h.Close()
			_ = s.Close()
		case <-finished:
		}
	}()
	log.Printf("Easy-proxy %s listening on %s", c.Kind, c.Listen)
	if c.Kind == "server" {
		e = s.ServeTLS(l, c.CertFile, c.KeyFile)
	} else {
		e = s.Serve(l)
	}
	if errors.Is(e, http.ErrServerClosed) {
		return nil
	}
	return e
}
