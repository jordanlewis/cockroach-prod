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

package amazon

import (
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/ec2"
	"github.com/cockroachdb/cockroach/util"
)

const (
	securityGroupName             = "docker-machine"
	allIPAddresses                = "0.0.0.0/0"
	cockroachProtocol             = "tcp"
	awsSecurityRuleDuplicateError = "InvalidPermission.Duplicate"
	awsSecurityGroupNotFound      = "InvalidGroup.NotFound"
)

// FindSecurityGroup looks for the security group created by docker-machine.
// We needs its ID for other EC2 tasks (eg: create load balancer).
// Not finding the security group is an error.
func FindSecurityGroup(region string) (string, error) {
	ec2Service := ec2.New(session.New(), &aws.Config{Region: aws.String(region)})
	resp, err := ec2Service.DescribeSecurityGroups(&ec2.DescribeSecurityGroupsInput{
		GroupNames: []*string{aws.String(securityGroupName)},
	})
	if err != nil {
		return "", err
	}

	if len(resp.SecurityGroups) == 0 {
		return "", util.Errorf("security group with name %q not found", securityGroupName)
	}

	return *resp.SecurityGroups[0].GroupId, nil
}

// AddCockroachSecurityGroupIngress takes in a nodeInfo and
// adds the cockroach port ingress rules to the security group.
// The To and From ports are set to 'cockroachPort'.
// Duplicates are technically errors according to the AWS API, but we check for
// the duplicate error code and return ok.
func AddCockroachSecurityGroupIngress(region string, cockroachPort int64, securityGroupID string) error {
	ec2Service := ec2.New(session.New(), &aws.Config{Region: aws.String(region)})

	_, err := ec2Service.AuthorizeSecurityGroupIngress(&ec2.AuthorizeSecurityGroupIngressInput{
		CidrIp:     aws.String(allIPAddresses),
		FromPort:   aws.Int64(cockroachPort),
		ToPort:     aws.Int64(cockroachPort),
		IpProtocol: aws.String(cockroachProtocol),
		GroupId:    aws.String(securityGroupID),
	})

	if IsAWSErrorCode(err, awsSecurityRuleDuplicateError) {
		return nil
	}
	return err
}
