# perl

use V;

dprofpp( '-T' );
$e1 = $expected = qq{
main::bar
main::baz
   main::bar
   main::foo
main::baz
main::foo
Garbled profile is missing some exit time stamps:
Try rerunning dprofpp with -F.
};
report 1, sub { $expected eq $results };

dprofpp('-TF');
$e2 = $expected = qq{
main::bar
main::baz
   main::bar
   main::foo
Faking 2 exit timestamp(s).
};
report 2, sub { $expected eq $results };

dprofpp( '-t' );
$expected = $e1;
report 3, sub { 1 };

dprofpp('-tF');
$expected = $e2;
report 4, sub { $expected eq $results };
