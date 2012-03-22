package Phylosift::Benchmark;
use warnings;
use strict;
use Carp;
use Bio::Phylo;
use Phylosift::Summarize;
use Phylosift::Utilities;

=head1 SUBROUTINES/METHODS

=Head2 benchmark_illumina

WARNING: The input file must have the correct format to run the benchmark
Reads the input file looking for taxonomic origins in the read headers and 
Reads Summary files and generates accuracy ratings for every taxonmic level.

=cut
my %parent               = ();
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
	debug "NIMREF : $nimref\nINMREF : $inmref\n";
	%nameidmap = %$nimref;
	%idnamemap  = %$inmref;
	%parent  = Phylosift::Summarize::read_ncbi_taxonomy_structure();
	my ($refTaxa_ref, $taxon_read_counts) = getInputTaxa( file_name=>$self->{"readsFile"} );
	%refTaxa = %$refTaxa_ref;
	my ($top_place,$all_place) = read_seq_summary( self=>$self, output_path=>$output_path,read_source=> \%readSource );
	
	$taxon_read_counts->{""}=0;	# define this to process all taxa at once
	foreach my $taxon(keys(%$taxon_read_counts)){
		$taxon = undef if $taxon eq "";
		my ($tp_acc, $read_count) = compute_top_place_accuracy(self=>$self, top_place=>$top_place, target_taxon=>$taxon);
		my ($mass_acc, $mass_reads) = compute_mass_accuracy(self=>$self, all_place=>$all_place, target_taxon=>$taxon);
	
		$taxon = ".$taxon" if defined($taxon);
		my $report_file    = $output_path . "/" . $self->{"readsFile"} . "$taxon.tophit.csv";
		report_csv( self=>$self, report_file=>$report_file, mtref=>$tp_acc, read_number=>$read_count );
	
		my $allmass_report_file    = $output_path . "/" . $self->{"readsFile"} . "$taxon.mass.csv";
		report_csv( self=>$self, report_file=>$allmass_report_file, mtref=>$mass_acc, read_number=>$mass_reads );
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
		if ( $_ =~ m/^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$/ ) {
			my $read           = $1;
			my $taxPlacement   = $4;
			my $probability    = $5;
			my @taxPlacementID = Phylosift::Summarize::get_taxon_info(taxon=>$2);
			
			$read =~ s/\\.+//g;	# get rid of bioperl garbage

			#	    print "TaxPlacement : $2\t $taxPlacementID[0]\t\n";
			my @readAncestor = get_ancestor_array(tax_id=> $taxPlacementID[2] );

			#	    print $read." $taxPlacementID[1]\t$taxPlacementID[2]:\t@readAncestor\n";
			my $rank = $taxPlacementID[1];

			#keep only the top hits for all ranks for each Read
			my @array = ( $probability, $taxPlacementID[2], scalar(@readAncestor) );
			if ( !exists $topReadScore{$read} || $topReadScore{$read}->[0] < $probability ) {
				print STDERR "Replacing prob" if exists( $topReadScore{$read} );
				$topReadScore{$read} = \@array;
			}
			$allPlacedScore{$read}{$taxPlacement} = \@array;
		}
	}
	close($FILE_IN);
	
	return (\%topReadScore, \%allPlacedScore);
}

sub compute_top_place_accuracy {
    my %args = @_;
    my $self        = $args{self} || miss("self");
    my $thref = $args{top_place} || miss("top_place");    
    my $target_taxon = $args{target_taxon};
    my %topReadScore = %$thref;
    	
	my %matchTop = ();
	init_taxonomy_levels( ncbi_hash => \%matchTop );
	my $read_count = 0;
	foreach my $readID ( keys %topReadScore ) {
		#look at each taxonomic level for each read
		my $true_taxon    = $readSource{$readID};
		# only evaluate this read if it came from the target organism
		next if(defined($target_taxon) && $true_taxon ne $target_taxon);
		$read_count++;
		
		my @ancArrayRead = get_ancestor_array( tax_id=>$topReadScore{$readID}->[1] );
		my @tt           = Phylosift::Summarize::get_taxon_info(taxon=>$true_taxon);
		my @firstTaxon   = Phylosift::Summarize::get_taxon_info( taxon=>$ancArrayRead[0] );
		print "Read $readID assigned to $firstTaxon[0], true $tt[0]\n";
		foreach my $id (@ancArrayRead) {
			if ( exists $refTaxa{$true_taxon}{$id} ) {
				my @currTaxon = Phylosift::Summarize::get_taxon_info(taxon=>$id);
				my $currRank  = $currTaxon[1];
				$matchTop{$currRank} = 0 unless exists( $matchTop{$currRank} );
				$matchTop{$currRank}++;
			}
		}
	}
	return (\%matchTop, $read_count);
}

