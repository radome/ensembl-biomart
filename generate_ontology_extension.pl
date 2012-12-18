#!/bin/env perl

use warnings;
use strict;

use DBI;
use Carp;
use Log::Log4perl qw(:easy);
use List::MoreUtils qw(any);
use Data::Dumper;
use DbiUtils;
use MartUtils;
use Getopt::Long;
use POSIX;

Log::Log4perl->easy_init($INFO);

my $logger = get_logger();

my $db_host = 'mysql-cluster-eg-prod-1.ebi.ac.uk';
my $db_port = 4238;
my $db_user = 'ensrw';
my $db_pwd = 'writ3rp1';
my $mart_db;
my $dataset;

sub usage {
    print "Usage: $0 [-h <host>] [-port <port>] [-u user <user>] [-p <pwd>] [-mart <mart>] [-databset <dataset_name>]\n";
    print "-h <host> Default is $db_host\n";
    print "-port <port> Default is $db_port\n";
    print "-u <host> Default is $db_user\n";
    print "-p <password> Default is top secret unless you know cat\n";
    print "-dataset <dataset_db>\n";
    print "-mart <mart_db>\n";
    exit 1;
};

my $options_okay = GetOptions (
			       "h=s"=>\$db_host,
			       "port=i"=>\$db_port,
			       "u=s"=>\$db_user,
			       "p=s"=>\$db_pwd,
			       "mart=s"=>\$mart_db,
			       "dataset=s"=>\$dataset,
			       "help"=>sub {usage()}
    );

if(!$options_okay) {
    usage();
}

if (!defined $mart_db || !defined $dataset) {
    usage();
}

# open a connection
# work out the name of the core
my $mart_string = "DBI:mysql:$mart_db:$db_host:$db_port";
my $mart_handle = DBI->connect($mart_string, $db_user, $db_pwd,
			       { RaiseError => 1 }
    ) or croak "Could not connect to $mart_string";

my $core_db = get_string($mart_handle->prepare("SELECT src_db FROM dataset_names WHERE name='$dataset'"));

if(!defined $core_db) {
    croak "Could not find core database for dataset $dataset";
}

my $filters = ;
my $attributes = ;

$logger->info("Creating base table for $dataset on $mart_db using $core_db");
create_base_table($mart_handle,$mart_db,$core_db,$dataset);

for my $condition (get_conditions($mart_handle,$core_db)) {
    $logger->info("Adding condition $condition for $dataset on $mart_db using $core_db");
    add_condition($mart_handle,$mart_db,$core_db,$dataset,$condition);
}


sub create_base_table {
    my ($mart_handle,$mart_db,$core_db,$dataset) = @_;
    my $drop_base_table = qq/drop table if exists ${mart_db}.${dataset}_gene__ontology_extension__dm/; 
    $logger->debug($drop_base_table);
    $mart_handle->do($drop_base_table);

    my $create_base_table = qq/create table ${mart_db}.${dataset}_gene__ontology_extension__dm as
select distinct t.transcript_id, 
ax.object_xref_id,
tx.dbprimary_acc subject_acc,
tx.display_label subject_label,
td.db_name subject_db,
sx.dbprimary_acc source_acc,
sx.display_label source_label,
sd.db_name source_db,
ag.associated_group_id group_id,
ag.description group_des
from ${core_db}.transcript t
left join ${core_db}.object_xref ox on (t.transcript_id=ox.ensembl_id 
and ox.ensembl_object_type='Transcript')
left join ${core_db}.xref tx on (tx.xref_id=ox.xref_id)
left join ${core_db}.external_db td on (tx.external_db_id=td.external_db_id)
left join ${core_db}.associated_xref ax using (object_xref_id)
left join ${core_db}.associated_group ag using (associated_group_id)
left join ${core_db}.xref sx on (sx.xref_id=ax.source_xref_id)
left join ${core_db}.external_db sd on (sx.external_db_id=sd.external_db_id)/;
    $logger->debug($create_base_table);
    $mart_handle->do($create_base_table);

    return;
}

sub get_conditions {
    my ($mart_handle,$core_db) = @_;
    my $get_conditions = "select distinct(condition_type) from $core_db.associated_xref";
    $logger->debug($get_conditions);
    my $sth = $mart_handle->prepare($get_conditions);
    return get_strings($sth);
}

sub add_condition {
    my ($mart_handle,$mart_db,$core_db,$dataset,$condition) = @_;

    my $add_condition = qq/create table ${mart_db}.TMP as
select oe.*,
cx.dbprimary_acc ${condition}_acc,
cx.display_label ${condition}_label,
cd.db_name ${condition}_db
from
${mart_db}.${dataset}_gene__ontology_extension__dm oe
left join $core_db.associated_xref ax on (oe.object_xref_id=ax.object_xref_id 
and ax.associated_group_id=oe.group_id 
and ax.condition_type='$condition')
left join $core_db.xref cx on (ax.xref_id=cx.xref_id)
left join $core_db.external_db cd on (cx.external_db_id=cd.external_db_id)/;
    $logger->debug($add_condition);
    $mart_handle->do($add_condition);

    my $drop_table = qq/drop table ${mart_db}.${dataset}_gene__ontology_extension__dm/;
    $logger->debug($drop_table);
    $mart_handle->do($drop_table);

    my $rename_table = qq/rename table ${mart_db}.TMP 
to ${mart_db}.${dataset}_gene__ontology_extension__dm/;
    $logger->debug($rename_table);
    $mart_handle->do($rename_table);

    return;
}
