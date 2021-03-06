#!/usr/bin/env perl
use strict;
use warnings;

=pod

=head1 NAME

GC_dist.pl -- sliding window of GC around each grinder-produced read

=head1 VERSION

This is version 0.0.1

=head1 USAGE

    GC_dist.pl [options] > GC_byWindow.txt

=head1 REQUIRED ARGUMENTS

=over

=item -r[eads] <read_file>

Reads output by grinder

=for Euclid:
read_file.type: readable

=item -g[enomes] <genome_file>

Fasta file of genomes used as '-reference_file' in grinder

=for Euclid:
genome_file.type: readable

=back

=head1 OPTIONS

=over

=item -a[mplicon]

Amplicon reads instead of shotgun metagenome reads? [FALSE]

=item -s[ize] <frag_size>

Fragment size (bp) around the read (total length assessed).

Default: frag_size.default

=for Euclid:
frag_size.type: int >0
frag_size.default: 20000

=item -w[indow] <window_size>

Size (bp) of sliding window around read.

Default: window_size.default

=for Euclid:
window_size.type: int > 0
window_size.default: 500

=item -j[ump] <jump_size>

Size (bp) for sliding window jump around read.

Default: jump_size.default

=for Euclid:
jump_size.type: int >0
jump_size.default: 100

=item -gap[_fraction] <gap_frac>

Fraction of DNA segment that can be composed of gaps ('-').
GC_content = 'NA' if cutoff not met.

Default: gap_frac.default

=for Euclid:
gap_frac.type: num >= 0
gap_frac.default: 0.05

=item -c_g[enomes]

Write out new version of the genome fasta file where all sequence
lines except the last are the same length for each entry? [FALSE]

=item -c_r[eads]

Write out new version of the read fasta file where all sequence
lines except the last are the same length for each entry? [FALSE]

=item -t[hreads] <threads>

Number of threads to use for GC calculations.

Default: threads.default

=for Euclid:
threads.type: 0+int
threads.default: 1

=item -i[ndex]

Force the genome & read database files (*.index) to be rebuilt 
(not needed if database exists)? [TRUE]

=item --debug [<log_level>]

Set the log level. Default is log_level.default but if you provide --debug,
then it is log_level.opt_default.

=for Euclid:
    log_level.type:        int
    log_level.default:     0
    log_level.opt_default: 1

=item --quiet

=item --version

=item --usage

=item --help

=item --man

Print the usual program information

=back

=head1 DESCRIPTION

Determine how GC is distributed around
each read produced by grinder.

This is an exploratory program to 
help understand values produced by deltaGC.

Postion is given by the midpoint of the window.
Edge cases are skipped.

The output table can be easily plotted in R
using ggplot.

Ambiguous IUPAC nucleotide codes will be included
in GC calculations based the the fraction of 'G' & 'C'
in the ambiguous character. See 'Warnings' about 'N'characters.

=head2 Warnings

If 'N' characters signify gaps, remove them from the
genome/read fasta files!

Delete the genome and read DB file (*index files)
if the script is killed before the DB construction
is completed, otherwise a partial database will be used.

=head1 EXAMPLES

=head1 AUTHOR

Nick Youngblut (ndy2@cornell.edu)

=head1 BUGS

There are undoubtedly serious bugs lurking somewhere in this code.
Bug reports and other feedback are most welcome.

=head1 COPYRIGHT

Copyright 2010, 2011
This software is licensed under the terms of the GPLv3

=cut

#--- modules ---#
use Data::Dumper;
use Getopt::Euclid;
use Bio::DB::Fasta;
use List::MoreUtils qw/each_array/;
use Parallel::ForkManager;
use Text::ParseWords;
use Devel::Size qw/total_size/;
use Memory::Usage;
use GC_dist qw/ 
correct_fasta
calc_frag_GC_window 
parse_desc
write_output/;


#--- I/O error ---#
if(defined $ARGV{'-index'}){  $ARGV{'-index'} = 0; } # don't force rebuilding of index
else{  $ARGV{'-index'} = 1; } # rebuild index

print STDERR "'-amplicon' not specified. Assuming shotgun reads, which affects how read position info is parsed\n"
  unless $ARGV{'-amplicon'};

#--- MAIN ---#
# memory
my $mu = Memory::Usage->new();
$mu->record('Starting memory') if $ARGV{'--debug'};

# genome fasta loading
## correcting genome fasta if needed
if( $ARGV{-c_genomes} ){
  print STDERR "Correcting any line length inconsistencies in the genome fasta\n";
  $ARGV{-genomes} = correct_fasta($ARGV{-genomes});
}

## make genome database
unless($ARGV{'--quiet'}){
  $ARGV{'-index'} == 1 ? print STDERR "Making genome database...\n" :
    print STDERR "Loading genome database...\n";
}

my $genome_db = Bio::DB::Fasta->new($ARGV{-genomes}, -reindex=>$ARGV{'-index'});
$mu->record('Genome db created') if $ARGV{'--debug'};


# load read info
##correcting reads if needed
if( $ARGV{-c_reads} ){
  print STDERR "Correcting any line length inconsistencies in the reads fasta\n";
  $ARGV{-reads} = correct_fasta($ARGV{-reads});
}

## make read database
print STDERR "Making read database...\n" unless $ARGV{'--quiet'};
sub make_my_id {
  my $desc = shift;
  $desc =~ /^>(\S+).*reference=(\S+)/;
  return join("__", $2, $1);
}
my $read_db = Bio::DB::Fasta->new($ARGV{-reads}, -makeid=>\&make_my_id, -reindex=>$ARGV{'-index'});
my @ids = $read_db->ids();

## getting read info
my @seq_obs = map{ $read_db->get_Seq_by_id($_) } @ids;
my @read_pos = map { parse_desc($_, $ARGV{-amplicon}) } map { $_->desc } @seq_obs; # read genome-start-end

## combining read info by genome
# genome => read_id => [start|end] => value
my $ea = each_array( @ids, @read_pos);
my %reads;
while( my ($x,$y) = $ea->()){
  $reads{$$y[0]}{$x} = [$$y[1], $$y[2], $$y[3]];
}
$mu->record('Created read hash') if $ARGV{'--debug'};
$mu->dump() if $ARGV{'--debug'};

## parsing genome fragments & calculating sliding window GC values
my $pm = Parallel::ForkManager->new($ARGV{-threads});
$pm->run_on_finish(
    sub {
      my ($pid, $exit_code, $ident, $exit_signal,
          $core_dump, $ret_r) = @_;
      write_output(@$ret_r); 
    }
  );

### forking 
print STDERR "Calculating GC content by window...\n";
print join("\t", qw/genome scaf readID read_num pos_local pos_global GC buoyant_density/), "\n";
foreach my $genome (keys %reads){
  print STDERR "Processing genome: $genome\n" if $ARGV{'--debug'};

  # forking & processing
  $pm->start and next;

  ## gc by window
  my $gc_r = calc_frag_GC_window($genome, $reads{$genome}, $genome_db->seq($genome), 
				 $ARGV{'-size'}, $ARGV{'-window'}, $ARGV{'-jump'},
				 $ARGV{'-gap_fraction'});

  $pm->finish( 0,[$gc_r, $genome_db->header($genome)] );
}
$pm->wait_all_children;

# debug
$mu->record('All children completed') if $ARGV{'--debug'};
$mu->dump() if $ARGV{'--debug'};

