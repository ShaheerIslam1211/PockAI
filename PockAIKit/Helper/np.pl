# Apple's perl is allowed to read now-playing info (incl. artwork) on macOS 15.4+; ordinary apps are not.
use DynaLoader;
my $l = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
my $s = DynaLoader::dl_find_symbol($l, "np_run") or die "np_run missing";
my $f = DynaLoader::dl_install_xsub("main::np_run", $s);
&$f();
