package Phylosift::Benchmark;
use warnings;
use strict;
use Carp;
use Bio::Phylo;
use Phylosift::Summarize;
use Phylosift::Utilities;

=head1 SUBROUTINES/METHODS

=head2 benchmark_illumina

WARNING: The input file must have the correct format to run the benchmark
Reads the input file looking for taxonomic origins in the read headers and 
Reads Summary files and generates accuracy ratings for every taxonmic level.

=cut
my %nameidmap            = ();    # Key is an id - Value is a name (Use if you have an ID and want a name)
my %idnamemap            = ();    # Key is a name - Value is an id (Use if you have a name and want an ID)
my %sourceIDs            = ();
my %readSource           = ();
my %correctReadPlacement = ();
my %refTaxa              = ();

sub run_benchmark {
    my %args = @_;
    my $self        = $args{self} || miss("self");
    my $output_path = $args{output_path} || miss("output_path");
	my ($nimref, $inmref) = Phylosift::Summarize::read_ncbi_taxon_name_map();
	%nameidmap = %$nimref;
	%idnamemap  = %$inmref;
	print STDERR "parse_simulated_reads\n";
	my ($refTaxa_ref, $taxon_read_counts,$taxonomy_counts) = parse_simulated_reads( file_name=>$self->{"readsFile"} );
	%refTaxa = %$refTaxa_ref;
	my ($top_place,$all_place) = read_seq_summary( self=>$self, output_path=>$output_path,read_source=> \%readSource );
	
	$taxon_read_counts->{""}=0;	# define this to process all taxa at once
	foreach my $taxon(keys(%$taxon_read_counts)){
		$taxon = undef if $taxon eq "";
		my ($tp_prec, $read_count, $tp_rec) = compute_top_place_precision(self=>$self, top_place=>$top_place, target_taxon=>$taxon, true_taxon_counts=>$taxonomy_counts);
		my ($mass_prec, $mass_reads) = compute_mass_precision(self=>$self, all_place=>$all_place, target_taxon=>$taxon);
	
		$taxon = ".$taxon" if defined($taxon);
		$taxon = "" unless defined($taxon);
		my $report_file    = $output_path . "/" . $self->{"readsFile"} . "$taxon.tophit.csv";
		report_csv( self=>$self, report_file=>$report_file, mtref=>$tp_prec, read_number=>$read_count );
		$report_file    = $output_path . "/" . $self->{"readsFile"} . "$taxon.tophit.recall.csv";
		report_csv( self=>$self, report_file=>$report_file, mtref=>$tp_rec, read_number=>1 );
	
		my $allmass_report_file    = $output_path . "/" . $self->{"readsFile"} . "$taxon.mass.csv";
		report_csv( self=>$self, report_file=>$allmass_report_file, mtref=>$mass_prec, read_number=>$mass_reads );
	}
}

=head2 read_seq_summary
Takes a Directory name for input
Reads the sequence_taxa.txt file and compares the read placements to their true source
prints the percentage of all reads that have the correct taxanomic ID
prints the percentage of all PLACED reads that have the correct taxonmic ID
=cut

