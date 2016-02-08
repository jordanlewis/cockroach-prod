#!/usr/bin/env python2.7

import argparse
import json
import os
import sys
import urllib
import urllib2


def send(server, data):
    response = "None"
    try:
        f = urllib2.urlopen(server + '/result/add/json/', urllib.urlencode(data))
    except urllib2.HTTPError as e:
        print str(e)
        print e.read()
        return
    response = f.read()
    f.close()
    print "Server (%s) response: %s\n" % (server, response)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Munge and POST benchstat json to a codespeed server')
    parser.add_argument('json', metavar="JSON FILE", nargs="?", help='json file from go\'s benchstat')
    parser.add_argument('-p', '--project', required=True)
    parser.add_argument('-s', '--server', required=True, metavar="CODESPEED_BASEPATH")
    parser.add_argument('-r', '--revision', required=True, metavar='SHA')
    parser.add_argument('-b', '--branch', default="default")
    parser.add_argument('-e', '--env', default="default")

    args = parser.parse_args()

    meta = {
        "commitid": args.revision,
        "project": args.project,
        "branch": args.branch,
        "environment": args.env,
        'units_title': 'Time',
    }

    if args.json:
        with open(args.json, 'rb') as fp:
            data = json.load(fp)
    else:
        data = json.load(sys.stdin)

    for i in data:
        i.update(meta)

        i["result_value"] = i["mean"]
        del i["mean"]

        i["executable"] = os.path.basename(i["config"])
        del i["config"]

        if i["units"].startswith('allocs'):
            i['units_title'] = 'Allocations'
        if i["units"].startswith('B/'):
            i['units_title'] = 'Memory'

    send(args.server, {'json': json.dumps(data)})
