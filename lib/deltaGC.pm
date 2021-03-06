package deltaGC;

use 5.006;
use strict;
use warnings;

=head1 NAME

deltaGC - scripts for running deltaGC.pl

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';


=head1 SYNOPSIS

=head1 EXPORT


=head1 SUBROUTINES/METHODS

=cut

use base 'Exporter';
our @EXPORT_OK = '';
use Carp qw/ confess carp /;
use Data::Dumper;
use Text::ParseWords;
use Bio::SeqIO;
use Math::Gauss ':all';
use Math::Random::SkewNormal qw/generate_sn/;
use Math::Random qw/
random_uniform_integer
random_uniform
random_normal
random_exponential
random_poisson
random_f/;


=head2 correct_fasta

Making sure sequence lines for each entry are the same length.

=cut

sub correct_fasta{
  my $genome_file = shift;

  (my $genome_out = $genome_file) =~ s/\.[^.]+$/_fix.fasta/;

  my $seqin = Bio::SeqIO->new(-file => $genome_file, -format => 'fasta');
  my $seqout = Bio::SeqIO->new(-file => ">$genome_out", -format => 'fasta');

  while(my $seq = $seqin->next_seq){
    $seqout->write_seq($seq);
  }

  print STDERR "Corrected genome file written: '$genome_out'\n";
  return $genome_out;
}

=head2 calc_GC

Calculating GC content for a string (DNA)

=head3 IN

1) dna_string 2) fraction of string length that are gaps (not [ATGC]i)

=cut

push @EXPORT_OK, 'calc_GC';

sub calc_GC {
# calculting GC of a sequence
  my ($seq, $gap_frac) = @_;

  confess "ERROR: no sequences provided for calculating GC!\n" 
    unless defined $seq;

  # length
  my $raw_len = length $seq;

  # removing gaps
  $seq =~ s/-+//g;
  my $len = length $seq;
  return ('NA',$len) if 1 - $len / $raw_len > $gap_frac; # if too many gaps in DNA

  # upcase
  $seq =~ tr/a-z/A-Z/;

  # scoring table (included ambiguous nucleotides)
  my %score = (G => 1,
	       C => 1,
	       R => 0.5,
	       Y => 0.5,
	       S => 1,
	       K => 0.5,
	       M => 0.5,
	       B => 0.66,
	       D => 0.33,
	       H => 0.33,
	       V => 0.66,
	       N => 0.5
	       );

  # GC
  my $q = join("", "[", keys %score, "]");
  $q = qr/$q/;
  my $GC_sum = 0;
  $GC_sum += $score{$1} while $seq =~ /($q)/g;
  my $GC_content = $GC_sum / $len * 100;

  return $GC_content, $len;
}


=head2 get_frag_GC

Creating fragments for each read & calculating GC on each.
Return (gather): a hash that replicates input hash along with frag_GC, frag_len, & frag_start

=cut

push @EXPORT_OK, 'get_frag_GC';

