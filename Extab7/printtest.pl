use strict;
use warnings;


(my $f1, my $f2) = openfiles();

$f1->print("test1", "\n");
$f2->print("test2", "\n");

sub openfiles {
	my $fh1;
	my $fh2;
	
	open($fh1, '+>', "file1.txt");
	open($fh2, '+>', "file2.txt");
	
	$fh1->print("testa", "\n");
	$fh2->print("testb", "\n");
	
	print $fh1 ("testa1", "\n");
	
	return $fh1, $fh2
}
