// The sample function of runtimes-verify.sh for the go runtime. The three samples (python, node, go) answer alike.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"syscall"
	"time"

	"github.com/OpenViCloud/titan-function-runtimes/function"
)

func kernel() string {
	var u syscall.Utsname
	syscall.Uname(&u)
	var b strings.Builder
	for _, c := range u.Release {
		if c == 0 {
			break
		}
		b.WriteByte(byte(c))
	}
	return b.String()
}

func canWrite(file string) string {
	f, err := os.Create(file)
	if err != nil {
		return "denied"
	}
	f.Close()
	return "ok"
}

func handler(ctx context.Context, e function.Event) (function.Response, error) {
	if e.Trigger == "cron" {
		b, _ := json.Marshal(e)
		fmt.Println("CRON-EVENT " + string(b))
		if os.Getenv("SAMPLE_CRON") == "fail" {
			return function.Response{}, errors.New("sample cron failure")
		}
		return function.Response{}, nil
	}
	if e.Path == "/fail" {
		return function.Response{}, errors.New("sample failure")
	}
	info, _ := function.FromContext(ctx)
	left := "none"
	if d, ok := ctx.Deadline(); ok {
		left = fmt.Sprint(time.Until(d).Milliseconds())
	}
	body := fmt.Sprintf("hello go kernel=%s uid=%d fnwrite=%s tmpwrite=%s path=%s fn=%s version=%s left=%s",
		kernel(), os.Getuid(), canWrite("/function/x"), canWrite("/tmp/x"), e.Path, info.FunctionID, info.VersionID, left)
	return function.Response{StatusCode: 201, Headers: map[string]string{"x-runtime": "go"}, Body: body}, nil
}

func main() { function.Start(handler) }
