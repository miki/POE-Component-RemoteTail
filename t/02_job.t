use strict;
use warnings;
use POE::Component::RemoteTail;
use Test::More tests => 1;

my $host     = 'www1';
my $path     = '/home/httpd/vhost/www1/logs/access_log';
my $user     = 'hoge';
my $password = 'fuga';

{
    my $job = POE::Component::RemoteTail->job(
        host          => $host,
        path          => $path,
        user          => $user,
        password      => $password,
        process_class => "POE::Component::RemoteTail::Engine::Default",
    );
    delete $job->{id};
    my $obj = bless(
        {
            'password'      => 'fuga',
            'process_class' => 'POE::Component::RemoteTail::Engine::Default',
            'user'          => 'hoge',
            'path'          => '/home/httpd/vhost/www1/logs/access_log',
            'host'          => 'www1'
        },
        'POE::Component::RemoteTail::Job'
    );
    is_deeply($job, $obj, "object is deeply matched");
}
