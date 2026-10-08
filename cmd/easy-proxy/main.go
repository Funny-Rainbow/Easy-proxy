package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"flag"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"github.com/Funny-Rainbow/Easy-proxy/internal/config"
	"github.com/Funny-Rainbow/Easy-proxy/internal/manage"
	"github.com/Funny-Rainbow/Easy-proxy/internal/pki"
	"github.com/Funny-Rainbow/Easy-proxy/internal/proxy"
)

var version = "dev"

func main() {
	if e := run(os.Args[1:]); e != nil {
		fmt.Fprintln(os.Stderr, "easy-proxy:", e)
		os.Exit(1)
	}
}
func run(args []string) error {
	if len(args) == 0 {
		return help()
	}
	command, args := args[0], args[1:]
	switch command {
	case "version":
		fmt.Println(version)
		return nil
	case "help", "--help", "-h":
		return help()
	case "install", "upgrade", "rollback", "uninstall", "status", "doctor", "restart", "export-client", "rotate-password", "renew-cert":
		return manage.Run(false, append([]string{command}, args...))
	case "client":
		if len(args) > 0 && args[0] != "" && args[0] != "run" && args[0][0] != '-' {
			return manage.Run(true, args)
		}
		if len(args) > 0 && args[0] == "run" {
			args = args[1:]
		}
		return serve("client", args)
	case "server":
		return serve("server", args)
	case "init", "pki-export", "pki-renew", "pki-rotate":
		f := flag.NewFlagSet(command, flag.ContinueOnError)
		dir := f.String("dir", "/etc/easy-proxy", "server state directory")
		host := f.String("host", "", "server IP")
		port := f.Int("port", 443, "server TLS port")
		listen := f.String("listen", "", "listen address")
		out := f.String("out", "client.json", "client configuration output")
		if e := f.Parse(args); e != nil {
			return e
		}
		if f.NArg() != 0 {
			return errors.New("unexpected positional arguments")
		}
		abs, e := filepath.Abs(*dir)
		if e != nil {
			return e
		}
		switch command {
		case "init":
			if *listen == "" {
				*listen = net.JoinHostPort("0.0.0.0", strconv.Itoa(*port))
			}
			e = pki.Init(abs, *host, *listen, *port)
		case "pki-export":
			if *listen == "" {
				*listen = "127.0.0.1:17890"
			}
			e = pki.Export(abs, *out, *listen)
		case "pki-renew":
			c, err := config.Load(filepath.Join(abs, "server.json"), "server")
			if err != nil {
				return err
			}
			e = pki.Renew(abs, c.Host)
		case "pki-rotate":
			c, err := config.Load(filepath.Join(abs, "server.json"), "server")
			if err != nil {
				return err
			}
			c.Password, e = pki.Secret()
			if e == nil {
				e = config.Write(filepath.Join(abs, "server.json"), c, 0640)
			}
		}
		return e
	case "check", "probe":
		f := flag.NewFlagSet(command, flag.ContinueOnError)
		kind := f.String("kind", "client", "server or client")
		path := f.String("config", manage.DefaultClientConfig(), "configuration path")
		checkListen := f.Bool("listen", false, "also check listener availability")
		if e := f.Parse(args); e != nil {
			return e
		}
		if f.NArg() != 0 {
			return errors.New("unexpected positional arguments")
		}
		c, e := config.Load(*path, *kind)
		if e != nil {
			return e
		}
		if command == "probe" {
			if c.Kind != "client" {
				return errors.New("probe requires client config")
			}
			return probe(c)
		}
		if c.Kind == "client" {
			h, e := proxy.Client(c)
			if e != nil {
				return e
			}
			h.Close()
		} else {
			pair, e := tls.LoadX509KeyPair(c.CertFile, c.KeyFile)
			if e != nil {
				return e
			}
			leaf, e := x509.ParseCertificate(pair.Certificate[0])
			if e != nil {
				return e
			}
			if e = leaf.VerifyHostname(c.Host); e != nil {
				return e
			}
			if time.Now().Before(leaf.NotBefore) || time.Now().After(leaf.NotAfter) {
				return errors.New("server certificate is not currently valid")
			}
			fmt.Println("Certificate expires:", leaf.NotAfter.UTC().Format(time.RFC3339))
			if time.Until(leaf.NotAfter) < 30*24*time.Hour {
				fmt.Println("Certificate expires within 30 days; run renew-cert")
			}
			b, e := os.ReadFile(filepath.Join(filepath.Dir(*path), "ca.pem"))
			if e != nil {
				return e
			}
			block, _ := pem.Decode(b)
			if block == nil {
				return errors.New("invalid CA")
			}
			ca, e := x509.ParseCertificate(block.Bytes)
			if e != nil {
				return e
			}
			roots := x509.NewCertPool()
			roots.AddCert(ca)
			if _, e = leaf.Verify(x509.VerifyOptions{Roots: roots, DNSName: c.Host}); e != nil {
				return e
			}
		}
		if *checkListen {
			l, e := net.Listen("tcp", c.Listen)
			if e != nil {
				return e
			}
			l.Close()
		}
		fmt.Println("Configuration OK:", c.Kind)
		return nil
	default:
		return fmt.Errorf("unknown command %q; run help", command)
	}
}