sub get_frag_GC{
# foreach read:
## determine random fragment size
## pull fragment from genome
### start-end around amplicon determine from a uniform distribution
## calculate fragment GC
## record GC & length
  use GC_dist qw/parse_desc/;
  use Text::ParseWords;

  my ($genome, $spec_ids_r,
      $genome_db, $read_db, 
      $amp_b,
      $size_dist, 
      $frag_min, $frag_max, 
      $mean, $stdev, 
      $skewness, $mu,
      $DFn, $DFd,
      $primer_buffer,
      $gap_frac) = @_;


  # sanity checks
  ## values provided
  map{ confess "ERROR: argument missing: $!\n" unless defined $_ } 
    ($size_dist, $frag_min, $frag_max, $mean, $stdev, $primer_buffer);

  # genome_info
  my $genome_len = $genome_db->length($genome);
  die "ERROR: cannot find '$genome' in genomes database\n"
    unless defined $genome_len;

  # processing each read
  my @ret;
  my $genome_name;
  foreach my $Uid (@$spec_ids_r){
    my $seqo = $read_db->get_Seq_by_id($Uid);
    my $desc = parse_desc($seqo->desc, $amp_b);
    my ($ref, $amp_start, $amp_end, $strand) = @$desc;
    my $amp_len = abs($amp_end - $amp_start) + 1;

    unless(defined $genome_name){
      my @l = grep(/description=/, quotewords('\s+', 0, $read_db->header($Uid)) );
      croak("ERROR: no 'description=' found for read '$Uid'\n")
	unless @l;
      map{ $genome_name = $1 if /description="*(.+)"*/ } $l[0];
    }

    # fragment size
    my $frag_size;
    my $time_out = 0;
    if($size_dist eq 'uniform'){
      while(1){
	$time_out++;
	die "ERROR for genome $genome: could not get sequence in length range within $time_out attempts\n"
	  if $time_out > 9999;
	$frag_size = random_uniform_integer(1, $frag_min, $frag_max); 
	last if $frag_size >= $frag_min && $frag_size <= $frag_max;
      }
    }
    elsif($size_dist eq 'normal'){
      while(1){
	$time_out++;
	die "ERROR for genome $genome: could not get sequence in length range within $time_out attempts\n"
	  if $time_out > 9999;
	#$frag_size = int random_normal(1, $mean, $stdev);
	$frag_size = int random_normal(1, $mean, $stdev);
	last if $frag_size >= $frag_min && $frag_size <= $frag_max;
      }
    }
    elsif($size_dist eq 'skewed-normal'){
      while(1){
	$time_out++;
	die "ERROR for genome $genome: could not get sequence in length range within $time_out attempts\n"
	  if $time_out > 9999;
	my $sk = generate_sn($skewness);    
	next if $sk == 0;
	$frag_size = $sk >= 0 ? $mean + ($frag_max-$mean) * sqrt($sk) : 
	  $mean - ($frag_max-$mean) * sqrt(abs($sk));
	last if $frag_size >= $frag_min && $frag_size <= $frag_max;
      }
    }
    elsif($size_dist eq 'exponential'){
      while(1){
	$time_out++;
	die "ERROR for genome $genome: could not get sequence in length range within $time_out attempts\n"
	  if $time_out > 9999;
	$frag_size = int random_exponential(1, $mean);
	last if $frag_size >= $frag_min && $frag_size <= $frag_max;
      }
    }
    elsif($size_dist eq 'poisson'){
      while(1){
	$time_out++;
	die "ERROR for genome $genome: could not get sequence in length range within $time_out attempts\n"
	  if $time_out > 9999;
	$frag_size = int random_poisson(1, $mu);
	last if $frag_size >= $frag_min && $frag_size <= $frag_max;
      }
    }
    elsif($size_dist eq 'f'){
      while(1){
	$time_out++;
	die "ERROR for genome $genome: could not get sequence in length range within $time_out attempts\n"
	  if $time_out > 9999;
	$frag_size = random_f(1, $DFn, $DFd);  # scaling by 5; values >5 will be excluded
	$frag_size = $frag_size == 0 ? 0 : $frag_size / 5;
	$frag_size = $frag_size <= 1 ? 1 - $frag_size : next;
	$frag_size = int($frag_size * ($frag_max - $frag_min));
	$frag_size = $frag_min if $frag_size == 0;
	last if $frag_size >= $frag_min && $frag_size <= $frag_max;
      }
    }
    else{ confess "ERROR: do not recognize size distribution\n"; }

    ### sanity check: frag_size > amp_len
    if($amp_len > $frag_size){
      warn "WARNING for $genome -> $Uid: read_len:$amp_len > fragment_length:$frag_size. Skipping!\n";
      next;
    }	
    
    # determine fragment start-end based on amplicon start-end
    ## amplicon center postion
    my $amp_center = int($amp_start + abs($amp_len * 0.5));
    ## fragment_start = amp_center - (frag_size * x); x = random draw from unifrom distribution 0:1
    my $x = random_uniform();
    ### frag_start_floor = (primer_buffer + 0.5*amp_len) / frag_size
    my $floor  = ($primer_buffer + 0.5 * $amp_len) / $frag_size; 
    $x = $floor if $x < $floor;
    ##$ frag_start_ceiling = 1 - floor
    my $ceiling = 1 - $floor;                               # ceiling = 1 - floor
    $x = $ceiling if $x > $ceiling;
    my $frag_start = int( $amp_center - ($frag_size * $x) );

    ### sanity check: fragment start within range of amplicon
    carp "WARNING for genome '$genome': frag_start is too far from amplicon!\n\tfrag_start:", 
      " $frag_start, amp_start: $amp_start, amp_end: $amp_end, primer_buffer: $primer_buffer,",
      " frag_size: $frag_size, amp_center: $amp_center, x: $x\n"
      if $frag_start - ($amp_end + $primer_buffer) > $frag_size;

    # getting fragment
    ## fragment start-end can span ends of genome (assuming circular genome)
    ## need to account for this; making an %@ of 1-3 start-end positions
    my %pos;
    ### left wrap
    if($frag_start < 0){
      $pos{left_wrap} = [$genome_len + $frag_start + 1, $genome_len];
      $pos{middle} = [1, $frag_size + $frag_start];
    }
    if(! exists $pos{middle}){
      $pos{middle} = [$frag_start, $frag_start + $frag_size -1 ];
    }
    if($frag_start + $frag_size -1 > $genome_len){
      $pos{right_wrap} = [1, $frag_start + $frag_size -1 - $genome_len];
      ${$pos{middle}}[1] = [$genome_len];
    }
    
    ### getting sequence
    my $frag_seq = "";
    map{ $frag_seq .= $genome_db->seq($genome, ${$pos{$_}}[0], ${$pos{$_}}[1]) } keys %pos; 
    
    ### sanity check: fragment is encompassing read
    my ($frag_start_chk, $frag_end_chk) = ($frag_start, $frag_start + length($frag_seq));
    $frag_start_chk = 0 if $frag_start_chk < 0;
    $frag_end_chk = $genome_len if $frag_end_chk > $genome_len;
    if($frag_start_chk > $amp_start or $frag_end_chk < $amp_end){ # fragment must encompass the amplicon
      warn "WARNING for genome $genome: fragment does not encompass the read (frag_start=$frag_start_chk, frag_end=$frag_end_chk, amp_start=$amp_start, amp_end=$amp_end). Skipping\n";
	next;
    }

    # calculating fragment GC
    my ($frag_GC, $frag_length) = calc_GC( $frag_seq, $gap_frac );

    # calculating fragment buoyant density    
    my $frag_dens = $frag_GC =~ /^[\d.]+$/ ?
      ($frag_GC * 0.098 / 100) + 1.660 : 'NA';

    # calculating amplicon GC
    my ($amp_GC, $amp_length) = calc_GC($seqo->seq, $gap_frac);

    # calculating amplicon buoyant density
    my $amp_dens = $amp_GC =~ /^[\d.]+$/ ?
      ($amp_GC * 0.098 / 100) + 1.660 : 'NA';

    # writing output
    push @ret, [$genome_name, #<-- from 'description='    #$genome_db->header($genome),
	       $genome,
	       $Uid,
	       $amp_GC,
	       $amp_dens,
	       $amp_start,
	       $amp_length,
	       $frag_GC,
	       $frag_dens,
	       $frag_start,
	       $frag_length]; #, "\n";
  }

  return \@ret;
}


