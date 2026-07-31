// Copyright 2026 tsuru authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package registry

import (
	"context"
	"errors"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/ecr"
	ecrtypes "github.com/aws/aws-sdk-go-v2/service/ecr/types"
	check "gopkg.in/check.v1"
)

type fakeECRClient struct {
	input    *ecr.BatchDeleteImageInput
	output   *ecr.BatchDeleteImageOutput
	err      error
	callHits int
}

func (f *fakeECRClient) BatchDeleteImage(_ context.Context, in *ecr.BatchDeleteImageInput, _ ...func(*ecr.Options)) (*ecr.BatchDeleteImageOutput, error) {
	f.callHits++
	f.input = in
	if f.err != nil {
		return nil, f.err
	}
	if f.output != nil {
		return f.output, nil
	}
	return &ecr.BatchDeleteImageOutput{}, nil
}

// withFakeECRClient swaps newECRClient for a fake and restores it afterwards.
func (s *S) withFakeECRClient(fake *fakeECRClient) func() {
	original := newECRClient
	newECRClient = func(_ context.Context, _ string) (ecrAPI, error) {
		return fake, nil
	}
	return func() { newECRClient = original }
}

func (s *S) TestIsECRRegistry(c *check.C) {
	tests := []struct {
		host   string
		region string
		ok     bool
	}{
		{"123456789012.dkr.ecr.us-east-1.amazonaws.com", "us-east-1", true},
		{"123456789012.dkr.ecr.eu-west-3.amazonaws.com", "eu-west-3", true},
		{"123456789012.dkr.ecr-fips.us-gov-west-1.amazonaws.com", "us-gov-west-1", true},
		{"123456789012.dkr.ecr.cn-north-1.amazonaws.com.cn", "cn-north-1", true},
		{"registry.hub.docker.com", "", false},
		{"gcr.io", "", false},
		{"myregistry:5000", "", false},
		{"12345.dkr.ecr.us-east-1.amazonaws.com", "", false}, // account id must be 12 digits
	}
	for _, tt := range tests {
		region, ok := isECRRegistry(tt.host)
		c.Check(ok, check.Equals, tt.ok, check.Commentf("host: %s", tt.host))
		c.Check(region, check.Equals, tt.region, check.Commentf("host: %s", tt.host))
	}
}

func (s *S) TestRemoveECRImageByTag(c *check.C) {
	fake := &fakeECRClient{}
	defer s.withFakeECRClient(fake)()

	err := RemoveImage(context.TODO(), "123456789012.dkr.ecr.us-east-1.amazonaws.com/tsuru/app-test:v3")
	c.Assert(err, check.IsNil)
	c.Assert(fake.callHits, check.Equals, 1)
	c.Assert(aws.ToString(fake.input.RepositoryName), check.Equals, "tsuru/app-test")
	c.Assert(fake.input.ImageIds, check.HasLen, 1)
	c.Assert(aws.ToString(fake.input.ImageIds[0].ImageTag), check.Equals, "v3")
	c.Assert(fake.input.ImageIds[0].ImageDigest, check.IsNil)
}

func (s *S) TestRemoveECRImageNestedRepositoryPath(c *check.C) {
	fake := &fakeECRClient{}
	defer s.withFakeECRClient(fake)()

	err := RemoveImage(context.TODO(), "123456789012.dkr.ecr.us-east-1.amazonaws.com/org/team/tsuru/app-test:v1")
	c.Assert(err, check.IsNil)
	c.Assert(aws.ToString(fake.input.RepositoryName), check.Equals, "org/team/tsuru/app-test")
	c.Assert(aws.ToString(fake.input.ImageIds[0].ImageTag), check.Equals, "v1")
}

func (s *S) TestRemoveECRImageByDigest(c *check.C) {
	fake := &fakeECRClient{}
	defer s.withFakeECRClient(fake)()

	digest := "sha256:ac9168d67991e02841c09fd1af9f41e0997571b32ad8f101813c7fa82f62f17f"
	err := RemoveImage(context.TODO(), "123456789012.dkr.ecr.us-east-1.amazonaws.com/tsuru/app-test:"+digest)
	c.Assert(err, check.IsNil)
	c.Assert(aws.ToString(fake.input.ImageIds[0].ImageDigest), check.Equals, digest)
	c.Assert(fake.input.ImageIds[0].ImageTag, check.IsNil)
}

func (s *S) TestRemoveECRImageNotFoundIsIgnored(c *check.C) {
	fake := &fakeECRClient{output: &ecr.BatchDeleteImageOutput{
		Failures: []ecrtypes.ImageFailure{{
			FailureCode:   ecrtypes.ImageFailureCodeImageNotFound,
			FailureReason: aws.String("Requested image not found"),
		}},
	}}
	defer s.withFakeECRClient(fake)()

	// RemoveImage surfaces ErrImageNotFound; RemoveImageIgnoreNotFound swallows it.
	err := RemoveImageIgnoreNotFound(context.TODO(), "123456789012.dkr.ecr.us-east-1.amazonaws.com/tsuru/app-test:v3")
	c.Assert(err, check.IsNil)
}

func (s *S) TestRemoveECRImageOtherFailureIsError(c *check.C) {
	fake := &fakeECRClient{output: &ecr.BatchDeleteImageOutput{
		Failures: []ecrtypes.ImageFailure{{
			FailureCode:   ecrtypes.ImageFailureCodeInvalidImageDigest,
			FailureReason: aws.String("boom"),
		}},
	}}
	defer s.withFakeECRClient(fake)()

	err := RemoveImage(context.TODO(), "123456789012.dkr.ecr.us-east-1.amazonaws.com/tsuru/app-test:v3")
	c.Assert(err, check.ErrorMatches, `.*failed to delete image tsuru/app-test:v3 from ECR.*boom.*`)
}

func (s *S) TestRemoveECRImageAPIError(c *check.C) {
	fake := &fakeECRClient{err: errors.New("access denied")}
	defer s.withFakeECRClient(fake)()

	err := RemoveImage(context.TODO(), "123456789012.dkr.ecr.us-east-1.amazonaws.com/tsuru/app-test:v3")
	c.Assert(err, check.ErrorMatches, `.*failed to delete image tsuru/app-test:v3 from ECR.*access denied.*`)
}
