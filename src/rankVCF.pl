#!/usr/bin/perl

#USAGE: Run with no options to get usage or with --help for basic details

#Robert W. Leach
#Princeton University
#Carl Icahn Laboratory
#Lewis Sigler Institute for Integrative Genomics
#Bioinformatics Group
#Room 137A
#Princeton, NJ 08544
#rleach@princeton.edu
#Copyright 2017

#Template version: 1.0

use warnings;
use strict;
use CommandLineInterface;

our $VERSION = '1.04';
setScriptInfo(VERSION => $VERSION,
              CREATED => '6/22/2017',
              AUTHOR  => 'Robert William Leach',
              CONTACT => 'rleach@princeton.edu',
              COMPANY => 'Princeton University',
              LICENSE => 'Copyright 2017',
              HELP    => << 'END_HELP'

This script takes a sequence variant file in VCF format and sorts the records in the file in ranked order, with optional filtering.  If you have multiple samples for a variant on each row, you can define groups of samples, each with criteria to be met to keep each row, or filter it out.  E.g. You can specify that the genotype of a variant in samples 1 & 2 must be different from the genotype of the variant in samples 3 & 4.  Or you can specify that the genotype of the variant in at least N samples (1, 2, and 3) must differ from the genotype of the variant in at least M samples (4, 5, 6, and 7).

END_HELP
	      ,
	      DETAILED_HELP => << 'END_AHELP'

Sorting is done by descending number of samples with hits, descending total support/mapped ratio, descending number of total mapped reads, and ascending sample name.

Filtering is done using the minimum number of mapped reads, minimum variant support reads / total reads ratio, fewer than all have the variant, and by the comparison ratios by supplying pairs of sets of sample names required to be "different".  Each group of samples must be accompanied by a number of samples in the group that are required to differ from the other group in the pair of groups.  One of the groups' accompanying number of samples must represent over 50% of the samples.  Note, there must also be a minimum number of reads mapped in a variant location in order to be positively called a non-variant.

END_AHELP
	     );

setDefaults(HEADER        => 1,
	    ERRLIMIT      => 3,
	    COLLISIONMODE => 'error',
	    DEFRUNMODE    => 'usage',
	    DEFSDIR       => undef);

my $format_index            = 8;
my $sample_name_start_index = $format_index + 1;

my $vcf_type_id =
  addInfileOption(GETOPTKEY   => 'i|vcf-file|input-file=s',
		  REQUIRED    => 1,
		  PRIMARY     => 1,
		  DEFAULT     => undef,
		  SMRY_DESC   => 'VCF input file (generated by FreeBayes).',
		  FORMAT_DESC => << 'END_FORMAT'

A VCF file is a plain text, tab-delimited file.  The format is generally described here: http://bit.ly/2sulKcZ and described in detail here: http://bit.ly/2gKP5bN

However, the important parts that this script relies on are:

1. The column header line (in particular - looking for the FORMAT and sample name columns).
2. The colon-delimited codes in the FORMAT column values, specifically (for SNP data produced by freeBayes and Structural Variant data produced by SVTyper) AO (the number of reads supporting the variant) and DP (Read depth).  For structural variant data produced by Lumpy (without annotation by SVTyper), SU, SR, and PE are used for both filtering and ranking.
3. The colon-delimited values in the sample columns that correspond to the positions defined in the FORMAT column.

The file may otherwise be a standard VCF file containing header lines preceded by '##'.  Empty lines are OK and will be printed regardless of parameters supplied to this script.  Note, the --header and --no-header flags of this script do not refer to the VCF file's header, but rather the script run info header.  Note that with the script run info header, the output is no longer a standard VCF format file.  Use --no-header and the format of the output will be consistent with a standard VCF file.

END_FORMAT
		 );

