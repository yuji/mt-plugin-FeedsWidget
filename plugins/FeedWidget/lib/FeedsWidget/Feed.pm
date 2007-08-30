# $Id:$

package FeedsWidget::Feed;

use strict;

use MT;
use MT::Blog;
use base qw (MT::Object );

__PACKAGE__->install_properties(
    {
        column_defs => {
            'id'            => 'integer not null auto_increment',
            'blog_id'       => 'integer not null',
            'author_id'     => 'integer not null',
            'title'         => 'string(255)',
            'url'           => 'string(255)',
            'enable'        => 'boolean',
            'last_modified' => 'timestamp',
        },
        indexes => {
            blog_id       => 1,
            author_id     => 1,
            url           => 1,
            last_modified => 1,
        },
        datasource  => 'feedwidget_feed',
        primary_key => 'id',
        child_of    => 'MT::Blog',
    }
);

1;
