package Cloudmin::VMManage;

# Loaded by VMManage.pm so live operations share its validation and job methods.
use strict;
use warnings;
use Time::HiRes qw(time sleep);

# live_cpu_minimum(doc)
# Subtracts enabled, removable CPUs from the running count. Without individual
# CPU entries, conservatively treats every enabled CPU as non-removable.
sub live_cpu_minimum
{
my ($doc) = @_;
my $current = $doc->findvalue('/domain/vcpu/@current') || $doc->findvalue('/domain/vcpu');
my $removable = $doc->findvalue('count(/domain/vcpus/vcpu[@enabled="yes" and @hotpluggable="yes"])');
my $minimum = $current - $removable;
return $minimum > 0 ? $minimum : 1;
}

1;
