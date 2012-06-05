package app

import (
	. "launchpad.net/gocheck"
)

func (s *S) TestFilterOutputWithJujuLog(c *C) {
	output := []byte(`/usr/lib/python2.6/site-packages/juju/providers/ec2/files.py:8: DeprecationWarning: the sha module is deprecated; use the hashlib module instead
  import sha
2012-06-05 17:26:15,881 WARNING ssl-hostname-verification is disabled for this environment
2012-06-05 17:26:15,881 WARNING EC2 API calls not using secure transport
2012-06-05 17:26:15,881 WARNING S3 API calls not using secure transport
2012-06-05 17:26:15,881 WARNING Ubuntu Cloud Image lookups encrypted but not authenticated
2012-06-05 17:26:15,891 INFO Connecting to environment...
2012-06-05 17:26:16,657 INFO Connected to environment.
2012-06-05 17:26:16,860 INFO Connecting to machine 0 at 10.170.0.191
; generated by /sbin/dhclient-script
search novalocal
nameserver 192.168.1.1`)
	expected := []byte(`; generated by /sbin/dhclient-script
search novalocal
nameserver 192.168.1.1`)
	got := filterOutput(output)
	c.Assert(string(got), Equals, string(expected))
}

func (s *S) TestFilterOutputWithoutJujuLog(c *C) {
	output := []byte(`/usr/lib/python2.6/site-packages/juju/providers/ec2/files.py:8: DeprecationWarning: the sha module is deprecated; use the hashlib module instead
  import sha
; generated by /sbin/dhclient-script
search novalocal
nameserver 192.168.1.1`)
	expected := []byte(`; generated by /sbin/dhclient-script
search novalocal
nameserver 192.168.1.1`)
	got := filterOutput(output)
	c.Assert(string(got), Equals, string(expected))
}

func (s *S) TestFilterOutputWithoutJujuLogAndWarnings(c *C) {
	output := []byte(`; generated by /sbin/dhclient-script
search novalocal
nameserver 192.168.1.1`)
	expected := []byte(`; generated by /sbin/dhclient-script
search novalocal
nameserver 192.168.1.1`)
	got := filterOutput(output)
	c.Assert(string(got), Equals, string(expected))
}
