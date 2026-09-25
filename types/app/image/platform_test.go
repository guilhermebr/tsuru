// Copyright 2026 tsuru authors. All rights reserved.
// Use of this source code is governed by a BSD-style
// license that can be found in the LICENSE file.

package image

import "testing"

func TestRegistryVersionImageForRegistry(t *testing.T) {
	v := RegistryVersion{Images: []string{
		"registry.local:5000/tsuru/go:v7",
		"161.35.120.119:20500/tsuru/go:v7",
	}}
	tests := []struct {
		reg  ImageRegistry
		want string
		ok   bool
	}{
		{"161.35.120.119:20500", "161.35.120.119:20500/tsuru/go:v7", true},
		{"registry.local:5000", "registry.local:5000/tsuru/go:v7", true},
		{"161.35.120.119:2050", "", false},
		{"other:5000", "", false},
		{EmptyImageRegistry, "", false},
	}
	for _, tt := range tests {
		got, ok := v.ImageForRegistry(tt.reg)
		if got != tt.want || ok != tt.ok {
			t.Errorf("ImageForRegistry(%q) = %q, %v; want %q, %v", tt.reg, got, ok, tt.want, tt.ok)
		}
	}
}
