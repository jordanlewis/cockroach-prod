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
// Author: Tobias Schottdorf

package terrafarm

import (
	"fmt"

	"github.com/cockroachdb/cockroach/util"
)

// A Farmer sets up and manipulates a test cluster via terraform.
type Farmer struct {
	Debug          bool
	Cwd            string
	Args           []string
	KeyName        string
	nodes, writers []string
}

func (f *Farmer) Refresh() {
	f.nodes = f.output("instances")
	f.writers = f.output("example_block_writer")
}

// Nodes returns a slice of provisioned nodes' host names.
func (f *Farmer) Nodes() (hosts []string) {
	return append(hosts, f.nodes...)
}

// Writers returns a slice of provisioned block writers' host names.
func (f *Farmer) Writers() (hosts []string) {
	return append(hosts, f.writers...)
}

// NumNodes returns the number of nodes.
func (f *Farmer) NumNodes() int {
	return len(f.Nodes())
}

// NumWriters returns the number of block writers.
func (f *Farmer) NumWriters() int {
	return len(f.Writers())
}

// Add provisions the given number of nodes and block writers, respectively.
func (f *Farmer) Add(nodes, writers int) error {
	nodes += f.NumNodes()
	writers += f.NumWriters()
	args := []string{fmt.Sprintf("--var=num_instances=%d", nodes),
		fmt.Sprintf("--var=example_block_writer_instances=%d", writers)}

	if nodes == 0 && writers == 0 {
		return f.runErr("terraform", f.appendDefaults(append([]string{"destroy", "--force"}, args...))...)
	}
	return f.apply(args...)
}

// Destroy tears down the cluster.
func (f *Farmer) Destroy() error {
	return f.Add(-f.NumNodes(), -f.NumWriters())
}

// Exec executes the given command on the i-th node, returning (in that order)
// stdout, stderr and an error.
func (f *Farmer) Exec(i int, cmd string) error {
	stdout, stderr, err := f.ssh("ubuntu", f.Nodes()[i], f.defaultKeyFile(), cmd)
	if err != nil {
		return fmt.Errorf("failed: %s: %s\nstdout:\n%s\nstderr:\n%s", cmd, err, stdout, stderr)
	}
	return nil
}

// ConnString returns a connection string to pass to client.Open().
func (f *Farmer) ConnString(i int) string {
	// TODO(tschottdorf,mberhault): TLS all the things!
	return "rpc://" + "root" + "@" +
		util.EnsureHostPort(f.Nodes()[i]) +
		"?certs=" + "certswhocares"
}

// Assert verifies that the cluster state is as expected (i.e. no unexpected
// restarts or node deaths occurred). Tests can call this periodically to
// ascertain cluster health.
// TODO(tschottdorf): unimplemented.
func (f *Farmer) Assert(t util.Tester) {}

// AssertAndStop performs the same test as Assert but then proceeds to
// dismantle the cluster.
func (f *Farmer) AssertAndStop(t util.Tester) {
	if err := f.Destroy(); err != nil {
		t.Fatal(err)
	}
}

// Kill terminates the cockroach process running on the given node number.
// The given integer must be in the range [0,NumNodes()-1].
func (f *Farmer) Kill(i int) error {
	return f.Exec(i, "pkill -9 cockroach")
}

// Restart terminates the cockroach process running on the given node
// number, unless it is already stopped, and restarts it.
// The given integer must be in the range [0,NumNodes()-1].
func (f *Farmer) Restart(i int) error {
	_ = f.Kill(i)
	// supervisorctl is horrible with exit codes (cockroachdb/cockroach-prod#59).
	return f.execSupervisor(i, "start cockroach")
}

// URL returns the HTTP(s) endpoint.
func (f *Farmer) URL(i int) string {
	return "http://" + util.EnsureHostPort(f.Nodes()[i])
}
