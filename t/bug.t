my $case = 1;

print "1..2\n";

&foo1( A );
&foo2( B );

sub foo1 {
	print "# foo1(@_)\n";
	bar(@_); # okay
}
sub foo2 {
	print "# foo2(@_)\n";
	&bar; # not okay
}
sub bar {
	print "# bar(@_)\n";
	print( (@_ > 0 ? "ok" : "not ok"), " $case\n" );
	++$case;
}