sub compute_mass_accuracy {	
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
		my $pretty = sprintf( "%.2f", 100 * $num / $denom );
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
		print $TOPHITS "Date,Superkingdom,Phylum,Subphylum,Class,Order,Family,Genus,Species,Subspecies,No Rank\n";
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
	print $TOPHITS "," . as_percent( num=>$matchTop{"no rank"},      denom=>$readNumber );
	print $TOPHITS "\n";
}

sub report_text {
    my %args = @_;
    my $self = $args{self};
	my $outputfile    = $args{output_file} || miss("output_file");
	my $mtref         = $args{mtref} || miss("mtref");
	my $maref         = $args{maref} || miss("maref");
	my $readNumber    = $args{read_number} || miss("read_number");
	my $allReadNumber = $args{all_read_number} || miss("all_read_number");
	my $totalProb     = $args{total_prob} || miss("total_prob");
	my $rtpref        = $args{rtpref} || miss("rtpref");
	my %matchTop      = %$mtref;
	my %matchAll      = %$maref;
	my %rankTotalProb = %$rtpref;
	print "\n";
	print "Top placed Matches : Superkingdom\t" . 100 * $matchTop{"superkingdom"} / $readNumber . "\n";
	print "Top placed Matches : Phylum\t" . 100 * $matchTop{"phylum"} / $readNumber . "\n";
	print "Top placed Matches : Subphylum\t" . 100 * $matchTop{"subphylum"} / $readNumber . "\n";
	print "Top placed Matches : Class\t" . 100 * $matchTop{"class"} / $readNumber . "\n";
	print "Top placed Matches : Order\t" . 100 * $matchTop{"order"} / $readNumber . "\n";
	print "Top placed Matches : Family\t" . 100 * $matchTop{"family"} / $readNumber . "\n";
	print "Top placed Matches : Genus\t" . 100 * $matchTop{"genus"} / $readNumber . "\n";
	print "Top placed Matches : Species\t" . 100 * $matchTop{"species"} / $readNumber . "\n";
	print "Top placed Matches : Subspecies\t" . 100 * $matchTop{"subspecies"} / $readNumber . "\n";
	print "Top placed Matches : No rank\t" . 100 * $matchTop{"no rank"} / $readNumber . "\n";
	print "\n";
	print "Total placed Reads : $readNumber\n";
	print "\n";
	print "All placements Matches : Superkingdom\t" . 100 * $matchAll{"superkingdom"} / $allReadNumber . "\n";
	print "All placements Matches : Phylum\t" . 100 * $matchAll{"phylum"} / $allReadNumber . "\n";
	print "All placements Matches : Subphylum\t" . 100 * $matchAll{"subphylum"} / $allReadNumber . "\n";
	print "All placements Matches : Class\t" . 100 * $matchAll{"class"} / $allReadNumber . "\n";
	print "All placements Matches : Order\t" . 100 * $matchAll{"order"} / $allReadNumber . "\n";
	print "All placements Matches : Family\t" . 100 * $matchAll{"family"} / $allReadNumber . "\n";
	print "All placements Matches : Genus\t" . 100 * $matchAll{"genus"} / $allReadNumber . "\n";
	print "All placements Matches : Species\t" . 100 * $matchAll{"species"} / $allReadNumber . "\n";
	print "All placements Matches : Subspecies\t" . 100 * $matchAll{"subspecies"} / $allReadNumber . "\n";
	print "All placements Matches : No rank\t" . 100 * $matchAll{"no rank"} / $allReadNumber . "\n";
	print "\n";
	print "All placements Matches : Superkingdom\t" . 100 * $matchAll{"superkingdom"} / $totalProb . "\n";
	print "All placements Matches : Phylum\t" . 100 * $matchAll{"phylum"} / $totalProb . "\n";
	print "All placements Matches : Subphylum\t" . 100 * $matchAll{"subphylum"} / $totalProb . "\n";
	print "All placements Matches : Class\t" . 100 * $matchAll{"class"} / $totalProb . "\n";
	print "All placements Matches : Order\t" . 100 * $matchAll{"order"} / $totalProb . "\n";
	print "All placements Matches : Family\t" . 100 * $matchAll{"family"} / $totalProb . "\n";
	print "All placements Matches : Genus\t" . 100 * $matchAll{"genus"} / $totalProb . "\n";
	print "All placements Matches : Species\t" . 100 * $matchAll{"species"} / $totalProb . "\n";
	print "All placements Matches : Subspecies\t" . 100 * $matchAll{"subspecies"} / $totalProb . "\n";
	print "All placements Matches : No rank\t" . 100 * $matchAll{"no rank"} / $totalProb . "\n";
	print "\n";
	print "Rank specific Percentages\n";
	print "All placements Matches : Superkingdom\t" . 100 * $matchAll{"superkingdom"} / $rankTotalProb{"superkingdom"} . "\n";
	print "All placements Matches : Phylum\t" . 100 * $matchAll{"phylum"} / $rankTotalProb{"phylum"} . "\n";
	print "All placements Matches : Subphylum\t" . 100 * $matchAll{"subphylum"} / $rankTotalProb{"subphylum"} . "\n";
	print "All placements Matches : Class\t" . 100 * $matchAll{"class"} / $rankTotalProb{"class"} . "\n";
	print "All placements Matches : Order\t" . 100 * $matchAll{"order"} / $rankTotalProb{"order"} . "\n";
	print "All placements Matches : Family\t" . 100 * $matchAll{"family"} / $rankTotalProb{"family"} . "\n";
	print "All placements Matches : Genus\t" . 100 * $matchAll{"genus"} / $rankTotalProb{"genus"} . "\n";
	print "All placements Matches : Species\t" . 100 * $matchAll{"species"} / $rankTotalProb{"species"} . "\n";
	print "All placements Matches : Subspecies\t" . 100 * $matchAll{"subspecies"} / $rankTotalProb{"subspecies"} . "\n";
	print "All placements Matches : No rank\t" . 100 * $matchAll{"no rank"} / $rankTotalProb{"no rank"} . "\n";
	print "\n";
	print "Total placements : $allReadNumber\n";
}

