# DEPENDENCIES:
#   * XML::Feed
#   * Digest::MD5
#   * LWP::Simple
#   * File::Spec
#
# $Id:$

package MT::Plugin::FeedsWidget;

use strict;
use base qw( MT::Plugin );
our $VERSION = '1.0';
our $SCHEMA_VERSION = '0.2';

use MT;
use XML::Feed;
use FeedsWidget::Feed;
use Digest::MD5 qw(md5_hex);
use File::Spec;
use LWP::Simple;

my $plugin = __PACKAGE__->new(
    {
        id          => 'FeedsWidget',
        name        => 'Feed Reader Dashboard Widget',
        version     => $VERSION,
        description => "Feed aggregate dashboard widget. You can repost easily.",
        author_name => 'Six Apart, Ltd.',
        author_link => 'http://www.sixapart.com/',
        key         => 'FeedsWidget',
        settings    =>
            new MT::PluginSettings( [ ['use_qotd_us'], ['use_qotd_jp'], ] ),
        blog_config_template => 'config.tmpl',
        schema_version => $SCHEMA_VERSION,
    }
);
MT->add_plugin($plugin);

sub init_registry {
    my $plugin = shift;
    $plugin->registry(
        {
            object_types => {
                'feedswidget_feed' => 'FeedsWidget::Feed',
            },
            applications => {
                'cms' => {
                    widgets => {
                        'FeedsWidget' => {
                            label     => 'Aggregate Feeds',
                            template  => 'tmpl/widget.tmpl',
                            handler   => \&_hdlr_widget,
                            set       => 'main',
                            singular  => 1,
                            view      => 'blog',
                        },
                    },
                    methods => {
                        feed_widget_add_feed => \&_hdlr_add_feed,
                        feed_widget_unread_feed => \&_hdlr_unread_feed,
                    },
                },
            },
        });
}

sub _hdlr_widget {
    my $app = shift;
    my ( $tmpl, $param ) = @_;

    # prepare
    my $enc     = MT::config('PublishCharset');
    my $blog_id = $app->blog->id;
    my $config  = $plugin->get_config_hash( 'blog:' . $blog_id );

    # Read from database
    my @feed_loop;
    my $iter = FeedsWidget::Feed->load_iter({enable => 1});
    my $count = 0;
    while (my $feed = $iter->()) {
        my $feed_item = _fetch( $feed->url, $enc );
        next unless $feed_item;
        $feed->title($feed_item->{feed_title}),$feed->save unless $feed->title;
        $feed_item->{feed_id} = $feed->id;
        $feed_item->{__first__} = ($count == 0);
        $feed_item->{__count__} = $count;
        $count++;
        push @feed_loop, $feed_item if $feed_item;
    }

    $param->{feed_loop} = \@feed_loop;
    $param->{feed_max_count} = $count;
}


sub _hdlr_add_feed {
    my $app = shift;
    my $blog = $app->blog;
    my $user = $app->user;

    if (!$blog) {
        my $blog_id = $app->param('blog_id');
        $blog = MT->model('blog')->load($blog_id);
    }

    my $text = $app->param('text');
    my $feed = FeedsWidget::Feed->load({url => $text});
    unless ($feed) {
        $feed = FeedsWidget::Feed->new;
        $feed->blog_id($blog->id);
        $feed->author_id($user->id);
        $feed->url($text);
    }
    $feed->enable(1);
    $feed->save;

    $app->json_result(1);
}

sub _hdlr_unread_feed {
    my $app = shift;
    my $id = $app->param('id');
    my $feed = FeedsWidget::Feed->load($id);
    if ($feed) {
        $feed->enable(0);
        $feed->save;
    }

    $app->json_result(1);
}

sub load_config {
    my $plugin = shift;
    my $app = MT->instance;
    return unless $app->can('user');

    my ($param, $scope) = @_;
    $scope .= ':user:' . $app->user->id if $scope =~ m/^blog:/;
    $plugin->SUPER::load_config($param, $scope);
}

