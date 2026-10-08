package proxy

import (
	"bufio"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/Funny-Rainbow/Easy-proxy/internal/config"
	"github.com/Funny-Rainbow/Easy-proxy/internal/pki"
)

func TestPublicPolicy(t *testing.T) {
	for _, s := range []string{"127.0.0.1", "10.0.0.1", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "192.0.2.1", "198.18.0.1", "224.0.0.1", "255.255.255.255", "::1", "::", "fe80::1", "fc00::1", "::ffff:127.0.0.1", "64:ff9b::a00:1", "2002:7f00:1::", "2001::1", "2001:db8::1", "3fff::1"} {
		if Public(netip.MustParseAddr(s)) {
			t.Errorf("allowed restricted address %s", s)
		}
	}
	for _, s := range []string{"8.8.8.8", "1.1.1.1", "::ffff:8.8.8.8", "2606:4700:4700::1111"} {
		if !Public(netip.MustParseAddr(s)) {
			t.Errorf("blocked public address %s", s)
		}
	}
}

type fakeResolver struct {
	ips   []netip.Addr
	calls int
}

func (r *fakeResolver) LookupNetIP(context.Context, string, string) ([]netip.Addr, error) {
	r.calls++
	return r.ips, nil
}

type fakeDialer struct{ addresses []string }

func (d *fakeDialer) DialContext(_ context.Context, _, address string) (net.Conn, error) {
	d.addresses = append(d.addresses, address)
	a, b := net.Pipe()
	b.Close()
	return a, nil
}
func TestDNSValidationAndPinning(t *testing.T) {
	for _, ips := range [][]netip.Addr{{netip.MustParseAddr("127.0.0.1")}, {netip.MustParseAddr("8.8.8.8"), netip.MustParseAddr("10.0.0.1")}} {
		r := &fakeResolver{ips: ips}
		d := &fakeDialer{}
		if c, e := dialPublic(context.Background(), "example.com:443", r, d); e == nil {
			c.Close()
			t.Fatal("private DNS result accepted")
		}
		if len(d.addresses) != 0 {
			t.Fatal("dialed before validating all DNS answers")
		}
	}
	r := &fakeResolver{ips: []netip.Addr{netip.MustParseAddr("8.8.8.8")}}
	d := &fakeDialer{}
	c, e := dialPublic(context.Background(), "example.com:443", r, d)
	if e != nil {
		t.Fatal(e)
	}
	c.Close()
	if r.calls != 1 || len(d.addresses) != 1 || d.addresses[0] != "8.8.8.8:443" {
		t.Fatalf("DNS was not pinned: %#v %#v", r, d)
	}
	for _, s := range []string{"example.com:80", "example.com:22", "[fe80::1%eth0]:443", "bad-address"} {
		if c, e := dialPublic(context.Background(), s, r, d); e == nil {
			c.Close()
			t.Errorf("allowed %s", s)
		}
	}
}

func serverConfig() config.Config {
	return config.Config{Schema: 1, Kind: "server", Username: "user", Password: "secret", MaxConnections: 4, IdleSeconds: 2}
}
func auth(c config.Config) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(c.Username+":"+c.Password))
}
func TestAuthenticationAndRequestPolicy(t *testing.T) {
	c := serverConfig()
	h := Server(c)
	defer h.Close()
	var called atomic.Int32
	h.connect = func(context.Context, string) (net.Conn, *bufio.Reader, error) {
		called.Add(1)
		return nil, nil, fmt.Errorf("unexpected dial")
	}
	for _, test := range []struct {
		method, target, auth string
		want                 int
	}{{"CONNECT", "example.com:443", "", 407}, {"CONNECT", "example.com:443", "Basic wrong", 407}, {"GET", "https://example.com/", auth(c), 405}, {"CONNECT", "example.com:80", auth(c), 403}, {"CONNECT", "example.com:22", auth(c), 403}} {
		r := httptest.NewRequest(test.method, test.target, nil)
		r.Header.Set("Proxy-Authorization", test.auth)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != test.want {
			t.Errorf("%s %s: got %d want %d", test.method, test.target, w.Code, test.want)
		}
	}
	if called.Load() != 0 {
		t.Fatal("invalid request reached dialer")
	}
}