sub read_seq_summary {
    my %args = @_;
    my $self        = $args{self} || miss("self");
	my $readSource  =$args{read_source} || miss("read_source");
	my $targetDir   = $self->{"fileDir"};
	my $FILE_IN = ps_open( $targetDir . "/sequence_taxa.txt" );
	my %topReadScore   = ();
	my %allPlacedScore = ();

	#reading and storing information from the sequence_taxa.txt file
	while (<$FILE_IN>) {
		next if $_ =~ /^#/;
		my ($read, $tid, $rank, $taxPlacement, $probability) = split(/\t/,$_);
		my @taxPlacementID = Phylosift::Summarize::get_taxon_info(taxon=>$tid);
					
		$read =~ s/\\.+//g;	# get rid of bioperl garbage

		#	    print "TaxPlacement : $2\t $taxPlacementID[0]\t\n";
		my @readAncestor = get_ancestor_array(tax_id=> $taxPlacementID[2] );

		#	    print $read." $taxPlacementID[1]\t$taxPlacementID[2]:\t@readAncestor\n";
		$rank = $taxPlacementID[1];

		#keep only the top hits for all ranks for each Read
		my @array = ( $probability, $taxPlacementID[2], scalar(@readAncestor) );
		if ( !exists $topReadScore{$read} || $topReadScore{$read}->[0] < $probability ) {
			$topReadScore{$read} = \@array;
		}
		$allPlacedScore{$read}{$taxPlacement} = \@array;
	}
	close($FILE_IN);
	
	return (\%topReadScore, \%allPlacedScore);
}
# precision: TP / (TP+FP)
# recall: TP / (TP+FN)
sub compute_top_place_precision {
    my %args = @_;
    my $self        = $args{self} || miss("self");
    my $thref = $args{top_place} || miss("top_place");    
    my $true_counts = $args{true_taxon_counts};
    my $target_taxon = $args{target_taxon};
    my %topReadScore = %$thref;
    my %recall;
    	
	my %matchTop = ();
	init_taxonomy_levels( ncbi_hash => \%matchTop );
	my $all_positive = 0;
	foreach my $readID ( keys %topReadScore ) {
		#look at each taxonomic level for each read
		my $true_taxon    = $readSource{$readID};
		# only evaluate this read if it came from the target organism
		next if(defined($target_taxon) && $true_taxon ne $target_taxon);
		$all_positive++;

#		print "Read $readID first tax is $topReadScore{$readID}->[1]\n";
		my @ancArrayRead = get_ancestor_array( tax_id=>$topReadScore{$readID}->[1] );
		next unless @ancArrayRead > 0;
		next unless defined($ancArrayRead[0]);
		my @tt           = Phylosift::Summarize::get_taxon_info(taxon=>$true_taxon);
		my @firstTaxon   = Phylosift::Summarize::get_taxon_info( taxon=>$ancArrayRead[0] );
#		print "Read $readID assigned to $firstTaxon[0], true $tt[0]\n";
		foreach my $id (@ancArrayRead) {
			if ( exists $refTaxa{$true_taxon}{$id} ) {
				my @currTaxon = Phylosift::Summarize::get_taxon_info(taxon=>$id);
				my $currRank  = $currTaxon[1];
				$matchTop{$currRank} = 0 unless exists( $matchTop{$currRank} );
				$matchTop{$currRank}++;
				if(defined($target_taxon)){
					$recall{$currRank}=$matchTop{$currRank} / $true_counts->{$true_taxon}{$currRank};
				}else{
					$recall{$currRank}=$matchTop{$currRank} / $true_counts->{""}{$currRank};
				}
			}
		}
	}
	return (\%matchTop, $all_positive, \%recall);
}

sub compute_mass_precision {	
    my %args = @_;
    my $self        = $args{self} || miss("self");
    my $apref = $args{all_place} || miss("all_place");    
    my $target_taxon = $args{target_taxon};
    my %allPlacedScore = %$apref;

	my $allReadNumber = 0;
	my $totalProb     = 0;
	my %rankTotalProb = ();
	my %matchAll      = ();
	init_taxonomy_levels( ncbi_hash => \%matchAll );
	init_taxonomy_levels( ncbi_hash => \%rankTotalProb, initial_value => 0.0000000000000001 );    # avoid divide by zero

	foreach my $readID ( keys %allPlacedScore ) {
		my $true_taxon    = $readSource{$readID};
		# only evaluate this read if it came from the target organism
		next if(defined($target_taxon) && $true_taxon ne $target_taxon);
		$allReadNumber++;
		foreach my $tax ( keys %{ $allPlacedScore{$readID} } ) {
			my @ancArrayRead = get_ancestor_array( tax_id=>$allPlacedScore{$readID}{$tax}->[1] );
			pop(@ancArrayRead);
			push( @ancArrayRead, $allPlacedScore{$readID}{$tax}->[1] );
			foreach my $id (@ancArrayRead) {
				my @currTaxon = Phylosift::Summarize::get_taxon_info(taxon=>$id);
				my $currRank  = $currTaxon[1];
				next unless defined($currRank); # could be a taxon missing from the NCBI database.

				if ( exists $sourceIDs{$id} ) {
					if ( exists $matchAll{$currRank} ) {
						$matchAll{$currRank} += $allPlacedScore{$readID}{$tax}->[0];
					} else {
						$matchAll{$currRank} = $allPlacedScore{$readID}{$tax}->[0];
					}
				}
				if ( exists $rankTotalProb{$currRank} ) {
					$rankTotalProb{$currRank} += $allPlacedScore{$readID}{$tax}->[0];
				} else {
					$rankTotalProb{$currRank} = $allPlacedScore{$readID}{$tax}->[0];
				}
				$totalProb += $allPlacedScore{$readID}{$tax}->[0];
			}
		}
	}
	return (\%matchAll, $allReadNumber);
}

