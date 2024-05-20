package Mojolicious::Plugin::Config::Structured::Bootstrap;
use v5.26;
use warnings;

# ABSTRACT: Autoconfigure Mojolicious application and plugins

use Mojo::Base 'Mojolicious::Plugin';

use Array::Utils qw(intersect);
use Hash::Merge;
use HTTP::Status qw(:constants status_message);
use List::MoreUtils qw(arrayify);
use Module::Loadable qw(module_loadable);
use Readonly;
use Syntax::Keyword::Try;

use experimental qw(signatures);

Readonly::Hash my %RENDER_FAIL => (
  badreq   => HTTP_BAD_REQUEST,
  unauth   => HTTP_UNAUTHORIZED,
  notfound => HTTP_NOT_FOUND,
);
Readonly::Hash my %RENDER_SUCCESS => (
  nocontent => HTTP_NO_CONTENT
);

sub register($self, $app, $app_config) {
  $app->log->debug("=================-CSBootstrap Starting-===================");

  my $cfg_dir = $app->home->child('cfg');
  my $merge = Hash::Merge->new('RIGHT_PRECEDENT');

  my $ns_append = sub (@suffixes) {
    return join('::', ucfirst($app->moniker), @suffixes);
  };

  my $load = sub($name, $get_defaults = undef, $force_load = 0) {
    return unless(module_loadable("Mojolicious::Plugin::$name"));
    return if(!$force_load && exists($app_config->{$name}) && !defined($app_config->{$name}));
    try {
      my $defaults = ref($get_defaults) eq 'CODE' ? $get_defaults->() : {};
      $app->plugin($name, $merge->merge($defaults, $app_config->{$name}//{}));
      $app->log->debug("CSBootstrap loaded plugin '$name'");
    } catch($e) {
      if($e =~ /Can't locate object method "(.*)" via package "PKG0x/) {
        $e = "Config::Structured node '$1' does not exist";
      }
      chomp($e);
      $app->log->error("CSBootstrap failed to load plugin '$name': $e");
    }
  };

  $load->('Config::Structured' => sub {
    {
      structure_file => $cfg_dir->child(sprintf('%s-conf.yml', lc($app->moniker)))->to_string,
      config_file    => $ENV{uc($app->moniker).'_CONFIG'},
    }
  }, 1);

  # Sessionless
  $load->('Sessionless');

  # ORM::DBIx
  $load->('ORM::DBIx' => sub { {
    dsn                  => $app->conf->db->dsn,
    username             => $app->conf->db->user,
    password             => $app->conf->db->pass(1),
    feature_bundle       => 'v'.join(q{.}, @{$^V->{version}}[0,1]),
    tidy_format_skipping => ['## no tidy', '## use tidy'],
    connect_params       => { quote_names => 1 },
  } });
  
  # Migration::Sqitch
  $load->('Migration::Sqitch' => sub { {
    dsn       => $app->conf->db->dsn,
    registry  => $app->conf->db->migration->registry,
    username  => $app->conf->db->migration->user,
    password  => $app->conf->db->migration->pass(1),
    directory => $app->conf->db->migration->directory,
  } });

  # SendEmail
  $load->('SendEmail' => sub { {
    from          => $app->conf->email->from,
    host          => $app->conf->email->smtp->host,
    port          => $app->conf->email->smtp->port,
    ssl           => $app->conf->email->smtp->ssl,
    sasl_username => $app->conf->email->smtp->sasl_username || undef, 
    sasl_password => $app->conf->email->smtp->sasl_password(1) || undef, 

    recipient_resolver => sub($add) {
      if(defined($add)) {
        return [arrayify(map {__SUB__->($_)} $add->@*)] if(ref($add) eq 'ARRAY');
        return $add if($add =~ /@/);
        return __SUB__->($app->conf->email->recipients->{$add} // $app->conf->email->recipients->{default}) unless(ref($add));
      }
      return ();
    },
  } });

  $load->('Cron::Scheduler' => sub { {
    namespaces => [$ns_append->('Cron')],
    schedules  => $app->conf->scheduled_tasks->to_hash,
  } });

  $load->('Authentication::SAML' => sub { {
    entity_id      => $app->conf->auth->entity_id,
    metadata_url   => $app->conf->auth->metadata_url,
    slo_url        => $app->conf->auth->slo_url,
    sp_signing_key => $app->conf->auth->sp_signing_key
  } });

  $load->('Authentication::OIDC' => sub { {
    client_secret  => $app->conf->auth->client_secret(1),
    public_key     => $app->conf->auth->public_key,
    well_known_url => $app->conf->auth->well_known_url,
    login_path     => '/api/auth/login',
    make_routes    => 0,

    get_token      => sub ($c) {
      if(($c->req->headers->authorization//'') =~ /^Bearer (.*)/) { return $1; }
      return undef;
    },
    get_user       => sub ($token) {
      my $person = $app->model('Person')->find_or_create({
        firstname    => $token->{given_name},
        lastname     => $token->{family_name},
      }); 
      my $user = $app->model("User")->update_or_create({
        username       => $token->{preferred_username},
        email          => $token->{email},
        email_verified => $token->{email_verified} ? 'Y' : 'N',
        person         => $person,
      })
    },
    role_map       => $app->conf->auth->role_map,
    get_roles      => sub ($user, $token) {
      $token->{realm_access}->{roles}
    },

    on_success     => sub ($c, $token) {
      $c->stash(token => $token);
      my $tpl = <<'      END';
        <!doctype html>
        <html>
          <script type="text/javascript">
            localStorage.setItem("oidc_auth_token", "<%= $token %>");
            location.replace("/login/success");
          </script>
        </html>
      END
      return $c->render(inline => $tpl);
    },
    on_login => sub ($c, $u) {
      $u->update({last_login_at => \["NOW()"]});
      $u->update({last_activity_at => \["NOW()"]});
    },
    on_activity => sub ($c, $u) {
      $u->update({last_activity_at => \["NOW()"]})
    }
  } });

  $load->('Authorization::AccessControl' => sub { {
  } });

  $load->('Data::Transfigure' => sub { {
    renderers => [qw(openapi json)]
  } });

  $load->(OpenAPI => sub { {
    url              => $app->home->child('cfg')->child(sprintf('%s-api.yml', lc($app->moniker)))->to_string,
    op_spec_to_route => sub($plugin, $op_spec, $route, $t) {
      $route->to($op_spec->{operationId} =~ s/->/#/r) if($op_spec->{operationId});
    },
    security               => {
      Token =>  sub($c, $definition, $scopes, $cb) {
        try {
          my $u = $c->authn->current_user();
          return $c->$cb('User not authenticated') unless(defined($u));
          return $c->$cb('User email not verified') unless($u->email_verified);
          return $c->$cb() unless($scopes->@*);
          return $c->$cb() if(intersect($scopes->@*, $c->current_user_roles->@*));
          return $c->$cb('User not authorized');
        } catch($e) {
          $e =~ s/( at \/.*)$//;
          chomp($e);
          $c->$cb($e)
        }
      }
    }
  } });

  $load->('Module::Loader' => sub {
    {
      command_namespaces => [$ns_append->('Command')],
      plugin_namespaces  => [$ns_append->('Plugin')],
    }
  });

  foreach my $k (keys(%RENDER_FAIL)) {
    my $code = $RENDER_FAIL{$k};
    $app->helper("render_failure.$k" => sub($c, $message = status_message($code)) {
      chomp($message);
      $c->render(status => $code, openapi => { status => $code, errors => [{message => $message}]})
    })
  }
  foreach my $k (keys(%RENDER_SUCCESS)) {
    my $code = $RENDER_SUCCESS{$k};
    $app->helper("render_success.$k" => sub($c, $message = status_message($code)) {
      chomp($message);
      if($code == HTTP_NO_CONTENT) {
        $c->render(status => $code, text => $message);
      } else {
        $c->render(status => $code, openapi => { status => $code, errors => [{message => $message}]})
      }
    })
  }
  
}

=head1 AUTHOR

Mark Tyrrell C<< <mark@tyrrminal.dev> >>

=head1 LICENSE

Copyright (c) 2024 Mark Tyrrell

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

=cut

1;

__END__
