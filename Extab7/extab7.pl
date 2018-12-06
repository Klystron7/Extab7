# extab7
# version 7 of comparable import from MLS
# Changes:
# version 6:
# 1. Convert input from CAAR List-It to Paragon MLS
# version 5:
# 1. changes for fnma UAD formatting
# version 4:
# 1. run from right click on file to be imported (pass file name)
# 2. added automatic import of comps into wintotal (run compimp.exe)
#	 using Win32::Gui to step through compimp.exe gui.
# 3. took out temp::file due to problems deleting temp file. Making own temp file again.
# 4. fixed problem with text::recordparser "use of uninitialized value in hash element" by
#    removing tab character after last field just before end of line in CAAR file.
use strict;
use warnings;
no warnings 'deprecated';

use Geo::StreetAddress::US;
use Tie::IxHash;
use Text::RecordParser;
use Text::CSV;

use Text::Autoformat;
use Lingua::EN::Titlecase;
use Lingua::EN::AddressParse;
use Tk;
use Cwd;
use Switch;
use File::Basename;
use Math::Round;
use Time::HiRes qw( gettimeofday tv_interval);

use IO::Handle;
use Win32::GUI qw(/^MB_/);    # Export all constants starting with MB_
use Win32::GuiTest qw( :ALL);
use Win32::Process;
use Win32();

#use Tie::File;
#use File::Temp qw/ tempfile tempdir /;
#use autodie;
#use Text::Capitalize;

use Time::localtime;
#use Date::EzDate;
#my $sfDate = Date::EzDate->new('July 16, 2011');

# modules for registry functions
use Encode;
my $Registry;
use Win32::TieRegistry 0.25 (
	TiedRef     => \$Registry,
	Delimiter   => "/",
	ArrayValues => 1,
	SplitMultis => 1,
	AllowLoad   => 1,
	qw( REG_SZ REG_EXPAND_SZ REG_DWORD REG_BINARY REG_MULTI_SZ
	  KEY_READ KEY_WRITE KEY_ALL_ACCESS ),
);

our $Run_CompImp = 0;

my $os = Win32::GetOSName();
if ( $os =~ /WinXP/ig ) {
	my $test = 1;
}

my %addrArgs = (
				 country                     => 'US',
				 autoclean                   => 1,
				 force_case                  => 1,
				 abbreviate_subcountry       => 0,
				 abbreviated_subcountry_only => 1
);

my $laddress  = new Lingua::EN::AddressParse(%addrArgs);
my $errorAddr = $laddress->parse(" 316 9TH ST SW, CHARLOTTESVILLE, VA 22903");
my %addrComp  = $laddress->components;
my $addrCase  = $laddress->case_all;

#remove to print# print "Starting processing\n";

# check if file to be processed is an input argument
my $inputfilename = undef;

#remove to print# print "Input file: $ARGV[0]\n";
if ( $ARGV[0] ) {
	$inputfilename = $ARGV[0];
}

# for testing without having to use openfiledialog
#$inputfilename = "C:\\Documents and Settings\\Ernest\\workspace\\extab4\\KEENAN8652_m2tetfta.txt";

#process input file
# returns: handle to output file, preprocessed temp data file, data source
#( my $WTfile, my $dataFile, my $mlsSrc ) = preProcInputFile($inputfilename);
( my $WTfile, my $WTfileT, my $WTfileName, my $WTfileNT, my $dataFile, my $mlsSrc ) =
  preProcInputFile($inputfilename);

# replace \ with / in output file name.
$WTfileName =~ s/\//\\/g;

#set up output data hash table and print keys
my $rhash = WTrecord();

#print fields on output file
printFields( $rhash, $WTfile );

# set up record parser
my $p = Text::RecordParser->new(
								 {
								   filename         => $dataFile,
								   field_separator  => "\t",
								   record_separator => "\n"
								 }
);
$p->bind_header;

my $pnum = 0;

# loop over each input record and process according to MLS type
# get each record (row from file) as a hashref
while ( my $record = $p->fetchrow_hashref ) {

	# Get a new record with only tabs
	$rhash = WTrecord();

	# Check the source (CAAR, MRIS, CVMLS)
	if ( $mlsSrc eq "CAAR" ) {
		process_CAAR( $record, $rhash, $WTfile, $WTfileT);
	} else {
		#continue
	}
	$pnum = $pnum + 1;
	#print('Comp ',$pnum);
	#print('\n');
}

# close file handles not needed
close $p->fh;
close $WTfile;

# setup for export to wintotal
# inputs:
# 1. Name and path of file to be imported
# 2. Import template to use
# 3. Duplicates mode: add new, update existing, skip, or cancel [0,1,2,3]

my $impt = "Import V.3";    # Import template to use
my $dmod = 0;               # Duplicates mode: add new

if ($Run_CompImp) {
	compimpexe( $WTfileName, $impt, $dmod, $pnum );
}

# clean up temp file
unlink $dataFile;

sub preProcInputFile {

	my $dir      = '';
	my $csv_file = '';
	my $filename = $_[0];
	if ( !defined $filename ) {

		# get file for processing
		my $top = new MainWindow;
		$top->withdraw();

		$dir = "C:\\Documents and Settings\\Ernest\\workspace\\extab6uad\\CAAR-Paragon Conversion";
		$dir = "X:\\";
		$dir = "C:\\Users\\Ernest\\eclipse-workspace\\Extab7";
		$csv_file = $top->getOpenFile( -initialdir => $dir );

	} else {
		$csv_file = $filename;
	}

	my $INPUTFILE;
	open( $INPUTFILE, '<', $csv_file );
	my $firstline;
	while (<$INPUTFILE>) {
		$firstline = $_;
		last;
	}
	close $INPUTFILE;

	# Check data file for source MLS
	# my $lineToCheck = $line[ $cnt - 1 ];
	my $lineToCheck = $firstline;
	my $dSrc        = checkRcdSource($lineToCheck);

	if ( $dSrc !~ /CAAR|MRIS|CVRMLS/ig ) {
		#this is not an MLS data file that we can handle, so exit...
		exit;
	}
	
	#convert comma delimited to tab delimited
	my $csv = Text::CSV->new( { binary => 1 } );
	my $tsv = Text::CSV->new( { binary => 1, sep_char => "\t", eol => "\n" });
	
	#set up for temporary output file
	(my $base, $dir, my $ext ) = fileparse( $csv_file, '\..*' );
	my $file = "${dir}${base}.txt";	
	
	open (my $infh, '<:encoding(utf8)', $csv_file);
	open (my $outfh, '>:encoding(utf8)', $file);  #temp tab delimited output file.
	$outfh->autoflush();
	
	my $rownum = 1;
	while ( my $row = $csv->getline($infh) ) {	
		# fix duplicate field names in Paragon 5 MLS export
    	# Basement appears twice, once for yes or no, and again for type.
    	# Change to Bsmnt_1 and Bsmnt_2 
		
		if ($rownum eq 1) {
			my $dupcnt = 1;
			my $cnt = 0;
			my $element = '';
			my $newname = '';
			foreach (@{$row}) {	
				$element=@{$row}[$cnt];
				if($element =~ /Basement/ix) {
					$element =~ s/Basement/Bsmnt_${dupcnt}/;
					@{$row}[$cnt] = $element;
					$dupcnt++;
				}
				$cnt++;
			}
		}
		
    	$tsv->print( $outfh, $row );
    	$rownum++;
	}
    $outfh->autoflush();
    close $outfh;
    

	# Preprocess file to replace single and double quotes (' -> `, " -> ~)
	my @line;
	my $cnt = 0;
	if ( $dSrc eq 'CAAR' ) {
		open( $INPUTFILE, '<', $file );

		# read file line by line
		while (<$INPUTFILE>) {
			$line[$cnt] = $_;

			# CAAR records may have a tab after the last field,
			# making it seem that there is one more field than there is.
			# so remove any tab character just before the newline.
			$line[$cnt] =~ s/(\t\n)/\n/;
			$line[$cnt] =~ s/'/`/ig;
			$line[$cnt] =~ s/"//ig;
			$cnt++;
		}
		close $INPUTFILE;

	} elsif ( $dSrc eq 'MRIS' ) {
		open( $INPUTFILE, '<', $file );
		while (<$INPUTFILE>) {
			$line[$cnt] = $_;
			$line[$cnt] =~ s/'/`/ig;
			$line[$cnt] =~ s/"//ig;
			$cnt++;
		}
		close $INPUTFILE;
	}

	#set up for output file
	($base, $dir, $ext ) = fileparse( $file, '\..*' );
	my $WToutfileName = "${dir}${base}_for_wintotal${ext}";
	open( my $WToutfile, '+>', $WToutfileName );
	
	my $WToutfileNameTxt = "${dir}${base}_for_wintotal_text${ext}";
	open( my $WToutfileTxt, '+>', $WToutfileNameTxt );

	#create temporary file
	my $dTmpFile;
	my $dTmpFileName = "${dir}${base}_temp${ext}";
	open( $dTmpFile, '>', $dTmpFileName );
	$dTmpFile->autoflush();
	my $lcnt = 0;
	while ( $lcnt < $cnt ) {
		print $dTmpFile $line[$lcnt];
		$lcnt++;
	}
	close $dTmpFile;

	return ( $WToutfile, $WToutfileTxt, $WToutfileName, $WToutfileNameTxt, $dTmpFileName, $dSrc);
}

sub process_CAAR {
	my ($mlsrec)  = shift;
	my ($outdata) = shift;
	my ($outfile) = shift;
	my ($outfileT) = shift;

	#3. check the record type (Resid (det, att, condo), Land, Multifam, Rental)
	# a) for land, check for "Use" field
	if ( exists $mlsrec->{'Land Description'} ) {
		CAAR_Land( $mlsrec, $outdata, $outfile );
	} elsif ( exists $mlsrec->{'For Sale'} ) {
		CAAR_Rental( $mlsrec, $outdata, $outfile );
	} elsif ( exists $mlsrec->{'units #'} ) {
		CAAR_Multifam( $mlsrec, $outdata, $outfile );
	}

	# 2/16/2010 Property Type field change ('Prop Type')
	# Detached 			= 'DET'
	# Proposed Detached = 'PDT'
	# Attached 			= 'ATH'
	# Proposed Attached = 'PAT'
	# Condominium		= 'CND'
	# Proposed Condo	= 'PCD'

	# 5/31/2010 Property Type field changed back
	# DET	 			= 'Detached'
	# PDT				= 'Proposed Detached'
	# ATH 				= 'Attached'
	# PAT 				= 'Proposed Attached'
	# CND				= 'Condominiums'
	# PCD				= 'Proposed Condo'

	elsif ( $mlsrec->{'PropType'} =~
/Attached|Detached|Condo|Proposed Detached|Proposed Atached|Proposed Condo/ig
	  )
	{
		CAAR_Resid($mlsrec, $outdata, $outfile);
		CAAR_Resid_Text($outdata, $outfileT);
	}

	# elsif ( $mlsrec->{'Prop Type'} =~ /attached|detached|condo|farm/ig ) {
	#	CAAR_Resid( $mlsrec, $outdata, $outfile );
	# }
}

