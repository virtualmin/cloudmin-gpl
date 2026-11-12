package CloudminJSONFallback;

# Load with PERL5OPT=-MCloudminJSONFallback to test Webmin's PP fallback.
# Mark XS unavailable in this test process without changing installed modules.
BEGIN { $INC{'JSON/XS.pm'} = undef; }

1;
