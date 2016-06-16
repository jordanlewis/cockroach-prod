package server

import (
	"fmt"
	"net/http"
	"os"
	"strings"

	"google.golang.org/appengine"
	"google.golang.org/appengine/log"
	"google.golang.org/appengine/urlfetch"
)

func init() {
	http.HandleFunc("/trigger", triggerHandler)
}

func getToken() string {
	return os.Getenv("CIRCLE_CI_TOKEN")
}

func triggerHandler(w http.ResponseWriter, r *http.Request) {
	ctx := appengine.NewContext(r)
	client := urlfetch.Client(ctx)
	token := getToken()
	log.Debugf(ctx, "https://circleci.com/api/v1/project/cockroachdb/cockroach-prod/tree/master?circle-token="+token)
	resp, err := client.Post("https://circleci.com/api/v1/project/cockroachdb/cockroach-prod/tree/master?circle-token="+token,
		"application/json", strings.NewReader("{\"build_parameters\": {\"RUN_NIGHTLY_BUILD\": \"true\"}}"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	fmt.Fprint(w, "HTTP POST to CircleCI returned status %v", resp.Status)
}
