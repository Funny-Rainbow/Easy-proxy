package pki

import (
	"crypto/tls"
	"crypto/x509"
	"os"
	"path/filepath"
	"testing"

	"github.com/Funny-Rainbow/Easy-proxy/internal/config"
)

func TestInitExportRenewAndRefuseOverwrite(t *testing.T) {
	dir := t.TempDir()
	if e := Init(dir, "203.0.113.1", "0.0.0.0:8443", 8443); e != nil {
		t.Fatal(e)
	}
	ca, _ := os.ReadFile(filepath.Join(dir, "ca.pem"))
	key, _ := os.ReadFile(filepath.Join(dir, "ca-key.pem"))
	if e := Init(dir, "203.0.113.1", "0.0.0.0:8443", 8443); e == nil {
		t.Fatal("existing state overwritten")
	}
	profile := filepath.Join(t.TempDir(), "client.json")
	if e := Export(dir, profile, "127.0.0.1:17890"); e != nil {
		t.Fatal(e)
	}
	c, e := config.Load(profile, "client")
	if e != nil {
		t.Fatal(e)
	}
	if c.CA != string(ca) || c.KeyFile != "" || c.Port != 8443 {
		t.Fatal("bad exported profile")
	}
	if e := Renew(dir, "203.0.113.1"); e != nil {
		t.Fatal(e)
	}
	newCA, _ := os.ReadFile(filepath.Join(dir, "ca.pem"))
	newKey, _ := os.ReadFile(filepath.Join(dir, "ca-key.pem"))
	if string(ca) != string(newCA) || string(key) != string(newKey) {
		t.Fatal("renewal changed CA")
	}
	pair, e := tls.LoadX509KeyPair(filepath.Join(dir, "server.pem"), filepath.Join(dir, "server-key.pem"))
	if e != nil {
		t.Fatal(e)
	}
	leaf, e := x509.ParseCertificate(pair.Certificate[0])
	if e != nil {
		t.Fatal(e)
	}
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(ca)
	if _, e = leaf.Verify(x509.VerifyOptions{Roots: pool, DNSName: "203.0.113.1"}); e != nil {
		t.Fatal(e)
	}
}