#    foreach my $m (keys %matchTop){
#	next if $m eq "no rank";
#print "Match : $m\t".$match{$m}/$readNumber."\n";
#	print "Top placed Matches : $m\t".$matchTop{$m}."\n";
#}
sub init_taxonomy_levels {
    my %args = @_;
	my $ncbihash = $args{ncbi_hash} || miss("ncbi_hash");
	my $initval  = $args{initial_value};
	$initval = 0 unless defined $initval;
	$ncbihash->{"superkingdom"} = $initval;
	$ncbihash->{"phylum"}       = $initval;
	$ncbihash->{"subphylum"}    = $initval;
	$ncbihash->{"class"}        = $initval;
	$ncbihash->{"order"}        = $initval;
	$ncbihash->{"family"}       = $initval;
	$ncbihash->{"genus"}        = $initval;
	$ncbihash->{"species"}      = $initval;
	$ncbihash->{"subspecies"}   = $initval;
	$ncbihash->{"no rank"}      = $initval;
}


sub report_timing {
    my %args = @_;
	my $self        = $args{self} || miss("self");
	my $data        = $args{data} || miss("data");
	my $output_path = $args{output_path} || miss("output_path");
	my $timing_file = $output_path . "/timing.csv";
	unless ( -f $timing_file ) {
		my $TIMING = ps_open( ">$timing_file" );
		print $TIMING "Date," . join( ",", keys(%$data) ) . "\n";
		close $TIMING;
	}
	my $TIMING = ps_open( ">>$timing_file" );
	print $TIMING Phylosift::Utilities::get_date_YYYYMMDD;
	foreach my $time ( keys(%$data) ) {
		print $TIMING "," . $data->{$time};
	}
	print $TIMING "\n";
}

sub as_percent {
    my %args = @_;
	my $num   = $args{num};
	my $denom =$args{denom};
	if ( defined $num && defined $denom && $denom > 0 ) {
		my $pretty = sprintf( "%.4f", 100 * $num / $denom );
		return $pretty;
	}
	return "";
}

sub report_csv {
    my %args = @_;
	my $self          = $args{self} || miss("self");
	my $report_file   = $args{report_file} || miss("report_file");
	my $mtref         = $args{mtref} || miss("mtref");
	my $readNumber    = $args{read_number};
	my %matchTop      = %$mtref;

	unless ( -f $report_file ) {
		my $TOPHITS = ps_open( ">$report_file" );
		print $TOPHITS "Date,Superkingdom,Phylum,Subphylum,Class,Order,Family,Genus,Species,Subspecies\n";
		close $TOPHITS;
	}
	my $date = Phylosift::Utilities::get_date_YYYYMMDD();

	# append an entry to the tophits file
	my $TOPHITS = ps_open(">>$report_file" );
	print $TOPHITS $date;
	print $TOPHITS "," . as_percent( num=>$matchTop{"superkingdom"}, denom=>$readNumber );
	print $TOPHITS "," . as_percent( num=>$matchTop{"phylum"},       denom=>$readNumber );
	print $TOPHITS "," . as_percent( num=>$matchTop{"subphylum"},    denom=>$readNumber );
	print $TOPHITS "," . as_percent( num=>$matchTop{"class"},        denom=>$readNumber );
	print $TOPHITS "," . as_percent( num=>$matchTop{"order"},        denom=>$readNumber );
	print $TOPHITS "," . as_percent( num=>$matchTop{"family"},       denom=>$readNumber );
	print $TOPHITS "," . as_percent( num=>$matchTop{"genus"},        denom=>$readNumber );
	print $TOPHITS "," . as_percent( num=>$matchTop{"species"},      denom=>$readNumber );
	print $TOPHITS "," . as_percent( num=>$matchTop{"subspecies"},   denom=>$readNumber );
	print $TOPHITS "\n";
}