sub CAAR_Resid {
	my ($inrec)   = shift;
	my ($outrec)  = shift;
	my ($outfile) = shift;
	
	# Backspace character used between fields in Wintotal
	my $w = sprintf( '%c', 8 );

	my $tc = Lingua::EN::Titlecase->new("initialize titlecase");
	my %addrArgs = (
					 country                     => 'US',
					 autoclean                   => 1,
					 force_case                  => 1,
					 abbreviate_subcountry       => 0,
					 abbreviated_subcountry_only => 1
	);
	my $laddress = new Lingua::EN::AddressParse(%addrArgs);

	my $address = $inrec->{'Address'};
	my $streetnum = '';
	# Street Number
	if ($address =~ /(\d+)/) {
		$streetnum = $1;
	}
	$outrec->{'StreetNum'} = $streetnum;
	#-----------------------------------------

	$outrec->{'StreetDir'} = '';
	
	#-----------------------------------------
	
	$outrec->{'Address1'} = $tc->title($inrec->{'Address'});
	print($outrec->{'Address1'});
	print "\n";
	#-----------------------------------------

	# Address 2
	my $city = $inrec->{'City'};
	$city = $tc->title($city);
	$city =~ s/\(.*//;
	$city =~ s/\s+$//;
	my $address2 = $city . ", " . "VA " . $inrec->{'Zip'};
	$outrec->{'Address2'} = $address2;

	#-----------------------------------------

	# Address 3
	my $address3 = "VA" . " " . $inrec->{'Zip'};
	$outrec->{'Address3'} = $address3;

	#-----------------------------------------

	# City
	$outrec->{'City'} = $city;

	#-----------------------------------------

	# State
	$outrec->{'State'} = "VA";

	#-----------------------------------------

	# Zip
	$outrec->{'Zip'} = $inrec->{'Zip'};

	#-----------------------------------------

	# SalePrice
	my $soldstatus = 0;
	my $soldprice  = 0;
	my $recstatus  = $inrec->{'Status'};
	if ( $recstatus eq 'SLD' ) {
		$soldstatus = 0;                        #sold
		$soldprice  = $inrec->{'Sold Price'};
	} elsif ( $recstatus =~ m /ACT/i ) {
		$soldstatus = 1;                        #Active
		$soldprice  = $inrec->{'Price'};
	} elsif ( $recstatus =~ m /PND/i ) {
		$soldstatus = 2;                        #Pending
		$soldprice  = $inrec->{'Price'};
	} elsif ( $recstatus =~ m /CNT/i ) {
		$soldstatus = 3;                        #Contingent
		$soldprice  = $inrec->{'Price'};
	} elsif ( $recstatus =~ m /EXP/i ) {
		$soldstatus = 4;                        #Withdrawn
		$soldprice  = $inrec->{'Price'};
	} else {

		#nothing
	}
	$outrec->{'SalePrice'} = $soldprice;

	#-----------------------------------------

	# SoldStatus
	$outrec->{'Status'} = $soldstatus;

	#-----------------------------------------

	# DataSource1
	my $datasrc =
	  "CAARMLS #" . $inrec->{'MLS#'} . ";DOM " . $inrec->{'DOM'};
	$outrec->{'DataSource1'} = $datasrc;
	$outrec->{'DOM'} = $inrec->{'DOM'};

	#-----------------------------------------

	# Data Source 2
	$outrec->{'DataSource2'} = "Tax Records";

	#-----------------------------------------

	# Finance Concessions Line 1
	# REO		REO sale
	# Short		Short sale
	# CrtOrd	Court ordered sale
	# Estate	Estate sale
	# Relo		Relocation sale
	# NonArm	Non-arms length sale
	# ArmLth	Arms length sale
	# Listing	Listing

	my $finconc1 = '';
	if ( $soldstatus == 0 ) {	
		my $agentnotes = $inrec->{'Agent Notes'};
		
		if ( $inrec->{'Foreclosur'} =~ /Yes/i ) {
			$finconc1 = "REO";
		} elsif ( $inrec->{'LenderOwn'} =~ /Yes/i ) {
			$finconc1 = "REO";
		} elsif ( $inrec->{'ShortSale'} =~ /Yes/i ) {
			$finconc1 = "Short";
		} elsif ( $agentnotes =~ /court ordered /i ) {
			$finconc1 = "CrtOrd";
		} elsif ( $agentnotes =~ /estate sale /i ) {
			$finconc1 = "Estate";
		} elsif ( $agentnotes =~ /relocation /i ) {
			$finconc1 = "Relo";
		} else {
			$finconc1 = "ArmLth";
		}
	} elsif ( $soldstatus == 1 ) {
		$finconc1 = "Listing";
	} elsif ( $soldstatus == 2 ) {
		$finconc1 = "Listing";
	} elsif ( $soldstatus == 3 ) {
		$finconc1 = "Listing";
	} else {
		$finconc1 = '';
	}
	$outrec->{'FinanceConcessions1'} = $finconc1;

	#-----------------------------------------

	# FinanceConcessions2
	# Type of financing:
	# FHA		FHA
	# VA		VA
	# Conv		Conventional
	# Seller 	Seller
	# Cash 		Cash
	# RH		Rural Housing
	# Other
	# Format: 12 Char maximum

	my $finconc2    = '';
	my $conc        = '';
	my $finconc2out = '';
	my $finOther    = '';
	my $finFullNm   = '';
	
	if ( $soldstatus == 0 ) {
		my $terms = $inrec->{'How Sold'};
		if ( $terms =~ /NOTSP/ig) {
			$finconc2 = "NotSpec"; $finFullNm = "Other (describe)"; $finOther = "NotSpec";     #Not Specified
		} elsif ( $terms =~ /CASH/ig ) {
			$finconc2 = "Cash"; $finFullNm = "Cash";
		} elsif ( $terms =~ /CNVFI/ig ) {
			$finconc2 = "Conv"; $finFullNm = "Conventional";
		} elsif ( $terms =~ /CNVAR/ig ) {
			$finconc2 = "Conv"; $finFullNm = "Conventional";
		} elsif ( $terms =~ /FHA/ig ) {
			$finconc2 = "FHA"; $finFullNm = "FHA";
		} elsif ( $terms =~ /VHDA/ig ) {
			$finconc2 = "VHDA"; $finFullNm = "Other (describe)"; $finOther = "VHDA";
		} elsif ( $terms =~ /FHMA/ig ) {
			$finconc2 = "FHMA"; $finFullNm = "Other (describe)"; $finOther = "FHMA";
		} elsif ( $terms =~ /VA/ig ) {
			$finconc2 = "VA"; $finFullNm = "VA";
		} elsif ( $terms =~ /ASMMT/ig ) {
			$finconc2 = "AsmMtg"; $finFullNm = "Other (describe)"; $finOther = "AsmMtg";
		} elsif ( $terms =~ /PVTMT/ig ) {
			$finconc2 = "PrvMtg"; $finFullNm = "Other (describe)"; $finOther = "PrvMtg";
		} elsif ( $terms =~ /OWNFN/ig ) {
			$finconc2 = "Seller"; $finFullNm = "Seller";
		} elsif ( $terms =~ /OTHER/ig ) {
			$finconc2 = "NotSpec"; $finFullNm = "Other (describe)"; $finOther = "NotSpec";
		} elsif ( $terms =~ /USDAR/ig ) {
			$finconc2 = "RH"; $finFullNm = "USDA - Rural housing";
		}else {
			$finconc2 = "NotSpec"; $finFullNm = "Other (describe)"; $finOther = "NotSpec";
		}

		$conc = 0;
		if ( $inrec->{'SellerConc'} ) {
			$conc = USA_Format( $inrec->{'SellerConc'} );
			$conc =~ s/$//;
			$conc = $inrec->{'SellerConc'};
		}
		$finconc2out = $finconc2 . ";" . $conc;
	}

	$outrec->{'FinanceConcessions2'} = $finconc2out;
	$outrec->{'FinConc'} = $finconc2;
	$outrec->{'FinFullNm'} = $finFullNm;
	$outrec->{'FinOther'} = $finOther;
	$outrec->{'Conc'} = $conc;

	#-----------------------------------------

	# DateSaleTime1
	my $datesaletime1 = '';
	if ( $soldstatus == 0 ) {
		$datesaletime1 = $inrec->{'Close Date'};
	} else {
		$datesaletime1 = $inrec->{'Lst Date'};
	}
	my $dateonly = '';
	if ( $datesaletime1 =~
		 m/((0?[1-9]|1[012])\/(0?[1-9]|[12][0-9]|3[01])\/(19|20)\d\d)/ )
	{
		$dateonly = $1;
	}
	$outrec->{'DateSaleTime1'} = $dateonly;

	#-----------------------------------------

	# DateSaleTime2
	my $datesaletime2 = '';
	if ( $soldstatus == 0 ) {
		my $sdate = $inrec->{'Close Date'};
		my @da = ( $sdate =~ m/(\d+)/g );
		$datesaletime2 = $da[2] . "/" . $da[0] . "/" . $da[1];

		#time_manip('yyyy/mm/dd', $sdate );
	}
	$outrec->{'DateSaleTime2'} = $datesaletime2;

	#-----------------------------------------
	# SaleDateFormatted
	# Sale and Contract formatted as mm/yy
	my $sdatestr    = '';
	my $cdatestr    = '';
	my $wsdatestr   = '';
	my $wcdatestr   = '';
	my $fulldatestr = '';
	my $salestatus  = '';
	
	if ( $soldstatus == 0 ) {
		my $sdate = $inrec->{'Close Date'};
		my @da = ( $sdate =~ m/(\d+)/g );

		#my $m2digit = sprintf("%02d", $da[0]);
		my $m2digit  = sprintf( "%02d", $da[0] );
		my $yr2digit = sprintf( "%02d", $da[2] % 100 );
		$sdatestr  = "s" . $m2digit . "/" . $yr2digit;
		$wsdatestr = $m2digit . "/" . $yr2digit;

		
		my $cdate = $inrec->{'Cont Date'};
		if ( ( $cdate eq undef ) || ( $cdate eq "" ) ) {
			$cdatestr = "Unk";
		} else {
			my @da = ( $cdate =~ m/(\d+)/g );
			my $m2digit  = sprintf( "%02d", $da[0] );
			my $yr2digit = sprintf( "%02d", $da[2] % 100 );
			$cdatestr  = "c" . $m2digit . "/" . $yr2digit;
			$wcdatestr = $m2digit . "/" . $yr2digit;
		}
		$fulldatestr = $sdatestr . ";" . $cdatestr;
		$outrec->{'SaleStatus'} = "Settled sale";
		$outrec->{'SaleDate'} = $wsdatestr;
		$outrec->{'ContDate'} = $wcdatestr;
		
	} elsif (    ( $soldstatus == 1 )
			  || ( $soldstatus == 2 )
			  || ( $soldstatus == 3 ) )
	{
		$fulldatestr = "Active";
		$outrec->{'SaleStatus'} = "Active"
	}

	#$outrec->{'CloseDate'} = $wsdatestr;
	#$outrec->{'ContrDate'} = $wcdatestr;

	#$fulldatestr = 's12/11;c11/11';
	$outrec->{'SaleDateFormatted'} = $fulldatestr;
	

	#-----------------------------------------

	# Location
	# N - Neutral, B - Beneficial, A - Adverse
	# Res		Residential
	# Ind		Industrial
	# Comm		Commercial
	# BsyRd		Busy Road
	# WtrFr		Water Front
	# GlfCse	Golf Course
	# AdjPrk	Adjacent to Park
	# AdjPwr	Adjacent to Power Lines
	# LndFl		Landfill
	# PubTrn	Public Transportation

	# basic neutral residential
	my $loc1    = "N";
	my $loc2    = "Res";
	my $loc3    = '';
	my $fullLoc = $loc1 . ";" . $loc2;

	# special cases
	#	my $spLoc;
	#	$spLoc =~ s/Wintergreen Mountain Village/Wintergreen Mtn/ig;
	#	$location =~ s/1800 Jefferson Park Ave/Charlottesville/ig;
	#	my $fullLoc = $loc1 . ";" . $loc2;

	$outrec->{'Location1'} = $fullLoc;

	# Original Non-UAD Location
	#	my $location;
	#	my $subdiv;
	#
	#	$subdiv = $inrec->{'Subdivision'};
	#	if ( $subdiv =~ m/NONE/ig ) {
	#		$location = $tc->title($city);
	#	} else {
	#		$subdiv =~ s/`/'/;
	#		$subdiv = $tc->title($subdiv);
	#		$subdiv =~ s/\(.*//;
	#		$subdiv =~ s/\s+$//;
	#		$location = $subdiv;
	#	}
	#	$location =~ s/Wintergreen Mountain Village/Wintergreen Mtn/ig;
	#	$location =~ s/1800 Jefferson Park Ave/Charlottesville/ig;
	#
	#	$outrec->{'Location1'} = $location;

	#-----------------------------------------

	# PropertyRights
	$outrec->{'PropertyRights'} = "Fee Simple";

	#-----------------------------------------

	# Site
	# MLS: LotSize
	my $acres      = $inrec->{'Acres #'};
	my $acresuffix = '';
	my $outacres   = '';
	if ( $acres < 0.001 ) {
		$outacres = '';
	}
	if ( ( $acres > 0.001 ) && ( $acres < 1.0 ) ) {
		my $acresf = $acres * 43560;
		$outacres = sprintf( "%.0f", $acresf );
		$acresuffix = " sf";
	}
	if ( $acres >= 1.0 ) {
		$outacres = sprintf( "%.2f", $acres );
		$acresuffix = " ac";
	}
	$outrec->{'LotSize'} = $outacres . $acresuffix;

	#-----------------------------------------

	# View
	# N - Neutral, B - Beneficial, A - Adverse
	# Wtr		Water View
	# Pstrl		Pastoral View
	# Woods		Woods View
	# Park		Park View
	# Glfvw		Golf View
	# CtySky	City View Skyline View
	# Mtn		Mountain View
	# Res		Residential View
	# CtyStr	CtyStr
	# Ind		Industrial View
	# PwrLn		Power Lines
	# LtdSght	Limited Sight

# MLS LotView
# Blue Ridge | Garden | Golf | Mountain | Pastoral | Residential | Water | Woods
# Water properties: Bay/Cove | Irrigation | Pond/Lake | Pond/Lake Site | River | Spring | Stream/Creek

	my $view1    = "N";
	my $view2    = 'Res';
	my $view3    = '';
	my $fullView = '';

	my $MLSview = $inrec->{'View'};
	if ( $MLSview =~ /Blue Ridge|Mountain/ig ) { #View-Blue Ridge
		$view3 = "Mtn";
	} elsif ( $MLSview =~ /Pastoral|Garden/ ) { #View-Pastoral
		$view3 = "Pstrl";
	} elsif ( $MLSview =~ /Water/ ) { #View-Water
		$view3 = "Wtr";
	} elsif ( $MLSview =~ /Woods/ ) { #View-Woods
		$view3 = "Woods";
	}

	# Analyze view according to area
	# Cville

	# Albemarle

	# Nelson

	# Fluvanna

	$fullView = $view1 . ";" . $view2 . ";" . $view3;
	$outrec->{'LotView'} = $fullView;

	#-----------------------------------------

	# DesignAppeal

	my $stories  = "";
	my $design   = "";
	my $design_uad = '';
	my $storynum = '';
	my $proptype = $inrec->{'PropType'};
	my $atthome  = $inrec->{'Attached Home'};
	$stories = $inrec->{'Level'};
		
	# Street Number
	#$stories =~ s/\D//;
	$stories =~ s/[^0-9\.]//ig;
	$outrec->{'Stories'} = $stories;
		
	if ( $proptype =~ /Detached/ig ) {
		$design  = $inrec->{'Design'};
		$design_uad = 'DT'.$stories.';'.$design;
	}
	
	elsif ( $proptype =~ /Attached/ig ) {
		$design = $inrec->{'Design'};
		if ( $atthome =~ /End Unit/ig ) {
			$design_uad ='SD'. $stories . ';' . $design;
		} elsif ( $atthome =~ /Duplex/ig ) {
			$design_uad ='SD'. $stories . ';' . $design;
		} else {
			$design_uad ='AT'. $stories . ';' . $design;
		}
	}
	$outrec->{'Design'} = $design;
	$outrec->{'DesignAppeal1'} = $design_uad;

	#-----------------------------------------

	# Age
	my $age = 0;

	#$age = $time{'yyyy'} - $inrec->{'Year Built'};
	
	# Age calculated from current year
	#$age = localtime->year + 1900 - $inrec->{'YearBuilt'};
	
	# Age calculated from year sold
	my $sdate = $inrec->{'Close Date'};
	my @da = ( $sdate =~ m/(\d+)/g );
	$age = $da[2] - $inrec->{'YearBuilt'};
	
	$outrec->{'Age'} = $age;

	#-----------------------------------------

	# DesignConstructionQuality
	# Q1 through Q6
	my $extcond = '';
	# use price per square foot after location/land
	
	my $soldpriceint = $soldprice;
	$soldpriceint =~ s/^\$//;
	$soldpriceint =~ s/,//g;
	
	if ( $soldpriceint > 2000000 ) {
		$extcond = "Q1";
	} elsif ( $soldpriceint > 1000000 ) {
		$extcond = "Q2";
	} elsif ( $soldpriceint > 175000 ) {
		$extcond = "Q3";
	} elsif ( $soldpriceint > 80000 ) {
		$extcond = "Q4";
	} else {
		$extcond = "";
	}
	#$extcond = '';
	$outrec->{'DesignConstrQual'} = $extcond;

	#-----------------------------------------

	# AgeCondition1
	my $agecondition = '';
	my $agecond      = '';
	if ( $age <= 1 ) {
		$agecond = "C1";
	} else {
		$agecond = "C3";
	}

#	my $kitcounter = $inrec->{"Kitchen Counters"};
#	if ( $kitcounter =~ /Granite|Marble|Quartz|Soapstone|Wood|Solid Surface/ ) {
#		$agecondition = "C2";
#	} else {
#		$agecondition = $agecond;
#	}
	#$agecond = '';
	$outrec->{'AgeCondition1'} = $agecond;

	#-----------------------------------------
	# CarStorage1
	# UAD output example: 2ga2cp2dw, 2gd2cp2dw,
	
	my $garage = '';
	my $gartype = '';
	my $carport = '';
	my $garnumcar = '';
	my $cpnumcar = '';
	my $dw = '';
	my $nogar = 1;
	my $nocp = 1;
	my $nodw = 1;
	my $carstortype = '';
	my $garfeat = $inrec->{'Garage Features'};
	
	if ( $inrec->{'Garage'} eq 'Y' ) {
	# check number of cars garage		
		$garnumcar = $inrec->{'Garage#Car'};
		if ( $garnumcar =~ /(\d)/ ) {
			$garnumcar = $1;
			# number of cars exists, so use that number
		} else {
			$garnumcar = 1;
		}
	
		# check if attached/detached/built-in

		if ( $garfeat =~ /Attached/){
			$gartype = 'ga';
		} elsif ( $garfeat =~ /Detached/) {
			$gartype = 'gd';
		} elsif ( $garfeat =~ /In Basement/) {
			$gartype = 'bi';
		}
		
		$carstortype = $garnumcar.$gartype;
		$nogar = 0;
	}
	
	# check for carport
	$cpnumcar = $inrec->{'Carpt#Car'};
	if ( $cpnumcar =~ /(\d)/ ) {
			$cpnumcar = $1;
			$nocp = 0;
			$carstortype = $carstortype . $cpnumcar . 'cp';
	}
		
	if ( $garfeat =~ /On Street Parking/) {
		$dw = '';
	}
		
	my $driveway = $inrec ->{'Driveway'};
	if ($driveway =~ /Asphalt|Brick|Concrete|Dirt|Gravel|Riverstone/){
		$dw = '2dw';	
		$carstortype = $carstortype . $dw;
	}
	
	if ($nogar && $nocp && $nodw) {
		$carstortype = 'None'
	}
	
	$outrec->{'CarStorage1'} = $carstortype;
	$outrec->{'CarStorage1Txt'} = 

	#-----------------------------------------

	# CoolingType
	my $heat    = '';
	my $cool    = '';
	my $divider = "/";
	my $cooling = $inrec->{'Air Conditioning'};
	my $heating = $inrec->{'Heating'};
	if ( ( $cooling =~ /Heat Pump/i ) || ( $heating =~ /Heat Pump/i ) ) {
		$heat    = "HTP";
		$cool    = '';
		$divider = '';
	} else {
		if ( $cooling =~ /Central AC/ ) {
			$cool = "CAC";
		} else {
			$cool = "No CAC";
		}
		if ( $heating =~ /Forced Air|Furnace/i ) {
			$heat = "FWA";
		} elsif ( $heating =~ /Electric/i ) {
			$heat = "EBB";
		} elsif ( $heating =~ /Baseboard|Circulator|Hot Water/i ) {
			$heat = "HWBB";
		} else {
			$heat = $heating;
		}
	}
	$outrec->{'CoolingType'} = $heat . $divider . $cool;

	#-----------------------------------------

	#23 FunctionalUtility
	$outrec->{'FunctionalUtility'} = "Average";

	#-----------------------------------------
	
# EnergyEfficiencies1
# EcoCert: LEED Certified  Energy Star | EarthCraft | Energy Wise | WaterSense Certified Fixtures
# Heating: Active Solar | Geothermal | passive Solar
# Windows: Insulated | Low-E
# Water Heater: Instant | Solar | Tankless

	# first check EcoCert
	my $energyeff = 'None';
	my $remarks   = $inrec->{'Remarks'};
	my $windows   = $inrec->{'Windows'};
	my $doors     = $inrec->{'Doors'};
	my $heats     = $inrec->{'Heating'};
	my $waterhtr  = $inrec->{'Water Heater'};
	my $ewndd     = '';
	my $eheat     = '';
	my $ewhtr     = '';
	if ( $remarks =~ /LEED/i ) {
		$energyeff = "LEED Cert";
	} elsif ( $remarks =~ /Energy Star/i ) {
		$energyeff = "EnergyStar Cert";
	} elsif ( $remarks =~ /EarthCraft /i ) {
		$energyeff = "EartCraft Cert";
	} elsif ( $remarks =~ /Energy Wise/i ) {
		$energyeff = "EnergyWise Cert";
	} else {
		if ( $windows =~ /insulated|low-e/i ) {
			$ewndd = "InsWnd ";
		}
		if ( $doors =~ /insul/i ) {
			if ( $ewndd =~ /InsWnd/ig ) {
				$ewndd = "InsWnd&Drs ";
			} else {
				$ewndd = "InsDrs ";
			}
		}
		if ( $heats =~ /Solar/i ) {
			$eheat = "Solar ";
		}
		if ( $heats =~ /Geothermal/i ) {
			$eheat = $eheat . "GeoHTP ";
		}
		if ( $waterhtr =~ /Solar/ ) {
			if ( $eheat !~ /Solar/ ) {
				$ewhtr = "Solar ";
			}
		}
		if ( $waterhtr =~ /Instant|Tankless/i ) {
			$ewhtr = "InstHW";
		}
		$energyeff = $eheat . $ewhtr . $ewndd;
		$energyeff =~ s/ /,/ig;
		$energyeff =~ s/,$//ig;
	}

	$outrec->{'EnergyEfficiencies1'} = $energyeff;

	#-----------------------------------------


# Rooms
# From CAAR MLS:
# Room count includes rooms on levels other than Basement.
# AtticApt, BasementApt, Bedroom, BilliardRm, Brkfast, BonusRm, ButlerPantry, ComboRm,
# DarkRm, Den, DiningRm, ExerciseRm, FamRm, Foyer, Full Bath, Gallery, GarageApt, GreatRm,
# Greenhse, Half Bath, HmOffice, HmTheater, InLaw Apt, Kitchen, Laundry, Library, LivingRm,
# Loft, Master BR, MudRm, Parlor, RecRm, Sauna, SewingRm, SpaRm, Study/Library, SunRm, UtilityRm

	my $rooms      = 0;
	my $fullbath   = 0;
	my $halfbath   = 0;
	my $bedrooms   = 0;
	my $bsRooms    = 0;
	my $bsRecRm    = 0;
	my $bsFullbath = 0;
	my $bsHalfbath = 0;
	my $bsBedrooms = 0;
	my $bsOther    = 0;
	my $bsRmCount  = 0;

	#maximum of 30 rooms
	#my @rmarr = split( /,/, $inrec->{'Rooms'} );
	my $room = '';
	my $indx  = 0;
	my $rindx = 0;
	my $rlim  = 30;
	my $rmtype = '';
	my $rmflr = '';
	my $roomnum = ''; 
	my $roomcount = '';	
	my $roomname = '';
	my $roomfieldname = '';
	my $roomlevfieldname = '';
	my $roomlev = '';
	while ( $rindx < $rlim ) {
		$roomcount = sprintf( "%02d", $rindx +1 );
		$roomfieldname = 'Rm'.$roomcount;
		$roomlevfieldname = $roomfieldname . 'Lv';
		$roomname = $inrec->{$roomfieldname};
		$roomlev = $inrec->{$roomlevfieldname};

		#my $rmtype = $rmarr[$rindx];
		#my $rmsz   = $rmarr[ $rindx + 1 ];
		#my $rmflr  = $rmarr[ $rindx + 2 ];
		#$rmtype =~ s/^\s+|\s+$//g;
		#$rmflr  =~ s/ //g;
		
		$roomname =~ s/^\s+|\s+$//g;
		$rmtype = $roomname;
		$roomlev =~ s/ //g;
		$rmflr = $roomlev;

		if ( $rmflr !~ /Basement/ ) {
			if ( $rmtype =~/Bedroom|Breakfast|Bonus|Den|Dining|Exercise|Family|Great|Home Office|Home Theater|Kitchen|Library|Living|Master|Mud|Parlor|Rec|Sauna|Sewing|Spa|Study|Library|Sun/i
			  )
			{
				$rooms++;
			}
			if ( $rmtype =~ /Full Bath/i ) {
				$fullbath++;
			}
			if ( $rmtype =~ /Half Bath/i ) {
				$halfbath++;
			}
			if ( $rmtype =~ /Bedroom|Master/ ) {
				$bedrooms++;
			}
		}
		if ( $rmflr =~ /Basement/ ) {
			if ( $rmtype =~
				 /Bonus|Den|Family|Great|Library|Living|Rec|Study|Library/i )
			{
				$bsRecRm++;
				$bsRmCount++;
			}
			if ( $rmtype =~/Breakfast|Dining|Exercise|Home Office|Home Theater|Kitchen|Mud|Parlor|Sauna|Sewing|Spa|Sun/i
			  )
			{
				$bsOther++;
				$bsRmCount++;
			}
			if ( $rmtype =~ /Full Bath/i ) {
				$bsFullbath++;
				$bsRmCount++;
			}
			if ( $rmtype =~ /Half Bath/i ) {
				$bsHalfbath++;
				$bsRmCount++;
			}
			if ( $rmtype =~ /Bedroom|Master/ ) {
				$bsBedrooms++;
				$bsRmCount++;
			}
		}

		$indx++;
		$rindx++
		#$rindx = $indx * 3;

	}
	if ( $rooms < $bedrooms + 2 ) {
		$rooms = $bedrooms + 2;
	}

	$outrec->{'Rooms'} = $rooms;

	my $bsRmList = '';
	my $bsRmListTxt = '';
#	if ( $bsRmCount > 0 ) {
#		if ( $bsRecRm > 0 )    { $bsRmList = $bsRecRm . "rr"; }
#		if ( $bsBedrooms > 0 ) { $bsRmList = $bsRmList . $bsBedrooms . "br"; }
#		if ( ( $bsFullbath + $bsHalfbath ) > 0 ) {
#			$bsRmList = $bsRmList . $bsFullbath . "." . $bsHalfbath . "ba";
#		}
#		if ( $bsOther > 0 ) { $bsRmList = $bsRmList . $bsOther . "o"; }
#	}
	$bsRmList = $bsRecRm . 'rr' . $bsBedrooms . 'br' . $bsFullbath . '.' . $bsHalfbath . 'ba' . $bsOther . 'o';
	$bsRmListTxt = $bsRecRm . $w . $bsBedrooms . $w . $bsFullbath . '.' . $bsHalfbath . $w . $bsOther;
	
	# Basement2
	$outrec->{'Basement2'} = $bsRmList;
	$outrec->{'Basement2Txt'} = $bsRmListTxt;
	$outrec->{'BsRecRm'} = $bsRecRm;
	$outrec->{'BsBedRm'} = $bsBedrooms;
	$outrec->{'BsFullB'} = $bsFullbath;
	$outrec->{'BsHalfB'} = $bsHalfbath;
	$outrec->{'BsOther'} = $bsOther;

	#-----------------------------------------

	# Bedrooms
	my $bedroomstot = $inrec->{'#Beds'};

	$outrec->{'Beds'} = $bedrooms;

	#-----------------------------------------

	# Baths
	my $baths = 0;
#	if ( $fullbath == 0 ) {
#		$fullbath = $inrec->{'#FBaths'};
#		$halfbath = $inrec->{'#HBaths'};
#	}

	$fullbath = $inrec->{'#FBaths'};
	$halfbath = $inrec->{'#HBaths'};
	my $bgbath = $inrec->{'#BathsBG'};
	if ($bgbath =~ /.5/){
		$halfbath = $halfbath - 1;
		$bgbath = $bgbath - 1;
	}
	if ($bgbath >= 1){
		$fullbath = $fullbath - $bgbath;
	}
	my $bathnum = $fullbath + $halfbath / 10;
	my $bathstr = "$fullbath.$halfbath";
	$baths = sprintf( "%.1f", $bathnum );
	$outrec->{'Baths'} = $bathstr;

	#-----------------------------------------

	# BathsFull
	$outrec->{'BathsFull'} = $fullbath;

	#-----------------------------------------

	# BathsHalf
	$outrec->{'BathsHalf'} = $halfbath;

	#-----------------------------------------

	 # Basement1
	 # Crawl | English | Finished | Full | Heated | Inside Access | Outside Access |
	 # Partial | Partly Finished | Rough Bath Plumb | Shelving | Slab | Sump Pump |
	 # Unfinished | Walk Out | Windows | Workshop

	$outrec->{'Basement1'} = '';

	#-----------------------------------------

	# Basement2
	#$outrec->{'Basement2'} = $bsmntfin;

	#-----------------------------------------

	$outrec->{'ExtraCompInfo2'} = '';

	#-----------------------------------------

	# ExtraCompInfo1 (Fireplaces)
	my $fp;
	my $fpout = '';
	my $numFPword = $inrec->{'Fireplace'};
	my $numFP = '';
	
	if ($numFPword =~ /One/ ) {
		$numFP = 1;
	} elsif ($numFPword =~ /Two/ ) {
		$numFP = 2;
	} elsif ($numFPword =~ /Three/ ) {
		$numFP = 3;
	} else {
		$numFP = 0 
	}

	my $locFP = $inrec->{'Fireplace Location'};
	my $locFPcnt = $locFP =~ (m/Basement|Bedroom|Den|Dining Room|Exterior Fireplace|Family Room|Foyer|Great Room|!
								Home Office|Kitchen|Library|Living Room|Master Bedroom|Study/ig
	);
	if ( !$locFPcnt ) { $locFPcnt = 0 }

	if ( $numFP >= $locFPcnt ) {
		$fp = $numFP;
	} elsif ( $locFPcnt >= $numFP ) {
		$fp = $locFPcnt;
	} elsif ( $numFP == 0 && $locFPcnt == 0 ) {
		$fpout = "0 Fireplace";
	}

	if ( $fp == 0 ) {
		$fpout = "0 Fireplace";
	}

	if ( $fp == 1 ) {
		$fpout = $fp . " Fireplace";
	} elsif ( $fp > 1 ) {
		$fpout = $fp . " Fireplaces";
	}

	$outrec->{'ExtraCompInfo1'} = $fpout;

	#-----------------------------------------

	# SqFt Source: Appraisal, Builder, Other, Owner, Tax Assessor
	my $sqftsrc = '';

	#-----------------------------------------

	# SqFt (after basement is determined)
	# Square foot fields added to CAAR on 7/19/2011:
	# SqFt Above Grade Fin
	# SqFt Above Grade Total
	# SqFt Above Grade UnFin
	# SqFt Below Grade Fin
	# SqFt Below Grade Total
	# SqFt Below Grade Unfin
	# SqFt Fin Total
	# SqFt Garage Fin
	# SqFt Garage Total
	# SqFt Garage Unfin
	# SqFt Total
	# SqFt Unfin Total

	my $sfAGFin = $inrec->{'AGFin'};
	my $sfAGTot = $inrec->{'AGTotSF'};
	my $sfAGUnF = $inrec->{'AGUnfin'};
	my $sfBGFin = $inrec->{'BGFin'};
	my $sfBGTot = $inrec->{'BGTotSF'};
	my $sfBGUnF = $inrec->{'BGUnfin'};
	my $sfFnTot = $inrec->{'TotFinSF'};
	my $sfGaFin = $inrec->{'GarAGFin'};
	my $sfGaTot = $inrec->{'GarTotAG'};
	my $sfGaUnF = $inrec->{'GarAGUnf'};
	my $sfTotal = $inrec->{'TotFinSF'};
	my $sfUnTot = $inrec->{'TotUnfinSF'};

	#my $listdate = Date::EzDate->new( $inrec->{'List Date'} );
	#if ( $listdate >= $sfDate ) {
	my $basType = "wo";
	my $basTypeTxt = "Walk-out";
	if ( $sfAGFin > 0 ) {
		$outrec->{'SqFt'} = $sfAGFin;
		if ( $sfBGTot == 0 ) {
			$outrec->{'Basement1'} = "0sf";
		} else {
			my $basExit = $inrec->{'Bsmnt_2'};
			if ( $basExit =~ /Walk Out/ig ) {
				$basType = "wo";
				$basTypeTxt = "Walk-out";
			} elsif ( $basExit =~ /Outside Entrance/ig ) {
				$basType = "wu";
				$basTypeTxt = "Walk-up";
			} elsif ( $basExit =~ /Inside Access/ig ) {
				$basType = "in";
				$basTypeTxt = "Interior-only";
			} 

			#Walk Out
			if ( $sfBGFin == 0 ) {
				$outrec->{'Basement1'} = $sfBGTot . "sf" . 0 . $basType;
				$outrec->{'Basement1Txt'} = $sfBGTot . $w . 0 . $w . $basTypeTxt;
			} else {
				$outrec->{'Basement1'} = $sfBGTot . "sf" . $sfBGFin . "sf" . $basType;
				$outrec->{'Basement1Txt'} = $sfBGTot . $w . $sfBGFin . $w . $basTypeTxt;
			}
		}
	} else {
		# SF Above Grade not entered, use SqFt Fin total
		my $sqft        = '';
		my $sqftabvGrnd = '';
		my $bsmntyn = $inrec->{'Bsmnt_1'};
		my $bsmntfin = $inrec->{'Bsmnt_2'};
		
		if ( ( $sfAGFin eq '' ) | ( $sfAGFin eq undef ) | ( $sfAGFin == 0 ) ) {


			$sfAGFin = $inrec->{'TotFinSF'};
			$stories = $inrec->{'Levels'};
			$sqft    = $sfAGFin;
			if ( $bsmntyn eq 'No' ) {
				$sqftabvGrnd = $sqft;

			} elsif ( $bsmntfin eq 'Finished' ) {
				if ( $stories eq '1 Story' ) {
					$sqftabvGrnd = round( 0.5 * $sqft );
				} elsif ( $stories eq '1.5 Story' ) {
					$sqftabvGrnd = round( 0.6 * $sqft );
				} elsif ( $stories eq '2 Story' ) {
					$sqftabvGrnd = round( 0.67 * $sqft );
				} else {
					$sqftabvGrnd = round( 0.75 * $sqft );
				}

			} elsif ( $bsmntfin eq 'Partly Finished' ) {
				if ( $stories eq '1 Story' ) {
					$sqftabvGrnd = round( 0.67 * $sqft );
				} elsif ( $stories eq '1.5 Story' ) {
					$sqftabvGrnd = round( 0.75 * $sqft );
				} elsif ( $stories eq '2 Story' ) {
					$sqftabvGrnd = round( 0.8 * $sqft );
				} else {
					$sqftabvGrnd = round( 0.8 * $sqft );
				}

			} else {
				$sqftabvGrnd = $sqft;
			}

		} else {
			$sqftabvGrnd = $sfAGFin;
		}

		$outrec->{'SqFt'} = $sqftabvGrnd;
	}
	
	#-----------------------------------------

# Porch ()Porch/Patio/Deck)
# Porch: Balcony | Brick | Deck | Front | Glassed | Patio | Porch | Rear | Screened | Side | Slate | Terrace
	my $pchcnt = 0;
	my $balcnt = 0;
	my $dekcnt = 0;
	my $patcnt = 0;
	my $tercnt = 0;
	
	my $pchout = '';
	my $pdp= $inrec->{'Structure-Deck/Porch'};
	if ($pdp =~ /Porch[^ -]|Rear|Side/){
		$pchout = "Pch ";
		$pchcnt++;
	}
	if ($pdp =~ /Front/ig){
		$pchout = $pchout . "FPc ";
		$pchcnt++
	}
	if ($pdp =~ /Screened/ig){
		$pchout = $pchout. "ScPc ";
		$pchcnt++
	}
	if ($pdp =~ /Glassed/ig){
		$pchout = $pchout. "EncPc ";
		$pchcnt++
	}
	
	$outrec->{'Porch'} = $pchout;

	#-----------------------------------------

	my $patout = '';
	if ($pdp =~ /Patio[^ -]/){
		$patout = "Pat ";
	}
	if ($pdp =~ /Covered/ig){
		$patout = $pchout . "CvPat ";
	}
	$outrec->{'Patio'} = $patout;

	#-----------------------------------------

	my $dkout = '';
	if ($pdp =~ /Deck/){
		$patout = "Deck ";
	}
	$outrec->{'Deck'} = $dkout;

	#-----------------------------------------

	# FencePorchPatio2
	my $totpchcnt = 0;
	my $pdpout    = '';

	$pdpout = $pchout . $patout . $dkout;
	$outrec->{'FencePorchPatio2'} = $pdpout;

	#-----------------------------------------

	# ExtraCompInfo3
	$outrec->{'ExtraCompInfo3'} = $pdpout;

	#-----------------------------------------

	# Notes1
	$outrec->{'Notes1'} = "Imported from CAAR";

	#-----------------------------------------

	# Photo
	my $photo = '';
	$photo = $inrec->{'Photo 1'};
	$outrec->{'Photo'} = '';

	#-----------------------------------------

	my $mediaflag = '';
	$mediaflag = $inrec->{'Media Flag'};
	$outrec->{'MediaFlag'} = '';
	#-----------------------------------------

	my $medialink = $inrec->{'Media Link'};
	my $mediapath = '';
	if ( $mediaflag =~ m/1 Photo|Multiphotos/ig ) {
		if ( $medialink =~ /(http:\/\/www.caarmls.com.*?.jpg>)/ix ) {
			$mediapath = $1;
		}
	}
	$outrec->{'MediaLink'} = '';

	#-----------------------------------------

	# ML Number
	my $mlnumber = '';
	$mlnumber = $inrec->{'MLS#'};
	$outrec->{'MLNumber'} = $mlnumber;

	#-----------------------------------------

	# ML Prop Type
	$proptype             = '';
	$proptype             = $inrec->{'PropType'};
	$outrec->{'PropType'} = $proptype;

	#-----------------------------------------

	# ML County
	my $county = '';
	my $area   = '';
	$area = $inrec->{'Cnty/IncC'};
	switch ($area) {
		case '001' { $county = "Albemarle" }
		case '002' { $county = "Amherst" }
		case '003' { $county = "Augusta" }
		case '004' { $county = "Buckingham" }
		case '005' { $county = "Charlottesville" }
		case '006' { $county = "Culpeper" }
		case '007' { $county = "Fauquier" }
		case '008' { $county = "Fluvanna" }
		case '009' { $county = "Goochland" }
		case '010' { $county = "Greene" }
		case '011' { $county = "Louisa" }
		case '012' { $county = "Madison" }
		case '013' { $county = "Nelson" }
		case '014' { $county = "Orange" }
		case '015' { $county = "Rockbridge" }
		case '016' { $county = "Waynesboro" }
		case '017' { $county = "Other" }
	}
	$outrec->{'County'} = $county;

	#-----------------------------------------

	# DateofPriorSale1
	my $dateofPriorSale1 = '';
	$outrec->{'DateofPriorSale1'} = $dateofPriorSale1;

	#-----------------------------------------

	# PriceofPriorSale1
	my $priceofPriorSale1 = '';
	$outrec->{'PriceofPriorSale1 '} = $priceofPriorSale1;

	#-----------------------------------------

	# DataSourcePrior1
	my $dataSourcePrior1 = "Assessors Records";
	if ( $area >= 9 ) {
		$dataSourcePrior1 = "Courthouse Records";
	}
	$outrec->{'DataSourcePrior1'} = $dataSourcePrior1;

	#-----------------------------------------

	# EffectiveDatePrior1
	my $effectiveDatePrior1 = '';
	$outrec->{'EffectiveDatePrior1'} = $effectiveDatePrior1;

	#-----------------------------------------

	# Agent Notes
	my $agentNotes = ''; #$inrec->{'Agent Notes'};
	if ( defined $agentNotes ) {

		# $outrec->{'AgentNotes'} = $agentNotes;
		$outrec->{'AgentNotes'} = '';
	}

	#-----------------------------------------

	# Dependencies
	my $dependencies = $inrec->{'Dependencies'};
	if ( defined $dependencies ) {
		$outrec->{'Dependencies'} = $dependencies;
	}

	#-----------------------------------------

	# Zoning
	my $zoning = $inrec->{'Zoning'};
	if ( defined $zoning ) {
		$outrec->{'Zoning'} = $zoning;
	}

	#-----------------------------------------

	# Hoa Fee
	my $hoafee = $inrec->{'AssnFee'};
	if ( defined $hoafee ) {
		$outrec->{'HoaFee'} = $hoafee;
	}

	#-----------------------------------------

	#condo specific

	my $aprop = $inrec->{'PropType'};
	if ( $aprop =~ /Condo/ig ) {

		# Unit Number
		my $unitnum = $inrec->{'Unit#'};
		$outrec->{'Unitnum'} = $unitnum;

# Amenities
#Art Studio | Bar/Lounge | Baseball Field | Basketball Court | Beach | Billiard Room
#| Boat Launch | Clubhouse | Community Room | Dining Rooms | Exercise Room | Extra Storage
#| Golf | Guest Suites | Lake | Laundry Room | Library | Meeting Room | Newspaper Serv.
#| Picnic Area | Play Area | Pool | Riding Trails | Sauna | Soccer Field | Stable
#| Tennis | Transportation Service | Volleyball | Walk/Run Trails

# | Walk/Run Trails | Boat Launch | Clubhouse | Community Room | Exercise Room
# | Extra Storage | Golf | Play Area | Pool | Riding Trails | Sauna | Stable Tennis | Walk/Run Trails

		my $amenities = $inrec->{'Amenities(HOA/Club/Sub)'};
		$outrec->{'Amenities'} = $amenities;

		# stories
		# 1-4 stories:  stories
		# 5-7:			mid-rise
		# 8 and higher: High-rise

		# address modified with unit number
		$outrec->{'Address1'} = $outrec->{'Address1'} . ", #" . $unitnum;

		# location set to city

		# subdivision set to project name

	}

	#-----------------------------------------
	#-----------------------------------------
	# CAAR_Resid Last Line
	#my $pnum = 1;
	while ( my ( $k, $v ) = each %$outrec ) {
		print $outfile "$v\t";

		# print "$pnum\n";
		# $pnum = $pnum+1;
	}
	print $outfile "\n";

}

sub CAAR_Resid_Text {
	# output comparable as text file for direct copy into Total
	my ($outrec)  = shift;
	my ($outfile) = shift;
	
	my $or = $outrec;
	my $w = sprintf( '%c', 8 );

	# Line	Form Field					input field	
	#	1	111 Street Ave				street address (from MLS)				
	#	2	City, ST 12345				street address
	#	3	CityST12345				city, state, zip
	#	4   Proximity
	#	5   Sale Price
	#	6   Price per square foot
	#	7   CAARMLS#;DOM
	#	8   CAARMLS#DOM
	#	9   Tax Records
	#	10  sale type
	#	11  financing type;concession amount
	#	12  financing typeconcession amount
	#	13  s02/17;c01/17
	#	14  Settled saleX01/1702/17
	#	15  N;Res;
	#	16  NeutralResidential
	#	17  Fee Simple
	#	18  21780 sf
	#	19  N;Res;
	#	20  NeutralResidential
	#	21  DT2;Colonial
	#	22  X2Colonial
	#   23  Q3
	#	24  10
	#	25  C3
	#	26  742.1
	#	27  2,500
	#	28  2500sf1000sfwo
	#	29  25001000Walk-out
	#	30  1rr1br1.1ba1o
	#	31  111.11
	#	32  Average
	#	33  FWA/CAC
	#	34  InsulWnd&Drs
	#	35  2ga2dw
	#   36  22
	#	37  CvP,Deck
	#	38  1 Fireplace
	#
	
	#pre-processing of some fields for text output
	my $uadexp1 = $or->{'FinFullNm'}.$w.$or->{'FinOther'}.$w.$or->{'Conc'};
	my $datestr = $or->{'SaleStatus'}.$w."X".$w.$w.$or->{'ContDate'}.$w.$or->{'SaleDate'}.$w.$w.$w.$w;
	my $design  = "x".$w.$w.$w.$or->{'Stories'}.$w.$or->{'Design'}.$w.$w;
	my $rooms   = $or->{'Rooms'}.$w.$or->{'Beds'}.$w.$or->{'Baths'}.$w.$w;
	
	tie my %comp   => 'Tie::IxHash',
	  address1     => $or->{'Address1'}.$w,
	  address2     => $or->{'Address2'}.$w,
	  citystzip    => $or->{'City'}.$w.$or->{'State'}.$w.$or->{'Zip'}.$w,
	  proximity    => $w,
	  saleprice    => $or->{'SalePrice'}.$w,
	  saleprgla    => $w,
	  datasrc      => $or->{'DataSource1'}.$w."CAARMLS #".$or->{'MLNumber'}.$w.$or->{'DOM'}.$w,,
	  versrc       => $or->{'DataSource2'}.$w,
	  saletype     => $or->{'FinanceConcessions1'}.$w.$w,
	  finconc      => $or->{'FinanceConcessions2'}.$w.$uadexp1.$w.$w,
	  datesale     => $or->{'SaleDateFormatted'}.$w.$datestr,
	  location     => "N;Res".$w."Neutral".$w."Residential".$w.$w.$w.$w.$w,
	  lsorfeesim   => "Fee Simple".$w.$w,
	  site         => $or->{'LotSize'}.$w.$w,
	  view         => "N;Res".$w."Neutral".$w."Residential".$w.$w.$w.$w.$w,,
	  designstyle  => $or->{'DesignAppeal1'}.$w.$design,
	  quality      => $or->{'DesignConstrQual'}.$w.$w,
	  age          => $or->{'Age'}.$w.$w,
	  condition    => $or->{'AgeCondition1'}.$w.$w.$w,
	  roomcnt      => $rooms,
	  gla          => $or->{'SqFt'}.$w.$w,
	  basement     => $or->{'Basement1'}.$w.$or->{'Basement1Txt'}.$w.$w,
	  basementrm   => $or->{'Basement2'}.$w.$or->{'Basement2Txt'}.$w.$w,
	  funcutil     => "Average".$w.$w,
	  heatcool     => $or->{'CoolingType'}.$w.$w,
	  energyeff    => $or->{'EnergyEfficiencies1'}.$w.$w,
	  garage       => $or->{'CarStorage1'}.$w.$w,
	  pchpatdk     => $or->{'FencePorchPatio2'}.$w.$w,
	  fireplace    => $or->{'ExtraCompInfo1'}.$w.$w;
	  
	  my $x = 1;
	  print $outfile "\n";
	  while ( my ( $key, $value ) = each(%comp) ) 
	  {
		print $outfile ($value);
	  }
	  print $outfile "\n";
	  
}

sub CAAR_Resid_NG {
	my ($inrec)   = shift;
	my ($outrec)  = shift;
	my ($outfile) = shift;
	my ($outfileT) = shift;
	
	my $wtline = sprintf( '%c', 8 );

# Line	Form Field					input field	
#	1	111 Street Ave				street address (from MLS)				
#	2	City, ST 12345				street address
#	3	CityST12345				city, state, zip
#	4   Proximity
#	5   Sale Price
#	6   Price per square foot
#	7   CAARMLS#;DOM
#	8   CAARMLS#DOM
#	9   Tax Records
#	10  sale type
#	11  financing type;concession amount
#	12  financing typeconcession amount
#	13  s02/17;c01/17
#	14  Settled saleX01/1702/17
#	15  N;Res;
#	16  NeutralResidential
#	17  Fee Simple
#	18  21780 sf
#	19  N;Res;
#	20  NeutralResidential
#	21  DT2;Colonial
#	22  X2Colonial
#   23  Q3
#	24  10
#	25  C3
#	26  742.1
#	27  2,500
#	28  2500sf1000sfwo
#	29  25001000Walk-out
#	30  1rr1br1.1ba1o
#	31  111.11
#	32  Average
#	33  FWA/CAC
#	34  InsulWnd&Drs
#	35  2ga2dw
#   36  22
#	37  CvP,Deck
#	38  1 Fireplace

	tie my %comp   => 'Tie::IxHash',
	  address1     => '',
	  address2     => '',
	  citystzip    => '',
	  proximity    => '',
	  saleprice    => '',
	  saleprgla    => '',
	  datasrc      => '',
	  versrc       => '',
	  saleconc     => '',
	  finconc      => '',
	  datesale     => '',
	  location     => '',
	  lsorfeesim   => '',
	  site         => '',
	  view         => '',
	  designstyle  => '',
	  quality      => '',
	  age          => '',
	  condition    => '',
	  roomcnt      => '',
	  gla          => '',
	  basement     => '',
	  basementrm   => '',
	  funcutil     => '',
	  heatcool     => '',
	  energyeff    => '',
	  garage       => '',
	  pchpatdk     => '',
	  fireplace    => '';
	  
	my $tc = Lingua::EN::Titlecase->new("initialize titlecase");
	my %addrArgs = (
					 country                     => 'US',
					 autoclean                   => 1,
					 force_case                  => 1,
					 abbreviate_subcountry       => 0,
					 abbreviated_subcountry_only => 1
	);
	my $laddress = new Lingua::EN::AddressParse(%addrArgs);

	my $address = $inrec->{'Address'};
	my $streetnum = '';
	# Street Number
	if ($address =~ /(\d+)/) {
		$streetnum = $1;
	}
	$outrec->{'StreetNum'} = $streetnum;
	#-----------------------------------------

	$outrec->{'StreetDir'} = '';
	
	#-----------------------------------------
	
	my $address1 = $tc->title($inrec->{'Address'});
	$outrec->{'Address1'} = $address1;	
	$comp{'address1'} = $address1.$wtline;
	
	#-----------------------------------------

# TODO get rid of close files
	#close $outfile;
	#close $outfileT;

	# Address 2
	my $city = $inrec->{'City'};
	$city = $tc->title($city);
	$city =~ s/\(.*//;
	$city =~ s/\s+$//;
	my $address2 = $city . ", " . "VA " . $inrec->{'Zip'};
	$outrec->{'Address2'} = $address2;
	
	my $citystatezip = $city.$wtline."VA".$wtline.$inrec->{zip};
	$comp{'address2'} = $address2.$wtline.$citystatezip.$wtline;
	
	#-----------------------------------------

	# Address 3
	my $address3 = "VA" . " " . $inrec->{'Zip'};
	$outrec->{'Address3'} = $address3;

	#-----------------------------------------

	# City
	$outrec->{'City'} = $city;

	#-----------------------------------------

	# State
	$outrec->{'State'} = "VA";

	#-----------------------------------------

	# Zip
	$outrec->{'Zip'} = $inrec->{'Zip'};

	#-----------------------------------------

	# SalePrice
	my $soldstatus = 0;
	my $soldprice  = 0;
	my $recstatus  = $inrec->{'Status'};
	if ( $recstatus eq 'SLD' ) {
		$soldstatus = 0;                        #sold
		$soldprice  = $inrec->{'Sold Price'};
	} elsif ( $recstatus =~ m /ACT/i ) {
		$soldstatus = 1;                        #Active
		$soldprice  = $inrec->{'Price'};
	} elsif ( $recstatus =~ m /PND/i ) {
		$soldstatus = 2;                        #Pending
		$soldprice  = $inrec->{'Price'};
	} elsif ( $recstatus =~ m /CNT/i ) {
		$soldstatus = 3;                        #Contingent
		$soldprice  = $inrec->{'Price'};
	} elsif ( $recstatus =~ m /EXP/i ) {
		$soldstatus = 4;                        #Withdrawn
		$soldprice  = $inrec->{'Price'};
	} else {

		#nothing
	}
	$outrec->{'SalePrice'} = $soldprice;

	#-----------------------------------------

	# SoldStatus
	$outrec->{'Status'} = $soldstatus;

	#-----------------------------------------

	# DataSource1
	my $datasrc =
	  "CAARMLS#" . $inrec->{'MLS#'} . ";DOM " . $inrec->{'DOM'};
	$outrec->{'DataSource1'} = $datasrc;

	#-----------------------------------------

	# Data Source 2
	$outrec->{'DataSource2'} = "Tax Records";

	#-----------------------------------------

	# Finance Concessions Line 1
	# REO		REO sale
	# Short		Short sale
	# CrtOrd	Court ordered sale
	# Estate	Estate sale
	# Relo		Relocation sale
	# NonArm	Non-arms length sale
	# ArmLth	Arms length sale
	# Listing	Listing

	my $finconc1 = '';
	if ( $soldstatus == 0 ) {	
		my $agentnotes = $inrec->{'Agent Notes'};
		
		if ( $inrec->{'Foreclosur'} =~ /Yes/i ) {
			$finconc1 = "REO";
		} elsif ( $inrec->{'LenderOwn'} =~ /Yes/i ) {
			$finconc1 = "REO";
		} elsif ( $inrec->{'ShortSale'} =~ /Yes/i ) {
			$finconc1 = "Short";
		} elsif ( $agentnotes =~ /court ordered /i ) {
			$finconc1 = "CrtOrd";
		} elsif ( $agentnotes =~ /estate sale /i ) {
			$finconc1 = "Estate";
		} elsif ( $agentnotes =~ /relocation /i ) {
			$finconc1 = "Relo";
		} else {
			$finconc1 = "ArmLth";
		}
	} elsif ( $soldstatus == 1 ) {
		$finconc1 = "Listing";
	} elsif ( $soldstatus == 2 ) {
		$finconc1 = "Listing";
	} elsif ( $soldstatus == 3 ) {
		$finconc1 = "Listing";
	} else {
		$finconc1 = '';
	}
	$outrec->{'FinanceConcessions1'} = $finconc1;

	#-----------------------------------------

	# FinanceConcessions2
	# Type of financing:
	# FHA		FHA
	# VA		VA
	# Conv		Conventional
	# Seller 	Seller
	# Cash 		Cash
	# RH		Rural Housing
	# Other
	# Format: 12 Char maximum

	my $finconc2    = '';
	my $conc        = '';
	my $finconc2out = '';
	if ( $soldstatus == 0 ) {
		my $terms = $inrec->{'How Sold'};
		if ( $terms eq '0' ) {
			$finconc2 = "NotSpec";    #Not Specified
		} elsif ( $terms =~ /CASH/ig ) {
			$finconc2 = "Cash";
		} elsif ( $terms =~ /CNVFI/ig ) {
			$finconc2 = "Conv";
		} elsif ( $terms =~ /CNVAR/ig ) {
			$finconc2 = "Conv";
		} elsif ( $terms =~ /FHA/ig ) {
			$finconc2 = "FHA";
		} elsif ( $terms =~ /VHDA/ig ) {
			$finconc2 = "VHDA";
		} elsif ( $terms =~ /FHMA/ig ) {
			$finconc2 = "FHMA";
		} elsif ( $terms =~ /VA/ig ) {
			$finconc2 = "VA";
		} elsif ( $terms =~ /ASSMT/ig ) {
			$finconc2 = "AsmMtg";
		} elsif ( $terms =~ /PVTMT/ig ) {
			$finconc2 = "PrvMtg";
		} elsif ( $terms =~ /OWNFN/ig ) {
			$finconc2 = "Seller";
		} elsif ( $terms =~ /Other/ig ) {
			$finconc2 = "Other";
		} elsif ( $terms =~ /USDAR/ig ) {
			$finconc2 = "USDA";
		}else {
			$finconc2 = "Other";
		}

		$conc = 0;
		if ( $inrec->{'SellerConc'} ) {
			$conc = USA_Format( $inrec->{'SellerConc'} );
			$conc =~ s/$//;
			$conc = $inrec->{'SellerConc'};
		}
		$finconc2out = $finconc2 . ";" . $conc;
	}

	#$finconc2out = 'FHA;0';
	$outrec->{'FinanceConcessions2'} = $finconc2out;

	#-----------------------------------------

	# DateSaleTime1
	my $datesaletime1 = '';
	if ( $soldstatus == 0 ) {
		$datesaletime1 = $inrec->{'Close Date'};
	} else {
		$datesaletime1 = $inrec->{'Lst Date'};
	}
	my $dateonly = '';
	if ( $datesaletime1 =~
		 m/((0?[1-9]|1[012])\/(0?[1-9]|[12][0-9]|3[01])\/(19|20)\d\d)/ )
	{
		$dateonly = $1;
	}
	$outrec->{'DateSaleTime1'} = $dateonly;

	#-----------------------------------------

	# DateSaleTime2
	my $datesaletime2 = '';
	if ( $soldstatus == 0 ) {
		my $sdate = $inrec->{'Close Date'};
		my @da = ( $sdate =~ m/(\d+)/g );
		$datesaletime2 = $da[2] . "/" . $da[0] . "/" . $da[1];

		#time_manip('yyyy/mm/dd', $sdate );
	}
	$outrec->{'DateSaleTime2'} = $datesaletime2;

	#-----------------------------------------
	# SaleDateFormatted
	# Sale and Contract formatted as mm/yy
	my $sdatestr    = '';
	my $cdatestr    = '';
	my $wsdatestr   = '';
	my $wcdatestr   = '';
	my $fulldatestr = '';
	if ( $soldstatus == 0 ) {
		my $sdate = $inrec->{'Close Date'};
		my @da = ( $sdate =~ m/(\d+)/g );

		#my $m2digit = sprintf("%02d", $da[0]);
		my $m2digit  = sprintf( "%02d", $da[0] );
		my $yr2digit = sprintf( "%02d", $da[2] % 100 );
		$sdatestr  = "s" . $m2digit . "/" . $yr2digit;
		$wsdatestr = $m2digit . "/" . $yr2digit;

		my $cdate = $inrec->{'Cont Date'};
		if ( ( $cdate eq undef ) || ( $cdate eq "" ) ) {
			$cdatestr = "Unk";
		} else {
			my @da = ( $cdate =~ m/(\d+)/g );
			my $m2digit  = sprintf( "%02d", $da[0] );
			my $yr2digit = sprintf( "%02d", $da[2] % 100 );
			$cdatestr  = "c" . $m2digit . "/" . $yr2digit;
			$wcdatestr = $m2digit . "/" . $yr2digit;
		}
		$fulldatestr = $sdatestr . ";" . $cdatestr;
	} elsif (    ( $soldstatus == 1 )
			  || ( $soldstatus == 2 )
			  || ( $soldstatus == 3 ) )
	{
		$fulldatestr = "Active";
	}

	#$outrec->{'CloseDate'} = $wsdatestr;
	#$outrec->{'ContrDate'} = $wcdatestr;

	#$fulldatestr = 's12/11;c11/11';
	$outrec->{'SaleDateFormatted'} = $fulldatestr;

	#-----------------------------------------

	# Location
	# N - Neutral, B - Beneficial, A - Adverse
	# Res		Residential
	# Ind		Industrial
	# Comm		Commercial
	# BsyRd		Busy Road
	# WtrFr		Water Front
	# GlfCse	Golf Course
	# AdjPrk	Adjacent to Park
	# AdjPwr	Adjacent to Power Lines
	# LndFl		Landfill
	# PubTrn	Public Transportation

	# basic neutral residential
	my $loc1    = "N";
	my $loc2    = "Res";
	my $loc3    = '';
	my $fullLoc = $loc1 . ";" . $loc2;

	# special cases
	#	my $spLoc;
	#	$spLoc =~ s/Wintergreen Mountain Village/Wintergreen Mtn/ig;
	#	$location =~ s/1800 Jefferson Park Ave/Charlottesville/ig;
	#	my $fullLoc = $loc1 . ";" . $loc2;

	$outrec->{'Location1'} = $fullLoc;

	# Original Non-UAD Location
	#	my $location;
	#	my $subdiv;
	#
	#	$subdiv = $inrec->{'Subdivision'};
	#	if ( $subdiv =~ m/NONE/ig ) {
	#		$location = $tc->title($city);
	#	} else {
	#		$subdiv =~ s/`/'/;
	#		$subdiv = $tc->title($subdiv);
	#		$subdiv =~ s/\(.*//;
	#		$subdiv =~ s/\s+$//;
	#		$location = $subdiv;
	#	}
	#	$location =~ s/Wintergreen Mountain Village/Wintergreen Mtn/ig;
	#	$location =~ s/1800 Jefferson Park Ave/Charlottesville/ig;
	#
	#	$outrec->{'Location1'} = $location;

	#-----------------------------------------

	# PropertyRights
	$outrec->{'PropertyRights'} = "Fee Simple";

	#-----------------------------------------

	# Site
	# MLS: LotSize
	my $acres      = $inrec->{'Acres #'};
	my $acresuffix = '';
	my $outacres   = '';
	if ( $acres < 0.001 ) {
		$outacres = '';
	}
	if ( ( $acres > 0.001 ) && ( $acres < 1.0 ) ) {
		my $acresf = $acres * 43560;
		$outacres = sprintf( "%.0f", $acresf );
		$acresuffix = " sf";
	}
	if ( $acres >= 1.0 ) {
		$outacres = sprintf( "%.2f", $acres );
		$acresuffix = " ac";
	}
	$outrec->{'LotSize'} = $outacres . $acresuffix;

	#-----------------------------------------

	# View
	# N - Neutral, B - Beneficial, A - Adverse
	# Wtr		Water View
	# Pstrl		Pastoral View
	# Woods		Woods View
	# Park		Park View
	# Glfvw		Golf View
	# CtySky	City View Skyline View
	# Mtn		Mountain View
	# Res		Residential View
	# CtyStr	CtyStr
	# Ind		Industrial View
	# PwrLn		Power Lines
	# LtdSght	Limited Sight

# MLS LotView
# Blue Ridge | Garden | Golf | Mountain | Pastoral | Residential | Water | Woods
# Water properties: Bay/Cove | Irrigation | Pond/Lake | Pond/Lake Site | River | Spring | Stream/Creek

	my $view1    = "N";
	my $view2    = 'Res';
	my $view3    = '';
	my $fullView = '';

	my $MLSview = $inrec->{'View'};
	if ( $MLSview =~ /Blue Ridge|Mountain/ig ) { #View-Blue Ridge
		$view3 = "Mtn";
	} elsif ( $MLSview =~ /Pastoral|Garden/ ) { #View-Pastoral
		$view3 = "Pstrl";
	} elsif ( $MLSview =~ /Water/ ) { #View-Water
		$view3 = "Wtr";
	} elsif ( $MLSview =~ /Woods/ ) { #View-Woods
		$view3 = "Woods";
	}

	# Analyze view according to area
	# Cville

	# Albemarle

	# Nelson

	# Fluvanna

	$fullView = $view1 . ";" . $view2 . ";" . $view3;
	$outrec->{'LotView'} = $fullView;

	#-----------------------------------------

	# DesignAppeal
	my $stories  = "";
	my $design   = "";
	my $design_uad = '';
	my $storynum = '';
	my $proptype = $inrec->{'PropType'};
	my $atthome  = $inrec->{'Attached Home'};
	$stories = $inrec->{'Level'};
		
	# Street Number
	$stories =~ s/\D//;
		
	if ( $proptype =~ /Detached/ig ) {
		$design  = $inrec->{'Design'};
		$design_uad = 'DT'.$stories.';'.$design;
	}
	
	elsif ( $proptype =~ /Attached/ig ) {
		$design = $inrec->{'Design'};
		if ( $atthome =~ /End Unit/ig ) {
			$design_uad ='SD'. $stories . ';' . $design . '/End';
		} elsif ( $atthome =~ /Duplex/ig ) {
			$design_uad ='SD'. $stories . ';' . $design . '/Dup';
		} else {
			$design_uad ='AT'. $stories . ';' . $design . '/Int';
		}
	}
	$outrec->{'DesignAppeal1'} = $design_uad;

	#-----------------------------------------

	# Age
	my $age = 0;

	#$age = $time{'yyyy'} - $inrec->{'Year Built'};
	$age = localtime->year + 1900 - $inrec->{'YearBuilt'};
	
	$outrec->{'Age'} = $age;

	#-----------------------------------------

	# DesignConstructionQuality
	# Q1 through Q6
	my $extcond = '';

	if ( $soldprice > 800000 ) {
		$extcond = "Q1";
	} elsif ( $soldprice > 500000 ) {
		$extcond = "Q2";
	} elsif ( $soldprice > 150000 ) {
		$extcond = "Q3";
	} elsif ( $soldprice > 50000 ) {
		$extcond = "Q4";
	} else {
		$extcond = "";
	}
	$extcond = '';
	$outrec->{'DesignConstrQual'} = $extcond;

	#-----------------------------------------

	# AgeCondition1
	my $agecondition = '';
	my $agecond      = '';
	if ( $age <= 1 ) {
		$agecond = "C1";
	} else {
		$agecond = "C3";
	}

#	my $kitcounter = $inrec->{"Kitchen Counters"};
#	if ( $kitcounter =~ /Granite|Marble|Quartz|Soapstone|Wood|Solid Surface/ ) {
#		$agecondition = "C2";
#	} else {
#		$agecondition = $agecond;
#	}
	$agecond = '';
	$outrec->{'AgeCondition1'} = $agecond;

	#-----------------------------------------
	# CarStorage1
	# UAD output example: 2ga2cp2dw, 2gd2cp2dw,
	
	my $garage = '';
	my $gartype = '';
	my $carport = '';
	my $garnumcar = '';
	my $cpnumcar = '';
	my $dw = '';
	my $nogar = 1;
	my $nocp = 1;
	my $nodw = 1;
	my $carstortype = '';
	my $garfeat = $inrec->{'Garage Features'};
	
	if ( $inrec->{'Garage'} eq 'Y' ) {
	# check number of cars garage		
		$garnumcar = $inrec->{'Garage#Car'};
		if ( $garnumcar =~ /(\d)/ ) {
			$garnumcar = $1;
			# number of cars exists, so use that number
		} else {
			$garnumcar = 1;
		}
	
		# check if attached/detached/built-in

		if ( $garfeat =~ /Attached/){
			$gartype = 'ga';
		} elsif ( $garfeat =~ /Detached/) {
			$gartype = 'gd';
		} elsif ( $garfeat =~ /In Basement/) {
			$gartype = 'bi';
		}
		
		$carstortype = $garnumcar.$gartype;
		$nogar = 0;
	}
	
	# check for carport
	$cpnumcar = $inrec->{'Carpt#Car'};
	if ( $cpnumcar =~ /(\d)/ ) {
			$cpnumcar = $1;
			$nocp = 0;
			$carstortype = $carstortype . $cpnumcar . 'cp';
	}
		
	if ( $garfeat =~ /On Street Parking/) {
		$dw = '';
	}
		
	my $driveway = $inrec ->{'Driveway'};
	if ($driveway =~ /Asphalt|Brick|Concrete|Dirt|Gravel|Riverstone/){
		$dw = '2dw';	
		$carstortype = $carstortype . $dw;
	}
	
	if ($nogar && $nocp && $nodw) {
		$carstortype = 'None'
	}
	
	$outrec->{'CarStorage1'} = $carstortype;

	#-----------------------------------------

	# CoolingType
	my $heat    = '';
	my $cool    = '';
	my $divider = "/";
	my $cooling = $inrec->{'Air Conditioning'};
	my $heating = $inrec->{'Heating'};
	if ( ( $cooling =~ /Heat Pump/i ) || ( $heating =~ /Heat Pump/i ) ) {
		$heat    = "HTP";
		$cool    = '';
		$divider = '';
	} else {
		if ( $cooling =~ /Central AC/ ) {
			$cool = "CAC";
		} else {
			$cool = "No CAC";
		}
		if ( $heating =~ /Forced Air|Furnace|Ceiling|Gas|Liquid Propane/i ) {
			$heat = "FWA";
		} elsif ( $heating =~ /Electric/i ) {
			$heat = "EBB";
		} elsif ( $heating =~ /Baseboard|Circulator|Hot Water/i ) {
			$heat = "HWBB";
		} else {
			$heat = $heating;
		}
	}
	$outrec->{'CoolingType'} = $heat . $divider . $cool;

	#-----------------------------------------

	#23 FunctionalUtility
	$outrec->{'FunctionalUtility'} = "Average";

	#-----------------------------------------

# EnergyEfficiencies1
# EcoCert: LEED Certified | Energy Star | EarthCraft | Energy Wise | WaterSense Certified Fixtures
# Heating: Active Solar | Geothermal | Passive Solar
# Windows: Insulated | Low-E
# Water Heater: Instant | Solar | Tankless

	# first check EcoCert
	my $energyeff = 'None';
	my $remarks   = $inrec->{'Remarks'};
	my $windows   = $inrec->{'Windows'};
	my $doors     = $inrec->{'Doors'};
	my $heats     = $inrec->{'Heating'};
	my $waterhtr  = $inrec->{'Water Heater'};
	my $ewndd     = '';
	my $eheat     = '';
	my $ewhtr     = '';
	if ( $remarks =~ /LEED/i ) {
		$energyeff = "LEED Cert";
	} elsif ( $remarks =~ /Energy Star/i ) {
		$energyeff = "EnergyStar Cert";
	} elsif ( $remarks =~ /EarthCraft /i ) {
		$energyeff = "EartCraft Cert";
	} elsif ( $remarks =~ /Energy Wise/i ) {
		$energyeff = "EnergyWise Cert";
	} else {
		if ( $windows =~ /insulated|low-e/i ) {
			$ewndd = "InsWnd ";
		}
		if ( $doors =~ /insul/i ) {
			if ( $ewndd =~ /InsWnd/ig ) {
				$ewndd = "InsWnd&Drs ";
			} else {
				$ewndd = "InsDrs ";
			}
		}
		if ( $heats =~ /Solar/i ) {
			$eheat = "Solar ";
		}
		if ( $heats =~ /Geothermal/i ) {
			$eheat = $eheat . "GeoHTP ";
		}
		if ( $waterhtr =~ /Solar/ ) {
			if ( $eheat !~ /Solar/ ) {
				$ewhtr = "Solar ";
			}
		}
		if ( $waterhtr =~ /Instant|Tankless/i ) {
			$ewhtr = "InstHW";
		}
		$energyeff = $eheat . $ewhtr . $ewndd;
		$energyeff =~ s/ /,/ig;
		$energyeff =~ s/,$//ig;
	}

	$outrec->{'EnergyEfficiencies1'} = $energyeff;

	#-----------------------------------------

# Rooms
# From CAAR MLS:
# Room count includes rooms on levels other than Basement.
# AtticApt, BasementApt, Bedroom, BilliardRm, Brkfast, BonusRm, ButlerPantry, ComboRm,
# DarkRm, Den, DiningRm, ExerciseRm, FamRm, Foyer, Full Bath, Gallery, GarageApt, GreatRm,
# Greenhse, Half Bath, HmOffice, HmTheater, InLaw Apt, Kitchen, Laundry, Library, LivingRm,
# Loft, Master BR, MudRm, Parlor, RecRm, Sauna, SewingRm, SpaRm, Study/Library, SunRm, UtilityRm

	my $rooms      = 0;
	my $fullbath   = 0;
	my $halfbath   = 0;
	my $bedrooms   = 0;
	my $bsRooms    = 0;
	my $bsRecRm    = 0;
	my $bsFullbath = 0;
	my $bsHalfbath = 0;
	my $bsBedrooms = 0;
	my $bsOther    = 0;
	my $bsRmCount  = 0;

	#maximum of 30 rooms
	#my @rmarr = split( /,/, $inrec->{'Rooms'} );
	my $room = '';
	my $indx  = 0;
	my $rindx = 0;
	my $rlim  = 30;
	my $rmtype = '';
	my $rmflr = '';
	my $roomnum = ''; 
	my $roomcount = '';	
	my $roomname = '';
	my $roomfieldname = '';
	my $roomlevfieldname = '';
	my $roomlev = '';
	while ( $rindx < $rlim ) {
		$roomcount = sprintf( "%02d", $rindx +1 );
		$roomfieldname = 'Rm'.$roomcount;
		$roomlevfieldname = $roomfieldname . 'Lv';
		$roomname = $inrec->{$roomfieldname};
		$roomlev = $inrec->{$roomlevfieldname};

		#my $rmtype = $rmarr[$rindx];
		#my $rmsz   = $rmarr[ $rindx + 1 ];
		#my $rmflr  = $rmarr[ $rindx + 2 ];
		#$rmtype =~ s/^\s+|\s+$//g;
		#$rmflr  =~ s/ //g;
		
		$roomname =~ s/^\s+|\s+$//g;
		$rmtype = $roomname;
		$roomlev =~ s/ //g;
		$rmflr = $roomlev;

		if ( $rmflr !~ /Basement/ ) {
			if ( $rmtype =~/Bedroom|Breakfast|Bonus|Den|Dining|Exercise|Family|Great|Home Office|Home Theater|Kitchen|Library|Living|Master|Mud|Parlor|Rec|Sauna|Sewing|Spa|Study|Library|Sun/i
			  )
			{
				$rooms++;
			}
			if ( $rmtype =~ /Full Bath/i ) {
				$fullbath++;
			}
			if ( $rmtype =~ /Half Bath/i ) {
				$halfbath++;
			}
			if ( $rmtype =~ /Bedroom|Master/ ) {
				$bedrooms++;
			}
		}
		if ( $rmflr =~ /Basement/ ) {
			if ( $rmtype =~
				 /Bonus|Den|Family|Great|Library|Living|Rec|Study|Library/i )
			{
				$bsRecRm++;
				$bsRmCount++;
			}
			if ( $rmtype =~/Breakfast|Dining|Exercise|Home Office|Home Theater|Kitchen|Mud|Parlor|Sauna|Sewing|Spa|Sun/i
			  )
			{
				$bsOther++;
				$bsRmCount++;
			}
			if ( $rmtype =~ /Full Bath/i ) {
				$bsFullbath++;
				$bsRmCount++;
			}
			if ( $rmtype =~ /Half Bath/i ) {
				$bsHalfbath++;
				$bsRmCount++;
			}
			if ( $rmtype =~ /Bedroom|Master/ ) {
				$bsBedrooms++;
				$bsRmCount++;
			}
		}

		$indx++;
		$rindx++
		#$rindx = $indx * 3;

	}
	if ( $rooms < $bedrooms + 2 ) {
		$rooms = $bedrooms + 2;
	}

	$outrec->{'Rooms'} = $rooms;

	my $bsRmList = '';
#	if ( $bsRmCount > 0 ) {
#		if ( $bsRecRm > 0 )    { $bsRmList = $bsRecRm . "rr"; }
#		if ( $bsBedrooms > 0 ) { $bsRmList = $bsRmList . $bsBedrooms . "br"; }
#		if ( ( $bsFullbath + $bsHalfbath ) > 0 ) {
#			$bsRmList = $bsRmList . $bsFullbath . "." . $bsHalfbath . "ba";
#		}
#		if ( $bsOther > 0 ) { $bsRmList = $bsRmList . $bsOther . "o"; }
#	}
	$bsRmList = $bsRecRm . 'rr' . $bsBedrooms . 'br' . $bsFullbath . '.' . $bsHalfbath . 'ba' . $bsOther . 'o';
	
	# Basement2
	$outrec->{'Basement2'} = $bsRmList;

	#-----------------------------------------

	# Bedrooms
	my $bedroomstot = $inrec->{'#Beds'};

	$outrec->{'Beds'} = $bedrooms;

	#-----------------------------------------

	# Baths
	my $baths = 0;
	if ( $fullbath == 0 ) {
		$fullbath = $inrec->{'#FBaths'};
		$halfbath = $inrec->{'#HBaths'};
	}
	my $bathnum = $fullbath + $halfbath / 10;
	my $bathstr = "$fullbath.$halfbath";
	$baths = sprintf( "%.1f", $bathnum );
	$outrec->{'Baths'} = $bathstr;

	#-----------------------------------------

	# BathsFull
	$outrec->{'BathsFull'} = $fullbath;

	#-----------------------------------------

	# BathsHalf
	$outrec->{'BathsHalf'} = $halfbath;

	#-----------------------------------------

	 # Basement1
	 # Crawl | English | Finished | Full | Heated | Inside Access | Outside Access |
	 # Partial | Partly Finished | Rough Bath Plumb | Shelving | Slab | Sump Pump |
	 # Unfinished | Walk Out | Windows | Workshop

	$outrec->{'Basement1'} = '';

	#-----------------------------------------

	# Basement2
	#$outrec->{'Basement2'} = $bsmntfin;

	#-----------------------------------------

	$outrec->{'ExtraCompInfo2'} = '';

	#-----------------------------------------

	# ExtraCompInfo1 (Fireplaces)
	my $fp;
	my $fpout = '';
	my $numFPword = $inrec->{'Fireplace'};
	my $numFP = '';
	
	if ($numFPword =~ /One/ ) {
		$numFP = 1;
	} elsif ($numFPword =~ /Two/ ) {
		$numFP = 2;
	} elsif ($numFPword =~ /Three/ ) {
		$numFP = 3;
	} else {
		$numFP = 0 
	}

	my $locFP = $inrec->{'Fireplace Location'};
	my $locFPcnt = $locFP =~ (m/Basement|Bedroom|Den|Dining Room|Exterior Fireplace|Family Room|Foyer|Great Room|!
								Home Office|Kitchen|Library|Living Room|Master Bedroom|Study/ig
	);
	if ( !$locFPcnt ) { $locFPcnt = 0 }

	if ( $numFP >= $locFPcnt ) {
		$fp = $numFP;
	} elsif ( $locFPcnt >= $numFP ) {
		$fp = $locFPcnt;
	} elsif ( $numFP == 0 && $locFPcnt == 0 ) {
		$fpout = "0 Fireplace";
	}

	if ( $fp == 0 ) {
		$fpout = "0 Fireplace";
	}

	if ( $fp == 1 ) {
		$fpout = $fp . " Fireplace";
	} elsif ( $fp > 1 ) {
		$fpout = $fp . " Fireplaces";
	}

	$outrec->{'ExtraCompInfo1'} = $fpout;

	#-----------------------------------------

	# SqFt Source: Appraisal, Builder, Other, Owner, Tax Assessor
	my $sqftsrc = '';

	#-----------------------------------------

	# SqFt (after basement is determined)
	# Square foot fields added to CAAR on 7/19/2011:
	# SqFt Above Grade Fin
	# SqFt Above Grade Total
	# SqFt Above Grade UnFin
	# SqFt Below Grade Fin
	# SqFt Below Grade Total
	# SqFt Below Grade Unfin
	# SqFt Fin Total
	# SqFt Garage Fin
	# SqFt Garage Total
	# SqFt Garage Unfin
	# SqFt Total
	# SqFt Unfin Total

	my $sfAGFin = $inrec->{'AGFin'};
	my $sfAGTot = $inrec->{'AGTotSF'};
	my $sfAGUnF = $inrec->{'AGUnfin'};
	my $sfBGFin = $inrec->{'BGFin'};
	my $sfBGTot = $inrec->{'BGTotSF'};
	my $sfBGUnF = $inrec->{'BGUnfin'};
	my $sfFnTot = $inrec->{'TotFinSF'};
	my $sfGaFin = $inrec->{'GarAGFin'};
	my $sfGaTot = $inrec->{'GarTotAG'};
	my $sfGaUnF = $inrec->{'GarAGUnf'};
	my $sfTotal = $inrec->{'TotFinSF'};
	my $sfUnTot = $inrec->{'TotUnfinSF'};

	#my $listdate = Date::EzDate->new( $inrec->{'List Date'} );
	#if ( $listdate >= $sfDate ) {
	my $basType = "wo";
	if ( $sfAGFin > 0 ) {
		$outrec->{'SqFt'} = $sfAGFin;
		if ( $sfBGTot == 0 ) {
			$outrec->{'Basement1'} = "0sf";
		} else {
			my $basExit = $inrec->{'Bsmnt_2'};
			if ( $basExit =~ /Walk Out/ig ) {
				$basType = "wo";
			} elsif ( $basExit =~ /Outside Entrance/ig ) {
				$basType = "wu";
			} elsif ( $basExit =~ /Inside Access/ig ) {
				$basType = "in";
			} 

			#Walk Out
			if ( $sfBGFin == 0 ) {
				$outrec->{'Basement1'} = $sfBGTot . "sf" . 0 . $basType;
			} else {
				$outrec->{'Basement1'} =
				  $sfBGTot . "sf" . $sfBGFin . "sf" . $basType;
			}
		}
	} else {
		# SF Above Grade not entered, use SqFt Fin total
		my $sqft        = '';
		my $sqftabvGrnd = '';
		my $bsmntyn = $inrec->{'Bsmnt_1'};
		my $bsmntfin = $inrec->{'Bsmnt_2'};
		
		if ( ( $sfAGFin eq '' ) | ( $sfAGFin eq undef ) | ( $sfAGFin == 0 ) ) {


			$sfAGFin = $inrec->{'TotFinSF'};
			$stories = $inrec->{'Levels'};
			$sqft    = $sfAGFin;
			if ( $bsmntyn eq 'No' ) {
				$sqftabvGrnd = $sqft;

			} elsif ( $bsmntfin eq 'Finished' ) {
				if ( $stories eq '1 Story' ) {
					$sqftabvGrnd = round( 0.5 * $sqft );
				} elsif ( $stories eq '1.5 Story' ) {
					$sqftabvGrnd = round( 0.6 * $sqft );
				} elsif ( $stories eq '2 Story' ) {
					$sqftabvGrnd = round( 0.67 * $sqft );
				} else {
					$sqftabvGrnd = round( 0.75 * $sqft );
				}

			} elsif ( $bsmntfin eq 'Partly Finished' ) {
				if ( $stories eq '1 Story' ) {
					$sqftabvGrnd = round( 0.67 * $sqft );
				} elsif ( $stories eq '1.5 Story' ) {
					$sqftabvGrnd = round( 0.75 * $sqft );
				} elsif ( $stories eq '2 Story' ) {
					$sqftabvGrnd = round( 0.8 * $sqft );
				} else {
					$sqftabvGrnd = round( 0.8 * $sqft );
				}

			} else {
				$sqftabvGrnd = $sqft;
			}

		} else {
			$sqftabvGrnd = $sfAGFin;
		}

		$outrec->{'SqFt'} = $sqftabvGrnd;
	}
	
	#-----------------------------------------

# Porch ()Porch/Patio/Deck)
# Porch: Balcony | Brick | Deck | Front | Glassed | Patio | Porch | Rear | Screened | Side | Slate | Terrace
	my $pchcnt = 0;
	my $balcnt = 0;
	my $dekcnt = 0;
	my $patcnt = 0;
	my $tercnt = 0;
	
	my $pchout = '';
	my $pdp= $inrec->{'Structure-Deck/Porch'};
	if ($pdp =~ /Porch[^ -]|Rear|Side/){
		$pchout = "Pch ";
		$pchcnt++;
	}
	if ($pdp =~ /Front/ig){
		$pchout = $pchout . "FPc ";
		$pchcnt++
	}
	if ($pdp =~ /Screened/ig){
		$pchout = $pchout. "ScPc ";
		$pchcnt++
	}
	if ($pdp =~ /Glassed/ig){
		$pchout = $pchout. "EncPc ";
		$pchcnt++
	}
	
	$outrec->{'Porch'} = $pchout;

	#-----------------------------------------

	my $patout = '';
	if ($pdp =~ /Patio[^ -]/){
		$patout = "Pat ";
	}
	if ($pdp =~ /Covered/ig){
		$patout = $pchout . "CvPat ";
	}
	$outrec->{'Patio'} = $patout;

	#-----------------------------------------

	my $dkout = '';
	if ($pdp =~ /Deck/){
		$patout = "Deck ";
	}
	$outrec->{'Deck'} = $dkout;

	#-----------------------------------------

	# FencePorchPatio2
	my $totpchcnt = 0;
	my $pdpout    = '';

	$pdpout = $pchout . $patout . $dkout;
	$outrec->{'FencePorchPatio2'} = $pdpout;

	#-----------------------------------------

	# ExtraCompInfo3
	$outrec->{'ExtraCompInfo3'} = $pdpout;

	#-----------------------------------------

	# Notes1
	$outrec->{'Notes1'} = "Imported from CAAR";

	#-----------------------------------------

	# Photo
	my $photo = '';
	$photo = $inrec->{'Photo 1'};
	$outrec->{'Photo'} = '';

	#-----------------------------------------

	my $mediaflag = '';
	$mediaflag = $inrec->{'Media Flag'};
	$outrec->{'MediaFlag'} = '';
	#-----------------------------------------

	my $medialink = $inrec->{'Media Link'};
	my $mediapath = '';
	if ( $mediaflag =~ m/1 Photo|Multiphotos/ig ) {
		if ( $medialink =~ /(http:\/\/www.caarmls.com.*?.jpg>)/ix ) {
			$mediapath = $1;
		}
	}
	$outrec->{'MediaLink'} = '';

	#-----------------------------------------

	# ML Number
	my $mlnumber = '';
	$mlnumber = $inrec->{'MLS#'};
	$outrec->{'MLNumber'} = $mlnumber;

	#-----------------------------------------

	# ML Prop Type
	$proptype             = '';
	$proptype             = $inrec->{'PropType'};
	$outrec->{'PropType'} = $proptype;

	#-----------------------------------------

	# ML County
	my $county = '';
	my $area   = '';
	$area = $inrec->{'Cnty/IncC'};
	switch ($area) {
		case '001' { $county = "Albemarle" }
		case '002' { $county = "Amherst" }
		case '003' { $county = "Augusta" }
		case '004' { $county = "Buckingham" }
		case '005' { $county = "Charlottesville" }
		case '006' { $county = "Culpeper" }
		case '007' { $county = "Fauquier" }
		case '008' { $county = "Fluvanna" }
		case '009' { $county = "Goochland" }
		case '010' { $county = "Greene" }
		case '011' { $county = "Louisa" }
		case '012' { $county = "Madison" }
		case '013' { $county = "Nelson" }
		case '014' { $county = "Orange" }
		case '015' { $county = "Rockbridge" }
		case '016' { $county = "Waynesboro" }
		case '017' { $county = "Other" }
	}
	$outrec->{'County'} = $county;

	#-----------------------------------------

	# DateofPriorSale1
	my $dateofPriorSale1 = '';
	$outrec->{'DateofPriorSale1'} = $dateofPriorSale1;

	#-----------------------------------------

	# PriceofPriorSale1
	my $priceofPriorSale1 = '';
	$outrec->{'PriceofPriorSale1 '} = $priceofPriorSale1;

	#-----------------------------------------

	# DataSourcePrior1
	my $dataSourcePrior1 = "Assessors Records";
	if ( $area >= 9 ) {
		$dataSourcePrior1 = "Courthouse Records";
	}
	$outrec->{'DataSourcePrior1'} = $dataSourcePrior1;

	#-----------------------------------------

	# EffectiveDatePrior1
	my $effectiveDatePrior1 = '';
	$outrec->{'EffectiveDatePrior1'} = $effectiveDatePrior1;

	#-----------------------------------------

	# Agent Notes
	my $agentNotes = ''; #$inrec->{'Agent Notes'};
	if ( defined $agentNotes ) {

		# $outrec->{'AgentNotes'} = $agentNotes;
		$outrec->{'AgentNotes'} = '';
	}

	#-----------------------------------------

	# Dependencies
	my $dependencies = $inrec->{'Dependencies'};
	if ( defined $dependencies ) {
		$outrec->{'Dependencies'} = $dependencies;
	}

	#-----------------------------------------

	# Zoning
	my $zoning = $inrec->{'Zoning'};
	if ( defined $zoning ) {
		$outrec->{'Zoning'} = $zoning;
	}

	#-----------------------------------------

	# Hoa Fee
	my $hoafee = $inrec->{'AssnFee'};
	if ( defined $hoafee ) {
		$outrec->{'HoaFee'} = $hoafee;
	}

	#-----------------------------------------

	#condo specific

	my $aprop = $inrec->{'PropType'};
	if ( $aprop =~ /Condo/ig ) {

		# Unit Number
		my $unitnum = $inrec->{'Unit#'};
		$outrec->{'Unitnum'} = $unitnum;

# Amenities
#Art Studio | Bar/Lounge | Baseball Field | Basketball Court | Beach | Billiard Room
#| Boat Launch | Clubhouse | Community Room | Dining Rooms | Exercise Room | Extra Storage
#| Golf | Guest Suites | Lake | Laundry Room | Library | Meeting Room | Newspaper Serv.
#| Picnic Area | Play Area | Pool | Riding Trails | Sauna | Soccer Field | Stable
#| Tennis | Transportation Service | Volleyball | Walk/Run Trails

# | Walk/Run Trails | Boat Launch | Clubhouse | Community Room | Exercise Room
# | Extra Storage | Golf | Play Area | Pool | Riding Trails | Sauna | Stable Tennis | Walk/Run Trails

		my $amenities = $inrec->{'Amenities(HOA/Club/Sub)'};
		$outrec->{'Amenities'} = $amenities;

		# stories
		# 1-4 stories:  stories
		# 5-7:			mid-rise
		# 8 and higher: High-rise

		# address modified with unit number
		$outrec->{'Address1'} = $outrec->{'Address1'} . ", #" . $unitnum;

		# location set to city

		# subdivision set to project name

	}

	#-----------------------------------------
	#-----------------------------------------
	# CAAR_Resid Last Line
	#my $pnum = 1;
	while ( my ( $k, $v ) = each %$outrec ) {
		print $outfile ("$v\t");

		# print "$pnum\n";
		# $pnum = $pnum+1;
	}
	print $outfile ("\n");
	
	print $outfileT "\n";
	while ( my ( $key, $value ) = each(%comp) ) {
		print $outfileT $value;
		#print $outfile "$key => $value\n";
	}
	print $outfileT "\n";




}

sub CAAR_Land {

}

sub CAAR_Multifam {
	my ($inrec)   = shift;
	my ($outrec)  = shift;
	my ($outfile) = shift;

	my $tc = Lingua::EN::Titlecase->new("initialize titlecase");

	# don't run wintotal comp importer at the end
	$Run_CompImp = 0;

	my $wtline = sprintf( '%c', 8 );
	
	tie my %multifam => 'Tie::IxHash',
	  Address1       => '',
	  Address2       => '',
	  Proximity      => '',
	  SalePrice      => '',
	  PriceGBA       => '',
	  GMR            => '',
	  GRM            => '',
	  PriceUnit      => '',
	  PriceRm        => '',
	  PriceBR        => '',
	  RentCont       => '',
	  Datasrc        => '',
	  Verifysrc      => '',
	  SaleType       => '',
	  Concessions    => '',
	  SaleDate       => '',
	  NeighborHd     => '',
	  LsHldFS        => '',
	  Acreage        => '',
	  View           => '',
	  Design         => '',
	  Quality        => '',
	  Age            => '',
	  Condition      => '',
	  GBA            => '',
	  Unit1TR        => '',
	  Unit1BR        => '',
	  Unit1Ba        => '',
	  Unit2TR        => '',
	  Unit2BR        => '',
	  Unit2Ba        => '',
	  Unit3TR        => '',
	  Unit3BR        => '',
	  Unit3Ba        => '',
	  Unit4TR        => '',
	  Unit4BR        => '',
	  Unit4Ba        => '',
	  TotUnit        => '',
	  TotRm          => '', 
	  TotBr          => '', 
	  TotBa          => '', 
	  Basement       => '',
	  BasementFR     => '',
	  FunctionalU    => '',
	  HVAC	         => '',
	  EnergyEff      => '',
	  Parking		 => '',
	  Porch			 => '';

	#3 Street Name Preprocessing
	my $fullStreetName = $tc->title( $inrec->{'Street Name'} );
	$fullStreetName =~ s/\(.*//;    #remove parens

	my $streetName = $fullStreetName;
	if ( $streetName =~ m/( +[nsew] *$| +[ns][ew] *$)/ig ) {
		my $strpostdir = uc $1;
		$streetName =~ s/$strpostdir//i;
	}

	#5 Street Name, Street Suffix
	#find street suffix (assumes last word is street type, e.g. ave, rd, ln)
	my @words        = split( / /, $streetName );
	my @revwords     = reverse(@words);
	my $streetSuffix = $revwords[0];
	$streetName =~ s/$streetSuffix//;

	#6 Address 1
	my $streetnum = $inrec->{'Street Num'};
	my $address1  = "$streetnum $fullStreetName";

	# Address 2
	my $city = $inrec->{'City'};
	$city = $tc->title($city);
	$city =~ s/\(.*//;
	$city =~ s/\s+$//;
	my $address2 = $city . ", " . $inrec->{'State'} . " " . $inrec->{'Zip'};
	$outrec->{'Address2'} = $address2;

	#7 Address 2
	#my $city = $inrec->{'City'};
	#$city = $tc->title($city);
	#$city =~ s/\s+$//;
	#my $state    = $inrec->{'State'};
	#my $zip      = $inrec->{'Zip'};
	#my $address2 = $city . ", " . $state . " " . $zip;

	$multifam{'Address1'} = $address1 . $wtline;
	$multifam{'Address2'} = $address2 . $wtline;
	#-----------------------------------------

	# Proximity (calculated)
	$multifam{'Proximity'} = $wtline;
	#-----------------------------------------
	
	# SalePrice
	my $soldstatus = 0;
	my $soldprice  = 0;
	my $recstatus  = $inrec->{'Status'};
	if ( $recstatus eq 'S' ) {
		$soldstatus = 0;                        #sold
		$soldprice  = $inrec->{'Sold/Leased Price'};
	} elsif ( $recstatus =~ m /A/i ) {
		$soldstatus = 1;                        #Active
		$soldprice  = $inrec->{'List Price'};
	} elsif ( $recstatus =~ m /P/i ) {
		$soldstatus = 2;                        #Pending
		$soldprice  = $inrec->{'List Price'};
	} elsif ( $recstatus =~ m /C/i ) {
		$soldstatus = 3;                        #Contingent
		$soldprice  = $inrec->{'List Price'};
	} elsif ( $recstatus =~ m /X/i ) {
		$soldstatus = 4;                        #Withdrawn
		$soldprice  = $inrec->{'List Price'};
	} else {

		#nothing
	}
	$multifam{'SalePrice'} = $soldprice . $wtline;
	#-----------------------------------------
	
	# Price per GBA (calculated)
	$multifam{'PriceGBA'} = $wtline;
	#-----------------------------------------
	
	# Gross monthly rent
	$multifam{'GMR'} = $inrec->{'Gross Rent'}.$wtline;
	#-----------------------------------------
	
	# GRM, Price/Unit, Price/Rm, Price/BR (calculated)
	$multifam{'GRM'} = $wtline;
	$multifam{'PriceUnit'} = $wtline;
	$multifam{'PriceRm'} = $wtline;
	$multifam{'PriceBR'} = $wtline;
	#-----------------------------------------
	
	# Rent Control
	$multifam{'RentCont'} = $wtline. 'X' . $wtline;
	#-----------------------------------------
	
	# DataSource1
	my $datasrc =
	  "CAARMLS#" . $inrec->{'MLS Number'} . "; DOM " . $inrec->{'Dom'};
	$multifam{'Datasrc'} = $datasrc . $wtline;  
	#-----------------------------------------

	# Data Source 2
	$multifam{'Verifysrc'} = "Tax Records" . $wtline;
	#-----------------------------------------

	# Finance Concessions Line 1
		# REO		REO sale
		# Short		Short sale
		# CrtOrd	Court ordered sale
		# Estate	Estate sale
		# Relo		Relocation sale
		# NonArm	Non-arms length sale
		# ArmLth	Arms length sale
		# Listing	Listing

	my $finconc1 = '';
	if ( $soldstatus == 0 ) {
		my $foreclosure = $inrec->{'Foreclosure?'};
		my $saletype =
		  $inrec->{'Sale Type'};    #Lender Owned, Short Sale, Standard
		my $agentnotes = $inrec->{'Agent Notes'};

		if ( $saletype =~ /Lender Owned/i ) {
			$finconc1 = "REO";
		} elsif ( $saletype =~ /Short Sale/i ) {
			$finconc1 = "Short";
		} elsif ( $agentnotes =~ /court ordered /i ) {
			$finconc1 = "CrtOrd";
		} elsif ( $agentnotes =~ /estate sale /i ) {
			$finconc1 = "Estate";
		} elsif ( $agentnotes =~ /relocation /i ) {
			$finconc1 = "Relo";
		} else {
			$finconc1 = "ArmLth";
		}
	} elsif ( $soldstatus == 1 ) {
		$finconc1 = "Listing";
	} elsif ( $soldstatus == 2 ) {
		$finconc1 = "Listing";
	} elsif ( $soldstatus == 3 ) {
		$finconc1 = "Listing";
	} else {
		$finconc1 = '';
	}
	$multifam{'SaleType'} = $finconc1 . $wtline . $wtline;
	#-----------------------------------------

	# FinanceConcessions2
		# Type of financing:
		# FHA		FHA
		# VA		VA
		# Conv		Conventional
		# Seller 	Seller
		# Cash 		Cash
		# RH		Rural Housing
		# Other
		# Format: 12 Char maximum

	my $finconc2    = '';
	my $conc        = '';
	my $finconc2out = '';
	if ( $soldstatus == 0 ) {
		my $terms = $inrec->{'Sold Terms'};
		if ( $terms eq '0' ) {
			$finconc2 = "NotSpec";    #Not Specified
		} elsif ( $terms eq '1' ) {
			$finconc2 = "Cash";
		} elsif ( $terms eq '2' ) {
			$finconc2 = "Conv";
		} elsif ( $terms eq '3' ) {
			$finconc2 = "Conv";
		} elsif ( $terms eq '4' ) {
			$finconc2 = "FHA";
		} elsif ( $terms eq '5' ) {
			$finconc2 = "VHDA";
		} elsif ( $terms eq '6' ) {
			$finconc2 = "FHMA";
		} elsif ( $terms eq '7' ) {
			$finconc2 = "VA";
		} elsif ( $terms eq '8' ) {
			$finconc2 = "AsmMtg";
		} elsif ( $terms eq '9' ) {
			$finconc2 = "PrvMtg";
		} elsif ( $terms eq '10' ) {
			$finconc2 = "Seller";
		} elsif ( $terms eq '11' ) {
			$finconc2 = "NotSpec";
		} else {
			$finconc2 = "NotSpec";
		}

		$conc = 0;
		if ( $inrec->{'Seller Concessions'} ) {
			$conc = USA_Format( $inrec->{'Seller Concessions'} );
			$conc =~ s/$//;
			$conc = $inrec->{'Seller Concessions'};
		}
		$finconc2out = $finconc2 . ";" . $wtline;
	}

	#$finconc2out = 'FHA;0';
	$multifam{'Concessions'} = $finconc2out . $wtline;
	#-----------------------------------------

	# SaleDate
		# Sale and Contract formatted as mm/yy
	my $sdatestr    = '';
	my $cdatestr    = '';
	my $wsdatestr   = '';
	my $wcdatestr   = '';
	my $fulldatestr = '';
	my $year4digit  = '';
	if ( $soldstatus == 0 ) {
		my $sdate = $inrec->{'Sold/Leased Date'};
		my @da = ( $sdate =~ m/(\d+)/g );

		#my $m2digit = sprintf("%02d", $da[0]);
		my $m2digit  = sprintf( "%02d", $da[0] );
		my $yr2digit = sprintf( "%02d", $da[2] % 100 );
		$year4digit  = sprintf( "%04d", $da[2]);
		$sdatestr  = "s" . $m2digit . "/" . $yr2digit;
		$wsdatestr = $m2digit . "/" . $yr2digit;

		my $cdate = $inrec->{'Contract Date'};
		if ( ( $cdate eq undef ) || ( $cdate eq "" ) ) {
			$cdatestr = "Unk";
		} else {
			my @da = ( $cdate =~ m/(\d+)/g );
			my $m2digit  = sprintf( "%02d", $da[0] );
			my $yr2digit = sprintf( "%02d", $da[2] % 100 );
			$cdatestr  = "c" . $m2digit . "/" . $yr2digit;
			$wcdatestr = $m2digit . "/" . $yr2digit;
		}
		$fulldatestr = $sdatestr . ";" . $cdatestr;
	} elsif (    ( $soldstatus == 1 )
			  || ( $soldstatus == 2 )
			  || ( $soldstatus == 3 ) )
	{
		$fulldatestr = "Listing";
	}

	#$outrec->{'CloseDate'} = $wsdatestr;
	#$outrec->{'ContrDate'} = $wcdatestr;

	#$fulldatestr = 's12/11;c11/11';
	$multifam{'SaleDate'} = $fulldatestr . $wtline;
	#-----------------------------------------

	$multifam{'NeighborHd'} = $wtline . $wtline . $wtline;
	#-----------------------------------------
	
	$multifam{'LsHldFS'} = "Fee Simple" . $wtline . $wtline;
	#-----------------------------------------

	my $acres      = $inrec->{'Acreage'};
	my $acresuffix = '';
	my $outacres   = '';
	$outacres = sprintf( "%.2f", $acres );
	$acresuffix = " ac";
	
	$multifam{'Acreage'} = $outacres . $acresuffix . $wtline . $wtline;
	#-----------------------------------------
	
	$multifam{'View'} = "Resid/Avg" . $wtline . $wtline;
	#-----------------------------------------
	
	my $design = $inrec->{'Design'};
	my $style = $inrec->{'Style'};
	my $styleabb = '';
	if ($style =~ /Duplex O/) {
		$styleabb = "DOU";
	} elsif ($style =~ /Duplex S/) {
		$styleabb = "DSS"
	}
	$multifam{'Design'} = $design . '/' . $styleabb . $wtline . $wtline;
	#-----------------------------------------
	
	my $age = 0;
	#$age = localtime->year + 1900 - $inrec->{'Year Built'};
	$age = $year4digit - $inrec->{'Year Built'};
	$multifam{'Age'} = $age . $wtline . $wtline;
	#-----------------------------------------
		
	#Aluminum | Asbestos | Block | Board & Batten | Brick | Cedar |
	#Clapboard | Concrete | Glass | Hardiplank | Log | Masonite |
	#Partial | Shingle | Stone | Stucco | T-111 | Vinyl | Wood
	my $extcond = '';
	my $ext     = $inrec->{'Exterior'};
	$ext =~ s/~//;
	$ext =~ s/\s*//g;
	my $len = length($ext);
	if ( $len > 12 ) {
		$ext =~ s/Aluminum/Alum/ig;
		$ext =~ s/Asbestos/Asb/ig;
		$ext =~ s/HardiPlank/HdPlk/ig;
		$ext =~ s/FiberCementSiding/HdPlk/ig;
		$ext =~ s/Masonite/Msnite/ig;
		$ext =~ s/Block/Blk/ig;
		$ext =~ s/BoardandBatten/Bd&Btn/ig;
		$ext =~ s/Brick/Brk/ig;
		$ext =~ s/Cedar/Cdr/ig;
		$ext =~ s/Clapboard/Clpbd/ig;
		$ext =~ s/Concrete/Conc/ig;
		$ext =~ s/Glass/Gls/ig;
		$ext =~ s/Shingle/Shgl/ig;
		$ext =~ s/Wood/Wd/ig;
	}
	if ( $age <= 1 ) {
		$extcond = "${ext}/New";
	} elsif ( $age <= 15 ) {
		$extcond = "${ext}/New";
	}
	else {
		$extcond = "${ext}/Avg";
	}
	$multifam{'Quality'} = $extcond . $wtline . $wtline;
	#-----------------------------------------
	
	$multifam{'Condition'} = $wtline . $wtline;
	#-----------------------------------------
	
	my $GBA = $inrec->{'SqFt Fin Total'};
	$multifam{'GBA'} = $GBA . $wtline . $wtline;
	#-----------------------------------------

	my $brcnt1 = $inrec->{'U1 #Bedrooms'};
	my $bacnt1 = $inrec->{'U1 #Baths'};
	$multifam{'Unit1BR'} = $brcnt1 . $wtline;
	$multifam{'Unit1Ba'} = $bacnt1 . $wtline . $wtline;
	my $trcnt1; if ($brcnt1 > 0) {$trcnt1 = $brcnt1 + 2;}
	$multifam{'Unit1TR'} = $trcnt1 . $wtline;
	#-----------------------------------------
	
	my $brcnt2 = $inrec->{'U2 #Bedrooms'};
	my $bacnt2 = $inrec->{'U2 #Baths'};
	$multifam{'Unit2BR'} = $brcnt2 . $wtline;
	$multifam{'Unit2Ba'} = $bacnt2 . $wtline . $wtline;
	my $trcnt2; if ($brcnt2 > 0) {$trcnt2 = $brcnt2 + 2;}
	$multifam{'Unit2TR'} = $trcnt2 . $wtline;
	#-----------------------------------------
	
	my $brcnt3 = $inrec->{'U3 #Bedrooms'};
	my $bacnt3 = $inrec->{'U3 #Baths'};
	$multifam{'Unit3BR'} = $brcnt3 . $wtline;
	$multifam{'Unit3Ba'} = $bacnt3 . $wtline . $wtline;
	my $trcnt3; if ($brcnt3 > 0) {$trcnt3 = $brcnt3 + 2;}
	$multifam{'Unit3TR'} = $trcnt3 . $wtline;
	#-----------------------------------------
	
	my $brcnt4 = $inrec->{'U4 #Bedrooms'};
	my $bacnt4 = $inrec->{'U4 #Baths'};
	$multifam{'Unit4BR'} = $brcnt4 . $wtline;
	$multifam{'Unit4Ba'} = $bacnt4 . $wtline . $wtline;
	my $trcnt4; if ($brcnt4 > 0) {$trcnt4 = $brcnt4 + 2;}
	$multifam{'Unit4TR'} = $trcnt4 . $wtline;
	#-----------------------------------------
	
	$multifam{TotUnit} = $inrec->{'Tot Units'} . $wtline;
	$multifam{TotRm} = ($trcnt1 + $trcnt2 + $trcnt3 + $trcnt4) . $wtline;
	$multifam{TotBr} = ($brcnt1 + $brcnt2 + $brcnt3 + $brcnt4) . $wtline;
	$multifam{TotBa} = ($bacnt1 + $bacnt2 + $bacnt3 + $bacnt4) . $wtline;
	
	$multifam{'Basement'} = $wtline . $wtline;
	
	$multifam{'BasementFR'} = $wtline . $wtline;
	
	$multifam{'FunctionalU'} = "Average" . $wtline . $wtline;
	
	#HVAC
	my $heat    = '';
	my $cool    = '';
	my $divider = "/";
	my $cooling = $inrec->{'Cooling'};
	my $heating = $inrec->{'Heating'};
	if ( ( $cooling =~ /Heat Pump/i ) || ( $heating =~ /Heat Pump/i ) ) {
		$heat    = "HTP";
		$cool    = '';
		$divider = '';
	} else {
		if ( $cooling =~ /Central AC/ ) {
			$cool = "CAC";
		} else {
			$cool = "No CAC";
		}
		if ( $heating =~ /Forced Air|Furnace|Ceiling|Gas|Liquid Propane/i ) {
			$heat = "FWA";
		} elsif ( $heating =~ /Electric/i ) {
			$heat = "EBB";
		} elsif ( $heating =~ /Baseboard|Circulator|Hot Water/i ) {
			$heat = "HWBB";
		} else {
			$heat = $heating;
		}
	}
	$multifam{'HVAC'} = $heat . $divider . $cool . $wtline . $wtline;
	#-----------------------------------------
	
	$multifam{'EnergyEff'} = $inrec->{'Windows'} . $wtline . $wtline;
	#-----------------------------------------
	
	$multifam{'Parking'} = $inrec->{'Drive'} . $wtline . $wtline;
	#-----------------------------------------
	
	$multifam{'Porch'} = $inrec->{'Porch'} . $wtline . $wtline;
    #-----------------------------------------
    
	print $outfile "\n";
	while ( my ( $key, $value ) = each(%multifam) ) {
		print $outfile $value;

		#print $outfile "$key => $value\n";

	}
	print $outfile "\n";

}

sub CAAR_Rental {
	my ($inrec)   = shift;
	my ($outrec)  = shift;
	my ($outfile) = shift;

	my $tc = Lingua::EN::Titlecase->new("initialize titlecase");

	# don't run wintotal comp importer at the end
	$Run_CompImp = 0;

	#select((select($outfile), $|=1)[0]); #flushes print buffer
	#tie my @array, 'Tie::File', $outfile;
	#my $n_rec = @array;

	#delete first line if it contains field names; not needed for rentals
	#if ( $array[0] =~ /^StreetNum/ig ) {
	#	$#array -= 1;
	#} else {

	#$array[ $n_rec + 1 ] = "Next rent comp";
	#}
	#untie @array;

	#print $outfile sprintf('%c', 8);
	my $wtline = sprintf( '%c', 8 );

# Line 	Form field			input field 													output
#	1	Address line 1		street address	(from MLS)								street address	$wtline
#	2	Address	line 2		city, state, zip (from MLS)								city state zip $wtline
#	3	proximity line 1			n/a												$wtline
#	3	proximity line 2			n/a												$wtline
#	4	date lease begins	sold date to next half month or month (from MLS)		date $wtline
#	5	date lease ends		1-year or lease required								date $wtline
#	6	monthly rent		sold price		(from MLS)								price $wtline
#	7	less util,furn				n/a												3x($wtline)
#	8	Adjusted rent		sold price		(from MLS)								price $wtline
#	9	Data Sourc			"Tax Recds/MLS"	(standard)								"Tax Recds/MLS" 6x($wtline)
#	10	Location			Location (from MLS)										Location 2x($wtline)
#	11	View				View (from MLS)											View 2x($wtline)
#	12	Design style		Number of stories (from MLS)							Stories 4x($wtline)
#	13	Age					Age (calculated from MLS)								Age 2x($wtline)
#	14	Condition			"Average"												"Average" 2x($wtline)
#	15	Room count			Total,Beds,Baths										Total,$wtline,Beds,$wtline,Baths,3x($wtline)
#   16	GLA					Square feet (MLS)										square feet 3x($wtline)
#   17	Other				Basement/Finish(MLS)									Basement/finished 2x($wtline)
#   18	Other				"n/a"													"n/a" 2x($wtline)
#   19	Other				Parking (MLS)											Parking 4x($wtline)

#1565 Troy Rdpalmyra, va3.85 miles NE8/1/20087/31/20091,4951,495Tax Rcds/MLSSuburbanResidential2 Story3-10Average952.5-102,521-30Crawlspacen/aGarageNo Pool+20

	# format for 1007 rent schedule form
	tie my %rental => 'Tie::IxHash',
	  address1     => '',
	  address2     => '',
	  prox1        => '',
	  prox2        => '',
	  begindate    => '',
	  enddate      => '',
	  rentmon      => '',
	  lesutilfurn  => '',
	  rentadj      => '',
	  datasrc      => '',
	  location     => '',
	  view         => '',
	  design       => '',
	  age          => '',
	  condition    => '',
	  roomcnt      => '',
	  gla          => '',
	  other1       => '',
	  other2       => '',
	  other3       => '';

	#3 Street Name Preprocessing
	my $fullStreetName = $tc->title( $inrec->{'Street Name'} );
	$fullStreetName =~ s/\(.*//;    #remove parens

	my $streetName = $fullStreetName;
	if ( $streetName =~ m/( +[nsew] *$| +[ns][ew] *$)/ig ) {
		my $strpostdir = uc $1;
		$streetName =~ s/$strpostdir//i;
	}

	#5 Street Name, Street Suffix
	#find street suffix (assumes last word is street type, e.g. ave, rd, ln)
	my @words        = split( / /, $streetName );
	my @revwords     = reverse(@words);
	my $streetSuffix = $revwords[0];
	$streetName =~ s/$streetSuffix//;

	#6 Address 1
	my $streetnum = $inrec->{'Street Num'};
	my $address1  = "$streetnum $fullStreetName";

	#7 Address 2
	my $city = $inrec->{'City'};
	$city = $tc->title($city);
	$city =~ s/\(.*//;
	$city =~ s/\s+$//;
	my $state    = $inrec->{'State'};
	my $zip      = $inrec->{'Zip'};
	my $address2 = $city . ", " . $state . " " . $zip;

	$rental{'address1'} = $address1 . $wtline;
	$rental{'address2'} = $address2 . $wtline;

	# proximity
	$rental{'prox1'} = $wtline;
	$rental{'prox2'} = $wtline;
	
	# lease begin date
	my $indate = $inrec->{'Sold/Leased Date'};
	my @da     = ( $indate =~ m/(\d+)/g );
	my $mo     = $da[0];
	my $day    = $da[1];
	my $yr     = $da[2];
	if ( $day >= 2 && $day <= 15 ) {
		$day = 15;
	} elsif ( $day >= 16 ) {
		$day = 1;
		$mo  = $mo + 1;
		if ( $mo == 13 ) {
			$mo = 1;
			$yr = $yr + 1;
		}
	}
	my $begindate = $mo . "/" . $day . "/" . $yr;
	$rental{'begindate'} = $begindate . $wtline;

	# lease end date

	#		Lease Required
	#		Lease Required
	#		Lease Required, Short Term
	#		1-year
	#
	#		Lease Required
	#		Lease Required, 1-year
	#		Lease Required, 1-year
	#		Lease Required, 1-year
	#		Lease Required, Short Term
	#		Lease Required, Short Term

	my $leaseterm = $inrec->{'Lease Term'};
	my $enddate   = "(*) Lease term not specified";
	if ( $leaseterm =~ /1-year|^$/ig ) {
		if ( $day == 15 ) {
			$day     = 14;
			$yr      = $yr + 1;
			$enddate = $mo . "/" . $day . "/" . $yr;
		} elsif ( $day == 1 ) {
			$day = 31;
			if ( $mo =~ /5|7|10|12/ig ) {
				$day = 30;
			}
			$mo      = $mo - 1;
			$yr      = $yr + 1;
			$enddate = $mo . "/" . $day . "/" . $yr;
		} else {

		}
	} else {
		$enddate = "(*) Lease term not specified";
	}
	$rental{'enddate'} = $enddate . $wtline;

	# monthly rent
	my $rentmon = $inrec->{'Sold/Leased Price'};
	$rental{'rentmon'} = $rentmon . $wtline;
	
	# lessutil
	$rental{'lesutilfurn'} = $wtline . $wtline;

	# adj rent
	$rental{'rentadj'} = $rentmon . $wtline;

	# datasrc
	# ML Number
	my $mlnumber = '';
	$mlnumber = $inrec->{'MLS Number'};
	$rental{'datasrc'} =
	    "CAARMLS#"
	  . $mlnumber
	  . $wtline
	  . "Tax Records"
	  . $wtline
	  . "None"
	  . $wtline
	  . $wtline
	  . $wtline
	  . $wtline;

	# location
	my $location = '';
	my $subdiv   = $inrec->{'Subdivision'};
	if ( $subdiv =~ m/NONE|^$/ig ) {
		$location = $tc->title($city);
	} else {
		$location = $tc->title($subdiv);
	}
	$rental{'location'} = $location . $wtline . $wtline;

	# view
	my $view = "Residential";
	$rental{'view'} = $view . $wtline . $wtline;

	# design
	my $design = $inrec->{'Stories'};
	$rental{'design'} = $design . $wtline . $wtline . $wtline . $wtline;

	# age
	my $age = 0;

	#$age = $time{'yyyy'} - $inrec->{'Year Built'};
	$age = localtime->year + 1900 - $inrec->{'Year Built'};
	$rental{'age'} = $age . $wtline . $wtline;

	# condition
	$rental{'condition'} = "Average" . $wtline . $wtline;

	#-----------------------------------------

# Rooms
# From CAAR MLS:
# Room count includes rooms on levels other than Basement.
# AtticApt, BasementApt, Bedroom, BilliardRm, Brkfast, BonusRm, ButlerPantry, ComboRm,
# DarkRm, Den, DiningRm, ExerciseRm, FamRm, Foyer, Full Bath, Gallery, GarageApt, GreatRm,
# Greenhse, Half Bath, HmOffice, HmTheater, InLaw Apt, Kitchen, Laundry, Library, LivingRm,
# Loft, Master BR, MudRm, Parlor, RecRm, Sauna, SewingRm, SpaRm, Study/Library, SunRm, UtilityRm

	my $rooms      = 0;
	my $fullbath   = 0;
	my $halfbath   = 0;
	my $bedrooms   = 0;
	my $bsRooms    = 0;
	my $bsRecRm    = 0;
	my $bsFullbath = 0;
	my $bsHalfbath = 0;
	my $bsBedrooms = 0;
	my $bsOther    = 0;
	my $bsRmCount  = 0;

	my @rmarr = split( /,/, $inrec->{'Rooms'} );
	my $indx  = 0;
	my $rindx = 0;
	my $rlim  = @rmarr - 3;
	while ( $rindx <= $rlim ) {
		my $rmtype = $rmarr[$rindx];
		my $rmsz   = $rmarr[ $rindx + 1 ];
		my $rmflr  = $rmarr[ $rindx + 2 ];
		$rmtype =~ s/^\s+|\s+$//g;
		$rmflr  =~ s/ //g;

		if ( $rmflr !~ /B/ ) {
			if ( $rmtype =~
/Bedroom|Breakfast|Bonus|Den|Dining|Exercise|Family|Great|Home Office|Home Theater|Kitchen|Library|Living|Master|Mud|Parlor|Rec|Sauna|Sewing|Spa|Study|Library|Sun/i
			  )
			{
				$rooms++;
			}
			if ( $rmtype =~ /Full Bath/i ) {
				$fullbath++;
			}
			if ( $rmtype =~ /Half Bath/i ) {
				$halfbath++;
			}
			if ( $rmtype =~ /Bedroom|Master/ ) {
				$bedrooms++;
			}
		}
		if ( $rmflr =~ /B/ ) {
			if ( $rmtype =~
				 /Bonus|Den|Family|Great|Library|Living|Rec|Study|Library/i )
			{
				$bsRecRm++;
				$bsRmCount++;
			}
			if ( $rmtype =~
/Breakfast|Dining|Exercise|Home Office|Home Theater|Kitchen|Mud|Parlor|Sauna|Sewing|Spa|Sun/i
			  )
			{
				$bsOther++;
				$bsRmCount++;
			}
			if ( $rmtype =~ /Full Bath/i ) {
				$bsFullbath++;
				$bsRmCount++;
			}
			if ( $rmtype =~ /Half Bath/i ) {
				$bsHalfbath++;
				$bsRmCount++;
			}
			if ( $rmtype =~ /Bedroom|Master/ ) {
				$bsBedrooms++;
				$bsRmCount++;
			}
		}

		$indx++;
		$rindx = $indx * 3;

	}

	my $bsRmList = '';
	if ( $bsRmCount > 0 ) {
		if ( $bsRecRm > 0 )    { $bsRmList = $bsRecRm . "rr"; }
		if ( $bsBedrooms > 0 ) { $bsRmList = $bsRmList . $bsBedrooms . "br"; }
		if ( ( $bsFullbath + $bsHalfbath ) > 0 ) {
			$bsRmList = $bsRmList . $bsFullbath . "." . $bsHalfbath . "ba";
		}
		if ( $bsOther > 0 ) { $bsRmList = $bsRmList . $bsOther . "o"; }
	}

	$rental{'roomcnt'} =
	    $rooms 
	  . $wtline
	  . $bedrooms
	  . $wtline
	  . $fullbath . "."
	  . $halfbath
	  . $wtline
	  . $wtline;

	my $sfAGFin = $inrec->{'SqFt Above Grade Fin'};
	my $sfAGTot = $inrec->{'SqFt Above Grade Total'};
	my $sfAGUnF = $inrec->{'SqFt Above Grade UnFin'};
	my $sfBGFin = $inrec->{'SqFt Below Grade Fin'};
	my $sfBGTot = $inrec->{'SqFt Below Grade Total'};
	my $sfBGUnF = $inrec->{'SqFt Below Grade Unfin'};
	my $sfFnTot = $inrec->{'SqFt Fin Total'};
	my $sfGaFin = $inrec->{'SqFt Garage Fin'};
	my $sfGaTot = $inrec->{'SqFt Garage Total'};
	my $sfGaUnF = $inrec->{'SqFt Garage Unfin'};
	my $sfTotal = $inrec->{'SqFt Total'};
	my $sfUnTot = $inrec->{'SqFt Unfin Total'};

	my $basType = "wo";

	# gla above grade
	my $gla = $sfAGFin;
	$rental{'gla'} = $gla . $wtline . $wtline;

	# other line 1
	if ( $rooms == 0 ) {
		$rental{'other1'} =
		  $sfTotal . "sf" . $sfFnTot . "sf" . $basType . $wtline . $wtline;
	} else {
		$rental{'other1'} =
		  $sfBGTot . "sf" . $sfBGFin . "sf" . $basType . $wtline . $wtline;
	}

	# other2
	$rental{'other2'} = $bsRmList . $wtline . $wtline;

	# other3
	my $garout    = "No Garage";
	my $garcarnum = $inrec->{'Garage Num Cars'};
	if ( $garcarnum >= 1 ) {
		$garout = $garcarnum . " Car Garage";
	}
	$rental{'other3'} = $garout . $wtline . $wtline . $wtline . $wtline;

	print $outfile "\n";
	while ( my ( $key, $value ) = each(%rental) ) {
		print $outfile $value;

		#print $outfile "$key => $value\n";

	}
	print $outfile "\n";
	

	# 403 Valley Road Ext # ACharlottesville, VA 229031.06 miles NE2,0250.93XMLS#508911, MLS#50704308/03/2013, 09/15/2012Fry's Spring
	# 43Above Average2,1702,1702,025531.11,085975531.11,0851,050  
	# format for 1025 rent comparables
	tie my %rent1025 => 'Tie::IxHash',
	  address1     => '',
	  address2     => '',
	  prox         => '',
	  rent         => '',
	  rentgba      => '',
	  rentctrl     => '',
	  datasrc      => '',
	  leasedate    => '',
	  location     => '',
	  age          => '',
	  condition    => '',
	  GBA          => '';
	
	$rent1025{'address1'}  = $address1 . $wtline;
	$rent1025{'address2'}  = $address2 . $wtline;
	$rent1025{'prox'}      = $wtline;	
	$rent1025{'rent'}      = $rentmon . $wtline;
	$rent1025{'rentgba'}   = $wtline;
	$rent1025{'rentctrl'}  = $wtline . 'X' . $wtline;
	$rent1025{'datasrc'}   = "MLS#" . $mlnumber . $wtline;
	$rent1025{'leasedate'} = $begindate . $wtline;
	$rent1025{'location'}  = $location . $wtline;
	$rent1025{'age'}       = $age . $wtline; 
	$rent1025{'condition'} = $wtline;
	$rent1025{'GBA'}       = $sfFnTot . $wtline;
	
	print $outfile "\n";
	while ( my ( $key, $value ) = each(%rent1025) ) {
		print $outfile $value;
		#print $outfile "$key => $value\n";
	}
	print $outfile "\n";

}

sub printFields {
	my ($localhash) = shift;
	my ($localfile) = shift;

	while ( my ( $k, $v ) = each %$localhash ) {
		print $localfile "$k\t";
	}
	print $localfile "\n";
}

sub checkRcdSource {

	# check the source of data:
	# CAARMLS: My Email Address EJEKEENAN@YAHOO.COM
	# MRIS:
	# CVAR: Whaley

	my $line = shift;
	if ( ( $line =~ /CAAR Lockbox/ig ) ) {
		return ("CAAR");
	} elsif ( $line =~ /abovegradeareafinished/ig ) {
		return ("MRIS");
	} elsif ( $line =~ /CVRMLS/ig ) {
		return ("CVRMLS");
	} else {
		return ("CAAR");
	}
}

sub WTrecord {

	# output record
	# side data structure
	tie my %wthash        => 'Tie::IxHash',
	  StreetNum           => '',
	  StreetDir           => '',
	  StreetName          => '',
	  StreetSuffix        => '',
	  Address1            => '',
	  Address2            => '',
	  Address3            => '',
	  City                => '',
	  State               => '',
	  Zip                 => '',
	  PropertyRights      => '',
	  DataSource1         => '',
	  DataSource2         => '',
	  DesignAppeal1       => '',
	  DesignConstrQual    => '',
	  Age                 => '',
	  AgeCondition1       => '',
	  CarStorage1         => '',
	  LotSize             => '',
	  LotView             => '',
	  CoolingType         => '',
	  FunctionalUtility   => '',
	  EnergyEfficiencies1 => '',
	  SalePrice           => '',
	  Status              => '',
	  Beds                => '',
	  Baths               => '',
	  BathsFull           => '',
	  BathsHalf           => '',
	  Basement1           => '',
	  Basement2           => '',
	  ExtraCompInfo2      => '',
	  ExtraCompInfo1      => '',
	  SqFt                => '',
	  Rooms               => '',
	  Location1           => '',
	  DateSaleTime1       => '',
	  DateSaleTime2       => '',
	  FinanceConcessions1 => '',
	  FinanceConcessions2 => '',
	  Porch               => '',
	  Patio               => '',
	  Deck                => '',
	  FencePorchPatio2    => '',
	  ExtraCompInfo3      => '',
	  Notes1              => '',
	  Photo               => '',
	  MediaFlag           => '',
	  MediaLink           => '',
	  MLNumber            => '',
	  PropType            => '',
	  County              => '',
	  DateofPriorSale1    => '',
	  PriceofPriorSale1   => '',
	  DataSourcePrior1    => '',
	  EffectiveDatePrior1 => '',
	  Dependencies        => '',
	  Amenities           => '',
	  UnitNum             => '',
	  HoaFee              => '',
	  AgentNotes          => '',
	  Zoning              => '',
	  SaleDateFormatted   => '',
	  DOM                 => '',
	  FinConc             => '',
	  FinFullNm           => '',	  
	  FinOther            => '',
	  Conc                => '',
	  SaleStatus          => '',
	  SaleDate            => '',
	  ContDate            => '',	  
	  Stories             => '',
	  Design              => '';
	  
	#DOM                 => '',
	#CloseDate           => '',
	#ContrDate           => '';

	tie my %sdhash   => 'Tie::IxHash',
	  fullStreetName => "",
	  streetSuffix   => "";

	#my $val = $wthash{key1};
	#print %wthash;

	return \%wthash;
}

sub suffixabbr {
	tie my %sufhash => 'Tie::IxHash',
	  allee         => "aly",
	  alley         => "aly",
	  ally          => "aly",
	  anex          => "anx",
	  annex         => "anx",
	  annx          => "anx",
	  arcade        => "arc",
	  av            => "ave",
	  aven          => "ave",
	  avenu         => "ave",
	  avenue        => "ave",
	  avn           => "ave",
	  avnue         => "ave",
	  bayoo         => "byu",
	  bayou         => "byu",
	  beach         => "bch",
	  bend          => "bnd",
	  bluf          => "blf",
	  bluff         => "blf",
	  bluffs        => "blfs",
	  bot           => "btm",
	  bottm         => "btm",
	  bottom        => "btm",
	  boul          => "blvd",
	  boulevard     => "blvd",
	  boulv         => "blvd",
	  branch        => "br",
	  brdge         => "brg",
	  bridge        => "brg",
	  brnch         => "br",
	  brook         => "brk",
	  brooks        => "brks",
	  burg          => "bg",
	  burgs         => "bgs",
	  bypa          => "byp",
	  bypas         => "byp",
	  bypass        => "byp",
	  byps          => "byp",
	  camp          => "cp",
	  canyn         => "cyn",
	  canyon        => "cyn",
	  cape          => "cpe",
	  causeway      => "cswy",
	  causway       => "cswy",
	  cen           => "ctr",
	  cent          => "ctr",
	  center        => "ctr",
	  centers       => "ctrs",
	  centr         => "ctr",
	  centre        => "ctr",
	  circ          => "cir",
	  circl         => "cir",
	  circle        => "cir",
	  circles       => "cirs",
	  ck            => "crk",
	  cliff         => "clf",
	  cliffs        => "clfs",
	  club          => "clb",
	  cmp           => "cp",
	  cnter         => "ctr",
	  cntr          => "ctr",
	  cnyn          => "cyn",
	  common        => "cmn",
	  corner        => "cor",
	  corners       => "cors",
	  course        => "crse",
	  court         => "ct",
	  courts        => "cts",
	  cove          => "cv",
	  coves         => "cvs",
	  cr            => "crk",
	  crcl          => "cir",
	  crcle         => "cir",
	  crecent       => "cres",
	  creek         => "crk",
	  crescent      => "cres",
	  cresent       => "cres",
	  crest         => "crst",
	  crossing      => "xing",
	  crossroad     => "xrd",
	  crscnt        => "cres",
	  crsent        => "cres",
	  crsnt         => "cres",
	  crssing       => "xing",
	  crssng        => "xing",
	  crt           => "ct",
	  curve         => "curv",
	  dale          => "dl",
	  dam           => "dm",
	  div           => "dv",
	  divide        => "dv",
	  driv          => "dr",
	  drive         => "dr",
	  drives        => "drs",
	  drv           => "dr",
	  dvd           => "dv",
	  estate        => "est",
	  estates       => "ests",
	  exp           => "expy",
	  expr          => "expy",
	  express       => "expy",
	  expressway    => "expy",
	  expw          => "expy",
	  extension     => "ext",
	  extensions    => "exts",
	  extn          => "ext",
	  extnsn        => "ext",
	  falls         => "fls",
	  ferry         => "fry",
	  field         => "fld",
	  fields        => "flds",
	  flat          => "flt",
	  flats         => "flts",
	  ford          => "frd",
	  fords         => "frds",
	  forest        => "frst",
	  forests       => "frst",
	  forg          => "frg",
	  forge         => "frg",
	  forges        => "frgs",
	  fork          => "frk",
	  forks         => "frks",
	  fort          => "ft",
	  freeway       => "fwy",
	  freewy        => "fwy",
	  frry          => "fry",
	  frt           => "ft",
	  frway         => "fwy",
	  frwy          => "fwy",
	  garden        => "gdn",
	  gardens       => "gdns",
	  gardn         => "gdn",
	  gateway       => "gtwy",
	  gatewy        => "gtwy",
	  gatway        => "gtwy",
	  glen          => "gln",
	  glens         => "glns",
	  grden         => "gdn",
	  grdn          => "gdn",
	  grdns         => "gdns",
	  green         => "grn",
	  greens        => "grns",
	  grov          => "grv",
	  grove         => "grv",
	  groves        => "grvs",
	  gtway         => "gtwy",
	  harb          => "hbr",
	  harbor        => "hbr",
	  harbors       => "hbrs",
	  harbr         => "hbr",
	  haven         => "hvn",
	  havn          => "hvn",
	  height        => "hts",
	  heights       => "hts",
	  hgts          => "hts",
	  highway       => "hwy",
	  highwy        => "hwy",
	  hill          => "hl",
	  hills         => "hls",
	  hiway         => "hwy",
	  hiwy          => "hwy",
	  hllw          => "holw",
	  hollow        => "holw",
	  hollows       => "holw",
	  holws         => "holw",
	  hrbor         => "hbr",
	  ht            => "hts",
	  hway          => "hwy",
	  inlet         => "inlt",
	  island        => "is",
	  islands       => "iss",
	  isles         => "isle",
	  islnd         => "is",
	  islnds        => "iss",
	  jction        => "jct",
	  jctn          => "jct",
	  jctns         => "jcts",
	  junction      => "jct",
	  junctions     => "jcts",
	  junctn        => "jct",
	  juncton       => "jct",
	  key           => "ky",
	  keys          => "kys",
	  knol          => "knl",
	  knoll         => "knl",
	  knolls        => "knls",
	  la            => "ln",
	  lake          => "lk",
	  lakes         => "lks",
	  landing       => "lndg",
	  lane          => "ln",
	  lanes         => "ln",
	  ldge          => "ldg",
	  light         => "lgt",
	  lights        => "lgts",
	  lndng         => "lndg",
	  loaf          => "lf",
	  lock          => "lck",
	  locks         => "lcks",
	  lodg          => "ldg",
	  lodge         => "ldg",
	  loops         => "loop",
	  manor         => "mnr",
	  manors        => "mnrs",
	  meadow        => "mdw",
	  meadows       => "mdws",
	  medows        => "mdws",
	  mill          => "ml",
	  mills         => "mls",
	  mission       => "msn",
	  missn         => "msn",
	  mnt           => "mt",
	  mntain        => "mtn",
	  mntn          => "mtn",
	  mntns         => "mtns",
	  motorway      => "mtwy",
	  mount         => "mt",
	  mountain      => "mtn",
	  mountains     => "mtns",
	  mountin       => "mtn",
	  mssn          => "msn",
	  mtin          => "mtn",
	  neck          => "nck",
	  orchard       => "orch",
	  orchrd        => "orch",
	  overpass      => "opas",
	  ovl           => "oval",
	  parks         => "park",
	  parkway       => "pkwy",
	  parkways      => "pkwy",
	  parkwy        => "pkwy",
	  passage       => "psge",
	  paths         => "path",
	  pikes         => "pike",
	  pine          => "pne",
	  pines         => "pnes",
	  pk            => "park",
	  pkway         => "pkwy",
	  pkwys         => "pkwy",
	  pky           => "pkwy",
	  place         => "pl",
	  plain         => "pln",
	  plaines       => "plns",
	  plains        => "plns",
	  plaza         => "plz",
	  plza          => "plz",
	  point         => "pt",
	  points        => "pts",
	  port          => "prt",
	  ports         => "prts",
	  prairie       => "pr",
	  prarie        => "pr",
	  prk           => "park",
	  prr           => "pr",
	  rad           => "radl",
	  radial        => "radl",
	  radiel        => "radl",
	  ranch         => "rnch",
	  ranches       => "rnch",
	  rapid         => "rpd",
	  rapids        => "rpds",
	  rdge          => "rdg",
	  rest          => "rst",
	  ridge         => "rdg",
	  ridges        => "rdgs",
	  river         => "riv",
	  rivr          => "riv",
	  rnchs         => "rnch",
	  road          => "rd",
	  roads         => "rds",
	  route         => "rte",
	  rvr           => "riv",
	  shoal         => "shl",
	  shoals        => "shls",
	  shoar         => "shr",
	  shoars        => "shrs",
	  shore         => "shr",
	  shores        => "shrs",
	  skyway        => "skwy",
	  spng          => "spg",
	  spngs         => "spgs",
	  spring        => "spg",
	  springs       => "spgs",
	  sprng         => "spg",
	  sprngs        => "spgs",
	  spurs         => "spur",
	  sqr           => "sq",
	  sqre          => "sq",
	  sqrs          => "sqs",
	  squ           => "sq",
	  square        => "sq",
	  squares       => "sqs",
	  station       => "sta",
	  statn         => "sta",
	  stn           => "sta",
	  str           => "st",
	  strav         => "stra",
	  strave        => "stra",
	  straven       => "stra",
	  stravenue     => "stra",
	  stravn        => "stra",
	  stream        => "strm",
	  street        => "st",
	  streets       => "sts",
	  streme        => "strm",
	  strt          => "st",
	  strvn         => "stra",
	  strvnue       => "stra",
	  sumit         => "smt",
	  sumitt        => "smt",
	  summit        => "smt",
	  terr          => "ter",
	  terrace       => "ter",
	  throughway    => "trwy",
	  tpk           => "tpke",
	  tr            => "trl",
	  trace         => "trce",
	  traces        => "trce",
	  track         => "trak",
	  tracks        => "trak",
	  trafficway    => "trfy",
	  trail         => "trl",
	  trails        => "trl",
	  trk           => "trak",
	  trks          => "trak",
	  trls          => "trl",
	  trnpk         => "tpke",
	  trpk          => "tpke",
	  tunel         => "tunl",
	  tunls         => "tunl",
	  tunnel        => "tunl",
	  tunnels       => "tunl",
	  tunnl         => "tunl",
	  turnpike      => "tpke",
	  turnpk        => "tpke",
	  underpass     => "upas",
	  union         => "un",
	  unions        => "uns",
	  valley        => "vly",
	  valleys       => "vlys",
	  vally         => "vly",
	  vdct          => "via",
	  viadct        => "via",
	  viaduct       => "via",
	  view          => "vw",
	  views         => "vws",
	  vill          => "vlg",
	  villag        => "vlg",
	  village       => "vlg",
	  villages      => "vlgs",
	  ville         => "vl",
	  villg         => "vlg",
	  villiage      => "vlg",
	  vist          => "vis",
	  vista         => "vis",
	  vlly          => "vly",
	  vst           => "vis",
	  vsta          => "vis",
	  walks         => "walk",
	  well          => "wl",
	  wells         => "wls",
	  wy            => "way";

	return \%sufhash;

}

sub compimpexe {

	# inputs:
	# 1. Name and path of file to be imported
	# 2. Import template to use
	# 3. Duplicates mode: add new, update existing, skip, or cancel [0,1,2,3]
	# 4. Number of comps to import

	my $impfname = shift;
	my $imptemp  = shift;
	my $dmode    = shift;
	my $numcomps = shift;

	#my $file2bproc = $impfname;
	my $this_os = Win32::GetOSName();
	( my $base, my $dir, my $ext ) = fileparse( $impfname, '\..*' );
	my $file2bproc = $base . $ext;

	if ( $this_os =~ /WinXP/ig ) {
		set_regkey($dir);
	}

	#chdir $dir;
	#my $curdir = getcwd();

	# message window variables
	my ( $mbmsg, $mbtitle, $mbflags, $return );

	#remove to print# "Setting up for comp import\n";

	# check path of compimp.exe, ProgramDir=dirletter:\wintotal
	my ( $field, $alapath, $fhalamodeini ) = undef;
	my $alamodeini = "c:\\Windows\\alamode.ini";
	if ( !( open $fhalamodeini, '<', $alamodeini ) ) {
		errmsgbox("$alamodeini not found");
		return 0;
	} else {
		while (<$fhalamodeini>) {
			chomp;
			( $field, $alapath ) = split("=");
			if ( $field =~ /programdir/ig ) { last }
		}
		close $fhalamodeini;
	}

	# start system("start W:\\WinTOTAL\\CompImp\\compimp.exe");
	my $t0 = [gettimeofday];

	#	my @args = ( "start", "$alapath\\CompImp\\compimp.exe" );
	#my @args = ( "start /B /MIN", "$alapath\\CompImp\\compimp.exe");
	#	if ( !system(@args) == 0 ) {
	#		errmsgbox("$alapath\\CompImp\\compimp.exe not found");
	#		return 0;
	#	}

	my $ProcessObj;
	Win32::Process::Create( $ProcessObj, "$alapath\\CompImp\\compimp.exe",
							"", 0, NORMAL_PRIORITY_CLASS, "." )
	  || die ErrorReport();

	# wait 10 sec. until Comps Import Database Wizard window opens, die if not.
	#remove to print# "Waiting for Comps Import Wizard to start\n";
	my @wTopCDIM = FindWindowLike( undef, "^Comps Database Import Wizard" );
	$t0 = [gettimeofday];
	while ( !@wTopCDIM ) {
		@wTopCDIM = FindWindowLike( undef, "^Comps Database Import Wizard" );
		my $elapsed = tv_interval($t0);

		#print "Sec. elapsed: $elapsed\n";
		if ( $elapsed > 30 ) {
			errmsgbox(
					"Comps Database Import Wizard not starting. exiting now\n");
			return 0;
		}
	}

	SetForegroundWindow( $wTopCDIM[0] );
	SetFocus( $wTopCDIM[0] );

# --------------------------------------------------------------------------------------------
# 1st control to set: Radio Button, "Use previously defined template"
# Appears to always be the same control, but no text to identify control
# SSOptionWndClass[1]
# sibling of: ThunderRT6Frame "Frame1", which has parent: SSTabPanelWndClass

	# all the edit controls are in "Frame1"
	my @ThunderRT6Frame = [];
	my $parent          = 0;
	WaitForReady( $wTopCDIM[0] );
	@ThunderRT6Frame =
	  FindWindowLike( $wTopCDIM[0], "Frame1", "ThunderRT6Frame", undef );
	my $value = $ThunderRT6Frame[0];
	$parent = GetParent($value);
	my @SSOptionWndClass =
	  FindWindowLike( $parent, undef, "SSOptionWndClass", undef, 2 );
	SetForegroundWindow( $wTopCDIM[0] );
	SetActiveWindow( $wTopCDIM[0] );
	SetFocus( $SSOptionWndClass[1] );

# --------------------------------------------------------------------------------------------
# 2nd control to set: conversion template
# control properties for conversion template (e.g.: Import V.2 CAAR,MRIS)
# SSActiveTabsWndClass
# SSTabPanelWndClass (Parent)
# ThunderRT6UserControlDC
# style WS_VISIBLE (10000000)
# 540108C0 window style (visible, enabled)

	my $convTemp_Ctrl_ID = 3;

	# move to control and set focus
	@ThunderRT6Frame =
	  FindWindowLike( $wTopCDIM[0], "Frame1", "ThunderRT6Frame" );
	$parent = GetParent( $ThunderRT6Frame[0] );
	my @ThunderRT6UserControlDC =
	  FindWindowLike( $parent, undef, "ThunderRT6UserControlDC", undef, 2 );

#my @ThunderRT6TextBox = FindWindowLike( $ThunderRT6UserControlDC[0], undef, "ThunderRT6TextBox", $convTemp_Ctrl_ID, 2);
	my @convTempField =
	  FindWindowLike( $parent, undef, "ThunderRT6TextBox", $convTemp_Ctrl_ID,
					  3 );
	SetForegroundWindow( $wTopCDIM[0] );
	SetActiveWindow( $wTopCDIM[0] );
	SetFocus( $convTempField[0] );

	# send up/down arrow until specified import template is reached
	my $convTemp = getEditBoxTxt( $convTempField[0] );

  #	if ( $convTemp !~ /^$imptemp/ig ) {
  #		my $cnt = 0;
  #
  #		# up arrow to top
  #		SendKeys("{UP 20}");
  #
  #		# now check each one after down arrow
  #		while ( $convTemp !~ /^$imptemp/ig ) {
  #			SetForegroundWindow( $wTopCDIM[0] );
  #			SetActiveWindow( $wTopCDIM[0] );
  #			SetFocus( $convTempField[0] );
  #			SendKeys("{DOWN}");
  #			$convTemp = getEditBoxTxt( $convTempField[0] );
  #
  #			#remove to print# "$convTemp\n";
  #			if ( $cnt++ == 20 ) {
  #
  #	#display message box that conversion template was not found, then exit on OK
  #				errmsgbox("Conversion template not found, exiting");
  #				return 0;
  #			}
  #		}
  #	}
	$convTemp = getEditBoxTxt( $convTempField[0] );

# --------------------------------------------------------------------------------------------
# 3rd conrol to set: file name to convert
# control properties for name of file to convert (e.g.: filename.txt)
# SSActiveTabsWndClass
# SSTabPanelWndClass
# ThunderRT6Frame "Frame1"
# ThunderRT6UserControlDC
# style WS_VISIBLE (10000000)
#my $fstyle = '540108C0';

	# all the edit controls are in "Frame1"
	# find the "Browse" button
	@ThunderRT6Frame =
	  FindWindowLike( $wTopCDIM[0], "Frame1", "ThunderRT6Frame" );
	my @BrowseButton =
	  FindWindowLike( $ThunderRT6Frame[0], undef, "ThunderRT6UserControlDC" );

	SetForegroundWindow( $wTopCDIM[0] );
	SetActiveWindow( $wTopCDIM[0] );
	SetFocus( $BrowseButton[0] );
	my $focus = GetFocus( $wTopCDIM[0] );
	$t0 = [gettimeofday];
	while ( $focus != $BrowseButton[0] ) {

		#remove to print# print "Browse button not in focus";
		SetFocus( $BrowseButton[0] );
		$focus = GetFocus( $wTopCDIM[0] );
		my $elapsed = tv_interval($t0);
		if ( $elapsed > 3 ) {
			errmsgbox("Browse Button not found");
			return 0;
		}
	}

	#print "Got Browse Button\n";

  # wait until focus is set on browse button, then hit Enter (uncertain bug fix)
	$t0 = [gettimeofday];
	WaitForReady( $wTopCDIM[0],     2000 );
	WaitForReady( $BrowseButton[0], 2000 );
	my $elapsed = tv_interval($t0);

	#print "$elapsed\n";
	Time::HiRes::sleep(.25);
	SetActiveWindow( $wTopCDIM[0] );
	Time::HiRes::sleep(.25);
	SendKeys( "~", .5 );

	# wait until open dialog appears then enter file name

	my @wOpenDialog = FindWindowLike( undef, "^Open" );
	$t0 = [gettimeofday];
	while ( !@wOpenDialog ) {
		@wOpenDialog = FindWindowLike( undef, "^Open" );
		my $elapsed = tv_interval($t0);

		#print "$elapsed\n";
		if ( $elapsed > 2 ) {
			errmsgbox("Open File Box not opening");
			return 0;
		}
	}

	#sleep 2;
	WaitForReady( $wOpenDialog[0], 4000 );

	#remove to print# print "File being imported: $file2bproc\n";
	SendKeys( "$file2bproc", 1 );
	SendKeys("~");
	Time::HiRes::sleep(.25);

	if ( $numcomps < 3 ) {

# --------------------------------------------------------------------------------------------
# finished first page setup, now click NEXT
# Get NEXT button
		my @butParent =
		  FindWindowLike( $wTopCDIM[0], undef, "ThunderRT6UserControlDC", undef,
						  2 );
		my @buttons =
		  FindWindowLike( $butParent[0], undef, "ThunderRT6UserControlDC",
						  undef, 2 );

		# set focus to NEXT button and send ENTER
		SetForegroundWindow( $wTopCDIM[0] );
		SetFocus( $buttons[1] );
		WaitForReady( $buttons[1], 3000 );
		SendKeys("~");

# --------------------------------------------------------------------------------------------
# check for next form, either "Preview Duplicate Comparable", or CLOSE button
		@butParent =
		  FindWindowLike( $wTopCDIM[0], undef, "ThunderRT6UserControlDC", undef,
						  2 );
		@buttons =
		  FindWindowLike( $butParent[0], undef, "ThunderRT6UserControlDC",
						  undef, 2 );

		my $Close_Button = $buttons[3];

#print "Close button enabled: "; print IsWindowEnabled( $Close_Button ); print "\n";

 #remove to print# print "Setup Complete. Comp Importer now processing comps\n";
		$t0 = [gettimeofday];
		my $tcnt          = 0;
		my $duplicateComp = 0;
		while ( !IsWindowEnabled($Close_Button) ) {

			# print status every second
			my $elapsed = tv_interval($t0);
			if ( $elapsed > $tcnt ) {

				#remove to print# print "Processing comps... \n";
				$tcnt = $tcnt + 0.5;    #print every half sec
			}
			my @wPDC = FindWindowLike( undef, "^Preview Duplicate Comparable" );
			if ( !@wPDC ) {

				#print "Waiting... \n";
				my @wTopCDIM =
				  FindWindowLike( undef, "^Comps Database Import Wizard" );

				#quit if Comps Database Import Wizard has been closed
				if ( !@wTopCDIM ) {
					errmsgbox("Comps Database Import Wizard Gone");
					return 0;
				}

			} elsif ( !$duplicateComp ) {
				$duplicateComp = 1;

			#remove to print# print "Got Preview Duplicate Comparable dialog\n";

				SetForegroundWindow( $wPDC[0] );
				SetActiveWindow( $wPDC[0] );

				# check the box for apply to all
				my @wCheck =
				  FindWindowLike( $wPDC[0], undef, "SSCheckWndClass" );
				SetFocus( $wCheck[0] );
				my $focus = GetFocus( $wPDC[0] );

				#print "$focus\n";
				my $t0 = [gettimeofday];
				while ( $focus != $wCheck[0] ) {

					#remove to print# print "Check box not in focus";
					my $elapsed = tv_interval($t0);
					if ( $elapsed > 10 ) {
						errmsgbox("Check box not in focus");
						return 0;
					}
					SetFocus( $wCheck[0] );
					$focus = GetFocus( $wPDC[0] );
				}
				WaitForReady( $wPDC[0], 3000 );
				SendKeys("{SPACEBAR}");

# focus on button specified by input (Add New, Update Existing, Skip, Cancel) button and send ENTER
				@wPDC =
				  FindWindowLike( undef, "^Preview Duplicate Comparable" );
				SetForegroundWindow( $wPDC[0] );
				SetActiveWindow( $wPDC[0] );

				# set focus to button specified by dmode
				my @wCtrl0 =
				  FindWindowLike( $wPDC[0], undef, "^ThunderRT6UserControlDC",
								  undef, 2 );
				SetFocus( $wCtrl0[$dmode] );
				$focus = GetFocus( $wPDC[0] );
				$t0    = [gettimeofday];
				while ( $focus != $wCtrl0[$dmode] ) {

					#remove to print# print "Waiting for import mode\n";
					my $elapsed = tv_interval($t0);
					if ( $elapsed > 10 ) {
						errmsgbox("Import mode box not in focus");
						return 0;
					}
					SetFocus( $wCtrl0[$dmode] );
					$focus = GetFocus( $wPDC[0] );
				}
				WaitForReady( $wPDC[0], 3000 );
				SendKeys('~');
			}
		}

		#remove to print# print "Ready to close\n";

		Time::HiRes::sleep(3);

		# Get CLOSE button, Finished
		SetForegroundWindow( $wTopCDIM[0] );
		SetFocus($Close_Button);
		$focus = GetFocus( $wTopCDIM[0] );

		#print "$focus\n";
		$t0 = [gettimeofday];
		while ( $focus != $Close_Button ) {
			my $elapsed = tv_interval($t0);

			#print "Waiting for final Close\n";
			SetForegroundWindow( $wTopCDIM[0] );
			SetFocus($Close_Button);
			$focus = GetFocus( $wTopCDIM[0] );

			if ( $elapsed > 3 ) {
				errmsgbox("Close Button not found");
				return 0;
			}
		}

		#remove to print# print "Comps Wizard closing\n";
		WaitForReady( $Close_Button, 3000 );
		SendKeys('~');

	}
}

sub getEditBoxTxt {

	# WM_GETTEXT is 0xD
	my $msg_id  = 0xd;
	my $hwnd    = $_[0];                      #0x204ba;
	my $buffer  = " " x 100;
	my $buf_ptr = pack( 'P', $buffer );
	my $ptr     = unpack( 'L!', $buf_ptr );
	SendMessage( $hwnd, $msg_id, 100, $ptr );

	#print "The result from Calculator is $buffer\n";
	return $buffer;
}

sub errmsgbox {

	#$mbmsg   = "Test Message";
	#$mbtitle = "Message Box Test";
	#$mbflags = MB_OK | MB_ICONWARNING | MB_TOPMOST | MB_SYSTEMMODAL;
	#$return  = Win32::GUI::MessageBox( 0, "$mbmsg", "$mbtitle", $mbflags );

	my $mbmsg   = shift;
	my $mbtitle = "Error";
	my $mbflags = MB_OK | MB_ICONWARNING | MB_TOPMOST | MB_SYSTEMMODAL;
	my $return  = Win32::GUI::MessageBox( 0, "$mbmsg", "$mbtitle", $mbflags );
}

sub set_regkey {

	#my $filepath    = 'C:\temp';
	my $filepath = shift;

	# encode the file path into utf16le binary for REG_BINARY
	my $new_path = 'CompImp.exe' . "\x00" . $filepath . "\x00";
	my $encode_path = encode( "utf16le", $new_path );

	my $LastVisitedMRU = $Registry->Open(
"HKEY_CURRENT_USER/Software/Microsoft/Windows/CurrentVersion/Explorer/ComDlg32/LastVisitedMRU",
		{ Access => KEY_READ() | KEY_WRITE(), Delimiter => "/" }
	);

	# get information on a regitry key
	my %keyInfo    = $LastVisitedMRU->Information;
	my @valueNames = $LastVisitedMRU->ValueNames;

	my $i        = 0;
	my $keyfound = 0;

	# check each entry under "LastVisitedMRU" for the compimp.exe entry
	foreach ( keys %$LastVisitedMRU ) {

		# get the next registry entry under key LastVisitedMRU
		my ( $mru_value_bin, $valueType ) =
		  $LastVisitedMRU->GetValue( $valueNames[$i] );
		my $mru_value_dec = decode( "utf16le", $mru_value_bin );

		# if it is for "compimp.exe" then set the path and quit the loop
		if ( $mru_value_dec =~ m/^CompImp.exe/ig ) {

		 #$key->SetValue( "ValueName", pack($format,$valueData), "REG_BINARY" );
			$LastVisitedMRU->SetValue( $valueNames[$i], $encode_path,
									   "REG_BINARY" );
			$keyfound = 1;
			last;
		}
		$i++;
	}

  # if entry not found, take over the least recently used one
  # because no doc found on how many entries permitted under this key and how to
  # name any after "z"
	if ( !$keyfound ) {

		# maximum MRU, pick last value and change it to compimp.exe
		# get the LastVisitedMRU entry named "MRUList"
		my ( $mrulist, $mrulist_type ) = $LastVisitedMRU->GetValue('MRUList');

# get the last entry in the MRUList, a letter that corresponds to the least recently
# used entry in the LastVistMRU list
		my $least_used_mru;
		if ( $mrulist =~ /(.$)/ig ) {
			$least_used_mru = $1;
		}

		$LastVisitedMRU->SetValue( $least_used_mru, $encode_path,
								   "REG_BINARY" );
	}
}

sub USA_Format {

	( my $n = shift ) =~ s/\G(\d{1,3})(?=(?:\d\d\d)+(?:\.|$))/$1,/g;
	return "\$$n";
}

sub commify {
	my $input = shift;
	$input = reverse $input;
	$input =~ s<(\d\d\d)(?=\d)(?!\d*\.)><$1,>g;
	return reverse $input;
}

