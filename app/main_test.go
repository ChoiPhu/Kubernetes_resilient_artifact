package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func request(app http.Handler, method, path string) *httptest.ResponseRecorder {
	response := httptest.NewRecorder()
	app.ServeHTTP(response, httptest.NewRequest(method, path, nil))
	return response
}

func TestIdentity(t *testing.T) {
	for _, tc := range []struct {
		name string
		pod  string
		node string
		want string
	}{
		{"downward API", "demo-api-abc", "resilience-lab-worker2", "pod: demo-api-abc\nnode: resilience-lab-worker2\nversion: v2\n"},
		{"local defaults", "", "", "pod: local\nnode: local\nversion: v2\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("POD_NAME", tc.pod)
			t.Setenv("NODE_NAME", tc.node)
			app := newApplication(time.Now)
			app.version = "v2"
			response := request(app, http.MethodGet, "/")
			if response.Code != http.StatusOK || response.Body.String() != tc.want {
				t.Fatalf("got status %d, body %q; want 200, %q", response.Code, response.Body.String(), tc.want)
			}
			if got := response.Header().Get("Content-Type"); got != "text/plain; charset=utf-8" {
				t.Errorf("Content-Type = %q", got)
			}
		})
	}
}

func TestExactRoutesAndMethods(t *testing.T) {
	app := newApplication(time.Now)
	for _, path := range []string{"/", "/readyz", "/livez"} {
		for _, method := range []string{http.MethodHead, http.MethodPost, http.MethodPut, http.MethodDelete, http.MethodOptions, http.MethodPatch} {
			t.Run(method+" "+path, func(t *testing.T) {
				response := request(app, method, path)
				if response.Code != http.StatusMethodNotAllowed || response.Header().Get("Allow") != http.MethodGet {
					t.Fatalf("got status %d, Allow %q; want 405, GET", response.Code, response.Header().Get("Allow"))
				}
			})
		}
	}
	for _, path := range []string{"/missing", "/readyz/", "/livez/", "/work", "/admin/ready"} {
		for _, method := range []string{http.MethodGet, http.MethodPost} {
			t.Run(method+" "+path, func(t *testing.T) {
				if response := request(app, method, path); response.Code != http.StatusNotFound {
					t.Fatalf("got status %d; want 404", response.Code)
				}
			})
		}
	}
}

func TestReadinessAndLiveness(t *testing.T) {
	start := time.Unix(100, 0)
	now := start
	app := newApplication(func() time.Time { return now })
	for _, tc := range []struct {
		name     string
		elapsed  time.Duration
		shutdown bool
		ready    int
	}{
		{"starting", 0, false, http.StatusServiceUnavailable},
		{"before delay", 3*time.Second - time.Nanosecond, false, http.StatusServiceUnavailable},
		{"at delay", 3 * time.Second, false, http.StatusOK},
		{"running", time.Hour, false, http.StatusOK},
		{"shutting down", time.Hour, true, http.StatusServiceUnavailable},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now = start.Add(tc.elapsed)
			app.shuttingDown.Store(tc.shutdown)
			ready := request(app, http.MethodGet, "/readyz")
			if ready.Code != tc.ready {
				t.Errorf("readiness status = %d; want %d", ready.Code, tc.ready)
			}
			if ready.Code == http.StatusOK && ready.Body.String() != "ok\n" {
				t.Errorf("readiness body = %q; want ok", ready.Body.String())
			}
			live := request(app, http.MethodGet, "/livez")
			if live.Code != http.StatusOK || live.Body.String() != "ok\n" {
				t.Errorf("liveness = %d %q; want 200 ok", live.Code, live.Body.String())
			}
		})
	}
}
