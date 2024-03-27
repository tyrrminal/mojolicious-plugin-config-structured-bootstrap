package Mojolicious::Plugin::Config::Structured::RAD;
use v5.26;
use warnings;

# ABSTRACT: Autoconfigure Mojolicious application and plugins for RAD

use Mojo::Base 'Mojolicious::Plugin';

use Array::Utils qw(intersect);
use Hash::Merge;

use experimental qw(signatures try);

sub register($self, $app, $conf) {
  my $cfg_dir = $app->home->child('cfg');
  my $merge = Hash::Merge->new('RIGHT_PRECEDENT');

  $app->plugin('NoSession');

  # Config::Structured
  $app->plugin(
    'Config::Structured' => $merge->merge({
      structure_file => $cfg_dir->child(sprintf('%s-conf.yml', lc($app->moniker)))->to_string,
      config_file    => $ENV{uc($app->moniker).'_CONFIG'},
    }, $conf->{'Config::Structured'}//{}),
  ) if(!exists($conf->{'Config::Structured'}) || defined($conf->{'Config::Structured'}));

  # ORM::DBIx
  $app->plugin(
    'ORM::DBIx' => $merge->merge({
      dsn                        => $app->conf->db->dsn,
      username                   => $app->conf->db->user,
      password                   => $app->conf->db->pass,
    }, $conf->{'ORM::DBIx'}//{}),
  ) if(!exists($conf->{'ORM::DBIx'}) || defined($conf->{'ORM::DBIx'}));
  
  # Migration::Sqitch
  $app->plugin(
    'Migration::Sqitch' => $merge->merge({
      dsn       => $app->conf->db->dsn,
      registry  => $app->conf->db->migration->registry,
      username  => $app->conf->db->migration->user,
      password  => $app->conf->db->migration->pass,
      directory => $app->conf->db->migration->directory,
    }, $conf->{'Migration::Sqitch'}//{}),
  ) if(!exists($conf->{'Migration::Sqitch'}) || defined($conf->{'Migration::Sqitch'}));

}

1;
