#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

/*#define DBG_SUB 1	/* */
/*#define DBG_TIMER 1	/* */

#ifdef DBG_SUB
#  define DBG_SUB_NOTIFY(A,B) warn( A, B )
#else
#  define DBG_SUB_NOTIFY(A,B)  /* nothing */
#endif

#ifdef DBG_TIMER
#  define DBG_TIMER_NOTIFY(A) warn( A )
#else
#  define DBG_TIMER_NOTIFY(A)  /* nothing */
#endif

/* HZ == clock ticks per second */
#ifdef VMS
#  define HZ CLK_TCK
#  include <starlet.h>  /* prototype for sys$gettim() */
   clock_t dprof_times(struct tms *bufptr) {
	clock_t retval;
	/* Get wall time and convert to 10 ms intervals to
	 * produce the return value dprof expects */
#  if defined(__DECC) && defined (__ALPHA)
#    include <ints.h>
	uint64 vmstime;
	_ckvmssts(sys$gettim(&vmstime));
	vmstime /= 100000;
	retval = vmstime & 0x7fffffff;
#  else
	/* (Older hw or ccs don't have an atomic 64-bit type, so we
	 * juggle 32-bit ints (and a float) to produce a time_t result
	 * with minimal loss of information.) */
	long int vmstime[2],remainder,divisor = 100000;
	_ckvmssts(sys$gettim((unsigned long int *)vmstime));
	vmstime[1] &= 0x7fff;  /* prevent overflow in EDIV */
	_ckvmssts(lib$ediv(&divisor,vmstime,(long int *)&retval,&remainder));
#  endif
	/* Fill in the struct tms using the CRTL routine . . .*/
	times((tbuffer_t *)bufptr);
	return (clock_t) retval;
   }
#  define Times(ptr) (dprof_times(ptr))
#else
#  define Times(ptr) (times(ptr))
#  ifndef HZ
#    ifdef CLK_TCK
#      define HZ CLK_TCK
#    else
#      define HZ 60
#    endif
#  endif
#endif

static SV * Sub;	/* pointer to $DB::sub */
static FILE *fp;	/* pointer to tmon.out file */

static int prof_pid;	/* pid of profiled process */

/* Everything is built on times(2).  See its manpage for a description
 * of the timings.
 */

static
struct tms	prof_start,
		prof_end;

static
clock_t		rprof_start, /* elapsed real time, in ticks */
		rprof_end;

union prof_any {
	clock_t tms_utime;  /* cpu time spent in user space */
	clock_t tms_stime;  /* cpu time spent in system */
	clock_t realtime;   /* elapsed real time, in ticks */
	char *name;
	opcode ptype;
};

typedef union prof_any PROFANY;

static PROFANY	*profstack;
static int	profstack_max = 128;
static int	profstack_ix = 0;


static void
prof_mark( ptype )
opcode ptype;
{
	struct tms t;
	clock_t realtime;
	char *name, *pv;
	char *hvname;
	STRLEN len;
	SV *sv;

	if( profstack_ix + 5 > profstack_max ){
		profstack_max = profstack_max * 3 / 2;
		Renew( profstack, profstack_max, PROFANY );
	}

	realtime = Times(&t);
	pv = SvPV( Sub, len );

	if( SvROK(Sub) ){
		/* Attempt to make CODE refs slightly identifiable by
		 * including their package name.
		 */
		sv = (SV*)SvRV(Sub);
		if( sv && SvTYPE(sv) == SVt_PVCV ){
			hvname = HvNAME(CvSTASH(sv));
			len += strlen( hvname ) + 2;  /* +2 for ::'s */

		}
		else {
			croak( "DProf prof_mark() lost on supposed CODE ref %s.\n", pv );
		}
		name = (char *)safemalloc( len * sizeof(char) + 1 );
		strcpy( name, hvname );
		strcat( name, "::" );
		strcat( name, pv );
	}
	else{
		if( *(pv+len-1) == 'D' ){
			/* It could be an &AUTOLOAD. */

			/* I measured a bunch of *.pl and *.pm (from Perl
			 * distribution and other misc things) and found
			 * 780 fully-qualified names.  They averaged
			 * about 19 chars each.  Only 1 of those names
			 * ended with 'D' and wasn't an &AUTOLOAD--it
			 * was &overload::OVERLOAD.
			 *    --dmr 2/19/96
			 */

			if( strcmp( pv+len-9, ":AUTOLOAD" ) == 0 ){
				/* The sub name is in $AUTOLOAD */
				sv = perl_get_sv( pv, 0 );
				if( sv == NULL ){
					croak("DProf prof_mark() lost on AUTOLOAD (%s).\n", pv );
				}
				pv = SvPV( sv, na );
				DBG_SUB_NOTIFY( "  AUTOLOAD(%s)\n", pv );
			}
		}
		name = savepv( pv );
	}

	profstack[profstack_ix++].ptype = ptype;
	profstack[profstack_ix++].tms_utime = t.tms_utime;
	profstack[profstack_ix++].tms_stime = t.tms_stime;
	profstack[profstack_ix++].realtime = realtime;
	profstack[profstack_ix++].name = name;
}