=head2 parse_simulated_reads
Reads a fasta file extracting the source field for each read.
Compiles statistics on the input read abundance
Returns a hash of taxonomic ancestry for Source organisms

TODO : Determine which reads came from the marker gene regions from the source genomes

=cut

sub parse_simulated_reads {
    my %args = @_;
	my $file_name         = $args{file_name} || miss("file_name");
	my %sourceTaxa;
	my %sourceReadCounts;
	my %taxonomy_counts;
	my $FILE_IN = ps_open( $file_name );
	print STDERR "Opened $file_name\n";
	while (<$FILE_IN>) {
		my $read_id;
		my $taxon;
		if($_ =~  m/^>/){
	#		$_ =~ m/^>(\S+).*SOURCE_\d+="(.*)"/;  # for metasim header format
			$_ =~ m/^>(\S+).*reference=(\d+)/;  # grinder header format
			$read_id = $1;
			$taxon = $2;
		}elsif($_ =~  m/^@/){
			$_ =~ m/^@(\S+).*reference=(\d+)/;  # grinder header format	
			$read_id = $1;
			$taxon = $2;
		}else{
			next;
		}

		#push(@sourceTaxa,$1);
		$readSource{$read_id} = $taxon;
		my @ancestors = get_ancestor_array(tax_id=>$taxon);
		foreach my $id (@ancestors) {
			$sourceIDs{$id} = 1;
		}
		$sourceIDs{$taxon} = 1;
		$sourceReadCounts{$taxon} = 0 unless defined($sourceReadCounts{$taxon});
		$sourceReadCounts{$taxon}++;
		foreach my $id (@ancestors) {
			my @info = Phylosift::Summarize::get_taxon_info(taxon=>$id);
			$sourceTaxa{$taxon}{$id}=1;
			$taxonomy_counts{$taxon}{$info[1]} = 0 unless defined($taxonomy_counts{$taxon}{$info[1]});
			$taxonomy_counts{$taxon}{$info[1]}++;
			# "" is to store counts for all taxa
			$taxonomy_counts{""}{$info[1]} = 0 unless defined($taxonomy_counts{""}{$info[1]});
			$taxonomy_counts{""}{$info[1]}++;
		}
	}
	close($FILE_IN);

	print "total counts ".join(" ",keys(%{$taxonomy_counts{""}}))."\n";
	print "total counts ".join(" ",values(%{$taxonomy_counts{""}}))."\n";

	foreach my $source ( keys %sourceReadCounts ) {
		print $source . "\t";
		if(exists $nameidmap{$source} ){
			print $nameidmap{$source} . "\t";
		}
		if(exists $idnamemap{$source}){
			print $idnamemap{$source} . "\t";
		}
		print "\t" . $sourceReadCounts{$source} . "\n";
	}
	return (\%sourceTaxa, \%sourceReadCounts, \%taxonomy_counts);
}

=head2 get_ancestor_array
Takes an input taxID and returns the ancestors in an array going up the tree.
index 0 being the first ancestor.
last index being the root of the tree.
=cut

sub get_ancestor_array {
    my %args = @_;
	my $curID    = $args{tax_id} || miss("tax_id");
	my @ancestor = ();
	my $parent = Phylosift::Summarize::read_ncbi_taxonomy_structure();
	while ( defined($curID) && $curID != 1 ) {
		push( @ancestor, $curID );
		$curID = ${ $parent->{$curID} }[0];
	}
	return @ancestor;
}

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Phylosift::Benchmark


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Phylosift-Phylosift>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Phylosift-Phylosift>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Phylosift-Phylosift>

=item * Search CPAN

L<http://search.cpan.org/dist/Phylosift-Phylosift/>

=back

=head1 ACKNOWLEDGEMENTS


=head1 LICENSE AND COPYRIGHT

Copyright 2011 Aaron Darling and Guillaume Jospin.

    This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
    by the Free Software Foundation.

See http://dev.perl.org/licenses/ for more information.


=cut
1;    # End of Phylosift::Benchmark.pm
