package pki

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"errors"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"

	"github.com/Funny-Rainbow/Easy-proxy/internal/config"
)

func Secret() (string, error) {
	b := make([]byte, 32)
	_, e := rand.Read(b)
	return hex.EncodeToString(b), e
}
func serial() *big.Int {
	n, e := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if e != nil {
		panic(e)
	}
	return n
}
func certPEM(b []byte) []byte { return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: b}) }
func keyPEM(k ed25519.PrivateKey) ([]byte, error) {
	b, e := x509.MarshalPKCS8PrivateKey(k)
	if e != nil {
		return nil, e
	}
	return pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: b}), nil
}

func Init(dir, host, listen string, port int) error {
	if net.ParseIP(host) == nil {
		return errors.New("host must be a literal server IP")
	}
	password, e := Secret()
	if e != nil {
		return e
	}
	c := config.Config{Schema: config.Schema, Kind: "server", Host: host, Port: port, Listen: listen, Username: "proxyuser", Password: password, CertFile: filepath.Join(dir, "server.pem"), KeyFile: filepath.Join(dir, "server-key.pem"), MaxConnections: 512, IdleSeconds: 300}
	if e = c.Validate("server"); e != nil {
		return e
	}
	// Refuse any existing state: incomplete installs must be inspected rather than
	// silently replacing the CA clients already trust.
	for _, name := range []string{"server.json", "ca.pem", "ca-key.pem", "server.pem", "server-key.pem"} {
		if _, e := os.Stat(filepath.Join(dir, name)); !os.IsNotExist(e) {
			return errors.New("existing state found; refusing to replace certificates or credentials")
		}
	}
	pub, key, e := ed25519.GenerateKey(rand.Reader)
	if e != nil {
		return e
	}
	now := time.Now()
	ca := &x509.Certificate{SerialNumber: serial(), Subject: pkix.Name{CommonName: "Easy-proxy private CA"}, NotBefore: now.Add(-time.Hour), NotAfter: now.AddDate(10, 0, 0), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign | x509.KeyUsageCRLSign}
	b, e := x509.CreateCertificate(rand.Reader, ca, ca, pub, key)
	if e != nil {
		return e
	}
	k, e := keyPEM(key)
	if e != nil {
		return e
	}
	if e = config.WriteBytes(filepath.Join(dir, "ca-key.pem"), k, 0600); e != nil {
		return e
	}
	if e = config.WriteBytes(filepath.Join(dir, "ca.pem"), certPEM(b), 0644); e != nil {
		return e
	}
	if e = Renew(dir, host); e != nil {
		return e
	}
	return config.Write(filepath.Join(dir, "server.json"), c, 0640)
}

func Renew(dir, host string) error {
	caBytes, e := os.ReadFile(filepath.Join(dir, "ca.pem"))
	if e != nil {
		return e
	}
	block, _ := pem.Decode(caBytes)
	if block == nil {
		return errors.New("invalid CA")
	}
	ca, e := x509.ParseCertificate(block.Bytes)
	if e != nil {
		return e
	}
	k, e := os.ReadFile(filepath.Join(dir, "ca-key.pem"))
	if e != nil {
		return e
	}
	block, _ = pem.Decode(k)
	if block == nil {
		return errors.New("invalid CA key")
	}
	caKey, e := x509.ParsePKCS8PrivateKey(block.Bytes)
	if e != nil {
		return e
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return errors.New("invalid server IP")
	}
	pub, key, e := ed25519.GenerateKey(rand.Reader)
	if e != nil {
		return e
	}
	now := time.Now()
	expiry := now.AddDate(1, 0, 0)
	if ca.NotAfter.Before(expiry) {
		expiry = ca.NotAfter
	}
	if expiry.Before(now.Add(30 * 24 * time.Hour)) {
		return errors.New("CA expires within 30 days; create and distribute a new CA")
	}
	leaf := &x509.Certificate{SerialNumber: serial(), Subject: pkix.Name{CommonName: "Easy-proxy"}, IPAddresses: []net.IP{ip}, NotBefore: now.Add(-time.Hour), NotAfter: expiry, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	b, e := x509.CreateCertificate(rand.Reader, leaf, ca, pub, caKey)
	if e != nil {
		return e
	}
	k, e = keyPEM(key)
	if e != nil {
		return e
	}
	// The manager stops/restarts the daemon around this operation so a running
	// process never reloads a half-updated pair.
	if e = config.WriteBytes(filepath.Join(dir, "server-key.pem"), k, 0640); e != nil {
		return e
	}
	return config.WriteBytes(filepath.Join(dir, "server.pem"), certPEM(b), 0644)
}

func Export(dir, output, listen string) error {
	c, e := config.Load(filepath.Join(dir, "server.json"), "server")
	if e != nil {
		return e
	}
	b, e := os.ReadFile(filepath.Join(dir, "ca.pem"))
	if e != nil {
		return e
	}
	c.Kind = "client"
	c.Listen = listen
	c.CA = string(b)
	c.CertFile = ""
	c.KeyFile = ""
	c.MaxConnections = 128
	if e = c.Validate("client"); e != nil {
		return e
	}
	return config.Write(output, c, 0600)
}
