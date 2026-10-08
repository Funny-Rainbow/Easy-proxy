package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInvalidClientAndSchema(t *testing.T) {
	c := Config{Schema: 1, Kind: "client", Host: "203.0.113.1", Port: 443, Listen: "127.0.0.1:17890", Username: "u", Password: "p", CA: "ca", MaxConnections: 1, IdleSeconds: 1}
	if e := c.Validate("client"); e != nil {
		t.Fatal(e)
	}
	for _, listen := range []string{"0.0.0.0:17890", "localhost:17890", "192.168.1.1:17890", "[::]:17890", "127.0.0.1:0", "127.0.0.1:99999"} {
		bad := c
		bad.Listen = listen
		if e := bad.Validate("client"); e == nil {
			t.Errorf("accepted %s", listen)
		}
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "client.json")
	c.Schema = 2
	if e := Write(path, c, 0600); e != nil {
		t.Fatal(e)
	}
	if _, e := Load(path, "client"); e == nil {
		t.Fatal("unknown schema accepted")
	}
	if e := os.WriteFile(path, []byte(`{"schema":1,"unknown":true}`), 0600); e != nil {
		t.Fatal(e)
	}
	if _, e := Load(path, "client"); e == nil {
		t.Fatal("unknown field accepted")
	}
}