=head2 getInputTaxa
Reads a fasta file extracting the source field for each read.
Compiles statistics on the input read abundance
Returns a hash of taxonomic ancestry for Source organisms

TODO : Determine which reads came from the marker gene regions from the source genomes

=cut

sub getInputTaxa {
    my %args = @_;
	my $fileName         = $args{file_name} || miss("file_name");
	my %sourceTaxa       = ();
	my %sourceReadCounts = ();
	my $FILE_IN = ps_open( $fileName );
	while (<$FILE_IN>) {
		next unless $_ =~ m/^>/;
		$_ =~ m/^>(\S+).*SOURCE_\d+="(.*)"/;

		#push(@sourceTaxa,$1);
		$readSource{$1} = $2;
		my @ancestors = get_ancestor_array(tax_id=>$2);
		foreach my $id (@ancestors) {
			$sourceIDs{$id} = 1;
		}
		$sourceIDs{$2} = 1;
		if ( exists $sourceReadCounts{$2} ) {
			$sourceReadCounts{$2}++;
		} else {
			$sourceReadCounts{$2} = 0;
			foreach my $id (@ancestors) {
				$sourceTaxa{$2}{$id} = 1;
			}
		}
	}
	close($FILE_IN);
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
	return (\%sourceTaxa, \%sourceReadCounts);
}

=head2 get_ancestor_array
Takes an input taxID and returns the ancestors in an array going up the tree.
index 0 being the first ancestor.
last index being the root of the tree.
=cut

sub get_ancestor_array {
    my %args = @_;
	my $taxID    = $args{tax_id} || miss("tax_id");
	my $curID    = $taxID;
	my @ancestor = ();
	while ( defined($curID) && $curID != 1 ) {
		push( @ancestor, $curID );
		$curID = ${ $parent{$curID} }[0];
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
