use ExtUtils::MakeMaker;
require 5.002;
$Verbose = 1;
WriteMakefile(
	'NAME'		=> 'Devel::DProf',
	'DISTNAME'	=> 'DProf',
	'VERSION_FROM'	=> 'DProf.pm',
	'clean'		=> {'FILES' => 'tmon.out t/tmon.out t/err dprofpp T/tmon.out'},
	'EXE_FILES'	=> ['dprofpp'],
	'PL_FILES'	=> {'dprofpp.PL' => 'dprofpp'},
	'XSPROTOARG'	=> '-noprototypes',

	'dist' => { COMPRESS => 'gzip', SUFFIX => 'gz' },
);

#sub MY::test_via_harness { "" }
sub MY::test_via_harness {
	my( $self, $perl, $tests ) = @_;
	my $t = quotemeta( $tests );
	my $res;

	$res = $self->MM::test_via_harness( $perl, $tests );
	$res =~ s/^(\s+)/$1-/;
	$res =~ s/(&runtests)/\$\$switches $1/;
	$res =~ s/(; runtests)/; \$\$switches=q{-d:DProf}$1/;
	$res =~ s,$t,t/bug.t,;
	$res;
}

sub MY::test_via_script {
	my( $self, $perl, $script ) = @_;
	my $res;

	$res = $self->MM::test_via_script( $perl, $script );
	$res =~ s/(test.pl)/$1 -p $perl/;
	$res;
}