func makeChain(t *testing.T, destination *httptest.Server) (config.Config, *httptest.Server) {
	t.Helper()
	dir := t.TempDir()
	if e := pki.Init(dir, "127.0.0.1", "127.0.0.1:443", 443); e != nil {
		t.Fatal(e)
	}
	c, e := config.Load(filepath.Join(dir, "server.json"), "server")
	if e != nil {
		t.Fatal(e)
	}
	h := Server(c)
	t.Cleanup(h.Close)
	h.connect = func(ctx context.Context, address string) (net.Conn, *bufio.Reader, error) {
		if address != "example.com:443" {
			return nil, nil, fmt.Errorf("unexpected destination")
		}
		conn, e := (&net.Dialer{}).DialContext(ctx, "tcp", destination.Listener.Addr().String())
		if e != nil {
			return nil, nil, e
		}
		return conn, bufio.NewReader(conn), nil
	}
	pair, e := tls.LoadX509KeyPair(c.CertFile, c.KeyFile)
	if e != nil {
		t.Fatal(e)
	}
	s := httptest.NewUnstartedServer(h)
	s.TLS = &tls.Config{Certificates: []tls.Certificate{pair}, MinVersion: tls.VersionTLS12}
	s.StartTLS()
	t.Cleanup(s.Close)
	host, port, _ := net.SplitHostPort(s.Listener.Addr().String())
	c.Kind = "client"
	c.Host = host
	c.Port, _ = strconv.Atoi(port)
	c.Listen = "127.0.0.1:17890"
	b, e := os.ReadFile(filepath.Join(dir, "ca.pem"))
	if e != nil {
		t.Fatal(e)
	}
	c.CA = string(b)
	return c, s
}
func localHTTPClient(t *testing.T, c config.Config, destination *httptest.Server) (*http.Client, *Handler) {
	t.Helper()
	h, e := Client(c)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(h.Close)
	s := httptest.NewServer(h)
	t.Cleanup(s.Close)
	u, _ := url.Parse(s.URL)
	pool := x509.NewCertPool()
	pool.AddCert(destination.Certificate())
	tr := &http.Transport{Proxy: http.ProxyURL(u), TLSClientConfig: &tls.Config{RootCAs: pool}, DisableKeepAlives: true}
	t.Cleanup(tr.CloseIdleConnections)
	return &http.Client{Transport: tr, Timeout: 10 * time.Second}, h
}
func TestEncryptedTwoHopStreamingAndRange(t *testing.T) {
	body := strings.Repeat("model-data-", 200000)
	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Proxy-Authorization") != "" {
			t.Error("proxy credentials leaked to destination")
		}
		if r.URL.Path == "/stream" {
			for i := 0; i < 7; i++ {
				fmt.Fprint(w, "chunk\n")
				w.(http.Flusher).Flush()
				time.Sleep(350 * time.Millisecond)
			}
			return
		}
		http.ServeContent(w, r, "model.bin", time.Now(), strings.NewReader(body))
	}))
	defer origin.Close()
	c, _ := makeChain(t, origin)
	c.IdleSeconds = 1
	client, _ := localHTTPClient(t, c, origin)
	for _, test := range []struct {
		path, rangeHeader string
		want              int
		body              string
	}{{"/model", "", 200, body}, {"/model", "bytes=100-199", 206, body[100:200]}, {"/stream", "", 200, strings.Repeat("chunk\n", 7)}} {
		r, _ := http.NewRequest("GET", "https://example.com"+test.path, nil)
		if test.rangeHeader != "" {
			r.Header.Set("Range", test.rangeHeader)
		}
		resp, e := client.Do(r)
		if e != nil {
			t.Fatal(e)
		}
		got, e := io.ReadAll(resp.Body)
		resp.Body.Close()
		if e != nil {
			t.Fatal(e)
		}
		if resp.StatusCode != test.want || string(got) != test.body {
			t.Fatalf("tunnel corrupted %s response: status=%d bytes=%d", test.path, resp.StatusCode, len(got))
		}
	}
}
func TestRejectWrongCredentialsAndCA(t *testing.T) {
	origin := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "ok") }))
	defer origin.Close()
	c, _ := makeChain(t, origin)
	t.Run("credentials", func(t *testing.T) {
		c.Password = "wrong"
		client, _ := localHTTPClient(t, c, origin)
		if r, e := client.Get("https://example.com"); e == nil {
			r.Body.Close()
			t.Fatal("wrong credentials accepted")
		}
	})
	t.Run("CA", func(t *testing.T) {
		dir := t.TempDir()
		if e := pki.Init(dir, "127.0.0.1", "127.0.0.1:443", 443); e != nil {
			t.Fatal(e)
		}
		b, _ := os.ReadFile(filepath.Join(dir, "ca.pem"))
		c.CA = string(b)
		client, _ := localHTTPClient(t, c, origin)
		if r, e := client.Get("https://example.com"); e == nil {
			r.Body.Close()
			t.Fatal("wrong CA accepted")
		}
	})
}
func TestConnectionLimitAndShutdown(t *testing.T) {
	c := serverConfig()
	c.MaxConnections = 1
	h := Server(c)
	defer h.Close()
	h.connect = func(context.Context, string) (net.Conn, *bufio.Reader, error) {
		a, b := net.Pipe()
		t.Cleanup(func() { b.Close() })
		return a, bufio.NewReader(a), nil
	}
	s := httptest.NewServer(h)
	defer s.Close()
	conn, e := net.Dial("tcp", s.Listener.Addr().String())
	if e != nil {
		t.Fatal(e)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	fmt.Fprintf(conn, "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nProxy-Authorization: %s\r\n\r\n", auth(c))
	br := bufio.NewReader(conn)
	line, e := br.ReadString('\n')
	if e != nil || !strings.Contains(line, "200") {
		t.Fatalf("first CONNECT failed: %s %v", line, e)
	}
	br.ReadString('\n')
	r := httptest.NewRequest("CONNECT", "example.com:443", nil)
	r.Header.Set("Proxy-Authorization", auth(c))
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	if w.Code != 503 {
		t.Fatalf("limit not enforced: %d", w.Code)
	}
	h.Close()
	if _, e = br.ReadByte(); e == nil {
		t.Fatal("shutdown left tunnel open")
	}
	deadline := time.Now().Add(time.Second)
	for len(h.sem) != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if len(h.sem) != 0 {
		t.Fatal("connection slot leaked")
	}
}