sub save_config {
    my $plugin = shift;
    my $app = MT->instance;
    return unless $app->can('user');

    my ($param, $scope) = @_;

    _update_qotd('http://questions.vox.com/',
                 'QOTD',
                 $param->{use_qotd_us} ? 1 : 0);
    _update_qotd('http://questions-jp.vox.com/',
                 'QOTD (jp)',
                 $param->{use_qotd_jp} ? 1 : 0);

    $scope .= ':user:' . $app->user->id if $scope =~ m/^blog:/;
    $plugin->SUPER::save_config($param, $scope);
}

sub reset_config {
    my $plugin = shift;
    my $app = MT->instance;
    return unless $app->can('user');
    my ($scope) = @_;
    $scope .= ':user:' . $app->user->id if $scope =~ m/^blog:/;
    $plugin->SUPER::reset_config($scope);
}

sub _fetch {
    my ( $uri, $enc ) = @_;

    my @feeds = XML::Feed->find_feeds($uri);
    return undef unless @feeds;
    my $feed_uri = $feeds[0];

    my $cachedir = MT->config('TempDir');
    if (! -e $cachedir) {
        MT->log( { message => "Cannot find $cachedir.", } );
        return undef;
    }
    my $cache = File::Spec->catdir($cachedir, Digest::MD5::md5_hex($uri));
    my $status = LWP::Simple::mirror($feed_uri, $cache)
        or MT->log({ message => "Cannot get content from $uri."}), return undef;
    my $FH;
    open $FH, $cache
        or MT->log({ message => "Cannot read content from file."}), return undef;
    my $feed = XML::Feed->parse( $FH );
    close $FH;

    return undef unless $feed;

    my $app = MT->instance;
    my $author = $app->user;
    my $auth_prefs = $author->entry_prefs;
    my $delim = chr( $auth_prefs->{tag_delim} );

    my $feed_item;
    my @items;
    for my $entry ( $feed->entries ) {
        my $content = $entry->content;
        my $body = $content ? $content->body : '';
        $body = Encode::decode_utf8($body)
            if !MT::I18N::is_utf8($body);
        my $title = $entry->title;
        $title = Encode::decode_utf8($title)
            if !MT::I18N::is_utf8($title);
        my $date = $entry->modified;
        $date = $date ? $date->ymd('/') : '';
        my $pubdate = sprintf( "%s", $date );

        my $tags;
        my @tags = $entry->category;
        if ( @tags ) {
            foreach my $tag ( @tags ) {
                $tag = Encode::decode_utf8($tag)
                    if !MT::I18N::is_utf8($tag);
                $tags .= $tag . $delim;
            }
        }

        push @items,
          {
            title   => MT::I18N::encode_text( $title, undef, $enc ),
            link    => $entry->link,
            body    => '<blockquote>' . MT::I18N::encode_text($body, undef, $enc ) . '</blockquote><br/>',
            tags    => $tags,
            pubdate => $pubdate,
          };
    }

    $feed_item->{feed_items} = \@items;
    $feed_item->{feed_link}  = $feed->link;

    my $feed_title = $feed->title;
    $feed_title = Encode::decode_utf8($feed_title)
        if !MT::I18N::is_utf8($feed_title);
    $feed_item->{feed_title} = MT::I18N::encode_text($feed_title, undef, $enc );

    return $feed_item;
}

sub _update_qotd {
    my ($url, $title, $state) = @_;
    my $app = MT->instance;
    my $blog = $app->blog;
    my $user = $app->user;

    my $qotd = FeedsWidget::Feed->load({url => $url});
    unless ($qotd) {
        $qotd = FeedsWidget::Feed->new;
        $qotd->blog_id($blog->id);
        $qotd->author_id($user->id);
        $qotd->title($title);
        $qotd->url($url);
    }
    $qotd->enable($state);
    $qotd->save;
}

1;