=head1 skew

Skewing values from a normal distribution

=head2 Input

x (value), e (location), w (scale), a (alpha)

=head2 Output 

value

=cut

sub skew{
  my ($x, # value (from a normal distribution)
      $e, # location
      $w, # scale
      $a  # skewness
     ) = @_;
  my $t = ($x - $e) / $w;
  return 2 / $w * pdf($t) * cdf($a * $t);
}



=head write_read_info

Writing out all read info if wanted.
For debugging.

=cut

push @EXPORT_OK, 'write_read_info';

sub write_read_info{
  my ($reads_r, $db) = @_;
  
  # output file
#  open OUT, ">$outfile" or die $!;

  # header
  print join("\t", qw/genome scaffold read_ID read_GC 
			 read_length read_start 
			 frag_GC frag_length frag_start/), "\n";

  # body
  foreach my $genome (keys %$reads_r){
    (my $desc = $db->header($genome)) =~ s/^[^ ]+ //;
    foreach my $Uid (keys %{$reads_r->{$genome}}){
      print join("\t",
		     #$reads_r->{$genome}{$Uid}{desc},
		     $desc,
		     $genome, 
		     $Uid, 
		     $reads_r->{$genome}{$Uid}{amp_GC},
		     $reads_r->{$genome}{$Uid}{amp_len},
		     $reads_r->{$genome}{$Uid}{amp_start},		     
		     $reads_r->{$genome}{$Uid}{frag_GC},
		     $reads_r->{$genome}{$Uid}{frag_len},
		     $reads_r->{$genome}{$Uid}{frag_start}
		    ), "\n";
    }
  }

  #close OUT or die $!;
  #print STDERR "Read info file written to: '$outfile'\n";
}


