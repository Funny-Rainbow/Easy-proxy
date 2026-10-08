package manage

import (
	_ "embed"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

//go:embed server.sh
var serverScript string

//go:embed client.sh
var clientScript string

//go:embed client.ps1
var windowsScript string

func Run(client bool, args []string) error {
	exe, e := os.Executable()
	if e != nil {
		return e
	}
	var cmd *exec.Cmd
	if runtime.GOOS == "windows" {
		if !client {
			return errors.New("server management requires Linux with systemd")
		}
		f, e := os.CreateTemp("", "easy-proxy-*.ps1")
		if e != nil {
			return e
		}
		defer os.Remove(f.Name())
		if _, e = f.WriteString(windowsScript); e != nil {
			f.Close()
			return e
		}
		if e = f.Close(); e != nil {
			return e
		}
		translated := append([]string(nil), args...)
		for i, arg := range translated {
			if arg == "--config" {
				translated[i] = "-Config"
			}
		}
		cmd = exec.Command("powershell.exe", append([]string{"-NoProfile", "-ExecutionPolicy", "Bypass", "-File", f.Name(), "-Binary", exe}, translated...)...)
	} else {
		if runtime.GOOS != "linux" {
			return errors.New("service management supports Linux and Windows")
		}
		script := serverScript
		if client {
			script = clientScript
		}
		cmd = exec.Command("bash", append([]string{"-s", "--", exe}, args...)...)
		cmd.Stdin = strings.NewReader(script)
	}
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func DefaultClientConfig() string {
	if runtime.GOOS == "windows" {
		return filepath.Join(os.Getenv("LOCALAPPDATA"), "Easy-proxy", "client.json")
	}
	dir := os.Getenv("XDG_CONFIG_HOME")
	if dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "easy-proxy", "client.json")
}
