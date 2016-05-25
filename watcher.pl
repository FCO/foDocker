#!/usr/bin/env perl
use Mojolicious::Lite;
use Mojo::JSON qw/from_json/;
use Mojo::UserAgent;
use MongoDB;
use YAML;

helper ua => sub {
	state $ua ||= Mojo::UserAgent->new;
};

helper mongo => sub {
	state $mongo ||= MongoDB->connect('mongodb://mongo')
};

helper db => sub {
	my $c		= shift;
	state $db	||= $c->app->mongo->get_database("watcher");
};

helper separe_file => sub {
	my $c		= shift;
	my $file	= Load(shift);

	my %scale;
	$c->app->log->debug($c->app->dumper($file));
	if(exists $file->{services}) {
		for my $service(keys %{ $file->{services} }) {
			next unless exists $file->{services}{$service}{scaling};
			$scale{$service} = delete $file->{services}{$service}{scaling};
			$scale{$service}{min} = 0 unless exists $scale{$service}{min};
			$scale{$service}{initial} = $scale{$service}{min}
				if exists $scale{$service}{min}
					and (
						not exists $scale{$service}{initial}
						or $scale{$service}{initial} < $scale{$service}{min}
					)
			;
		}
	}

	{compose => $file, scale => \%scale}
};

helper get_stack_data => sub {
	my $c		= shift;
	my $stack	= shift;
	my $col		= $c->db->get_collection("stacks");
	my($data)	= $col->find({_id => $stack})->all;
	$c->app->log->debug("stack data:", $c->app->dumper($data));
	$data
};

helper get_scale_data => sub {
	my $c		= shift;
	my $stack	= shift;
	my $col		= $c->db->get_collection("stacks");
	my $scale	= $c->get_stack_data($stack)->{scale};
	$c->app->log->debug("scale:", $c->app->dumper($scale));
	$scale
};

helper get_compose_data => sub {
	my $c		= shift;
	my $stack	= shift;
	my $col		= $c->db->get_collection("stacks");
	my $compose	= $c->get_stack_data($stack)->{compose};
	$c->app->log->debug("compose:", $c->app->dumper($compose));
	$compose
};

helper create_stack => sub {
	my $c		= shift;
	my $stack	= shift;
	my $cb		= shift;

	my $compose = $c->get_compose_data($stack);
	$c->app->log->debug("compose yml:", $c->app->dumper($compose));
	$c->ua->post("http://composeapi:3000/$stack" => json => $compose => sub {
		my $ua	= shift;
		my $tx	= shift;
		if($tx->error or !$tx->res->json->{ok}) {
			$c->app->log->error($tx->error->{message});
			$c->render(json => {ok => \0, error => $tx->error->{message}}, status => 500);
			return
		}
		$c->app->log->debug($c->app->dumper($tx->res->json));
		$cb->($tx->res->json);
	});
};

helper run_stack => sub {
	my $c		= shift;
	$c->app->log->debug("run_stack(@_)");
	my $stack	= shift;
	my $cb		= pop;
	my $scale	= shift // $c->initial_scale($stack);

	$c->app->log->debug("run scale:", $c->app->dumper($scale));
	$c->ua->post("http://composeapi:3000/$stack/run" => json => $scale => sub {
		my $ua	= shift;
		my $tx	= shift;
		if($tx->error) {
			$c->app->log->error($tx->error->{message});
			$c->render(json => {ok => \0, error => $tx->error->{message}}, status => 500);
			return
		}
		$c->app->log->debug($c->app->dumper($tx->res->json));
		$cb->($tx->res->json);
	});
};

helper initial_scale => sub {
	my $c		= shift;
	my $stack	= shift;
	my $col		= $c->db->get_collection("stacks");
	my $scale	= $c->get_scale_data($stack);

	my %initial = map {($_ => $scale->{$_}{initial})} keys %$scale;
	$c->app->log->debug("initail:", $c->app->dumper(\%initial));
	\%initial
};

post "/:stack" => sub {
	my $c	= shift;
	die "no file" unless $c->param("file");
	my $stack = $c->param("stack");
	my $filename = "/tmp/$stack-$$-" . time . "-" . rand(10000) . ".yml";
	my $file = $c->param("file")->slurp;
	my $data = $c->separe_file($file);
	$c->app->log->debug($c->app->dumper($data));
	my $col = $c->db->get_collection("stacks");
	eval {$col->insert_one({ _id => $stack, %$data }) };
	$col->update_one( {_id => $stack}, {'$set' => $data}) if $@;
	$c->create_stack($stack => sub {
		$c->run_stack($stack => sub {
			my $scales = shift;
			$c->render(json => {ok => \1, scales => $scales});
		});
	});
	$c->render_later
};

app->start;
