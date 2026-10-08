package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
)

const Schema = 1

type Config struct {
	Schema         int    `json:"schema"`
	Kind           string `json:"kind"`
	Listen         string `json:"listen"`
	Host           string `json:"host"`
	Port           int    `json:"port"`
	Username       string `json:"username"`
	Password       string `json:"password"`
	CA             string `json:"ca_pem,omitempty"`
	CertFile       string `json:"cert_file,omitempty"`
	KeyFile        string `json:"key_file,omitempty"`
	MaxConnections int    `json:"max_connections"`
	IdleSeconds    int    `json:"idle_seconds"`
}

func Load(path, kind string) (Config, error) {
	var c Config
	f, err := os.Open(path)
	if err != nil {
		return c, err
	}
	defer f.Close()
	d := json.NewDecoder(io.LimitReader(f, 1<<20))
	d.DisallowUnknownFields()
	if err = d.Decode(&c); err != nil {
		return c, fmt.Errorf("invalid config: %w", err)
	}
	var extra any
	if err = d.Decode(&extra); err != io.EOF {
		return c, errors.New("config contains trailing data")
	}
	return c, c.Validate(kind)
}

func (c Config) Validate(kind string) error {
	if kind != "client" && kind != "server" {
		return errors.New("kind must be server or client")
	}
	if c.Schema != Schema {
		return fmt.Errorf("unsupported config schema %d (supported: %d)", c.Schema, Schema)
	}
	if c.Kind != kind {
		return fmt.Errorf("expected %s config", kind)
	}
	if c.Host == "" || c.Port < 1 || c.Port > 65535 {
		return errors.New("valid host and port required")
	}
	if net.ParseIP(c.Host) == nil {
		return errors.New("v1 requires a server IP address")
	}
	if c.Username == "" || c.Password == "" {
		return errors.New("credentials required")
	}
	if c.MaxConnections < 1 || c.MaxConnections > 100000 || c.IdleSeconds < 1 {
		return errors.New("invalid connection limits")
	}
	h, p, err := net.SplitHostPort(c.Listen)
	if err != nil {
		return errors.New("listen must be host:port")
	}
	port, err := strconv.Atoi(p)
	if err != nil || port < 1 || port > 65535 {
		return errors.New("invalid listen port")
	}
	if kind == "client" {
		ip := net.ParseIP(h)
		if ip == nil || !ip.IsLoopback() {
			return errors.New("client must listen on a literal loopback address")
		}
		if c.CA == "" {
			return errors.New("client CA required")
		}
	} else if c.CertFile == "" || c.KeyFile == "" {
		return errors.New("server certificate and key required")
	}
	return nil
}

// Write replaces one file atomically. A same-directory temporary file prevents
// partially written credentials after interruption.
func Write(path string, value any, mode os.FileMode) error {
	b, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return WriteBytes(path, append(b, '\n'), mode)
}

func WriteBytes(path string, b []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".easy-proxy-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if err = f.Chmod(mode); err == nil {
		_, err = f.Write(b)
	}
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(f.Name(), path)
}
