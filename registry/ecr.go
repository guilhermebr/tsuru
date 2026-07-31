// Copyright 2026 tsuru authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package registry

import (
	"context"
	"regexp"
	"strings"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ecr"
	ecrtypes "github.com/aws/aws-sdk-go-v2/service/ecr/types"
	"github.com/pkg/errors"
)

// ecrRegistryRegexp matches an Amazon ECR registry host, capturing the region.
// Covers standard, FIPS, and China partition (amazonaws.com.cn) endpoints.
var ecrRegistryRegexp = regexp.MustCompile(`^[0-9]{12}\.dkr\.ecr(?:-fips)?\.([a-z0-9-]+)\.amazonaws\.com(?:\.cn)?$`)

// isECRRegistry reports whether host is an Amazon ECR registry and, if so,
// returns the AWS region embedded in the hostname.
func isECRRegistry(host string) (region string, ok bool) {
	m := ecrRegistryRegexp.FindStringSubmatch(host)
	if m == nil {
		return "", false
	}
	return m[1], true
}

// ecrAPI is the subset of the ECR client used here, extracted as an interface
// so it can be faked in tests.
type ecrAPI interface {
	BatchDeleteImage(ctx context.Context, params *ecr.BatchDeleteImageInput, optFns ...func(*ecr.Options)) (*ecr.BatchDeleteImageOutput, error)
}

// newECRClient builds an ECR client for the given region using the default AWS
// credential chain (IRSA, instance profile, environment, ...). It is a package
// variable so tests can inject a fake.
var newECRClient = func(ctx context.Context, region string) (ecrAPI, error) {
	cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(region))
	if err != nil {
		return nil, errors.Wrap(err, "failed to load AWS config for ECR")
	}
	return ecr.NewFromConfig(cfg), nil
}

// removeECRImage deletes a single image reference from an ECR repository using
// the AWS API. ECR does not support the Docker Registry v2 manifest DELETE
// reliably (and uses Basic auth, which tsuru's Distribution client does not
// negotiate), so image deletion must go through BatchDeleteImage.
//
// The reference may be a tag or a "sha256:" digest; ECR accepts either.
// BatchDeleteImage removes the manifest (and its now-unreferenced layers) when
// the last tag pointing at it is deleted. A missing image is treated as success
// to keep RemoveImageIgnoreNotFound semantics.
func removeECRImage(ctx context.Context, region, repository, reference string) error {
	client, err := newECRClient(ctx, region)
	if err != nil {
		return err
	}

	imageID := ecrtypes.ImageIdentifier{}
	if strings.HasPrefix(reference, "sha256:") {
		imageID.ImageDigest = aws.String(reference)
	} else {
		imageID.ImageTag = aws.String(reference)
	}

	out, err := client.BatchDeleteImage(ctx, &ecr.BatchDeleteImageInput{
		RepositoryName: aws.String(repository),
		ImageIds:       []ecrtypes.ImageIdentifier{imageID},
	})
	if err != nil {
		return errors.Wrapf(err, "failed to delete image %s:%s from ECR", repository, reference)
	}

	for _, f := range out.Failures {
		if f.FailureCode == ecrtypes.ImageFailureCodeImageNotFound {
			// Idempotent: nothing to delete is not an error.
			return ErrImageNotFound
		}
		return errors.Errorf("failed to delete image %s:%s from ECR: %s: %s",
			repository, reference, f.FailureCode, aws.ToString(f.FailureReason))
	}
	return nil
}
