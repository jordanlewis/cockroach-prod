This is a simple Google App Engine project that exists to trigger daily tests
on CircleCI.

Deploy it by running the ./deploy.sh script in this directory. You'll need to
have the Google App Engine SDK for Go installed
(`brew install app-engine-go-64`) and a valid CircleCI API key exported to the
environment variable `CIRCLE_CI_TOKEN`. You can get a CircleCI API key
[here](https://circleci.com/account/api).