static void
prof_record(){
	char *name;
	int base = 0;
	opcode ptype;
	clock_t tms_utime;
	clock_t tms_stime;
	clock_t realtime;

	/* fp is opened in the BOOT section */
	fprintf(fp, "#fOrTyTwO\n" );
	fprintf(fp, "$hz=%d;\n", HZ );
	fprintf(fp, "$XS_VERSION='DProf %s';\n", XS_VERSION );
	fprintf(fp, "# All values are given in HZ\n" );
	fprintf(fp, "$rrun_utime=%ld; $rrun_stime=%ld; $rrun_rtime=%ld;\n",
		prof_end.tms_utime - prof_start.tms_utime,
		prof_end.tms_stime - prof_start.tms_stime,
		rprof_end - rprof_start );
	fprintf(fp, "PART2\n" );

	while( base < profstack_ix ){
		ptype = profstack[base++].ptype;
		tms_utime = profstack[base++].tms_utime;
		tms_stime = profstack[base++].tms_stime;
		realtime = profstack[base++].realtime;
		name = profstack[base++].name;

		switch( ptype ){
		case OP_LEAVESUB:
			fprintf(fp,"- %ld %ld %ld %s\n",
				tms_utime, tms_stime, realtime, name );
			break;
		case OP_ENTERSUB:
			fprintf(fp,"+ %ld %ld %ld %s\n",
				tms_utime, tms_stime, realtime, name );
			break;
		default:
			fprintf(fp,"Profiler unknown prof code %d\n", ptype);
		}
	}
	fclose( fp );
}

#define for_real
#ifdef for_real

XS(XS_DB_sub)
{
	dXSARGS;
	dORIGMARK;
	SP -= items;

	DBG_SUB_NOTIFY( "XS DBsub(%s)\n", SvPV(Sub, na) );

	sv_setiv( DBsingle, 0 ); /* disable DB single-stepping */

	prof_mark( OP_ENTERSUB );
	PUSHMARK( ORIGMARK );

	perl_call_sv( Sub, GIMME );

	prof_mark( OP_LEAVESUB );
	SPAGAIN;
	PUTBACK;
	return;
}

#endif /* for_real */

#ifdef testing

	MODULE = Devel::DProf		PACKAGE = DB

	void
	sub(...)
		PPCODE:

		dORIGMARK;
		/* SP -= items;  added by xsubpp */
		DBG_SUB_NOTIFY( "XS DBsub(%s)\n", SvPV(Sub, na) );

		sv_setiv( DBsingle, 0 ); /* disable DB single-stepping */

		prof_mark( OP_ENTERSUB );
		PUSHMARK( ORIGMARK );

		perl_call_sv( Sub, GIMME );

		prof_mark( OP_LEAVESUB );
		SPAGAIN;
		/* PUTBACK;  added by xsubpp */

#endif /* testing */

MODULE = Devel::DProf		PACKAGE = Devel::DProf

void
END()
	PPCODE:
	if( DBsub ){
		/* maybe the process forked--we want only
		 * the parent's profile.
		 */
		if( prof_pid == (int)getpid() ){
			rprof_end = Times(&prof_end);
			DBG_TIMER_NOTIFY("Profiler timer is off.\n");
			prof_record();
		}
	}

BOOT:
	/* Before we go anywhere make sure we were invoked
	 * properly, else we'll dump core.
	 */
	if( ! DBsub )
		croak("DProf: run perl with -d to use DProf.\n");

	/* When we hook up the XS DB::sub we'll be redefining
	 * the DB::sub from the PM file.  Turn off warnings
	 * while we do this.
	 */
	{
		I32 warn_tmp = dowarn;
		dowarn = 0;
		newXS("DB::sub", XS_DB_sub, file);
		dowarn = warn_tmp;
	}

	Sub = GvSV(DBsub);	 /* name of current sub */
	sv_setiv( DBsingle, 0 ); /* disable DB single-stepping */

	if( (fp = fopen( "tmon.out", "w" )) == NULL )
		croak("DProf: unable to write tmon.out, errno = %d\n", errno );

	prof_pid = (int)getpid();
	New( 0, profstack, profstack_max, PROFANY );
	DBG_TIMER_NOTIFY("Profiler timer is on.\n");
	rprof_start = Times(&prof_start);
