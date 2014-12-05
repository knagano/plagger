package Plagger::Plugin::Filter::FetchNicoVideo;
use strict;
use base qw( Plagger::Plugin );

our $VERSION = 0.02;

use URI::Escape;
use File::Path qw(mkpath);
use File::Spec;
use HTTP::Request;
use Time::HiRes qw(sleep);
use Plagger::Enclosure;
use Plagger::UserAgent;
use CGI;

sub register {
    my ( $self, $context ) = @_;
    $context->register_hook( $self, 'update.entry.fixup' => \&filter, );
     my $ua = Plagger::UserAgent->new( keep_alive => 1 );
    $ua->cookie_jar( {} );
    $ua->post( "https://secure.nicovideo.jp/secure/login?site=niconico" => $self->conf );
    $self->{ua} = $ua;
}

sub init {
    my $self = shift;
    $self->SUPER::init(@_);

    defined $self->conf->{mail}
      or Plagger->context->error("conifg 'mail' is not set.");
    defined $self->conf->{password}
      or Plagger->context->error("config 'password' is not set.");
    defined $self->conf->{dir}
      or Plagger->context->error("config 'dir' is not set.");

    if ( $self->conf->{dir} =~ /^[a-zA-Z]/ && $self->conf->{dir} !~ /:/ ) {
        $self->conf->{dir} =
          File::Spec->catfile( Cwd::cwd, $self->conf->{dir} );
    }

    unless ( -e $self->conf->{dir} && -d _ ) {
        Plagger->context->log(
            warn => $self->conf->{dir} . " does not exist. Creating" );
        mkpath $self->conf->{dir};
    }
}

sub filter {
    my ( $self, $context, $args ) = @_;
    my $ua    = $self->{ua};
    my $entry = $args->{entry};

    #get video_id
    my ($video_id) = $entry->link =~ m!www.nicovideo.jp/watch/(.*)!;

    #get flv url
    my $res = $ua->get("http://www.nicovideo.jp/api/getflv?v=$video_id");
    my $q   = CGI->new( $res->content );
    my $flv_url = $q->param('url');

    unless ($flv_url) {
        $context->log( warn => "Not Found FLV URL : $video_id" );
        return;
    }
    $context->log( info => "Found FLV URL $flv_url" );

    my $enclosure = Plagger::Enclosure->new;
    $enclosure->url( URI->new($flv_url) );
    $enclosure->media_type("video/x-flv");

    #set local path
    my $filename = $self->conf->{id_as_filename} ? $video_id : $entry->title;
    utf8::encode($filename);
    if ( $self->conf->{filename_encode} ) {
        Encode::from_to( $filename, "utf-8", $self->conf->{filename_encode} );
    }

    $enclosure->url =~ m!^http://[^/]+(?:smilevideo|nicovideo)\.jp/smile\?(\w)=(?:[^.]+)\.\d+(?:low)?!;
    my %video_type_of = (
			 v => 'flv',
			 m => 'mp4',
			 s => 'swf',
		      );
    my $ext = exists( $video_type_of{$1} ) ? $video_type_of{$1} : "flv";
    
    my $path = File::Spec->catfile( $self->conf->{dir}, $filename . ".$ext" );

    unless ( -e $path ) {
	#access video page
	$ua->get("http://www.nicovideo.jp/watch/$video_id");

	#download flv file
	my $req = HTTP::Request->new(GET => $enclosure->url);
	$context->log(info => "Fetching $video_id FLV File from " . $enclosure->url . "..." );
	my $res = $ua->request($req, $path);
	$context->log(warn => "Fetch FLV Error: $video_id" ) if $res->is_error;	
    }else{
	$context->log(info => "Exist FLV File: $video_id"); 
	my $sleeping_time = $self->conf->{interval} || 15;
	$context->log(info => "sleep $sleeping_time.");
	sleep( $sleeping_time );
    }

    #download xml file
    if ( $self->conf->{download_comment} ) {
        $path = File::Spec->catfile( $self->conf->{dir}, $filename . ".xml" );
	unless ( -e $path ) {
	    my $thread_id = $q->param('thread_id');
	    my $post_data =
		qq!<thread res_from="-500" version="20061206" thread="$thread_id" />"!;
	    my $header = HTTP::Headers->new;
	    $header->header( 'Content-Type' => 'text/xml' );
	    my $req = HTTP::Request->new( 'POST', $q->param('ms'), $header, $post_data );
	    $context->log( info => "Fetching $video_id XML File ... " );
	    $res = $ua->request( $req, $path );
	    $context->log( warn => "Fetch XML Error: $video_id" ) if $res->is_error;
	}
    }

    $enclosure->filename($filename);
    $enclosure->local_path($path);    # set to be used in later plugins
    if  ($res->header('Content-Length') ) {
        $enclosure->length( $res->header('Content-Length') );
    }
    $enclosure->type( Plagger::Util::mime_type_of($path) );
    $entry->add_enclosure($enclosure);
}

1;

__END__

=head1 NAME

Plagger::Plugin::Filter::FetchNicoVideo - Fetch flv file from NicoVideo link

=head1 SYNOPSIS

  - module: Filter::FetchNicoVideo
    config:
      mail: your@mailadddres
      password: yourpassword
      dir: /path/to/files
      download_xml: 1 #optional default is 0
      filename_encode: euc-jp #optional default is utf-8
      interval: 60 #optional default is 15

=head1 DESCRIPTION

This plugin downloads flv file for each entry which has NicoVideo link.

=head1 CONFIG

=over 4

=item mail password

Your NicoVideo login mail address and password.

=item dir

Directory to store downloaded enclosures. Required.

=item download_xml

IF set, download comment xml file. Optional. Default is off.

=item filename_encode

File name encode. Example: euc-jp / shift_jis. Optional. Default is utf-8.

=item id_as_filename

IF set, set video id as flv file. Default file name is entry title. Optional.

=back

=head1 AUTHOR

Yusuke Wada

=head1 SEE ALSO

L<Plagger>, L<http://www.nicovideo.jp/>

=cut

