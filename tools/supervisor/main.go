// Copyright 2015 The Cockroach Authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
// implied. See the License for the specific language governing
// permissions and limitations under the License. See the AUTHORS file
// for names of contributors.
//
// Author: Marc Berhault (marc@cockroachlabs.com)

// This program takes a list of addresses and a program name and monitors
// the program status on each address through supervisor.
// It exits once all addresses report a non-running program or an error.
// It outputs basic status per address to stdout.
//
// If --stop or --signal are specified, the program is first stop or sent
// a signal.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/kolo/xmlrpc"
)

var addrs = flag.String("addrs", "", "Comma-separated list of host:port")
var program = flag.String("program", "", "Program name (eg: cockroach or sql.test")
var stop = flag.Bool("stop", false, "Stop all processes first")
var signal = flag.Bool("signal", false, "Signal all processes first. Requires supervisor 3.2.0 (2015-11-30)")
var signalName = flag.String("signal_name", "TERM", "Signal name to send")

const sleepTime = time.Second * 30
const shortSleepTime = time.Second * 3

type processInfo struct {
	Name          string `xmlrpc:"name"`
	Group         string `xmlrpc:"group"`
	Description   string `xmlrpc:"description"`
	Start         int    `xmlrpc:"start"`
	Stop          int    `xmlrpc:"stop"`
	Now           int    `xmlrpc:"now"`
	State         int    `xmlrpc:"state"`
	StateName     string `xmlrpc:"statename"`
	SpawnErr      string `xmlrpc:"spawnerr"`
	ExitStatus    int    `xmlrpc:"exitstatus"`
	StdoutLogFile string `xmlrpc:"stdout_logfile"`
	StderrLogFile string `xmlrpc:"stderr_logfile"`
	PID           int    `xmlrpc:"pid"`
}

type supervisorInstance struct {
	host string
	err  error
	info processInfo
}

func (si *supervisorInstance) run() {
	client, err := xmlrpc.NewClient(fmt.Sprintf("http://%s/RPC2", si.host), nil)
	if err != nil {
		si.err = err
		log.Printf("%s: client error: %v", si.host, err)
		return
	}
	waitTime := sleepTime
	if *signal {
		err = client.Call("supervisor.signalProcess", []interface{}{*program, *signalName}, nil)
		log.Printf("%s: signalProcess. err=%v", si.host, err)
		waitTime = shortSleepTime
	}
	if *stop {
		err = client.Call("supervisor.stopProcess", []interface{}{*program, true}, nil)
		log.Printf("%s: stopProcess. err=%v", si.host, err)
		waitTime = shortSleepTime
	}

	for {
		si.err = client.Call("supervisor.getProcessInfo", *program, &si.info)
		if si.err != nil {
			log.Printf("%s: call error: %v", si.host, err)
			break
		}
		log.Printf("%s: %s", si.host, si.info.StateName)

		if si.info.State != 20 { /* 20=RUNNING */
			break
		}

		time.Sleep(waitTime)
	}
}

func (si supervisorInstance) String() string {
	if si.err != nil {
		return fmt.Sprintf("%s: error=%v", si.host, si.err)
	}
	status := "SUCCESS"
	if si.info.ExitStatus != 0 {
		status = fmt.Sprintf("FAILED(%s with %d)", si.info.StateName, si.info.ExitStatus)
	}
	duration := time.Duration(si.info.Stop-si.info.Start) * time.Second

	return fmt.Sprintf("%s %s: %s in %s", si.info.Name, si.host, status, duration)
}

func (si supervisorInstance) success() bool {
	return si.err == nil && si.info.ExitStatus == 0
}

func main() {
	flag.Parse()

	if *program == "" {
		log.Fatal("--program is required")
	}
	if *addrs == "" {
		log.Fatal("--addrs must specify at least one address")
	}

	parsedAddrs := strings.Split(*addrs, ",")

	var wg sync.WaitGroup
	instances := []*supervisorInstance{}
	for _, addr := range parsedAddrs {
		wg.Add(1)
		i := &supervisorInstance{
			host: addr,
		}
		instances = append(instances, i)
		go func(si *supervisorInstance) {
			si.run()
			wg.Done()
		}(i)
	}

	wg.Wait()
	exitCode := 0
	for _, i := range instances {
		fmt.Println(i.String())
		if !i.success() {
			exitCode++
		}
	}
	os.Exit(exitCode)
}