func serve(kind string, args []string) error {
	f := flag.NewFlagSet(kind, flag.ContinueOnError)
	defaultPath := manage.DefaultClientConfig()
	if kind == "server" {
		defaultPath = "/etc/easy-proxy/server.json"
	}
	path := f.String("config", defaultPath, "configuration file")
	if e := f.Parse(args); e != nil {
		return e
	}
	if f.NArg() != 0 {
		return errors.New("unexpected positional arguments")
	}
	c, e := config.Load(*path, kind)
	if e != nil {
		return e
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	return proxy.Run(ctx, c)
}

func probe(c config.Config) error {
	h, e := proxy.Client(c)
	if e != nil {
		return e
	}
	defer h.Close()
	l, e := net.Listen("tcp", "127.0.0.1:0")
	if e != nil {
		return e
	}
	s := &http.Server{Handler: h, ReadHeaderTimeout: 10 * time.Second}
	defer s.Close()
	go s.Serve(l)
	u, _ := url.Parse("http://" + l.Addr().String())
	t := &http.Transport{Proxy: http.ProxyURL(u), TLSHandshakeTimeout: 15 * time.Second}
	defer t.CloseIdleConnections()
	client := &http.Client{Transport: t, Timeout: 45 * time.Second}
	var failures []error
	for _, test := range []struct {
		url    string
		status int
	}{{"https://api.github.com", 200}, {"https://huggingface.co", 200}, {"https://registry-1.docker.io/v2/", 401}} {
		r, e := client.Get(test.url)
		if e != nil {
			failures = append(failures, fmt.Errorf("%s: %w", test.url, e))
			continue
		}
		r.Body.Close()
		if r.StatusCode != test.status {
			failures = append(failures, fmt.Errorf("%s: got %d, expected %d", test.url, r.StatusCode, test.status))
			continue
		}
		fmt.Printf("PASS %s %d\n", test.url, r.StatusCode)
	}
	return errors.Join(failures...)
}

func help() error {
	fmt.Print(`Easy-proxy: encrypted CONNECT proxy with a local loopback client.

Server (Linux/systemd, root):
  install --host SERVER_IP [--port 443] [--listen 0.0.0.0:443]
  upgrade --version vX.Y.Z [--base-url HTTPS_RELEASE_BASE]
  rollback | status | doctor | restart
  export-client --out /secure/path/client.json [--listen 127.0.0.1:17890]
  rotate-password | renew-cert
  uninstall [--purge]

Client (Linux/Windows, current user):
  client install --config /path/client.json
  client start | stop | status | uninstall
  client run [--config /path/client.json]
  probe [--config /path/client.json]

Advanced / development:
  server --config /path/server.json
  init --dir DIR --host SERVER_IP [--port 443] [--listen ADDRESS]
  check --kind server|client --config PATH [--listen]
  version

See README.md for shell enable/disable, certificates, and Docker configuration.
`)
	return nil
}