addOutfileSuffixOption(GETOPTKEY   => 'o|outfile-suffix|outfile-extension=s',
		       PRIMARY     => 1,
		       DEFAULT     => undef,
		       SMRY_DESC   => 'Outfile extension (appended to -i).',
		       FORMAT_DESC => << 'END_FORMAT'

The output file is essentially the same format as the input VCF files, except 3 columns are added at the beginning of the file:

1. Number of hits and a summary of the filters that were passed passed
2. A listing of variant support/mapped reads per sample (or a listing of the stuctural variant support values that passed cutoffs (SU, SR, and/or PE).
3. A listing of samples containing evidence for the variant

END_FORMAT
		 );

my $sample_groups = [];
add2DArrayOption(GETOPTKEY   => 's|sample-group|filter-group=s',
		 GETOPTVAL   => $sample_groups,
		 DEFAULT     => 'none',
		 SMRY_DESC   => 'List of sample names for filtering.',
		 DETAIL_DESC => << 'END_DETAIL'

This is a filtering option that allows you to arbitrarily define pairs of groups of samples in which to require a minimum number of members' genotype state of a variant to differ in order to pass filtering.  For example, if you have 3 wildtype samples and 4 mutant samples, you can define these 2 groups using -s 's1 s2 s3' -s 's4 s5 s6 s7' (where 's1' and other sample names match the sample names in the VCF column headers row).  If you want to require that at least 1 of the mutants differ from all the wildtype samples, after defining these groups, you would use: -d 3 -d 1.  The ordering of the options is important.

Note, if you are filtering a VCF file produced by Lumpy and haven't annotated the results with SVTyper, negative results cannot be confirmed.  Lumpy does not output support that a structural variant does not exist.  So results from this filtering must be taken with a large grain of salt.

END_DETAIL
		);

my $group_diff_mins = [];
addArrayOption(GETOPTKEY   => 'd|group-diff-min=s',
	       GETOPTVAL   => $group_diff_mins,
	       DEFAULT     => 'all',
	       SMRY_DESC   => 'Number of group samples required to differ.',
	       DETAIL_DESC => << 'END_DETAIL'

Sample groups defined by -s are procssed in pairs.  Each -s group is accompanied by a minimum number of samples in that group that are required to be different from the genotype of its partner group.  "Different" in this case means the genotype state of each sample for the variant defined by the VCF record (a data row/line in the VCF file).

END_DETAIL
		);

my $min_support_ratio = 0.7;
addOption(GETOPTKEY   => 'm|min-support-ratio=s',
	  GETOPTVAL   => \$min_support_ratio,
	  DEFAULT     => $min_support_ratio,
	  SMRY_DESC   => 'Minimum ratio of variant reads vs total.',
	  DETAIL_DESC => ('Minimum ratio of reads supporting a variant ' .
			  '(over total reads that mapped over the variant) ' .
			  'in order to keep the row/line/record.  If any ' .
			  'sample meets this requirement, the entire record ' .
			  'is kept (potentially including samples which ' .
			  'failed this filter).  Applies to all samples.  ' .
			  'Only used VCF records produced by freeBayes and ' .
			  'SVTyper, as it requires AO and DP to be present ' .
			  'in the FORMAT string - otherwise ignored.  In ' .
			  'the case of structural variants from SVTyper, AO ' .
			  'is assumed to indicate the number of split, soft-' .
			  'clipped, or discordant reads that support the ' .
			  'variant and everything else is attroibuted to RO ' .
			  'support (reference observations, i.e. number of ' .
			  'reads that span the breakpoint).'));

my $min_read_depth = 2;
addOption(GETOPTKEY   => 'r|min-read-depth=i',
	  GETOPTVAL   => \$min_read_depth,
	  DEFAULT     => $min_read_depth,
	  SMRY_DESC   => 'Minimum number of reads mapped over small variant.',
	  DETAIL_DESC => ('Minimum number of reads required to have mapped ' .
			  'over a small variant position in order to make a ' .
			  'small variant call (e.g. a SNP).  If any sample ' .
			  'meets this requirement, the entire record is ' .
			  'kept (potentially including samples which failed ' .
			  'this filter).  Applies to all samples.  Only ' .
			  'used on freeBayes and SVTyper VCF records - ' .
			  'otherwise ignored.'));

my $min_discords_def = 0;
my($min_discords);
addOption(GETOPTKEY   => 'p|min-discordants=i',
	  GETOPTVAL   => \$min_discords,
	  DEFAULT     => $min_discords_def,
	  SMRY_DESC   => ('Min num of discordant read pairs supporting a ' .
			  'structural variant.'),
	  DETAIL_DESC => ('Minimum number of discordant read pairs required ' .
			  'to support a structural variant in order to make ' .
			  'a call.  This value, plus the value for -c must ' .
			  'be less than or equal to the value for -v (if -v ' .
			  'is also supplied).  If any sample meets this ' .
			  'requirement, the entire record is kept ' .
			  '(potentially including samples which failed this ' .
			  'filter).  A read pair (from a paired-end ' .
			  'sequencing run) is considered discordant if they ' .
			  'mapped to unexpected positions.  Pairs are ' .
			  'expected to map an specified distance from one ' .
			  'another (i.e. the sequencing insert length) in ' .
			  'specific orientations.  If the distance between ' .
			  'them or their orientation is not as expected, ' .
			  'they are discordant.  Applies to all samples.  ' .
			  'Only used on SV VCF records, such as are ' .
			  'produced by lumpy - otherwise ignored.  Requires ' .
			  'PE to be present in the FORMAT string.'));

my $min_splits_def = 0;
my($min_splits);
addOption(GETOPTKEY   => 'c|min-splits=i',
	  GETOPTVAL   => \$min_splits,
	  DEFAULT     => $min_splits_def,
	  SMRY_DESC   => ('Min num of split reads supporting a structural ' .
			  'variant.'),
	  DETAIL_DESC => ('Minimum number of split reads required to ' .
			  'support a structural variant in order to make a ' .
			  'call.  This value, plus the value for -p must be ' .
			  'less than or equal to the value for -v (if -v is ' .
			  'also supplied).  If any sample meets this ' .
			  'requirement, the entire record is kept ' .
			  '(potentially including samples which failed this ' .
			  'filter).  A split read (a.k.a. a soft-clipped ' .
			  'read) is a read where roughly half of it maps to ' .
			  'one position and the other half either does not ' .
			  'map (or maps to a different position).  Applies ' .
			  'to all samples.  Only used on SV VCF records, ' .
			  'such as are produced by lumpy - otherwise ' .
			  'ignored.  Requires SR to be present in the ' .
			  'FORMAT string.'));

my $min_svs_def = 0;
my($min_svs);
addOption(GETOPTKEY   => 'v|min-sv-reads=i',
	  GETOPTVAL   => \$min_svs,
	  DEFAULT     => "$min_svs_def*",
	  SMRY_DESC   => ('Min num of split or discordant reads supporting ' .
			  'a structural variant.'),
	  DETAIL_DESC => ('Minimum number of split reads or discordant read ' .
			  'pairs required to support a structural variant ' .
			  'in order to make a call.  Must be larger than or ' .
			  'equal to the sum of the values for -p and -c.  ' .
			  'If any sample meets this requirement, the entire ' .
			  'record is kept (potentially including samples ' .
			  'which failed this filter).  A split read (a.k.a. ' .
			  'a soft-clipped read) is a read where roughly ' .
			  'half of it maps to one position and the other ' .
			  'half either does not map (or maps to a different ' .
			  'position).  Applies to all samples.  Only used ' .
			  'on SV VCF records, such as are produced by lumpy ' .
			  '- otherwise ignored.  Requires SU to be present ' .
			  'in the FORMAT string.' .
			  "\n\n* If -c and/or -p are supplied, the default " .
			  "of this value is the sum of the values for -p " .
			  "and -c."));

processCommandLine();

#There must be an even number of sample groups
if(scalar(@$sample_groups) % 2)
  {
    error("There must be 2 (or an even number of) sample groups, but [",
	  scalar(@$sample_groups),"] were supplied.  See the usage ",
	  "description for -s for details.");
    quit(1);
  }

#Construct default values for the group_diff_mins if they weren't all supplied
if(scalar(@$sample_groups) &&
   scalar(@$sample_groups) != scalar(@$group_diff_mins))
  {
    my $all = (scalar(@$group_diff_mins) == 0);
    foreach my $sample_group_index (0..$#{$sample_groups})
      {
	if(scalar(@$group_diff_mins) < ($sample_group_index + 1))
	  {
	    if($all || ($group_diff_mins->[0] >
			scalar(@{$sample_groups->[$sample_group_index]})))
	      {$group_diff_mins->[$sample_group_index] =
		 scalar(@{$sample_groups->[$sample_group_index]})}
	    else
	      {$group_diff_mins->[$sample_group_index] = $group_diff_mins->[0]}
	  }
      }
  }

#If sample groups and multiple group diff mins were submitted
if(scalar(@$sample_groups) && scalar(@$group_diff_mins) > 1)
  {
    #There must be an equal number of group diff mins and their values must be
    #less than or equal to the group sizes
    if(scalar(@$group_diff_mins) != scalar(@$sample_groups) ||
       scalar(grep {$group_diff_mins->[$_] < 1 ||
		      $group_diff_mins->[$_] > scalar(@{$sample_groups->[$_]})}
	      (0..$#{$sample_groups})))
      {
	error("The group diff mins (-d) [",join(',',@$group_diff_mins),
	      "] must each be a positive value less than or equal to the ",
	      "number of members in the corresponding sample group [",
	      join(',',map {scalar(@$_)} @$sample_groups),"].  To require ",
	      "all members of each group be different, do not supply -d.  ",
	      "Unable to proceed.");
	quit(2);
      }
  }
elsif(scalar(@$sample_groups) && scalar(@$group_diff_mins) == 1)
  {
    #The values of the group diff mins must be less than or equal to the group
    #sizes
    if(scalar(grep {$group_diff_mins->[0] >= 0 &&
		      $group_diff_mins->[0] <=
			scalar(@{$sample_groups->[$_]})}
	      (0..$#{$sample_groups})) != 0)
      {
	warning("The group diff min (-d) should be a positive value less ",
		"than or equal to the number of members in each sample ",
		"group.  Note, the value will be reduced to the group size ",
		"for those groups that are smaller.");
      }
  }

#NOTE: One of the group_diff_mins in each pair must represent a majority of the
#corresponding group
if(scalar(@$sample_groups) &&
   scalar(grep {($group_diff_mins->[$_] >
		 (scalar(@{$sample_groups->[$_]}) / 2)) ||
		   ($group_diff_mins->[$_ + 1] >
		    (scalar(@{$sample_groups->[$_ + 1]}) / 2))}
	  grep {$_ % 2 == 0} (0..$#{$sample_groups})) == 0)
  {
    error("One of each pair of group diff mins (-d) must represent a ",
	  "majority of the number of members in its corresponding sample ",
	  "group.",
	  {DETAIL => "One group must serve as an unambiguous reference " .
	   "genotype.  It can be a single sample or a set of replicate " .
	   "samples.  This makes the results more interpretable."});
    quit(3);
  }

if(defined($min_svs))
  {
    if(!defined($min_discords))
      {$min_discords = $min_discords_def}
    if(!defined($min_splits))
      {$min_splits = $min_splits_def}
    my $min_svs = $min_discords + $min_splits;
  }
elsif(defined($min_discords) || defined($min_splits))
  {
    if(!defined($min_discords))
      {$min_discords = $min_discords_def}
    if(!defined($min_splits))
      {$min_splits = $min_splits_def}
    $min_svs = $min_discords + $min_splits;
  }
else
  {
    if(!defined($min_discords))
      {$min_discords = $min_discords_def}
    if(!defined($min_splits))
      {$min_splits = $min_splits_def}
    if(!defined($min_svs))
      {$min_svs = $min_svs_def}
  }

if($min_svs < ($min_discords + $min_splits))
  {
    my $sum = $min_discords + $min_splits;
    error(($min_svs_def < ($min_discords_def + $min_splits_def) ?
	   'Hard-coded defaults error: ' : ''),"-v [$min_svs] cannot be less ",
	  "than the sum of -p [$min_discords] and -c [$min_splits]: [$sum].");
    quit(4);
  }

if($min_discords < 0)
  {
    error("Invalid value for -p: [$min_discords].  Cannot be negative.");
    quit(5);
  }
elsif($min_splits < 0)
  {
    error("Invalid value for -c: [$min_splits].  Cannot be negative.");
    quit(6);
  }
elsif($min_svs < 0)
  {
    error("Invalid value for -v: [$min_svs].  Cannot be negative.");
    quit(7);
  }

my $global_mode = '';

while(nextFileCombo())
  {
    my $inputFile = getInfile();
    my $outputFile = getOutfile();

    openIn(*IN,$inputFile);

    my $line_num  = 0;
    my @samples   = ();
    my $data_line = 0;
    my @passed    = ();

    while(getLine(*IN)) #Using this method provides verbose functionality and
      {                 #automatic conversion of carriage return characters
	$line_num++;
	verboseOverMe({FREQUENCY => 100},
		      "[$inputFile] Reading line: [$line_num].");

	#If this is a header line that is not the (first) column header line
	if(/^##/ || (scalar(@samples) && /^#/) || /^\s*$/)
	  {
	    print;
	    next;
	  }

	chomp;
	my @cols = split(/\t/,$_,-1);

	#If this is the (first) column header line
	if(/^#[^#].*\t/ && scalar(@samples) == 0)
	  {
	    #Get the index of the FORMAT column - we will assume that the
	    #sample columns start immediately after and go to the end
	    if(/\tFORMAT\t/)
	      {
		#Assuming only 1 FORMAT column header
		$format_index = (grep {$cols[$_] eq 'FORMAT'} (0..$#cols))[0];
		$sample_name_start_index = $format_index + 1;
	      }
	    else
	      {
		warning("FORMAT column header not found on column header ",
			"line.  Using default expected FORMAT column number [",
			($format_index + 1),"] and sample column start ",
			"number [",($sample_name_start_index + 1),"].");
	      }

	    #If -s was supplied, the sample names in the column header are
	    #necessary - otherwise, we can assume that the header is just
	    #malformed and that the samples are where we would otherwise expect
	    #them to be in a standard VCF file (as produced by FreeBayes).
	    if(scalar(@samples) &&
	       scalar(@cols) < ($sample_name_start_index + 1))
	      {
		error("No columns for sample names were found on the ",
		      "column header line: [$_].  Unable to finish ",
		      "processing file [$inputFile].",
		      {DETAIL => "Sample names in the column header are " .
		       "used to identify sample columns for use with the -s " .
		       "and -d parameters, and to find the number of " .
		       "supporting read and total reads for each record.  " .
		       "If your column header line is malformed, but the " .
		       "data is there and you do not supply -s or -d, you " .
		       "will still be able to proceed using the default " .
		       "FORMAT column number [",($format_index + 1),"] and " .
		       "sample column start number [",
		       ($sample_name_start_index + 1),"]."});

		last;
	      }

	    @samples = @cols[$sample_name_start_index..$#cols];
	    s/#//;

	    #Print the new header
	    print("#NUMHITS,SEARCHCRITERIA\tSNPREAD/DEPTH\tSNPSAMPLES\t$_\n");

	    next;
	  }
	elsif(scalar(@samples) == 0)
	  {
	    warning("Column header line not found before data.  Using ",
		    "default expected FORMAT column number [",
		    ($format_index + 1),"] and sample column start number [",
		    ($sample_name_start_index + 1),"].");
	  }

	if(scalar(@cols) < ($sample_name_start_index + 1))
	  {
	    error("Sample data was not found on line: [$line_num] of VCF ",
		  "file [$inputFile].  Skipping line.",
		  {DETAIL => "Sample names in the column header are " .
		   "used to identify sample columns for use with the -s " .
		   "and -d parameters, and to find the number of " .
		   "supporting read and total reads for each record.  " .
		   "If your column header line is malformed, but the " .
		   "data is there and you do not supply -s or -d, you " .
		   "will still be able to proceed using the default " .
		   "FORMAT column number [",($format_index + 1),"] and " .
		   "sample column start number [",
		   ($sample_name_start_index + 1),"]."});

	    next;
	  }

	$data_line++;

	my $format_str = $cols[$format_index];
	my(@data)      = @cols[$sample_name_start_index..$#cols];

	debug("FORMAT string for data record [$data_line]: [$format_str].");

	#Determine the subindex of each piece of sample data based on the
	#FORMAT string by creating a hash
	my $format_subindex = 0;
	my $format_key_tosubindex = {};
	foreach my $key (split(/:/,$format_str,-1))
	  {$format_key_tosubindex->{$key} = $format_subindex++}

	my $mode = '';
	if(exists($format_key_tosubindex->{DP}) ||
	   exists($format_key_tosubindex->{AO}))
	  {
	    if(scalar(grep {exists($format_key_tosubindex->{$_})}
		      ('SU','PE','SR')))
	      {
		$mode = 'BOTH';
		if($global_mode ne 'SNP' && $global_mode ne 'MIXED' &&
		   $global_mode ne '' && $global_mode ne 'BOTH')
		  {$global_mode = 'MIXED'}
		else
		  {$global_mode = $mode}
	      }
	    else
	      {
		$mode = 'SNP';
		if($global_mode ne 'SNP' && $global_mode ne 'MIXED' &&
		   $global_mode ne '' && $global_mode ne 'BOTH')
		  {$global_mode = 'MIXED'}
		else
		  {$global_mode = $mode}
	      }
	  }
	elsif(scalar(grep {exists($format_key_tosubindex->{$_})}
		     ('SU','PE','SR')))
	  {
	    $mode = 'SV';
	    if($global_mode ne 'SV' && $global_mode ne 'MIXED' &&
	       $global_mode ne '' && $global_mode ne 'BOTH')
	      {$global_mode = 'MIXED'}
	    else
	      {$global_mode = $mode}
	  }
	else
	  {
	    error("Unable to determine variant type for record in line: ",
		  "[$line_num] of file: [$inputFile].  Skipping line.",
		  {DETAIL => ("The format string must have at least one of " .
			      "the following keys: [DP,AO,SU,PE,SR].")});
	    next;
	  }
	if($mode eq 'SNP' || $mode eq 'BOTH')
	  {
	    if(!exists($format_key_tosubindex->{DP}))
	      {
		error("The index of the read depth key [DP] could not be ",
		      "found in the FORMAT string in data record ",
		      "[$data_line] on line [$line_num] in file ",
		      "[$inputFile].  Skipping line.",
		      {DETAIL => ('The read depth per sample is required by ' .
				  '-m and -r for filtering and ranking.')});
		next;
	      }
	    elsif(!exists($format_key_tosubindex->{AO}))
	      {
		error("The index of the key for the number of read ",
		      "supporting the alternate genotype [AO] could not be ",
		      "found in the FORMAT string in data record ",
		      "[$data_line] on line [$line_num] in file ",
		      "[$inputFile].  Skipping line.",
		      {DETAIL => ('The alternate genotype read support per ' .
				  'sample is required by -m for filtering ' .
				  'and ranking.')});
		next;
	      }
	  }
	if($mode eq 'SV' || $mode eq 'BOTH')
	  {
	    if(!exists($format_key_tosubindex->{SU}))
	      {
		error("The index of the supporting evidence key [SU] could ",
		      "not be found in the FORMAT string in data record ",
		      "[$data_line] on line [$line_num] in file ",
		      "[$inputFile].  Skipping line.",
		      {DETAIL => ('The supporting evidence per sample is ' .
				  'required by -v for filtering and ' .
				  'ranking.')});
		next;
	      }
	    elsif(!exists($format_key_tosubindex->{PE}))
	      {
		error("The index of the key for the number of discordant ",
		      "read pairs supporting a structural variant [PE] could ",
		      "not be found in the FORMAT string in data record ",
		      "[$data_line] on line [$line_num] in file ",
		      "[$inputFile].  Skipping line.",
		      {DETAIL => ('The structural variant read pair support ' .
				  'per sample is required by -p for ' .
				  'filtering and ranking.')});
		next;
	      }
	    elsif(!exists($format_key_tosubindex->{SR}))
	      {
		error("The index of the key for the number of split reads ",
		      "supporting a structural variant [SR] could not be ",
		      "found in the FORMAT string in data record ",
		      "[$data_line] on line [$line_num] in file ",
		      "[$inputFile].  Skipping line.",
		      {DETAIL => ('The structural variant split read ' .
				  'support per sample is required by -c for ' .
				  'filtering and ranking.')});
		next;
	      }
	  }

	my $got    = 0;
	my $depths = {};
	my @hits   = ();
	my @rats   = ();
	my @filts  = ();

	foreach my $format_subindex (0..$#samples)
	  {
	    #If there is no data for this sample (i.e. no reads mapped over the
	    #position of this variant)
	    if($data[$format_subindex] eq '.')
	      {
		#Create a bogus record so that DP and AO (or SU, PE, and SR)
		#can be set to 0
		$data[$format_subindex] =
		  "0:"x(scalar(keys(%$format_key_tosubindex)));
		chop($data[$format_subindex]);
	      }

	    #Get the sample name for this sample column
	    my $sample = $samples[$format_subindex];

	    #Get the data specific to this sample
	    my @d = split(/:/,$data[$format_subindex],-1);

	    debug("Data for sample [$sample]: [",join(':',@d),"].");

	    if($mode eq 'BOTH')
	      {
		#Sometimes there are multiple alternate variants that are comma
		#delimited.  We will consider the one with the most support
		#because all we're doing is seeing if anything marks this
		#sample as a hit
		my $ao = max(split(/,/,$d[$format_key_tosubindex->{AO}]));
		my $su = max(split(/,/,$d[$format_key_tosubindex->{SU}]));
		my $sr = max(split(/,/,$d[$format_key_tosubindex->{SR}]));
		my $pe = max(split(/,/,$d[$format_key_tosubindex->{PE}]));

		#Record how many samples had adequate depth of coverage
		$depths->{$sample}++
		  if($d[$format_key_tosubindex->{DP}] >= $min_read_depth);

		#If the depth is adequate, greater than 0, and support for the
		#alternate allele is adequate
		if($su >= $min_svs      &&
		   $pe >= $min_discords &&
		   $sr >= $min_splits   &&
		   $d[$format_key_tosubindex->{DP}] >= $min_read_depth &&
		   $d[$format_key_tosubindex->{DP}] > 0 &&
		   ($ao / $d[$format_key_tosubindex->{DP}]) >=
		   $min_support_ratio)
		  {
		    $got++;

		    #Record the ratios of alt allele support over total reads
		    push(@rats,"$ao/$d[$format_key_tosubindex->{DP}]");

		    #Record the sample name that was a hit
		    push(@hits,$samples[$format_subindex]);
		  }
	      }
	    elsif($mode eq 'SNP')
	      {
		#Sometimes there are multiple alternate variants that are comma
		#delimited.  We will consider the one with the most support
		#because all we're doing is seeing if anything marks this
		#sample as a hit
		my $ao = max(split(/,/,$d[$format_key_tosubindex->{AO}]));

		#Record how many samples had adequate depth of coverage
		$depths->{$sample}++
		  if($d[$format_key_tosubindex->{DP}] >= $min_read_depth);

		#If the depth is adequate, greater than 0, and support for the
		#alternate allele is adequate
		if($d[$format_key_tosubindex->{DP}] >= $min_read_depth &&
		   $d[$format_key_tosubindex->{DP}] > 0 &&
		   ($ao / $d[$format_key_tosubindex->{DP}]) >=
		   $min_support_ratio)
		  {
		    $got++;

		    #Record the ratios of alt allele support over total reads
		    push(@rats,"$ao/$d[$format_key_tosubindex->{DP}]");

		    #Record the sample name that was a hit
		    push(@hits,$samples[$format_subindex]);
		  }
	      }
	    else #Mode is SV
	      {
		#Sometimes there are multiple alternate variants that are comma
		#delimited.  We will consider the one with the most support
		#because all we're doing is seeing if anything marks this
		#sample as a hit
		my $su = max(split(/,/,$d[$format_key_tosubindex->{SU}]));
		my $sr = max(split(/,/,$d[$format_key_tosubindex->{SR}]));
		my $pe = max(split(/,/,$d[$format_key_tosubindex->{PE}]));

		if($su >= $min_svs      &&
		   $pe >= $min_discords &&
		   $sr >= $min_splits)
		  {
		    $got++;

		    #Record the discrete filters that were passed which were >0
		    push(@filts,'' .
			 ($min_svs > ($min_discords + $min_splits) ?
			  'SU' . $su : '') .
			 ($min_svs > ($min_discords + $min_splits) &&
			  ($min_discords > 0 || $min_splits > 0) ? '/' : '') .
			 ($min_discords > 0 ? 'PE' . $pe : '') .
			 ($min_discords > 0 && $min_splits > 0 ? '/' : '') .
			 ($min_splits   > 0 ? 'SR' . $sr : ''));

		    #Record the sample name that was a hit
		    push(@hits,$samples[$format_subindex]);
		  }
	      }
	  }

	my $anything_passed = 0;
	my $pass_str = "$got,HITS>0,HITS<" . scalar(@samples) .
	  ($global_mode eq 'SV' ?
	   '' : ",SNP/DEP>=$min_support_ratio,DEP>=$min_read_depth") .
	     ($global_mode eq 'SNP' ?
	      '' : ",SE>=$min_svs,PE>=$min_discords,SR>=$min_splits");
	if(scalar(@$sample_groups))
	  {
	    my $group_pair_rule = 0;
	    foreach my $pair_index (grep {$_ % 2 == 0} (0..$#{$sample_groups}))
	      {
		$group_pair_rule++;
		my @set1     = @{$sample_groups->[$pair_index]};
		my $set1_min = $group_diff_mins->[$pair_index];
		my @set2     = @{$sample_groups->[$pair_index + 1]};
		my $set2_min = $group_diff_mins->[$pair_index + 1];

		debug("$_\nSET1: [@set1] SET1MIN: $set1_min ",
		      "SET2: [@set2] SET2MIN: $set2_min");

		#If we got something, not all samples were hits, and either:
		# - The first sample group was a hit for the alternate allele
		#   and the second sample group was not OR
		# - The first sample group was not a hit for the alternate
		#   allele and the second sample group was
		if($got > 0 && $got < scalar(@samples) &&
		   ((scalar(grep {my $u=$_;scalar(grep {$_ eq $u} @set1)}
			    @hits) >= $set1_min &&
		     scalar(grep {my $u=$_;scalar(grep {$_ eq $u} @set2)}
			    grep {$mode eq 'SV' || exists($depths->{$_})}
			    @hits) < $set2_min &&
		     scalar(grep {$mode eq 'SV' || exists($depths->{$_})}
			    @set2) >= $set2_min) ||
		    (scalar(grep {my $u=$_;scalar(grep {$_ eq $u} @set1)}
			    grep {$mode eq 'SV' ||exists($depths->{$_})}
			    @hits) < $set1_min &&
		     scalar(grep {$mode eq 'SV' ||
				    exists($depths->{$_})} @set1) >=
		     $set1_min &&
		     scalar(grep {my $u=$_;scalar(grep {$_ eq $u} @set2)}
			    @hits) >= $set2_min)))
		  {
		    debug("PASSED POS1/NEG2: [",
			  scalar(grep {my $u=$_;scalar(grep {$_ eq $u} @set1)}
				 @hits),'/',
			  scalar(grep {my $u=$_;scalar(grep {$_ eq $u} @set2)}
				 grep {$mode eq 'SV' || exists($depths->{$_})}
				 @hits),
			  "] NEG1/POS2: [",
			  scalar(grep {my $u=$_;scalar(grep {$_ eq $u} @set1)}
				 grep {$mode eq 'SV' || exists($depths->{$_})}
				 @hits),'/',
			  scalar(grep {my $u=$_;scalar(grep {$_ eq $u} @set2)}
				 @hits),"]");
		    $anything_passed++;
		    $pass_str .= ",GROUPRULEPAIR$group_pair_rule\[SET(" .
		      join(',',@set1) . ")>=$set1_min DIFFERS FROM SET(" .
		      join(',',@set2) . ")>=$set2_min]";
		  }
		else
		  {debug("FAILED")}
	      }
	  }
	elsif($got > 0 && $got < scalar(@samples))
	  {$anything_passed++}

	if($anything_passed)
	  {push(@passed,
		join('',
		     ("$pass_str\t",
		      join(',',($mode ne 'SV' ? @rats : @filts)),"\t",
		      join(',',@hits),"\t$_")))}
      }

    closeIn(*IN);

    openOut(*OUT,$outputFile);
    print(join("\n",rank(\@passed)),"\n");
    closeOut(*OUT);
  }


sub rank
  {
    my @lines = @{$_[0]};
    return(sort
	   {
	     #If we can parse the number of hits, the allelic support over
	     #total read ratio, and the sample names that passed the filtering
	     if($a=~/^(\d+)[^\t]+\t([^\t]+)\t([^\t]+)/)
	       {
		 my $ah       = $1; #number of 'a' hits
		 my $arats    = $2; #Comma delimited 'a' string of either SNP
                                    #support ratios or SV evidence, depending
                                    #on record type
		 my $asamps   = $3; #Comma delimited 'a' sample names
		 my @anums    = split(/,/,$arats);
		 my $amode    = ($arats =~ /SU|SR|PE/ ? 'SV' :
				 ($arats =~ /\d+\/\d+/ ? 'SNP' :
				  ($arats eq '' ? 'SNP' : 'ERROR')));

		 #SNP metrics
		 my $anumsum  = 0;  #Support ratio numerator sum
		 my $adensum  = 0;  #Support ratio denominator sum
		 my $asup     = 0;

		 #SV metric
		 my $asusup   = 0;
		 my $asrsup   = 0;
		 my $apesup   = 0;
		 my $abothsup = 0;

		 if($amode eq 'SNP')
		   {
		     foreach my $arat (@anums)
		       {
			 my($anum,$aden) = split(/\//,$arat);
			 $anumsum += $anum;
			 $adensum += $aden;
		       }
		     $asup = $anumsum / $adensum;
		   }
		 elsif($amode eq 'SV')
		   {
		     foreach my $arat (@anums)
		       {
			 my $asr = 0;
			 my $ape = 0;
			 if($arat =~ /SU(\d+)/)
			   {$asusup += $1}
			 if($arat =~ /SR(\d+)/)
			   {$asr = $1}
			 if($arat =~ /PE(\d+)/)
			   {$ape += $1}
			 if($asr && $ape)
			   {$abothsup += $asr + $ape}
			 $asrsup += $asr;
			 $apesup += $ape;
		       }
		   }
		 else
		   {
		     error("Unable to parse variant metrics.",
			   {DETAIL => ('Expecting a comma delimited list of ' .
				       'numeric fractions or coded read ' .
				       'counts (e.g. SU1/PE2/SR3) in the ' .
				       'second column.')});
		   }

		 if($b =~ /^(\d+)[^\t]+\t([^\t]+)\t([^\t]+)/)
		   {
		     my $bh       = $1; #number of 'b' hits
		     my $brats    = $2; #Comma delimited 'b' ratios string
		     my $bsamps   = $3; #Comma delimited 'b' sample names
		     my @bnums    = split(/,/,$brats);
		     my $bmode    = ($brats =~ /SU|SR|PE/ ? 'SV' :
				     ($brats =~ /\d+\/\d+/ ? 'SNP' :
				      ($brats eq '' ? 'SNP' : 'ERROR')));

		     #SNP metrics
		     my $bnumsum  = 0;
		     my $bdensum  = 0;
		     my $bsup     = 0;

		     #SV metric
		     my $bsusup   = 0;
		     my $bsrsup   = 0;
		     my $bpesup   = 0;
		     my $bbothsup = 0;

		     if($bmode eq 'SNP')
		       {
			 foreach my $brat (@bnums)
			   {
			     my($bnum,$bden) = split(/\//,$brat);
			     $bnumsum += $bnum;
			     $bdensum += $bden;
			   }
			 $bsup = $bnumsum / $bdensum;
		       }
		     elsif($bmode eq 'SV')
		       {
			 foreach my $brat (@bnums)
			   {
			     my $bsr = 0;
			     my $bpe = 0;
			     if($brat =~ /SU(\d+)/)
			       {$bsusup += $1}
			     if($brat =~ /SR(\d+)/)
			       {$bsr = $1}
			     if($brat =~ /PE(\d+)/)
			       {$bpe += $1}
			     if($bsr && $bpe)
			       {$bbothsup += $bsr + $bpe}
			     $bsrsup += $bsr;
			     $bpesup += $bpe;
			   }
		       }
		     else
		       {
			 error("Unable to parse variant metrics.",
			       {DETAIL => ('Expecting a comma delimited ' .
					   'list of numeric fractions or ' .
					   'coded read counts (e.g. ' .
					   'SU1/PE2/SR3) in the second ' .
					   'column.')});
		       }

		     #This is the end result - logic for sorting
		     if($amode ne $bmode)
		       {
			 if($amode eq 'SV') #and bmode is SNP
			   {
			     #Sometimes SU isn't shown in the results (if the
			     #user specified a different value for the other
			     #cutoffs at the command line), but one or both of
			     #the splits or discordants will definitely be
			     #there.
			     my $bsvsup =
			       ($bsusup ? $bsusup : $bsrsup + $bpesup);

			     #Number of hits
			     $bh <=> $ah ||

			       #All support for the SV versus all support for
			       #the SNP
			       $bsvsup <=> $anumsum ||

				 #SV support from both discordants and splits
				 #or support from total, splits, or discordants
				 $bbothsup <=> $anumsum ||
				    $bsusup <=> $anumsum ||
				      $bsrsup <=> $anumsum ||
					$bpesup <=> $anumsum ||

					  #Or finally - sample name
					  $asamps cmp $bsamps;
			   }
			 else #amode is SNP and bmode is SV
			   {
			     #Sometimes SU isn't shown in the results (if the
			     #user specified a different value for the other
			     #cutoffs at the command line), but one or both of
			     #the splits or discordants will definitely be
			     #there.
			     my $asvsup =
			       ($asusup ? $asusup : $asrsup + $apesup);

			     #Number of hits
			     $bh <=> $ah ||

			       #All support for the SV versus all support for
			       #the SNP
			       $bnumsum <=> $asvsup ||

				 #SV support from both discordants and splits
				 #or support from total, splits, or discordants
				 $bnumsum <=> $abothsup ||
				    $bnumsum <=> $asusup ||
				      $bnumsum <=> $asrsup ||
					$bnumsum <=> $apesup ||

					  #Or finally - sample name
					  $asamps cmp $bsamps;
			   }
		       }
		     else
		       {
			 #Note - using both SNP and SV metrics here does not
			 #matter - the other type will be all 0s

			 #Number of hits
			 $bh <=> $ah ||

			   #SNP support ratios or depth
			   $bsup <=> $asup || $bdensum <=> $adensum ||

			     #SV support from both discordants and splits
			     #or support from total, splits, or discordants
			     $bbothsup <=> $abothsup || $bsusup <=> $asusup ||
			       $bsrsup <=> $asrsup || $bpesup <=> $apesup ||

				 #Or finally - sample name
				 $asamps cmp $bsamps;
		       }
		   }
		 else
		   {-1}
	       }
	     else
	       {-1}
	   } grep {/^\d/} @lines);
  }

sub max
  {
    my @vals = @_;
    return(undef) unless(scalar(@vals));
    my $max  = $vals[0];
    foreach my $val (@vals)
      {if(!defined($max) || $val > $max)
	 {$max = $val}}
    return($max);
  }