=head1 get_genome_GC_stats

Calculating GC stats per genome. 
Foreach read: 
   calculate GC diff beteween amplicon & fragment
   load into stat object
calculate stats
load stats into return hash

=cut

push @EXPORT_OK, 'get_genome_GC_stats';

sub get_genome_GC_stats{

  my $genome = $_;
  my ($self) = @_;
  my $reads_r = $self->user_args->{reads_r};

  my %stats;
  my $genome_id;
  my $genome_stat = new Statistics::PointEstimation;
  foreach my $Uid (keys %{$reads_r->{$genome}}){

    $genome_id = join("|", $reads_r->{$genome}{$Uid}{desc}, $genome)
      unless defined $genome_id;
    
    # loading deltaGC of frag & read(amplicon)
    my $deltaGC = abs($reads_r->{$genome}{$Uid}{amp_GC} - 
			$reads_r->{$genome}{$Uid}{frag_GC});
    $genome_stat->add_data($deltaGC);
  }

  # calculting genome stats
  $stats{mean} = $genome_stat->mean();
  $stats{variance} = $genome_stat->variance();
  $stats{df} = $genome_stat->df();
  $genome_stat->set_significance(95);
  $stats{upper_clm_95} = $genome_stat->upper_clm();
  $genome_stat->set_significance(99);
  $stats{upper_clm_99} = $genome_stat->upper_clm();

  MCE->gather($genome_id, \%stats);
}


=head1 get_total_GC_stats

Calculating GC stats for all genomes combined.
Same as get_genome_GC_stats, but reads from all
genomes are combining. 

=cut

push @EXPORT_OK, 'get_total_GC_stats';

sub get_total_GC_stats{
  my ($reads_r, $stats_r) = @_;

  my $total_stat = new Statistics::PointEstimation;
  foreach my $genome (keys %$reads_r){
    foreach my $Uid (keys %{$reads_r->{$genome}}){

      # loading deltaGC of frag & read(amplicon)
      my $deltaGC = abs($reads_r->{$genome}{$Uid}{amp_GC} - 
			$reads_r->{$genome}{$Uid}{frag_GC});
      $total_stat->add_data($deltaGC);
    }
  }
  
  # total 
  $stats_r->{TOTAL}{mean} = $total_stat->mean();
  $stats_r->{TOTAL}{variance} = $total_stat->variance();
  $stats_r->{TOTAL}{df} = $total_stat->df();
  $total_stat->set_significance(95);
  $stats_r->{TOTAL}{upper_clm_95} = $total_stat->upper_clm();
  $total_stat->set_significance(99);
  $stats_r->{TOTAL}{upper_clm_99} = $total_stat->upper_clm();
  
  #print Dumper $stats_r;  exit;
}

=head2 write_stats_summary

Writing a summary table to STDOUT

Using %stats produced by sub get_GC_stats

=cut

push @EXPORT_OK, 'write_stats_summary';

sub write_stats_summary{
  my ($stats_r) = @_;

  foreach my $genome ( sort{ 
    if($a eq 'TOTAL'){ return -1; }
    elsif($b eq 'TOTAL'){ return 1; }
    else{ return $a cmp $b }
    } keys %$stats_r ){
    
    print join("\t", $genome,
	       $stats_r->{$genome}{mean},
	       $stats_r->{$genome}{variance},
	       $stats_r->{$genome}{df},
	       $stats_r->{$genome}{upper_clm_95},
	       $stats_r->{$genome}{upper_clm_99}
	       ), "\n";
  }

}





=head1 AUTHOR

Nick Youngblut, C<< <ndy2 at cornell.edu> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-deltaGC at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=deltaGC>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.




=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc deltaGC


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=deltaGC>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/deltaGC>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/deltaGC>

=item * Search CPAN

L<http://search.cpan.org/dist/deltaGC/>

=back


=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2014 Nick Youngblut.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.


=cut

1; # End of deltaGC
